# Viewport denoise delivery on development

## Snapshot

- Base: `development`, `12d6cc17b2b92233657d3eb548ee146dbdcb8530`.
- Branch: `feature/viewport-denoise-preview`.
- The original `review/viewport-denoise-cache` worktree is preserved. Its reports document the original controlled investigation, not the new delivery baseline.
- Only the viewport, denoise-cache, Android memory fixes and their tests/docs were migrated. The old branch's AI and JPEG XL DNG commits were not imported.
- SHA-256 of the sorted changed-source checksum manifest: `1a06c45b850b456e8a7df98797587f045673ba83912ae38961b81f6edb310a5b`.
- Logs and generated artifacts are excluded from Git under `build/delivery-validation/`.

## Baseline integration

The new baseline already supports HSL, master recipes, automatic exposure and generic Metal/GLES/D3D11 denoising. Conflict resolution preserves those APIs and settings. Viewport renders supply the resized, filtered image to every GPU backend; native exports and 100% views do not opt into the viewport approximation.

`wavelet_cache_tests` uses the existing external RAW argument for its processing assertions rather than importing a fixture from the unrelated old DNG history. The fixture-free target still checks cache slots and the preview budget; the real-RAW target covers baseline invalidation and the actual filtering call counts.

## Android controls and results

Fixture: Panasonic S5II RW2, active resolution 6000x4000, SHA-256 `bf2f33175b63fc4ebfae59bd3f53bb1483eb7770196bbeed73764ade0ad12a1e`.

Controls: API 35 arm64 AVD, 2560 MiB configured RAM, CPU processing, Clean denoise (10/72/100), original-size 16-bit PNG and JPEG, 100 ms native-heap sampling, unchanged 1,800,000,000-byte budget.

| Run | Exposure mode | Native heap sample maximum | Result |
| --- | --- | ---: | --- |
| Cold, PNG/JPEG, luma 10 to 11 recompute | Current default 1 | 1,635,562,576 B | Instrumentation passed |
| Warm 1600px denoise preview, PNG/JPEG, recompute | Current default 1 | 1,656,024,256 B | Instrumentation passed |
| Fresh cold, matched historical exposure, PNG/JPEG | Explicit Scene 0 | 1,632,177,792 B | Script and instrumentation passed |

The default-mode cold and warm files have identical whole-file hashes:

- PNG: `2557ff8fb53ccc015a012be8044dbd4073763b822400100acd237376575cd5ef`.
- JPEG: `07c37c26874e2963e4d572d1ada3c6fe81e23bcf102a0c39de4b56cc24853083`.

Those hashes differ from the old branch because baseline commit `cf71b81` changed Android's default exposure mode from implicit Scene to embedded-preview mode. The test-only `memoryExposureMode` parameter fixes the comparison condition without changing the application's default. With explicit Scene 0, both files are byte-identical to the original pre-optimization 6 GiB reference:

- PNG: `1f13cc75fd0a91c60c656ea85e26e83d25abba1d68a854b5a9e8ac391ed1942a`.
- JPEG: `2ef1a825823893290f606cd30d0430ca9b7ea9e7a9442ca52f4545c6bd4f8fc2`.

The original same-condition investigation established that full-resolution buffer lifetimes, full RGB filter padding and concurrent coarse SWT work already exceeded the 2.5 GiB environment before viewport optimization. An additional stale 288 MB exact output was confirmed during strength changes before its cache-miss release was fixed. See the historical Android memory report for the failing controls and incremental fixes.

Collection notes: the warm instrumentation completed successfully before its shell wrapper failed because the running script was edited to add the optional exposure parameter. Its complete CSV and outputs were collected separately and verified. An initial explicit-Scene run on port 5582 was interrupted by an emulator reboot, with no final assertion result; it is excluded. The reboot's external cause is unconfirmed. The successful Scene run used private ADB server port 5038 and console/transport ports 5682/5683, invisible to the default server, without changing RAM or test thresholds.

After the successful Scene run and eight-test suite, QEMU PID 8532 independently aborted at 12:41:37. Its macOS crash report identifies an internal gRPC callback calling an empty `std::function` (`std::__throw_bad_function_call`, then `SIGABRT`), not Android LMK or an external SIGKILL. Those tests had already finished. The Sony metadata case passed in a separate fresh instance. This emulator-host failure was not addressed by changing application code or weakening a gate.

## Executed gates

- Android arm64 app/test APKs, unit tests and lint: passed; 60 unit tests, zero failures; lint zero errors and 38 existing warnings.
- Android applied GLES denoise/CPU parity, native JPEG/PNG against independent FINAL processing, HSL/auto exposure, quiet-resize/latest-edit race and five Compose canvas cases: eight tests passed.
- Android Sony native export/metadata case: passed separately (one test, 22.787s), preserving the LensModel precondition and original-size JPEG/PNG assertions.
- Shared core, wavelet/chroma enabled, real Panasonic RAW, CPU/Metal/HSL/cache/tiling tests: 22/22 CTest passed. A wavelet-disabled translation unit also compiled without OpenCV headers.
- macOS full viewport integration: passed, including native denoised JPEG/16-bit PNG, independent exact references, rapid resize, stale timer cancellation, current edits and 100% restoration.
- macOS progressive render integration: passed. All 14 master recipes passed real-RAW CPU/Force Metal parity and frozen single/batch JPEG/PNG checks; recipe model tests passed.
- Fresh standalone macOS arm64 Release app bundle, ad-hoc signatures, resource/license equality and packaged startup smoke: passed in the isolated follow-up described below.
- iOS device arm64 and simulator arm64/x86_64 framework slices, dependency/license verification and simulator app build: passed.
- iOS processor export: passed, including HSL/auto exposure, all 14 master recipes, Force Metal parity, 512/768px denoise viewport to native JPEG with independent FINAL equality and capture metadata. iOS currently exports JPEG, not PNG.
- iOS viewport-state regression: passed (busy replay, quiet resize, latest edits, cancellation and disabling denoise).
- Windows isolated native suite: 20/20 CTest passed. Initial unbounded MSBuild workers exited with MSB4166; the native build was completed with four workers, without changing compiler flags or test tolerances. Final managed suite passed 136 checks, including original-size 4672x7008 JPEG/16-bit PNG, metadata, CPU/D3D11 parity and real WPF opening/resize/photo-switch assertions. Final self-contained publish passed.
- Windows Panasonic applied denoise: actual Auto/Force D3D11 and CPU fallback parity, combined effects/chroma/detail, deterministic grain, native 6000x4000 16-bit PNG against independent exact processing and JPEG after resized viewport against independent FINAL all passed. The interaction suite passed physical-pixel resize/zoom sizing, immediate native geometry, three 100%/Fit cycles, retained pan and thumbnail/export gating. Log: `build/delivery-validation/windows-final-managed.log`; exit 0. Native DLL SHA-256: `9580678e647e227fe07b3730db0799bfc2235bad5809bd537f335b6db6b91f6b`.
- Changed-source checksum verification and diff whitespace checks: passed.

## Review and limitations

The complete Windows WPF suite exposed startup regressions. First, an embedded-preview source-size callback replaced the initial progressive ticket with a non-interactive request. A synchronous callback reproduced the missing proxy; the final integration test also resizes the real window during opening. `CommitPreviewSize` now retains the initial-preview/refine path while `result` is null; stale tickets remain rejected and proxy export remains disabled.

The strengthened bitmap assertion then demonstrated that an initial placeholder could settle at the legacy 2000px edge even though the physical canvas requested 384px. `OpenFile` keeps Fit/source/placeholder initialization under its existing synchronization guard and then copies the canvas edge. The physical-window RED/GREEN test settled at 256x384 after the fix.

Both reviewers identified one remaining no-placeholder path: source metadata could not update the canvas edge until an image arrived. A synchronous source-metadata callback at an arranged 600x400 canvas reproduced the failure against the original `PhotoCanvas` (`windows-no-image-valid-red.log`). Resolution is now computed even without an image; only the drawing transform requires one. Initial and late aspect-ratio metadata assertions, the real no-supplied-placeholder photo switch, and the complete 136-check managed suite passed with the final source. An earlier detached-canvas test relied on deferred SizeChanged delivery; its ordering was corrected before the valid RED/GREEN cycle, without changing production behavior or tolerances.

Two independent read-only reviewers covered the migrated changes against the recorded development baseline. No confirmed Must/Should findings remain. A targeted follow-up review of the exposure-control test parameter also found no issues. See the delivery review report for call-chain coverage.

## Standalone macOS bundle follow-up

Verified source commit: `e101b798c174356d0223ade1eff31ba8983f91db`, with the unchanged 58-path source manifest above. The follow-up changes verification documentation only; no production or test code changed and no completed RAW suite was repeated.

The delivery worktree had no macOS dependency prefix. The existing external prefix used by earlier integration tests contained a later DNG SDK-enabled LibRaw build, so it was not reused for this standalone package. Only pinned upstream source archives were copied from the cache, and every archive passed the current scripts' SHA-256 checks. `RawLabMac/build-dependencies.sh` rebuilt LibRaw 0.22.2, OpenCV 4.12.0, wavelib and transitive dependencies into this worktree's own `build/macos15-deps/arm64/install`. No old DNG SDK source or binary was imported.

`RawLabMac/build.sh` used `RAWLAB_BUILD_DIR=build/delivery-macos-e101b798/native` and `RAWLAB_APP_PATH=build/delivery-macos-e101b798/RawLab Mac.app`. The new core cache selected the new prefix's LibRaw headers/library, with GPU, wavelet and chroma enabled. The build was Release/arm64, deployment target 26.0, on macOS 27.0 (26A428), using the existing Xcode toolchain. The default application/output directories and other worktrees were not overwritten.

- Dependency build and complete app bundle build: exit 0; logs `build/delivery-macos-e101b798/dependencies.log` and `bundle-build.log`.
- Existing `tests/bundle.sh`: passed architecture/minimum-system checks and strict per-binary/deep signature verification for the executable and all 12 embedded dynamic libraries. Every declared non-system load resolves to an existing bundled `@rpath` library.
- Additional closure checks: Info.plist identity, all copied license/notice files against their sources, OpenCV notices and wavelib copyright, 10 LUTs, 12 film images, master recipes/icons, and all 1x/2x icon sizes/alpha passed. `codesign` reports `Signature=adhoc`, no TeamIdentifier. Log `closure.log`.
- Packaged startup: the new source dependency install directory was temporarily moved out of its original path, with automatic restoration, and DYLD override variables were removed. One Panasonic `--smoke` entry run passed scene/preview cache isolation, bundled PROVIA loading and JPEG/16-bit PNG output; the missing-input case was correctly rejected. `DYLD_PRINT_LIBRARIES` recorded actual app-bundle library loads and no Homebrew, source-prefix or old `rawlab_dng_sdk` load. Logs `startup-smoke.log`, `isolated-startup.log`, and `missing-input.log`. The prefix was restored and no app process remained.
- Executable SHA-256: `b2e6395012a2c954d2d90d5106cb8f4c95e74f449d89528438ac02a199a14c11`; ad-hoc CDHash `2f76c82f7c7aa6d03bece5e901ccb12b7bc64ec2`. The Panasonic RAW hash remained unchanged.

This is a local verification bundle, not a new versioned release: its Info.plist retains the development baseline's 0.6.0/build 10. No notarization, Developer ID signing, upload, deployment, Xcode license acceptance or system security configuration change was performed. The packaged smoke entry was exercised without normal GUI activation; a fresh interactive GUI run and runtime on macOS 26/15 are not claimed.

Heap sampling is not an instantaneous peak measurement. These runs establish memory/export correctness, not a controlled throughput benchmark; concurrent host workloads differed. Physical Android/iOS devices, Android x86_64 runtime and macOS x86_64 runtime are not verified by this report. Exact-head remote CI is reported separately from local/VM results. No merge or release is authorized by these gates.

## Later Composition Increment

The feature's normal merge with `development` at `d810fe6` and its bounded
Lens/NR/viewport/FINAL, client binding and package-runtime checks are recorded
separately in [the composition report](verification-viewport-lens-dng-integration-2026-10-13.md).
The historical measurements above are not relabeled as that composed-source
matrix; the old cold/warm/Scene experiments were not repeated.
