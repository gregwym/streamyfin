#!/usr/bin/env bash
set -euo pipefail

work_dir="$RUNNER_TEMP/streamyfin-qa"
evidence="$RUNNER_TEMP/streamyfin-qa-evidence"
harness="$GITHUB_WORKSPACE/qa"
mkdir -p "$work_dir" "$evidence"
cd "$GITHUB_WORKSPACE/app-src"
test "$(git rev-parse HEAD)" = "$QA_REVISION"
printf '%s\n' "$QA_VARIANT $QA_REVISION" > "$evidence/revision.txt"

xcodebuild -version
xcrun simctl list runtimes
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
  if [[ -f "$work_dir/server.pid" ]]; then
    kill "$(cat "$work_dir/server.pid")" 2>/dev/null || true
  fi
  xcrun simctl shutdown "$device_id" 2>/dev/null || true
}
trap cleanup EXIT

# Generate the original app with its exact dependencies and a separate UI test target.
bun install --frozen-lockfile > "$evidence/bun.log" 2>&1 || { tail -100 "$evidence/bun.log"; exit 1; }
bun run ios:install-metal-toolchain > "$evidence/metal.log" 2>&1 || { tail -50 "$evidence/metal.log"; exit 1; }
bunx expo prebuild --platform ios --no-install > "$evidence/prebuild.log" 2>&1 || { tail -100 "$evidence/prebuild.log"; exit 1; }
(cd ios && pod install) > "$evidence/pods.log" 2>&1 || { tail -120 "$evidence/pods.log"; exit 1; }

ruby "$harness/test-target.rb" "$harness/MixedLibraryTests.swift" "$QA_VARIANT"
workspace=$(find ios -maxdepth 1 -name '*.xcworkspace' -print -quit)
test -n "$workspace"

xcrun simctl boot "$device_id"
xcrun simctl bootstatus "$device_id" -b
if [[ "$EXPO_TV" == 0 ]]; then
  xcrun simctl status_bar "$device_id" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState unplugged --batteryLevel 100
fi
python3 "$harness/fixture.py" "$work_dir" "$evidence"

status=0
xcodebuild test -workspace "$workspace" -scheme MixedLibraryQA -configuration Release \
  -destination "id=$device_id" -derivedDataPath "$work_dir/build" \
  -resultBundlePath "$work_dir/test.xcresult" -parallel-testing-enabled NO -jobs 3 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  > "$evidence/xcodebuild.log" 2>&1 || status=$?

if [[ -d "$work_dir/test.xcresult" ]]; then
  xcrun xcresulttool get test-results summary --path "$work_dir/test.xcresult" > "$evidence/test-summary.json" || true
  xcrun xcresulttool export attachments --path "$work_dir/test.xcresult" --output-path "$evidence/screenshots" || true
fi
if [[ "$status" -ne 0 ]]; then
  grep -E 'error:|failed|\*\* TEST' "$evidence/xcodebuild.log" | tail -35 || true
  tail -45 "$evidence/xcodebuild.log"
  xcrun simctl io "$device_id" screenshot "$evidence/failure.png" || true
  exit "$status"
fi
test -s "$evidence/test-summary.json"
find "$evidence/screenshots" -type f -name '*.png' | grep -q .
cat "$evidence/test-summary.json"
