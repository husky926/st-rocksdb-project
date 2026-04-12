cmake_minimum_required(VERSION 3.20)
project(rocks_demo LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Match a typical Release-built rocksdb.lib: same CRT (/MD vs /MDd) and build type.
if(NOT CMAKE_CONFIGURATION_TYPES)
  if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "rocks-demo build type" FORCE)
  endif()
  message(STATUS "rocks-demo CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}")
  if(MSVC AND CMAKE_BUILD_TYPE STREQUAL "Debug")
    message(WARNING
      "rocks-demo is Debug (/MDd) but rocksdb.lib is often built Release (/MD). "
      "DB::Open can crash at runtime. Reconfigure with: "
      "cmake .. -DCMAKE_BUILD_TYPE=Release")
  endif()
endif()

if(MSVC)
  add_compile_options(/utf-8 /EHsc)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
  # Ninja + cl without vcvars: INCLUDE is empty. Add SDK (crtdbg.h in ucrt) + MSVC STL.
  # Do not use include_directories(SYSTEM): CMake maps that to /external:I and breaks yvals.h -> crtdbg.h.
  if(CMAKE_CXX_COMPILER)
    set(_rocks_novc_inc "")
    set(_w_ucrt "")
    set(_w_um "")
    set(_w_sh "")
    # $ENV{ProgramFiles(x86)} is invalid CMake syntax (parentheses). Resolve x86 Program Files once.
    set(_rocks_pf86 "")
    if(CMAKE_HOST_WIN32)
      execute_process(
        COMMAND powershell -NoProfile -Command "[Environment]::GetFolderPath('ProgramFilesX86')"
        OUTPUT_VARIABLE _rocks_pf86
        OUTPUT_STRIP_TRAILING_WHITESPACE)
      string(STRIP "${_rocks_pf86}" _rocks_pf86)
    endif()
    if("${_rocks_pf86}" STREQUAL "")
      set(_rocks_pf86 "C:/Program Files (x86)")
    endif()
    cmake_path(CONVERT "${_rocks_pf86}" TO_CMAKE_PATH_LIST _rocks_pf86 NORMALIZE)

    if(DEFINED ENV{WindowsSdkDir} AND DEFINED ENV{WindowsSDKVersion})
      cmake_path(CONVERT "$ENV{WindowsSdkDir}" TO_CMAKE_PATH_LIST _wsd NORMALIZE)
      string(STRIP "$ENV{WindowsSDKVersion}" _wsv)
      string(REGEX REPLACE "[\\/]+$" "" _wsv "${_wsv}")
      set(_w_ucrt "${_wsd}/Include/${_wsv}/ucrt")
      set(_w_um "${_wsd}/Include/${_wsv}/um")
      set(_w_sh "${_wsd}/Include/${_wsv}/shared")
    endif()

    if(NOT EXISTS "${_w_ucrt}/crtdbg.h")
      set(_plat "${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}")
      if(NOT "${_plat}" STREQUAL "")
        foreach(
          _kits_root IN
          ITEMS
            "${_rocks_pf86}/Windows Kits/10/Include"
            "C:/Program Files (x86)/Windows Kits/10/Include"
            "$ENV{ProgramFiles}/Windows Kits/10/Include"
            "C:/Program Files/Windows Kits/10/Include")
          cmake_path(CONVERT "${_kits_root}" TO_CMAKE_PATH_LIST _kr NORMALIZE)
          if(EXISTS "${_kr}/${_plat}/ucrt/crtdbg.h")
            set(_w_ucrt "${_kr}/${_plat}/ucrt")
            set(_w_um "${_kr}/${_plat}/um")
            set(_w_sh "${_kr}/${_plat}/shared")
            break()
          endif()
        endforeach()
      endif()
    endif()

    if(NOT EXISTS "${_w_ucrt}/crtdbg.h")
      foreach(
        _kits_root IN
        ITEMS
          "${_rocks_pf86}/Windows Kits/10/Include"
          "C:/Program Files (x86)/Windows Kits/10/Include"
          "$ENV{ProgramFiles}/Windows Kits/10/Include"
          "C:/Program Files/Windows Kits/10/Include")
        cmake_path(CONVERT "${_kits_root}" TO_CMAKE_PATH_LIST _kr NORMALIZE)
        if(NOT EXISTS "${_kr}")
          continue()
        endif()
        file(GLOB _sdk_vers RELATIVE "${_kr}" "${_kr}/*")
        list(FILTER _sdk_vers INCLUDE REGEX "^[0-9]+\\.[0-9]+\\.[0-9]+")
        list(SORT _sdk_vers COMPARE NATURAL ORDER DESCENDING)
        foreach(_v IN LISTS _sdk_vers)
          if(EXISTS "${_kr}/${_v}/ucrt/crtdbg.h")
            set(_w_ucrt "${_kr}/${_v}/ucrt")
            set(_w_um "${_kr}/${_v}/um")
            set(_w_sh "${_kr}/${_v}/shared")
            break()
          endif()
        endforeach()
        if(EXISTS "${_w_ucrt}/crtdbg.h")
          break()
        endif()
      endforeach()
    endif()

    if(EXISTS "${_w_ucrt}/crtdbg.h")
      list(APPEND _rocks_novc_inc "${_w_ucrt}")
    endif()
    if(EXISTS "${_w_um}")
      list(APPEND _rocks_novc_inc "${_w_um}")
    endif()
    if(EXISTS "${_w_sh}")
      list(APPEND _rocks_novc_inc "${_w_sh}")
    endif()

    get_filename_component(_msvc_walk "${CMAKE_CXX_COMPILER}" DIRECTORY)
    set(_msvc_stl "")
    foreach(_i RANGE 12)
      if(EXISTS "${_msvc_walk}/include/chrono")
        set(_msvc_stl "${_msvc_walk}/include")
        break()
      endif()
      get_filename_component(_msvc_next "${_msvc_walk}" DIRECTORY)
      if(_msvc_next STREQUAL _msvc_walk)
        break()
      endif()
      set(_msvc_walk "${_msvc_next}")
    endforeach()
    if(NOT "${_msvc_stl}" STREQUAL "")
      list(APPEND _rocks_novc_inc "${_msvc_stl}")
    endif()

    if(_rocks_novc_inc)
      include_directories(${_rocks_novc_inc})
      message(STATUS "rocks-demo: MSVC+SDK includes for Ninja (no vcvars): ${_rocks_novc_inc}")
    endif()

    # Ninja without vcvars: LIB may be empty -> LNK1181/LNK1104 (shlwapi.lib in um\x64; ucrt.lib in ucrt\x64).
    set(_rocks_link_dirs "")
    if(EXISTS "${_w_ucrt}/crtdbg.h")
      get_filename_component(_rocks_sdk_ver_dir "${_w_ucrt}" DIRECTORY)
      get_filename_component(_rocks_winsdk_ver "${_rocks_sdk_ver_dir}" NAME)
      get_filename_component(_rocks_include_root "${_rocks_sdk_ver_dir}" DIRECTORY)
      get_filename_component(_rocks_winkit10 "${_rocks_include_root}" DIRECTORY)
      set(_rocks_ucrt_lib "${_rocks_winkit10}/Lib/${_rocks_winsdk_ver}/ucrt/x64")
      set(_rocks_um_lib "${_rocks_winkit10}/Lib/${_rocks_winsdk_ver}/um/x64")
      if(EXISTS "${_rocks_ucrt_lib}/ucrt.lib")
        list(APPEND _rocks_link_dirs "${_rocks_ucrt_lib}")
      endif()
      if(EXISTS "${_rocks_um_lib}/shlwapi.lib")
        list(APPEND _rocks_link_dirs "${_rocks_um_lib}")
      endif()
    endif()
    get_filename_component(_lib_walk "${CMAKE_CXX_COMPILER}" DIRECTORY)
    foreach(_li RANGE 18)
      set(_rocks_vc_lib_x64 "${_lib_walk}/lib/x64")
      if(EXISTS "${_rocks_vc_lib_x64}/vcruntime.lib" OR EXISTS "${_rocks_vc_lib_x64}/msvcrt.lib")
        list(APPEND _rocks_link_dirs "${_rocks_vc_lib_x64}")
        break()
      endif()
      get_filename_component(_lib_next "${_lib_walk}" DIRECTORY)
      if(_lib_next STREQUAL _lib_walk)
        break()
      endif()
      set(_lib_walk "${_lib_next}")
    endforeach()
    if(_rocks_link_dirs)
      link_directories(BEFORE ${_rocks_link_dirs})
      message(STATUS "rocks-demo: lib dirs for Ninja (no vcvars): ${_rocks_link_dirs}")
    endif()
  endif()
endif()

# Patched RocksDB next to this repo (not vcpkg). Build first:
#   cd ../rocksdb/build && cmake -G Ninja ... && ninja rocksdb
get_filename_component(PROJECT_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
set(ROCKSDB_ROOT "${PROJECT_ROOT}/rocksdb" CACHE PATH "RocksDB source tree")
set(ROCKSDB_BUILD "${ROCKSDB_ROOT}/build" CACHE PATH "RocksDB CMake build dir (contains rocksdb.lib)")
set(ROCKSDB_LIB "${ROCKSDB_BUILD}/rocksdb.lib")

if(NOT EXISTS "${ROCKSDB_LIB}")
  message(FATAL_ERROR
    "Missing ${ROCKSDB_LIB}. From MSVC x64 Native Tools or after vcvars64:\n"
    "  cd \"${ROCKSDB_BUILD}\" && cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=/utf-8 -DCMAKE_C_FLAGS=/utf-8 .. && ninja rocksdb")
endif()

message(STATUS
  "rocks-demo: link ${ROCKSDB_LIB}. RocksDB's CMake defaults to **Debug** when "
  ".git exists and CMAKE_BUILD_TYPE was unset — that yields a Debug rocksdb.lib. "
  "You must use the **same** CMAKE_BUILD_TYPE for rocksdb and rocks-demo or "
  "DB::Open may crash. Example (Release both):\n"
  "  cd \"${ROCKSDB_BUILD}\" && cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .. && ninja rocksdb")

set(VANILLA_ROCKSDB_ROOT "${PROJECT_ROOT}/rocksdb_vanilla" CACHE PATH "Upstream RocksDB tree (official sources)")
set(VANILLA_ROCKSDB_BUILD "${VANILLA_ROCKSDB_ROOT}/build" CACHE PATH "Upstream RocksDB build directory")
set(VANILLA_ROCKSDB_LIB "${VANILLA_ROCKSDB_BUILD}/rocksdb.lib")
# VS multi-config puts import lib under build/Release/rocksdb.lib
set(VANILLA_ROCKSDB_LIB_VS "${VANILLA_ROCKSDB_BUILD}/Release/rocksdb.lib")
option(VANILLA_STANDIN_LINK_FORK_LIB
  "Build st_segment_window_scan_vanilla with ../rocksdb when upstream rocksdb_vanilla lib missing (FORK — not official upstream; offline/smoke only)"
  OFF)

set(_vanilla_lib "")
set(_vanilla_inc "")
set(_vanilla_stand_in FALSE)
if(EXISTS "${VANILLA_ROCKSDB_LIB}")
  set(_vanilla_lib "${VANILLA_ROCKSDB_LIB}")
  set(_vanilla_inc "${VANILLA_ROCKSDB_ROOT}/include")
elseif(EXISTS "${VANILLA_ROCKSDB_LIB_VS}")
  set(_vanilla_lib "${VANILLA_ROCKSDB_LIB_VS}")
  set(_vanilla_inc "${VANILLA_ROCKSDB_ROOT}/include")
elseif(VANILLA_STANDIN_LINK_FORK_LIB AND EXISTS "${ROCKSDB_LIB}")
  set(_vanilla_lib "${ROCKSDB_LIB}")
  set(_vanilla_inc "${ROCKSDB_ROOT}/include")
  set(_vanilla_stand_in TRUE)
  message(WARNING
    "st_segment_window_scan_vanilla will link PROJECT FORK ${ROCKSDB_LIB} (VANILLA_STANDIN_LINK_FORK_LIB=ON). "
    "This is NOT upstream facebook/rocksdb — use only for offline pipeline / until clone works.")
endif()

if(_vanilla_lib)
  add_executable(st_segment_window_scan_vanilla st_segment_window_scan_vanilla.cpp)
  target_include_directories(st_segment_window_scan_vanilla PRIVATE "${_vanilla_inc}")
  target_link_libraries(st_segment_window_scan_vanilla PRIVATE
    "${_vanilla_lib}"
    shlwapi
    rpcrt4)
  if(_vanilla_stand_in)
    target_compile_definitions(st_segment_window_scan_vanilla PRIVATE VANILLA_BENCH_LINKED_FORK_LIB=1)
  endif()
  message(STATUS "rocks-demo: st_segment_window_scan_vanilla -> ${_vanilla_lib}")
else()
  message(STATUS
    "rocks-demo: no upstream rocksdb_vanilla lib (and VANILLA_STANDIN_LINK_FORK_LIB=OFF) — st_segment_window_scan_vanilla skipped. "
    "See tools/bootstrap_rocksdb_vanilla.ps1 or cmake -DVANILLA_STANDIN_LINK_FORK_LIB=ON")
endif()

# Fork-only: dump KV stream for Phase-1 vanilla replica (see docs/VANILLA_ROCKSDB_BASELINE.md).
add_executable(st_fork_kv_stream_dump st_fork_kv_stream_dump.cpp)
target_include_directories(st_fork_kv_stream_dump PRIVATE "${ROCKSDB_ROOT}/include")
target_link_libraries(st_fork_kv_stream_dump PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)
message(STATUS "rocks-demo: st_fork_kv_stream_dump (fork)")

# Upstream-only: ingest dump into a new DB with plain SSTs (real Vanilla-readable paths).
if(EXISTS "${VANILLA_ROCKSDB_LIB}" OR EXISTS "${VANILLA_ROCKSDB_LIB_VS}")
  if(EXISTS "${VANILLA_ROCKSDB_LIB}")
    set(_VANILLA_INGEST_LIB "${VANILLA_ROCKSDB_LIB}")
  else()
    set(_VANILLA_INGEST_LIB "${VANILLA_ROCKSDB_LIB_VS}")
  endif()
  add_executable(st_vanilla_kv_stream_ingest st_vanilla_kv_stream_ingest.cpp)
  target_include_directories(st_vanilla_kv_stream_ingest PRIVATE "${VANILLA_ROCKSDB_ROOT}/include")
  target_link_libraries(st_vanilla_kv_stream_ingest PRIVATE
    "${_VANILLA_INGEST_LIB}"
    shlwapi
    rpcrt4)
  message(STATUS "rocks-demo: st_vanilla_kv_stream_ingest -> ${_VANILLA_INGEST_LIB}")
else()
  message(STATUS "rocks-demo: st_vanilla_kv_stream_ingest skipped (no rocksdb_vanilla build)")
endif()

add_executable(rocks_demo main.cpp)
target_include_directories(rocks_demo PRIVATE "${ROCKSDB_ROOT}/include")
target_link_libraries(rocks_demo PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

add_executable(trajectory_validate trajectory_validate.cpp)
target_include_directories(trajectory_validate PRIVATE "${ROCKSDB_ROOT}/include")
target_link_libraries(trajectory_validate PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

add_executable(st_meta_smoke st_meta_smoke.cpp)
target_include_directories(st_meta_smoke PRIVATE "${ROCKSDB_ROOT}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(st_meta_smoke PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

add_executable(st_meta_bench st_meta_bench.cpp)
target_include_directories(st_meta_bench PRIVATE "${ROCKSDB_ROOT}/include")
target_link_libraries(st_meta_bench PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

add_executable(st_meta_scan_bench st_meta_scan_bench.cpp)
target_include_directories(st_meta_scan_bench PRIVATE "${ROCKSDB_ROOT}/include")
target_link_libraries(st_meta_scan_bench PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

# Real read IO / PerfContext on an existing ST-key DB (no rebuild).
add_executable(st_meta_read_bench st_meta_read_bench.cpp)
target_include_directories(st_meta_read_bench PRIVATE "${ROCKSDB_ROOT}/include"
  "${ROCKSDB_ROOT}")
target_link_libraries(st_meta_read_bench PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

add_executable(traj_db_audit traj_db_audit.cpp)
target_include_directories(traj_db_audit PRIVATE "${ROCKSDB_ROOT}/include")
target_link_libraries(traj_db_audit PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

add_executable(st_meta_compact_existing st_meta_compact_existing.cpp)
target_include_directories(st_meta_compact_existing PRIVATE "${ROCKSDB_ROOT}/include")
target_link_libraries(st_meta_compact_existing PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

# Synthetic Manifest §7.2: time-bucket + per-bucket R-tree vs brute (no RocksDB).
add_executable(manifest_bucket_rtree_validate manifest_bucket_rtree_validate.cpp)

add_executable(st_meta_compaction_verify st_meta_compaction_verify.cpp)
target_include_directories(st_meta_compaction_verify PRIVATE "${ROCKSDB_ROOT}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}")
if(CMAKE_BUILD_TYPE)
  # Passed as -DROCKS_DEMO_BT=Release so we can stringify it in the tool.
  target_compile_definitions(st_meta_compaction_verify PRIVATE
    ROCKS_DEMO_BT=${CMAKE_BUILD_TYPE})
endif()
target_link_libraries(st_meta_compaction_verify PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)

add_executable(st_bucket_ingest_build st_bucket_ingest_build.cpp)
target_include_directories(st_bucket_ingest_build PRIVATE "${ROCKSDB_ROOT}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(st_bucket_ingest_build PRIVATE
  "${ROCKSDB_LIB}"
  shlwapi
  rpcrt4)
