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
  if [[ -f "$work_dir/server.pid" ]]; then
    kill "$(cat "$work_dir/server.pid")" 2>/dev/null || true
  fi
  xcrun simctl shutdown "$device_id" 2>/dev/null || true
}
trap cleanup EXIT

echo "Starting the Jellyfin fixture"
python3 "$harness/fixture.py" "$work_dir" "$evidence" 2>&1 | tee "$evidence/fixture.log"
python3 - "$test_run" "$work_dir/library-id.txt" <<'PYENV'
from pathlib import Path
import plistlib
import re
import sys

test_run, library_id_file = map(Path, sys.argv[1:])
library_id = library_id_file.read_text().strip()
if not re.fullmatch(r"[a-fA-F0-9]{32}", library_id):
    raise ValueError(f"Unexpected Jellyfin fixture library ID: {library_id!r}")
with test_run.open("rb") as file:
    spec = plistlib.load(file)
if "TestConfigurations" in spec:
    targets = [target for configuration in spec["TestConfigurations"] for target in configuration["TestTargets"]]
else:
    targets = [target for target in spec.values() if isinstance(target, dict) and "TestBundlePath" in target]
if not targets:
    raise ValueError("The xctestrun file does not contain a test target.")
for target in targets:
    target.setdefault("EnvironmentVariables", {})["STREAMYFIN_QA_LIBRARY_ID"] = library_id
with test_run.open("wb") as file:
    plistlib.dump(spec, file)
PYENV
echo "Booting $runtime_family simulator $device_id"
xcrun simctl boot "$device_id"
python3 - "$device_id" <<'PYBOOT' 2>&1 | tee "$evidence/boot.log"
import subprocess
import sys

subprocess.run(["xcrun", "simctl", "bootstatus", sys.argv[1], "-b"], check=True, timeout=300)
PYBOOT

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
