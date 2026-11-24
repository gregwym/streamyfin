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
bun install --frozen-lockfile > "$evidence/bun.log" 2>&1 || { tail -100 "$evidence/bun.log"; exit 1; }
bun run ios:install-metal-toolchain > "$evidence/metal.log" 2>&1 || { tail -50 "$evidence/metal.log"; exit 1; }
bunx expo prebuild --platform ios --no-install > "$evidence/prebuild.log" 2>&1 || { tail -100 "$evidence/prebuild.log"; exit 1; }
for attempt in 1 2 3; do
  if (cd ios && pod install) >> "$evidence/pods.log" 2>&1; then
    break
  fi
  tail -30 "$evidence/pods.log"
  if [[ "$attempt" == 3 ]]; then
    exit 1
  fi
  sleep 12
done

ruby "$harness/test-target.rb" "$harness/MixedLibraryTests.swift" "$QA_VARIANT"
workspace=$(find ios -maxdepth 1 -name '*.xcworkspace' -print -quit)
test -n "$workspace"

platform="iOS Simulator"
if [[ "$EXPO_TV" == 1 ]]; then
  platform="tvOS Simulator"
fi
status=0
xcodebuild build-for-testing -workspace "$workspace" -scheme MixedLibraryQA -configuration Release \
  -destination "generic/platform=$platform" -derivedDataPath "$work_dir/build" -jobs 3 \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  > "$evidence/xcodebuild.log" 2>&1 || status=$?
if [[ "$status" -ne 0 ]]; then
  grep -E 'error:|failed|\*\* BUILD' "$evidence/xcodebuild.log" | tail -35 || true
  tail -45 "$evidence/xcodebuild.log"
  exit "$status"
fi
find "$work_dir/build/Build/Products" -maxdepth 2 -name '*.xctestrun' -print
