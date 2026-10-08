# Windows RAW performance — 2026-10-08

Based on `origin/codex/cross-platform-photo-zoom` at `2f49d7b` (Windows 0.2.0).
Implementation is on `codex/windows-raw-decode-performance`. Earlier uncommitted
work in the original checkout was preserved; selected parallelism and preview
changes were adapted to this newer branch, retaining zoom and EXIF export.

## Cause and changes

### Follow-up: opening, native zoom and panning

The decode improvements below did not resolve all interaction delays. A visible
WPF-window benchmark using a local copy of the user's `DSC02090.ARW` found:

| Interaction | Previous optimized build | Current build |
|---|---:|---:|
| First image without an existing thumbnail | 1059 ms | 43 ms |
| Exact RAW ready | 2018 ms | 1687 ms |
| First native-detail render | 393 ms | 405 ms |
| Subsequent native-detail toggles | 410–414 ms | 4 ms |
| Mean composition interval during native-size panning | 60.7 ms | 31.5 ms |
| P95 composition interval | 65.2 ms | 31.9 ms |
| WPF rendering tier | 0 (software) | 2 (hardware) |

The host reports `SystemParameters.IsRemoteSession=True`, with a Microsoft Remote
Display Adapter reporting 32 Hz. .NET 8 disables WPF GPU composition in RDP unless
the application opts in. The app and test runtime configurations now enable
`Switch.System.Windows.Media.EnableHardwareAccelerationInRdp`; see
[Microsoft's WPF runtime configuration documentation](https://learn.microsoft.com/en-us/dotnet/core/runtime-config/wpf).
No machine-wide registry or remote-session settings were changed. Native Direct3D
11 photo development and WPF canvas composition are separate acceleration paths.

The frame figures are `CompositionTarget.Rendering` callback intervals from a
visible 1440 × 920 window, not input-to-photon latency or a 60/120 fps claim.
Retained drawing alone, before the RDP opt-in, still measured 60.7 ms with tier 0.
The offscreen software paint microbenchmark stayed about 1.1 ms; managed
allocations over 60 pans fell from 704352 to 109632 bytes. Remote transport and
display pacing cannot be inferred from an offscreen paint benchmark.

Changes in this follow-up:

- Reuse the clicked thumbnail synchronously (1.6 ms dispatch in the test), then
  read a larger embedded camera preview without RAW unpack/demosaic. Label it as
  a camera preview, hide film labels, and keep export disabled until exact RAW is
  ready. Embedded reads use one running and one latest pending request; revisions
  prevent obsolete previews from replacing the selected photo or an exact frame.
- Read the active, oriented source dimensions with the preview. Native zoom
  immediately enlarges the existing image at the correct physical-pixel geometry
  (0.5 ms dispatch), then replaces its detail asynchronously without resetting pan.
  First full detail is still about 0.4 s; the improvement is immediate visual
  response, not an assertion that full-resolution processing became instantaneous.
- Retain image drawing layers and change their matrix transform for pan/zoom;
  keep wipe clipping and divider overlay separate. Use opaque Pbgra32 photo
  buffers so WPF does not need to convert their alpha format during composition.
- Cache exact 2000px and native frames for the current file/settings within a
  256 MiB pixel budget. Invalidate on adjustment, comparison/clipping, acceleration
  mode and RAW/LUT stamp changes. Replaced sources also reset the native session.
  Proxies never satisfy exact requests; exports bypass the cache. This budget
  excludes live UI images, native working data and GPU textures.

Validation: 119 managed/WPF checks passed, including immediate native geometry,
retained pan, preview-cache bounds/invalidation, source dimensions, masks, zoom,
GPU fallback, EXIF and full-resolution exports. All 38 original Sony/DJI output
hashes still match. Interaction checks also verify immediate thumbnail display
and export gating. The native shared rendering algorithm is unchanged in this
follow-up; the added Windows helper only extracts embedded preview/metadata.

Evidence: `build/interaction-before.log`, `build/interaction-after.log` (retained
layers with RDP acceleration still off), `build/interaction-rdp-after.log`,
`build/interaction-validation.log`, `build/interaction-pixels-{arw,dng}.log`.
Run `RawLabWindows.Tests.dll --interactions <repo> <raw>` after building the tests
to reproduce the visible-window measurements. Filesystem caches were not flushed.

### Initial decode pass

The original Windows build did not enable OpenMP for LibRaw. Its guarded AHD
demosaic parallel loops therefore ran serially, as did our camera-RGB conversion.
On this 32-logical-processor machine, a fresh exact Sony preview consumed about
one logical core on average (roughly 3% of total CPU capacity). Direct3D 11 runs
after RAW processing, so low GPU utilization during this stage is expected.

- Compile LibRaw and `raw_processor.cpp` with MSVC `/openmp`; parallelize independent
  output rows without changing pixel arithmetic. Keep unrelated core files on
  their existing compiler settings because their unsigned OpenMP loops are not
  compatible with classic MSVC OpenMP. Ship `vcomp140.dll` with app and tests.
- Convert private native RGBA buffers to WPF BGRA in place using SIMD, avoiding
  large managed pixel arrays. WPF copies the buffer before native memory is freed.
- Compute only the visible edited histogram; build clipping masks only when
  enabled, and skip the neutral image when comparison is disabled.
- Open with a 1000px half-size RAW proxy, then process an exact 2000px preview.
  The proxy cannot enable export; superseded work cannot schedule an old refinement.
  100% previews and exports retain full-resolution processing.
- Skip slider events that round to the existing parameter value.

The initial pass introduced no photo cache or alternative demosaic algorithm. RAW unpacking
still contains serial work; this does not move LibRaw decoding onto the GPU.

Compiler and library references: [MSVC OpenMP](https://learn.microsoft.com/en-us/cpp/build/reference/openmp-enable-openmp-2-0-support?view=msvc-170),
[LibRaw C++ API](https://www.libraw.org/docs/API-CXX.html).

## Local measurements

Intel i9-13900F (24 cores / 32 logical processors), NVIDIA RTX 4090 D,
MSVC 14.44, .NET 8 Release x64. No `OMP_NUM_THREADS` override.
Inputs: local copies of a 24MP Sony ARW (6024 × 4024 output) and the repository's
`DJI_20250602164503_0444_D.DNG`. Filesystem caches were not flushed. These are
short local runs, not disk-cold, network-drive, sustained throughput or FPS claims.

`--benchmark` uses identical work before/after: two images with both masks and
statistics. Times include native processing, GPU readback and WPF conversion;
pixel hashing is outside timings. Fresh exact and release are single observations;
warm/drag exposure are means of six, exact WB of two, and drag WB of three.

| Workload | Sony before | Sony after | DJI before | DJI after |
|---|---:|---:|---:|---:|
| Fresh-session exact preview | 3159 ms | 1556 ms | 1697 ms | 1106 ms |
| Warm 2000px preview | 68.7 ms | 56.1 ms | 102.7 ms | 83.3 ms |
| 1000px exposure dragging | 17.9 ms | 15.0 ms | 26.0 ms | 21.6 ms |
| Exact white-balance change | 2411 ms | 793 ms | 1007 ms | 414 ms |
| Interactive white-balance change | 214 ms | 152 ms | 97.6 ms | 77.7 ms |
| Exact white balance on release | 2416 ms | 792 ms | 1020 ms | 426 ms |

Sony fresh exact average CPU use, calculated as process CPU time / elapsed time,
increased from 0.99 to 8.34 logical cores. This includes runtime overhead and
OpenMP spinning, not just useful calculations; short intervals are coarse.
Warm Sony managed allocations fell from approximately 40.8 MiB to 17.4 KiB
per pair. Native, WPF and GPU allocations still exist.

The actual optimized default UI (comparison on, clipping off) averages 39.9 ms
for a warm 2000px pair and 11.4 ms for exposure dragging. A fresh session produces
its first RAW proxy in 908 ms, followed by 829 ms of exact refinement. The real
WPF dispatcher test observed first proxy at 888 ms and exact readiness at 1920 ms;
it polls in 30 ms intervals and also performs UI work. The proxy is a different
quality level; only the final exact image is compared for equivalence.

## Verification and reproduction

- All 38 corresponding before/after output SHA-256 hashes match across both files,
  including camera WB, absolute WB, interactive WB, exposure and final refinement.
- All 11 configured Windows native CTest cases passed (138 s before, 60 s after),
  including Sony/DJI acceleration, RAW reuse, WB, image statistics and DCP look tests.
- All 105 managed/WPF checks passed: fast-preview export gating, optional masks,
  comparison behavior, double-click zoom, CPU/GPU parity, Auto fallback, Force
  failure, full-resolution JPEG/16-bit PNG, capture EXIF and unchanged source bytes.
- Inspected the generated WPF screenshot; channel order and displayed content are
  correct. Self-contained publish includes the OpenMP runtime.
- The first combined build encountered a stalled .NET build process after CTest.
  Rebuilding tests with `--disable-build-servers -p:UseSharedCompilation=false`
  succeeded (zero C# warnings/errors); tests were then run separately. Native
  compilation retains pre-existing numeric-conversion warnings.
- Mac/iOS/Android, other camera families and other GPUs were not validated here.
  The optional Sony highlight fixture is absent and its dedicated test was not run.

```powershell
./RawLabWindows/build.ps1 -SelfContained -Test -RawPath 'C:/samples/photo.ARW'
# After building the test executable (use the same input for before/after):
dotnet ./RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --benchmark $PWD.Path 'C:/samples/photo.ARW'
dotnet ./RawLabWindows/tests/bin/Release/net8.0-windows/RawLabWindows.Tests.dll --benchmark-ui $PWD.Path 'C:/samples/photo.ARW'
```

Local evidence: `build/performance-{before,after}-{arw,dng}.log`,
`build/performance-ui-arw.log`, `build/performance-summary.json`,
`build/performance-build.log`, `build/performance-managed-build.log`,
`build/performance-validation.log` and `build/windows-verification/editor.png`.
