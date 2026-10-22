#!/bin/sh
set -eu

# Exercise the real packager with tiny native binaries, without rebuilding Swift.
task_script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_test_directory=$(mktemp -d "${TMPDIR:-/tmp}/tsumiki-bundle-test.XXXXXX")
task_pid_one=
task_pid_two=
cleanup() {
  for task_pid in "$task_pid_one" "$task_pid_two"; do
    if [ -n "$task_pid" ]; then
      kill "$task_pid" 2>/dev/null || :
      wait "$task_pid" 2>/dev/null || :
    fi
  done
  rm -rf "$task_test_directory"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fail() { printf 'FAIL: macOS bundle: %s\n' "$1" >&2; exit 1; }

mkdir -p "$task_test_directory/bin" "$task_test_directory/version 1" "$task_test_directory/version 2"
cat > "$task_test_directory/probe.c" <<'SOURCE'
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    (void)argv;
    printf("version=%d\n", PROBE_VERSION);
    fflush(stdout);
    if (argc > 1) { for (;;) pause(); }
    return 0;
}
SOURCE
for task_version in 1 2; do
  xcrun clang -DPROBE_VERSION="$task_version" "$task_test_directory/probe.c" \
    -o "$task_test_directory/version $task_version/TsumikiText"
done
cat > "$task_test_directory/bin/swift" <<'SWIFT'
#!/bin/sh
set -eu
[ "${TSUMIKI_BUNDLE_TEST_FAIL:-0}" = 0 ] || exit 42
case " $* " in
  *" --show-bin-path "*) printf '%s\n' "$TSUMIKI_BUNDLE_TEST_BINARY_DIRECTORY" ;;
esac
SWIFT
chmod +x "$task_test_directory/bin/swift"
task_bundle="$task_test_directory/output with spaces/TsumikiText.app"
task_executable="$task_bundle/Contents/MacOS/TsumikiText"
package_fixture() {
  PATH="$task_test_directory/bin:$PATH" \
  TSUMIKI_MAC_BUNDLE_PATH="$task_bundle" \
  TSUMIKI_BUNDLE_TEST_BINARY_DIRECTORY="$1" \
  TSUMIKI_BUNDLE_TEST_FAIL="${2:-0}" \
    sh "$task_script_directory/build-macos-app.sh" > "$task_test_directory/package.log" 2>&1
}
expect_version() {
  if task_actual=$("$task_executable"); then
    [ "$task_actual" = "version=$1" ] || fail "expected version $1, got $task_actual"
  else
    fail "published version $1 did not launch"
  fi
}
wait_ready() {
  task_attempt=0
  until [ -s "$2" ]; do
    kill -0 "$1" 2>/dev/null || fail 'old process exited before becoming ready'
    task_attempt=$((task_attempt + 1))
    [ "$task_attempt" -lt 200 ] || fail 'old process did not become ready'
    sleep 0.025
  done
}

package_fixture "$task_test_directory/version 1"
expect_version 1
cp "$task_executable" "$task_test_directory/preserved-executable"
cp "$task_bundle/Contents/Info.plist" "$task_test_directory/preserved-plist"
if package_fixture "$task_test_directory/version 2" 1; then fail 'failed build was accepted'; fi
cmp "$task_executable" "$task_test_directory/preserved-executable" || fail 'build failure changed executable'
cmp "$task_bundle/Contents/Info.plist" "$task_test_directory/preserved-plist" || fail 'build failure changed plist'

"$task_executable" hold > "$task_test_directory/old.ready" &
task_pid_one=$!
wait_ready "$task_pid_one" "$task_test_directory/old.ready"
package_fixture "$task_test_directory/version 1"
expect_version 1
kill -0 "$task_pid_one" || fail 'same-version publication stopped the old process'
package_fixture "$task_test_directory/version 2"
expect_version 2
kill -0 "$task_pid_one" || fail 'changed-version publication stopped the old process'

"$task_executable" hold > "$task_test_directory/new.ready" &
task_pid_two=$!
wait_ready "$task_pid_two" "$task_test_directory/new.ready"
package_fixture "$task_test_directory/version 2"
expect_version 2
kill -0 "$task_pid_two" || fail 'repeat publication stopped the new process'
cp "$task_executable" "$task_test_directory/preserved-executable"
cp "$task_bundle/Contents/Info.plist" "$task_test_directory/preserved-plist"
if package_fixture "$task_test_directory/missing binary"; then fail 'missing executable was accepted'; fi
cmp "$task_executable" "$task_test_directory/preserved-executable" || fail 'packaging failure changed executable'
cmp "$task_bundle/Contents/Info.plist" "$task_test_directory/preserved-plist" || fail 'packaging failure changed plist'
expect_version 2
kill "$task_pid_one" "$task_pid_two"
wait "$task_pid_one" 2>/dev/null || :
wait "$task_pid_two" 2>/dev/null || :
task_pid_one=
task_pid_two=
package_fixture "$task_test_directory/version 1"
expect_version 1
printf 'PASS: macOS bundle launch, live replacement, and failure preservation\n'
