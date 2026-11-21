#!/bin/bash
# Used by the Mac app harnesses that compile the full product source set:
# every RawLabMac/Sources file plus every Shared Swift file. The harnesses
# glob RawLabMac/Sources and pass MAC_SHARED_SWIFT_SOURCES below instead of
# their own Shared/*.swift glob: the Shared top level stays globbed so files
# added there are picked up automatically, but Shared/Native needs this
# explicit list. HDRPresentation, HDRDisplayState and HDRCameraProfileAssetStore
# (ab9be520, 6f940269) broke every harness that hardcoded its list once
# Engine.swift, EditorView.swift and MacEditedPhotoPreviews.swift started
# referencing them. Keep this covering all of Shared/Native:
# scripts/ci/test_mac_native_sources.py fails on drift, so a new file costs
# one line in this list instead of one per harness.
# Harnesses that pass these sources must bridge against sony2fuji_hdr.h, not
# sony2fuji_c.h: Shared/Native reaches the HDR C ABI, and the HDR header is a
# superset that includes sony2fuji_c.h itself (same choice as the native HDR
# harnesses sourced by Shared/tests/hdr-native-sources.sh).
MAC_NATIVE_SWIFT_SOURCES=(
    # Paired with the top-level Shared/ProcessingMigration.swift that
    # full-source harnesses pass through the glob below; subset harnesses
    # compile both or neither.
    "$ROOT/Shared/Native/ProcessingMigrationNative.swift"
    "$ROOT/Shared/Native/HDRRequest.swift"
    "$ROOT/Shared/Native/HDRSource.swift"
    "$ROOT/Shared/Native/ProRAWSource.swift"
    "$ROOT/Shared/Native/ProRAWExport.swift"
    "$ROOT/Shared/Native/HDRImage.swift"
    "$ROOT/Shared/Native/HDRPresentation.swift"
    "$ROOT/Shared/Native/HDRCanvas.swift"
    "$ROOT/Shared/Native/HDRMonitoring.swift"
)
MAC_SHARED_SWIFT_SOURCES=(
    "$ROOT"/Shared/*.swift
    "${MAC_NATIVE_SWIFT_SOURCES[@]}"
)
MAC_NATIVE_BRIDGING_HEADER="$ROOT/lutools/include/sony2fuji/ffi/sony2fuji_hdr.h"
