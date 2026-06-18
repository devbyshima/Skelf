#!/usr/bin/env bash
# Compile Skelf.swift into a runnable Skelf.app bundle (no Xcode project).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/Skelf.app"
ARCH="$(uname -m)"   # arm64 on Apple Silicon

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Skelf</string>
  <key>CFBundleDisplayName</key><string>Skelf</string>
  <key>CFBundleIdentifier</key><string>dev.fulltime.skelf</string>
  <key>CFBundleExecutable</key><string>Skelf</string>
  <key>CFBundleIconFile</key><string>Skelf</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# App icon (Skelf.icns generated from Icons/Skelf-iOS-Default-1024@1x.png).
[ -f "$DIR/Skelf.icns" ] && cp "$DIR/Skelf.icns" "$APP/Contents/Resources/Skelf.icns"
# Menu-bar icon: the Skelf mark (loaded as a vector template image at runtime).
[ -f "$DIR/Icons/skelf.svg" ] && cp "$DIR/Icons/skelf.svg" "$APP/Contents/Resources/skelf.svg"

# SwiftUI uses external macros (@State, @Bindable, …) whose compiler plugin
# (libSwiftUIMacros.dylib) ships only inside Xcode, NOT the Command Line Tools.
# Find a plugin dir that has it and feed it to swiftc via -plugin-path so the
# SwiftUI navigation/toolbar code compiles. (AppKit-only code never needs this.)
PLUGIN_DIR=""
for d in \
  "$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
  "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" \
  "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"; do
  if [ -f "$d/libSwiftUIMacros.dylib" ]; then PLUGIN_DIR="$d"; break; fi
done
PLUGIN_ARGS=()
if [ -n "$PLUGIN_DIR" ]; then
  PLUGIN_ARGS=(-plugin-path "$PLUGIN_DIR")
  echo "SwiftUI macros plugin: $PLUGIN_DIR"
else
  echo "WARNING: libSwiftUIMacros.dylib not found (need Xcode installed); SwiftUI @State code may fail to compile." >&2
fi

echo "Compiling ($ARCH)…"
swiftc -O -swift-version 5 -parse-as-library \
  -target "${ARCH}-apple-macosx26.0" \
  -framework AppKit -framework QuartzCore -framework CoreServices \
  "${PLUGIN_ARGS[@]}" \
  "$DIR/Skelf.swift" \
  -o "$APP/Contents/MacOS/Skelf"

# Ad-hoc sign so the locally-built app launches cleanly.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
