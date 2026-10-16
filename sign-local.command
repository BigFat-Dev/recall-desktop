#!/bin/bash
# Copyright (C) 2026 BigFat-Dev
# SPDX-License-Identifier: MIT
set -euo pipefail
cd "$(dirname "$0")"
recall_app="${1:-$PWD/build/Recall Desktop.app}"
if [[ ! -f "$recall_app/Contents/Info.plist" ]]; then
    echo "Application bundle not found. Run ./build.command first." >&2
    exit 1
fi
# '-' is ad-hoc signing: useful for local builds, not a notarized distribution.
# An existing local identity may be selected without storing any secret here.
recall_identity="${RECALL_SIGNING_IDENTITY:--}"
if [[ "${RECALL_DISTRIBUTION:-0}" == 1 ]]; then
    if [[ "$recall_identity" != "Developer ID Application: "* ]]; then
        echo "Distribution signing requires your Developer ID Application identity, not ad-hoc or a local development identity." >&2
        exit 1
    fi
    recall_args=(--force --sign "$recall_identity" --options runtime --timestamp)
else
    recall_args=(--force --sign "$recall_identity" --timestamp=none)
fi
if [[ -n "${RECALL_SIGNING_KEYCHAIN:-}" ]]; then
    if [[ "$recall_identity" == - ]]; then
        echo "Choose an identity before specifying a signing keychain." >&2
        exit 1
    fi
    recall_args+=(--keychain "$RECALL_SIGNING_KEYCHAIN")
fi
/usr/bin/codesign "${recall_args[@]}" "$recall_app"
/usr/bin/codesign --verify --strict "$recall_app"
if [[ "$recall_identity" == - ]]; then
    echo "Ad-hoc development signature: rebuilds may require Accessibility reauthorization."
fi
