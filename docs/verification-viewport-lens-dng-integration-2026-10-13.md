# Viewport / Lens / DNG Integration Increment

## Source And Scope

The viewport feature normally merges `development` at
`d810fe6e47fbc70be79786a8ebaee2d1e9e9fe0e` into
`feature/viewport-denoise-preview` at
`90809a718b71786308fac750497959cd6e83630c`. This preserves the existing feature
history and the already merged JPEG XL, rendered DNG and Lens implementations.
The six conflict paths are the core C ABI session, iOS processor/helpers,
Android editor/native tests and Windows window. No public request layout or
existing enum value is changed by the conflict resolutions.

Validation uses the staged normal-merge source identified by those immutable
parents; the resulting source commit is recorded in PR #27. The sorted checksum
manifest for 60 non-Markdown feature paths relative to `d810fe6` is
`be656f12197be66d1f7eb41b29023511859d724938cffd860b92a4ab7d0b1faf`.
The color contract checksum is
`9c6d649459bb08062a3d148b9ed6214062d5a266a01e3ab8573d7b7581eba71c`.
Generated logs and validation artifacts stay under ignored
`build/viewport-lens-dng-d810/` in this worktree.

This is a bounded composition check, not a rerun of the historical Android
2.5 GiB cold/warm/Scene experiments or the completed SDK Stage3/Lens suites.
Their original results remain scoped to their recorded source and configuration.
The Android memory implementation is unchanged in this merge; its test's three
file calls only adopt the new `ExportFormat` API, retaining the original
1,800,000,000-byte assertion and fixture/strength controls.

## Preserved Merge Semantics

- The core retains `WaveletRenderCache`, its exact/viewport slots and budget,
  while retaining the Lens database revision, configuration, reports, RAW key
  and preview-exposure anchor. The actual baseline float remains in the NR key.
- iOS initializes the bundled Lens database once when creating its persistent
  preview session. Loading it on every preview would increment the database
  revision and defeat NR reuse. Fresh exact, Auto and file sessions retain
  their existing database initialization.
- Android preview work retains its viewport edge while file work uses the
  typed JPEG/PNG/DNG format. Independent native references remain serial,
  rather than retaining two full-resolution RAW sessions simultaneously.
- Windows JPEG, PNG, DNG and batch controls retain pending-resize/busy/exact
  guards, including checks before and after the native file dialog.

## One Real Combination Regression

`rendered_dng_tests` now has a separate, explicitly selected real-RAW case.
Configure `SONY2FUJI_TEST_LENS_WAVELET_RAW` with an eligible input; ordinary
`SONY2FUJI_TEST_RAW` remains usable with arbitrary supported cameras. The
combination case hard-fails if Lens calibration or visibly applied NR is absent.
It never silently treats an ineligible fixture as a successful combination.

Fixture: Sony `DSC06251.ARW`, original geometry 4672x7008, SHA-256
`dc280884db9e0d2e1e7389dca1370958ea8fde749cef8169702f64237d98763f`.
The test selects a matching distortion/TCA profile from the pinned Lens
database and uses wavelet strengths 40/46/50. RAW files are read-only.

The single sequence checks applied Lens and NR, viewport 1600/1024/1600 reuse,
downstream-edit NR reuse, manual/automatic profile and auto-crop changes,
database-revision invalidation, exact baseline/report equality with independent
equivalent viewport sessions, and native FINAL with both preview flags left on.
Native JPEG, 16-bit PNG and float32 DNG are compared with a fresh independent
FINAL session, including whole-file equality, decoded geometry and PNG/DNG
pixel checks. Internal filter/output/analysis counters prove the intended
invalidation and reuse; no diagnostic C ABI was added.

The first run failed three history assertions because its fresh reference had
not enabled viewport mode: it compared reduced-source NR with full-source NR
followed by resize. Only the reference configuration was corrected, and pixel,
baseline and report checks were separated to avoid short-circuit masking.
Production code and equality thresholds were not changed. The corrected case
passed in 74.95 seconds. After adding actual file decoding and optional GPU
Force coverage, the final case passed in 88.63 seconds:

- PNG/DNG maximum error against independent RGB8: 0.498054/0.50001, limit 1.
- Force Metal FINAL maximum CPU-reference error: 1, limit 2; filter-count
  increment proves Force did not reuse the CPU-filtered output.
- Native three-format history/fresh files are byte-identical.
- Explicit fixture registration yields one combination CTest; leaving that
  option unset yields zero, regardless of the generic real-RAW option.

Command: `SONY2FUJI_TEST_GPU=1 ctest --test-dir lutools/build-macos -V -R
'^rendered_dng_lens_wavelet$'`. Logs: `combo-current.log`,
`combo-viewport-matched.log`, `combo-final.log` and
`combo-registration-{default,explicit}.log`.

## Fresh Client Bindings And Outputs

The old standalone Mac dependency prefix was SDK-free. The increment builds
matched SDK-enabled LibRaw 0.22.2, SDK 1.7.1, Lensfun 0.3.4 and TIFF 4.7.1 from
pinned, SHA-verified source into this worktree, retaining unchanged OpenCV,
wavelib and other dependency builds. A fresh core cache/link audit confirms the
worktree's own headers/libraries, not another checkout's binary prefix.

macOS arm64 Release app build uses minimum target 26.0 on macOS 27.0 and the
existing Xcode toolchain. The first static dependency/signature check passed,
but actual DYLD tracing exposed source-prefix LCMS/JPEG/OpenMP loads: the new
CMake LibRaw/dependencies retained absolute `LC_RPATH` values. That initial
static pass is not counted as runtime closure. A new bundle RPATH assertion
failed against that package. The packager now removes non-system absolute
RPATHs from every copied Mach-O, then uses the existing signing sequence; it
does not alter installed dependencies, algorithms or locked versions.

The rebuilt package passes the strengthened bundle assertion, bundled Lens
XML/SDK/TIFF license comparisons, minimum-version check and strict ad-hoc
signature. Packaged smoke passes with DYLD overrides cleared both with the
source prefix present and with it temporarily hidden/restored by an exit trap.
Actual SDK/Lens/LCMS/JPEG/OpenMP loads are inside the app bundle, with no source
prefix or Homebrew load. Native JPEG/PNG bytes are equal between these two
runs. Logs: `macos-rpath-red.log`, `macos-rpath-green-build.log`,
`macos-rpath-green-runtime.log` and `macos-isolated-startup.log`.

The viewport Swift test's first link failed because its feature-only script
omitted SDK/Lens/TIFF libraries. Its package flags now match the integrated
core. The same viewport test passed after this binding-only correction,
including applied Panasonic NR, native JPEG/16-bit PNG against independent
FINAL, CPU/Metal, resize bursts, stale timers/current edits, 100% restoration
and export readiness. Logs: `macos-viewport.log` and
`macos-viewport-green.log`.

Android fresh arm64 app/test APK, unit and lint tasks passed: all 81 tasks
executed, 65 unit cases with zero failures, lint zero errors/38 existing
warnings. Runtime checks use a newly owned API 35 arm64 AVD with 6 GiB RAM,
private ADB port 5038 and explicit serial `emulator-5682`; this is not the
historical 2.5 GiB memory gate. The Sony run finished with three passes (Lens,
CPU/Force GLES DNG, quiet resize/latest edit) and one fixture-precondition
failure: Clean NR 10/72/100 did not change its RGB8 pixels. This is not recorded
as four passes, and the Sony failure log is retained. The original applied-NR
Panasonic fixture then passed the same NR/native JPEG/16PNG test in 210.17
seconds, including independent serial FINAL references and GLES parity. No
strength or equality threshold was weakened. Only the test APK's RAW asset was
changed for this retry; production APK/native source remained unchanged.

Production APK SHA-256:
`ec92adb2ac9037304a86f9ba26236169ca2813ccf8b0d74a22bb1be0b7c4f994`.
Stripped arm64 JNI SHA-256:
`c7c9b5359c6bec6edb268b4b7b0ee83aedd5536feeeff1850d3534c163cacf1a`.
Logs: `android-build.log`, `android-focused.log`, `android-pan-test-apk.log`
and `android-pan-nr.log`. The owned emulator and private ADB server are stopped.

iOS fresh arm64 device and arm64/x86_64 simulator slices, framework dependency/
license verification, app, dedicated Lens/DNG helper and viewport-state helper
passed. The first framework configure failed on a pinned GLib/PCRE2 download
SSL EOF; retry used this worktree's already SHA-verified source cache without
TLS/version changes or borrowed binaries. The old standalone processor-export
driver then failed because a bare executable could not locate bundled Lens
resources. Its scaffold now follows the existing Lens/DNG helper's `.app` and
`Frameworks` layout with a relative runtime path.

Only that affected helper was rerun. It passed with Sony for Lens and a
separate `RAWLAB_TEST_DENOISE_RAW` Panasonic input for the existing native-NR
segment, now including a hard NR-on/off pixel-change precondition. Viewport
512/768 to native 6000x4000 JPEG equals independent FINAL bytes; actual RAW DNG
and Force Metal/reference checks also pass. The 14-recipe loop was not enabled.
The selected iOS path does not export 16-bit PNG, and no such result is claimed.
Logs are under `ios/`; owned simulator
`FC48B47E-EC1B-4DB7-912A-01D9FE3C883C` is shut down.

Windows fresh native DLL, self-contained WPF package and managed tests compiled
in `C:/RawLabBuild/viewport-lens-dng-d810/workspace`. Matched LibRaw 0.22.2,
SDK 1.7.1, Lensfun 0.3.4, TIFF 4.7.1, OpenCV 4.12.0 and NR/D3D11 options are
verified from the new workspace's cache/link outputs. Only source archives from
the existing dependency cache were reused, not another workspace's binaries.

The ignored runner first used `bin/Release` instead of the actual `bin/x64/Release`
managed output path after successful compilation. It was corrected to query
MSBuild `TargetDir`; no dependency rebuild or source change was made for that
collection failure. The resumed focused commands all ended with exit zero:

- `--denoise` on Panasonic: applied NR, viewport/exact isolation, actual Auto/
  Force D3D11 and fallback/rejection, native sixteen-bit PNG, and JPEG after
  viewport matching independent FINAL.
- `--rendered-dng` on Sony: CPU/Auto/Force DNG and 16PNG references at 85x128,
  actual backends 0/3/3, typed three-format exports, source/alias protection,
  frozen batch publication, recovery and unchanged RAW bytes.
- `--interactions` on Sony: actual WPF opening, physical-pixel resize/zoom,
  native source geometry, repeated Fit/100% and resize/export busy guards.

Native DLL SHA-256:
`8c5a318495bd46fc8398cdaa541e1c1fec9135d62e05acde193a563fb337550c`.
Logs: `windows/run-20261013-192359/{remote,resume}.log`. All owned remote
sessions ended. The as-built 416-file archive manifest matches the current
worktree in 415 paths; its sole later difference is the optional combination
fixture registration in CMake, which changes no Windows DLL options/code.
That case was not selected for this Windows build. The new shared native-size
three-format combination is verified separately by the core case above.

The Windows test explicitly reports `NOT REACHED MainWindow SaveFileDialog and
Explorer desktop integration`. No manual Explorer/publication or new end-to-end
native-dialog result is inferred from the managed checks.

## Review And Limits

The two original independent reviewers covered the frozen 22-path integration
increment and adjacent calls after the client gates. Both found one Should:
iOS DNG success/failure callbacks did not replay viewport changes received while
export was busy, unlike JPEG. This affected the post-export preview size, not
FINAL file pixels. A real tiny-raster DNG success/failure regression reproduced
both missing replays before the production change; neither a compile error nor
a missing Lens bundle was accepted as RED evidence.

The two callbacks now perform the same requested-size/current-settings replay
as JPEG. With the unchanged test, both cases and the existing resize-state cases
pass. The test preserves the latest edge 896 and exposure 0.5 after two busy
resize events. The affected iOS app source was recompiled successfully; native
frameworks and the previously completed platform/export gates were not rerun.
Logs: `ios/dng-busy-resize-{red,green}.log` and
`ios/dng-busy-app-build.log`. Both original reviewers rechecked only that
three-path fix and closed the Should, with no new Must/Should. Their conclusion
is bound to the final 60-path manifest above; see
[the incremental review](../reviews/self-viewport-lens-dng-increment-20261013.md).

No hosted CI success or platform runtime not actually run is claimed here.
This work does not modify the final integration candidate worktree, localization,
versions, main, tags, releases, signing policy or system security settings.
