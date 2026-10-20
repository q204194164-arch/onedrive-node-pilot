#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/build/OneDrive 选线.app"
MODULE_CACHE="${TMPDIR:-/tmp}/onedrive-pilot-module-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 -module-cache-path "$MODULE_CACHE" Sources/Engine.swift Sources/App.swift -o "$APP/Contents/MacOS/OneDrivePilot" -framework SwiftUI -framework AppKit -framework SystemConfiguration -framework Security -framework ServiceManagement
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$MODULE_CACHE" Sources/LaunchWatcher.swift -o "$APP/Contents/MacOS/OneDriveLaunchWatcher" -framework AppKit
/usr/bin/codesign --force --sign - "$APP/Contents/MacOS/OneDriveLaunchWatcher"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.onedrivepilot</string>
<key>CFBundleName</key><string>OneDrive 选线</string>
<key>CFBundleDisplayName</key><string>OneDrive 选线</string>
<key>CFBundleExecutable</key><string>OneDrivePilot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP"
echo "$APP"
