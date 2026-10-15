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

The initial `build-remote.py --test --raw <external ARW>` run built native C++ and the self-contained WPF application. All **33/33 CTest passed** in 1071.02 seconds. The legacy `build.ps1 -Test` wrapper subsequently failed with `Cannot resolve the WPF test output directory.`; its default WPF suite was **NOT REACHED**. A direct WPF test build and TargetDir query succeeded. This is not reported as a successful full `build.ps1 -Test` gate.

Native shared source is unchanged from the base. The task-owned native DLL/ExifTool artifact is reused for platform-only incremental WPF checks; no stale RawLab managed DLL is copied over a fresh test build.

The owned runner is `tests/run-v08.ps1`. It captures per-check logs and `summary.json`, continues to record independent failures, and supports comma-separated `-Only` for affected checks. The initial targeted run passed editing, denoise-model, localization, About, editor-shell, geometry, master-recipes, rendered-dng and lens. DNG Auto/Force reported backend 3 and lens CPU/Force parity passed. It exposed two test-fixture problems: a missing DispatcherSynchronizationContext in transform-ui, and searching collapsed vignette visual descendants before expansion in photo-features. Both fixtures were repaired for the affected rerun; failures are retained in `build/windows-v08-initial-results/`.

The existing native denoise check failed at `tests/DenoiseChecks.cs:24`, `Native wavelet changes real RAW output`: the 1600px off/Clean 8-bit images were identical for this Sony fixture. Do not report the rest of that suite as reached. Its test, `DenoiseSettings.Clean` and shared wavelet code are unchanged from the base; the new geometry/perspective setters run before the wavelet setter and do not write wavelet state/cache.

A same-fixture A/B probe used a private copy of the test runtime with the initial native-build workspace's managed RawLab DLL, before the new perspective setter. Its `RenderEngine.cs` matches the base exactly (SHA-256 `360e8de76c1bfe7a7c8dfa9317727c587ff77f49f96e17e886f0028d0f613bfe`); it fails at the same assertion. Evidence: `build/windows-v08-baseline-denoise.log`, remote `build/baseline-denoise-probe/probe.log`. This reproduces the failure without the new perspective binding, but is not a full clean-base acceptance run. The algorithm can intentionally return without filtering when fewer than eight flat samples exist, and 8-bit quantization is another possible explanation; neither root cause has been proven for this fixture. The assertion has not been weakened and shared code has not been modified to make it pass.

## Affected Reruns

- Final code/test source: `8528b83681f3a4180462b023b9be62cbc495a7b6`. Later documentation-only commits do not require another render run.
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
