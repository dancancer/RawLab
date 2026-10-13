# Final Development Composition Verification

## Tested Source

Tested development source: `3f252a1006d349c2a3655129a9cf665385dccaca`.
Its parents are `2c46edc5f0d8a26933f853afbb068e5def06e2bf` and
`de3b79376d40657856285f5dfc41ca8bf4ecc1e9` (the final #25 source).
The isolated worktree is `/Users/xupeng/mycode/rawtools/build/iteration-v070-integration`,
on `feature/v070-integration`. It was clean before verification.

Both the tested source and #25 have the identical complete Git tree
`8cd099efca75c18765ec5db178746d8bd8da3ebd`:
`git diff --exit-code de3b79376d40657856285f5dfc41ca8bf4ecc1e9 HEAD` returned 0.
The core, Android JNI and native processor are also unchanged from the final
#27 source `15e0d044a91102a2157219e8250b69f5c5ac7ada`.
This is the identity basis for reusing completed client and language gates,
not a claim that those commands were rerun on the merge commit.

The five completed feature merges are #23 `caf51809102489dd0ecc5bc185352fe9992a5177`,
#24 `802354aa9b54e540fc2ca1c55be09038a5f621bd`,
#26 `d810fe6e47fbc70be79786a8ebaee2d1e9e9fe0e`,
#27 `2c46edc5f0d8a26933f853afbb068e5def06e2bf`, and #25 `3f252a1`.
Their source-bound independent review records retain their original scope.
This run does not repeat the old broad Stage3, Android cold/warm/Scene or
four-platform feature review matrices.

Any commit containing only this report is a documentation revision following
the tested source, not a new tested executable revision. No production, test,
build-script, version or minimum-OS source was changed in this final run.

## Fresh Mac Build

All new artifacts are ignored under `build/v070-final-3f252a1/` (`RUN` below).
The new core directory is `lutools/build-macos`; it did not exist before this run.
`cmake --fresh` binds it to this worktree's own prefixes:
`build/macos15-deps/arm64/install` and `build/lensfun/arm64/install`.
No compiled dependency, core binary or CMake cache was copied from another
worktree. Only pinned source archives were copied and checked by the helpers.
Lensfun uses the existing Mac helper's architecture-checked host GLib;
its runtime dependencies are copied into the app and checked separately.

Configuration: arm64 Release; DNG SDK/JPEG XL, Lensfun, TIFF 4.7.1,
wavelet/chroma and Metal ON; core OpenMP OFF. Matched SDK/LibRaw definitions
include `qDNGThreadSafe=1`, `qMacOS=1`, `qDNGSupportJXL=1` and `USE_DNGSDK`.
LibRaw 0.22.2, SDK 1.7.1, OpenCV 4.12.0, Lensfun 0.3.4 and the pinned wavelib
revision are built together. Cache/link inspection found no old feature,
localization, Lens worktree or primary-checkout dependency prefix.

Host measured for this run: macOS 27.0.1 / `26A434`; Xcode SDK 27.0.
This local build uses the existing target 26.0. It does not decide the 0.7.0
minimum supported macOS version. The published 0.6.0 Mac package supports 15;
the candidate retains Mac 15, with separate target-15 package verification pending.
The package remains version 0.6.0 / build 10, not a release candidate.

Commands:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  RAWLAB_ARCH=arm64 MACOSX_DEPLOYMENT_TARGET=26.0 JOBS=6 \
  bash RawLabMac/build-dependencies.sh
bash build/v070-final-3f252a1/build-final.sh
SONY2FUJI_TEST_GPU=1 ctest --test-dir lutools/build-macos -V \
  -R '^rendered_dng_lens_wavelet$'
```

The ignored `build-final.sh` records the exact fresh configure, explicit real
fixture options, own `CMAKE_PREFIX_PATH`, SDK and package path.
Build/package/strict-signature checks returned 0. The production build's
existing `dng_jxl_tests` passed, including the unchanged SDK OOM load/WB/C ABI
assertion, decoder reuse, crop/opcodes and CPU/Auto rendering.

The first CMake SDK download remained at 0 bytes. Downloading the same official
URL with curl produced the declared SHA-256
`740fbe95c69e09e9cd17654a5e4fef2d7021254b06fd2b8c5557b79a1496b50c`.
Only the owned download PID was stopped; its failed log is retained. Seeding
that verified archive into the own FetchContent download cache and rerunning
the unmodified helper succeeded. No TLS, checksum or assertion was relaxed.
The build also records Lensfun's repeated-install old-RPATH removal diagnostics;
it is not a zero-warning claim. Final linkage, all Mach-O checks and actual
runtime closure are the relevant artifact checks.

## Fresh Focused Results

| Gate | Result and scope |
| --- | --- |
| Six-language static resources | 5/5, exit 0 on the tested source |
| Unique Lens/NR/viewport/FINAL combination | 1/1, 79.29 seconds, exit 0; real Sony and CPU/Force Metal |
| Mac viewport and native NR JPEG/PNG | Exit 0; applied Panasonic NR, native 6000x4000 JPEG/PNG16 against independent FINAL, CPU/Metal, quiet-resize/latest edits and 100% restoration |
| Mac isolated package runtime closure | Exit 0; signed app, Lens DB/SDK/TIFF notices, all six catalogs and no RAW files; actual bundled library loads with both own install prefixes hidden, then restored |

The unique combination requires applied distortion/TCA, auto-crop and visibly
applied wavelet NR, rather than accepting an ineligible fixture. It checks
1600/1024/1600 viewport reuse, downstream edits without repeating NR, profile,
auto-crop and database-revision invalidation, and exact exposure/report/pixel
equality with independent equivalent sessions. FINAL ignores both preview flags.
Native JPEG, PNG16 and float32 RGB DNG whole files equal independent exact
exports. JPEG geometry and decoded PNG/DNG pixels are checked. PNG/DNG maximum
RGB8-reference error is `0.498054/0.50001` (limit 1); Force Metal maximum error
is 1 (limit 2), with its own NR filter run rather than CPU output reuse.

The fresh Mac viewport harness also checks non-NR effects, actual NR and chroma
CPU/Metal parity, exposure/WB metadata, interactive WB transitions, old resize
timer cancellation, export blocking until quiet and current-settings retention.
Its JPEG and PNG after viewport/WB/strength edits are whole-file identical to
independent native references (in addition to the harness's decoded-pixel
checks). An independent ImageIO `sips` read confirms 6000x4000, JPEG 8-bit and
PNG 16-bit. Temporary photos remain at `/tmp/rawlab-viewport-preview.ONiGeq`;
identities and geometry are retained in `RUN/macos-native-exports.sha256` and
`RUN/macos-native-export-geometry.log`. They are not committed or packaged.

`RUN/package-closure.sh` compares current Lens XML, SDK/TIFF licenses and notices,
checks all bundled Mach-O architecture/minimum-target/dependency/RPATH/signatures,
and checks RAW exclusion. Actual DYLD tracing with overrides cleared and both
own prefixes temporarily hidden shows SDK, LibRaw, Lensfun, OpenCV, LCMS, JPEG,
OpenMP, GLib, gettext and PCRE inside the app. No old worktree, own install prefix
or Homebrew runtime load was observed. Packaged smoke exports succeed; the exit
trap restores both install prefixes. This is runtime closure, not notarization.

Fixtures remain unchanged:

| Fixture | Original geometry | SHA-256 |
| --- | --- | --- |
| Sony `DSC06251.ARW` | 4672x7008 | `dc280884db9e0d2e1e7389dca1370958ea8fde749cef8169702f64237d98763f` |
| Panasonic S5II RW2 | 6000x4000 | `bf2f33175b63fc4ebfae59bd3f53bb1483eb7770196bbeed73764ade0ad12a1e` |
| DJI `DJI_20250602164503_0444_D.DNG` | 3072x3072 | `0ecdc8087d566c5ba39f9bd40eef4dfc5f3884ccb016f311a606508751c79eaf` |

## Reused Client Evidence

The final #25 report's Development section describes fresh clients built after
merging `2c46edc5`; its final complete tree is identical to this tested source.
The currently readable logs were checked, not replaced by a new broad run.
See [the localization integration record](verification-localization-2026-10-13.md)
and [the preceding viewport/Lens/DNG increment](verification-viewport-lens-dng-integration-2026-10-13.md).

| Platform | Adopted proof and preserved limitation |
| --- | --- |
| iOS | Three framework slices, app, typed Lens/persistence checks and v7 UI 2/2. Six-language state and actual Files Save/copy verified; Files Cancel remains unverified. The earlier applied-NR/native JPEG and DNG busy-resize RED/GREEN evidence remains source scoped. No iOS PNG UI is claimed. |
| Android | Current dual-ABI build/APK/lint and five Sony single successes, without a successful aggregate. Same production APK/ELFs with DJI test fixture: CPU/forced GLES DNG `OK (1 test)`, 216.539 seconds. Two Sony 7008x4672 RAW-input preview/export attempts on a 2.5 GiB/four-CPU AVD requested longEdge128 preview and DNG/PNG outputs (full-resolution FINAL computation before resize). Guest `lmkd` SIGKILL occurred before the CPU-round completion marker; the failing stage is unknown. Original-size DNG file output was not verified, and these logs do not establish a writer-specific failure. DJI success does not replace the unfinished Sony-input run or prove physical-device GPU behavior. |
| Windows | Fresh managed six-language WPF state PASS, portable 29; full-feature native build and one GPU_OFF session JPEG/PNG16/DNG 128x85, statuses 0 and missing-directory DNG status 6. Hardware GPU, full CTest and RDP/manual desktop integration are not newly verified by #25. Earlier #27 Auto/Force D3D11/applied-NR/native JPEG/PNG and interaction proofs retain their own bindings. |

The earlier Android 2.5 GiB controlled before/current investigation and native
6000x4000 JPEG/PNG regression remain recorded in
[the memory investigation](verification-android-denoise-memory-2026-10-13.md)
and [the development migration](verification-viewport-development-2026-10-13.md).
Their unchanged 1,800,000,000-byte test budget is not a guarantee for arbitrary
RAWs or new Sony DNG SDK working sets. They were not rerun in this final pass.
Inherited #25 observations about RAW-to-raster disabled Lens selection and iOS
model-level DNG export guarding remain observations, not silently repaired here.

## Artifacts And Candidate Reuse

The own Mac source manifest `RUN/mac-core-source.sha256` has SHA-256
`70e4624a6b13d84b426529006abdc26cab5b3d199a0402dc0ccc561a3b65e3a2`.
The unchanged color contract is
`9c6d649459bb08062a3d148b9ed6214062d5a266a01e3ab8573d7b7581eba71c`.

| Artifact | SHA-256 |
| --- | --- |
| `lutools/build-macos/libsony2fuji_core.a` | `400f8053715f65595c9f9e1ce60c12100ae7fcf41dd9e46bbeaa7ac1f7e5da4c` |
| `RUN/RawLab Mac.app/Contents/MacOS/RawLabMac` | `31405da9f470607fb2cbe016e4570164cca5ea7589ba884ebd50ab75b1da3903` |
| Sorted app file manifest `RUN/package-files.sha256` | `b85fe2749c3896ac6005905289d210aa4389fce842606fa5021d70b8c4882b07` |
| Own LibRaw `libraw.25.dylib` | `fc65bcc1d8c5e891ce6d0e3b23ab91095a70c91d2836af528973fca1fe0e2806` |
| Own SDK `librawlab_dng_sdk.1.dylib` | `d55fafdb5e433d1a8a644e59a1d1f9c88ae1670c30e501b7ab71b903406ab0c3` |

Existing final #25 artifacts remain in
`/Users/xupeng/.codex/worktrees/multilingual-development/rawtools` (`I18N` below).
Its current HEAD/tree was independently checked clean and identical to the
tested source. The following iOS/Android SHA-256 values were measured from
existing files now; there was no unified build-time SHA manifest for all #25
artifacts, so they are not represented as historical per-binary source-hash
records. Current files and their associated final logs are available together.

| Existing artifact | Current SHA-256 |
| --- | --- |
| `I18N/lutools/build-ios/sony2fuji.xcframework/ios-arm64/sony2fuji.framework/sony2fuji` | `230601cf00472a96409b37bc4eff52326e0146c9629e6e846f7398f15348fd0a` |
| `I18N/lutools/build-ios/sony2fuji.xcframework/ios-arm64_x86_64-simulator/sony2fuji.framework/sony2fuji` | `a502bcdf3d81f74b9aab7f353094f3792f32ddd9dd3266cf74756ecfb9f7aa5e` |
| `I18N/RawLabAndroid/app/build/outputs/apk/debug/app-debug.apk` | `f67a6b84ecbee7f1d949b9972ac8eccfde466b6ddee8a9070b5c4eed3e350740` |

The iOS app and embedded matching simulator framework are in
`I18N/build/localization-integration-prep/ios-derived-v4/Build/Products/Debug-iphonesimulator/RawLab.app`.
The v7 UI command/log uses that DerivedData, owned simulator
`52D76F0A-FAE5-4409-9C2C-5C33C2E37AE6` and two explicit test selectors;
do not infer PASS/FAIL from the `v4` directory name.
The exact invocation is in `I18N/build/localization-integration-prep/ios-lens-dng-v7.log`.
Android ABI build directories are
`I18N/RawLabAndroid/app/build/intermediates/cxx/Debug/502o4556/obj/{arm64-v8a,x86_64}`.
The final build log records assembleDebug, assembleDebugAndroidTest,
testDebugUnitTest and lintDebug, but the unit task was UP-TO-DATE, not freshly run.

Windows retained isolated VM source `C:/RawLabBuild/i18n-final-20261013`, native
build `C:/RawLabBuild/i18n-final-20261013/ng`, and its own official Python 3.11.9
under `build/tools/python-lens`. The final logs in
`I18N/build/localization-integration-prep/` record Visual Studio 17 2022,
MSVC 19.44.35229.0 and Windows SDK 10.0.26100.0, direct production CMake build and
GPU_OFF export validation. They record these binary identities at validation:

| VM artifact | Recorded SHA-256 |
| --- | --- |
| `C:/RawLabBuild/i18n-final-20261013/ng/core/Release/sony2fuji.dll` | `d5c5d52b993d2101f4cd79b8d4fcee25e092f9ded511feeacf789af222bb512c` |
| `C:/RawLabBuild/i18n-final-20261013/ng/Release/raw.dll` | `ae839f7c4a58ff5e85eab43b97a904c8412f931ba27b8d5067413067a09d3a71` |

The earlier #27 native/managed workspace remains separate at
`C:/RawLabBuild/viewport-lens-dng-d810/workspace`, with the exact runner
`/Users/xupeng/.codex/worktrees/viewport-denoise-development/rawtools/build/viewport-lens-dng-d810/windows/validate_increment.py`
and `run-20261013-192359/{remote,resume}.log`. Its source manifest and actual
D3D11/native export checks retain the preceding increment's binding; do not
confuse that native DLL (`8c5a3184...`) with #25's GPU_OFF-validated DLL above.
The blocked early `i18n-20261013-113953` PowerShell-script run is not the final
native build. No execution policy or VM setting was changed in this pass.

Retain the own dependency caches and `RUN/{build-final,package-closure}.sh`,
`dependency-archives.sha256`, configure/build/combination/viewport/closure logs.
The package manifest binds the current complete app, not a future version bump.
Metadata-only candidate changes can reuse unchanged native source/configuration
evidence and caches; regenerate/recheck the client package, version metadata,
resource closure, signatures and artifact hashes. A different minimum-OS target
is a configuration change and cannot inherit this 26.0 compatibility result.
No main/tag/release/notarization/publication or CI/security change was performed.
These results are local/dedicated-host evidence, not GitHub exact-head CI.
