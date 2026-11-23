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

python3 - "$ROOT/RawLab/RawLab/UI/Camera/IOSCameraController.swift" "$OUT/IOSCameraLayoutPolicySlice.swift" <<'PY'
import pathlib, re, sys
src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"(enum IOSCameraLayoutPolicy: Sendable \{.*?\n\})", src, re.S)
assert m, "Could not locate IOSCameraLayoutPolicy in IOSCameraController.swift"
out = "import CoreGraphics\nimport Foundation\n\n" + m.group(1) + "\n"
pathlib.Path(sys.argv[2]).write_text(out, encoding="utf-8")
PY
cat > "$OUT/IOSCameraLayoutPolicyTests.swift" <<'SWIFT'
import CoreGraphics
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

@main
struct IOSCameraLayoutPolicyTests {
    static func main() {
        check(IOSCameraLayoutPolicy.gridColumns(forWidth: 390) == 3, "iPhone portrait uses 3 columns")
        check(IOSCameraLayoutPolicy.gridColumns(forWidth: 599) == 3, "Sub-600pt width uses 3 columns")
        check(IOSCameraLayoutPolicy.gridColumns(forWidth: 600) == 4, "600pt width uses 4 columns")
        check(IOSCameraLayoutPolicy.gridColumns(forWidth: 899) == 4, "899pt width uses 4 columns")
        check(IOSCameraLayoutPolicy.gridColumns(forWidth: 900) == 5, "900pt+ width uses 5 columns")

        let visible = ["vis-1", "vis-2"]
        var selection: Set<String> = ["hidden-a", "vis-1"]
        check(!IOSCameraLayoutPolicy.allVisibleSelected(visibleIDs: visible, selection: selection),
              "allVisibleSelected is false when part of visible subset is unselected")

        IOSCameraLayoutPolicy.toggleVisibleSelection(visibleIDs: visible, selection: &selection)
        check(selection == ["hidden-a", "vis-1", "vis-2"],
              "toggleVisibleSelection selects missing visible IDs while preserving hidden selection")
        check(IOSCameraLayoutPolicy.allVisibleSelected(visibleIDs: visible, selection: selection),
              "allVisibleSelected becomes true after selecting visible IDs")

        IOSCameraLayoutPolicy.toggleVisibleSelection(visibleIDs: visible, selection: &selection)
        check(selection == ["hidden-a"],
              "toggleVisibleSelection deselects only visible IDs while keeping hidden selection")

        IOSCameraLayoutPolicy.toggleVisibleSelection(visibleIDs: [], selection: &selection)
        check(selection == ["hidden-a"], "Empty visible scope leaves selection untouched")

        let noTokens = IOSCameraLayoutPolicy.activeFilterTokens(
            format: "all", day: nil, onlySelected: false, selectedLabel: "Selected"
        )
        check(noTokens.isEmpty, "Default filter state emits zero active filter tokens")

        let tokens = IOSCameraLayoutPolicy.activeFilterTokens(
            format: "raw", day: "2026-11-23", onlySelected: true, selectedLabel: "Selected"
        )
        check(tokens == ["RAW", "2026-11-23", "Selected"],
              "Active filters emit format, day, and selected-only summary tokens")
    }
}
SWIFT
rawlab_ios_host_swiftc -parse-as-library \
    "$OUT/IOSCameraLayoutPolicySlice.swift" "$OUT/IOSCameraLayoutPolicyTests.swift" \
    -o "$OUT/ios-camera-layout-policy-tests"
"$OUT/ios-camera-layout-policy-tests"

bash "$ROOT/RawLab/tests/viewing-state.sh"
