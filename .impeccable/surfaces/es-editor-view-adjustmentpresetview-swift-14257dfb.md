---
version: 1
slug: "es-editor-view-adjustmentpresetview-swift-14257dfb"
primary_target: "RawLabMac/Sources/Editor/View/AdjustmentPresetView.swift"
related_targets: ["RawLab/RawLab/UI/Editor/IOSAdjustmentPresetView.swift","RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/AdjustmentPresetSheet.kt","RawLabWindows/AdjustmentPresetDialogs.cs"]
---

# RawLab User Adjustment Presets

Mode: Operate. Target audience: sighted photographers at standard OS text sizes across six supported languages. This is an addition to the existing native editor across all four clients (Quick Presets inline drawer + Manage Presets sheet/dialog + unreadable-preset quarantine), governed by the preset-save, preset-manage, and scope-transfer flows without adding decorative chrome.

## Direction contract

**THESIS:** A named, independent set of adjustments (supporting both SDR and HDR scopes) can be saved and reused without altering the clipboard; application uses the same visible compatibility, preflight, and transaction history flow as paste.

**OWN-WORLD:** Preserve native dark-gray surfaces, functional yellow, system typography, continuous list rows, and platform menus/sheets. Use existing field-selection controls (`AdjustmentScopeEditor` / `AdjustmentSummaryView`) and clear state labels.

**STORY:** Open My Presets from Looks or the editor More menu to apply presets in one tap with inline Undo/Retry (`QuickPresetView`), or open Manage Presets (`AdjustmentPresetView` / `IOSAdjustmentPresetView` / `AdjustmentPresetSheet` / `AdjustmentPresetLibraryDialog`) to save committed values with an editable name and exact scope, apply to one or multiple photos, rename, or confirm overwrite/delete. Unreadable preset records are quarantined separately with explicit Delete recovery while leaving valid presets usable.

**FIRST VIEWPORT:** A title and Close/Back action, a primary Save Current Adjustments action, and a scrolling list of preset names and field counts. Each row exposes Apply and management actions. Empty, unreadable-entry, and read-failure states occupy the list area cleanly. Name and scope editing have persistent Cancel/Save actions.

**FORM:** Native code-led implementation across macOS, iOS, Android, and Windows. No concept tournament or new artwork. seed: not applicable (local extension).

**FINISH:** Verified against current four-client source code, [PRODUCT.md](../../PRODUCT.md), and [DESIGN.md](../../DESIGN.md); native verification covers long names, six languages, standard text sizes, confirmation guards, error recovery, and persistence.
