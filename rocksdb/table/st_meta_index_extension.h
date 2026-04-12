// SPDX-License-Identifier: Apache-2.0
// Spatio-temporal summary embedded after standard IndexValue bytes (experimental).

#pragma once

#include <cstddef>
#include <cstdint>

namespace ROCKSDB_NAMESPACE {

struct SpatioTemporalBlockMeta {
  uint32_t t_min = 0;
  uint32_t t_max = 0;
  float x_min = 0.f;
  float y_min = 0.f;
  float x_max = 0.f;
  float y_max = 0.f;
  uint64_t bitmap = 0;
};

constexpr size_t kSpatioTemporalIndexTailBytes() {
  return sizeof(uint32_t) * 2 + sizeof(float) * 4 + sizeof(uint64_t);
}

// User property written to SST property block; flushed into MANIFEST via
// FileMetaData (experimental).
inline const char* kExperimentalStFileBoundsPropertyName() {
  return "rocksdb.experimental.st_file_bounds";
}

}  // namespace ROCKSDB_NAMESPACE
