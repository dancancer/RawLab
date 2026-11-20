#!/bin/bash
# Shared Apple host SDK and deployment target helpers for macOS and iOS test harnesses.
# Avoids cross-client sourcing of macOS dependency setup in RawLabMac/build-env.sh.

rawlab_apple_host_env() {
    ARCH="${RAWLAB_ARCH:-$(uname -m)}"
    case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture: $ARCH" >&2; return 2 ;; esac
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
    if [[ ! "$MACOSX_DEPLOYMENT_TARGET" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Invalid macOS deployment target: $MACOSX_DEPLOYMENT_TARGET" >&2
        return 2
    fi
    export ARCH MACOSX_DEPLOYMENT_TARGET
}

rawlab_apple_host_env || return $?

# Resolve the macOS SDK for swiftc. The CLT 27 SDK exposes SwiftUI macros
# without shipping their compiler plugin ("plugin for module 'SwiftUIMacros'
# not found"); when xcrun resolves a CommandLineTools SDK and the CLT 26.5 SDK
# is installed, prefer it, mirroring the RawLabMac/build.sh guardrail. When
# xcrun resolves an Xcode SDK (or SDKROOT is set), keep that SDK so SwiftPM
# RawLabKit builds and swiftc use the exact same SDK.
rawlab_mac_sdk_path() {
    if [ -n "${SDKROOT:-}" ]; then
        printf '%s\n' "$SDKROOT"
        return 0
    fi
    local sdk
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    case "$sdk" in
        /Library/Developer/CommandLineTools/SDKs/*)
            if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
                sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
            fi
            ;;
    esac
    printf '%s\n' "$sdk"
}

rawlab_mac_target() {
    printf '%s-apple-macosx%s\n' "$ARCH" "$MACOSX_DEPLOYMENT_TARGET"
}
