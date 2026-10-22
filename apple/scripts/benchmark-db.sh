#!/bin/sh
set -eu

task_script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_package_directory=$(CDPATH= cd -- "$task_script_directory/.." && pwd)
task_scratch_path=${TSUMIKI_DB_BENCHMARK_BUILD:-"$task_package_directory/../.local-state/database-benchmark-build"}
task_cache_path=${TSUMIKI_DB_BENCHMARK_CACHE:-"$task_package_directory/../.local-state/database-benchmark-cache"}

swift build --package-path "$task_package_directory" --scratch-path "$task_scratch_path" \
  --cache-path "$task_cache_path" -c release --target TextbookCore
task_binary_directory=$(swift build --package-path "$task_package_directory" \
  --scratch-path "$task_scratch_path" --cache-path "$task_cache_path" -c release --show-bin-path)
swiftc -O -parse-as-library -swift-version 6 \
  -I "$task_binary_directory/Modules" -I "$task_package_directory/Sources/CSQLite/include" \
  "$task_package_directory/Benchmarks/DatabaseReads.swift" \
  "$task_binary_directory"/TextbookCore.build/*.swift.o \
  "$task_binary_directory"/CSQLite.build/*.o \
  -o "$task_binary_directory/DatabaseReadBenchmark"
exec "$task_binary_directory/DatabaseReadBenchmark" "$@"
