#!/bin/bash
# 本地/发布前手工 UI 检查（依赖 macOS 辅助功能 AXUIElement 授权，CI 不执行）。
# 三态闸与 Mac UI 套件共用 ax-gate.sh（契约见 docs/process/ci.md 与 PR #311）：
# AX 在场真跑；无 AX 且设 RAWLAB_REQUIRE_AX 则 FAIL exit 1；无 AX 未设档 SKIP exit 0。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/RawLabMac/tests/ax-gate.sh"
rawlab_ax_gate
OUT="$(mktemp -d "${TMPDIR:-/tmp}/rawlab-ios-reset-entry-ui.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -swift-version 5 -sdk "$SDK" \
    -target "$(uname -m)-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -module-cache-path "${RAWLAB_TRANSFER_MODULE_CACHE:-$OUT/module-cache}" \
    "$ROOT/Shared/Localization.swift" "$ROOT/Shared/HSLSettings.swift" "$ROOT/Shared/GeometrySettings.swift" \
    "$ROOT/Shared/HDRSettings.swift" "$ROOT/Shared/ProcessingMigration.swift" "$ROOT/Shared/ToneControlsSettings.swift" \
    "$ROOT/Shared/AtmosphereSettings.swift" "$ROOT/Shared/ColorGradingSettings.swift" "$ROOT/Shared/ToneCurveSettings.swift" \
    "$ROOT/Shared/AdjustmentTransfer.swift" "$ROOT/Shared/HDRAdjustmentTransfer.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/RawSettings.swift" "$ROOT/RawLab/RawLab/Core/Persistence/CachedPhotoFile.swift" \
    "$ROOT/RawLab/RawLab/Core/Persistence/EditPersistence.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/AdjustmentKind.swift" "$ROOT/RawLab/RawLab/Core/Models/EditorAdjustmentRules.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransfer.swift" "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransferValues.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/IOSAdjustmentTransferWB.swift" \
    "$ROOT/RawLab/RawLab/Core/Models/EditorToolDraft.swift" \
    "$ROOT/RawLab/RawLab/Core/ViewModel/EditorResetTransaction.swift" \
    "$ROOT/RawLab/RawLab/UI/EditorState/EditorWorkspaceResetControl.swift" \
    "$ROOT/RawLab/tests/IOSResetEntryUITests.swift" \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -o "$OUT/test"
"$OUT/test"
