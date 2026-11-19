#!/bin/bash
# Builds SnapMark.app next to this script. Needs the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="SnapMark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SnapMark</string>
    <key>CFBundleIdentifier</key><string>local.snapmark</string>
    <key>CFBundleExecutable</key><string>SnapMark</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

swiftc -O main.swift -o "$APP/Contents/MacOS/SnapMark" \
    -framework Cocoa -framework Carbon -framework CoreImage -framework Vision
codesign --force --sign - "$APP"
echo "Built $APP"
