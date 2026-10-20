#!/bin/bash
# Build a disk image for NVIDIA Card Control from a built .app and put it in builds/ next to the project.
#
# From Xcode (recommended): Product > Scheme > Edit Scheme > Archive > Post-actions > + > New Run Script Action,
# "Provide build settings from" the app target, and the script
#     "$SRCROOT/../scripts/make-dmg.sh"
# Then Product > Archive builds the Release app and writes the image. The app is found through
# $ARCHIVE_PRODUCTS_PATH and the version is the app's own (Xcode's MARKETING_VERSION).
# The same script also works as a Build post-action (it then uses $BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME and makes
# an image only for Release builds; set NVCC_MAKE_DMG=1 to force one for Debug).
# A scheme post-action runs after code signing and is not subject to Xcode's user-script sandboxing, which a
# Run Script build phase would be (ENABLE_USER_SCRIPT_SANDBOXING = YES would stop it writing to builds/).
#
# By hand:  make-dmg.sh [--any-config] [PATH-TO-APP] [OUTPUT-DIR]
# With no PATH-TO-APP it uses the most recent build of this project: the newest app among Xcode's DerivedData
# builds (Debug and Release), Xcode's archives, and the dot-app-builds folder next to builds/ (archives or apps). The image is unsigned: users open the app with right-click >
# Open the first time (the README inside says how). Output: builds/NVIDIA-Card-Control-<version>.dmg (+ .sha256).
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

PROJECT=nvidia-card-control          # the Xcode project's name: its DerivedData folder is "<PROJECT>-<hash>"
DEFAULT_OUT=$(cd "$(dirname "$0")/.." && pwd)/builds
APP_BUILDS=${NVCC_APP_BUILDS:-$(cd "$(dirname "$0")/.." && pwd)/dot-app-builds}
ANY=0; [ "${1:-}" = "--any-config" ] && { ANY=1; shift; }
APP=${1:-}; OUT=${2:-}
VERSION=""; CONF=""

if [ -z "$APP" ] && [ -n "${ARCHIVE_PRODUCTS_PATH:-}" ]; then
  # running as the Archive action's post-action: the archive is always a Release build
  for a in "$ARCHIVE_PRODUCTS_PATH"/Applications/*.app; do [ -d "$a" ] && APP=$a && break; done
  [ -n "$APP" ] || { echo "make-dmg: no app in $ARCHIVE_PRODUCTS_PATH/Applications" >&2; exit 2; }
  CONF=Release
  [ -z "$OUT" ] && [ -n "${SRCROOT:-}" ] && OUT=$(dirname "$SRCROOT")/builds
elif [ -z "$APP" ] && [ -n "${BUILT_PRODUCTS_DIR:-}" ] && [ -n "${FULL_PRODUCT_NAME:-}" ]; then
  # running inside Xcode
  APP="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"; VERSION=${MARKETING_VERSION:-}; CONF=${CONFIGURATION:-}
  [ -z "$OUT" ] && [ -n "${SRCROOT:-}" ] && OUT=$(dirname "$SRCROOT")/builds
  if [ "$CONF" != "Release" ] && [ "${NVCC_MAKE_DMG:-0}" != 1 ]; then
    echo "make-dmg: $CONF build, no disk image (Release builds make one; NVCC_MAKE_DMG=1 forces it)"; exit 0
  fi
elif [ -z "$APP" ]; then
  # by hand: the newest app among DerivedData builds and archives
  newest=""; newest_t=0
  consider() {
    local app=$1 t
    [ -d "$app" ] || return 0
    t=$(stat -f %m "$app" 2>/dev/null || echo 0)
    if [ "$t" -gt "$newest_t" ]; then newest=$app; newest_t=$t; fi
  }
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/"$PROJECT"-*/Build/Products/*/*.app; do consider "$app"; done
  for app in "$HOME"/Library/Developer/Xcode/Archives/*/*.xcarchive/Products/Applications/*.app; do consider "$app"; done
  # archives or apps you moved into dot-app-builds (next to builds/ and scripts/; NVCC_APP_BUILDS overrides the folder)
  for app in "$APP_BUILDS"/*.xcarchive/Products/Applications/*.app "$APP_BUILDS"/*/*.xcarchive/Products/Applications/*.app \
             "$APP_BUILDS"/*.app "$APP_BUILDS"/*/*.app; do consider "$app"; done
  [ -n "$newest" ] || { echo "make-dmg: no build of $PROJECT found; pass the path to the .app" >&2; exit 2; }
  APP=$newest
  case "$APP" in */Build/Products/Debug/*) CONF=Debug;; */Build/Products/Release/*|*.xcarchive/*) CONF=Release;; esac
  echo "most recent build: $APP"
fi
[ -d "$APP" ] || { echo "make-dmg: '$APP' is not an app bundle" >&2; exit 2; }
[ -n "$VERSION" ] || VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 0)
[ -n "$OUT" ] || OUT=$DEFAULT_OUT
SUFFIX=""; [ "$CONF" = "Debug" ] && SUFFIX="-debug"

NAME=$(basename "$APP" .app)
VOL="NVIDIA Card Control"
DMG="$OUT/NVIDIA-Card-Control-$VERSION$SUFFIX.dmg"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/nvcc-dmg.XXXXXX")
trap 'rm -rf "$STAGE" "$STAGE.rw.dmg"' EXIT

echo "app:     $APP"
echo "version: $VERSION${CONF:+ ($CONF)}"
echo "archs:   $(lipo -archs "$APP/Contents/MacOS/$NAME" 2>/dev/null || echo unknown)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
NVIDIA Card Control: a control panel for the NVIDIA Metal driver on macOS (experimental, community fork).

Install: drag the app onto Applications.

First launch: this app is not signed by an Apple Developer ID, so macOS will say it cannot verify the developer.
Right-click the app, choose Open, then Open again. You only need to do this once. If the app was downloaded
and still will not open, run:  xattr -dr com.apple.quarantine "/Applications/NVIDIA Card Control.app"

It changes driver settings and clears caches with an administrator prompt; it never sends anything anywhere.

License: PolyForm Noncommercial 1.0.0 (source-available, noncommercial).
TXT

mkdir -p "$OUT"
rm -f "$DMG"

# Window layout: README on the left, the app in the middle, the Applications shortcut on the right, an arrow
# between the last two. Finder records icon positions and the background in the volume's .DS_Store, and the only way
# to make it do that is to drive Finder with AppleScript on a mounted read-write copy. The first time, macOS asks
# whether Terminal / Xcode may control Finder (System Settings > Privacy & Security > Automation). If that fails or
# times out, the image is still built, just without the layout.
HERE=$(cd "$(dirname "$0")" && pwd)
BG="$HERE/dmg-background.png"
LAYOUT=0
if [ -f "$BG" ]; then
  mkdir -p "$STAGE/.background"; cp "$BG" "$STAGE/.background/background.png"; chflags hidden "$STAGE/.background"
fi
RW="$STAGE.rw.dmg"
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 4096 ))
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size ${SIZE_KB}k -ov "$RW" >/dev/null
MNT=$(hdiutil attach -readwrite -noverify -noautoopen -mountpoint "/Volumes/$VOL" "$RW" 2>/dev/null | tail -1 | cut -f3)
if [ -n "$MNT" ] && [ -f "$BG" ]; then
  if perl -e 'alarm 120; exec @ARGV' osascript >/dev/null 2>&1 <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 570}
    set theOptions to the icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 96
    set text size of theOptions to 13
    set background picture of theOptions to file ".background:background.png"
    set position of item "READ ME FIRST.txt" of container window to {100, 180}
    set position of item "$NAME.app" of container window to {300, 180}
    set position of item "Applications" of container window to {500, 180}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
  then LAYOUT=1; else echo "make-dmg: could not drive Finder for the window layout (allow it in Privacy & Security > Automation); building a plain image"; fi
fi
sync
[ -n "$MNT" ] && { bless --folder "$MNT" --openfolder "$MNT" >/dev/null 2>&1 || true; hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1; }
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
echo "layout:  $([ $LAYOUT = 1 ] && echo applied || echo "not applied")"
( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "image:   $DMG"
cat "$DMG.sha256"
