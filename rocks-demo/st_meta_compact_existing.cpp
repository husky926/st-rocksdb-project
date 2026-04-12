// Offline compaction on an EXISTING ST-key DB (use a **copy** of precious data).
// After open: SetOptions(target_file_size_base) then CompactRange(full keyspace)
// on the default column family to increase SST count / tighten per-file bounds.
//
// Example:
//   robocopy D:\Project\data\verify_traj_st_full D:\Project\data\verify_traj_compact /E
//   st_meta_compact_existing.exe --db D:\Project\data\verify_traj_compact --target-file-mb 32

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <rocksdb/db.h>
#include <rocksdb/iterator.h>
#include <rocksdb/metadata.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>

namespace {

rocksdb::Options BenchCompatibleOpenOptions() {
  rocksdb::Options o;
  o.create_if_missing = false;
  rocksdb::BlockBasedTableOptions tb;
  tb.experimental_spatio_temporal_meta_in_index_value = true;
  tb.block_cache = rocksdb::NewLRUCache(8ULL * 1048576);
  tb.cache_index_and_filter_blocks = true;
  o.table_factory.reset(rocksdb::NewBlockBasedTableFactory(tb));
  return o;
}

void ReportFiles(rocksdb::DB* db, const char* label) {
  std::vector<rocksdb::LiveFileMetaData> m;
  db->GetLiveFilesMetaData(&m);
  std::cout << label << " live_sst=" << m.size() << "\n";
  for (const auto& f : m) {
    std::cout << "  L" << f.level << " " << f.name
              << " num_entries=" << f.num_entries << "\n";
  }
}

void ProbeUserKeys(rocksdb::DB* db, size_t sample_limit = 4096) {
  rocksdb::ReadOptions ro;
  std::unique_ptr<rocksdb::Iterator> it(db->NewIterator(ro));
  size_t seen = 0;
  size_t e6 = 0;
  size_t e5 = 0;
  size_t other = 0;
  uint32_t first_t = 0;
  uint32_t last_t = 0;
  bool have_t = false;
  for (it->SeekToFirst(); it->Valid() && seen < sample_limit; it->Next()) {
    const rocksdb::Slice k = it->key();
    if (k.size() == 0) {
      ++other;
      ++seen;
      continue;
    }
    const uint8_t magic = static_cast<uint8_t>(k.data()[0]);
    if (magic == 0xE6 && k.size() >= 5) {
      ++e6;
      uint32_t t = 0;
      std::memcpy(&t, k.data() + 1, sizeof(uint32_t));
      if (!have_t) {
        first_t = t;
        have_t = true;
      }
      last_t = t;
    } else if (magic == 0xE5) {
      ++e5;
    } else {
      ++other;
    }
    ++seen;
  }
  std::cout << "KEY_PROBE sample=" << seen << " e6=" << e6 << " e5=" << e5
            << " other=" << other;
  if (have_t) {
    std::cout << " e6_t_first=" << first_t << " e6_t_last=" << last_t;
  }
  std::cout << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  std::string db_path;
  int target_file_mb = 32;
  bool dry_run = false;
  bool st_time_split_enable = false;
  uint32_t st_bucket_sec = 0;
  uint32_t st_min_keys_per_file = 0;

  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--db") == 0 && i + 1 < argc) {
      db_path = argv[++i];
      continue;
    }
    if (std::strcmp(argv[i], "--target-file-mb") == 0 && i + 1 < argc) {
      char* e = nullptr;
      const long v = std::strtol(argv[++i], &e, 10);
      if (e == argv[i] || *e != '\0' || v < 1 || v > 2048) {
        std::cerr << "Invalid --target-file-mb (1..2048)\n";
        return 1;
      }
      target_file_mb = static_cast<int>(v);
      continue;
    }
    if (std::strcmp(argv[i], "--st-time-split") == 0) {
      st_time_split_enable = true;
      continue;
    }
    if (std::strcmp(argv[i], "--st-bucket-sec") == 0 && i + 1 < argc) {
      char* e = nullptr;
      const unsigned long v = std::strtoul(argv[++i], &e, 10);
      if (e == argv[i] || *e != '\0' || v == 0 || v > 86400ul * 3650ul) {
        std::cerr << "Invalid --st-bucket-sec (1..315360000)\n";
        return 1;
      }
      st_bucket_sec = static_cast<uint32_t>(v);
      continue;
    }
    if (std::strcmp(argv[i], "--st-min-keys") == 0 && i + 1 < argc) {
      char* e = nullptr;
      const unsigned long v = std::strtoul(argv[++i], &e, 10);
      if (e == argv[i] || *e != '\0' || v > 100000000ul) {
        std::cerr << "Invalid --st-min-keys (0..1e8)\n";
        return 1;
      }
      st_min_keys_per_file = static_cast<uint32_t>(v);
      continue;
    }
    if (std::strcmp(argv[i], "--dry-run") == 0) {
      dry_run = true;
      continue;
    }
    if (std::strcmp(argv[i], "-h") == 0 ||
        std::strcmp(argv[i], "--help") == 0) {
      std::cout
          << "st_meta_compact_existing --db <dir> [options]\n"
             "  Opens an existing DB (same ST table options as st_meta_read_bench).\n"
             "  **Copy the DB first** if the source directory is precious.\n"
             "  Lists live SSTs, sets target_file_size_base (default 32 MB), runs "
             "CompactRange on full keyspace.\n"
             "Options:\n"
             "  --target-file-mb N   passed to SetOptions before compact (default 32)\n"
             "  --st-time-split      enable ST event-time split during compaction\n"
             "  --st-bucket-sec W    split when floor(t_sec/W) changes (segment keys use t_start)\n"
             "  --st-min-keys K      require at least K ST keys in output before splitting on bucket change\n"
             "  --dry-run            print live files only; no SetOptions/CompactRange\n";
      return 0;
    }
    std::cerr << "Unknown: " << argv[i] << "\n";
    return 1;
  }

  if (db_path.empty()) {
    std::cerr << "Required: --db <dir>\n";
    return 1;
  }

  rocksdb::Options opt = BenchCompatibleOpenOptions();
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status s = rocksdb::DB::Open(opt, db_path, &db);
  if (!s.ok()) {
    std::cerr << "DB::Open: " << s.ToString() << "\n";
    return 1;
  }

  ReportFiles(db.get(), "BEFORE");
  ProbeUserKeys(db.get());
  if (dry_run) {
    return 0;
  }

  const uint64_t base_bytes =
      static_cast<uint64_t>(target_file_mb) * 1048576ull;
  std::unordered_map<std::string, std::string> cf_opts;
  cf_opts["target_file_size_base"] = std::to_string(base_bytes);
  if (st_time_split_enable || st_bucket_sec != 0 || st_min_keys_per_file != 0) {
    cf_opts["experimental_compaction_event_time_split"] = "true";
    if (st_bucket_sec != 0) {
      cf_opts["experimental_compaction_event_time_bucket_width"] =
          std::to_string(st_bucket_sec);
    }
    if (st_min_keys_per_file != 0) {
      cf_opts["experimental_compaction_event_time_min_keys_per_file"] =
          std::to_string(st_min_keys_per_file);
    }
  }
  s = db->SetOptions(cf_opts);
  if (!s.ok()) {
    std::cerr << "SetOptions warning: " << s.ToString()
              << " (continuing with CompactRange)\n";
  } else {
    std::cout << "SetOptions target_file_size_base=" << base_bytes << " ok\n";
  }

  // Reopen to ensure subsequent manual compaction picks up latest mutable CF
  // options on all paths.
  db.reset();
  s = rocksdb::DB::Open(opt, db_path, &db);
  if (!s.ok()) {
    std::cerr << "DB::Open(after SetOptions): " << s.ToString() << "\n";
    return 1;
  }
  ReportFiles(db.get(), "REOPEN");
  ProbeUserKeys(db.get());

  rocksdb::CompactRangeOptions cro;
  std::cout << "CompactRange (full keyspace, may take a long time)...\n";
  std::cout.flush();
  s = db->CompactRange(cro, nullptr, nullptr);
  if (!s.ok()) {
    std::cerr << "CompactRange: " << s.ToString() << "\n";
    return 1;
  }

  ReportFiles(db.get(), "AFTER");
  std::cout
      << "Next: run st_meta_sst_diag.exe on each *.sst (or st_diag_align_read_bench "
         "after pointing SST paths / copy DB).\n";
  return 0;
}
