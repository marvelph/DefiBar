#!/bin/sh
set -eu
cd "$(dirname "$0")"

swift build -c release "$@"
bin_dir=$(swift build -c release "$@" --show-bin-path)
app="$PWD/.build/DefiBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DefiBar" "$app/Contents/MacOS/DefiBar"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.defibar.app</string>
    <key>CFBundleName</key>
    <string>DefiBar</string>
    <key>CFBundleExecutable</key>
    <string>DefiBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.4</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
