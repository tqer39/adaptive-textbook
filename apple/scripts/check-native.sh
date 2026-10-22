#!/bin/sh
set -eu

task_script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_package_directory=$(CDPATH= cd -- "$task_script_directory/.." && pwd)
task_root=$(CDPATH= cd -- "$task_package_directory/.." && pwd)
task_scratch_path=${TSUMIKI_SWIFT_SCRATCH_PATH:-$task_root/.local-state/swift-build}
task_cache_path=${TSUMIKI_SWIFT_CACHE_PATH:-$task_root/.local-state/swift-cache}
task_ios_path=${TSUMIKI_IOS_BUILD_PATH:-$task_root/.local-state/ios-build}

if [ "$#" -ne 1 ]; then
  printf 'usage: check-native.sh test|build|ios-build\n' >&2
  exit 2
fi
case "$1" in
  test) exec swift test --package-path "$task_package_directory" --scratch-path "$task_scratch_path" --cache-path "$task_cache_path" ;;
  build) exec swift build --package-path "$task_package_directory" --scratch-path "$task_scratch_path" --cache-path "$task_cache_path" ;;
  ios-build)
    exec xcodebuild -project "$task_package_directory/TsumikiText.xcodeproj" \
      -scheme TsumikiText-iOS -configuration Debug -sdk iphonesimulator \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$task_ios_path" \
      CODE_SIGNING_ALLOWED=NO build ;;
  *) printf 'unknown native check: %s\n' "$1" >&2; exit 2 ;;
esac
