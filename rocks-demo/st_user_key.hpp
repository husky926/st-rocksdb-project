// Shared 21-byte ST user key (magic 0xE5 + t_sec LE + lon/lat floats LE + id LE).
// Same layout as st_meta_compaction_verify / table/st_meta_user_key.h.

#pragma once

#include <cstdint>
#include <cstring>
#include <string>

inline std::string StUserKey(uint32_t t_sec, float lon, float lat, uint64_t id) {
  std::string k(21, '\0');
  k[0] = static_cast<char>(0xE5);
  std::memcpy(&k[1], &t_sec, 4);
  std::memcpy(&k[5], &lon, 4);
  std::memcpy(&k[9], &lat, 4);
  std::memcpy(&k[13], &id, 8);
  return k;
}
