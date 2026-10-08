# Windows verification

## v0.2 — 2026-09-29

Built from `codex/all-platform-strength-exif` using .NET 8 and MSVC on Windows
x64 with the NVIDIA Direct3D 11 backend. The external Sony ILCE-7M2 ARW was
copied into ignored `build/` for testing; no original photo was modified.

- Core CTest: **7/7 passed**.
- Full Windows integration run: **95 checks passed**, including 200% film CPU /
  Direct3D 11 parity and 6024 × 4024 JPEG / 16-bit PNG exports retaining real RAW
  camera, capture date and exposure metadata.
- Follow-up UI/metadata run: **68 checks passed**, including the added real WPF
  slider checks: default 100% at midpoint, 200% at the upper endpoint, stale
  exports blocked until the new render completes. The generated 200% editor
  screenshot was visually inspected.
- Synthetic metadata fixtures verify camera/lens/date, shutter, aperture, ISO
  and GPS preservation, normalized orientation/dimensions/sRGB, omitted old
  thumbnails, Unicode paths, missing shooting metadata and source protection.
- JPEG scan data and PNG IDAT data are byte-identical before/after metadata
  attachment. PNG retains 16-bit channels and contains a standard `eXIf` chunk.
- ExifTool 13.59 is packaged locally with its complete runtime, sources and
  licenses; its Windows archive is pinned by SHA-256. No separate installation
  is required.

Other platforms were not built or retested on this Windows host for v0.2.
Their source changes are already on the release branch; installation packages
will be added separately. Previous results below describe the earlier build.

## Previous verification — 2026-09-28

## Environment and fixtures

- Windows x64, MSVC 19.44 / Visual Studio 2022 Build Tools, .NET SDK 8.0.425.
- NVIDIA GeForce RTX 4090 D, driver 32.0.16.1656.
- External photos from `Z:\Photo\2019\2019-02-02`:
  - `_DSC0205.ARW`: Sony ILCE-7M2, developed size 6024 × 4024.
  - `DSC02737.ARW`: developed size 4920 × 3276.
- Original photos were read only. Core tests use a copy under ignored `build/`;
  Unicode-path tests make a separate copy. No photos are included in this change.
- The old `DSC09067.ARW` was removed from the repository at the user's request.

## Results

The full core suite passed **7/7** using `_DSC0205.ARW`: color contracts,
histogram/clipping statistics, synthetic GPU cases, real RAW CPU/GPU acceleration,
RAW decode reuse, white balance and RAW input/exposure tests.

The Windows integration runner passed **67 checks on each external fixture**,
including actual Direct3D backend reporting, all adjustment controls, camera WB
reset, interactive/exact separation, Unicode RAW/LUT/output paths, full-resolution
JPEG and 16-bit PNG, protected input, unavailable-input errors, automatic CPU
fallback and forced-GPU failure. Native-resolution display and 16-bit PNG differ
by at most one 8-bit code value after quantization.

The real RAW CPU/GPU comparison differed by at most **one 8-bit code value** across
as-shot/4000 K/8500 K and the combined tone/detail settings. Synthetic cases
(non-unit LUT domains, strengths 0/0.5/1/2, 1×N detail borders and preview/final
resize order) matched the CPU's 8-bit output exactly on this GPU.

Additional WPF checks cover file enumeration on the external photo directory,
latest-request replacement, export gating, per-photo exposure restoration, GPU
status and rendered window content. Window PNGs were inspected for layout.

### Preview timing

Three warm 2000px film renders, including readback, bitmap conversion and CPU
histogram/clipping analysis; RAW was already decoded and uploaded. These numbers
do not describe initial open time or a white-balance change that needs demosaic.

| Fixture | CPU mean | Direct3D 11 mean |
|---|---:|---:|
| `_DSC0205.ARW` | 372.9 ms | 32.3 ms |
| `DSC02737.ARW` | 349.2 ms | 32.4 ms |

Timing is observational, not a CI performance threshold.

## Reproduce

### Windows UI follow-up

Impeccable's polish guidance was applied to the existing dark desktop design.
The local WPF review runner passed **56 checks** with `DSC02737.ARW`, including
six new synthetic checks for wipe comparison endpoints and responsive thumbnail
columns. It also checked file-tree resizing/restoration, visible-only thumbnail
decoding, film/adjustment category switching and the actual Direct3D backend.
Native WPF captures at 1440 × 920 and 1000 × 680 were inspected, together with
the styled exposure and comparison menus. These are offscreen WPF renders;
physical mouse input, screen-reader narration and mixed-DPI monitors were not
part of this follow-up.

The file tree now uses the standard expander once, one or two thumbnail columns,
and filename ellipsis with a full-name tooltip. Toolbars use vector icons;
Lucide's Film icon is used under its ISC license. Menus, focus states and loading
feedback share the dark palette. The new comparison mode reveals neutral on the
left and the edited result on the right without rerendering or changing export.

### Commands

```powershell
./RawLabWindows/build.ps1 -Test -RawPath 'Z:\Photo\2019\2019-02-02\_DSC0205.ARW'
./RawLabWindows/build.ps1 -SelfContained
```

Logs and generated exports/screenshots are local ignored build artifacts.
Mac/iOS/Android builds were not run on this Windows host. Their fixture paths
were adapted to external files following sample removal. Intel/AMD adapters,
multiple monitors, different DPI settings and the remaining photos in the
external directory have not been validated. The four DNG files in that directory
were not part of these runs.
