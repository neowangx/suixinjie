#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
output="${1:-$PWD/build/随心截.app}"
architecture="${SUIXINJIE_MAC_ARCH:-$(uname -m)}"
case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'Unsupported macOS architecture: %s\n' "$architecture" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$output")"
temporary="$(mktemp -d "$(dirname "$output")/.build.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
bundle="$temporary/随心截.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors -O -whole-module-optimization -parse-as-library \
    -module-cache-path "$(dirname "$output")/.module-cache" \
    -target "$architecture-apple-macosx14.0" Sources/*.swift -o "$bundle/Contents/MacOS/Suixinjie"
codesign --force --sign "${SIGN_IDENTITY:--}" "$bundle"
codesign --verify --strict "$bundle"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$bundle/Contents/MacOS/Suixinjie" "$output/Contents/MacOS/Suixinjie.new"
mv -f "$output/Contents/MacOS/Suixinjie.new" "$output/Contents/MacOS/Suixinjie"
cp "$bundle/Contents/Info.plist" "$output/Contents/Info.plist"
cp "$bundle/Contents/Resources/AppIcon.icns" "$output/Contents/Resources/AppIcon.icns"
if [[ -d "$bundle/Contents/_CodeSignature" ]]; then
    mkdir -p "$output/Contents/_CodeSignature"
    cp "$bundle/Contents/_CodeSignature/CodeResources" "$output/Contents/_CodeSignature/CodeResources"
fi
codesign --verify --strict "$output"
printf '%s\n' "$output"
