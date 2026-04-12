// Segment KV value layout for --st-segment-keys ingest (st_meta_smoke, st_bucket_ingest_build).
// V2 (required for new ingests): magic + fixed header + packed points (t, lon, lat per point).
// Legacy (28 bytes, no magic): header only — still decoded for old DBs.

#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

#include "trajectory_kv.hpp"

namespace segval {

static constexpr uint32_t kSegmentValueMagicV2 = 0x32676553;  // bytes 'S','e','g','2'

#pragma pack(push, 1)
struct SegmentValueHeader {
  uint32_t t_start = 0;
  uint32_t t_end = 0;
  float x_min = 0.f;
  float y_min = 0.f;
  float x_max = 0.f;
  float y_max = 0.f;
  uint32_t point_count = 0;
};
#pragma pack(pop)

static_assert(sizeof(SegmentValueHeader) == 28, "segment header size");

struct SegmentPoint {
  uint32_t unix_s = 0;
  float lon = 0.f;
  float lat = 0.f;
};

inline std::string EncodeSegmentValueV2(const SegmentValueHeader& head,
                                       const std::vector<SegmentPoint>& points) {
  if (points.size() != static_cast<size_t>(head.point_count)) {
    return {};
  }
  std::string out;
  out.resize(4 + sizeof(SegmentValueHeader) + points.size() * 12);
  std::memcpy(out.data(), &kSegmentValueMagicV2, 4);
  std::memcpy(out.data() + 4, &head, sizeof(head));
  size_t off = 4 + sizeof(head);
  for (const auto& p : points) {
    std::memcpy(out.data() + off, &p.unix_s, 4);
    std::memcpy(out.data() + off + 4, &p.lon, 4);
    std::memcpy(out.data() + off + 8, &p.lat, 4);
    off += 12;
  }
  return out;
}

struct DecodedSegmentValue {
  SegmentValueHeader header{};
  std::vector<SegmentPoint> points;
  bool is_legacy = false;
};

inline bool DecodeSegmentValue(const std::string& blob, DecodedSegmentValue* out) {
  if (out == nullptr) {
    return false;
  }
  out->points.clear();
  out->is_legacy = false;
  if (blob.size() == sizeof(SegmentValueHeader)) {
    std::memcpy(&out->header, blob.data(), sizeof(SegmentValueHeader));
    out->is_legacy = true;
    return true;
  }
  if (blob.size() < 4 + sizeof(SegmentValueHeader)) {
    return false;
  }
  uint32_t magic = 0;
  std::memcpy(&magic, blob.data(), 4);
  if (magic != kSegmentValueMagicV2) {
    return false;
  }
  std::memcpy(&out->header, blob.data() + 4, sizeof(SegmentValueHeader));
  const size_t expected =
      4 + sizeof(SegmentValueHeader) +
      static_cast<size_t>(out->header.point_count) * 12;
  if (blob.size() != expected) {
    return false;
  }
  out->points.resize(out->header.point_count);
  size_t off = 4 + sizeof(SegmentValueHeader);
  for (uint32_t i = 0; i < out->header.point_count; ++i) {
    std::memcpy(&out->points[i].unix_s, blob.data() + off, 4);
    std::memcpy(&out->points[i].lon, blob.data() + off + 4, 4);
    std::memcpy(&out->points[i].lat, blob.data() + off + 8, 4);
    off += 12;
  }
  out->is_legacy = false;
  return true;
}

// segments_points.csv: segment_id, dataset, point_index, unix_time_s, lon, lat, ...
// Points per segment ordered by point_index.
inline bool LoadSegmentPointsCsv(
    const std::string& path,
    std::unordered_map<std::string, std::vector<SegmentPoint>>* by_segment) {
  if (by_segment == nullptr) {
    return false;
  }
  by_segment->clear();
  std::ifstream in(path);
  if (!in) {
    std::cerr << "Cannot open segment points CSV: " << path << "\n";
    return false;
  }
  std::string header;
  if (!std::getline(in, header)) {
    std::cerr << "Empty segment points CSV.\n";
    return false;
  }
  std::unordered_map<std::string, std::map<int, SegmentPoint>> indexed;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) {
      continue;
    }
    auto f = trajkv::SplitCsvLine(line);
    if (f.size() < 6) {
      std::cerr << "Bad row in segment points CSV (need >= 6 fields)\n";
      return false;
    }
    const std::string& segment_id = f[0];
    const int point_index = std::stoi(f[2]);
    SegmentPoint p{};
    p.unix_s = static_cast<uint32_t>(std::stoul(f[3]));
    p.lon = static_cast<float>(std::stod(f[4]));
    p.lat = static_cast<float>(std::stod(f[5]));
    indexed[segment_id][point_index] = p;
  }
  for (auto& kv : indexed) {
    std::vector<SegmentPoint> vec;
    vec.reserve(kv.second.size());
    for (const auto& pr : kv.second) {
      vec.push_back(pr.second);
    }
    (*by_segment)[std::move(kv.first)] = std::move(vec);
  }
  return true;
}

}  // namespace segval
