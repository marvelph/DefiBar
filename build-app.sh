#!/bin/sh
set -eu
cd "$(dirname "$0")"

version=${DEFI_BAR_VERSION:-0.4.0}
build_number=${DEFI_BAR_BUILD_NUMBER:-4}
public_key=${SPARKLE_PUBLIC_ED_KEY:-}
feed_url=${SPARKLE_FEED_URL:-https://github.com/marvelph/DefiBar/releases/latest/download/appcast.xml}
signing_identity=${DEFI_BAR_SIGNING_IDENTITY:-}

if [ -n "$public_key" ]; then
    if [ "${#public_key}" -ne 44 ] || ! printf '%s\n' "$public_key" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
        echo "SPARKLE_PUBLIC_ED_KEY must be a base64-encoded Ed25519 public key." >&2
        exit 1
    fi
    case "$feed_url" in
        https://*) ;;
        *) echo "SPARKLE_FEED_URL must use HTTPS." >&2; exit 1 ;;
    esac
fi

swift build -c release -Xlinker -rpath -Xlinker @executable_path/../Frameworks "$@"
bin_dir=$(swift build -c release "$@" --show-bin-path)
sparkle_root=$bin_dir
while [ "$sparkle_root" != "/" ] && [ ! -f "$sparkle_root/artifacts/sparkle/Sparkle/LICENSE" ]; do
    sparkle_root=$(dirname "$sparkle_root")
done
sparkle_license="$sparkle_root/artifacts/sparkle/Sparkle/LICENSE"

output_dir=${DEFI_BAR_OUTPUT_DIR:-"$PWD/.build"}
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
app="$output_dir/DefiBar.app"
stage=$(mktemp -d "$output_dir/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
staged_app="$stage/DefiBar.app"
contents="$staged_app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Frameworks"
cp "$bin_dir/DefiBar" "$contents/MacOS/DefiBar"
ditto "$bin_dir/Sparkle.framework" "$contents/Frameworks/Sparkle.framework"
cp "$sparkle_license" "$contents/Resources/Sparkle-LICENSE.txt"
cp Support/AppIcon.icns "$contents/Resources/AppIcon.icns"
cp -R Sources/DefiBar/Resources/*.lproj "$contents/Resources/"
plist="$contents/Info.plist"
cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>org.programmershigh.defibar</string>
    <key>CFBundleName</key>
    <string>DefiBar</string>
    <key>CFBundleExecutable</key>
    <string>DefiBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.4</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
plutil -insert CFBundleShortVersionString -string "$version" "$plist"
plutil -insert CFBundleVersion -string "$build_number" "$plist"
if [ -n "$public_key" ]; then
    plutil -insert SUFeedURL -string "$feed_url" "$plist"
    plutil -insert SUPublicEDKey -string "$public_key" "$plist"
    plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$plist"
    plutil -insert SURequireSignedFeed -bool YES "$plist"
fi

if [ -n "$signing_identity" ]; then
    sparkle_framework="$contents/Frameworks/Sparkle.framework"
    sparkle_version="$sparkle_framework/Versions/Current"
    codesign --force --sign "$signing_identity" --timestamp --options runtime \
        --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
    codesign --force --sign "$signing_identity" --timestamp --options runtime \
        "$sparkle_version/XPCServices/Installer.xpc" "$sparkle_version/Autoupdate" \
        "$sparkle_version/Updater.app" "$sparkle_framework" "$staged_app"
    codesign --verify --strict \
        -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' \
        "$staged_app"
else
    codesign --force --sign - "$staged_app"
fi
codesign --verify --deep --strict "$staged_app"

if [ -e "$app" ]; then
    mv "$app" "$stage/previous.app"
fi
if ! mv "$staged_app" "$app"; then
    if [ -e "$stage/previous.app" ] && ! mv "$stage/previous.app" "$app"; then
        trap - EXIT
        echo "Previous build is at $stage/previous.app." >&2
    fi
    exit 1
fi
printf '%s\n' "$app"
