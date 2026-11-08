#!/bin/bash
# Used by the native Apple harnesses that compile the product rendering adapters.
HDR_SWIFT_SOURCES=(
    "$ROOT/Shared/AdjustmentTransfer.swift"
    "$ROOT/Shared/HDRAdjustmentTransfer.swift"
    "$ROOT/Shared/HDRRecipe.swift"
    "$ROOT/Shared/HDRDisplay.swift"
    "$ROOT/Shared/Native/HDRRequest.swift"
    "$ROOT/Shared/Native/HDRSource.swift"
    "$ROOT/Shared/Native/ProRAWSource.swift"
    "$ROOT/Shared/Native/ProRAWExport.swift"
    "$ROOT/Shared/Native/HDRImage.swift"
    "$ROOT/Shared/Native/HDRPresentation.swift"
    "$ROOT/Shared/Native/HDRCanvas.swift"
    "$ROOT/Shared/Native/HDRMonitoring.swift"
)
