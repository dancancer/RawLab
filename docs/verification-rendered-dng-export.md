# Rendered DNG Export Verification

## Scope

The implementation is isolated on `feature/rendered-dng-export`, based on
`origin/development` at `12d6cc1`. The primary checkout and its unrelated edits
were not modified. Delivery uses a feature PR targeting `development`; merging
and release are outside the current authorization.

Rendered DNG bakes the FINAL display-sRGB image after the selected look, white
balance, exposure, tone/HSL, denoising, sharpening, vignette, grain and final
resize. It is not sensor RAW and does not preserve independently editable RawLab
controls. The shared encoder uses DNG 1.4 float32 RGB LinearRaw, inverse sRGB,
an output-referred D50 virtual profile and neutral Adobe settings.

Source capture EXIF, MakerNotes and sensor calibration are not copied. Existing
JPEG/PNG metadata handling is unchanged. Uncompressed storage is approximately
12 bytes per pixel. Classic TIFF outputs above the 4 GiB container limit are
rejected. Mobile DNG exports use files, not the photo library.

## Mac And Lightroom

The packaged Mac application exposes rendered DNG in single-export menus and
the batch format picker. A current-edit-memory photo was exported through the
actual single-export UI to both DNG and 16-bit PNG without changing its settings.

The focused real-RAW test also exercised nonzero adjustment categories, CPU and
forced Metal, original size and a 1536-pixel long edge. For each backend and size,
single and batch DNG files were byte-identical and source identity was unchanged.

The actual batch UI was then exercised with DNG, original size and an isolated
output folder. It reported one success and zero failures; the published DNG was
byte-identical to the current-settings single-export UI file. Only the validation
application was quit, and its owned test journal/look snapshot were moved out of
the default batch directory into ignored validation artifacts.

Lightroom Classic 14.1 imported two production DNG files using Add, without
Develop presets. Both were inspected in Develop and exported as uncompressed,
unresized, unsharpened 16-bit sRGB TIFFs. The file Software tags identify
`Adobe Photoshop Lightroom Classic 14.1 (Macintosh)`; ICC is
`sRGB IEC61966-2.1`. Export XMP retains zero exposure/tone/detail/effects controls
and a Linear curve rather than reapplying the baked RawLab adjustments.

| Reference | Dimensions | Max error / 65535 | Mean error / 65535 | Max error / RGB8 step |
| --- | --- | --- | --- | --- |
| Current Mac adjustments | 4608 x 3072 | 26 | 1.428045 | 0.101167 |
| Nonzero effects / forced Metal | 4608 x 3072 | 50 | 1.982398 | 0.194553 |

Both comparisons pass the acceptance threshold of one RGB8 step (257 units in
RGB16). This validates these actual Lightroom imports, not arbitrary import
presets or subsequent edits. Photoshop / Camera Raw is not installed and remains
unverified.

The Adobe DNG SDK 1.4 validator also completed without warnings/errors on a
production Metal DNG. Its sRGB RGB16 decode differed from the matching PNG by at
most 35/65535 (0.136187 RGB8 steps).

## Checks

Run from the repository root, with `RAWLAB_TEST_RAW` pointing to an external
full-resolution Bayer RAW when a fixture is required:

```sh
bash RawLabMac/build.sh
bash RawLabMac/tests/batch-export.sh
bash RawLabMac/tests/edit-model.sh
bash RawLabMac/tests/chroma-settings.sh
bash RawLabMac/tests/wavelet-settings.sh
bash RawLabMac/tests/denoise-model.sh "$RAWLAB_TEST_RAW"
bash RawLabMac/tests/adjustments.sh "$RAWLAB_TEST_RAW"
bash RawLabMac/tests/rendered-dng.sh "$RAWLAB_TEST_RAW" output/rendered-dng-validation
ctest --test-dir lutools/build-macos --output-on-failure
```

Cross-platform checks use the regular platform commands:

```sh
bash lutools/platform/ios/build-framework.sh
bash lutools/platform/ios/verify-framework.sh
bash RawLab/tests/batch-export.sh
# IOS_SIMULATOR_APP is the linked arm64 simulator RawLab.app.
RAWLAB_TEST_RAW="$RAWLAB_TEST_RAW" bash RawLab/tests/processor-export.sh "$IOS_SIMULATOR_APP" "$IOS_SIMULATOR_ID"
# From RawLabAndroid:
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

Synthetic tests independently read tags and float pixels with libtiff. Storage
regressions cover unwritable paths, failed publication, replacement of an
existing output, invalid pixels and a POSIX mid-write file-size-limit failure.
Failed writes preserve the existing destination and remove owned staging files.
C ABI regressions require FINAL FILE output, reject DNG buffer/preview requests
and retain request layouts. The appended status `OUTPUT_IO_ERROR = 6` separates
DNG output-storage failure from source `IO_ERROR = 3`, so a bad source remains a
per-photo failure while a full/unwritable output stops the batch. Previous status
values and JPEG/PNG error behavior are unchanged.

An initial whole-core run with the Sony small-size RAW passed 18/21 checks.
`raw_noise`, `raw_reuse` and `raw_white_balance` failed identically on the
unchanged `development` baseline. All three pass with the full-resolution Bayer
fixture. No RAW processing algorithm was changed to mask those fixture failures.
The final whole-core run with the full-resolution fixture passed 21/21 checks.

The CLI was also corrected to map DNG extensions case-insensitively to format 4
rather than writing JPEG bytes under a DNG filename. System libtiff must be at
least the verified 4.7.1 version, or builds can select the pinned source dependency
with `SONY2FUJI_BUILD_TIFF_DEPS=ON`.

### iOS Publication Error Regressions

The production file writer now lives with the Foundation-only batch core so the
existing host suite exercises its real file moves and journal checkpoints.
After a successful publication, a failed checkpoint is classified as uncertain
rather than a normal per-photo failure. A regression temporarily makes the real
journal directory unavailable, restores it for the interrupted-state save, then
reloads and continues the job. The completed DNG is verified and neither rendered
nor replaced again.

Output-directory creation failures are converted to global storage errors in the
shared directory entry point used by both rendering and publication. Regressions
place a normal file at the job's directory path and verify both paths stop after
the first target, retain the second target as pending and preserve the blocker.
Both failures were reproduced before the fixes; the expanded batch suite and
simulator app build passed after the changes.

### iOS Confirmation Routing

Both DNG confirmation actions now check the output files directly, without
requesting Photos authorization or presenting the JPEG-only manual confirmation
dialog. The model also routes obsolete manual DNG confirmation calls through
file recovery rather than trusting a saved/unsaved choice. Reconciliation refreshes
the file export list and persists the checked state; missing outputs become
pending while existing outputs stay completed. Recovery also clears the resolved
checkpoint warning without clearing unresolved global storage errors.

`RawLab/tests/batch-publication.sh` compiles the actual iOS model and app sources
into a standalone simulator test process, using its own bundle with Photos access
explicitly denied. The regression reproduced the authorization failure before
the fix and now checks permission-free DNG recovery, unchanged output bytes,
post-open file deletion, refreshed export actions and journal state, as well as
the retained JPEG authorization and manual-confirmation behavior. It does not
inject a live checkpoint failure into the SwiftUI view; that state remains
covered by the real writer/journal regression in the batch core suite.

```sh
bash RawLab/tests/batch-publication.sh "$IOS_SIMULATOR_APP" "$IOS_SIMULATOR_ID"
```

### Android Physical Device

The Android production code at `04985e9` was tested on a Lenovo TB320FC,
Android 15 / API 35, arm64-v8a / SM8475. Every device operation used an explicit
dedicated serial; no Gradle `connected*` task or shared emulator was used.

A real 32 MP Sony Bayer RAW was injected only into the test APK. The native
regression rendered CPU and forced GLES outputs with nonzero look strength,
exposure, custom WB/tint, all tone/detail categories, HSL, wavelet/display-chroma
denoising, vignette and grain. Source digests were unchanged. The 128-pixel final
long-edge limit produced upright 85 x 128 float32 RGB DNG 1.4 images.

Independent libtiff/stb decoding compares DNG linear float samples, re-encoded
to sRGB, against the matching 16-bit PNG. Both CPU and GLES have maximum error
1/65535 (0.003891 RGB8 steps). Their encoded RGB8 comparison has maximum
difference one code value. The actual editor single output, both batch outputs
and forced-GLES native output were byte-identical for the same frozen settings.

The real system document pickers were separately exercised through the app UI:
single DNG with Gallery disabled, custom 128-pixel sizing, and one-target batch
export into an explicitly granted test folder. Both UI exports succeeded and
were byte-identical; the original RAW digest remained unchanged.

The instrumented workflow uses that system-granted SAF tree to exercise the
actual editor/model and two-target batch publication. It also reloads ready
publishing rows as completed without replacing their files. A separate regression
creates a known partial DNG document and verifies actual provider deletion,
pending recovery and journal persistence. These model tests do not themselves
automate the external picker; the preceding UI check covers its callbacks.
Diagnostics stay in app-specific test artifacts, while the tests remove their
own published SAF documents after collection.

All three DNG device regressions and the existing JPEG frozen-size recovery
regression passed in focused runs. The workflow also verifies target edit records
against their actual pre-export snapshots, including camera-derived white balance,
using a freshly loaded edit store. APK builds, JVM unit tests and lint passed.
An earlier aggregate run had one workflow assertion failure because its expected
target edits used factory WB defaults instead of the actual pre-export state.
The expectation was corrected and the focused workflow rerun passed; no
production behavior was changed to resolve that test failure.

`assembleDebugAndroidTest` exposed one remaining legacy Boolean JPEG test caller;
it now passes `ExportFormat.JPEG`. The change affects tests only, not production
rendering, file publication or the C ABI. No photos or generated outputs are
included in the source changes.

Build the APKs without touching devices, then install and run only on the
dedicated device. Grant a test folder through the app's directory picker first:

```sh
# From RawLabAndroid, with an external RAW fixture:
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest \
  :app:testDebugUnitTest :app:lintDebug -PrawlabTestRaw="$RAWLAB_TEST_RAW"
: "${ANDROID_DEVICE:?Use a dedicated device serial}"
: "${DNG_TEST_TREE:?Use the system-granted test folder URI}"
adb -s "$ANDROID_DEVICE" install -r app/build/outputs/apk/debug/app-debug.apk
adb -s "$ANDROID_DEVICE" install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb -s "$ANDROID_DEVICE" shell am instrument -w -r \
  -e dngTreeUri "$DNG_TEST_TREE" \
  -e class com.rawlab.android.RenderedDngInstrumentedTest \
  com.rawlab.android.test/androidx.test.runner.AndroidJUnitRunner
```

The pixel validator is a host-only diagnostic using existing libtiff and the
repository's stb decoder; it introduces no Android runtime dependency:

```sh
# From the repository root on the verified Mac host:
c++ -std=c++17 -O2 -I/opt/homebrew/opt/libtiff/include -Ilutools/src \
  RawLabAndroid/tests/rendered_dng_pixels.cpp -L/opt/homebrew/opt/libtiff/lib \
  -ltiff -o /tmp/rawlab-rendered-dng-pixels
/tmp/rawlab-rendered-dng-pixels cpu.dng cpu.png gles.dng
/tmp/rawlab-rendered-dng-pixels gles.dng gles.png
```

### Windows Standalone Test Includes

Both existing portable `net8.0` test projects were reproduced with .NET SDK
8.0.425 / runtime 8.0.31 on macOS arm64. Before the fix, editing failed with
`CS0246` for `ExportFormat`, and denoise failed with `CS0103` for
`ExportFormatExtensions`. The explicit source lists omitted the new format
helper; editing also referenced `WindowsFileIdentity` through its shared feature
checks without including that source.

Only the project source lists changed: editing now includes `ExportFormat.cs`
and `WindowsFileIdentity.cs`, and denoise includes `ExportFormat.cs`. Both
original entry points then compiled and completed with exit code 0:

```sh
dotnet run --project RawLabWindows/tests/editing/EditWorkflow.Tests.csproj -c Release
dotnet run --project RawLabWindows/tests/denoise/DenoiseSettingsTests.csproj -c Release
```

Local before/after logs are retained under `output/windows-dng-standalone/` and
are not committed. The editing source-alias hard-link check printed its existing
skip on this non-Windows host. These results cover the portable managed tests,
not Windows kernel32 behavior, WPF, native DLL/D3D11 rendering or actual Windows
DNG publication. No production source, workflow or execution policy changed.

### Windows Native Runtime

Actual Windows 11 execution used an isolated source workspace based on
`1890f830`, with this increment applied before rebuilding. MSVC 19.44,
CMake 3.31.6 and .NET SDK 8.0.425 produced fresh native and WPF binaries;
no RawLab binaries from another workspace were used. The test's native DLL
digest matched the freshly built DLL. Execution policy and account identity
were not changed.

The first WPF builds exposed missing `System.IO` imports in `ExportFormat`,
`WindowsFileIdentity` and the existing shared feature regression helper. Adding
only those imports allowed the application and test project to build with zero
warnings and errors. Both original portable editing/denoise entry points also
passed on actual Windows, including the NTFS hard-link identity check rather
than its non-Windows skip.

The first native `rendered_dng` CTest failed with `Error writing TIFF header`
(0/1, exit 8). The pinned libtiff Win32 backend interprets `TIFFFdOpen`'s integer
argument as the significant 32 bits of a native `HANDLE`, not a CRT descriptor.
The writer now retains and passes that handle directly, transfers ownership only
on a successful open, and otherwise closes it during cleanup. POSIX descriptor
handling, pixel math and the C ABI are unchanged. The same CTest then passed 1/1.

The staging regression previously scanned only the POSIX filename marker, so
Windows cleanup assertions could miss native `rld*.tmp` files. A Windows probe
reproduced that blind spot (exit 8); the platform-specific scan now detects those
files and the replacement/failed-publication cleanup regression passes 1/1.
This verifies normal failures, not abrupt process termination or Windows
mid-write failure injection.

The focused `--rendered-dng` runtime test uses an owned copy of a real 32 MP
Bayer RAW, nonzero settings across all adjustment categories, a frozen look and
a 128-pixel FINAL long edge. CPU reports backend 0; Auto and Force both report
actual Direct3D 11 backend 3. Independent libtiff/stb decoding confirms upright
85 x 128 float32 RGB DNG 1.4 files with these observed errors:

| Backend | Max DNG/PNG16 error / 65535 | Mean error / 65535 |
| --- | --- | --- |
| CPU | 1 | 0.000735294 |
| Auto / Direct3D 11 | 1 | 0.000888480 |
| Force / Direct3D 11 | 1 | 0.000888480 |

CPU and D3D11 differ by at most one encoded RGB8 value; Auto and Force DNGs
are byte-identical. The same runtime checks reject source aliases, verify that
the production source handle blocks rename, and preserve an existing DNG after
a missing-source failure.

The initial runtime attempt stopped before batch execution because the new test
harness assigned `null` to WPF's `StartupUri`. This was a test initialization
error, not a production export failure. The harness now uses a plain
`Application` with the two production resource dictionaries, without scheduling
the default MainWindow or loading its global journal. The corrected complete
runtime finished with exit 0: the real DNG option and export button published
both targets, with FINAL size/settings retained and bytes identical to the
single Auto export. An existing colliding output was preserved. Publishing
journal recovery skipped both completed files without changing their bytes or
timestamps; a simulated running journal removed its known partial DNG and
restored waiting. Original RAW digests and preseeded source/target edit records
were unchanged. This does not exercise MainWindow's live-edit task creation or
the DNG SaveFileDialog, nor does simulated journal recovery prove strong-kill
recovery.

The unchanged `--photo-features` entry point also completed with exit 0 and
44 checks. It covers real ExifTool metadata, the export-size menu/custom dialog,
one-target JPEG batch, PNG16/JPEG final sizing and metadata preservation, source
digests and existing WPF layout/actions. Explorer interaction explicitly printed
`NOT REACHED` because the SSH process runs in session 0. No shared default batch
journal existed before this run; no profile/journal cleanup was needed.

Commands from the configured isolated Windows source workspace:

```powershell
cmake --build build/windows-native --config Release --target sony2fuji rendered_dng_tests --parallel 6
ctest --test-dir build/windows-native -C Release -R '^rendered_dng$' --output-on-failure --no-tests=error
dotnet build RawLabWindows/RawLabWindows.csproj -c Release
dotnet build RawLabWindows/tests/RawLabWindows.Tests.csproj -c Release
dotnet run --project RawLabWindows/tests/editing/EditWorkflow.Tests.csproj -c Release
dotnet run --project RawLabWindows/tests/denoise/DenoiseSettingsTests.csproj -c Release
# Put the freshly built native DLL/dependencies and the existing ExifTool
# distribution in the WPF test output before running the actual runtime tests.
dotnet RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --rendered-dng $PWD $env:RAWLAB_TEST_RAW
dotnet RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --photo-features $PWD $env:RAWLAB_TEST_RAW
```

Local before/after logs and generated images remain under ignored
`output/windows-dng-runtime-1890f830/`. They are not committed.

### Development Integration

The shared feature branch merges `development` at
`caf51809102489dd0ecc5bc185352fe9992a5177` into the reviewed `d5d0b27` source,
without rebase or force-push. Six conflicts in CMake, Mac/Windows/iOS build and
notice files, and `core_tests.cpp` retain both JPEG XL decoding and rendered-DNG
writing. Both sets of C ABI error/output assertions remain. The installation
documents from `78f5d84` are unchanged from the target.

The later documentation-only target `261b9323bea13f562bcfee7db736fcf1728704f5`
is merged normally after these code gates. Its 126 changed paths are Markdown;
the two client README conflicts retain rendered-DNG descriptions and updated
archive links. The non-Markdown code manifest is identical to the verified
`e30660b` integration commit, so the platform gates are not rerun for that
documentation advance. The release tracker remains its explicitly dated
preparation snapshot, not a claim that all five feature branches are integrated.

The combined static core introduced a real Swift test-link regression:
`batch-export.sh` and `rendered-dng.sh` failed with an undefined `dng_host`
constructor. All 21 existing native Swift link commands now include the SDK
alongside libtiff, and the common dependency check requires both. The batch
model test then passed. `RAWLAB_DNG_TEST_LONG_EDGE=128` optionally limits the
rendered-DNG harness for this integration check; its original-size/1536 default
and pixel comparison thresholds are unchanged.

The first Mac build's SDK OOM check failed because old pkg-config cache data
linked another prefix's LibRaw and loaded two SDK instances. LibRaw/SDK were
rebuilt in this worktree and the stale LibRaw discovery cache was refreshed;
the final loader trace confirms one SDK and LibRaw from the same owned prefix.
No source correction or reduced OOM assertion was used for that environment
failure. The rebuilt application passed dependency closure, signing and both
SDK/TIFF license checks. The final core CTest passed 22/22, including both
conflicted assertion groups and all 14 JXL fixtures.

The actual packaged Mac smoke entry passed with a real JPEG XL camera DNG and
the existing DJI fixture. Nonzero-adjustment CPU and forced-Metal exports from
the real JXL input produced 96 x 128 DNGs, each byte-identical to its batch
output and preserving source identity. Independently decoded PNG16 comparisons
have maximum error 1/65535 for both backends; their encoded RGB8 difference is
at most one. A CLI JXL/DefaultCrop/GainMap input also exported a 20 x 28 DNG and
PNG pair with maximum error 1/65535. Minimal decoder-only synthetic JXL fixtures
cannot serve as the app smoke's embedded-preview or ImageIO metadata fixture;
those preliminary client checks failed and were rerun with the real camera
fixture without weakening their assertions.

The rebuilt iOS device arm64 and simulator arm64/x86_64 framework slices pass
architecture, runtime dependency and combined SDK/TIFF notice verification.
Windows targeted DNG/JXL/C ABI/real-RAW CTest passed 4/4; fresh WPF app/test builds
have zero warnings/errors, and the merged PowerShell script passes syntax plus
the recursive copy check for all six SDK notices and the TIFF notice. The
complete Windows DNG runtime then passed with the freshly rebuilt DLL: CPU and
actual Auto/Force D3D11 exports produced 85 x 128 outputs, the WPF batch published
both targets with identical FINAL bytes, and recovery skipped completed files
without changing bytes or timestamps. Source/edit records and the colliding
output were unchanged; known partial batch staging was removed. Independent
PNG16 comparisons have maximum error 1/65535 for all three backends. The native
build has upstream warnings; zero warnings refers only to the managed builds.
This run does not reach SaveFileDialog or Explorer and is not a full PowerShell
publish/package run.

Android `assembleDebug`, `testDebugUnitTest` and `lintDebug` completed successfully
after configuring the existing SDK path. Both arm64-v8a and x86_64 native builds
include the combined SDK/TIFF dependencies; the APK contains both ABI libraries
and all seven notices. Lint has no Error/Fatal findings. The unchanged Kotlin
unit-test task was UP-TO-DATE, not a fresh device or JVM test execution. The
earlier physical-device checks above remain the device evidence, not a new
integration-head device run.

The Android pre-Start format/destination report was checked against the existing
batch design, UI/model call chain and pre-DNG implementation. Output choices are
session draft state until Start freezes and journals them; closing SELECTING
discards that draft. Neither the design nor historical tests promise recovery
of these unstarted output choices across app close/restart, and the timing is
unchanged from the former JPEG/PNG implementation. No new persistence behavior
was added, and Activity recreation is not described as cold-start recovery.

Integration logs, dependency caches, source archives and images remain only in
ignored `output/dng-development-integration-caf5180/` and build directories.
No device, emulator or simulator runtime was operated for this integration.
The Lens/Stage3-warning follow-up is owned by its separate feature branch and
is not duplicated here. These results are local, not hosted CI.

## Platform Boundaries

- Mac final build and focused Swift/native tests have completed successfully.
  Both actual single and batch UI exports and the real-RAW batch runner were
  verified.
- Android explicit formats, JNI mapping, legacy journals and SAF file output are
  implemented. `:app:testDebugUnitTest`, `:app:lintDebug` and `:app:assembleDebug`
  passed, including arm64-v8a and x86_64 native builds. APK libtiff license
  packaging was checked. The physical-device UI/SAF and CPU/forced-GLES DNG
  checks above passed on TB320FC; no existing RawLab installation was overwritten.
  This does not cover every camera/device, large native-size DNG output, abrupt
  process death or revoked SAF permission during publication.
- iOS direct FINAL file rendering and persistent DNG batch file output are
  implemented. Device, arm64 simulator and x86_64 simulator framework builds and
  license checks passed. The simulator app linked successfully; synthetic
  processor/DNG/orientation/effects and batch recovery runtime tests passed.
  Completed DNG journals remain resumable until explicit dismissal, stale
  container output paths relocate and deleted outputs become pending again.
  A real full-resolution Bayer RAW was exported to an upright 85 x 128 DNG with
  nonzero WB, exposure, tone/HSL, look strength, denoising, sharpening, vignette
  and grain. Independently decoded float pixels, re-encoded to sRGB RGB8,
  differed from the matching iOS final buffer by at most one code value. CPU and
  forced-Metal DNGs differed by at most 0.189580 RGB8 steps. Device/UI
  document-picker validation remains unverified.
- Windows single/batch WPF integration, legacy journal tests and license
  packaging are implemented. Single export validates the selected format's
  extension and protects original-file aliases with a Windows file identity and
  a non-delete-sharing source handle during publication. The two portable
  managed test projects above pass on Mac and actual Windows. Fresh Windows
  native/WPF builds, kernel32 identity/source-lock checks, CPU/Auto/forced-D3D11
  file rendering and two-target WPF DNG publication/recovery passed as described
  above. DNG MainWindow SaveFileDialog/Explorer desktop interaction, original-size
  large DNG and abrupt process termination remain unverified.

Photos, DNG/TIFF/PNG files, screenshots, private source paths and build products
are not part of the source changes. Local comparison metrics and artifacts live
only under ignored `output/` directories.

Normal write/publication failures clean up staging files. Abrupt process
termination can leave an unreferenced native staging file; it is not published
as a completed DNG and is not currently part of batch-journal cleanup.
