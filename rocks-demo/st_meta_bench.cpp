// Micro-benchmark: sequential Put + Flush + random Get, OFF vs ON st-meta index.
// No gflags; same link as rocks-demo. Comparable intent to db_bench fillseq + readrandom.

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <random>
#include <string>

#include <rocksdb/db.h>
#include <rocksdb/options.h>
#include <rocksdb/table.h>

namespace {

using clock = std::chrono::steady_clock;

struct Stats {
  double fill_micros_per_op{};
  double read_micros_per_op{};
};

rocksdb::Options MakeOptions(bool st_meta) {
  rocksdb::Options options;
  options.create_if_missing = true;
  rocksdb::BlockBasedTableOptions table_options;
  table_options.experimental_spatio_temporal_meta_in_index_value = st_meta;
  options.table_factory.reset(rocksdb::NewBlockBasedTableFactory(table_options));
  return options;
}

Stats RunOnce(const std::string& db_path, bool st_meta, int num, int reads) {
  rocksdb::DestroyDB(db_path, rocksdb::Options());

  rocksdb::Options options = MakeOptions(st_meta);
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status st = rocksdb::DB::Open(options, db_path, &db);
  if (!st.ok()) {
    std::cerr << "DB::Open failed: " << st.ToString() << "\n";
    std::exit(1);
  }

  const std::string value(100, 'x');
  char keybuf[32];

  const auto t0 = clock::now();
  for (int i = 0; i < num; ++i) {
    std::snprintf(keybuf, sizeof(keybuf), "%016d", i);
    st = db->Put(rocksdb::WriteOptions(), keybuf, value);
    if (!st.ok()) {
      std::cerr << "Put failed: " << st.ToString() << "\n";
      std::exit(1);
    }
  }
  st = db->Flush(rocksdb::FlushOptions());
  if (!st.ok()) {
    std::cerr << "Flush failed: " << st.ToString() << "\n";
    std::exit(1);
  }
  const auto t1 = clock::now();

  std::mt19937 rng(12345);
  std::uniform_int_distribution<int> dist(0, num - 1);
  std::string got;
  got.reserve(128);

  const auto t2 = clock::now();
  for (int r = 0; r < reads; ++r) {
    const int k = dist(rng);
    std::snprintf(keybuf, sizeof(keybuf), "%016d", k);
    st = db->Get(rocksdb::ReadOptions(), keybuf, &got);
    if (!st.ok()) {
      std::cerr << "Get failed: " << st.ToString() << "\n";
      std::exit(1);
    }
  }
  const auto t3 = clock::now();

  const double fill_us =
      std::chrono::duration<double, std::micro>(t1 - t0).count();
  const double read_us =
      std::chrono::duration<double, std::micro>(t3 - t2).count();

  Stats s;
  s.fill_micros_per_op = fill_us / static_cast<double>(num);
  s.read_micros_per_op = read_us / static_cast<double>(reads);
  return s;
}

}  // namespace

int main(int argc, char** argv) {
  int num = 300000;
  int reads = 300000;
  std::string off_db = "bench_st_meta_embed/off";
  std::string on_db = "bench_st_meta_embed/on";

  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--num" && i + 1 < argc) {
      num = std::atoi(argv[++i]);
    } else if (a == "--reads" && i + 1 < argc) {
      reads = std::atoi(argv[++i]);
    } else if (a == "--db-off" && i + 1 < argc) {
      off_db = argv[++i];
    } else if (a == "--db-on" && i + 1 < argc) {
      on_db = argv[++i];
    } else if (a == "-h" || a == "--help") {
      std::cout
          << "st_meta_bench [--num N] [--reads R] [--db-off path] [--db-on path]\n"
             "  Sequential Put + Flush + random Get; prints OFF vs ON st-meta.\n";
      return 0;
    }
  }

  if (num < 1 || reads < 1) {
    std::cerr << "num and reads must be >= 1\n";
    return 1;
  }

  std::cout << "num=" << num << " reads=" << reads << "\n";

  std::cout << "\n--- OFF (experimental_spatio_temporal_meta_in_index_value=false) ---\n";
  const Stats off = RunOnce(off_db, false, num, reads);
  std::cout << "fillseq-like (Put+Flush): " << off.fill_micros_per_op << " micros/op\n";
  std::cout << "readrandom:                " << off.read_micros_per_op << " micros/op\n";

  std::cout << "\n--- ON (experimental_spatio_temporal_meta_in_index_value=true) ---\n";
  const Stats on = RunOnce(on_db, true, num, reads);
  std::cout << "fillseq-like (Put+Flush): " << on.fill_micros_per_op << " micros/op\n";
  std::cout << "readrandom:                " << on.read_micros_per_op << " micros/op\n";

  std::cout << "\n--- Ratio (ON / OFF; >1 means slower) ---\n";
  std::cout << "fill ratio:  " << (on.fill_micros_per_op / off.fill_micros_per_op) << "\n";
  std::cout << "read ratio:  " << (on.read_micros_per_op / off.read_micros_per_op) << "\n";

  return 0;
}
