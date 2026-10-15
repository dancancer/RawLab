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

## Acceptance Limits

- WPF layout images are native RenderTargetBitmap client-area compositions. The SSH desktop can clamp the HWND below the requested window size; the test records both actual HWND size and exact arranged client DIP dimensions. These are not physical-monitor screenshots or proof of Snap behavior.
- **NOT REACHED:** physical 125/150/200% DPI transitions, multiple monitors, Windows Snap, Narrator reading/focus order, live system high-contrast/text-size changes, physical mouse and Precision Touchpad behavior.
- WMI reports `Microsoft Basic Display Adapter`. Native tests observed backend `3` / Direct3D 11, including Force, but the actual physical GPU and interactive hardware performance have not been independently established. Do not equate this VM's backend result with a production hardware acceptance claim.
- No browser, CUA desktop, remote system setting, registry preference or source RAW was intentionally modified by the verification workflow.
