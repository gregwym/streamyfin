#!/usr/bin/env bash
set -euo pipefail

work_dir="$RUNNER_TEMP/streamyfin-qa"
evidence="$RUNNER_TEMP/streamyfin-qa-evidence"
harness="$GITHUB_WORKSPACE/qa"
mkdir -p "$work_dir" "$evidence"
cd "$GITHUB_WORKSPACE/app-src"
test "$(git rev-parse HEAD)" = "$QA_REVISION"
printf '%s\n' "$QA_VARIANT $QA_REVISION" > "$evidence/revision.txt"

xcrun simctl list runtimes
test_run=$(find "$work_dir/build/Build/Products" -maxdepth 2 -name '*.xctestrun' -print -quit)
test -n "$test_run"
if [[ -n "${QA_RESTORED_BUILD:-}" ]]; then
  bash "$harness/rebuild-tests.sh" "$test_run"
fi
if [[ "$EXPO_TV" == 1 ]]; then
  runtime_family=tvOS
  device_type=com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-1080p
else
  runtime_family=iOS
  device_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17
fi
runtime=$(xcrun simctl list runtimes -j | jq -er --arg prefix "com.apple.CoreSimulator.SimRuntime.$runtime_family-" '
  [.runtimes[] | select(.isAvailable and (.identifier | startswith($prefix)))] |
  sort_by(.version | split(".") | map(tonumber)) | last | .identifier')
device_id=$(xcrun simctl create "Streamyfin QA" "$device_type" "$runtime")

cleanup() {
  if [[ -n "${link_relay_pid:-}" ]]; then
    kill "$link_relay_pid" 2>/dev/null || true
  fi
  if [[ -f "$work_dir/server.pid" ]]; then
    kill "$(cat "$work_dir/server.pid")" 2>/dev/null || true
  fi
  xcrun simctl shutdown "$device_id" 2>/dev/null || true
}
trap cleanup EXIT

echo "Starting the Jellyfin fixture"
python3 "$harness/fixture.py" "$work_dir" "$evidence" 2>&1 | tee "$evidence/fixture.log"
echo "Booting $runtime_family simulator $device_id"
xcrun simctl boot "$device_id"
python3 - "$device_id" <<'PYBOOT' 2>&1 | tee "$evidence/boot.log"
import subprocess
import sys

subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b"], check=True, timeout=300)
PYBOOT

runner_info=$(find "$(dirname "$test_run")" -path '*/MixedLibraryUITests-Runner.app/Info.plist' -print -quit)
runner_bundle=$(plutil -extract CFBundleIdentifier raw "$runner_info")
library_id=$(cat "$work_dir/library-id.txt")
[[ "$library_id" =~ ^[a-fA-F0-9]{32}$ ]]
library_url="streamyfin:///$library_id"
if [[ "$EXPO_TV" == 1 ]]; then
  # The app uses this route parameter for its TV Home "See All" link.
  library_url+="?fromSeeAll=true"
fi
relay_library_link() {
  local data_path
  while true; do
    if data_path=$(xcrun simctl get_app_container "$device_id" "$runner_bundle" data 2>/dev/null) &&
      [[ -f "$data_path/Library/Caches/streamyfin-qa-open-library" ]]; then
      echo "Opening the fixture library in the running simulator app."
      xcrun simctl openurl "$device_id" "$library_url"
      return
    fi
    sleep 1
  done
}
relay_library_link > "$evidence/deep-link.log" 2>&1 &
link_relay_pid=$!

status=0
xcodebuild test-without-building -xctestrun "$test_run" -destination "id=$device_id" \
  -resultBundlePath "$work_dir/test.xcresult" -parallel-testing-enabled NO -jobs 3 \
  2>&1 | tee "$evidence/ui-test.log" || status=$?

if [[ -d "$work_dir/test.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$work_dir/test.xcresult" > "$evidence/test-summary.json" || true
  xcrun xcresulttool export attachments --path "$work_dir/test.xcresult" --output-path "$evidence/screenshots" || true
fi
if [[ "$status" -ne 0 ]]; then
  grep -E 'error:|failed|\*\* TEST' "$evidence/ui-test.log" | tail -35 || true
  tail -45 "$evidence/ui-test.log"
  xcrun simctl io "$device_id" screenshot "$evidence/failure.png" || true
  exit "$status"
fi
test -s "$evidence/test-summary.json"
find "$evidence/screenshots" -type f -name '*.png' | grep -q .
cat "$evidence/test-summary.json"
