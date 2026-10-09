#!/bin/bash
# Builds build/LILO.app, a native macOS app (SwiftUI + CoreBluetooth) to read and set the LILO.
# It declares Bluetooth usage itself, so it works whatever terminal launched the build.
#
# Usage: scripts/make-macos-app.sh && open build/LILO.app
# Requires the Xcode command line tools (swiftc). macOS 14 or later.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/LILO.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# macos/icon.png is a full-bleed 1024px rounded square: shrink it to the 824px macOS icon
# grid, then render every iconset size.
ICONSET=$(mktemp -d)/LILO.iconset
mkdir -p "$ICONSET"
sips -Z 824 macos/icon.png --out "$ICONSET/base.png" >/dev/null
sips -p 1024 1024 "$ICONSET/base.png" --out "$ICONSET/base.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z $size $size "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICONSET/base.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/LILO.icns"

# English strings are the source keys; an empty en.lproj declares English as supported.
cp -R macos/*.lproj "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/en.lproj"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIdentifier</key><string>com.github.laurent-d.lilo-ble</string>
    <key>CFBundleName</key><string>LILO</string>
    <key>CFBundleExecutable</key><string>LILO</string>
    <key>CFBundleIconFile</key><string>LILO</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$(node -p 'require("./package.json").version')</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>LILO controls the LILO indoor garden over Bluetooth.</string>
</dict>
</plist>
EOF

swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14" \
    -o "$APP/Contents/MacOS/LILO" macos/LiloApp.swift

codesign --force --sign - "$APP"
echo "Built $APP"
