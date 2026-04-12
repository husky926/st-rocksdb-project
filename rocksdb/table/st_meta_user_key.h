// SPDX-License-Identifier: Apache-2.0
// User-key prefix encoding for SpatioTemporalBlockMeta aggregation (experimental).

#pragma once

#include <cstdint>

#include "rocksdb/options.h"
#include "rocksdb/slice.h"
#include "table/st_meta_index_extension.h"

namespace ROCKSDB_NAMESPACE {

// User key layout (little-endian), minimum length 13 + N:
//   [0]     magic 0xE5
//   [1:5)   uint32_t t_sec   (application-defined epoch seconds or bucket)
//   [5:9)   float x          (e.g. longitude)
//   [9:13)  float y          (e.g. latitude)
//   [13:..) opaque suffix     (uniqueness; not parsed here)
//
// Keys without this prefix are ignored for st-meta aggregation.

constexpr unsigned char kSpatioTemporalUserKeyMagic = 0xE5;
constexpr unsigned char kSpatioTemporalSegmentKeyMagic = 0xE6;

// Merges one user key into per-data-block accumulator (same semantics as
// widening t/MBR and OR-ing a coarse 8x8 world-grid bit in bitmap).
void MergeSpatioTemporalMetaFromUserKey(const Slice& user_key,
                                        SpatioTemporalBlockMeta* acc,
                                        bool* acc_valid);

// Decodes Event Time `t_sec` from a spatio-temporal user key (magic 0xE5).
// Returns false if the key is too short or not an ST user key.
bool TryDecodeSpatioTemporalUserKeyTime(const Slice& user_key, uint32_t* t_sec);

// True if the key decodes as an ST user key and its (t,x,y) point is
// axis-disjoint from the prune window (same test as block/file MBR vs window).
// False if not an ST key or if the point intersects the window (caller keeps key).
bool UserKeySpatioTemporalDisjointFromPruneScan(
    const Slice& user_key,
    const ReadOptions::ExperimentalSpatioTemporalPruneScan& q);

// True iff the key is a valid ST user key (magic 0xE5, decodable t,x,y) and the
// point lies inside the axis-aligned window [t_min,t_max]×[x_min,x_max]×[y_min,y_max].
// Used for brute-force baselines that scan the CF but count only query answers.
bool UserKeySpatioTemporalInWindow(const Slice& user_key, uint32_t t_min,
                                   uint32_t t_max, float x_min, float x_max,
                                   float y_min, float y_max);

// Union of per-data-block SpatioTemporal summaries into whole-file bounds for
// Manifest (min/max t, MBR union, bitmap OR). *acc_valid false => copy block.
void UnionSpatioTemporalBlockMeta(SpatioTemporalBlockMeta* acc, bool* acc_valid,
                                  const SpatioTemporalBlockMeta& block);

}  // namespace ROCKSDB_NAMESPACE
