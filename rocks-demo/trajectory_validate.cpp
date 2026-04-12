// Step 1: load processed segments_points.csv into RocksDB and verify Get round-trip.
// Key: segment_id + '\0' + big-endian uint32 point_index
// Value: 32 bytes: int64 unix_time_s (LE), double lon, lat, alt_m (LE)

#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>

#include <rocksdb/db.h>
#include <rocksdb/options.h>

#include "trajectory_kv.hpp"

using trajkv::DecodeValue;
using trajkv::EncodeValue;
using trajkv::MakeKey;
using trajkv::PointValue;
using trajkv::SplitCsvLine;

int main(int argc, char** argv) {
  std::string csv_path;
  std::string db_path = "rocksdb_traj_validate";
  int64_t max_points = -1;  // all

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--csv" && i + 1 < argc) {
      csv_path = argv[++i];
    } else if (a == "--db" && i + 1 < argc) {
      db_path = argv[++i];
    } else if (a == "--max-points" && i + 1 < argc) {
      max_points = std::stoll(argv[++i]);
    } else if (a == "-h" || a == "--help") {
      std::cout
          << "Usage: trajectory_validate --csv <segments_points.csv> [--db <path>] "
             "[--max-points N]\n"
             "  Loads each point row into RocksDB, then re-reads CSV and verifies Get.\n";
      return 0;
    }
  }

  if (csv_path.empty()) {
    std::cerr << "Missing --csv path.\n";
    return 1;
  }

  std::ifstream in(csv_path);
  if (!in) {
    std::cerr << "Cannot open CSV: " << csv_path << "\n";
    return 1;
  }

  rocksdb::Options options;
  options.create_if_missing = true;

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
      std::cerr << "Bad row (expected >=7 fields): " << line.substr(0, 80) << "...\n";
      return 1;
    }

    const std::string& segment_id = fields[0];
    const int pt_idx = std::stoi(fields[2]);
    PointValue pv{};
    pv.unix_time_s = std::stoll(fields[3]);
    pv.lon = std::stod(fields[4]);
    pv.lat = std::stod(fields[5]);
    pv.alt_m = std::stod(fields[6]);

    const std::string key = MakeKey(segment_id, pt_idx);
    const std::string val = EncodeValue(pv);

    st = db->Put(rocksdb::WriteOptions(), key, val);
    if (!st.ok()) {
      std::cerr << "Put failed: " << st.ToString() << "\n";
      return 1;
    }
    ++written;
  }
  in.close();

  std::cout << "Wrote " << written << " point rows to DB: " << db_path << "\n";

  std::ifstream in2(csv_path);
  std::getline(in2, header);
  int64_t checked = 0;
  int64_t mismatches = 0;
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

    const std::string key = MakeKey(segment_id, pt_idx);
    std::string got_blob;
    st = db->Get(rocksdb::ReadOptions(), key, &got_blob);
    if (!st.ok()) {
      std::cerr << "Get failed for key segment=" << segment_id << " idx=" << pt_idx
                << " : " << st.ToString() << "\n";
      ++mismatches;
      continue;
    }
    PointValue got{};
    if (!DecodeValue(got_blob, &got)) {
      std::cerr << "Bad value size for segment=" << segment_id << " idx=" << pt_idx << "\n";
      ++mismatches;
      continue;
    }
    if (std::memcmp(&expect, &got, sizeof(PointValue)) != 0) {
      std::cerr << "Mismatch segment=" << segment_id << " idx=" << pt_idx << "\n";
      ++mismatches;
    }
    ++checked;
  }

  std::cout << "Verified " << checked << " Get round-trips";
  if (mismatches == 0) {
    std::cout << " - OK\n";
    return 0;
  }
  std::cout << "; mismatches: " << mismatches << "\n";
  return 2;
}
