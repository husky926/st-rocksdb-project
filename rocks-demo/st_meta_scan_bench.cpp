// Scan benchmark: SeekToFirst + Next with experimental_st_prune_scan OFF vs ON.
// Keys use magic 0xE5 + t + lon + lat + uint64 id (see rocksdb/table/st_meta_user_key.h).
// Requires DB built with experimental_spatio_temporal_meta_in_index_value = true.

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <sstream>
#include <string>

#include <rocksdb/db.h>
#include <rocksdb/iterator.h>
#include <rocksdb/options.h>
#include <rocksdb/perf_context.h>
#include <rocksdb/table.h>

namespace {

std::string StUserKey(uint32_t t_sec, float lon, float lat, uint64_t id) {
  std::string k(21, '\0');
  k[0] = static_cast<char>(0xE5);
  std::memcpy(&k[1], &t_sec, 4);
  std::memcpy(&k[5], &lon, 4);
  std::memcpy(&k[9], &lat, 4);
  std::memcpy(&k[13], &id, 8);
  return k;
}

rocksdb::Options StMetaTableOptions() {
  rocksdb::Options o;
  o.create_if_missing = true;
  rocksdb::BlockBasedTableOptions tb;
  tb.experimental_spatio_temporal_meta_in_index_value = true;
  o.table_factory.reset(rocksdb::NewBlockBasedTableFactory(tb));
  return o;
}

}  // namespace

std::string NowTimestampForLog() {
  using clock = std::chrono::system_clock;
  const std::time_t t = clock::to_time_t(clock::now());
  std::tm tm_buf{};
#ifdef _WIN32
  localtime_s(&tm_buf, &t);
#else
  localtime_r(&t, &tm_buf);
#endif
  std::ostringstream oss;
  oss << std::put_time(&tm_buf, "%Y-%m-%dT%H:%M:%S");
  return oss.str();
}

bool ParsePositiveInt(const char* s, int* out) {
  if (s == nullptr || out == nullptr) {
    return false;
  }
  char* end = nullptr;
  errno = 0;
  const long n = std::strtol(s, &end, 10);
  if (end == s || *end != '\0' || errno != 0 || n <= 0 ||
      n > static_cast<long>(std::numeric_limits<int>::max())) {
    return false;
  }
  *out = static_cast<int>(n);
  return true;
}

bool ParseU32(const char* s, uint32_t* out) {
  if (s == nullptr || out == nullptr) {
    return false;
  }
  char* end = nullptr;
  errno = 0;
  const unsigned long v = std::strtoul(s, &end, 10);
  if (end == s || *end != '\0' || errno != 0) {
    return false;
  }
  if (v > static_cast<unsigned long>(std::numeric_limits<uint32_t>::max())) {
    return false;
  }
  *out = static_cast<uint32_t>(v);
  return true;
}

bool ParseFloat(const char* s, float* out) {
  if (s == nullptr || out == nullptr) {
    return false;
  }
  char* end = nullptr;
  errno = 0;
  const double d = std::strtod(s, &end);
  if (end == s || *end != '\0' || errno != 0) {
    return false;
  }
  *out = static_cast<float>(d);
  return true;
}

void PrintUsage() {
  std::cout
      << "st_meta_scan_bench [--db <dir>] [--num <positive int>] "
         "[--log <csv>] [--log=<csv>]\n"
         "  Prune window (forward scan with ST summaries):\n"
         "    --prune-t-min <u32> --prune-t-max <u32>\n"
         "    --prune-x-min <float> --prune-x-max <float>\n"
         "    --prune-y-min <float> --prune-y-max <float>\n"
         "  Legacy: [db_dir] [num_keys] in addition to flags above.\n";
}

void AppendCsvLog(const std::string& path, const std::string& ts, int num_keys,
                  int64_t full_c, int64_t prune_c, uint64_t off_br, uint64_t on_br,
                  double off_us, double on_us, double ratio_or_neg, uint32_t pt_min,
                  uint32_t pt_max, float px_min, float px_max, float py_min,
                  float py_max, double key_selectivity) {
  bool need_header = true;
  {
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (in && in.tellg() > 0) {
      need_header = false;
    }
  }
  std::ofstream ofs(path, std::ios::app);
  if (!ofs) {
    std::cerr << "Warning: cannot open log file: " << path << "\n";
    return;
  }
  if (need_header) {
    ofs << "ts,keys,full_count,prune_count,off_block_reads,on_block_reads,"
           "off_time_us,on_time_us,block_read_ratio_on_div_off,"
           "prune_t_min,prune_t_max,prune_x_min,prune_x_max,prune_y_min,"
           "prune_y_max,key_selectivity\n";
  }
  ofs << ts << ',' << num_keys << ',' << full_c << ',' << prune_c << ','
      << off_br << ',' << on_br << ',' << off_us << ',' << on_us << ',';
  if (ratio_or_neg >= 0) {
    ofs << ratio_or_neg;
  }
  ofs << ',' << pt_min << ',' << pt_max << ',' << px_min << ',' << px_max << ','
      << py_min << ',' << py_max << ',' << key_selectivity << '\n';
}

int main(int argc, char** argv) {
  // Bumps when argv parsing changes — if your run does not print this, the exe
  // is stale; rebuild: cmake --build <rocks-demo/build> --target st_meta_scan_bench
  constexpr const char* kBenchBuildId = "st_meta_scan_bench 2026-04-04 argv-v4";
  std::cout << kBenchBuildId << " argc=" << argc << "\n";

  std::string db_path = "D:/Project/data/bench_st_meta_prune_scan";
  int num_keys = 80000;
  std::string log_path;
  uint32_t prune_t_min = 0;
  uint32_t prune_t_max = 99;
  float prune_x_min = -119.5f;
  float prune_x_max = -119.0f;
  float prune_y_min = 35.5f;
  float prune_y_max = 36.0f;

  int legacy_positional = 0;
  for (int i = 1; i < argc; ++i) {
    const char* a = argv[i];
    if (std::strncmp(a, "--log=", 6) == 0 && a[6] != '\0') {
      log_path = a + 6;
      continue;
    }
    if (std::strcmp(a, "--log") == 0 && i + 1 < argc) {
      log_path = argv[++i];
      continue;
    }
    if (std::strcmp(a, "--db") == 0 && i + 1 < argc) {
      db_path = argv[++i];
      continue;
    }
    if (std::strcmp(a, "--num") == 0 && i + 1 < argc) {
      if (!ParsePositiveInt(argv[++i], &num_keys)) {
        std::cerr << "Invalid --num (need positive integer)\n";
        return 1;
      }
      continue;
    }
#define ST_META_SCAN_BENCH_PARSE_OPT(name, parse_fn, var)                      \
  if (std::strcmp(a, name) == 0 && i + 1 < argc) {                             \
    if (!parse_fn(argv[++i], &(var))) {                                        \
      std::cerr << "Invalid " name " value\n";                                 \
      return 1;                                                                \
    }                                                                          \
    continue;                                                                  \
  }
    ST_META_SCAN_BENCH_PARSE_OPT("--prune-t-min", ParseU32, prune_t_min);
    ST_META_SCAN_BENCH_PARSE_OPT("--prune-t-max", ParseU32, prune_t_max);
    ST_META_SCAN_BENCH_PARSE_OPT("--prune-x-min", ParseFloat, prune_x_min);
    ST_META_SCAN_BENCH_PARSE_OPT("--prune-x-max", ParseFloat, prune_x_max);
    ST_META_SCAN_BENCH_PARSE_OPT("--prune-y-min", ParseFloat, prune_y_min);
    ST_META_SCAN_BENCH_PARSE_OPT("--prune-y-max", ParseFloat, prune_y_max);
#undef ST_META_SCAN_BENCH_PARSE_OPT
    if (std::strcmp(a, "-h") == 0 || std::strcmp(a, "--help") == 0) {
      PrintUsage();
      return 0;
    }
    if (a[0] == '-') {
      std::cerr << "Unknown option: " << a << "\n";
      PrintUsage();
      return 1;
    }
    if (legacy_positional == 0) {
      db_path = a;
      legacy_positional++;
    } else if (legacy_positional == 1) {
      if (!ParsePositiveInt(a, &num_keys)) {
        std::cerr << "Invalid num_keys (second positional): \"" << a << "\"\n";
        PrintUsage();
        return 1;
      }
      legacy_positional++;
    } else {
      std::cerr << "Unexpected argument: " << a << "\n";
      PrintUsage();
      return 1;
    }
  }

  if (num_keys <= 0) {
    std::cout << "ERROR: num_keys must be positive (got " << num_keys << ")\n";
    return 1;
  }
  if (prune_t_min > prune_t_max) {
    std::cerr << "ERROR: --prune-t-min must be <= --prune-t-max\n";
    return 1;
  }

  std::cout << "config: num_keys=" << num_keys << " db=\"" << db_path
            << "\" log=" << (log_path.empty() ? "(none)" : log_path) << "\n";
  std::cerr << "config: num_keys=" << num_keys << " db=\"" << db_path
            << "\" log=" << (log_path.empty() ? "(none)" : log_path) << "\n";
  std::cout << "config: prune t=[" << prune_t_min << "," << prune_t_max << "] "
            << "x=[" << prune_x_min << "," << prune_x_max << "] y=["
            << prune_y_min << "," << prune_y_max << "]\n";
  std::cerr << "config: prune t=[" << prune_t_min << "," << prune_t_max << "] "
            << "x=[" << prune_x_min << "," << prune_x_max << "] y=["
            << prune_y_min << "," << prune_y_max << "]\n";

  rocksdb::DestroyDB(db_path, rocksdb::Options());

  rocksdb::Options opt = StMetaTableOptions();
  std::unique_ptr<rocksdb::DB> db;
  rocksdb::Status s = rocksdb::DB::Open(opt, db_path, &db);
  if (!s.ok()) {
    std::cerr << "Open: " << s.ToString() << "\n";
    return 1;
  }

  const std::string val(40, 'v');
  for (int i = 0; i < num_keys; ++i) {
    const uint32_t t = static_cast<uint32_t>(i % 1000);
    const float lon = -120.f + static_cast<float>((i % 200) * 0.01);
    const float lat = 35.f + static_cast<float>((i % 150) * 0.01);
    s = db->Put(rocksdb::WriteOptions(), StUserKey(t, lon, lat, static_cast<uint64_t>(i)),
                val);
    if (!s.ok()) {
      std::cerr << "Put: " << s.ToString() << "\n";
      return 1;
    }
  }
  s = db->Flush(rocksdb::FlushOptions());
  if (!s.ok()) {
    std::cerr << "Flush: " << s.ToString() << "\n";
    return 1;
  }

  rocksdb::SetPerfLevel(rocksdb::PerfLevel::kEnableTimeExceptForMutex);

  rocksdb::ReadOptions base;
  base.total_order_seek = true;
  base.fill_cache = false;

  rocksdb::get_perf_context()->Reset();
  int64_t count = 0;
  auto t0 = std::chrono::steady_clock::now();
  {
    std::unique_ptr<rocksdb::Iterator> it(db->NewIterator(base));
    for (it->SeekToFirst(); it->Valid(); it->Next()) {
      ++count;
    }
    if (!it->status().ok()) {
      std::cerr << "Iter: " << it->status().ToString() << "\n";
      return 1;
    }
  }
  auto t1 = std::chrono::steady_clock::now();
  const uint64_t br0 = rocksdb::get_perf_context()->block_read_count;
  const double us0 =
      std::chrono::duration<double, std::micro>(t1 - t0).count();

  rocksdb::ReadOptions prune = base;
  prune.experimental_st_prune_scan.enable = true;
  prune.experimental_st_prune_scan.t_min = prune_t_min;
  prune.experimental_st_prune_scan.t_max = prune_t_max;
  prune.experimental_st_prune_scan.x_min = prune_x_min;
  prune.experimental_st_prune_scan.x_max = prune_x_max;
  prune.experimental_st_prune_scan.y_min = prune_y_min;
  prune.experimental_st_prune_scan.y_max = prune_y_max;

  rocksdb::get_perf_context()->Reset();
  int64_t count2 = 0;
  auto t2 = std::chrono::steady_clock::now();
  {
    std::unique_ptr<rocksdb::Iterator> it(db->NewIterator(prune));
    for (it->SeekToFirst(); it->Valid(); it->Next()) {
      ++count2;
    }
    if (!it->status().ok()) {
      std::cerr << "Iter prune: " << it->status().ToString() << "\n";
      return 1;
    }
  }
  auto t3 = std::chrono::steady_clock::now();
  const uint64_t br1 = rocksdb::get_perf_context()->block_read_count;
  const double us1 =
      std::chrono::duration<double, std::micro>(t3 - t2).count();

  std::cout << "keys=" << num_keys << " full_scan_count=" << count
            << " prune_scan_count=" << count2 << "\n";
  std::cout << "OFF block_read_count=" << br0 << " time_us=" << us0 << "\n";
  std::cout << "ON  block_read_count=" << br1 << " time_us=" << us1 << "\n";
  if (br0 > 0) {
    std::cout << "block_read_ratio(prune/full)=" << (static_cast<double>(br1) / br0)
              << "\n";
  }
  if (count > 0) {
    std::cout << "key_selectivity(prune/full)=" << std::fixed << std::setprecision(6)
              << (static_cast<double>(count2) / static_cast<double>(count)) << "\n";
  }
  std::cout
      << "Note: prune_scan_count < full when entire blocks are skipped (expected).\n";
  std::cout
      << "Repeatability: same --db rebuild + same --num/--prune-* yields identical "
         "counts; sweep prune window or num_keys for a selectivity curve.\n";
  std::cout
      << "block_read_count is cache-sensitive; use time_us and key counts as primary "
         "effect metrics.\n";

  if (!log_path.empty()) {
    const double ratio =
        (br0 > 0) ? (static_cast<double>(br1) / static_cast<double>(br0)) : -1.0;
    const double sel =
        (count > 0) ? (static_cast<double>(count2) / static_cast<double>(count)) : 0.0;
    AppendCsvLog(log_path, NowTimestampForLog(), num_keys, count, count2, br0,
                  br1, us0, us1, ratio, prune_t_min, prune_t_max, prune_x_min,
                  prune_x_max, prune_y_min, prune_y_max, sel);
    std::cout << "Appended row to " << log_path << "\n";
  }
  return 0;
}
