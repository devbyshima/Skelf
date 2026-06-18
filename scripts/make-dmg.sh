#!/usr/bin/env bash
# Build a "drag to Applications" Skelf.dmg from Skelf.app.
#
#   ./scripts/make-dmg.sh        # builds the app if needed, then Skelf.dmg
#
# Produces a compressed disk image whose window shows Skelf.app on the left and an
# Applications alias on the right, with scripts/dmg-background.png (squiggle + caption)
# behind them — so a user just drags Skelf onto Applications to install. Self-contained:
# only needs hdiutil + Finder (no create-dmg).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Skelf.app"
NAME="Skelf"
VOL="Skelf"
DMG="$ROOT/$NAME.dmg"
BG="$ROOT/scripts/dmg-background.png"
MOUNT="/Volumes/$VOL"

STAGE="$(mktemp -d)/stage"
RW="$(mktemp -u).dmg"

cleanup() {
    hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    rm -rf "$(dirname "$STAGE")" "$RW"
}
trap cleanup EXIT

# 1. Make sure the app exists.
[ -d "$APP" ] || "$ROOT/build.sh"

# 2. Stage the contents: the app, an Applications drop target, and the background.
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.png"

# 3. Create a writable image and mount it (give it slack space for the .DS_Store).
rm -f "$RW" "$DMG"
hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
    -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -readwrite -noautoopen -mountpoint "$MOUNT" >/dev/null
sleep 1
chflags hidden "$MOUNT/.background" 2>/dev/null || true

# 4. Lay out the window with Finder. Set options + positions, persist with a reopen.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {240, 150, 900, 550}
        set vo to the icon view options of container window
        set arrangement of vo to not arranged
        set icon size of vo to 120
        set text size of vo to 13
        set background picture of vo to file ".background:background.png"
        set position of item "$NAME.app" of container window to {178, 190}
        set position of item "Applications" of container window to {482, 190}
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
# NOTE: do NOT close the Finder window before detaching — on macOS 15/26 closing it
# resets the saved icon positions / bounds in .DS_Store. Detaching with it open persists.

sync; sleep 1

# 5. Detach (with retries — the volume is often briefly busy) and compress.
for _ in 1 2 3 4 5; do hdiutil detach "$MOUNT" >/dev/null 2>&1 && break || sleep 1; done
hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# 6. Checksum, so a release can publish Skelf.dmg + SHA256SUMS for users to verify the download.
( cd "$ROOT" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS )

echo "Built $DMG"
echo "Wrote $ROOT/SHA256SUMS"
