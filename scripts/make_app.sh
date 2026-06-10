#!/bin/bash
# Builds AdbBrowse.app into ./build — a double-clickable Mac app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/ADB Browser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AdbBrowse "$APP/Contents/MacOS/AdbBrowse"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>AdbBrowse</string>
    <key>CFBundleIdentifier</key>      <string>local.adbbrowse</string>
    <key>CFBundleName</key>            <string>ADB Browser</string>
    <key>CFBundleDisplayName</key>     <string>ADB Browser</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
echo "Run it with:  open \"$APP\""
