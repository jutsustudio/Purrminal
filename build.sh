#!/bin/bash
# Builds Purrminal.app (menu-bar-less agent app, ad-hoc signed) and dist/Purrminal.zip for releases.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
APP=Purrminal.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
swiftc -O -swift-version 5 main.swift settings.swift -o "$APP/Contents/MacOS/Purrminal"
cp -R sprites "$APP/Contents/Resources/sprites"
cp install.sh purrminal-hook.sh "$APP/Contents/Resources/"  # for the Install hooks button
cp icon/AppIcon.icns "$APP/Contents/Resources/"            # regenerate: python3 icon/make_icon.py icon/source.png

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Purrminal</string>
  <key>CFBundleDisplayName</key><string>Purrminal</string>
  <key>CFBundleIdentifier</key><string>app.purrminal</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Purrminal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
rm -f dist/Purrminal.zip
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" dist/Purrminal.zip  # no ._ AppleDouble files
echo "built $APP and dist/Purrminal.zip ($VERSION)"
