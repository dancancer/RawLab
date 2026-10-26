#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAGE=$(mktemp -d /tmp/rawlab-trust-integration.XXXXXX)
KEYCHAIN="$STAGE/test.keychain-db"
cleanup() { security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true; rm -rf "$STAGE"; }
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$STAGE/key.pem" -out "$STAGE/cert.pem" -days 1 -subj '/CN=RawLab isolated update test' -addext 'extendedKeyUsage=codeSigning' -addext 'keyUsage=digitalSignature' >/dev/null 2>&1
openssl pkcs12 -export -legacy -macalg sha1 -inkey "$STAGE/key.pem" -in "$STAGE/cert.pem" -out "$STAGE/identity.p12" -passout pass:rawlab >/dev/null 2>&1
security create-keychain -p rawlab-isolated-test "$KEYCHAIN" >/dev/null
security unlock-keychain -p rawlab-isolated-test "$KEYCHAIN"
security import "$STAGE/identity.p12" -k "$KEYCHAIN" -P rawlab -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k rawlab-isolated-test "$KEYCHAIN" >/dev/null
IDENTITY=$(openssl x509 -in "$STAGE/cert.pem" -fingerprint -sha1 -noout | cut -d= -f2 | tr -d :)
FINGERPRINT=$(openssl x509 -in "$STAGE/cert.pem" -fingerprint -sha256 -noout | cut -d= -f2 | tr -d :)
APP="$STAGE/RawLab.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
printf 'int main(void) { return 0; }\n' > "$STAGE/main.c"
printf 'int value(void) { return 42; }\n' > "$STAGE/helper.c"
clang "$STAGE/main.c" -o "$APP/Contents/MacOS/RawLab"
clang -dynamiclib "$STAGE/helper.c" -o "$APP/Contents/Frameworks/libtest.dylib"
python3 - "$APP" "$FINGERPRINT" <<'PY'
import sys,plistlib,pathlib,platform
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
plistlib.dump(dict(CFBundleIdentifier='com.rawtools.rawlab.mac',CFBundleExecutable='RawLab',CFBundlePackageType='APPL',CFBundleVersion='1',SUFeedURL='https://github.com/dancancer/RawLab/releases/latest/download/appcast-arm64.xml',SUPublicEDKey='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',RawLabUpdateCertificateSHA256=sys.argv[2],RawLabUpdateArchitecture=platform.machine(),SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0),p.open('wb'))
PY
if [ -n "${RAWLAB_TEST_SIGN_SCRIPT:-}" ]; then
    RAWLAB_RELEASE=1 RAWLAB_CODESIGN_IDENTITY="$IDENTITY" RAWLAB_CODESIGN_KEYCHAIN="$KEYCHAIN" \
        RAWLAB_UPDATE_CERTIFICATE_SHA256="$FINGERPRINT" bash "$RAWLAB_TEST_SIGN_SCRIPT" "$APP"
else
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$APP/Contents/Frameworks/libtest.dylib"
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$APP"
fi
cat > "$STAGE/test.swift" <<'SWIFT'
import Foundation
@main struct Test {
 static func main() throws {
  let bundle = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
  let expected = CommandLine.arguments[2]
  do {
   let trust = try MacUpdateTrust.configured(bundle: bundle)
   try trust.validateHost()
   if expected != "accept" { fatalError("Invalid bundle was trusted: \(expected)") }
   print("PASS: valid self-signed bundle accepted without spctl")
  } catch {
   if expected == "accept" { throw error }
   print("PASS: \(expected) rejected")
  }
 }
}
SWIFT
swiftc -swift-version 5 "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/MacUpdateTrust.swift" "$STAGE/test.swift" -o "$STAGE/test"
"$STAGE/test" "$APP" accept
cp -R "$APP" "$STAGE/AdHoc.app"
codesign --force --sign - "$STAGE/AdHoc.app"
"$STAGE/test" "$STAGE/AdHoc.app" ad-hoc
cp -R "$APP" "$STAGE/Mismatch.app"
/usr/libexec/PlistBuddy -c "Set :RawLabUpdateCertificateSHA256 $(printf '%064d' 0)" "$STAGE/Mismatch.app/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$STAGE/Mismatch.app"
"$STAGE/test" "$STAGE/Mismatch.app" certificate-mismatch
printf 'tampered' >> "$APP/Contents/Frameworks/libtest.dylib"
"$STAGE/test" "$APP" tampered-nested-code
