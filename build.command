#!/bin/bash
# Builds DailySpread.app from the source in this folder, installs it in ~/Applications and opens it.
# Double-click this file in Finder to run it.
cd "$(dirname "$0")" || exit 1
exec > >(tee build.log) 2>&1

echo "macOS $(sw_vers -productVersion) on $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo
  echo "DailySpread needs Apple's free Command Line Tools to compile."
  echo "A window will ask to install them: click Install, wait for it to finish,"
  echo "then double-click build.command again."
  xcode-select --install 2>/dev/null
  echo "BUILD NEEDS COMMAND LINE TOOLS"
  exit 1
fi
xcrun swiftc --version

ARCH="$(uname -m)"
APP="build/DailySpread.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Newer SDKs implement parts of SwiftUI as macros. Xcode tells the compiler where their
# plugins live; a plain swiftc call has to do the same.
SDK="$(xcrun --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
TOOLCHAIN_BIN="$(dirname "$SWIFTC")"
PLUGIN_ARGS=()
for dir in "$TOOLCHAIN_BIN/../lib/swift/host/plugins" "$TOOLCHAIN_BIN/../local/lib/swift/host/plugins"; do
  [ -d "$dir" ] && PLUGIN_ARGS+=(-plugin-path "$dir")
done
for dir in "$SDK/usr/lib/swift/host/plugins" "$SDK/usr/local/lib/swift/host/plugins"; do
  [ -d "$dir" ] && PLUGIN_ARGS+=(-external-plugin-path "$dir#$TOOLCHAIN_BIN/swift-plugin-server")
done
echo "SDK: $SDK"
echo "Macro plugins: ${PLUGIN_ARGS[*]:-none found}"

echo "Compiling…"
if ! "$SWIFTC" -O -swift-version 5 -parse-as-library \
    -sdk "$SDK" -target "$ARCH-apple-macos13.0" \
    "${PLUGIN_ARGS[@]}" \
    Sources/*.swift -o "$APP/Contents/MacOS/DailySpread"; then
  echo "BUILD FAILED"
  exit 1
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"

# Replace the copy that's already installed: the main Applications folder unless it only
# lives in your own ~/Applications, or you can't write to the main one.
TARGET="/Applications"
if { [ -d "$HOME/Applications/DailySpread.app" ] && [ ! -d /Applications/DailySpread.app ]; } || [ ! -w /Applications ]; then
  TARGET="$HOME/Applications"
fi
echo "Installing into $TARGET…"
pkill -x DailySpread 2>/dev/null && sleep 1
mkdir -p "$TARGET"
rm -rf "$TARGET/DailySpread.app"
cp -R "$APP" "$TARGET/"

# Topics chosen outside the app (topics-to-apply.txt, one per line) are saved once, then a
# wallpaper for them is fetched straight away.
OPEN_ARGS=()
if [ -f topics-to-apply.txt ]; then
  TOPICS=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && TOPICS+=("$line")
  done < topics-to-apply.txt
  defaults write app.dailyspread.DailySpread topics -array "${TOPICS[@]}"
  echo "Topics set to: ${TOPICS[*]}"
  rm -f topics-to-apply.txt
  OPEN_ARGS=(--args --new-wallpaper)
fi
open "$TARGET/DailySpread.app" "${OPEN_ARGS[@]}"
echo "BUILD OK — DailySpread is running in your menu bar."
