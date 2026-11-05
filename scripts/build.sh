#!/bin/sh
set -eu
DECHROME_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$DECHROME_ROOT"
DECHROME_BUILD="$DECHROME_ROOT/build"
DECHROME_STAGE="$DECHROME_BUILD/.DeChrome-$$.app"
DECHROME_TARGET="arm64-apple-macos13.0"
DECHROME_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' resources/Info.plist)
DECHROME_SOURCE_COMMIT=null
DECHROME_SOURCE_DIRTY=null
if DECHROME_GIT_COMMIT=$(git rev-parse --verify HEAD 2>/dev/null); then
  DECHROME_SOURCE_COMMIT="\"$DECHROME_GIT_COMMIT\""
  DECHROME_SOURCE_DIRTY=false
  if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then DECHROME_SOURCE_DIRTY=true; fi
fi
mkdir -p "$DECHROME_STAGE/Contents/MacOS" "$DECHROME_STAGE/Contents/Resources" "$DECHROME_BUILD/module-cache"
trap 'rm -rf "$DECHROME_STAGE"' EXIT HUP INT TERM
/usr/bin/xcrun clang -target "$DECHROME_TARGET" -dynamiclib -fobjc-arc -fblocks \
  -Wall -Wextra -Werror -O2 -framework Cocoa -framework QuartzCore \
  -Wl,-install_name,@rpath/DeChrome.dylib \
  native/DeChrome.m native/DCBrowser.m native/DCPalette.m \
  -o "$DECHROME_STAGE/Contents/Resources/DeChrome.dylib"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O -whole-module-optimization \
  -target "$DECHROME_TARGET" -module-cache-path "$DECHROME_BUILD/module-cache" \
  -framework AppKit -framework Foundation launcher/DeChromeCore.swift launcher/DeChromeMain.swift \
  -o "$DECHROME_STAGE/Contents/MacOS/DeChrome"
/bin/cp resources/Info.plist "$DECHROME_STAGE/Contents/Info.plist"
/bin/cp resources/Start.html "$DECHROME_STAGE/Contents/Resources/Start.html"
/usr/bin/printf 'APPL????' > "$DECHROME_STAGE/Contents/PkgInfo"
/usr/bin/xcrun swiftc -O -target "$DECHROME_TARGET" -module-cache-path "$DECHROME_BUILD/module-cache" \
  -framework AppKit scripts/make_icon.swift -o "$DECHROME_BUILD/make-icon"
rm -rf "$DECHROME_BUILD/AppIcon.iconset"
mkdir -p "$DECHROME_BUILD/AppIcon.iconset"
"$DECHROME_BUILD/make-icon" "$DECHROME_BUILD/AppIcon.iconset"
/bin/cp "$DECHROME_BUILD/AppIcon.icns" "$DECHROME_STAGE/Contents/Resources/AppIcon.icns"
/bin/cat > "$DECHROME_STAGE/Contents/Resources/build-info.json" <<EOF
{"version":"$DECHROME_VERSION","architecture":"arm64","minimumMacOS":"13.0","signing":"ad-hoc development","experimentalTabs":true,"sourceCommit":$DECHROME_SOURCE_COMMIT,"sourceDirty":$DECHROME_SOURCE_DIRTY,"runtimeVerifiedMacOS":["26.6.2"],"runtimeVerifiedChrome":["156.0.8078.80"],"macOS27":"requires on-device validation"}
EOF
/usr/bin/codesign --force --sign - --timestamp=none "$DECHROME_STAGE/Contents/Resources/DeChrome.dylib"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$DECHROME_STAGE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DECHROME_STAGE"
if [ -e "$DECHROME_BUILD/DeChrome.app" ]; then
  rm -rf "$DECHROME_BUILD/DeChrome.previous.app"
  /bin/mv "$DECHROME_BUILD/DeChrome.app" "$DECHROME_BUILD/DeChrome.previous.app"
fi
/bin/mv "$DECHROME_STAGE" "$DECHROME_BUILD/DeChrome.app"
/usr/bin/printf 'Built %s\n' "$DECHROME_BUILD/DeChrome.app"
