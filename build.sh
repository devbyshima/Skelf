#!/usr/bin/env bash
# Compile the Sources/Skelf/*.swift sources into a runnable Skelf.app bundle (no Xcode
# project). For development you can also `swift build` or open Package.swift in Xcode.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/Skelf.app"
SRCDIR="$DIR/Sources/Skelf"
RES="$DIR/Resources"
ARCH="$(uname -m)"   # arm64 on Apple Silicon

# Version — the single source of truth for the app's version. SKELF_VERSION is the public
# (marketing) version, SemVer; SKELF_BUILD is a monotonic build number, bumped each release
# build. Both are written into Info.plist below and read back at runtime by Bundle+Skelf.swift
# (skelfShortVersion / skelfBuildVersion) and surfaced via `Skelf --version`.
SKELF_VERSION="1.3.0"
SKELF_BUILD="5"

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
  <key>CFBundleShortVersionString</key><string>${SKELF_VERSION}</string>
  <key>CFBundleVersion</key><string>${SKELF_BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# App-packaging asset: the icon (Resources/Skelf.icns, from Resources/AppIcon/…1024@1x.png).
[ -f "$RES/Skelf.icns" ] && cp "$RES/Skelf.icns" "$APP/Contents/Resources/Skelf.icns"
# Runtime resources live with the target (Sources/Skelf/Resources/) so SwiftPM/Xcode bundle
# them too (Bundle.module); build.sh copies them into Skelf.app (Bundle.main). See Bundle+Skelf.swift.
RUNRES="$SRCDIR/Resources"
# Menu-bar icon: the Skelf mark (loaded as a vector template image at runtime).
[ -f "$RUNRES/skelf.svg" ] && cp "$RUNRES/skelf.svg" "$APP/Contents/Resources/skelf.svg"
# Per-skill public-domain painting map (skill id → artwork URL); optional — the app
# generates a themed fallback for any skill not listed.
[ -f "$RUNRES/art-map.json" ] && cp "$RUNRES/art-map.json" "$APP/Contents/Resources/art-map.json"

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
  -framework AppKit -framework QuartzCore -framework CoreServices -framework CryptoKit \
  -framework FoundationModels \
  "${PLUGIN_ARGS[@]}" \
  "$SRCDIR"/*.swift \
  -o "$APP/Contents/MacOS/Skelf"

# Compile the SwiftUI Metal shaders (Shaders.metal) into the app's default.metallib so
# SwiftUI's ShaderLibrary can load them at runtime (the ripple effect on the artwork popup).
# swiftc above only compiles *.swift; the .metal file needs the Metal toolchain.
METAL_SRC="$SRCDIR/Shaders.metal"
if [ -f "$METAL_SRC" ]; then
  if xcrun -sdk macosx metal -o "$DIR/Skelf.air" -c "$METAL_SRC" 2>/dev/null \
     && xcrun -sdk macosx metallib "$DIR/Skelf.air" -o "$APP/Contents/Resources/default.metallib" 2>/dev/null; then
    echo "Built default.metallib (Metal shaders)"
  else
    echo "WARNING: Metal shader compile failed; the ripple effect will be inert." >&2
  fi
  rm -f "$DIR/Skelf.air"
fi

# Ad-hoc sign so the locally-built app launches cleanly. Skelf is a single binary, so --deep
# is unnecessary (and Apple deprecates it for signing). Released builds are also ad-hoc/unsigned;
# see the README "Install" section for the macOS first-launch (Gatekeeper) approval step.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
