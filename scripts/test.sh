#!/bin/sh
set -eu
DECHROME_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$DECHROME_ROOT"
mkdir -p build/tests build/module-cache-tests
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  -module-cache-path "$DECHROME_ROOT/build/module-cache-tests" -warnings-as-errors \
  launcher/DeChromeCore.swift launcher/DeChromeProfiles.swift tests/RuntimeTests.swift -o build/tests/RuntimeTests
"$DECHROME_ROOT/build/tests/RuntimeTests" "$DECHROME_ROOT"
/usr/bin/xcrun clang -target arm64-apple-macos13.0 -fobjc-arc -fblocks \
  -Wall -Wextra -Werror -framework Foundation tests/TabTargetPolicyTests.m \
  -o build/tests/TabTargetPolicyTests
"$DECHROME_ROOT/build/tests/TabTargetPolicyTests"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 \
  -module-cache-path "$DECHROME_ROOT/build/module-cache-tests" -warnings-as-errors \
  launcher/DeChromeCore.swift launcher/DeChromeProfiles.swift tests/ProfileImportTests.swift \
  -o build/tests/ProfileImportTests
exec "$DECHROME_ROOT/build/tests/ProfileImportTests"
