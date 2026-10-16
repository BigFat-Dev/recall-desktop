#!/bin/bash
# Copyright (C) 2026 BigFat-Dev
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "Tests require an Apple Silicon Mac and a native arm64 terminal." >&2
    exit 1
fi
xcrun --find swiftc >/dev/null
recall_python="${RECALL_PYTHON:-$(command -v python3 || true)}"
if [[ -z "$recall_python" || ! -x "$recall_python" ]]; then
    echo "Python 3 is required for the synthetic mock service. Set RECALL_PYTHON to its executable." >&2
    exit 1
fi
"$recall_python" -c 'import sys; assert sys.version_info >= (3, 8), "Python 3.8+ required"'
export RECALL_PYTHON="$recall_python"
mkdir -p build/module-cache build/tests
recall_test_dir="$(mktemp -d "$PWD/build/tests/run.XXXXXX")"
trap 'rm -rf "$recall_test_dir"' EXIT
export RECALL_CODEX_PATH="$PWD/Tests/mock-codex"
export RECALL_DESKTOP_DATA_DIR="$recall_test_dir/app-data"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    -module-cache-path "$PWD/build/module-cache" \
    -framework AppKit -framework ApplicationServices -framework Carbon \
    Sources/Core.swift Sources/History.swift Sources/Clipboard.swift Sources/Native.swift Tests/Tests.swift \
    -o build/tests/core-tests
build/tests/core-tests "$recall_test_dir"
xcrun swiftc -D RECALL_TESTING -swift-version 5 -target arm64-apple-macosx14.0 \
    -disable-sandbox -module-cache-path "$PWD/build/module-cache" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Carbon \
    Sources/Core.swift Sources/History.swift Sources/Clipboard.swift Sources/Native.swift Sources/AppIcon.swift Sources/App.swift Tests/ModelTests.swift \
    -o build/tests/model-tests
build/tests/model-tests "$recall_test_dir"
