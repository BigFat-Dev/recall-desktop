#!/bin/bash
# Copyright (C) 2026 BigFat-Dev
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")"
recall_root="$PWD"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "Build requires an Apple Silicon Mac and a native arm64 terminal." >&2
    exit 1
fi
xcrun --find swiftc >/dev/null
# Native icon compilation needs full Xcode; tested toolchain is documented.
if ! xcrun --find actool >/dev/null 2>&1; then
    echo "Native icon compiler not found. Select full Xcode, not Command Line Tools only; see README." >&2
    exit 1
fi
recall_build="$recall_root/build"
mkdir -p "$recall_build/module-cache"
recall_stage="$(mktemp -d "$recall_build/stage.XXXXXX")"
trap 'rm -rf "$recall_stage"' EXIT
recall_app="$recall_stage/Recall Desktop.app"
mkdir -p "$recall_app/Contents/MacOS" "$recall_app/Contents/Resources"
cp Resources/Info.plist "$recall_app/Contents/Info.plist"
cp LICENSE NOTICE "$recall_app/Contents/Resources/"
cp Resources/RecallLight.icns Resources/RecallDark.icns "$recall_app/Contents/Resources/"
xcrun actool Resources/Recall.icon --compile "$recall_app/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --app-icon Recall \
    --output-partial-info-plist "$recall_stage/icon-info.plist" \
    --standalone-icon-behavior all --output-format human-readable-text --warnings --errors
/usr/libexec/PlistBuddy -c "Merge '$recall_stage/icon-info.plist'" "$recall_app/Contents/Info.plist"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    -disable-sandbox -O -module-cache-path "$recall_build/module-cache" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Carbon \
    Sources/Core.swift Sources/History.swift Sources/Clipboard.swift Sources/Native.swift Sources/AppIcon.swift Sources/App.swift \
    -o "$recall_app/Contents/MacOS/RecallDesktop"
./sign-local.command "$recall_app"
/usr/bin/plutil -lint "$recall_app/Contents/Info.plist"
# Replace generated output only after compilation and signature verification.
rm -rf "$recall_build/Recall Desktop.app"
mv "$recall_app" "$recall_build/Recall Desktop.app"
echo "Built: build/Recall Desktop.app (arm64, local development build)"
