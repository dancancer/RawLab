#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLab/tests/lib/ios-harness.sh"
rawlab_ios_host_init
rawlab_ios_make_temp_dir OUT rawlab-ios-presentation
rawlabkit_flags link "$OUT/swiftpm" macos 0
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library -whole-module-optimization \
    "$ROOT/RawLab/tests/EditorPresentationTests.swift" \
    -o "$OUT/presentation"
"$OUT/presentation"

python3 - "$ROOT/RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift" "$OUT/MakeBaseRequestSlice.swift" <<'PY'
import pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"(    func makeBaseRequest\(settings: RawSettings, inputType: sony2fuji_input_type\) -> sony2fuji_request \{.*?\n    \})", src, re.S)
assert m, "Could not locate makeBaseRequest in Sony2FujiProcessor+Helpers.swift"
out = """import Foundation
import RawLabKit

struct Sony2FujiProcessor {
""" + m.group(1) + "\n}\n"
pathlib.Path(sys.argv[2]).write_text(out, encoding="utf-8")
PY
cat > "$OUT/MakeBaseRequestTests.swift" <<'SWIFT'
import Foundation
import RawLabKit

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

@main
struct MakeBaseRequestTests {
    static func main() {
        let processor = Sony2FujiProcessor()
        var rasterEdited = RawSettings.default
        rasterEdited.whiteBalanceMode = .camera
        rasterEdited.masterRecipeID = nil
        rasterEdited.temperature = 5400
        rasterEdited.tint = 12
        let rasterReq = processor.makeBaseRequest(settings: rasterEdited, inputType: SONY2FUJI_INPUT_DISPLAY_BUFFER)
        check(rasterReq.wb_mode == SONY2FUJI_WB_CAMERA &&
              rasterReq.temperature == 6500 &&
              rasterReq.tint == 0,
              "iOS makeBaseRequest keeps SONY2FUJI_WB_CAMERA at 6500/0 for edited SDR raster relative WB")

        var rawCamera = rasterEdited
        let rawCameraReq = processor.makeBaseRequest(settings: rawCamera, inputType: SONY2FUJI_INPUT_RAW)
        check(rawCameraReq.wb_mode == SONY2FUJI_WB_CAMERA &&
              rawCameraReq.temperature == 6500 &&
              rawCameraReq.tint == 0,
              "iOS makeBaseRequest keeps SONY2FUJI_WB_CAMERA at 6500/0 for RAW camera WB")

        var rawCustom = rasterEdited
        rawCustom.whiteBalanceMode = .custom
        let rawCustomReq = processor.makeBaseRequest(settings: rawCustom, inputType: SONY2FUJI_INPUT_RAW)
        check(rawCustomReq.wb_mode == SONY2FUJI_WB_TEMPERATURE &&
              rawCustomReq.temperature == 5400 &&
              rawCustomReq.tint == 12,
              "iOS makeBaseRequest forwards temperature/tint for RAW custom WB")
    }
}
SWIFT
rawlab_ios_host_swiftc "${RAWLABKIT_SWIFTC_FLAGS[@]}" -parse-as-library \
    -import-objc-header "$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_c.h" \
    "$OUT/MakeBaseRequestSlice.swift" "$OUT/MakeBaseRequestTests.swift" \
    -o "$OUT/make-base-request-tests"
"$OUT/make-base-request-tests"

bash "$ROOT/RawLab/tests/viewing-state.sh"
