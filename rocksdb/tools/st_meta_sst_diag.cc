//  Copyright (c) 2011-present, Facebook, Inc.  All rights reserved.
//  This source code is licensed under both the GPLv2 (found in the
//  COPYING file in the root directory) and Apache 2.0 License
//  (found in the LICENSE file in the root directory).
//
// Block-level: walk the block-based index, decode ST tails; optional prune
// window (same disjointness as ReadOptions::experimental_st_prune_scan).
// File-level: decode rocksdb.experimental.st_file_bounds from properties.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "rocksdb/env.h"
#include "rocksdb/options.h"
#include "rocksdb/table_properties.h"
#include "table/block_based/block_based_table_reader.h"
#include "table/format.h"
#include "table/index_value_codec.h"
#include "table/sst_file_dumper.h"
#include "table/st_meta_index_extension.h"

namespace ROCKSDB_NAMESPACE {

struct StMetaSstDiagStats {
  uint64_t index_entries = 0;
  uint64_t has_st_meta = 0;
  uint64_t no_st_meta = 0;
  uint64_t prune_disjoint = 0;
  uint64_t prune_intersect = 0;
  uint64_t prune_na_no_meta = 0;
};

// Friend of BlockBasedTable; implementation in this .cc only.
class StMetaSstDiag {
 public:
  static Status WalkIndex(
      BlockBasedTable* table, bool verify_checksum,
      const ReadOptions::ExperimentalSpatioTemporalPruneScan* prune_window,
      StMetaSstDiagStats* stats);
};

Status StMetaSstDiag::WalkIndex(
    BlockBasedTable* table, bool verify_checksum,
    const ReadOptions::ExperimentalSpatioTemporalPruneScan* prune_window,
    StMetaSstDiagStats* stats) {
  stats->index_entries = 0;
  stats->has_st_meta = 0;
  stats->no_st_meta = 0;
  stats->prune_disjoint = 0;
  stats->prune_intersect = 0;
  stats->prune_na_no_meta = 0;

  ReadOptions ro;
  ro.verify_checksums = verify_checksum;
  IndexBlockIter iiter_on_stack;
  BlockCacheLookupContext lookup_ctx{TableReaderCaller::kSSTDumpTool};
  InternalIteratorBase<IndexValue>* iiter = table->NewIndexIterator(
      ro, /*disable_prefix_seek=*/false, &iiter_on_stack,
      /*get_context=*/nullptr, &lookup_ctx);
  std::unique_ptr<InternalIteratorBase<IndexValue>> owned;
  if (iiter != &iiter_on_stack) {
    owned.reset(iiter);
  }
  if (!iiter->status().ok()) {
    return iiter->status();
  }

  for (iiter->SeekToFirst(); iiter->Valid(); iiter->Next()) {
    stats->index_entries++;
    const IndexValue& v = iiter->value();
    if (v.has_st_meta) {
      stats->has_st_meta++;
      if (prune_window && prune_window->enable) {
        const auto& m = v.st_meta;
        const auto& q = *prune_window;
        if (m.t_max < q.t_min || m.t_min > q.t_max || m.x_max < q.x_min ||
            m.x_min > q.x_max || m.y_max < q.y_min || m.y_min > q.y_max) {
          stats->prune_disjoint++;
        } else {
          stats->prune_intersect++;
        }
      }
    } else {
      stats->no_st_meta++;
      if (prune_window && prune_window->enable) {
        stats->prune_na_no_meta++;
      }
    }
  }
  return iiter->status();
}

}  // namespace ROCKSDB_NAMESPACE

namespace {

using ROCKSDB_NAMESPACE::BlockBasedTable;
using ROCKSDB_NAMESPACE::DecodeSpatioTemporalIndexTail;
using ROCKSDB_NAMESPACE::Env;
using ROCKSDB_NAMESPACE::kExperimentalStFileBoundsPropertyName;
using ROCKSDB_NAMESPACE::Options;
using ROCKSDB_NAMESPACE::ReadOptions;
using ROCKSDB_NAMESPACE::Slice;
using ROCKSDB_NAMESPACE::SpatioTemporalBlockMeta;
using ROCKSDB_NAMESPACE::SstFileDumper;
using ROCKSDB_NAMESPACE::Status;
using ROCKSDB_NAMESPACE::Temperature;
using ROCKSDB_NAMESPACE::StMetaSstDiag;
using ROCKSDB_NAMESPACE::StMetaSstDiagStats;

bool StMetaDisjointFromQuery(
    const SpatioTemporalBlockMeta& m,
    const ReadOptions::ExperimentalSpatioTemporalPruneScan& q) {
  return m.t_max < q.t_min || m.t_min > q.t_max || m.x_max < q.x_min ||
         m.x_min > q.x_max || m.y_max < q.y_min || m.y_min > q.y_max;
}

void PrintUsage(const char* argv0) {
  std::fprintf(stderr,
               "Usage: %s [options] <file.sst> [file2.sst ...]\n"
               "  (Built with RocksDB; run from build/tools/, e.g. "
               "D:\\Project\\rocksdb\\build\\tools\\st_meta_sst_diag.exe)\n"
               "  Block-level: walk native index, decode ST tails.\n"
               "  File-level: decode %s from table properties.\n"
               "Options:\n"
               "  --window T_MIN T_MAX X_MIN Y_MIN X_MAX Y_MAX\n"
               "           Count index entries pruned (disjoint) vs kept.\n"
               "  --verify-checksum   Verify SST checksums when opening.\n",
               argv0, kExperimentalStFileBoundsPropertyName());
}

bool ParseUint32(const char* s, uint32_t* out) {
  char* end = nullptr;
  unsigned long v = std::strtoul(s, &end, 10);
  if (end == s || *end != '\0' || v > 0xffffffffUL) {
    return false;
  }
  *out = static_cast<uint32_t>(v);
  return true;
}

bool ParseFloat(const char* s, float* out) {
  char* end = nullptr;
  double v = std::strtod(s, &end);
  if (end == s || *end != '\0') {
    return false;
  }
  *out = static_cast<float>(v);
  return true;
}

Status DiagnoseOneSst(const std::string& path, bool verify_checksum,
                      const ReadOptions::ExperimentalSpatioTemporalPruneScan*
                          prune_window) {
  Options options;
  options.env = Env::Default();

  SstFileDumper dumper(options, path, Temperature::kUnknown,
                       /*readahead_size=*/2 << 20, verify_checksum,
                       /*output_hex=*/false, /*decode_blob_index=*/false,
                       ROCKSDB_NAMESPACE::EnvOptions(), /*silent=*/true,
                       /*show_sequence_number_type=*/false);
  if (!dumper.getStatus().ok()) {
    return dumper.getStatus();
  }

  std::fprintf(stdout, "=== %s ===\n", path.c_str());

  ROCKSDB_NAMESPACE::TableProperties* raw_props = dumper.GetInitTableProperties();
  if (raw_props) {
    std::fprintf(stdout, "  num_data_blocks: %" PRIu64 "\n",
                 raw_props->num_data_blocks);
    auto it = raw_props->user_collected_properties.find(
        kExperimentalStFileBoundsPropertyName());
    if (it == raw_props->user_collected_properties.end()) {
      std::fprintf(stdout, "  file ST bounds property: (absent)\n");
    } else {
      Slice s(it->second);
      SpatioTemporalBlockMeta fm{};
      Status st = DecodeSpatioTemporalIndexTail(&s, &fm);
      if (!st.ok() || !s.empty()) {
        std::fprintf(stdout, "  file ST bounds property: decode error %s\n",
                     st.ToString().c_str());
      } else {
        std::fprintf(stdout,
                     "  file ST bounds: t[%" PRIu32 ", %" PRIu32
                     "] x[%.6g,%.6g] y[%.6g,%.6g] bitmap=%" PRIu64 "\n",
                     fm.t_min, fm.t_max, fm.x_min, fm.x_max, fm.y_min,
                     fm.y_max, fm.bitmap);
        if (prune_window && prune_window->enable) {
          bool disjoint = StMetaDisjointFromQuery(fm, *prune_window);
          std::fprintf(stdout, "  file vs query window: %s\n",
                       disjoint ? "DISJOINT (would skip whole file)"
                                : "INTERSECTS");
        }
      }
    }
  } else {
    std::fprintf(stdout, "  (no table properties)\n");
  }

  BlockBasedTable* table = dumper.GetBlockBasedTableOrNull();
  if (!table) {
    std::fprintf(stdout,
                 "  block-level: skip (not BlockBasedTable or null reader)\n\n");
    return Status::OK();
  }

  StMetaSstDiagStats stats;
  Status ist = StMetaSstDiag::WalkIndex(table, verify_checksum, prune_window,
                                        &stats);
  if (!ist.ok()) {
    std::fprintf(stdout, "  block-level: index walk error: %s\n\n",
                 ist.ToString().c_str());
    return ist;
  }

  std::fprintf(stdout,
               "  index entries (data blocks): %" PRIu64 "\n"
               "  with ST tail (has_st_meta): %" PRIu64 "\n"
               "  without ST tail: %" PRIu64 "\n",
               stats.index_entries, stats.has_st_meta, stats.no_st_meta);
  if (prune_window && prune_window->enable) {
    std::fprintf(stdout,
                 "  prune window: would skip (disjoint ST): %" PRIu64 "\n"
                 "                would keep (intersects): %" PRIu64 "\n"
                 "                no ST tail (not pruned by ST): %" PRIu64 "\n",
                 stats.prune_disjoint, stats.prune_intersect,
                 stats.prune_na_no_meta);
  }
  std::fprintf(stdout, "\n");
  return Status::OK();
}

}  // namespace

int main(int argc, char** argv) {
  bool verify_checksum = false;
  ReadOptions::ExperimentalSpatioTemporalPruneScan window{};
  bool have_window = false;

  std::vector<std::string> files;
  for (int i = 1; i < argc; i++) {
    if (std::strcmp(argv[i], "--help") == 0 ||
        std::strcmp(argv[i], "-h") == 0) {
      PrintUsage(argv[0]);
      return 0;
    }
    if (std::strcmp(argv[i], "--verify-checksum") == 0) {
      verify_checksum = true;
      continue;
    }
    if (std::strcmp(argv[i], "--window") == 0) {
      if (i + 6 >= argc) {
        std::fprintf(stderr, "--window needs 6 arguments\n");
        PrintUsage(argv[0]);
        return 2;
      }
      uint32_t tmin = 0, tmax = 0;
      float xmin = 0, ymin = 0, xmax = 0, ymax = 0;
      if (!ParseUint32(argv[++i], &tmin) || !ParseUint32(argv[++i], &tmax) ||
          !ParseFloat(argv[++i], &xmin) || !ParseFloat(argv[++i], &ymin) ||
          !ParseFloat(argv[++i], &xmax) || !ParseFloat(argv[++i], &ymax)) {
        std::fprintf(stderr, "Invalid --window values\n");
        return 2;
      }
      window.enable = true;
      window.t_min = tmin;
      window.t_max = tmax;
      window.x_min = xmin;
      window.y_min = ymin;
      window.x_max = xmax;
      window.y_max = ymax;
      have_window = true;
      continue;
    }
    if (argv[i][0] == '-') {
      std::fprintf(stderr, "Unknown option: %s\n", argv[i]);
      PrintUsage(argv[0]);
      return 2;
    }
    files.push_back(argv[i]);
  }

  if (files.empty()) {
    PrintUsage(argv[0]);
    return 2;
  }

  const ReadOptions::ExperimentalSpatioTemporalPruneScan* wptr =
      have_window ? &window : nullptr;
  for (const auto& f : files) {
    ROCKSDB_NAMESPACE::Status s =
        DiagnoseOneSst(f, verify_checksum, wptr);
    if (!s.ok()) {
      std::fprintf(stderr, "%s: %s\n", f.c_str(), s.ToString().c_str());
      return 1;
    }
  }
  return 0;
}
