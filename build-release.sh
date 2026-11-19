#!/bin/sh
set -eu
cd "$(dirname "$0")"

if [ "$#" -ne 2 ] || ! printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
   ! printf '%s\n' "$2" | grep -Eq '^[1-9][0-9]*$'; then
    echo "Usage: $0 <version such as 0.5.0> <increasing integer build number>" >&2
    exit 1
fi

version=$1
build_number=$2
tag="v$version"
release_url="https://github.com/marvelph/DefiBar/releases"
tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
output="$PWD/.build/releases/$tag"
if [ -e "$output" ]; then
    echo "Release output already exists at $output." >&2
    exit 1
fi
if [ ! -x "$tools/generate_keys" ] || [ ! -x "$tools/generate_appcast" ]; then
    swift package resolve
fi

public_key=$("$tools/generate_keys" --account DefiBar -p)
mkdir -p "$PWD/.build/releases"
stage=$(mktemp -d "$PWD/.build/releases/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
assets="$stage/assets"
mkdir "$assets"

DEFI_BAR_VERSION="$version" DEFI_BAR_BUILD_NUMBER="$build_number" \
    SPARKLE_PUBLIC_ED_KEY="$public_key" SPARKLE_FEED_URL="$release_url/latest/download/appcast.xml" \
    DEFI_BAR_OUTPUT_DIR="$stage/build" \
    ./build-app.sh --arch arm64 --arch x86_64

app="$stage/build/DefiBar.app"
case "$(lipo -archs "$app/Contents/MacOS/DefiBar")" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *) echo "The release build must support both arm64 and x86_64." >&2; exit 1 ;;
esac
ditto -c -k --keepParent "$app" "$assets/DefiBar-$tag.zip"
"$tools/generate_appcast" --account DefiBar --maximum-deltas 0 \
    --download-url-prefix "$release_url/download/$tag/" "$assets"
test -s "$assets/appcast.xml"
mv "$assets" "$output"
printf '%s\n' "$output"
