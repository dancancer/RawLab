#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?Pass an isolated output directory}"
mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/probe.XXXXXX")"
SERVER=""
trap 'if [ -n "$SERVER" ]; then kill "$SERVER" 2>/dev/null || true; wait "$SERVER" 2>/dev/null || true; fi; rm -rf "$STAGE"' EXIT
APP="$STAGE/SparkleSignatureProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$STAGE/home" "$STAGE/tmp"
FRAMEWORK="$(bash "$ROOT/RawLabMac/prepare-sparkle.sh")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
swiftc -parse-as-library -swift-version 5 -warnings-as-errors -sdk "${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" \
    -F "$(dirname "$FRAMEWORK")" -framework Sparkle -framework AppKit \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$ROOT/RawLabMac/tests/SparkleSignatureTests.swift" -o "$APP/Contents/MacOS/SparkleSignatureProbe"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
python3 - "$STAGE" > "$OUT/server.log" 2>&1 <<'PY' &
import http.server,pathlib,sys
root=pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data=b'<?xml version="1.0"?><rss version="2.0"><channel><title>Unsigned offline fixture</title></channel></rss>'
        self.send_response(200);self.send_header('Content-Type','application/xml');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
(root/'port').write_text(str(server.server_port));server.serve_forever()
PY
SERVER=$!
for attempt in $(seq 1 100); do [ -f "$STAGE/port" ] && break; sleep 0.05; done
python3 - "$APP" "$(cat "$STAGE/port")" <<'PY'
import pathlib,plistlib,sys,uuid
app=pathlib.Path(sys.argv[1]);port=sys.argv[2]
plist={'CFBundleIdentifier':'dev.rawlab.sparkle-signature-probe.'+uuid.uuid4().hex,'CFBundleExecutable':'SparkleSignatureProbe','CFBundlePackageType':'APPL',
       'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','LSBackgroundOnly':True,'SUFeedURL':f'http://127.0.0.1:{port}/appcast.xml',
       'SUPublicEDKey':'eRFPLZuNM6m8bltmtpPX4fzKbufI1z6rKJHtgIIsllk=','SURequireSignedFeed':True,'SUVerifyUpdateBeforeExtraction':True,
       'SUSignedFeedFailureExpirationInterval':0,'SUEnableAutomaticChecks':False,'SUAutomaticallyUpdate':False,'SUAllowsAutomaticUpdates':False,
       'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
PY
codesign --force --deep --sign - "$APP" >/dev/null
CFFIXED_USER_HOME="$STAGE/home" TMPDIR="$STAGE/tmp" "$APP/Contents/MacOS/SparkleSignatureProbe"
