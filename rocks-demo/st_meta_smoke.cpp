// Step 2 smoke: BlockBasedTableOptions::experimental_spatio_temporal_meta_in_index_value = true.
// Use a NEW empty --db path (do not reuse DBs created without this flag).
// Modes: default synthetic keys + Flush; or --csv same format as trajectory_validate.

#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_map>

#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>

#include "segment_value_codec.hpp"
#include "st_segment_key.hpp"
#include "st_user_key.hpp"
#include "trajectory_kv.hpp"

// Enables rocksdb/db/compaction logic in compaction_outputs.cc:
// cut output SST before the next key when ST event time bucket changes, etc.
struct StCompactionTimeSplitOptions {
  bool enable = false;
  // If non-zero, split when floor(t_sec / width) changes between consecutive ST keys.
  uint32_t bucket_width_sec = 0;
  // If non-zero, split when (max_t - min_t) in the current output would exceed this.
  uint32_t max_span_sec = 0;
  // If non-zero, split after this many ST keys in the current output file.
  uint32_t max_st_keys_per_file = 0;
};

using trajkv::DecodeValue;
using trajkv::EncodeValue;
using trajkv::MakeKey;
using trajkv::PointValue;
using trajkv::SplitCsvLine;

static rocksdb::Options MakeStMetaOptions(
    bool disable_auto_compactions, int write_buffer_mb,
    const StCompactionTimeSplitOptions& time_split = {}) {
  rocksdb::Options options;
  options.create_if_missing = true;
  options.disable_auto_compactions = disable_auto_compactions;
  if (write_buffer_mb > 0) {
    options.write_buffer_size =
        static_cast<size_t>(write_buffer_mb) * size_t{1048576};
  }
  if (time_split.enable) {
    options.experimental_compaction_event_time_split = true;
    options.experimental_compaction_event_time_bucket_width =
        time_split.bucket_width_sec;
    options.experimental_compaction_event_time_max_span =
        time_split.max_span_sec;
    options.experimental_compaction_event_time_max_point_keys =
        time_split.max_st_keys_per_file;
  }
  rocksdb::BlockBasedTableOptions table_options;
  table_options.experimental_spatio_temporal_meta_in_index_value = true;
  options.table_factory.reset(rocksdb::NewBlockBasedTableFactory(table_options));
  return options;
}

static rocksdb::Status MaybeCompactEntireKeyRange(rocksdb::DB* db) {
  rocksdb::CompactRangeOptions cro;
  return db->CompactRange(cro, nullptr, nullptr);
}

static int RunSynthetic(const std::string& db_path, bool disable_auto_compactions,
                        int write_buffer_mb,
                        const StCompactionTimeSplitOptions& time_split,
                        bool compact_after_ingest) {
  rocksdb::Options options =
      MakeStMetaOptions(disable_auto_compactions, write_buffer_mb, time_split);
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status st = rocksdb::DB::Open(options, db_path, &db);
  if (!st.ok()) {
    std::cerr << "DB::Open failed: " << st.ToString() << "\n";
    return 1;
  }

  constexpr int kN = 200;
  for (int i = 0; i < kN; ++i) {
    std::ostringstream oss;
    oss << "st:smoke:" << i;
    const std::string key = oss.str();
    const std::string val = "v" + std::to_string(i);
    st = db->Put(rocksdb::WriteOptions(), key, val);
    if (!st.ok()) {
      std::cerr << "Put failed: " << st.ToString() << "\n";
      return 1;
    }
  }

  st = db->Flush(rocksdb::FlushOptions());
  if (!st.ok()) {
    std::cerr << "Flush failed: " << st.ToString() << "\n";
    return 1;
  }

  if (compact_after_ingest) {
    st = MaybeCompactEntireKeyRange(db.get());
    if (!st.ok()) {
      std::cerr << "CompactRange failed: " << st.ToString() << "\n";
      return 1;
    }
  }

  for (int i = 0; i < kN; ++i) {
    std::ostringstream oss;
    oss << "st:smoke:" << i;
    const std::string key = oss.str();
    const std::string expect = "v" + std::to_string(i);
    std::string got;
    st = db->Get(rocksdb::ReadOptions(), key, &got);
    if (!st.ok() || got != expect) {
      std::cerr << "Get mismatch at i=" << i << " st=" << st.ToString() << "\n";
      return 2;
    }
  }

  std::cout << "st_meta_smoke: synthetic " << kN << " Put, Flush, Get - OK\n";
  return 0;
}

static int RunCsv(const std::string& csv_path, const std::string& db_path,
                  int64_t max_points, bool disable_auto_compactions,
                  int write_buffer_mb,
                  const StCompactionTimeSplitOptions& time_split,
                  bool compact_after_ingest) {
  std::ifstream in(csv_path);
  if (!in) {
    std::cerr << "Cannot open CSV: " << csv_path << "\n";
    return 1;
  }

  rocksdb::Options options =
      MakeStMetaOptions(disable_auto_compactions, write_buffer_mb, time_split);
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status st = rocksdb::DB::Open(options, db_path, &db);
  if (!st.ok()) {
    std::cerr << "DB::Open failed: " << st.ToString() << "\n";
    return 1;
  }

  std::string header;
  if (!std::getline(in, header)) {
    std::cerr << "Empty CSV.\n";
    return 1;
  }

  int64_t written = 0;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) {
      continue;
    }
    if (max_points >= 0 && written >= max_points) {
      break;
    }
    auto fields = SplitCsvLine(line);
    if (fields.size() < 7) {
      std::cerr << "Bad row\n";
      return 1;
    }
    const std::string& segment_id = fields[0];
    const int pt_idx = std::stoi(fields[2]);
    PointValue pv{};
    pv.unix_time_s = std::stoll(fields[3]);
    pv.lon = std::stod(fields[4]);
    pv.lat = std::stod(fields[5]);
    pv.alt_m = std::stod(fields[6]);
    st = db->Put(rocksdb::WriteOptions(), MakeKey(segment_id, pt_idx), EncodeValue(pv));
    if (!st.ok()) {
      std::cerr << "Put failed: " << st.ToString() << "\n";
      return 1;
    }
    ++written;
  }
  in.close();

  st = db->Flush(rocksdb::FlushOptions());
  if (!st.ok()) {
    std::cerr << "Flush failed: " << st.ToString() << "\n";
    return 1;
  }

  if (compact_after_ingest) {
    st = MaybeCompactEntireKeyRange(db.get());
    if (!st.ok()) {
      std::cerr << "CompactRange failed: " << st.ToString() << "\n";
      return 1;
    }
  }

  std::cout << "Wrote " << written << " rows (st_meta index) to " << db_path << "\n";

  std::ifstream in2(csv_path);
  std::getline(in2, header);
  int64_t checked = 0;
  while (std::getline(in2, line)) {
    if (line.empty()) {
      continue;
    }
    if (max_points >= 0 && checked >= max_points) {
      break;
    }
    auto fields = SplitCsvLine(line);
    if (fields.size() < 7) {
      continue;
    }
    const std::string& segment_id = fields[0];
    const int pt_idx = std::stoi(fields[2]);
    PointValue expect{};
    expect.unix_time_s = std::stoll(fields[3]);
    expect.lon = std::stod(fields[4]);
    expect.lat = std::stod(fields[5]);
    expect.alt_m = std::stod(fields[6]);
    std::string got_blob;
    st = db->Get(rocksdb::ReadOptions(), MakeKey(segment_id, pt_idx), &got_blob);
    if (!st.ok()) {
      std::cerr << "Get failed: " << st.ToString() << "\n";
      return 2;
    }
    PointValue got{};
    if (!DecodeValue(got_blob, &got) ||
        std::memcmp(&expect, &got, sizeof(PointValue)) != 0) {
      std::cerr << "Mismatch at segment=" << segment_id << " idx=" << pt_idx << "\n";
      return 2;
    }
    ++checked;
  }

  std::cout << "Verified " << checked << " Get round-trips - OK\n";
  return 0;
}

// CSV -> 21-byte ST user keys (0xE5 + t_sec + lon + lat + id); ST index tail can
// aggregate these. id is the sequential row index (unique). t_sec is unix cast to uint32.
static int RunCsvStUserKey(const std::string& csv_path, const std::string& db_path,
                           int64_t max_points, bool disable_auto_compactions,
                           int write_buffer_mb,
                           const StCompactionTimeSplitOptions& time_split,
                           bool compact_after_ingest) {
  std::ifstream in(csv_path);
  if (!in) {
    std::cerr << "Cannot open CSV: " << csv_path << "\n";
    return 1;
  }

  rocksdb::Options options =
      MakeStMetaOptions(disable_auto_compactions, write_buffer_mb, time_split);
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status st = rocksdb::DB::Open(options, db_path, &db);
  if (!st.ok()) {
    std::cerr << "DB::Open failed: " << st.ToString() << "\n";
    return 1;
  }

  std::string header;
  if (!std::getline(in, header)) {
    std::cerr << "Empty CSV.\n";
    return 1;
  }

  int64_t written = 0;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) {
      continue;
    }
    if (max_points >= 0 && written >= max_points) {
      break;
    }
    auto fields = SplitCsvLine(line);
    if (fields.size() < 7) {
      std::cerr << "Bad row\n";
      return 1;
    }
    const int64_t unix_s = std::stoll(fields[3]);
    PointValue pv{};
    pv.unix_time_s = unix_s;
    pv.lon = std::stod(fields[4]);
    pv.lat = std::stod(fields[5]);
    pv.alt_m = std::stod(fields[6]);
    const uint32_t t_sec =
        static_cast<uint32_t>(unix_s);  // Geolife-era unix fits uint32
    const std::string key =
        StUserKey(t_sec, static_cast<float>(pv.lon), static_cast<float>(pv.lat),
                  static_cast<uint64_t>(written));
    st = db->Put(rocksdb::WriteOptions(), key, EncodeValue(pv));
    if (!st.ok()) {
      std::cerr << "Put failed: " << st.ToString() << "\n";
      return 1;
    }
    ++written;
  }
  in.close();

  st = db->Flush(rocksdb::FlushOptions());
  if (!st.ok()) {
    std::cerr << "Flush failed: " << st.ToString() << "\n";
    return 1;
  }

  if (compact_after_ingest) {
    st = MaybeCompactEntireKeyRange(db.get());
    if (!st.ok()) {
      std::cerr << "CompactRange failed: " << st.ToString() << "\n";
      return 1;
    }
  }

  std::cout << "Wrote " << written << " rows (ST user keys + st_meta index) to "
            << db_path << "\n";

  std::ifstream in2(csv_path);
  std::getline(in2, header);
  int64_t checked = 0;
  while (std::getline(in2, line)) {
    if (line.empty()) {
      continue;
    }
    if (max_points >= 0 && checked >= max_points) {
      break;
    }
    auto fields = SplitCsvLine(line);
    if (fields.size() < 7) {
      continue;
    }
    const int64_t unix_s = std::stoll(fields[3]);
    PointValue expect{};
    expect.unix_time_s = unix_s;
    expect.lon = std::stod(fields[4]);
    expect.lat = std::stod(fields[5]);
    expect.alt_m = std::stod(fields[6]);
    const uint32_t t_sec = static_cast<uint32_t>(unix_s);
    const std::string k =
        StUserKey(t_sec, static_cast<float>(expect.lon),
                  static_cast<float>(expect.lat), static_cast<uint64_t>(checked));
    std::string got_blob;
    st = db->Get(rocksdb::ReadOptions(), k, &got_blob);
    if (!st.ok()) {
      std::cerr << "Get failed: " << st.ToString() << "\n";
      return 2;
    }
    PointValue got{};
    if (!DecodeValue(got_blob, &got) ||
        std::memcmp(&expect, &got, sizeof(PointValue)) != 0) {
      std::cerr << "Mismatch at st row " << checked << "\n";
      return 2;
    }
    ++checked;
  }

  std::cout << "Verified " << checked << " Get round-trips (ST keys) - OK\n";
  return 0;
}

static int RunSegmentMetaCsvStKey(const std::string& csv_path,
                                  const std::string& points_csv_path,
                                  const std::string& db_path,
                                  int64_t max_rows, int64_t flush_every,
                                  bool disable_auto_compactions,
                                  int write_buffer_mb,
                                  const StCompactionTimeSplitOptions& time_split,
                                  bool compact_after_ingest) {
  std::unordered_map<std::string, std::vector<segval::SegmentPoint>> by_segment;
  if (!segval::LoadSegmentPointsCsv(points_csv_path, &by_segment)) {
    return 1;
  }
  std::ifstream in(csv_path);
  if (!in) {
    std::cerr << "Cannot open segment-meta CSV: " << csv_path << "\n";
    return 1;
  }
  rocksdb::Options options =
      MakeStMetaOptions(disable_auto_compactions, write_buffer_mb, time_split);
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status st = rocksdb::DB::Open(options, db_path, &db);
  if (!st.ok()) {
    std::cerr << "DB::Open failed: " << st.ToString() << "\n";
    return 1;
  }
  std::string header;
  if (!std::getline(in, header)) {
    std::cerr << "Empty CSV.\n";
    return 1;
  }

  int64_t written = 0;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) {
      continue;
    }
    if (max_rows >= 0 && written >= max_rows) {
      break;
    }
    auto fields = SplitCsvLine(line);
    // segments_meta.csv columns:
    // 0:segment_id 1:dataset 2:point_count 3:t_start 4:t_end
    // 5:lon_min 6:lon_max 7:lat_min 8:lat_max 9:source_ref
    if (fields.size() < 9) {
      std::cerr << "Bad row in segment-meta CSV\n";
      return 1;
    }
    const uint32_t t_start = static_cast<uint32_t>(std::stoll(fields[3]));
    const uint32_t t_end = static_cast<uint32_t>(std::stoll(fields[4]));
    const float x_min = static_cast<float>(std::stod(fields[5]));
    const float x_max = static_cast<float>(std::stod(fields[6]));
    const float y_min = static_cast<float>(std::stod(fields[7]));
    const float y_max = static_cast<float>(std::stod(fields[8]));
    const uint32_t point_count = static_cast<uint32_t>(std::stoul(fields[2]));
    const std::string& segment_id = fields[0];
    auto pit = by_segment.find(segment_id);
    if (pit == by_segment.end()) {
      std::cerr << "No points for segment_id=" << segment_id << "\n";
      return 1;
    }
    if (pit->second.size() != static_cast<size_t>(point_count)) {
      std::cerr << "point_count mismatch segment_id=" << segment_id << " meta="
                << point_count << " points_csv=" << pit->second.size() << "\n";
      return 1;
    }

    const std::string key =
        StSegmentKey(t_start, t_end, x_min, y_min, x_max, y_max,
                     static_cast<uint64_t>(written));
    segval::SegmentValueHeader head{};
    head.t_start = t_start;
    head.t_end = t_end;
    head.x_min = x_min;
    head.y_min = y_min;
    head.x_max = x_max;
    head.y_max = y_max;
    head.point_count = point_count;
    const std::string encoded =
        segval::EncodeSegmentValueV2(head, pit->second);
    if (encoded.empty()) {
      std::cerr << "EncodeSegmentValueV2 failed for segment_id=" << segment_id
                << "\n";
      return 1;
    }
    st = db->Put(rocksdb::WriteOptions(), key, encoded);
    if (!st.ok()) {
      std::cerr << "Put failed: " << st.ToString() << "\n";
      return 1;
    }
    ++written;
    if (flush_every > 0 && (written % flush_every) == 0) {
      st = db->Flush(rocksdb::FlushOptions());
      if (!st.ok()) {
        std::cerr << "Flush failed: " << st.ToString() << "\n";
        return 1;
      }
    }
  }
  in.close();

  st = db->Flush(rocksdb::FlushOptions());
  if (!st.ok()) {
    std::cerr << "Flush failed: " << st.ToString() << "\n";
    return 1;
  }

  if (compact_after_ingest) {
    st = MaybeCompactEntireKeyRange(db.get());
    if (!st.ok()) {
      std::cerr << "CompactRange failed: " << st.ToString() << "\n";
      return 1;
    }
  }

  std::cout << "Wrote " << written
            << " rows (segment ST keys + V2 value with points) to " << db_path
            << "\n";

  // Spot verification by replaying the same rows.
  std::ifstream in2(csv_path);
  std::getline(in2, header);
  int64_t checked = 0;
  while (std::getline(in2, line)) {
    if (line.empty()) {
      continue;
    }
    if (max_rows >= 0 && checked >= max_rows) {
      break;
    }
    auto fields = SplitCsvLine(line);
    if (fields.size() < 9) {
      continue;
    }
    const std::string& segment_id = fields[0];
    const uint32_t t_start = static_cast<uint32_t>(std::stoll(fields[3]));
    const uint32_t t_end = static_cast<uint32_t>(std::stoll(fields[4]));
    const float x_min = static_cast<float>(std::stod(fields[5]));
    const float x_max = static_cast<float>(std::stod(fields[6]));
    const float y_min = static_cast<float>(std::stod(fields[7]));
    const float y_max = static_cast<float>(std::stod(fields[8]));
    const uint32_t point_count = static_cast<uint32_t>(std::stoul(fields[2]));
    const std::string key =
        StSegmentKey(t_start, t_end, x_min, y_min, x_max, y_max,
                     static_cast<uint64_t>(checked));
    std::string got_blob;
    st = db->Get(rocksdb::ReadOptions(), key, &got_blob);
    if (!st.ok()) {
      std::cerr << "Get failed: " << st.ToString() << "\n";
      return 2;
    }
    segval::DecodedSegmentValue got{};
    if (!segval::DecodeSegmentValue(got_blob, &got) || got.is_legacy) {
      std::cerr << "Expected V2 segment value at row " << checked << "\n";
      return 2;
    }
    if (got.header.t_start != t_start || got.header.t_end != t_end ||
        got.header.point_count != point_count) {
      std::cerr << "Header mismatch at segment row " << checked << "\n";
      return 2;
    }
    auto pit = by_segment.find(segment_id);
    if (pit == by_segment.end() || pit->second.size() != got.points.size()) {
      std::cerr << "Point list mismatch at row " << checked << "\n";
      return 2;
    }
    for (size_t i = 0; i < got.points.size(); ++i) {
      const auto& a = got.points[i];
      const auto& b = pit->second[i];
      if (a.unix_s != b.unix_s || a.lon != b.lon || a.lat != b.lat) {
        std::cerr << "Point mismatch at segment row " << checked << " i=" << i
                  << "\n";
        return 2;
      }
    }
    ++checked;
  }
  std::cout << "Verified " << checked
            << " Get round-trips (segment ST keys) - OK\n";
  return 0;
}

int main(int argc, char** argv) {
  std::string db_path;
  std::string csv_path;
  std::string segment_meta_csv_path;
  std::string segment_points_csv_path;
  int64_t max_points = 5000;
  bool st_keys = false;
  bool st_segment_keys = false;
  int64_t flush_every = -1;
  bool disable_auto_compactions = false;
  int write_buffer_mb = 0;
  StCompactionTimeSplitOptions time_split{};
  bool compact_after_ingest = false;

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--db" && i + 1 < argc) {
      db_path = argv[++i];
    } else if (a == "--csv" && i + 1 < argc) {
      csv_path = argv[++i];
    } else if (a == "--segment-meta-csv" && i + 1 < argc) {
      segment_meta_csv_path = argv[++i];
    } else if (a == "--segment-points-csv" && i + 1 < argc) {
      segment_points_csv_path = argv[++i];
    } else if (a == "--max-points" && i + 1 < argc) {
      max_points = std::stoll(argv[++i]);
    } else if (a == "--flush-every" && i + 1 < argc) {
      flush_every = std::stoll(argv[++i]);
    } else if (a == "--disable-auto-compactions") {
      disable_auto_compactions = true;
    } else if (a == "--write-buffer-mb" && i + 1 < argc) {
      write_buffer_mb = std::stoi(argv[++i]);
    } else if (a == "--st-compaction-time-split") {
      time_split.enable = true;
    } else if (a == "--st-compaction-bucket-sec" && i + 1 < argc) {
      time_split.bucket_width_sec =
          static_cast<uint32_t>(std::stoul(argv[++i]));
    } else if (a == "--st-compaction-max-span-sec" && i + 1 < argc) {
      time_split.max_span_sec =
          static_cast<uint32_t>(std::stoul(argv[++i]));
    } else if (a == "--st-compaction-max-st-keys" && i + 1 < argc) {
      time_split.max_st_keys_per_file =
          static_cast<uint32_t>(std::stoul(argv[++i]));
    } else if (a == "--compact-after-ingest") {
      compact_after_ingest = true;
    } else if (a == "--st-keys") {
      st_keys = true;
    } else if (a == "--st-segment-keys") {
      st_segment_keys = true;
    } else if (a == "-h" || a == "--help") {
      std::cout
          << "Step 2 smoke: experimental_spatio_temporal_meta_in_index_value = true.\n"
             "Use a NEW empty --db directory (not a DB from trajectory_validate).\n\n"
             "  st_meta_smoke --db <path>\n"
             "      Synthetic keys, Flush, Get.\n"
             "  st_meta_smoke --db <path> --csv <segments_points.csv> [--max-points N]\n"
             "      Trajectory CSV keys (segment\\0be32 idx); default max-points 5000.\n"
             "  st_meta_smoke --db <path> --csv <...> --st-keys [--max-points N]\n"
             "      Same CSV but keys are 21-byte ST layout (0xE5+t+lon+lat+id);\n"
             "      id = row index; enables ST index aggregation on real points.\n"
             "      Use max-points -1 for all rows (slow / large DB).\n"
             "  st_meta_smoke --db <path> --segment-meta-csv <segments_meta.csv>\n"
             "      --segment-points-csv <segments_points.csv> --st-segment-keys [--max-points N]\n"
             "      Segment-object mode: one KV per segment with ST segment key\n"
             "      (0xE6+...) and V2 value (header + all points t,lon,lat).\n"
             "  --flush-every N\n"
             "      Optional: Flush after every N writes (useful to generate many SSTs).\n"
             "  --disable-auto-compactions\n"
             "      Keep many L0 files for diagnostics/ablation.\n"
             "  --write-buffer-mb N\n"
             "      Optional write buffer size in MB.\n"
             "  Time-aligned compaction output (see experimental_compaction_event_time_* in RocksDB):\n"
             "  --st-compaction-time-split\n"
             "      Enable splitting SST outputs during compaction when ST keys cross time rules.\n"
             "  --st-compaction-bucket-sec W\n"
             "      Cut when floor(t_sec/W) changes (t from ST user key; segment keys use t_start).\n"
             "  --st-compaction-max-span-sec S\n"
             "      Cut when (max t - min t) in the output file would exceed S (0 = off).\n"
             "  --st-compaction-max-st-keys K\n"
             "      Cut after K ST keys in one output file (0 = off).\n"
             "  --compact-after-ingest\n"
             "      Run CompactRange on the default CF after flush (applies time-split on compaction).\n";
      return 0;
    }
  }

  if (db_path.empty()) {
    std::cerr << "Required: --db <empty_or_new_directory>\n";
    return 1;
  }

  if (!time_split.enable &&
      (time_split.bucket_width_sec != 0 || time_split.max_span_sec != 0 ||
       time_split.max_st_keys_per_file != 0)) {
    time_split.enable = true;
  }

  if (st_keys && csv_path.empty()) {
    std::cerr << "--st-keys requires --csv\n";
    return 1;
  }
  if (st_segment_keys && segment_meta_csv_path.empty()) {
    std::cerr << "--st-segment-keys requires --segment-meta-csv\n";
    return 1;
  }
  if (st_segment_keys && segment_points_csv_path.empty()) {
    std::cerr << "--st-segment-keys requires --segment-points-csv (full point list per segment)\n";
    return 1;
  }
  if (st_segment_keys && st_keys) {
    std::cerr << "Cannot use both --st-keys and --st-segment-keys\n";
    return 1;
  }

  if (csv_path.empty() && segment_meta_csv_path.empty()) {
    return RunSynthetic(db_path, disable_auto_compactions, write_buffer_mb,
                       time_split, compact_after_ingest);
  }
  if (st_segment_keys) {
    return RunSegmentMetaCsvStKey(segment_meta_csv_path, segment_points_csv_path,
                                  db_path, max_points, flush_every,
                                  disable_auto_compactions, write_buffer_mb,
                                  time_split, compact_after_ingest);
  }
  if (st_keys) {
    return RunCsvStUserKey(csv_path, db_path, max_points,
                           disable_auto_compactions, write_buffer_mb,
                           time_split, compact_after_ingest);
  }
  return RunCsv(csv_path, db_path, max_points, disable_auto_compactions,
                write_buffer_mb, time_split, compact_after_ingest);
}
