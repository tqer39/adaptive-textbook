#!/bin/sh
set -eu

task_script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
task_package_directory=${TSUMIKI_SEARCH_BENCHMARK_PACKAGE:-"$(CDPATH='' cd -- "$task_script_directory/.." && pwd)"}
task_scratch_path=${TSUMIKI_SEARCH_BENCHMARK_BUILD:-"$task_package_directory/../.local-state/search-benchmark-build"}
task_cache_path=${TSUMIKI_SEARCH_BENCHMARK_CACHE:-"$task_package_directory/../.local-state/search-benchmark-cache"}

if [ "$#" -gt 1 ]; then
  echo "usage: benchmark-search.sh [result.json]" >&2
  exit 2
fi

swift build --package-path "$task_package_directory" --scratch-path "$task_scratch_path" \
  --cache-path "$task_cache_path" -c release --target TextbookCore
task_binary_directory=$(swift build --package-path "$task_package_directory" \
  --scratch-path "$task_scratch_path" --cache-path "$task_cache_path" -c release --show-bin-path)
swiftc -O -parse-as-library -swift-version 6 \
  -I "$task_binary_directory/Modules" -I "$task_package_directory/Sources/CSQLite/include" \
  "$task_package_directory/Benchmarks/FullTextSearch.swift" \
  "$task_binary_directory"/TextbookCore.build/*.swift.o \
  "$task_binary_directory"/CSQLite.build/*.o \
  -o "$task_binary_directory/FullTextSearchBenchmark"
exec "$task_binary_directory/FullTextSearchBenchmark" "$@"
