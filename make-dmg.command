#!/bin/bash
# Builds DailySpread for Apple silicon and Intel Macs and packs it into a drag-to-install .dmg
# in ~/Claude Apps/DailySpread, with a copy of the source code beside it.
# Double-click this file in Finder to run it.
cd "$(dirname "$0")" || exit 1
exec > >(tee make-dmg.log) 2>&1

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
DEST="$HOME/Claude Apps/DailySpread"
WORK="build/dmg"
STAGE="$WORK/stage"
APP="$STAGE/DailySpread.app"
echo "Making the DailySpread $VERSION installer on macOS $(sw_vers -productVersion)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed. Click Install in the window that opens, then run this again."
  xcode-select --install 2>/dev/null
  echo "DMG FAILED"
  exit 1
fi

# The compiler needs to be told where SwiftUI's macro plugins live (Xcode does this itself).
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

rm -rf "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK/bin"

# One build per processor type, joined into a single app that runs on both.
SLICES=()
for ARCH in arm64 x86_64; do
  echo "Compiling for $ARCH…"
  if "$SWIFTC" -O -swift-version 5 -parse-as-library -sdk "$SDK" -target "$ARCH-apple-macos13.0" \
      "${PLUGIN_ARGS[@]}" Sources/*.swift -o "$WORK/bin/DailySpread-$ARCH"; then
    SLICES+=("$WORK/bin/DailySpread-$ARCH")
  else
    echo "The $ARCH build failed, so the installer leaves it out."
  fi
done
if [ ${#SLICES[@]} -eq 0 ]; then echo "DMG FAILED"; exit 1; fi
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/DailySpread"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/DailySpread")"
echo "App contains: $ARCHS"

cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP" && echo "Signature checks out"

case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) MACS="Apple silicon and Intel Macs" ;;
  arm64) MACS="Macs with Apple silicon (M1 or later)" ;;
  *) MACS="Intel Macs" ;;
esac

ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<EOT
DailySpread $VERSION

A menu bar app that puts a new high-resolution photo on your desktop every day
and spreads it across all your displays as one picture.

INSTALL
1. Drag DailySpread onto the Applications folder in this window.
2. Open DailySpread from Applications. It's a personal build that Apple hasn't
   checked, so macOS says it can't verify it. Click Done.
3. Open System Settings › Privacy & Security. Under Security, click Open Anyway
   next to DailySpread, and confirm with your password or Touch ID.
4. DailySpread appears in the menu bar as two small screens. It fetches the first
   wallpaper straight away and opens at login from then on.

ON A NEW MAC
- Topics start as Nature and Cars. Change them in Settings › Topics.
- With two displays, open Settings › Layout › Show Alignment Grid and adjust the
  gap and height until the lines run straight across both screens.

Runs on $MACS with macOS 13 Ventura or later.
The source code is in Claude Apps › DailySpread › Source code on the Mac this
installer was made on. Double-click build.command there to rebuild.
EOT

mkdir -p "$DEST"
DMG="$DEST/DailySpread $VERSION.dmg"
# Earlier installers made by this script are replaced by this one.
for old in "$DEST"/DailySpread\ *.dmg; do
  [ -e "$old" ] && hdiutil detach "/Volumes/$(basename "$old" .dmg)" >/dev/null 2>&1
  rm -f "$old"
done
echo "Packing the installer…"
if ! hdiutil create -volname "DailySpread $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$DMG"; then
  echo "DMG FAILED"
  exit 1
fi
hdiutil verify "$DMG"

# Open the finished installer read-only and check what's inside.
MOUNT="$(mktemp -d)"
if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null; then
  echo "Inside the installer:"
  ls -l "$MOUNT"
  echo "Processors: $(lipo -archs "$MOUNT/DailySpread.app/Contents/MacOS/DailySpread")"
  codesign --verify --strict "$MOUNT/DailySpread.app" && echo "Installed app signature checks out"
  hdiutil detach "$MOUNT" >/dev/null
fi
rmdir "$MOUNT" 2>/dev/null

# Keep a copy of the source code beside the installer, unless this already is that copy.
SOURCE_COPY="$DEST/Source code"
if [ "$(pwd -P)" != "$(cd "$SOURCE_COPY" 2>/dev/null && pwd -P)" ]; then
  mkdir -p "$SOURCE_COPY"
  rsync -a --delete --exclude build --exclude '*.log' ./ "$SOURCE_COPY/"
fi

echo "Installer: $DMG ($(du -h "$DMG" | cut -f1))"
echo "Runs on: $MACS"
echo "DMG OK"
# Show the finished installer, ready to drag DailySpread into Applications.
open "$DMG"
