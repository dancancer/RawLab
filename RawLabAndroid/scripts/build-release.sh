#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${ANDROID_HOME:?Set ANDROID_HOME to your Android SDK}"
KEYSTORE="${RAWLAB_RELEASE_KEYSTORE:?Set the release keystore path outside the repository}"
PASSWORD="${RAWLAB_RELEASE_PASSWORD_FILE:?Set the private keystore password file path}"
ALIAS="${RAWLAB_RELEASE_KEY_ALIAS:-rawlab-android-release}"
TOOLS="$SDK/build-tools/35.0.0"
OUTPUT="$ROOT/app/build/outputs/apk/release/RawLab-Android-release.apk"
# 正式包默认必须带使用统计 SDK（先运行 scripts/fetch-rum-sdk.sh）；只有离线打包才显式设为 false
RUM="${RAWLAB_RUM_RELEASE:-true}"
test -r "$KEYSTORE"
test -r "$PASSWORD"
"$ROOT/gradlew" -p "$ROOT" -PrawlabRumRelease="$RUM" :app:assembleRelease
UNSIGNED="$ROOT/app/build/outputs/apk/release/app-release-unsigned.apk"
if [[ "$RUM" == true ]] && ! unzip -Z1 "$UNSIGNED" lib/arm64-v8a/libproducer.so > /dev/null 2>&1; then
  printf 'Release APK is missing the Aliyun RUM SDK; refusing to sign it.\n' >&2
  exit 2
fi
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
"$TOOLS/zipalign" -f -P 16 4 "$UNSIGNED" "$TEMP/aligned.apk"
"$TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" \
  --ks-pass "file:$PASSWORD" --debuggable-apk-permitted false \
  --out "$OUTPUT" "$TEMP/aligned.apk"
"$TOOLS/apksigner" verify --verbose --print-certs "$OUTPUT"
bash "$ROOT/scripts/check-native.sh" "$OUTPUT"
printf 'Signed release: %s\n' "$OUTPUT"
