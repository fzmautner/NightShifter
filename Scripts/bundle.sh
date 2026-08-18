#!/usr/bin/env bash
# Assemble the SwiftPM executable into a .app. MenuBarExtra needs a real bundle (and LSUIElement
# to stay out of the Dock); SwiftPM alone only produces a bare binary.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/NightShifter.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/NightShifter"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NightShifter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NightShifter</string>
  <key>CFBundleDisplayName</key><string>NightShifter</string>
  <key>CFBundleIdentifier</key><string>dev.mautner.NightShifter</string>
  <key>CFBundleExecutable</key><string>NightShifter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu-bar-only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature. CoreBrightness is resolved with dlopen at runtime, so no private entitlement
# or .tbd stub is needed and an ad-hoc signature is enough to launch locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
