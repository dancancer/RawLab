# Windows 0.8 Editor Verification

## Source And Scope

- Implementation worktree: `/Users/xupeng/.codex/worktrees/fdd7/rawtools`.
- Branch: `feature/windows-v08-editor`; base `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`.
- Approved design: `88028a1ca49fd41ccb62bab88fed343e9566a549`, `docs/design/2026-10-14-windows-v08/WINDOWS-DESIGN.md` in the read-only design worktree.
- Owned paths: `RawLabWindows/**` only. No change to Shared, lutools, another platform, root design or the release checklist. No push, PR, merge, release, version bump or Library synchronization.
- This is platform implementation evidence, not release acceptance or hosted CI.

## Implemented Behavior

- Reusable five-column parameter rows with visible fine grids, inverse-temperature mapping, local input Escape and valid-field-only wheel accumulation/rate limiting. Numeric automation exposes actual units, not normalized slider positions.
- Standard WPF caption, five native menus, empty single canvas, retained/resizable dock, scrolling tools/parameters, six languages, system text-scale resources and system high-contrast palette.
- Independent geometry/lens drafts, exact-preview Apply gate, discard/cancel and three-choice leave prompt. Native draft callbacks cannot update committed WB; invalid geometry is retained until corrected, reset or discarded.
- Crop overlay with eight handles, move, ratio presets, rotation/flip, straighten ruler and keyboard movement. Perspective uses the existing separate 16-byte PerspectiveConfig, not an invented extension to the 40-byte GeometryConfig. Every render request writes both configs, including identity.
- Save failure blocks photo switches and exposes retry. Import validates each look against the current RAW and retains partial success. Batch target preflight uses frozen settings/look, disables invalid targets and cannot replace a task while its validation is active. RAW inputs are not output destinations.

## Local Managed Verification

SDK: repository-bundled .NET 8.0.425 on macOS.

```sh
dotnet run --project RawLabWindows/tests/editing/EditWorkflow.Tests.csproj
dotnet run --project RawLabWindows/tests/denoise/DenoiseSettingsTests.csproj
dotnet run --project RawLabWindows/tests/localization/LocalizationChecks.csproj
dotnet build RawLabWindows/tests/RawLabWindows.Tests.csproj -p:EnableWindowsTargeting=true -c Release
git diff --check
```

All passed; Windows cross-build has zero warnings/errors. The macOS hard-link identity probe was explicitly skipped because its Windows-specific helper is unavailable; Windows managed execution exercises that path separately. Cross-building WPF is not WPF runtime evidence.

## Isolated Windows Evidence

Windows 11 Pro 22631 VM100, Windows Desktop Runtime 8.0.31, SDKs 8.0.425 / 9.0.318. Task-owned source, native outputs, fixtures and results are under `C:/RawLabBuild/workspaces/windows-v08-fdd7*`. No desktop automation or other platform's acceptance resource was used.

The initial `build-remote.py --test --raw <external ARW>` run built native C++ and the self-contained WPF application. All **33/33 CTest passed** in 1071.02 seconds. The legacy `build.ps1 -Test` wrapper subsequently failed with `Cannot resolve the WPF test output directory.`; its default WPF suite was **NOT REACHED** in that run. A direct WPF test build and TargetDir query succeeded. The successful full-script follow-up is recorded separately below.

Native shared source is unchanged from the base. The task-owned native DLL/ExifTool artifact is reused for platform-only incremental WPF checks; no stale RawLab managed DLL is copied over a fresh test build.

The owned runner is `tests/run-v08.ps1`. It captures per-check logs and `summary.json`, continues to record independent failures, and supports comma-separated `-Only` for affected checks. The initial targeted run passed editing, denoise-model, localization, About, editor-shell, geometry, master-recipes, rendered-dng and lens. DNG Auto/Force reported backend 3 and lens CPU/Force parity passed. It exposed two test-fixture problems: a missing DispatcherSynchronizationContext in transform-ui, and searching collapsed vignette visual descendants before expansion in photo-features. Both fixtures were repaired for the affected rerun; failures are retained in `build/windows-v08-initial-results/`.

The initial native denoise check failed at `tests/DenoiseChecks.cs:24`, `Native wavelet changes real RAW output`: the 1600px off/Clean 8-bit images were identical for this Sony fixture. The rest of that initial suite was not reached. Its test, `DenoiseSettings.Clean` and shared wavelet code were unchanged from the base; the new geometry/perspective setters run before the wavelet setter and do not write wavelet state/cache.

A same-fixture A/B probe used a private copy of the test runtime with the initial native-build workspace's managed RawLab DLL, before the new perspective setter. Its `RenderEngine.cs` matches the base exactly (SHA-256 `360e8de76c1bfe7a7c8dfa9317727c587ff77f49f96e17e886f0028d0f613bfe`); it fails at the same assertion. Evidence: `build/windows-v08-baseline-denoise.log`, remote `build/baseline-denoise-probe/probe.log`. This reproduces the failure without the new perspective binding, but is not a full clean-base acceptance run. The follow-up below establishes the exact no-op cause without changing shared code.

## Build And Denoise Follow-Up

### Confirmed Causes

- `build.ps1` was UTF-8 without BOM and contained one Chinese comment immediately before the managed test build. Windows PowerShell 5.1 on this VM decodes it using ANSI code page 936; the final multibyte punctuation consumes the line ending, so the following build command is parsed as part of the comment. The original-file AST contains zero matching executable test-build commands, whereas explicitly parsing the UTF-8 text retains it. No TargetDir fallback or platform override is needed.
- The script comment is now ASCII. `tests/BuildScriptChecks.ps1` uses the actual PowerShell file parser to require the managed test-build command and guards the script's ASCII encoding. On Windows PowerShell 5.1 / code page 936, the preserved original fails with `parsed 0`, exit 1; the fixed script passes, exit 0. Logs: remote `build/build-script-red.log` and `build/build-script-green.log`.
- The test-only Windows `windows_denoise_probe` reuses the unchanged FFI decode/resize code and links the existing core; it adds no production DLL API and is excluded from the default build. For the Sony RAW, the Clean config is accepted, `filterRuns=1`, `outputHits=0`, `analysisHits=0`; the exact 1067x1600 pre-wavelet image has `flatTiles=5`, `applied=0`, `changedFloatChannels=0`, `maxAbsDelta=0`. The core intentionally returns success without filtering below eight flat tiles (`lutools/src/core/wavelet_denoise.cpp`). This is not 8-bit quantization or stale cache. The seeded 512x512 float control has 64 flat tiles, applies filtering and changes 786432 float channels.
- The rebuilt final probe also ran against the generated Bayer DNG: ABI `changedBytes=685636`, `filterRuns=1`, no cache hits; its capped 512x512 pre-wavelet image has 64 flat tiles, `applied=1`, 786432 changed float channels and `maxAbsDelta=0.0713038`. Both final probe runs exit 0. Logs: `build/windows-v08-diagnostics/denoise-probe-fixed-real.log` and `denoise-probe-fixed-control.log`.

### Windows Test Correction

The arbitrary-photo nonzero-pixel assertion is replaced by an actual managed preview-cache invalidation assertion and an observed-pixel-change log. The nonzero-filter requirement is retained on a controlled noisy Bayer DNG through the production `RenderEngine`, independently on CPU and available Auto/Force Direct3D 11, with CPU/GPU tolerance checks. Controlled Off independently probes GPU availability, so an active Auto fallback cannot silently skip the Force regression. The original external RAW still exercises neutral-frame isolation, proxy/exact separation, disable/restore, GPU fallback/Force rejection, combined effects, native-size sixteen-bit PNG and FINAL JPEG comparisons. Both input files must retain their SHA-256 hashes.

Generate the ignored control with the existing, unchanged `lutools/tests/make_denoise_fixture.py`; the task used NumPy 2.3.5 and tifffile 2024.9.20 in an ignored test-only environment. The generated DNG hash is `7766e33b4c88a2dcabf168c7d7f17583dc5d89214892724c61d56d3eedbd49d3`. Supply `run-v08.ps1 -DenoiseRaw <path>` or the fourth `--denoise` argument; otherwise the default is `build/windows-fixtures/denoise.dng`, and a missing fixture is a failure, not a skip. Remote source archives intentionally do not carry this generated DNG; transfer or generate it explicitly in the private task workspace.

No `Shared/**` or `lutools/**` source, wavelet threshold or production RenderEngine behavior changed. The 512px active-filter control does not establish active filtering on a downscaled large RAW, and VM backend 3 is still not physical-hardware acceptance.

The optional diagnostic is built and run explicitly, with the app-local native runtime on PATH:

```powershell
cmake --build build/windows-native --config Release --target windows_denoise_probe
$env:PATH="$PWD/build/RawLab-Windows;$env:PATH"
./build/windows-native/bin/Release/windows_denoise_probe.exe 'C:/samples/photo.ARW'
```

### Follow-Up Results

- Fresh local WPF cross-build: zero warnings/errors.
- Windows `run-v08.ps1 -Only denoise -DenoiseRaw <controlled-DNG>`: fresh managed build exit 0, denoise exit 0, **42 PASS checks**. The controlled CPU, Auto and Force paths all change pixels; Auto/Force report Direct3D 11 and match CPU within two code values. The Sony viewport records `pixel change=False` as expected, and all remaining real-RAW PNG/JPEG, GPU/fallback, cache and unchanged-input checks complete. Logs and summary: `build/windows-v08-denoise-fixed-results/`.
- Actual `build-remote.py --test --raw <external ARW> --workspace <private task workspace>` / `build.ps1 -Test`: exit 0. All **33/33 CTest pass again**, 1066.81 seconds; the managed WPF test build executes with zero warnings/errors, TargetDir discovery succeeds, About passes, and the default suite completes **152 checks**. The self-contained application and local ZIP artifact are produced. Complete log: `build/windows-remote/20261015-123133/build.log`. This is local isolated Windows evidence, not hosted CI, a published package or release acceptance.
- After independently reviewing the controlled Force gate, only `DenoiseChecks.cs` was strengthened to probe controlled Off GPU availability first. Fresh local and Windows managed builds pass; the full denoise suite passes **42 checks again**, with availability observed `True`, actual Force filtering/parity, final PNG/JPEG comparisons and unchanged RAW hashes all reached. Final source SHA-256 `2f48446831baafc020a4c7e05ae0f1245fd6ca265a772fd76b94f19d78ab9c4d` agrees on macOS and Windows. Final logs/summary: `build/windows-v08-denoise-final-results/`. No shared or production change followed the full-script run, so unchanged CTest/default WPF suites were not repeated for this isolated test hardening.
- Full-script source archive: `build/windows-remote/20261015-123133/source.zip`, SHA-256 `39100f77088c1bf4a53c98d218c339bfa32e57e128ae66b420e14b7df350c65a`, verified on Windows together with the build script and probe source. It contains the Windows build/test fixes and unchanged shared source before the final one-file Force-gate hardening described above; later evidence-only documentation edits are separate.

The controlled DNG runs retain Lensfun's existing duplicate-distortion-model warnings on stderr (PowerShell formats these as RemoteException records); no warning is suppressed. The managed build and suite exit codes are zero and all assertions above complete.

## Affected Reruns

- Earlier editor code/test source: `8528b83681f3a4180462b023b9be62cbc495a7b6`; the build/denoise follow-up above is newer. Documentation-only commits do not require another render run.
- Source archive: `build/windows-v08-final-code.zip`, SHA-256 `ce002c287c9647703593823989a4a8a3845f1e59bfcb693aec5671757e8c492d`; verified again on Windows. The preceding `27b293e` archive was verified and extracted; the final one-line exact-preview capture wait was overlaid and its source SHA-256 verified as `c71d5d14e8700b6e4d2b50697609bc49ab0ee2deb9284f20ab57d36e14a899d4` before recording this result.
- At `22c5812`, a fresh Windows build plus editing, denoise-model, localization, About, editor-shell, geometry, transform-ui and photo-features all returned zero. Logs and summary are retained in `build/windows-v08-22c5812-results/`.
- At `7ea31a3`, About and **52 photo-feature checks** passed again, including actual frozen batch export, invalid RAW exclusion, busy notifications, failed journal cleanup and retry, EXIF, sixteen-bit PNG, image sizes and unchanged RAW hashes. Compared with `22c5812`, the only production delta is readable native Expander/CheckBox/RadioButton foreground. Logs: `build/windows-v08-7ea31a3-results/`.
- Native composition QA found that detaching Content without flushing its old Window ContentPresenter retained the old layout slot/clip. The helper now flushes the old Window, measures in a new offscreen Grid, and checks nontransparent output at the requested bounds. Six languages at both client sizes, numeric input/wheel/range automation, enlarged rows/numeric fields and readable expander/binary controls then passed. Log: `build/windows-v08-unclipped-editor-shell.log`; twelve images: `build/windows-v08-unclipped-screenshots/`.
- Fresh build and `transform-ui` at `27b293e` returned zero; the final exact-preview-wait capture rerun at `8528b83` also returned zero. It again exercised auto-exposure precision, partial import, committed/draft WB isolation, invalid-preview Apply gating, local Escape, reset/apply/cancel, lens persistence and save-failure switch blocking/retry. It produced nontransparent geometry-draft and RAW client-area compositions at the requested sizes. Final logs/summary: `build/windows-v08-8528b83-results/`; inspected images: `build/windows-v08-ui-screenshots/geometry-draft.png`, `raw-1000.png`, `raw-1440.png`.

The external source and the native DNG test's fixture/source hash agree: SHA-256 `dc280884db9e0d2e1e7389dca1370958ea8fde749cef8169702f64237d98763f`.

The earlier master-recipes, DNG and lens results are retained evidence for unchanged render behavior, not a claim that every suite was repeated at the final source. The first-run failures, intermediate screenshot-fixture failures and denoise failure are not hidden by the narrower successful summaries.

## PR 53 Review Follow-Up

Scope remains `RawLabWindows/**`, on top of `37f82273bdc86c4622bdf87355430611518d1c68`. The user authorized fixing the two P1 findings and one P2, committing, pushing and updating PR #53 to `development`, but not merging. No shared core, C ABI or other-platform source is changed.

### Regressions And Corrections

- Boundary crop transforms: moving a 10% crop to the right/bottom edge produces `.9` origins; the following mirror subtraction can yield `-2.7755575615628914e-17`. The editing model regression failed with `ArgumentOutOfRangeException`, and the Windows checkbox regression failed in `GeometryPanel.FlipChanged -> Publish -> NativeConfig`. Rotation and flip now clamp these derived origins to zero without relaxing NativeConfig's validation of invalid input. Model coverage includes four crop extents and five turn counts; the WPF check exercises both real flip controls.
- Busy ownership: `foregroundBusy` is owned only by the single-export/import workflow. The existing gates read its union with the modeless batch's own Busy state; a batch notification no longer assigns another operation's flag. `ExportPhoto` is the production path used after SaveFileDialog and by the regression, retaining the source lock, temporary file, final publication and cleanup. Path/format preparation occurs before claiming busy. Independent batch engines can still work alongside foreground operations; this is not a new admission policy forbidding overlap.
- Both import/preflight completion orders failed the Windows red regression at the main-window editing/export gate. The final regression also covers actual single PNG export in both orders, blocks photo switching, requests owner close while one owner remains active, and verifies that publication and deferred close finish without releasing the render engine early. It uses actual ShowBatch wiring, not a separate listener attached only to a child window.
- A second red regression showed that an import finishing first could leave the old preview after the last batch owner ended. The batch callback now commits the current preview size and resubmits preview after all owners are idle, but not while closing. The regression compares the displayed image against an independent CPU render of the newly imported Velvia look before allowing export. A separate viewport-resize interaction is not claimed by this pixel test.
- Apply-and-leave: both Geometry and Lens red regressions observed a disabled dialog button after the current exact preview became ready. The dialog now uses a live one-way binding to the main Apply gate and retains the final ApplyTransformDraft recheck. Tests keep the actual dialog open across preview completion and then apply/end the draft.

The deterministic timing helper holds dispatcher completions while native work still runs normally. It proves ownership through completion/publication and close ordering, not a native-concurrency stress or performance claim. The single-export test invokes the same production body used after SaveFileDialog; it does not automate physical picker interaction. Tests use task-owned stores/journals and refuse to start with a recoverable default batch journal because MainWindow construction can clean up recovered staging files before a test replaces the journal.

Red evidence is retained in `build/windows-pr53-review/red-20261015-143921/review-red/`: five selected runs exit 1 at the intended crop, busy or dialog assertion. The final preview-resumption red is in `resume-red-20261015-145357/review-red/`. The preceding `145032` probe hit a test path-normalization problem; the fixture now normalizes paths and waits for Loaded before selecting its private photo. The initial green matrix passed the three original fixes, then was deliberately stopped in an unchanged native recipe suite while the extra preview-resumption regression was added. A subsequent invocation failed before tests because the task-local command passed a PowerShell array to the string Only parameter; the corrected command quotes the comma-separated list. Neither attempt is counted as a complete final pass; their logs are retained.

### Final Related Windows Results

The complete production/test patch was uploaded to a fresh task-owned workspace for the final run. Source archive `build/windows-pr53-review/final-20261015-145822/source.zip` has SHA-256 `21a86e629409463473486418ebd586127fe61beb2f9ae5e2df2c872f325af4c6`. All 112 Windows file hashes matched the uploaded manifest on Windows; local rechecking also matches, excluding only this verification record appended after the run began. No production or test source changed after that snapshot.

```powershell
./RawLabWindows/tests/BuildScriptChecks.ps1
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> -NativeArtifacts <unchanged-native-artifacts> -DenoiseRaw <controlled-DNG> -Only 'editing,denoise-model,localization,about,editor-shell,geometry,transform-ui,editor-review,photo-features,denoise'
```

- The actual Windows PowerShell file-parser/AST regression passes. Fresh Windows managed build has zero warnings/errors. All eleven summary entries, including build and ten selected suites, exit 0.
- Geometry passes 15 checks; transform-ui passes 19 including the two real flip controls; the new editor-review suite passes 45 checks including both foreground kinds, both completion orders, close/publication, preview resumption and both actual leave dialogs.
- Photo-features passes 52 checks, including actual frozen batch export, invalid RAW exclusion, failed journal cleanup and retry, metadata, sizes and RAW hashes. Explorer desktop interaction is explicitly NOT REACHED in SSH session 0, not silently counted as a pass.
- Denoise passes all 42 checks again, including actual controlled CPU/Auto/Force filtering and parity, real-RAW FINAL PNG/JPEG comparisons, cache/fallback checks and unchanged input hashes. Existing Lensfun warnings remain in the log. The real Sony viewport no-op and physical-GPU limits are unchanged.
- The separate, unfiltered default Windows executable run also exits 0 and completes all 152 checks, including real RAW/native rendering, full-resolution export and the asynchronous WPF editor. Its complete log is `windows-v08-results/default.log`; the task runner records `default exit=0`. This finished after the targeted summary; both use the same frozen source and fresh managed output.
- Local editing, denoise-model and six-language localization checks pass; the local WPF cross-build has zero warnings/errors. The macOS hard-link check remains explicitly skipped; Windows editing execution covers the platform helper.
- No C++ source/build inputs changed in this follow-up. The task reuses the previously built, task-owned native artifacts; the earlier 33/33 CTest result is retained baseline evidence, not a claim of a new CTest run. No new self-contained distributable or release artifact is claimed by this managed workflow.

Final logs and summary are retained under `build/windows-pr53-review/final-20261015-145822/`. These are isolated Windows/local results, not hosted CI, physical desktop acceptance or release acceptance.

## Recovery Coverage And Folder Drops

This follow-up starts at `0d782da16bf3b158d4879cd1b081c0b5394e92ca` and stays within `RawLabWindows/**`. It adds the three requested recovery regressions, direct folder drops on the left file tree, and an isolated default-suite edit store. No shared core, C ABI, rendering contract, other platform or version is changed.

- Journal cleanup failure uses the real MainWindow/ShowBatch wiring and a locked task-local `job.json`. It verifies deferred close, error propagation, restored `closing`/IsEnabled state, a retained engine, the pending viewport's dimensions and pixels, actual adjustment/photo switching, and successful cleanup/close after releasing the lock.
- Running batch close pauses the actual worker at its first journaled Running progress post, before rendering that item. Closing requests stop-after-current-item; releasing the gate executes the real native PNG render and metadata/publication path. The first output and journal survive, the second item stays Waiting, staging is absent, and the owner/engine live until completion. The gate is test-only Dispatcher instrumentation, not a new product hook or a native-kernel interruption/performance test.
- Pending resize covers import and single export with both completion orders. It uses actual WPF layout changes, including a real pending denoise debounce, and checks both final dimensions and byte-identical pixels against a separate CPU engine in the same viewport mode. The journal recovery case also resumes a genuinely changed viewport request.
- Folder drops use the real WPF preview/bubble event route on the empty tree and an existing row. Multiple directories persist as roots; case/trailing-separator duplicates are ignored. Folder-plus-RAW data does not switch the photo; RAW-only data retains the existing open behavior. Unsupported data, move-only transfers, busy and closing states are rejected. Source directories and RAW bytes remain intact. The normal folder-list location is unchanged; tests redirect only their library instance to a task-owned JSON file.

The editor-review suite now has **90 checks**: the previous 45, 34 recovery/resize checks and 11 folder-drop checks. Synthetic negative controls independently remove owner recovery, running-close cancellation, preview resubmission or folder-path normalization; each exits 1 at its intended assertion. The pre-implementation folder-drag test also exits 1 at the missing copy-feedback assertion. These task-local variants are not committed. Logs are retained under `gap-mutation-journal-20261015-155105`, `gap-mutation-running-20261015-154136`, `gap-mutation-resize-20261015-154137`, `gap-mutation-dedup-20261015-161041` and `gap-folder-red-20261015-160715` in `build/windows-pr53-review/`.

### Intermediate Failures And Isolation

The initial `gap-probe-20261015-153641` found two test-fixture mistakes: a normalized Slider position was mistaken for an exposure value, and a denoised viewport was compared with a non-viewport render. The Slider input and independent oracle mode were corrected without weakening pixel equality. The superseded probe was stopped only after auditing its own runner/child processes; its failures are retained, not counted as passes. The journal preflight also gained an explicit test-local enumeration barrier so completion capture does not depend on RAW processing speed.

`gap-final-20261015-154206` completed all eleven targeted entries successfully, including the earlier 79-check editor-review suite and 42 denoise checks, but its separate default run failed at `WPF film strength starts at 100% in the middle of its slider`. `gap-affected-20261015-155018` passed the hardened 79-check suite but hit the same default failure. Investigation confirmed that earlier default runs had saved Strength=200 for the external fixture in the real default Edits store; the next run correctly restored it. The default fixture now injects a fresh GUID-scoped EditStore before showing MainWindow instead of resetting/deleting existing records or changing product restore behavior. The final full/default-UI repeat below verifies the isolation. Neither earlier overall run is represented as an all-green run.

### Final Related Windows Results

The final source archive is `build/windows-pr53-review/gap-delivery-20261015-161042/source.zip`, SHA-256 `2421b4737b9fd7e6bacbf252d7431899814f66a6c746fbffce3ae243e306a633`. All 112 Windows file hashes matched on Windows and locally before this record was appended. No production or test source changed after that snapshot; only this verification document was appended afterward.

```powershell
./RawLabWindows/tests/BuildScriptChecks.ps1
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> -NativeArtifacts <unchanged-native-artifacts> -Only 'editing,localization,about,editor-shell,geometry,transform-ui,editor-review,photo-features'
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW>
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW> --ui-only
```

- PowerShell parser/AST regression passes. Fresh managed WPF build has **0 warnings and 0 errors**. All **nine** final summary entries exit 0: build and the eight selected suites above.
- Editor-review passes **90 checks**. Geometry passes 15, transform-ui 19, photo-features 52 and About 40. Photo-features again reports Explorer desktop interaction **NOT REACHED** in SSH session 0.
- The separate, unfiltered default executable completes **152 checks**, exit 0. The subsequent `--ui-only` repeat completes **98 checks**, exit 0, including the same default-strength assertions after the preceding run saved its private state.
- Final logs and summary are under `build/windows-pr53-review/gap-delivery-20261015-161042/windows-v08-results/`. These are isolated Windows results, not hosted CI or physical desktop acceptance.
- Denoise-model and 42-check native denoise results from the earlier broad run are retained for unchanged model/render code; they were not repeated after the folder-drop addition. No new CTest, native DLL build, self-contained package or release artifact is claimed. Earlier 33/33 CTest remains baseline evidence.
- Physical Explorer/OLE folder dragging has **NOT REACHED** acceptance: the new tests exercise genuine WPF routed handlers programmatically, not pointer interaction with Explorer. Existing DPI/multi-monitor/Snap/Narrator/high-contrast/text-size/input-device and physical-GPU limits below remain in force.

## Default Suite Journal Admission

This follow-up starts at `0758d7a3106f6de277dcda95de042abba7ce1b2b`. It changes only the Windows test executable, its runner and documentation. No production window, persistence/recovery behavior, shared core, C ABI or other platform is changed.

The earlier private EditStore fixed edit-record contamination but did not protect batch state: constructing MainWindow calls BatchJournal.Load, which can delete Running/Publishing staging files. Main now forwards to the common test entry with the real BatchJournal.DefaultDirectory. That entry rejects an existing job.json before localization, mode dispatch, fixture output, native work or WPF initialization. This also protects photo-features and interactions, so run-v08 continuing after another failed suite cannot bypass admission. The default body rechecks immediately before creating App after its native checks. Rejection does not parse, recover, rename or delete the journal.

The new `--default-isolation <output>` suite exercises that same common entry, injecting only a task-private journal path into the test executable, not into production code or Windows Known Folders. The normal CLI has no journal-path override. Its **34 checks** cover Running/Publishing with default/full, UI-only, photo-features and interactions arguments, plus an exclusively locked record and malformed JSON. Each refusal must return 1 with the journal-specific error, preserve the complete file-list/SHA-256/last-write-time snapshot (journal, staging, source and published fixture), and create neither suite output nor WPF Application. Separate private controls invoke the real BatchJournal.Load and prove that both status fixtures actually trigger staging cleanup. No fixture is placed in the user's real default directory.

### Red Controls And Intermediate Runs

- `isolation-red-20261015-165227`: fresh build passes; the pre-fix default path enters fixture work and exits 1 at the expected refusal assertion. The invalid private repo/RAW deliberately prevents reaching a real window; the preceding native initialization error is not claimed as a product regression. The private recovery control already demonstrates the actual cleanup side effect.
- The initial default-only implementation passed 22 isolation checks in `isolation-green-20261015-165337`. A preliminary broader matrix at `isolation-delivery-20261015-165429` used that version. Independent review then found the photo-features/interactions dispatch bypass; this snapshot is superseded, not the final fix evidence.
- `isolation-red-20261015-170003` exposed an intermediate test expectation error: the common entry converts exceptions to an exit code, while the test still expected a thrown exception. The regression now checks the real return-code/stderr contract. That intermediate red run is not treated as proof of the dispatch bypass.
- Task-private `isolation-bypass-red-20261015-170327` removes the common admission call. Build exits 0 and isolation exits 1 at `--photo-features-Running-False-False-False`, proving the bypass is detected. An earlier equivalent mutation at `170214` had incomplete recursive artifact retrieval because its generated fixture directories exceeded the Windows OpenSSH path limit; short private GUID/case directories fix retrieval. Both records remain retained; the failed retrieval is not called a clean verification run.

### Final Source And Commands

The final archive is `build/windows-pr53-review/isolation-delivery-20261015-170532/source.zip`, SHA-256 `d40296b3eb236aff4fd30af044c6b30e29af6599803ba15b9324e224a3c96e23`. All 113 Windows file hashes matched on Windows and locally before this record was appended. Only this verification record was appended after upload; no production/test source changed afterward.

```powershell
./RawLabWindows/tests/BuildScriptChecks.ps1
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> -NativeArtifacts <unchanged-native-artifacts> -Only 'editing,localization,about,default-isolation,editor-shell,geometry,transform-ui,editor-review,photo-features'
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW>
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW> --ui-only
```

### Final Windows Results

- The PowerShell parser/AST regression passes. Fresh managed WPF build has **0 warnings and 0 errors**. The final summary contains **10/10 entries with exit 0**: build and all nine selected suites above.
- **34 default-isolation**, **90 editor-review**, **15 geometry**, **19 transform UI**, **52 photo-feature** and **40 About** checks pass. The editor-review suite still covers folder drops and the three owner-recovery/running-close/pending-resize combinations, including unchanged RAW hashes.
- The separate unfiltered default run passes **152 checks**, exit 0. Its subsequent UI-only repeat passes **98 checks**, exit 0, including the initial-strength assertions. Final logs are retained under `build/windows-pr53-review/isolation-delivery-20261015-170532/windows-v08-results/`.
- An independent code review confirmed that all modes of the main test executable pass through common admission. The negative control removes that admission and fails at photo-features; the final suite preserves the journal/staging/output snapshots for all ten refusal cases.
- No new denoise-model/native denoise, CTest, native DLL build, self-contained package or release artifact is claimed. Those inputs are unchanged; their earlier evidence keeps its original source/scope. The current task reuses the prior task-owned native artifacts.
- Photo-features reports Explorer desktop interaction **NOT REACHED** in SSH session 0. No physical OLE folder dragging, SaveFileDialog, DPI/multi-monitor/Snap/Narrator/system-accessibility/input-device or physical GPU acceptance is added by this test-only fix. These Windows results are not hosted CI.

Admission is a data-preservation precondition, not profile virtualization or a cross-process lock. Use an exclusive test account with no product process creating a job concurrently. This coverage applies to RawLabWindows.Tests.dll/run-v08; the separate localization-ui executable is outside this entry and this verification. Existing physical acceptance limits below remain unchanged.

## All Windows Test Entry And State Preservation

This follow-up starts at `a57dd992419787bd96678f33872902b2e1303928`. The user extended the previous main-runner-only fix to the independent localization UI executable and requested that all related Windows issues discovered during this pass be handled together. All code remains in `RawLabWindows/**`; the additional edit in `docs/localization.md` only corrects its Windows test instructions. Shared core/C ABI, production batch recovery, product automatic-update policy, other platforms and versions are unchanged.

### Complete Entry Inventory And Repairs

- Both `RawLabWindows.Tests.dll` and `LocalizationUiChecks.dll` use the same test-layer journal admission before localization, argument dispatch, preference handling, output or WPF startup. An existing job is rejected with its path, without reading/recovering/moving/deleting it. The main default body retains its second check before WPF.
- The independent executable preserves the real `App.OnStartup` and `StartupUri="MainWindow.xaml"` path. Its test-only MainWindow Loaded class handler installs private state before the product Loaded instance handler, preventing the latter's automatic-update request/write. Startup/resource subscriptions and actual six-language UI/settings still run; this is not a physical desktop/profile restart acceptance claim.
- Every direct test construction of MainWindow now installs private Edits, Batch, folders and disabled automatic-update preferences before Show. This covers default/UI-only, About, editor-shell, transform-ui, editor-review, photo-features, interactions, profile and status-layout windows. Isolation also clears a default-profile update badge rather than retaining a blank notification from a previously cached release.
- The independent localization test no longer backs up, rewrites or restores real `language.txt`. The Windows Loc keeps its existing single-argument signatures/default path and adds explicit-file overloads for persistence/reload; the test uses its own file. Product callers retain their original path and behavior.
- The other standalone executables (editing, denoise-model, localization and updates), native denoise diagnostic and parser/package checks do not construct the product main window; their persistent fixtures are private or their localization use is read-only. Main runner render/model/benchmark modes add no separate main-window entry. There is no additional uncovered test executable in this inventory; the production WinExe intentionally keeps real recovery behavior.
- `run-v08.ps1` fresh-builds both test executables and includes independent admission/UI, profile-isolation, updates and status-layout checks. The interactions mode is selectable in the same runner. No public test command needs deletion/movement of an existing user journal.

### Additional Windows Layout Repair

The new layout regression observed a real status-bar change from 35 to 39 DIP when RetrySave became visible. The bar now reserves a minimum slot of 40 DIP but remains Auto-height, so larger fonts can grow naturally. A subsequent programmatic-font/image check found simultaneous text actions exhausting the footer and clipping the GPU selector at the minimum window size. All four footer commands now use the existing icon vocabulary with six-language ToolTip/UIA names, the GPU selector sizes to content, and secondary labels can ellipsize without overlapping commands. Long sidebar/empty-state copy wraps; original copy and Click handlers are retained.

The layout suite checks six languages, 1000x680/1440x920, 13/26 DIP fonts, seven notification combinations, and a maximally expanded dock. It compares bar/editor/dock/canvas frames and actual allocated layout slots, not only RenderSize rectangles that could still be clipped. Its empty-window expanded-dock captures are stress fixtures, not a product empty-state screenshot or physical-monitor evidence. A later six-language UIA pass also verifies the sidebar and four icon actions' accessible names.

### Regression Contracts And Retained Failures

- Independent admission has 22 checks: two real Running/Publishing recovery controls (four assertions), four refusal fixtures including locked/corrupt journals (four assertions each), and two empty-admission continuation checks. Each refusal requires return 1 plus its exact journal path, identical recursive file-list/SHA-256/last-write-time snapshots, no startup continuation/WPF, and no language initialization. Fixtures never occupy the real default Batch directory. The existing main admission suite remains 34 checks.
- Profile isolation checks explicit language persistence/reload without altering the default preference; replacement of an automatic-update config before Loaded, zero HTTP requests, unchanged protected update bytes/timestamp/tmp state, private paths for all four window stores, and clearing inherited update notification state.
- `localization-red-20261015-174816` fails at independent admission and private-update assertions. Its first layout probe and a second probe used an empty collapsed dock and hit Infinity; those fixture mistakes are not product regression evidence. The corrected `175002` probe observes the actual 35-to-39 height change. `175035` additionally catches the missing explicit language-file API.
- An intermediate GPU-width assertion used Ideal text measurement against a Display-formatted WPF control; it was corrected to an independent Display TextBlock measurement. This was not a hidden product pass/fail. An initial bounds-only overflow check falsely passed; adding allocated-slot checks makes `status-red-20261015-180930` fail at the intended 26-DIP/minimum-window/all-notifications assertion.
- The first broad `profile-final-20261015-175711` matrix has 16 successful entries but fails localization UI because the test prototype assigned null to StartupUri. No product startup defect is inferred from that test error, and this run is not counted as an overall pass. The replacement keeps production StartupUri and uses the Loaded class handler; the independent StartupUri/UI rechecks succeed.
- `profile-cache-red-20261015-182143` fails when an inherited visible update badge survives private-state replacement. The test helper now immediately synchronizes notification visibility to its private checker. Independent source/entry audits and final narrow rechecks cover these follow-ups rather than leaving them for another delivery.

### Final Source Bindings And Windows Results

The broad frozen-source run is `build/windows-pr53-review/profile-final-20261015-181103/`, archive SHA-256 `fa6e5b24a87f6234623ce597c3fddf9442e7560145fc694d5c02ebcd468406f1`. Windows verified all 117 file hashes before building. Both managed executables fresh-build with zero warnings/errors. The targeted summary has **17/17 entries exit 0**: two builds, editing, localization, updates, About, main admission, independent admission, profile isolation, localization UI, status layout, editor-shell, geometry, transform-ui, editor-review, photo-features and interactions. Editor-review retains **90** checks, geometry **15**, transform-ui **19**, photo-features **52**, About **40**. The following unfiltered default and UI-only repeat complete **152** and **98** checks, both exit 0.

```powershell
./RawLabWindows/tests/BuildScriptChecks.ps1
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> -NativeArtifacts <unchanged-native-artifacts> -Only 'editing,localization,updates,about,default-isolation,localization-admission,profile-isolation,localization-ui,status-layout,editor-shell,geometry,transform-ui,editor-review,photo-features,interactions'
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW>
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW> --ui-only
```

The last source follow-up only adds explicit sidebar UIA naming/empty-icon alignment and corresponding six-language assertions, then synchronizes the inherited update badge to private state and strengthens that regression. Those affected paths are rebuilt and rechecked in `profile-post-20261015-182419/`, archive SHA-256 `98e4062fcbb6f734b27e4fe348e91c00b6f4fb68eb2f339e87035d7cd0478167`. Its **7/7 entries exit 0**: both builds and all five selected suites below. Results are **34** main-admission, **22** independent-admission, **10** profile-isolation, **160** localization UI/UIA and **384** status-layout checks. The 160 UI assertions include the real StartupUri-created window and six-language names for the sidebar and all four footer commands. No render/recovery implementation changed between the two successful snapshots; unchanged native workflows retain the broad run's source/scope rather than being presented as a repeated broad run at the last snapshot.

```powershell
./RawLabWindows/tests/BuildScriptChecks.ps1
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> -NativeArtifacts <unchanged-native-artifacts> -Only 'default-isolation,localization-admission,profile-isolation,localization-ui,status-layout'
```

Both successful runs snapshot the real default `%LOCALAPPDATA%/RawLab` directory before and after execution. File lists, SHA-256 and last-write ticks compare identical; the retained files are `windows-v08-results/default-profile-before.json` and `default-profile-after.json`. This covers the actual account's existing default files without placing a job fixture there. The separate private admission fixtures exercise existing Running/Publishing journals and staging safely. It is not a registry/ACL/read-trace audit or full profile virtualization. Post-run process audit reports zero dotnet test workers referencing either completed task workspace; no other process was stopped.

All 117 final Windows hashes matched on Windows. Local rechecking matches the 115 files other than this verification record and the implementation checklist updated after the run. No production/test source changed after the last snapshot. Both source freezes and all final output directories are task-owned. No RAW, native DLL, screenshot, log or generated fixture is committed.

These results are local Windows verification, **not hosted CI**, physical desktop or release acceptance. No new CTest/native DLL, denoise-model/native denoise, macOS, self-contained package or release build is claimed. The earlier 33/33 CTest and denoise results retain their original source/scope. Explorer remains **NOT REACHED** in SSH session 0; physical DPI/multi-monitor/Snap/Narrator/system text-size/high-contrast/input-device and independently identified GPU acceptance remain open. Admission still requires an exclusive test account without a product process concurrently creating jobs; no cross-process lock is claimed.

## Three P2 Recovery, Contrast And Runner Follow-Up

This delivery starts at `5c2af9261f6872036e72996f214c7092a4d4d3d9` and changes only `RawLabWindows/**`. No shared core, C ABI, other-platform implementation, version or release artifact is changed.

### Repairs And Regression Contracts

- Synchronous idle batch-window close failure now shares the asynchronous owner recovery path: re-enable the owner, clear closing, resume a pending viewport size only when no foreground/batch owner remains, refresh gates and report the journal error. The new locked-private-journal cases cover both no foreground work and a held real look import, with active denoise debounce, retained requested size, no premature rendering, independent CPU exact-pixel comparison, photo switching and successful close retry after unlocking. The foreground branch explicitly checks request retention and stopped timer/idle scheduler instead of using an always-true conditional assertion.
- High contrast uses paired surface/foreground and selection/selection-text resources, including inputs, popups, menus, list/tree selection, buttons, status/error labels, progress and sliders. Retained local/static brushes are replaced by dynamic references. Derived About, batch, settings and export-size windows and ParameterSlider explicitly consume the common base-type style; WPF does not implicitly apply a base-type key to those derived controls. Disabled numeric inputs override the native theme's old GrayText. Photo/recipe captions and lens calibration inherit their selected container color; batch checkbox rows do not acquire an unrelated ListBox selection background. The final state audit also makes the keyboard focus outline two-tone so it cannot disappear on the selected Highlight background, gives tree items that outline, and uses paired foreground for the caret/focused input border and high-contrast scrollbar hover/pressed states.
- Resident swipe/crop DrawingVisual layers now redraw through dynamic paired overlay brushes when the palette changes. Crop grids use 1.5 DIP only in high contrast, retaining 0.6 DIP normally, and two-tone outlines remain visible over arbitrary photographs. Histogram RGB channel fills retain their original meaning; high contrast adds a foreground-colored max-channel envelope instead of replacing channel colors. No native render settings or exported image pixels are altered.
- `run-v08.ps1 -Only` normalizes CSV whitespace/case/duplicates and rejects unknown names or nonempty delimiter-only input before DotNet work. Empty/default selection runs every declared suite. Requested suites must appear in the fresh result summary. Build, output-query, missing-command/artifact and log-write failures remain nonzero and cannot leave a previous green summary or print PASS before summary persistence. Both builds remain mandatory.
- The real runner script is driven in independent Windows PowerShell 5.1 child processes with task-private external-command stubs, native sentinels, a path containing spaces and a stale success summary seeded before each case. The regression checks actual selected DLL arguments, complete default dispatch, native failure codes and continuation after a failed suite. It is a runner-contract test, not a substitute for the separate real managed/native suite matrix.
- The appearance regression keeps existing live product controls across light/dark/light injected palettes using the same production palette resolver, without changing system settings. It covers normal and disabled input, real status/save/size errors, About/settings/batch content, actual parameter/footer controls, lens popup/options, photo-group template, hover/pressed/selected states, progress and sliders. Retained gray synthetic canvas images and histogram bins provide actual WPF raster assertions for empty background, swipe divider, crop handle/grid and histogram envelope. It does not claim physical pointer, OS preference-event or arbitrary-photo acceptance.

### Negative Controls And Superseded Runs

- `p2-close-red-20261015-201545` builds successfully and fails because synchronous close cancellation does not resubmit the pending resize without another input; the corresponding `p2-close-green-20261015-201743` passes both owner cases.
- `p2-appearance-red-20261015-201852` exposes the original numeric input foreground/background mismatch. Later live-window tests expose derived-window/style and disabled GrayText omissions. `p2-appearance-red-20261015-204414` fails at the fixed-white swipe divider under the light palette. The final standalone appearance snapshot `p2-appearance-green-20261015-205151` passes 183 assertions after all related repairs.
- `p2-runner-red-20261015-202020` observes the old unknown-name runner printing PASS, so the new runner regression fails as intended. The completed expanded `p2-runner-green-20261015-203115` passes 37 assertions; the final matrix repeats it after moving PASS behind summary persistence.
- Iterative failures from a local LASTEXITCODE scope reset, passing an empty native `-File` argument, unrealized/hidden popup fixtures, an unbounded host composition and orphaned/offset/antialiased raster sampling are retained, not counted as product regression proofs or passing verification. The final fixtures use a live host, actual item containers and independently chosen raster thresholds. The preliminary broad `p2-final-20261015-203935` contains an appearance fixture failure and is superseded; its remaining native work was stopped after identifying that exact task-owned parent and worker, to avoid competing with the final run. It is not an overall pass and did not reach its subsequent default/UI repeats. No other task's process was stopped.

### Frozen Source And Final Windows Verification

The broad archive is `build/windows-pr53-review/p2-final-20261015-205239/source.zip`, SHA-256 `c8723d971207f31a4a69ac58ce42e2bca7e812bc2b94e98bf4abc1d48ae32af9`. All 119 Windows file hashes matched locally at source freeze and on Windows before building. This snapshot includes the close/runner repairs and the 183-check appearance regression, but predates the final focus/caret/scroll state-color follow-up.

The final affected-UI archive is `build/windows-pr53-review/p2-ui-final-20261015-212323/source.zip`, SHA-256 `232f0344a2c4b0f122d2b5ad38ddaee67d545286f95d3a1915f56a1e8cef4d93`. Between those archives only `Controls.xaml`, `EditorAppearance.cs`, `tests/AppearanceChecks.cs` and this record differ. No native/render/recovery/runner code changed. All 119 uploaded Windows hashes match on Windows. This snapshot fresh-builds both executables with zero warnings/errors and passes **10/10 entries**, including all eight selected suites below: **40 About**, **34 main admission**, **22 independent admission**, **10 profile isolation**, **160 localization UI/UIA**, **384 status layout**, **192 appearance** and editor-shell. Its real default profile before/after snapshots compare identical. No production/test source changed after this final UI snapshot; only this record and the implementation checklist are completed afterward. Broad native/default results retain the earlier archive's scope and are not represented as a repeated full matrix at the final UI archive.

```powershell
./RawLabWindows/tests/BuildScriptChecks.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./RawLabWindows/tests/RunnerSelectionChecks.ps1 -Output <private-results>
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> -NativeArtifacts <unchanged-native-artifacts> -DenoiseRaw <controlled-DNG>
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW>
dotnet <TargetDir>/RawLabWindows.Tests.dll <repo> <external-RAW> --ui-only
# Final affected UI snapshot, after the late state-color follow-up:
./RawLabWindows/tests/run-v08.ps1 -RawPath <external-RAW> -NativeArtifacts <unchanged-native-artifacts> -Only 'about,default-isolation,localization-admission,profile-isolation,localization-ui,status-layout,appearance,editor-shell'
```

The broad frozen-source run completes **23/23 entries with exit 0**, including both fresh managed builds with zero warnings/errors and all 21 declared suites. The independent runner gate passes **37 checks**. Results include **107 editor-review**, **183 appearance**, **15 geometry**, **19 transform UI**, **52 photo-feature**, **42 denoise** and **11 lens** checks; all fourteen native master recipes and the rendered-DNG suite also complete successfully. The following unfiltered default and UI-only repeat pass **152** and **98** checks, exit 0. The real default profile's complete file list, SHA-256 and last-write ticks remain identical before/after. These results, summary and logs are retained under `p2-final-20261015-205239/windows-v08-results/`.

The final UI snapshot additionally repeats the unfiltered `--ui-only` default body using its freshly built binary: **98 checks**, exit 0. Its separate `default-profile-after-ui-repeat.json` still matches the pre-run default snapshot byte-for-byte. The final appearance count is **192**, including selected-surface keyboard focus, caret and scrollbar hover assertions added after the broad 183-check snapshot. The latest 117 local Windows files other than this record and the implementation checklist match the final UI manifest. Final process audit finds zero task-owned test workers; no other task's process is stopped.

These are completed local Windows VM results, not hosted CI or physical/release acceptance. Native artifacts are reused, not rebuilt; no new CTest, macOS, self-contained or release build is claimed. The two source snapshots and late UI-only differences are stated separately rather than implying the 23-entry run was repeated at the last UI snapshot. Existing physical acceptance limits below remain open.

## Acceptance Limits

- WPF layout images are native RenderTargetBitmap client-area compositions. The SSH desktop can clamp the HWND below the requested window size; the test records both actual HWND size and exact arranged client DIP dimensions. These are not physical-monitor screenshots or proof of Snap behavior.
- **NOT REACHED:** physical 125/150/200% DPI transitions, multiple monitors, Windows Snap, Narrator reading/focus order, live system high-contrast/text-size changes, physical mouse and Precision Touchpad behavior.
- WMI reports `Microsoft Basic Display Adapter`. Native tests observed backend `3` / Direct3D 11, including Force, but the actual physical GPU and interactive hardware performance have not been independently established. Do not equate this VM's backend result with a production hardware acceptance claim.
- No browser, CUA desktop, remote system setting, registry preference or source RAW was intentionally modified by the verification workflow.
