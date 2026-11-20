#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/lib/compile.sh"
rawlab_mac_test_init
rawlab_mac_make_temp_dir _STAGE_RAW rawlab-trust-integration
STAGE="$(cd "$_STAGE_RAW" && pwd -P)"
KEYCHAIN="$STAGE/test.keychain-db"
PREV_KEYCHAINS=()
while IFS= read -r kc; do
    kc="${kc#"${kc%%[![:space:]]*}"}"
    kc="${kc%\"}"
    kc="${kc#\"}"
    [ -n "$kc" ] && PREV_KEYCHAINS+=("$kc")
done < <(security list-keychains -d user)
cleanup() {
    if [ "${#PREV_KEYCHAINS[@]}" -gt 0 ]; then
        security list-keychains -d user -s "${PREV_KEYCHAINS[@]}" >/dev/null 2>&1 || true
    else
        security list-keychains -d user -s >/dev/null 2>&1 || true
    fi
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rawlab_mac_cleanup_temp_dirs
}
trap cleanup EXIT
PKCS12_FLAGS=()
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
    PKCS12_FLAGS=(-legacy)
fi
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$STAGE/key.pem" -out "$STAGE/cert.pem" -days 1 -subj '/CN=RawLab isolated update test' -addext 'extendedKeyUsage=codeSigning' -addext 'keyUsage=digitalSignature' >/dev/null 2>&1
openssl pkcs12 -export ${PKCS12_FLAGS[@]+"${PKCS12_FLAGS[@]}"} -macalg sha1 -inkey "$STAGE/key.pem" -in "$STAGE/cert.pem" -out "$STAGE/identity.p12" -passout pass:rawlab >/dev/null 2>&1
security create-keychain -p rawlab-isolated-test "$KEYCHAIN" >/dev/null
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p rawlab-isolated-test "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" ${PREV_KEYCHAINS[@]+"${PREV_KEYCHAINS[@]}"}
security import "$STAGE/identity.p12" -k "$KEYCHAIN" -P rawlab -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k rawlab-isolated-test "$KEYCHAIN" >/dev/null
IDENTITY=$(openssl x509 -in "$STAGE/cert.pem" -fingerprint -sha1 -noout | cut -d= -f2 | tr -d :)
if ! security find-identity -p codesigning "$KEYCHAIN" | grep -Fq "$IDENTITY"; then
    security find-identity -p codesigning "$KEYCHAIN" >&2
    printf 'error: primary test signing identity %s missing from %s\n' "$IDENTITY" "$KEYCHAIN" >&2
    exit 1
fi
FINGERPRINT=$(openssl x509 -in "$STAGE/cert.pem" -fingerprint -sha256 -noout | cut -d= -f2 | tr -d :)
APP="$STAGE/RawLab.app"
rawlab_mac_swiftc "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/MacUpdateTrust.swift" \
    "$ROOT/RawLabMac/Sources/System/Updates/MacUpdatePackage.swift" "$ROOT/RawLabMac/tests/MacUpdatePackageTests.swift" -o "$STAGE/package-test"
PUBLIC_KEY=$("$STAGE/package-test" public-key)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
printf 'int main(void) { return 0; }\n' > "$STAGE/main.c"
printf 'int value(void) { return 42; }\n' > "$STAGE/helper.c"
rawlab_mac_clang "$STAGE/main.c" -o "$APP/Contents/MacOS/RawLab"
rawlab_mac_clang -dynamiclib "$STAGE/helper.c" -o "$APP/Contents/Frameworks/libtest.dylib"
python3 - "$APP" "$FINGERPRINT" "$PUBLIC_KEY" <<'PY'
import sys,plistlib,pathlib,platform
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
plistlib.dump(dict(CFBundleIdentifier='com.rawtools.rawlab.mac',CFBundleExecutable='RawLab',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',SUFeedURL='https://github.com/dancancer/RawLab/releases/latest/download/appcast-arm64.xml',SUPublicEDKey=sys.argv[3],RawLabUpdateCertificateSHA256=sys.argv[2],RawLabUpdateArchitecture=platform.machine(),SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0),p.open('wb'))
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
rawlab_mac_swiftc "$ROOT/RawLabMac/Sources/System/Updates/UpdateState.swift" "$ROOT/RawLabMac/Sources/System/Updates/UpdateAdapter.swift" "$ROOT/RawLabMac/Sources/System/Updates/MacUpdateTrust.swift" "$STAGE/test.swift" -o "$STAGE/test"
"$STAGE/test" "$APP" accept
ditto -c -k --keepParent "$APP" "$STAGE/trusted.zip"
"$STAGE/package-test" "$APP" "$STAGE/trusted.zip" accept
"$STAGE/package-test" "$APP" "$STAGE/trusted.zip" signature

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$STAGE/other-key.pem" -out "$STAGE/other-cert.pem" -days 1 -subj '/CN=RawLab wrong update signer' -addext 'extendedKeyUsage=codeSigning' -addext 'keyUsage=digitalSignature' >/dev/null 2>&1
openssl pkcs12 -export ${PKCS12_FLAGS[@]+"${PKCS12_FLAGS[@]}"} -macalg sha1 -inkey "$STAGE/other-key.pem" -in "$STAGE/other-cert.pem" -out "$STAGE/other.p12" -passout pass:rawlab >/dev/null 2>&1
security import "$STAGE/other.p12" -k "$KEYCHAIN" -P rawlab -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k rawlab-isolated-test "$KEYCHAIN" >/dev/null
OTHER_IDENTITY=$(openssl x509 -in "$STAGE/other-cert.pem" -fingerprint -sha1 -noout | cut -d= -f2 | tr -d :)
if ! security find-identity -p codesigning "$KEYCHAIN" | grep -Fq "$OTHER_IDENTITY"; then
    security find-identity -p codesigning "$KEYCHAIN" >&2
    printf 'error: secondary test signing identity %s missing from %s\n' "$OTHER_IDENTITY" "$KEYCHAIN" >&2
    exit 1
fi
cp -R "$APP" "$STAGE/OtherSigner.app"
codesign --force --sign "$OTHER_IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$STAGE/OtherSigner.app"
codesign --verify --deep --strict "$STAGE/OtherSigner.app"
ditto -c -k --keepParent "$STAGE/OtherSigner.app" "$STAGE/other.zip"
"$STAGE/package-test" "$APP" "$STAGE/other.zip" identity
cp -R "$APP" "$STAGE/AdHoc.app"
codesign --force --sign - "$STAGE/AdHoc.app"
"$STAGE/test" "$STAGE/AdHoc.app" ad-hoc
cp -R "$APP" "$STAGE/Mismatch.app"
/usr/libexec/PlistBuddy -c "Set :RawLabUpdateCertificateSHA256 $(printf '%064d' 0)" "$STAGE/Mismatch.app/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --timestamp=none "$STAGE/Mismatch.app"
"$STAGE/test" "$STAGE/Mismatch.app" certificate-mismatch
printf 'tampered' >> "$APP/Contents/Frameworks/libtest.dylib"
"$STAGE/test" "$APP" tampered-nested-code
ditto -c -k --keepParent "$APP" "$STAGE/tampered.zip"
"$STAGE/package-test" "$APP" "$STAGE/tampered.zip" identity
