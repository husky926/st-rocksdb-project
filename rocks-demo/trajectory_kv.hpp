// Shared helpers for trajectory_validate and st_meta_smoke (same key/value layout).

#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace trajkv {

struct PointValue {
  int64_t unix_time_s{};
  double lon{};
  double lat{};
  double alt_m{};
};

inline constexpr size_t kPointValueBytes = 32;
static_assert(sizeof(PointValue) == kPointValueBytes, "packed point value");

inline std::vector<std::string> SplitCsvLine(const std::string& line) {
  std::vector<std::string> out;
  std::string cur;
  bool in_quote = false;
  for (size_t i = 0; i < line.size(); ++i) {
    const char c = line[i];
    if (in_quote) {
      if (c == '"') {
        if (i + 1 < line.size() && line[i + 1] == '"') {
          cur += '"';
          ++i;
        } else {
          in_quote = false;
        }
      } else {
        cur += c;
      }
    } else {
      if (c == '"') {
        in_quote = true;
      } else if (c == ',') {
        out.push_back(cur);
        cur.clear();
      } else {
        cur += c;
      }
    }
  }
  out.push_back(cur);
  return out;
}

inline std::string MakeKey(const std::string& segment_id, int point_index) {
  std::string k = segment_id;
  k.push_back('\0');
  const auto u = static_cast<uint32_t>(point_index);
  k.push_back(static_cast<char>((u >> 24) & 0xff));
  k.push_back(static_cast<char>((u >> 16) & 0xff));
  k.push_back(static_cast<char>((u >> 8) & 0xff));
  k.push_back(static_cast<char>(u & 0xff));
  return k;
}

inline std::string EncodeValue(const PointValue& v) {
  std::string s(sizeof(PointValue), '\0');
  std::memcpy(s.data(), &v, sizeof(v));
  return s;
}

inline bool DecodeValue(const std::string& blob, PointValue* out) {
  if (blob.size() != sizeof(PointValue)) {
    return false;
  }
  std::memcpy(out, blob.data(), sizeof(PointValue));
  return true;
}

}  // namespace trajkv
