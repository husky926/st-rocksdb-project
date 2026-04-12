// Plan step 1: open existing ST-key DB read-only, VerifyChecksum, print live SST list
// and num_entries from manifest metadata (sum vs expected key count).
//
//   traj_db_audit --db D:\Project\data\verify_traj_st_full [--expect-keys N]

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <rocksdb/db.h>
#include <rocksdb/metadata.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>

namespace {

rocksdb::Options OpenOptionsForRead() {
  rocksdb::Options o;
  o.create_if_missing = false;
  rocksdb::BlockBasedTableOptions tb;
  tb.experimental_spatio_temporal_meta_in_index_value = true;
  o.table_factory.reset(rocksdb::NewBlockBasedTableFactory(tb));
  return o;
}

}  // namespace

int main(int argc, char** argv) {
  std::string db_path;
  int64_t expect_keys = -1;

  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]) == "--db" && i + 1 < argc) {
      db_path = argv[++i];
    } else if (std::string(argv[i]) == "--expect-keys" && i + 1 < argc) {
      expect_keys = std::strtoll(argv[++i], nullptr, 10);
    } else if (std::string(argv[i]) == "-h" || std::string(argv[i]) == "--help") {
      std::cout << "traj_db_audit --db <dir> [--expect-keys N]\n"
                   "  Opens DB (ST table options), runs VerifyChecksum(), prints\n"
                   "  GetLiveFilesMetaData() per SST: level, name, size, num_entries.\n"
                   "  Sums num_entries for cross-check vs st_meta_smoke row count.\n";
      return 0;
    }
  }

  if (db_path.empty()) {
    std::cerr << "Required: --db <dir>\n";
    return 1;
  }

  rocksdb::Options opt = OpenOptionsForRead();
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status s = rocksdb::DB::Open(opt, db_path, &db);
  if (!s.ok()) {
    std::cerr << "DB::Open: " << s.ToString() << "\n";
    return 1;
  }

  std::cout << "VerifyChecksum...\n";
  s = db->VerifyChecksum();
  if (!s.ok()) {
    std::cerr << "VerifyChecksum FAILED: " << s.ToString() << "\n";
    return 2;
  }
  std::cout << "VerifyChecksum: OK\n";

  std::vector<rocksdb::LiveFileMetaData> files;
  db->GetLiveFilesMetaData(&files);

  uint64_t sum_entries = 0;
  uint64_t sum_size = 0;
  std::cout << "live_sst count=" << files.size() << "\n";
  for (const auto& f : files) {
    const std::string& fn =
        f.relative_filename.empty() ? f.name : f.relative_filename;
    std::cout << "  L" << f.level << " " << fn << " size=" << f.size
              << " num_entries=" << f.num_entries << " del=" << f.num_deletions
              << "\n";
    sum_entries += f.num_entries;
    sum_size += f.size;
  }
  std::cout << "sum_num_entries=" << sum_entries << " sum_file_size=" << sum_size
            << "\n";

  if (expect_keys >= 0) {
    if (static_cast<uint64_t>(expect_keys) == sum_entries) {
      std::cout << "expect_keys=" << expect_keys << " matches sum_num_entries.\n";
    } else {
      std::cout << "WARNING: expect_keys=" << expect_keys
                << " != sum_num_entries=" << sum_entries << "\n";
    }
  }

  std::cout
      << "\nNext: run tools/audit_sst_entries.ps1 to parse sst_dump per file.\n";
  return 0;
}
