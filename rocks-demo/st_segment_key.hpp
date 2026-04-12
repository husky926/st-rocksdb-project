// Shared segment-level ST user key:
// [0] 0xE6 + [1:5) t_start + [5:9) t_end + [9:13) x_min + [13:17) y_min +
// [17:21) x_max + [21:25) y_max + [25:33) id

#pragma once

#include <cstdint>
#include <cstring>
#include <string>

inline std::string StSegmentKey(uint32_t t_start, uint32_t t_end, float x_min,
                                float y_min, float x_max, float y_max,
                                uint64_t id) {
  std::string k(33, '\0');
  k[0] = static_cast<char>(0xE6);
  std::memcpy(&k[1], &t_start, 4);
  std::memcpy(&k[5], &t_end, 4);
  std::memcpy(&k[9], &x_min, 4);
  std::memcpy(&k[13], &y_min, 4);
  std::memcpy(&k[17], &x_max, 4);
  std::memcpy(&k[21], &y_max, 4);
  std::memcpy(&k[25], &id, 8);
  return k;
}

