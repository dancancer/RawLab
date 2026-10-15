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

## Acceptance Limits

- WPF layout images are native RenderTargetBitmap client-area compositions. The SSH desktop can clamp the HWND below the requested window size; the test records both actual HWND size and exact arranged client DIP dimensions. These are not physical-monitor screenshots or proof of Snap behavior.
- **NOT REACHED:** physical 125/150/200% DPI transitions, multiple monitors, Windows Snap, Narrator reading/focus order, live system high-contrast/text-size changes, physical mouse and Precision Touchpad behavior.
- WMI reports `Microsoft Basic Display Adapter`. Native tests observed backend `3` / Direct3D 11, including Force, but the actual physical GPU and interactive hardware performance have not been independently established. Do not equate this VM's backend result with a production hardware acceptance claim.
- No browser, CUA desktop, remote system setting, registry preference or source RAW was intentionally modified by the verification workflow.
