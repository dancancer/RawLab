#!/bin/bash
set -euo pipefail

: "${CAMERA_BUILD_DIR:?Set CAMERA_BUILD_DIR to an absolute temporary directory}"
case "$CAMERA_BUILD_DIR" in /*) ;; *) echo 'CAMERA_BUILD_DIR must be absolute' >&2; exit 2;; esac
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
CAMERA_JAVA_HOME="${CAMERA_JAVA_HOME:-$(/usr/libexec/java_home -v 17)}"
CAMERA_KEYSTORE="${CAMERA_KEYSTORE:-$HOME/.android/debug.keystore}"
PROTOCOL_DIR="$SOURCE_DIR/../../../RawLabAndroid/app/src/main/java/com/rawlab/android/camera/protocol"
BUILD_TOOLS="$ANDROID_SDK_ROOT/build-tools/35.0.0"
ANDROID_JAR="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
mkdir -p "$CAMERA_BUILD_DIR/classes" "$CAMERA_BUILD_DIR/dex" "$CAMERA_BUILD_DIR/tests"
"$CAMERA_JAVA_HOME/bin/javac" -d "$CAMERA_BUILD_DIR/tests" \
    "$PROTOCOL_DIR/SonyWifiCredentials.java" "$SOURCE_DIR/WifiPayloadTest.java" \
    "$PROTOCOL_DIR/SonyMobileSession.java" "$SOURCE_DIR/MobilePTPTest.java"
"$CAMERA_JAVA_HOME/bin/java" -cp "$CAMERA_BUILD_DIR/tests" com.rawlab.android.camera.protocol.WifiPayloadTest
"$CAMERA_JAVA_HOME/bin/java" -cp "$CAMERA_BUILD_DIR/tests" com.rawlab.android.camera.protocol.MobilePTPTest
"$CAMERA_JAVA_HOME/bin/javac" --release 8 -classpath "$ANDROID_JAR" -d "$CAMERA_BUILD_DIR/classes" \
    "$SOURCE_DIR"/src/app/rawlab/cameraconnect/*.java "$PROTOCOL_DIR"/*.java
"$CAMERA_JAVA_HOME/bin/jar" cf "$CAMERA_BUILD_DIR/classes.jar" -C "$CAMERA_BUILD_DIR/classes" .
JAVA_HOME="$CAMERA_JAVA_HOME" "$BUILD_TOOLS/d8" --min-api 29 --lib "$ANDROID_JAR" \
    --output "$CAMERA_BUILD_DIR/dex" "$CAMERA_BUILD_DIR/classes.jar"
"$BUILD_TOOLS/aapt2" link --manifest "$SOURCE_DIR/AndroidManifest.xml" -I "$ANDROID_JAR" -o "$CAMERA_BUILD_DIR/base.apk"
(cd "$CAMERA_BUILD_DIR/dex" && zip -q "$CAMERA_BUILD_DIR/base.apk" classes.dex)
"$BUILD_TOOLS/zipalign" -f 4 "$CAMERA_BUILD_DIR/base.apk" "$CAMERA_BUILD_DIR/aligned.apk"
if [ ! -f "$CAMERA_KEYSTORE" ]; then
    mkdir -p "$(dirname "$CAMERA_KEYSTORE")"
    "$CAMERA_JAVA_HOME/bin/keytool" -genkeypair -keystore "$CAMERA_KEYSTORE" -storepass android \
        -keypass android -alias androiddebugkey -dname 'CN=RawLab Camera Experiment' -keyalg RSA -keysize 2048 -validity 30 >/dev/null 2>&1
fi
JAVA_HOME="$CAMERA_JAVA_HOME" "$BUILD_TOOLS/apksigner" sign --ks "$CAMERA_KEYSTORE" --ks-pass pass:android \
    --key-pass pass:android --out "$CAMERA_BUILD_DIR/CameraConnect.apk" "$CAMERA_BUILD_DIR/aligned.apk"
JAVA_HOME="$CAMERA_JAVA_HOME" "$BUILD_TOOLS/apksigner" verify "$CAMERA_BUILD_DIR/CameraConnect.apk"
echo "$CAMERA_BUILD_DIR/CameraConnect.apk"
