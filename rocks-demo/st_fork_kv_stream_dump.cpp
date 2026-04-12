// Fork RocksDB only: open an existing ST-meta DB (same table options as ingest path),
// iterate default CF, write framed (user_key, value) records for st_vanilla_kv_stream_ingest.
//
// Frame file format:
//   8-byte magic "WUXIKV01"
//   repeat: uint32_le key_len, uint32_le val_len, key bytes, value bytes
//
// Usage: st_fork_kv_stream_dump --db <fork_db> --out <file.kvs>

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>

#include <rocksdb/db.h>
#include <rocksdb/iterator.h>
#include <rocksdb/options.h>
#include <rocksdb/slice.h>
#include <rocksdb/table.h>

namespace {

using rocksdb::Slice;

rocksdb::Slice UserKeyFromInternalKey(const Slice& internal_key) {
  constexpr size_t kFooter = 8;
  if (internal_key.size() < kFooter) {
    return Slice();
  }
  return Slice(internal_key.data(), internal_key.size() - kFooter);
}

rocksdb::Options OpenForkDbReadOptions() {
  rocksdb::Options o;
  o.create_if_missing = false;
  rocksdb::BlockBasedTableOptions tb;
  tb.experimental_spatio_temporal_meta_in_index_value = true;
  o.table_factory.reset(rocksdb::NewBlockBasedTableFactory(tb));
  return o;
}

void WriteU32(std::ostream& out, uint32_t v) {
  char b[4];
  b[0] = static_cast<char>(v & 0xff);
  b[1] = static_cast<char>((v >> 8) & 0xff);
  b[2] = static_cast<char>((v >> 16) & 0xff);
  b[3] = static_cast<char>((v >> 24) & 0xff);
  out.write(b, 4);
}

constexpr char kMagic[8] = {'W', 'U', 'X', 'I', 'K', 'V', '0', '1'};

}  // namespace

int main(int argc, char** argv) {
  std::string db_path;
  std::string out_path;

  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--db" && i + 1 < argc) {
      db_path = argv[++i];
    } else if (a == "--out" && i + 1 < argc) {
      out_path = argv[++i];
    } else if (a == "-h" || a == "--help") {
      std::cout
          << "st_fork_kv_stream_dump --db <fork_db> --out <dump.kvs>\n"
             "  Opens fork ST-meta DB read-only, exports user keys + values (WUXIKV01 format).\n"
             "  Feed the file to st_vanilla_kv_stream_ingest to build an official-RocksDB replica.\n";
      return 0;
    }
  }

  if (db_path.empty() || out_path.empty()) {
    std::cerr << "Required: --db <dir> --out <file.kvs>\n";
    return 1;
  }

  rocksdb::Options opt = OpenForkDbReadOptions();
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status st = rocksdb::DB::OpenForReadOnly(opt, db_path, &db, false);
  if (!st.ok()) {
    st = rocksdb::DB::Open(opt, db_path, &db);
  }
  if (!st.ok()) {
    std::cerr << "DB::Open failed: " << st.ToString() << std::endl;
    return 2;
  }

  std::ofstream out(out_path, std::ios::binary);
  if (!out) {
    std::cerr << "Cannot open output: " << out_path << std::endl;
    return 3;
  }

  out.write(kMagic, sizeof(kMagic));
  if (!out) {
    std::cerr << "Write magic failed\n";
    return 3;
  }

  rocksdb::ReadOptions ro;
  ro.total_order_seek = true;

  uint64_t n = 0;
  std::unique_ptr<rocksdb::Iterator> it(db->NewIterator(ro));
  for (it->SeekToFirst(); it->Valid(); it->Next()) {
    const Slice ikey = it->key();
    const Slice ukey = UserKeyFromInternalKey(ikey);
    if (ukey.empty()) {
      continue;
    }
    const Slice val = it->value();
    if (ukey.size() > 0xffffffffu || val.size() > 0xffffffffu) {
      std::cerr << "Key/value too large at record " << n << std::endl;
      return 4;
    }
    WriteU32(out, static_cast<uint32_t>(ukey.size()));
    WriteU32(out, static_cast<uint32_t>(val.size()));
    out.write(ukey.data(), static_cast<std::streamsize>(ukey.size()));
    out.write(val.data(), static_cast<std::streamsize>(val.size()));
    if (!out) {
      std::cerr << "Write failed at record " << n << std::endl;
      return 4;
    }
    ++n;
  }
  if (!it->status().ok()) {
    std::cerr << "Iterator: " << it->status().ToString() << std::endl;
    return 5;
  }

  out.close();
  std::cout << "fork_kv_dump wrote " << n << " records to " << out_path << "\n";
  return 0;
}
