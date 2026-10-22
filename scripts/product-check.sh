#!/bin/sh
# This is called directly by the existing harness runner. Do not start a second runner/process group.
set -eu

task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_root"
if [ "$#" -ne 2 ]; then
  printf 'usage: product-check.sh preflight|check lint|harness|apple-tests|macos-app|ios-simulator\n' >&2
  exit 2
fi
task_mode=$1
task_profile=$2
case "$task_mode" in preflight|check) ;; *) exit 2 ;; esac
case "$task_profile" in lint|harness|apple-tests|macos-app|ios-simulator) ;; *) exit 2 ;; esac

missing() { printf 'product prerequisite: %s\n' "$1" >&2; exit 78; }
require_tool() { command -v "$1" >/dev/null 2>&1 || missing "missing tool: $1"; }
case "$task_profile" in
  lint)
    require_tool node
    require_tool npm
    node --version || missing 'Node failed to start'
    npm --version || missing 'npm failed to start'
    [ -d node_modules ] || missing 'install the locked Node dependencies before running this profile' ;;
  harness)
    require_tool go
    require_tool gofmt
    require_tool bash
    task_expected_go="go$(awk '$1 == "go" {print $2}' harness/go.mod)"
    task_actual_go=$(GOTOOLCHAIN=local go version) || missing 'Go failed to start'
    case "$task_actual_go" in *" $task_expected_go "*) ;; *) missing "expected $task_expected_go, found $task_actual_go" ;; esac
    printf '%s\n' "$task_actual_go"
    [ -x /usr/bin/sqlite3 ] || missing 'missing /usr/bin/sqlite3' ;;
  apple-tests|macos-app|ios-simulator)
    [ "$(uname -s)" = Darwin ] || missing 'Apple checks require macOS'
    require_tool xcrun
    xcrun --find swift >/dev/null 2>&1 || missing 'Swift toolchain is unavailable'
    swift --version || missing 'Swift failed to start'
    if [ "$task_profile" = ios-simulator ]; then
      require_tool xcodebuild
      xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || missing 'iOS Simulator SDK is unavailable'
    fi ;;
esac
if [ "$task_mode" = preflight ]; then
  printf 'product prerequisite ready: %s\n' "$task_profile"
  exit 0
fi

# Keep products separate from normal developer/QA outputs and never overwrite a prior QA bundle.
export TSUMIKI_SWIFT_SCRATCH_PATH="$task_root/.local-state/product-build/swift"
export TSUMIKI_SWIFT_CACHE_PATH="$task_root/.local-state/product-build/swift-cache"
export TSUMIKI_MAC_BUNDLE_PATH="$task_root/.local-state/product-build/macos/TsumikiText.app"
export TSUMIKI_IOS_BUILD_PATH="$task_root/.local-state/product-build/ios"
case "$task_profile" in
  lint) exec npm run lint ;;
  harness) exec bash scripts/check-harness.sh ;;
  apple-tests) exec sh apple/scripts/check-native.sh test ;;
  macos-app) exec sh apple/scripts/build-macos-app.sh ;;
  ios-simulator) exec sh apple/scripts/check-native.sh ios-build ;;
esac
