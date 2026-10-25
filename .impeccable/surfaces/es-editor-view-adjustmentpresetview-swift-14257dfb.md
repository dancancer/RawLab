---
version: 1
slug: "es-editor-view-adjustmentpresetview-swift-14257dfb"
primary_target: "RawLabMac/Sources/Editor/View/AdjustmentPresetView.swift"
related_targets: ["RawLab/RawLab/UI/Editor/IOSAdjustmentPresetView.swift","RawLabAndroid/app/src/main/java/com/rawlab/android/editor/ui/AdjustmentPresetSheet.kt","RawLabWindows/AdjustmentPresetDialogs.cs"]
---

# RawLab user adjustment presets

Mode: Operate. This is an addition to the existing native editor, governed by ITER-04 requirements and the existing preset-save/preset-manage flows. It adds no new visual identity or rendering controls.

## Direction contract

**THESIS:** A named, independent set of adjustments can be saved and reused without altering the clipboard; application uses the same visible compatibility and history flow as paste.

**OWN-WORLD:** Preserve native gray surfaces, functional yellow, system text, continuous list rows and platform menus/sheets. Use existing field-selection controls and accessible action names.

**STORY:** Open My Presets from Looks, save committed values with an editable name and exact scope, then apply to the current photo. Rename and confirmed overwrite/delete keep identity clear. Errors retain the original file and offer retry.

**FIRST VIEWPORT:** A title and Close/Back action, a primary Save Current Adjustments action, and a scrolling list of names and field counts. Each row exposes Apply and management actions. Empty and read-failure states occupy the list area. Name and scope editing have persistent Cancel/Save actions; text and rows reflow at large sizes.

**FORM:** Local extension of the existing r9 preset-management and scope flows; native code-led implementation. No concept tournament or new artwork. seed: not applicable (local extension).

**FINISH:** unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

Review preserves DESIGN.md because this feature adds no durable visual-system change. Verification uses actual native windows and simulator/emulator captures, including long names, six languages, large text, confirmation, errors and persistence.
