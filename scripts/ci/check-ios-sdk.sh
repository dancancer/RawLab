#!/bin/bash
set -euo pipefail

# Duo 的完整屏幕适配取决于构建 SDK，最低部署版本仍为 iOS 18.0。
if [[ $# == 0 ]]; then set -- iphoneos iphonesimulator; fi
for sdk in "$@"; do
    if ! version="$(xcrun --sdk "$sdk" --show-sdk-version)"; then
        printf 'error: Cannot discover iOS SDK %s. Select full Xcode 27.1+ with DEVELOPER_DIR.\n' "$sdk" >&2
        exit 1
    fi
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
        major=${BASH_REMATCH[1]}
        minor=${BASH_REMATCH[2]}
        if (( 10#$major > 27 || (10#$major == 27 && 10#$minor >= 1) )); then
            printf 'iOS SDK: %s %s (requires 27.1+)\n' "$sdk" "$version"
            continue
        fi
    fi
    printf 'error: RawLab requires iOS SDK 27.1+ for iPhone Duo; %s reports "%s". Select Xcode 27.1+ with DEVELOPER_DIR. The deployment target remains iOS 18.0.\n' "$sdk" "$version" >&2
    exit 1
done
