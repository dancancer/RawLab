# Fixed Style and Editable Tone Regions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local, fixed-style tone-region experiment to the existing macOS AI candidate workflow and verify fixed versus manually adapted results on authorized RAW samples before considering KNN.

**Architecture:** Keep `AIColorRecipe` version 1 and its 40 style parameters unchanged. Add four separately validated source-adaptation boundaries to the native compiler and candidate state; compile the resolved transform to the existing display-sRGB CUBE contract. Editing those boundaries never calls AI or changes the frozen style, exposure or white balance.

**Tech Stack:** Existing C++17 core, Swift/SwiftUI/AppKit, native test scripts, local sample rendering.

**Spec:** User-approved proposal in this chat, plus `docs/superpowers/specs/2026-10-09-macos-ai-color-match-design.md` and `lutools/docs/color-contract.md`. The additions below define the first experiment only.

## Global Constraints

- Stay on the current `codex/macos-ai-color-match` checkout because the required AI implementation is uncommitted here. Preserve unrelated dirty files; do not commit, push, deploy or create a worktree that omits the current implementation.
- No KNN training, automatic threshold prediction, new remote services, new photo uploads, camera calibration, spatial masks or changes to the existing Hamada v1/v2/v3 artifacts.
- RAW and reference originals remain read-only. Existing exposure, camera WB, neutral rendering and detail settings remain unchanged.
- The adaptation coordinate is Oklab lightness after the fixed style's tone/hue-lightness stages and before three-region toning, matching the existing native ordering.
- The four boundaries are `shadowStart`, `shadowEnd`, `highlightStart`, `highlightEnd`, defaults `0.2, 0.6, 0.4, 0.8`.
- Boundaries must be finite and in `[0,1]`; each interval is at least `0.05` wide, shadow start is not after highlight start, and shadow end is not after highlight end. Permit a middle plateau or overlapping falloffs. Use a documented small numeric tolerance only for float interval comparisons.
- Preserve native compile v1/40-parameter behavior. Native compile v2 accepts the same 40 style values plus 4 boundaries; this is not a change to the AI response JSON schema.
- Preserve the 65/129-grid serialized native round-trip gate, maximum channel error `0.02`, and sanitized static CUBE export semantics.
- A numeric pass does not establish a preferred style. The experiment must distinguish changed color-region placement from proven visual improvement.

## Task 1: Native Adaptation Contract

**Files:**
- Modify: `lutools/include/sony2fuji/color_recipe.h`
- Modify: `lutools/src/core/color_recipe.cpp`
- Modify: relevant compile documentation in `lutools/include/sony2fuji/ffi/sony2fuji_c.h`
- Test: `lutools/tests/color_recipe_tests.cpp`

**Interface:** Existing `sony2fuji_compile_color_look(version, parameters, count, destination, report)` remains ABI-compatible. Version 2 takes 44 floats. `ColorRecipe::fromParameters` stores 40 style values plus a separate four-boundary array.

- [x] Add failing tests that v2/44 with default boundaries agrees with v1 within floating-point tolerance, non-default boundaries change a nonzero-toning recipe, and zero-toning identity remains identity for every valid boundary choice.
- [x] Add rejection tests for NaN, out-of-domain values, reversed/too-narrow intervals, crossed shadow/highlight ordering, and wrong version/shape. Keep old v1 tests unchanged.
- [x] Build and run the native recipe target to confirm expected rejection of the new valid v2 cases before implementation.
- [x] Implement bounded parsing and replace only the fixed `smooth(.2,.6,L)` / `smooth(.4,.8,L)` arguments. Retain double default literals for v1 compatibility.
- [x] Verify nonnegative normalized region weights using representative boundary sets and dense lightness samples through the actual transform; verify endpoints and CUBE error gating remain intact.

## Task 2: Local Candidate State and Provenance

**Files:**
- Modify: `RawLabMac/Sources/AIColorRecipe.swift` (separate `AIToneRegions` value type)
- Modify: `RawLabMac/Sources/AIColorLook.swift`
- Modify: `RawLabMac/Sources/AIColorMatchModel.swift`
- Modify: `RawLabMac/Sources/AIService.swift` only for accurate prior-candidate context
- Test: `RawLabMac/tests/AIDataTests.swift`, `RawLabMac/tests/AIWorkflowTests.swift`

**Interfaces:**
```swift
struct AIToneRegions: Codable, Equatable {
    var shadowStart: Double
    var shadowEnd: Double
    var highlightStart: Double
    var highlightEnd: Double
    static let standard: AIToneRegions
    var parameters: [Float] { get }
    func validated() throws -> Self
}
// Existing callers retain the default behavior.
AIColorLook.compile(recipe: AIColorRecipe, model: String,
                    regions: AIToneRegions = .standard) throws -> AIColorLook
```

- [x] Test regions independently from the style decoder; keep the existing strict 40-parameter AI JSON contract.
- [x] Test default and adapted compiler bridging, private metadata retaining both style and boundaries, and public export stripping both private records.
- [x] Add model tests for local region changes preserving `recipe`, no additional HTTP requests, equal-strength fixed/adapted comparison, cancellation retaining the last valid candidate, and pending/failed adaptations not being applied or exported as current.
- [x] Implement debounced local preview changes using existing cancellation/revision guards. Keep an immutable default-region look per generated style and render its comparison at the same strength as the adapted look.
- [x] Network generation still replaces the style once per user action and resets region adaptation to standard. If the prior candidate used adjusted regions, include those values in the request context rather than falsely describing its preview as default-region rendering.
- [x] Keep saved CUBE metadata sufficient to inspect/reproduce this experiment, without promising a new automatic-adaptation library or restoring an editable preset across launches in this phase.

## Task 3: Native Candidate Controls

**Files:**
- Modify: `RawLabMac/Sources/AIColorMatchView.swift`
- Optional focused view file only if it keeps the existing sheet readable.

**Interface:** Four bounded native sliders/numeric readouts, reset icon, and `固定分区` comparison selection consume the model's region state and matching fixed preview.

- [x] Read the Impeccable craft floor before editing UI. Retain the existing dark native sheet, bottom controls, SF Symbols, photo proportions and no right inspector.
- [x] Use a compact disclosure for the four boundaries. Derive slider ranges from the current valid intervals, not arbitrary clamping in the native compiler.
- [x] Disable apply/export when displayed adaptation does not match the validated candidate; allow retry/reset after failure. Cancellation restores the controls to the last successful candidate.
- [x] Verify at compact and ordinary macOS sheet sizes using a local fixture/harness if necessary. Do not send a new real AI request only to populate a screenshot.

## Task 4: Controlled Experiment and Verification

**Files:**
- Create a focused driver and reproducible configuration under `experiments/ai-color-match/`.
- Update: `lutools/docs/color-contract.md`, `RawLabMac/README.md` for actual implemented semantics.
- Create: `docs/verification-adaptive-tone-regions-2026-10-10.md`.
- Generated outputs: `output/adaptive-tone-regions/` only.

- [x] Use one nonzero-toning fixed style for fixed/manual-boundary comparisons. Do not claim moving boundaries can change a zero-toning style or adapt the existing HLS Hamada CUBE.
- [x] Render a bounded subset of already authorized RAW samples covering foliage, white buildings, sea/snow and portrait. Keep WB, EV, style values and strength identical between arms. Record boundaries and native bake reports beside outputs.
- [x] Produce side-by-side evidence and, where helpful, tonal-region coverage summaries. Label hand-set values as experiment settings, not learned ground truth.
- [x] Run affected native tests and the repo-required core gate (`bash lutools/test.sh` / configured Mac `ctest` as applicable), Mac AI data/workflow/render checks, relevant real-RAW CPU/Metal parity, and `bash RawLabMac/build.sh`.
- [x] Inspect UI once, fix concrete defects in one batch, and confirm. Do not start an open-ended visual review loop.
- [x] Record whether manual adaptation visibly improves all, some or none of the tested scenes. Do not train KNN until manually confirmed labels and an independent scene-level evaluation exist.
- [x] Report delivered controls, actual checks and experiment conclusions; no commit/push unless requested.
