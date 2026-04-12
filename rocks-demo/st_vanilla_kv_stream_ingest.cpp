// Upstream (facebook) RocksDB only: create a new DB with plain BlockBasedTable,
// read framed KV stream from st_fork_kv_stream_dump, Put all keys, Flush + optional Compact.
//
// Usage: st_vanilla_kv_stream_ingest --db <new_empty_dir> --in <dump.kvs> [--compact]

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>

#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>
#include <rocksdb/write_batch.h>

namespace {

rocksdb::Options VanillaIngestOptions(int write_buffer_mb) {
  rocksdb::Options o;
  o.create_if_missing = true;
  // Default true in upstream RocksDB 11+ appends UDT bytes before seq+type in
  // internal keys; our dump is plain user keys and window scan strips 8 bytes.
  o.persist_user_defined_timestamps = false;
  if (write_buffer_mb > 0) {
    o.write_buffer_size = static_cast<size_t>(write_buffer_mb) * size_t{1048576};
  }
  rocksdb::BlockBasedTableOptions tb;
  // Intentionally NO experimental_spatio_temporal_meta — SSTs must be vanilla-native.
  o.table_factory.reset(rocksdb::NewBlockBasedTableFactory(tb));
  return o;
}

bool ReadU32(std::istream& in, uint32_t* out) {
  unsigned char b[4];
  in.read(reinterpret_cast<char*>(b), 4);
  if (in.gcount() != 4) {
    return false;
  }
  *out = static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
         (static_cast<uint32_t>(b[2]) << 16) | (static_cast<uint32_t>(b[3]) << 24);
  return true;
}

constexpr char kMagic[8] = {'W', 'U', 'X', 'I', 'K', 'V', '0', '1'};
constexpr uint32_t kMaxRecord = 64u * 1024u * 1024u;

}  // namespace

int main(int argc, char** argv) {
  std::string db_path;
  std::string in_path;
  bool do_compact = false;
  int write_buffer_mb = 256;

  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--db" && i + 1 < argc) {
      db_path = argv[++i];
    } else if (a == "--in" && i + 1 < argc) {
      in_path = argv[++i];
    } else if (a == "--compact") {
      do_compact = true;
    } else if (a == "--write-buffer-mb" && i + 1 < argc) {
      write_buffer_mb = std::atoi(argv[++i]);
    } else if (a == "-h" || a == "--help") {
      std::cout
          << "st_vanilla_kv_stream_ingest --db <new_dir> --in <dump.kvs> [--compact]\n"
             "  Builds a DB using **upstream** RocksDB only (plain SSTs).\n"
             "  Input must be produced by st_fork_kv_stream_dump (WUXIKV01).\n";
      return 0;
    }
  }

  if (db_path.empty() || in_path.empty()) {
    std::cerr << "Required: --db <dir> --in <dump.kvs>\n";
    return 1;
  }

  std::ifstream in(in_path, std::ios::binary);
  if (!in) {
    std::cerr << "Cannot open input: " << in_path << std::endl;
    return 2;
  }

  char magic[8];
  in.read(magic, 8);
  if (in.gcount() != 8 || std::memcmp(magic, kMagic, 8) != 0) {
    std::cerr << "Bad magic (expected WUXIKV01)\n";
    return 2;
  }

  rocksdb::Options opt = VanillaIngestOptions(write_buffer_mb);
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status st = rocksdb::DB::Open(opt, db_path, &db);
  if (!st.ok()) {
    std::cerr << "DB::Open(create): " << st.ToString() << std::endl;
    return 3;
  }

  const rocksdb::WriteOptions wopt;
  uint64_t n = 0;
  std::string key_buf;
  std::string val_buf;
  rocksdb::WriteBatch batch;
  size_t batch_bytes = 0;
  const size_t kBatchFlush = size_t{4} * 1048576;

  while (true) {
    uint32_t kl = 0, vl = 0;
    if (!ReadU32(in, &kl)) {
      break;
    }
    if (!ReadU32(in, &vl)) {
      std::cerr << "Truncated header after " << n << " records\n";
      return 4;
    }
    if (kl > kMaxRecord || vl > kMaxRecord) {
      std::cerr << "Record too large at " << n << std::endl;
      return 4;
    }
    key_buf.resize(kl);
    val_buf.resize(vl);
    // gcount() is for the last read only; validate each read separately.
    if (kl > 0) {
      in.read(key_buf.data(), static_cast<std::streamsize>(kl));
      if (in.gcount() != static_cast<std::streamsize>(kl)) {
        std::cerr << "Truncated key payload at record " << n << std::endl;
        return 4;
      }
    }
    if (vl > 0) {
      in.read(val_buf.data(), static_cast<std::streamsize>(vl));
      if (in.gcount() != static_cast<std::streamsize>(vl)) {
        std::cerr << "Truncated value payload at record " << n << std::endl;
        return 4;
      }
    }

    batch.Put(key_buf, val_buf);
    batch_bytes += kl + vl + 32;
    ++n;

    if (batch_bytes >= kBatchFlush) {
      st = db->Write(wopt, &batch);
      if (!st.ok()) {
        std::cerr << "Write failed: " << st.ToString() << std::endl;
        return 5;
      }
      batch.Clear();
      batch_bytes = 0;
    }
  }

  if (batch.GetDataSize() > 0) {
    st = db->Write(wopt, &batch);
    if (!st.ok()) {
      std::cerr << "Final Write failed: " << st.ToString() << std::endl;
      return 5;
    }
  }

  st = db->Flush(rocksdb::FlushOptions());
  if (!st.ok()) {
    std::cerr << "Flush: " << st.ToString() << std::endl;
    return 6;
  }

  if (do_compact) {
    rocksdb::CompactRangeOptions cro;
    st = db->CompactRange(cro, nullptr, nullptr);
    if (!st.ok()) {
      std::cerr << "CompactRange: " << st.ToString() << std::endl;
      return 7;
    }
  }

  std::cout << "vanilla_kv_ingest wrote " << n << " keys to " << db_path << "\n";
  return 0;
}
