# Edit Memory and Batch Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Use test-first changes and preserve all existing work. Do not commit or publish.

**Goal:** Ship per-photo local edit persistence and snapshot-based batch RAW export on Mac, Windows, Android and iOS, with aligned mobile adjustment behavior.

**Architecture:** Each native client owns its edit store, immutable batch settings snapshot, durable task journal and native presentation. Existing C/C++ render and metadata contracts remain unchanged. Batch work calls the existing full-resolution exporter serially and never updates target edit records. The platform tasks share behavior, not a new binary or network API.

**Tech Stack:** SwiftUI/AppKit/Foundation, SwiftUI/Photos, Kotlin/Compose/Android storage APIs, C#/WPF/System.Text.Json, existing C ABI.

**Spec:** `docs/design/2026-10-09-edit-memory-batch-export/README.md`; approved screenshots and `index.html` in the same directory.

**Execution status:** Four native implementations are present, uncommitted. Host/build checks and Mac/Android/iOS native verification are recorded in `docs/verification-edit-memory-batch-export-2026-10-09.md`; Windows native runtime remains unavailable. The checklist below is the original gate inventory, not a claim that every platform scenario was exercised.

## Global Constraints

- Four clients, local-only records; no sidecars or cross-device sync.
- Preserve RAW originals and pre-existing dirty changes. No commit, push, release, signing-key changes or deployment.
- Keep the current feature checkout: the approved UI assets and active dependency changes live here; do not move or reset it.
- Stable original photo identity, not basename or transient copied input path. Persist settings/modes/look identity, never preview frames.
- Defaults for unseen photos, independently restored values for known photos. Failed writes stay visibly unsaved and retryable.
- Freeze source settings/look when entering batch. Never merge target edits or save batch settings into target records.
- Serial full-resolution export; success only after output storage completes. No overwrite; reserve collision-free names; clean incomplete output.
- Preserve per-target EXIF. Continue per-file failures, stop global output errors; cancel between noninterruptible operations.
- Journal success/failed/pending separately; interrupted tasks resume only with user action and required input/output access. Retry never repeats successful rows.
- iOS RAW white balance uses camera/custom pre-demosaic semantics; keep raster path separate. Android adds missing controls and native parameter mapping.
- Use native controls and the approved hierarchy, not bitmap-rendered UI. No extra dependencies unless existing native APIs cannot serve a necessary behavior.

## Task 1: Mac Persistence and Batch UI (Primary Agent)

**Files:** `RawLabMac/Sources/Adjustments.swift`, `Engine.swift` (Codable exposure mode only), `EditorModel.swift`, `EditorView.swift`, `RawLabMacApp.swift`; new `EditPersistence.swift`, `BatchExport.swift`, `BatchExportView.swift`; new tests and scripts under `RawLabMac/tests/`.

**Interfaces:** `EditPersistence` stores/restores `PhotoEditState` by verified original URL identity. `BatchExportModel` owns frozen `Adjustments`, film identity/resource, target rows, output directory/format, journal and run/cancel/retry commands. `EditorModel` only creates the batch snapshot and gates conflicting edits; render work remains serialized.

- [ ] Add a focused Swift test harness for atomic save/reload, separate same-named inputs, reset persistence and failure propagation. First assert an edit survives a new store instance:
  ```swift
  var changed = Adjustments(); changed.exposure = 0.75
  try store.save(input, state: PhotoEditState(settings: changed, filmID: "provia"))
  let reopened = try EditPersistence(directory: directory)
  try check(reopened.state(for: input)?.settings.exposure == 0.75, "edit survives restart")
  ```
- [ ] Run the failing harness, implement Codable records and atomic writes, then rerun it. Persist on completed adjustments, photo changes and normal close, with a visible failure/retry state.
- [ ] Add tests proving fixed source settings, unique output names, per-target failures, cancellation, success-preserving retry and journal recovery. Rendering is injected at the batch executor boundary so tests perform real file writes without needing a UI or camera fixture.
- [ ] Implement serial executor, journal, selected-row handling and the native two-column task window. Add exact target-preview inspection using batch settings, readonly parameter summary, folder picker, format segment and task result actions.
- [ ] Run `bash RawLabMac/tests/edit-memory.sh`, `bash RawLabMac/tests/batch-export.sh`, affected existing presentation/scheduling tests, and `bash RawLabMac/build.sh`. Capture native compact/wide states and run real-RAW single-vs-batch output comparison.

## Task 2: Windows Persistence and Batch UI

**Files:** `RawLabWindows/Adjustments.cs`, `MainWindow.xaml`, `MainWindow.xaml.cs`; new native records/executor/window files within `RawLabWindows/`; focused tests under `RawLabWindows/tests/`. Do not edit native core, shared files or packaging notices.

**Interfaces:** Native C# persistence serializes a detached settings value and look path/identity; batch model keeps source/targets separate and calls existing `RenderEngine.Render` at full resolution. Existing UI and renderer remain the integration boundaries.

- [ ] Add failing tests for restart round-trip, same filename in different directories, snapshot independence and camera/custom white balance. Keep the persistence/executor harness runnable on macOS by linking pure C# domain files when WPF execution is unavailable.
  ```csharp
  source.Set(Parameter.Exposure, 0.75);
  var snapshot = source.Clone();
  source.Set(Parameter.Exposure, -1);
  Check(snapshot[Parameter.Exposure] == 0.75, "batch snapshot cannot follow live edits");
  ```
- [ ] Implement atomic local records, restore on open, autosave/reset, saved/failed feedback and retry. External look absence is explicit, not silent neutral fallback.
- [ ] Implement target selection, frozen source summary, readonly size/collision policy, native task window, serial atomic export, cancellation, retry and durable task recovery. Keep preview calls on a separate owned renderer or the serialized owner.
- [ ] Test collision and partial-failure outputs, cancellation and restart recovery. Cross-build with `dotnet build RawLabWindows/RawLabWindows.csproj -p:EnableWindowsTargeting=true`; run native WPF checks only where a Windows runner exists and report their actual status.

## Task 3: Android Alignment, Persistence and Batch UI

**Files:** only `RawLabAndroid/app/src/main/java/com/rawlab/android/`, `app/src/main/res/values/`, necessary `app/src/main/cpp/render_request.h` / `rawlab_jni.cpp`, unit/instrumentation/native request tests. Preserve existing CMake/dependency changes.

**Interfaces:** `EditSettings` expands existing settings; native request adapter maps all parameters to the established C ABI. Original URI/photo identity enters the edit store before cache-copy creation. Batch task freezes settings/look and owns input access, destination and item status independently from current editor state.

- [ ] Add failing request tests for contrast, highlights, shadows, tone curve, saturation and sharpening mapping; add native/Kotlin assertions for signed direction and defaults. For UI +25% highlights, verify core `highlights == -0.25f`.
- [ ] Extend settings and Compose peer tool strip, sliders/numeric inputs/reset and serialization; preserve existing album layout preferences and source selection behavior.
- [ ] Add persistence tests for URI identity, restart/reset, independent photos and failed writes; implement atomic app-private records and save/retry feedback.
- [ ] Add batch tests for immutable source, row selection, cancellation, failure continuation, atomic outputs and journal recovery. Implement album/file multiselect, confirm page, full readonly settings, target effect inspection, format/destination choice, serial export and progress/result/retry.
- [ ] Directory output is selected once; album output only on supported Android versions. Retain necessary URI grants or task-owned input copies for recoverability; cleanup never deletes original input. Do not rely on cache survival.
- [ ] Run `./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug` from `RawLabAndroid`, host `request_test.cpp`, then device/instrumentation verification when available. Report exact tooling/device limitations.

## Task 4: iOS Alignment, Persistence and Batch UI

**Files:** only `RawLab/RawLab/`, `RawLab/tests/`, `RawLab/RawLabUITests/`, and necessary Xcode project entries. Do not modify shared C++/Swift files owned outside this client.

**Interfaces:** `RawSettings` persists explicit RAW white-balance mode; processor returns current RAW as-shot metadata. Import source identity includes original Photos resource ID, with a content-based fallback only where the picker cannot supply a stable identity. Batch model owns settings and RAW resources independently of the current editor source.

- [ ] Add failing tests for camera-vs-custom RAW requests and per-photo as-shot reset; preserve raster white balance separately. Verify custom RAW uses `SONY2FUJI_WB_TEMPERATURE`, camera RAW uses camera WB with neutral post-adjustment values.
- [ ] Implement the native mode control, reciprocal temperature slider, required ranges and restored/saved feedback. Do not discard existing iOS-only tools.
- [ ] Add atomic record/identity tests, implement original-resource persistence and default settings for unseen photos (remove accidental previous-photo inheritance).
- [ ] Add batch tests for source freeze, six selected/six results, cancellation/retry and success-preserving journal recovery. Implement RAW multiselect, target validation, source/target confirmation, full settings disclosure, effect inspection, serial full-resolution JPEG export and Photos completion-based success.
- [ ] Persist recoverable input references or task-owned copies outside Caches; preserve separate metadata per input and don't save output settings as target edits. UI supports reauthorization on resume and makes permission failure actionable.
- [ ] Run existing host Swift tests, build the simulator target and run relevant UI tests on an available simulator. Capture portrait/landscape and larger text once after integration.

## Task 5: Integration, Review and Documentation

**Files:** scoped client feature docs plus `docs/verification-edit-memory-batch-export-2026-10-09.md`; approved design sidecar status. No release/version churn.

- [ ] Review each client diff against the global constraints and its actual call chain. Fix evidence-backed findings only.
- [ ] Verify same-input single/batch parameter and output equivalence, original/edit-record protection, failure and interruption behavior. Distinguish unavailable native runtime checks from passing host tests/builds.
- [ ] Capture actual native UI at shipped device classes, compare with approved composition, batch material fixes once, and confirm changed views once.
- [ ] Update feature docs without overwriting unrelated edits. Record executed commands and residual platform gaps; keep work uncommitted.

## Progress and Rulings

- Execution starts on `codex/cross-platform-photo-zoom`; approved UI files are untracked and retained.
- Existing unrelated RAW compatibility/dependency/test changes are outside this plan and must not be reverted.
- Platform implementations share semantics through the existing core only, so native file ownership is disjoint. The primary agent owns Mac and final integration; platform work can proceed independently.
- Source has gained RAW noise-reduction support since the design exploration. Preserve any newly present settings in snapshots/records rather than losing them to the earlier list.
