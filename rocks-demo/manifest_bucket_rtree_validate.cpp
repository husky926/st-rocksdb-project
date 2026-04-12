// Synthetic validation for Manifest time-bucket + per-bucket 2D R-tree (file MBR).
// Mirrors docs/sst_and_manifest_plan.md §7.2–7.3: multi-bucket mount + FileNumber dedupe.
//
// Layers:
//   1) Correctness: indexed candidate set (deduped) == brute-force intersect(time × MBR).
//   2) Effectiveness: raw_hits (with duplicates before dedupe) vs |brute|.
//   3) Performance: wall time brute vs indexed query loop (single-threaded).
//
// Selectivity: use --query-time-max and --query-mbr-hw-max to shrink query windows
// so |brute| drops; index then skips whole buckets and often beats linear scan.
//
// Read-path model (--open-ns): baseline assumes file-level MBR is NOT in Manifest,
// so every time-intersecting SST must be OpenTable'd to discover spatial overlap.
// Indexed path assumes t+Mbr in Manifest: OpenTable only for files in the final
// intersecting set (same |result| as brute). Weighted time = CPU wall + opens*open_ns.
//
// Build: ninja manifest_bucket_rtree_validate (no RocksDB link required).

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace {

struct Rect {
  float min_lon = 0, max_lon = 0, min_lat = 0, max_lat = 0;
};

inline bool Intersects(const Rect& a, const Rect& b) {
  return a.min_lon <= b.max_lon && a.max_lon >= b.min_lon &&
         a.min_lat <= b.max_lat && a.max_lat >= b.min_lat;
}

inline Rect UnionBound(const Rect& a, const Rect& b) {
  return Rect{std::min(a.min_lon, b.min_lon), std::max(a.max_lon, b.max_lon),
              std::min(a.min_lat, b.min_lat), std::max(a.max_lat, b.max_lat)};
}

struct FileRec {
  uint64_t file_no = 0;
  uint32_t t_min = 0;
  uint32_t t_max = 0;
  Rect mbr{};
};

inline bool TimeIntersects(uint32_t a0, uint32_t a1, uint32_t b0, uint32_t b1) {
  return a0 <= b1 && a1 >= b0;
}

void BruteQuery(const std::vector<FileRec>& files, uint32_t q_t0, uint32_t q_t1,
                const Rect& q_mbr, std::unordered_set<uint64_t>* out,
                size_t* time_intersecting_files = nullptr) {
  out->clear();
  size_t time_hits = 0;
  for (const auto& f : files) {
    if (!TimeIntersects(f.t_min, f.t_max, q_t0, q_t1)) {
      continue;
    }
    ++time_hits;
    if (Intersects(f.mbr, q_mbr)) {
      out->insert(f.file_no);
    }
  }
  if (time_intersecting_files != nullptr) {
    *time_intersecting_files = time_hits;
  }
}

bool SameSet(const std::unordered_set<uint64_t>& a,
             const std::unordered_set<uint64_t>& b) {
  if (a.size() != b.size()) {
    return false;
  }
  for (uint64_t x : a) {
    if (b.count(x) == 0) {
      return false;
    }
  }
  return true;
}

// ---- Bulk-loaded R-tree (static), 2D AABB, leaf payload = file_no ----
constexpr int kMaxLeaf = 8;
// Buckets with this many rectangles or fewer use linear scan (less overhead).
constexpr size_t kLinearBucketMax = 32;

struct RNode {
  Rect cover{};
  std::vector<RNode> children;
  std::vector<std::pair<Rect, uint64_t>> leaves;  // non-empty iff leaf
  bool is_leaf = true;

  static RNode BuildLeaf(std::vector<std::pair<Rect, uint64_t>> items) {
    RNode n;
    n.is_leaf = true;
    n.leaves = std::move(items);
    n.cover = n.leaves[0].first;
    for (size_t i = 1; i < n.leaves.size(); ++i) {
      n.cover = UnionBound(n.cover, n.leaves[i].first);
    }
    return n;
  }

  static RNode BuildInternal(std::vector<RNode> ch) {
    RNode n;
    n.is_leaf = false;
    n.children = std::move(ch);
    n.cover = n.children[0].cover;
    for (size_t i = 1; i < n.children.size(); ++i) {
      n.cover = UnionBound(n.cover, n.children[i].cover);
    }
    return n;
  }

  static RNode BulkBuild(std::vector<std::pair<Rect, uint64_t>> items) {
    if (items.size() <= static_cast<size_t>(kMaxLeaf)) {
      return BuildLeaf(std::move(items));
    }
    std::sort(items.begin(), items.end(), [](const auto& x, const auto& y) {
      const float cx = (x.first.min_lon + x.first.max_lon) * 0.5f;
      const float cxl = (y.first.min_lon + y.first.max_lon) * 0.5f;
      return cx < cxl;
    });
    const size_t mid = items.size() / 2;
    std::vector<std::pair<Rect, uint64_t>> left(items.begin(),
                                                  items.begin() + mid);
    std::vector<std::pair<Rect, uint64_t>> right(items.begin() + mid,
                                                 items.end());
    std::vector<RNode> ch;
    ch.push_back(BulkBuild(std::move(left)));
    ch.push_back(BulkBuild(std::move(right)));
    return BuildInternal(std::move(ch));
  }

  void Query(const Rect& q, std::vector<uint64_t>* out) const {
    if (!Intersects(cover, q)) {
      return;
    }
    if (is_leaf) {
      for (const auto& e : leaves) {
        if (Intersects(e.first, q)) {
          out->push_back(e.second);
        }
      }
      return;
    }
    for (const auto& c : children) {
      c.Query(q, out);
    }
  }
};

inline uint32_t BucketOf(uint32_t t, uint32_t bucket_width) {
  return bucket_width ? t / bucket_width : 0u;
}

inline void BucketsForFile(uint32_t t_min, uint32_t t_max, uint32_t bucket_width,
                           std::vector<uint32_t>* buckets) {
  buckets->clear();
  if (bucket_width == 0) {
    buckets->push_back(0);
    return;
  }
  const uint32_t b0 = BucketOf(t_min, bucket_width);
  const uint32_t b1 = BucketOf(t_max, bucket_width);
  for (uint32_t b = b0; b <= b1; ++b) {
    buckets->push_back(b);
  }
}

struct BucketStorage {
  std::vector<std::pair<Rect, uint64_t>> linear;
  RNode tree{};
  bool use_tree = false;
};

// Per-bucket R-tree or linear scan; file may be inserted into multiple buckets (§7.2).
class TimeBucketRTreeIndex {
 public:
  explicit TimeBucketRTreeIndex(uint32_t time_bucket_width)
      : width_(time_bucket_width) {}

  void Rebuild(const std::vector<FileRec>& files) {
    files_ = &files;
    std::unordered_map<uint32_t, std::vector<std::pair<Rect, uint64_t>>> by_b;
    uint32_t max_b = 0;
    for (const auto& f : files) {
      std::vector<uint32_t> bs;
      BucketsForFile(f.t_min, f.t_max, width_, &bs);
      for (uint32_t b : bs) {
        by_b[b].push_back({f.mbr, f.file_no});
        max_b = (std::max)(max_b, b);
      }
    }
    buckets_.clear();
    buckets_.resize(static_cast<size_t>(max_b) + 1);
    for (auto& kv : by_b) {
      auto& vec = kv.second;
      if (vec.empty()) {
        continue;
      }
      const uint32_t bid = kv.first;
      auto up = std::make_unique<BucketStorage>();
      if (vec.size() <= kLinearBucketMax) {
        up->linear = std::move(vec);
        up->use_tree = false;
      } else {
        up->tree = RNode::BulkBuild(std::move(vec));
        up->use_tree = true;
      }
      buckets_[bid] = std::move(up);
    }
  }

  // raw_spatial_hits: spatial hits (with cross-bucket duplicates) before time refine.
  void Query(uint32_t q_t0, uint32_t q_t1, const Rect& q_mbr,
             std::unordered_set<uint64_t>* deduped,
             uint64_t* raw_spatial_hits) const {
    deduped->clear();
    *raw_spatial_hits = 0;
    if (width_ == 0 || files_ == nullptr || files_->empty() ||
        buckets_.empty()) {
      return;
    }
    const uint32_t b0 = BucketOf(q_t0, width_);
    const uint32_t b1 = BucketOf(q_t1, width_);
    thread_local std::vector<uint64_t> tmp;
    tmp.clear();
    for (uint32_t b = b0; b <= b1 && b < buckets_.size(); ++b) {
      const auto* bs = buckets_[b].get();
      if (bs == nullptr) {
        continue;
      }
      const size_t before = tmp.size();
      if (bs->use_tree) {
        bs->tree.Query(q_mbr, &tmp);
      } else {
        for (const auto& e : bs->linear) {
          if (Intersects(e.first, q_mbr)) {
            tmp.push_back(e.second);
          }
        }
      }
      *raw_spatial_hits += (tmp.size() - before);
    }
    for (uint64_t fn : tmp) {
      const FileRec& f = (*files_)[static_cast<size_t>(fn)];
      if (TimeIntersects(f.t_min, f.t_max, q_t0, q_t1)) {
        deduped->insert(fn);
      }
    }
  }

 private:
  uint32_t width_;
  const std::vector<FileRec>* files_ = nullptr;
  std::vector<std::unique_ptr<BucketStorage>> buckets_;
};

void Usage() {
  std::fprintf(stderr,
               "manifest_bucket_rtree_validate [--files N] [--queries Q] "
               "[--seed S] [--t-span T] [--bucket-width W]\n"
               "    [--query-time-max L] [--query-mbr-hw-max D] [--open-ns K] "
               "[--check-only]\n"
               "  Synthetic files: random MBR (lon ~ [-120,-60], lat ~ [20,60]), "
               "time in [0, t_span).\n"
               "  --query-time-max: max query time interval length (0=default wide).\n"
               "  --query-mbr-hw-max: max query MBR half-width in deg (0=default ~0.5-4.5).\n"
               "  --open-ns: simulated nanoseconds per OpenTable (0=print opens only).\n"
               "  Tight windows -> smaller |brute| -> index often faster.\n");
}

struct Args {
  int num_files = 5000;
  int num_queries = 2000;
  uint64_t seed = 1;
  uint32_t t_span = 100000;
  uint32_t bucket_width = 500;
  uint32_t query_time_max = 0;
  float query_mbr_hw_max = 0.f;
  uint64_t open_ns = 0;
  bool check_only = false;
};

// Returns true on success; false on error; sets *help_out if --help.
bool ParseArgs(int argc, char** argv, Args* a, bool* help_out) {
  *help_out = false;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--files") == 0 && i + 1 < argc) {
      a->num_files = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "--queries") == 0 && i + 1 < argc) {
      a->num_queries = std::atoi(argv[++i]);
    } else if (std::strcmp(argv[i], "--seed") == 0 && i + 1 < argc) {
      a->seed = static_cast<uint64_t>(std::strtoull(argv[++i], nullptr, 10));
    } else if (std::strcmp(argv[i], "--t-span") == 0 && i + 1 < argc) {
      a->t_span = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
    } else if (std::strcmp(argv[i], "--bucket-width") == 0 && i + 1 < argc) {
      a->bucket_width =
          static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
    } else if (std::strcmp(argv[i], "--query-time-max") == 0 && i + 1 < argc) {
      a->query_time_max =
          static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
    } else if (std::strcmp(argv[i], "--query-mbr-hw-max") == 0 && i + 1 < argc) {
      a->query_mbr_hw_max = std::strtof(argv[++i], nullptr);
    } else if (std::strcmp(argv[i], "--open-ns") == 0 && i + 1 < argc) {
      a->open_ns = std::strtoull(argv[++i], nullptr, 10);
    } else if (std::strcmp(argv[i], "--check-only") == 0) {
      a->check_only = true;
    } else if (std::strcmp(argv[i], "-h") == 0 ||
               std::strcmp(argv[i], "--help") == 0) {
      *help_out = true;
      return false;
    } else {
      std::fprintf(stderr, "Unknown arg: %s\n", argv[i]);
      Usage();
      return false;
    }
  }
  if (a->num_files < 10 || a->num_queries < 1 || a->t_span < 100 ||
      a->bucket_width == 0) {
    std::fprintf(stderr, "Invalid args (need files>=10, queries>=1, "
                         "t-span>=100, bucket-width>0).\n");
    return false;
  }
  if (a->query_mbr_hw_max < 0.f) {
    std::fprintf(stderr, "Invalid --query-mbr-hw-max.\n");
    return false;
  }
  if (a->open_ns > 100000000000ULL) {
    std::fprintf(stderr, "Invalid --open-ns (too large).\n");
    return false;
  }
  return true;
}

// LCG for determinism
struct Rng {
  explicit Rng(uint64_t s) : state_(s ? s : 1) {}
  uint32_t NextU32() {
    state_ = state_ * 6364136223846793005ULL + 1;
    return static_cast<uint32_t>(state_ >> 33);
  }
  float UnitF() {
    return (NextU32() & 0xffffff) / float(0x1000000);
  }

 private:
  uint64_t state_;
};

std::vector<FileRec> GenerateFiles(int n, uint32_t t_span, Rng* rng) {
  std::vector<FileRec> files;
  files.reserve(static_cast<size_t>(n));
  for (int i = 0; i < n; ++i) {
    FileRec f;
    f.file_no = static_cast<uint64_t>(i);
    const uint32_t t0 = rng->NextU32() % (t_span > 200 ? t_span - 100 : 1);
    const uint32_t len = 1 + (rng->NextU32() % 99);
    f.t_min = t0;
    f.t_max = std::min(t_span - 1, t0 + len);
    const float lon = -120.f + rng->UnitF() * 60.f;
    const float lat = 20.f + rng->UnitF() * 40.f;
    const float hw = 0.1f + rng->UnitF() * 2.f;
    f.mbr = Rect{lon - hw, lon + hw, lat - hw * 0.8f, lat + hw * 0.8f};
    files.push_back(f);
  }
  return files;
}

}  // namespace

int main(int argc, char** argv) {
  Args args;
  bool help = false;
  if (!ParseArgs(argc, argv, &args, &help)) {
    if (help) {
      Usage();
      return 0;
    }
    return 1;
  }

  Rng rng(args.seed);
  std::vector<FileRec> files = GenerateFiles(args.num_files, args.t_span, &rng);

  TimeBucketRTreeIndex index(args.bucket_width);
  const auto t_build0 = std::chrono::steady_clock::now();
  index.Rebuild(files);
  const auto t_build1 = std::chrono::steady_clock::now();
  const double build_ms =
      std::chrono::duration<double, std::milli>(t_build1 - t_build0).count();

  std::printf(
      "manifest_bucket_rtree_validate: files=%d queries=%d seed=%llu "
      "t_span=%u bucket_width=%u query_time_max=%u query_mbr_hw_max=%g open_ns=%llu\n",
      args.num_files, args.num_queries,
      static_cast<unsigned long long>(args.seed), args.t_span,
      args.bucket_width, args.query_time_max,
      static_cast<double>(args.query_mbr_hw_max),
      static_cast<unsigned long long>(args.open_ns));
  std::printf("index build time: %.3f ms\n", build_ms);

  uint64_t mismatch = 0;
  uint64_t sum_brute = 0;
  uint64_t sum_time_intersect = 0;
  uint64_t sum_raw_spatial = 0;
  uint64_t sum_dedup = 0;

  std::vector<uint32_t> q_t0(args.num_queries);
  std::vector<uint32_t> q_t1(args.num_queries);
  std::vector<Rect> q_mbr(static_cast<size_t>(args.num_queries));
  for (int q = 0; q < args.num_queries; ++q) {
    const uint32_t span_cap =
        args.t_span > 1 ? args.t_span - 1 : 1;
    const uint32_t a = rng.NextU32() % span_cap;
    uint32_t t0 = a;
    uint32_t t1;
    if (args.query_time_max > 0) {
      const uint32_t w = (std::max)(1u, args.query_time_max);
      const uint32_t extra = rng.NextU32() % w;
      t1 = t0 + extra;
      if (t1 >= args.t_span) {
        t1 = args.t_span - 1;
      }
      if (t1 < t0) {
        t1 = t0;
      }
    } else {
      const uint32_t b = a + 1 + (rng.NextU32() % (args.t_span / 4 + 1));
      t1 = std::min(args.t_span - 1, b);
    }
    q_t0[q] = t0;
    q_t1[q] = t1;

    const float lon = -120.f + rng.UnitF() * 50.f;
    const float lat = 25.f + rng.UnitF() * 30.f;
    float hw;
    if (args.query_mbr_hw_max > 0.f) {
      const float cap = args.query_mbr_hw_max;
      hw = 0.02f + rng.UnitF() * (cap - 0.02f);
      if (hw > cap) {
        hw = cap;
      }
      if (hw < 0.02f) {
        hw = 0.02f;
      }
    } else {
      hw = 0.5f + rng.UnitF() * 4.f;
    }
    q_mbr[static_cast<size_t>(q)] =
        Rect{lon - hw, lon + hw, lat - hw * 0.7f, lat + hw * 0.7f};
  }

  std::unordered_set<uint64_t> brute_out;
  brute_out.reserve(128);
  const auto t_b0 = std::chrono::steady_clock::now();
  for (int q = 0; q < args.num_queries; ++q) {
    size_t time_hits = 0;
    BruteQuery(files, q_t0[q], q_t1[q], q_mbr[static_cast<size_t>(q)],
               &brute_out, &time_hits);
    sum_brute += brute_out.size();
    sum_time_intersect += time_hits;
  }
  const auto t_b1 = std::chrono::steady_clock::now();

  std::unordered_set<uint64_t> dedup;
  dedup.reserve(128);
  const auto t_i0 = std::chrono::steady_clock::now();
  for (int q = 0; q < args.num_queries; ++q) {
    uint64_t raw_sp = 0;
    index.Query(q_t0[q], q_t1[q], q_mbr[static_cast<size_t>(q)], &dedup,
                 &raw_sp);
    sum_raw_spatial += raw_sp;
    sum_dedup += dedup.size();

    BruteQuery(files, q_t0[q], q_t1[q], q_mbr[static_cast<size_t>(q)],
               &brute_out, nullptr);
    if (!SameSet(dedup, brute_out)) {
      ++mismatch;
    }
  }
  const auto t_i1 = std::chrono::steady_clock::now();

  const double brute_ms =
      std::chrono::duration<double, std::milli>(t_b1 - t_b0).count();
  const double index_ms =
      std::chrono::duration<double, std::milli>(t_i1 - t_i0).count();

  const double avg_brute = sum_brute / double(args.num_queries);
  const double avg_time_intersect =
      sum_time_intersect / double(args.num_queries);
  const double avg_raw_sp = sum_raw_spatial / double(args.num_queries);
  const double avg_dedup = sum_dedup / double(args.num_queries);
  const double spatial_per_final =
      avg_dedup > 0 ? (avg_raw_sp / avg_dedup) : 1.0;
  const double opens_ratio =
      avg_brute > 0 ? (avg_time_intersect / avg_brute) : 1.0;

  std::printf("correctness: mismatched_queries=%llu (want 0)\n",
              static_cast<unsigned long long>(mismatch));
  std::printf(
      "avg |brute|=%.2f  spatial_candidates/query=%.2f  after_time_dedup=%.2f  "
      "spatial/final=%.3f (R-tree+MBR then time; includes multi-bucket dup)\n",
      avg_brute, avg_raw_sp, avg_dedup, spatial_per_final);
  std::printf(
      "read-path opens/query: brute=%.2f (time-intersecting files; no file MBR in "
      "manifest)  indexed=%.2f (|result|; manifest t+MBR)  "
      "brute/indexed_opens=%.2f\n",
      avg_time_intersect, avg_brute, opens_ratio);
  const double bi = index_ms > 0 ? brute_ms / index_ms : 0.0;
  std::printf(
      "query wall time: brute=%.3f ms  indexed=%.3f ms  brute/indexed=%.2f "
      "(>1 => indexed faster)\n",
      brute_ms, index_ms, bi);

  if (args.open_ns > 0) {
    const double open_ms_total_brute =
        (static_cast<double>(sum_time_intersect) *
         static_cast<double>(args.open_ns)) /
        1e6;
    const double open_ms_total_indexed =
        (static_cast<double>(sum_brute) * static_cast<double>(args.open_ns)) /
        1e6;
    const double w_brute_ms = brute_ms + open_ms_total_brute;
    const double w_index_ms = index_ms + open_ms_total_indexed;
    const double w_ratio = w_index_ms > 0 ? w_brute_ms / w_index_ms : 0.0;
    std::printf(
        "weighted read-path (CPU + opens*open_ns): open_ns=%llu  "
        "brute=%.3f ms  indexed=%.3f ms  weighted_brute/indexed=%.2f "
        "(>1 => indexed wins)\n",
        static_cast<unsigned long long>(args.open_ns), w_brute_ms, w_index_ms,
        w_ratio);
  }

  if (mismatch != 0) {
    return 2;
  }
  if (args.check_only) {
    return 0;
  }
  return 0;
}
