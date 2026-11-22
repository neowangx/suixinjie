#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build
xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
    -module-cache-path build/.module-cache \
    Sources/Capture.swift Sources/Editor.swift Sources/HotKeys.swift Sources/Settings.swift Sources/Updater.swift \
    Tests/Verify.swift -o build/verify
build/verify
