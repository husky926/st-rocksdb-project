// SPDX-License-Identifier: Apache-2.0
//
// Extended layout when appended after a standard IndexValue encoding:
//   [ existing IndexValue encoding ]
//   [ uint32 LE T_min ][ uint32 LE T_max ]
//   [ float32 LE x_min ][ y_min ][ x_max ][ y_max ][ uint64 LE bitmap ]

#pragma once

#include <string>

#include "rocksdb/slice.h"
#include "rocksdb/status.h"
#include "table/st_meta_index_extension.h"

namespace ROCKSDB_NAMESPACE {

class BlockHandle;

// Full value = BlockHandle encoding + tail (legacy helper / tests).
Status EncodeSpatioTemporalIndexValue(std::string* dst, const BlockHandle& handle,
                                      const SpatioTemporalBlockMeta& meta);

Status DecodeSpatioTemporalIndexValue(Slice* input, BlockHandle* handle,
                                      SpatioTemporalBlockMeta* meta);

// Append / decode only the fixed tail (after IndexValue bytes).
void AppendSpatioTemporalIndexTail(std::string* dst,
                                   const SpatioTemporalBlockMeta& meta);
Status DecodeSpatioTemporalIndexTail(Slice* input,
                                     SpatioTemporalBlockMeta* meta);

}  // namespace ROCKSDB_NAMESPACE
