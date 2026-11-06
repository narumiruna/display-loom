#!/bin/bash
set -euo pipefail

# Compile and run production-code regression checks without Xcode or display changes.
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/display-loom-checks.XXXXXX")"
trap 'rm -rf "$build"' EXIT
sdk="$(xcrun --show-sdk-path)"
target="$(uname -m)-apple-macosx14.0"
header="$root/DisplayLoom/Bridge/DisplayLoom-Bridging-Header.h"
sources=()
while IFS= read -r -d '' source; do
  sources+=("$source")
done < <(find "$root/DisplayLoom" -name '*.swift' ! -name DisplayLoomApp.swift -print0)

xcrun clang -target "$target" -isysroot "$sdk" -fobjc-arc -Wall -Wextra -Werror \
  -c "$root/DisplayLoom/Bridge/VSCGVirtualDisplayBridge.m" -o "$build/bridge.o"
xcrun clang -target "$target" -isysroot "$sdk" -fobjc-arc -O -Wall -Wextra -Werror \
  -framework Foundation -framework CoreGraphics \
  "$root/scripts/tests/BridgeRegressionChecks.m" -o "$build/check-bridge"
"$build/check-bridge"
xcrun swiftc -swift-version 5 -target "$target" -sdk "$sdk" -parse-as-library \
  -warnings-as-errors -typecheck -import-objc-header "$header" "${sources[@]}" \
  "$root/DisplayLoom/Application/DisplayLoomApp.swift"
xcrun swiftc -swift-version 5 -target "$target" -sdk "$sdk" -O -parse-as-library \
  -warnings-as-errors -emit-library -emit-module -enable-testing -module-name DisplayLoom \
  -import-objc-header "$header" "${sources[@]}" "$build/bridge.o" \
  -o "$build/libDisplayLoom.dylib" -emit-module-path "$build/DisplayLoom.swiftmodule"
xcrun swiftc -swift-version 5 -target "$target" -sdk "$sdk" -O -parse-as-library \
  -warnings-as-errors -I "$build" -L "$build" -lDisplayLoom -Xlinker -rpath -Xlinker "$build" \
  -import-objc-header "$header" \
  "$root/DisplayLoomTests/TestDoubles.swift" \
  "$root/DisplayLoomTests/PerformanceChecks.swift" \
  "$root/DisplayLoomTests/BackendPerformanceChecks.swift" \
  "$root/scripts/PerformanceCheckMain.swift" -o "$build/check-performance"
"$build/check-performance"
