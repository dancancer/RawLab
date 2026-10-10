# RawLab v0.5.1 Release Verification

Date: 2026-10-10. Version `0.5.1`, build `9`.

The release branch starts from `development` at
`6a0ff634a4f73a0d65371f8048ae49716747be96`. Feature commit
`b072c678fb368987ec2277824652c610f266976b` was integrated through PR #14
after the published v0.5.0 changes returned to `development` through PR #13.
The original dirty checkout, private signing files and personal RAW files are
untouched. Release edits change version metadata and documentation, not runtime
algorithms.

Client executables and the shared native core were rebuilt from this release
tree. Unchanged pinned dependency and compiler caches were reused; this is not
a claim that every third-party dependency was rebuilt. Mac dependency caches
retain their macOS 15 deployment target. Apple builds use Xcode 27.0; Windows
builds use native MSVC/.NET on the prepared Windows x64 host rather than
cross-compilation on macOS.

## Release-Tree Gates

| Check | Confirmed result |
| --- | --- |
| Mac arm64 and x86_64 builds | Both built with deployment target 15.0; bundle checks passed architecture, dependency closure and ad-hoc signatures. |
| Mac core CTest | 19/19 passed on arm64 and 19/19 on x86_64 under Rosetta, including real Sony ARW/DJI DNG, CPU/Metal, wavelet/chroma and effects checks. |
| Mac application smoke | Both newly built apps passed real Sony/DJI preview, native JPEG/16-bit PNG export and missing-input rejection. |
| Mac model checks | Edit-memory and batch-export tests passed against the freshly built arm64 macOS 15 core; update release selection and update-check state tests passed. |
| Android signed Release | ARM64/x86_64 APK built; version 0.5.1/9, SDK minimum 26, v2/v3 signatures and all eight native ZIP/ELF 16 KB alignment checks passed. |
| Android Release host checks | 55/55 JVM tests, zero failures/errors/skips; `lintRelease` passed. |
| Android release certificate | SHA-256 matches the published release identity: `9fd68e245a597cde2abb949ff807819a89afdd4b000b5ad02391181f38a06048`. |
| Android Release native filters | Current RelWithDebInfo `gpu_filter_tests` passed on the connected Lenovo TB320FC, Android 15, with GLES execution and clean teardown. Complete wavelet/chroma float maxima were `1.49012e-7` / `2.68221e-7`; effects maximum was `6.58035e-5`. |
| Android Release native pipeline | Current RelWithDebInfo `rawlab_gpu_tests` passed actual-backend assertions, synthetic tone/detail/resize, fallback/Force failure and combined effects/wavelet/chroma/detail checks. Combined FINAL CPU/GLES maximum was 0 code values and repeated grain was identical. |
| iOS framework and apps | Device arm64 and simulator arm64/x86_64 XCFramework, unsigned device Release app and arm64 simulator Debug app built successfully. |
| iOS current framework rendering | `processor-export.sh` passed against the newly built simulator app, including real Sony JPEG sizing/EXIF and forced Metal with effects, wavelet, display-chroma and detail. GPU output matched CPU within 2 code values; repeated grain was identical. |
| iOS model/resource checks | Presentation, edit-memory and batch-export suites passed. |
| Windows native build | Current-source Release build passed all 14 CTest cases; none was skipped. |
| Windows default application checks | All 126 managed/native/WPF checks passed against the current build, including actual D3D11 RAW rendering, export dimensions/metadata, source protection and rendered-window content. |
| Windows additional denoise | Combined effects/wavelet/chroma/detail matched CPU within 2 code values, Auto/Force actually used D3D11, repeated grain was identical and backend disabling exercised fallback/failure. Native 16-bit PNG matched independent exact denoise within one code value. |
| Windows photo-feature checks | All 44 checks passed, including sizing, metadata, setting propagation and all five vignette labels at narrow widths. Actual published executable file version was 0.5.1.9. |
| Client archives | All five packages passed archive integrity, actual version, GPL/attribution and personal-RAW exclusion checks; ExifTool's small upstream test corpus remains in its own distribution. Documentation link/language checks also passed. |

These GPU checks assert the actual backend; an adapter display name does not
prove compute support. No physical Windows GPU model or comparative speedup is
inferred. Numerical comparisons use tolerances, not cross-driver bit identity.

## Feature-Stage Evidence

The [implementation report](verification-cross-platform-effects-gpu-denoise-2026-10-10.md)
records the earlier tests of the same runtime implementation, including Android
real Sony/DJI RAW instrumentation and both effects-control tests, iOS targeted
effects UI and inspected Windows/Android/iOS screenshots. Those are not reruns
of the final signed packages. The release report above records the new builds
and checks performed after version metadata changed.

The signed Android APK was not installed over the tablet's differently signed
debug app: doing so would require removing existing application data. Release
native GLES executables were tested independently in a dedicated temporary
device directory; the earlier UI/instrumentation tests used debug APKs.

Mac smoke tests cover Sony/DJI fixtures and Windows application checks use a
Sony fixture, not every camera. Earlier camera reports remain historical evidence, not new
full-camera validation for v0.5.1. Nikon HE* remains rejected as documented.

## Release Assembly

The Gitflow delivery merges the verified release branch to `main`, checks that
the merged tree equals the built release tree, and tags that commit `v0.5.1`.
The source-package gate archives that exact tag, supplies the pinned dependency
archives and corresponding patched LibRaw source, and records source/built
commits, tree and dependency hashes in `BUILD-PROVENANCE.json`. `SHA256SUMS.txt`
identifies the seven payload assets. Upload validation compares every remote
asset's size and SHA-256 before publishing; release changes return to
`development` through a PR. Final remote operations are evidenced by the PRs,
tag and GitHub Release rather than a post-publication source edit.

See [release notes](releases/v0.5.1.md),
[corresponding-source build instructions](releases/v0.5.1-source.md),
[installation](installation.md) and [licensing](licensing.md).

Local Git-ignored evidence is under `build/releases/v0.5.1/logs/` and `assets/`,
with the Windows transfer/build log under
`build/windows-remote/20261010-203145/`. These logs are not distributed source
and are not GitHub CI results.

## Remaining Limits

- No GitHub Actions workflow is configured; empty PR checks are not passing CI.
- Windows Explorer desktop interaction was **NOT REACHED** because the runner
  was in session 0. Native WPF controls and window rendering passed separately.
- iOS device builds are unsigned. Physical iPhone installation, GPU behavior,
  memory and thermals are not tested; simulator Metal is not physical coverage.
- Mac apps are ad-hoc signed, not notarized. Native Intel hardware and physical
  macOS 15 are untested; x86_64 execution here uses Rosetta.
- Low-memory devices, every camera mode, accessibility-size/landscape effects
  controls and comparative denoise performance are not covered. RAW processing
  remains memory-intensive; this is not an all-GPU RAW pipeline.
