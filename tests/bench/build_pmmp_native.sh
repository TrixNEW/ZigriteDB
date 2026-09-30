#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/zigritedb-pmmp-native
source_dir=$cache_dir/leveldb
build_dir=$cache_dir/build
leveldb_ref=1c7564468b41610da4f498430e795ca4de0931ff
cmake_bin=${CMAKE_BIN:-cmake}

mkdir -p "$cache_dir"
if [ ! -d "$source_dir/.git" ]; then
    git clone https://github.com/pmmp/leveldb.git "$source_dir"
fi
git -C "$source_dir" checkout --quiet "$leveldb_ref"

"$cmake_bin" -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
    -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF \
    -DLEVELDB_SNAPPY=OFF -DLEVELDB_ZSTD=OFF -DLEVELDB_TCMALLOC=OFF
"$cmake_bin" --build "$build_dir" --parallel

if [ ! -f "$repo_dir/zig-out/lib/libzigritedb_native.so" ]; then
    printf 'Build the Linux ZigriteDB library first: zig build bench -Doptimize=ReleaseSafe\n' >&2
    exit 1
fi
cc -std=c11 -O2 -Wall -Wextra -Werror \
    -I"$repo_dir/include" -I"$source_dir/include" \
    "$repo_dir/tests/bench/pmmp_native.c" \
    -L"$repo_dir/zig-out/lib" -L"$build_dir" \
    -lzigritedb_native -lleveldb -lstdc++ -o "$cache_dir/pmmp_native"
printf '%s\n' "$cache_dir/pmmp_native"
