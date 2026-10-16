# macOS Agent Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the verified Mac Agent, raster input and single-preview work into development without regressing the merged RUM feature or Windows shared-core support.

**Architecture:** Keep the existing Mac UI/Engine mapping and shared C++ rendering path. Merge the coordinator-confirmed development only after PR #53 has landed, retaining that target's shared core verbatim. Resolve Mac integration issues locally and validate the affected combinations before opening one development PR.

**Tech Stack:** Swift/SwiftUI/AppKit, shared C++ C ABI, ImageIO, CMake, existing shell/native test harnesses.

**Spec:** `docs/phase-one.md`, `docs/integration-workflow.md`, `docs/verification-agent-v08.md`; merged RUM contract `docs/superpowers/specs/2026-10-16-rum-analytics.md` at `435feda`.

## Global Constraints

- Resume `/Users/xupeng/.codex/worktrees/bb72/rawtools`, `feature/agent-complete-edits`; preserve frozen `82946eb4d3c99b0e6edffdc868c3c393539fc2e2` and its evidence.
- Do not merge a moving target before the coordinator supplies the PR #53 merge SHA.
- Windows owner owns `lutools/**` during prerequisite integration. Do not remove WIC, Windows UTF-8 CLI, platform capabilities or Windows fixture selection.
- Mac owner writes `RawLabMac/**` and this feature's documentation only. No Windows, Android or iOS UI changes.
- Preserve RUM opt-in, typed payloads, privacy surface, per-run batch counts and delayed termination. No SDK start, telemetry transmission, cloud configuration or user consent changes during verification.
- Default packages remain SDK-free. Local SDK build flags are private-only and rejected for Release; any local package stays under the task's `.cache/tmp/`.
- Never overwrite the dirty main checkout, another worktree, user edit records or original photos. Do not take over an occupied desktop session.
- Push/create one PR targeting development only after gates pass. Coordinator owns merge; no main, tags or release.

## Review Focus

- A successful JPEG/PNG import counts once after a usable preview; corrupt input and parameter rerenders do not add import events.
- Restoring a photo or generating Agent JSON does not masquerade as a user film selection; explicit FilmDock clicks keep the typed event.
- A mixed RAW/raster batch reports only this run's published successes and attempted failures; retry/cancel preserves its existing outcome rules.
- Draft confirmation, failed save and delayed SDK shutdown retain exactly-once termination replies.
- Shared-core integration must not make Mac raster processing use RAW WB/exposure baselines or remove Windows decoder/capability/Unicode support.

## Task 1: Prepare Integration Boundaries

**Files:** Read-only Mac/shared diffs; update this plan and `docs/verification-agent-v08.md`.

**Interfaces:** Frozen Mac feature `82946eb`; current target `435feda`; prerequisite PR #53 `7061b65` before its RUM conflict repair. No implementation handoff yet.

- [x] Verify the current worktree/branch, frozen logs and direct user authorization in the coordination chat.
- [x] Refresh development and PR refs. PR #57 is merged as `435feda`; #53 remains open at `7061b65`.
- [x] Read the RUM contract, `UsageAnalytics`, Mac lifecycle, explicit film selection and batch event wiring.
- [x] Analyze `82946eb` + `435feda` with `git merge-tree --write-tree`: exit 0, analysis tree `aa0865efa44e33213a919208f18d1127ebba962c`; no index/worktree/branch merge occurred.
- [x] Record the focused script/link audit below; hand the preparation snapshot to coordination before waiting for the prerequisite.

### Prepared File And Link Audit

The Mac feature adds 27 paths relative to `acfc4ae` (production, localization and tests). They have not been included in development yet; their absence there is not a deletion by RUM.

- Preserve the feature additions in `AgentRecipe.swift`, `Engine.swift`, `FileLibrary.swift`, `AdjustmentDock.swift`, `MacGeometryWorkspace.swift`, `EditorView.swift` and the photo-related model/menu/copy changes.
- Semantic overlaps with RUM are `EditorModel.swift`, `BatchExportModel.swift` and `RawLabMacApp.swift`. The merge analysis keeps both sides, but event timing/counts need actual combination tests.
- Take the target's unchanged `FilmDock.swift` (`model.selectFilm(id)`), `AboutView.swift` (consent/privacy), `MacGeometryWindowGuard.swift` (deferred shutdown), `AliyunRUMTransport.swift`, `RUMPCConfiguration.swift` and Shared usage files, not old full-file snapshots from this branch.
- `agent-recipe-render.sh` and `raster-render.sh` do not compile `EditorModel`/`BatchExportModel`; they need no extra RUM source or vendor library. `single-preview-interaction.sh` already compiles all Shared sources and excludes the production app entrypoint, so its default isolated harness remains SDK-free.
- Preserve RUM's `UsageAnalytics.swift` additions to `edit-model.sh`, `batch-render.sh`, `denoise-model.sh`, `look-import-model.sh`, `batch-import-presentation.sh` and `photo-effects-presentation.sh`. Do not duplicate a Shared source in scripts already using `Shared/*.swift`.
- Inspect/fix the explicit source/link closure in `RawLabMac/tests/usage-model.sh`: it currently lacks the feature's master/HSL/geometry/crop source dependencies and Lensfun/TIFF link flags. This is a Mac harness change, not a CMake/ABI change.
- `RawLabMac/build.sh` and `tests/bundle.sh` must retain the target's local flag/Release guard, task-local output restriction, loader-relative vendor dependency handling and exact GPL linking-exception copy. Do not transplant old scripts wholesale.

## Task 2: Integrate The Confirmed Shared-Core Target

**Files:** Mac production files listed below, this feature's docs; shared files only to retain the coordinator-confirmed target version.

**Interfaces:** `RenderEngine.agentRecipe(_:settings:lut:output:exportLongEdge:) -> Data`; `EditorModel.init(..., onUsage: (UsageEvent) -> Void)`; `BatchExportModel.init(job:journal:onUsage:)`; `EditorModel.selectFilm(_:)`.

- [x] Receive the PR #53 merge SHA, fetch development again and verify it contains that SHA. Record actual source/head/target before edits.
- [x] Merge the confirmed target into the existing source branch; enumerate actual conflicts, if any. Do not blanket-select ours/theirs for Mac files.
- [x] Retain target `lutools/**`, including Windows WIC, Unicode CLI and cross-platform capability declarations. Confirm `git diff <target> -- lutools` is empty; refer any required shared semantic change back to coordination.
- [x] Keep `AgentRecipe.swift`, raster `Engine.swift` input adapter, generic photo entry points, persistence, batch freezing and RAW-only control guards.
- [x] In `EditorModel.swift` preserve `onUsage`, pending-import completion and `attachBatch` callback injection alongside generic image opening and raster restore/error isolation.
- [x] In `BatchExportModel.swift` preserve per-run attempted/succeeded/failed accounting alongside supported image selection and rendering.
- [x] Preserve `RawLabMacApp.swift` usage lifecycle/local flag and change only the photo menu copy needed by this feature. Preserve `FilmDock.selectFilm`, `AboutView` privacy and `MacGeometryWindowGuard` termination logic.
- [x] Preserve `EditorView` compare=false and reset-on-file only; rerenders and history must not write compare state.
- [x] Inspect Mac build/link and affected test source lists. Use existing local dependency paths; add only missing Mac sources/libraries, with no shared build abstraction or core rewrite.

Actual integration: target `7da15e57b1f2178d12cabc823c249dc589578547`, merge commit
`5a4ead49de6e5007aaf2244d8d26498d2ce1c77a`. All six conflicts were in `lutools`;
the explicitly assigned shared owner required retaining the target tree. Mac/RUM files merged
without text conflicts. The target diff for `lutools`, Shared and all non-Mac platforms is empty.

## Task 3: Validate The Integrated Mac Combinations

**Files:** `RawLabMac/tests/UsageModelTests.swift`, its script, affected Mac test scripts and verification report. Production fixes only for demonstrated integration failures.

**Interfaces:** Inject private `onUsage` collectors, test-owned stores and fake transports. Existing rendering tests continue to use the shared C ABI/CLI and exact PNG comparisons.

- [x] Add regression-first raster cases to the usage/model harness: corrupt input adds no success, JPEG/PNG adds one event, rerender/restore does not add film clicks, explicit built-in/custom/neutral selections emit safe kinds, mixed batch and failed retry count only this run. Run new assertions before any necessary production fix; do not manufacture a failure when the composed behavior already works.
- [x] Build the default app: `bash RawLabMac/build.sh`. Run `bash RawLabMac/tests/bundle.sh` against the actual bundle and verify default dynamic closure contains no RUM SDK.
- [x] Run affected core tests from the freshly configured Mac target, including display decode/render, recipe/parser/schema/commands and RAW coverage. Record test count and any optional missing fixtures, never infer a pass from a skip.
- [x] Run `agent-recipe-render.sh <read-only-RAW> <current-CLI>` and `raster-render.sh <read-only-RAW> <current-CLI>`; require same-condition GUI/Agent/Batch FINAL and preview results with existing tolerances unchanged.
- [x] Run `edit-model.sh`, `batch-export.sh`, `presentation.sh`, `localization.sh`, `test_single_preview.py` and affected batch render/presentation tests after source/link changes.
- [x] Run `Shared/tests/usage-analytics.sh`, `Shared/tests/usage-transport.sh`, Mac `rum-local.sh`, `usage-model.sh <RAW>`, and `usage-termination.sh` (default/local fake SDK).
- [x] Run the privacy presentation harness only without stealing a desktop: use a task-owned unshown window or obtain a concrete desktop handoff first. Verify the default unavailable/opt-in surface; do not change real consent.
- [x] If local SDK linkage is affected, build a private local bundle only and verify exact bundled notices/SDK and Release-flag rejection. Do not launch that bundle or send events.
- [x] Preserve the 2026-10-15 CUA interaction evidence for unchanged compare logic. Inspect the integrated diff; repeat only state combinations whose code changed, using the isolated harness and a free/handed-off desktop.
- [ ] Run an independent read-only integration review, fix confirmed defects with focused RED/GREEN checks, and append source-bound results/limits to the report.

Validation limits: the unchanged local-SDK linkage was not rebuilt; default SDK-free closure,
fake-SDK termination and the Release/local flag rejection were checked. The unchanged look-import
sheet was compiled with `batch-import-presentation.sh <output-directory> --compile-only` after fixing its stale
source list; physical sheet interaction is **NOT REACHED**, not a runtime pass. Privacy uses an
unshown task-owned window, not desktop interaction. See the verification report for exact source,
commands, retained failed attempts and logs.

## Task 4: Deliver One Mac PR

**Files:** Only owned source/test/docs changes; no RAW, credentials, SDKs, screenshots or generated artifacts.

**Interfaces:** Existing source branch -> latest confirmed development; coordinator consumes PR URL, exact head/base and evidence.

- [ ] Check diff, owned staged paths and a clean worktree; make scoped local commits. Recheck target drift and rerun only affected gates.
- [ ] Query existing PRs for `feature/agent-complete-edits`; reuse a matching open PR rather than creating a duplicate.
- [ ] Push without force. For GitHub maintenance calls, use command-scoped owner authentication if required; do not switch global gh auth or expose/persist tokens.
- [ ] Create/update the development PR with changes, current-source verification, historical CUA scope, RUM preservation and unverified platform/SDK boundaries. Attach the created PR with the app tool.
- [ ] Verify remote head, current target, mergeability and exact-head CI/status. Empty CI is not success. Report URL/head/target/evidence to coordination; do not merge.
