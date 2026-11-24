#!/usr/bin/env bash
set -euo pipefail

products=$(dirname "$1")
harness=$(dirname "$0")
runner="$products/Release-iphonesimulator"
sdk=iphonesimulator
target=arm64-apple-ios16.4-simulator
if [[ "$EXPO_TV" == 1 ]]; then
  runner="$products/Release-appletvsimulator"
  sdk=appletvsimulator
  target=arm64-apple-tvos16.4-simulator
fi
test_bundle="$runner/MixedLibraryUITests-Runner.app/PlugIns/MixedLibraryUITests.xctest/MixedLibraryUITests"
bundle=$(plutil -extract CFBundleIdentifier raw "$runner/Streamyfin.app/Info.plist")
[[ "$bundle" =~ ^[a-zA-Z0-9.-]+$ ]]
test -f "$test_bundle"

scratch=$(mktemp -d "$RUNNER_TEMP/streamyfin-xctest.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
baseline=false
if [[ "$QA_VARIANT" == ios-before ]]; then
  baseline=true
fi
cat > "$scratch/QAConfiguration.swift" <<SWIFT
enum QAConfiguration {
    static let bundle = "$bundle"
    static let baseline = $baseline
    static let variant = "$QA_VARIANT"
}
SWIFT

sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
platform_path=$(xcrun --sdk "$sdk" --show-sdk-platform-path)
frameworks="$platform_path/Developer/Library/Frameworks"
platform_libraries="$platform_path/Developer/usr/lib"
xcrun --sdk "$sdk" swiftc -whole-module-optimization -emit-object \
  -module-name MixedLibraryUITests -swift-version 5 -sdk "$sdk_path" -target "$target" \
  -module-cache-path "$scratch/module-cache" \
  -F "$frameworks" -F "$sdk_path/Developer/Library/Frameworks" -Isystem "$platform_libraries" \
  "$harness/MixedLibraryTests.swift" "$scratch/QAConfiguration.swift" -o "$scratch/tests.o"

xcrun --sdk "$sdk" clang -bundle -target "$target" -isysroot "$sdk_path" \
  -F "$frameworks" -F "$sdk_path/Developer/Library/Frameworks" \
  -L "$sdk_path/usr/lib/swift" -L "$platform_libraries" \
  -Xlinker -rpath -Xlinker /usr/lib/swift -Xlinker -rpath -Xlinker @loader_path/Frameworks \
  -fobjc-link-runtime -framework XCTest -lXCTestSwiftSupport -framework Foundation \
  "$scratch/tests.o" -o "$scratch/MixedLibraryUITests"
/usr/bin/install -m 755 "$scratch/MixedLibraryUITests" "$test_bundle"
file "$test_bundle"
