# Builds libtorrent and Bluebox's Objective-C++ wrapper (BBTorrent.mm) as
# static libraries for one Apple platform. Driven by scripts/build-libtorrent.sh,
# which merges the two into libTorrentEngine.a per slice and packages the
# xcframework. Written for Bluebox.
cmake_minimum_required(VERSION 3.22)
project(BBTorrentEngine LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

if(NOT LIBTORRENT_SOURCE_DIR)
  message(FATAL_ERROR "Pass -DLIBTORRENT_SOURCE_DIR=<unpacked libtorrent source>")
endif()

add_subdirectory(${LIBTORRENT_SOURCE_DIR} libtorrent EXCLUDE_FROM_ALL)

add_library(BBTorrent STATIC BBTorrent.mm)
target_include_directories(BBTorrent PUBLIC include)
# PUBLIC compile definitions of torrent-rasterbar (ABI version, crypto, DHT…)
# flow into the wrapper, so both sides agree on libtorrent's layout.
target_link_libraries(BBTorrent PRIVATE torrent-rasterbar)
target_compile_options(BBTorrent PRIVATE -fobjc-arc -Wall)
