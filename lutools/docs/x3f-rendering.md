# X3F rendering contract

## Identity and compatibility

`legacy` uses the released LibRaw path, including its false-color appearance.
`normal-v1` uses the separate pinned X3F renderer. C/C++ sessions default to
legacy. Fresh edits on all four clients select normal; persisted records missing `x3fMode` decode
as legacy. Unknown identities are rejected. Reset preserves the selected mode;
preview, final export, batch snapshots and CLI recipes carry it explicitly.
Changing mode keeps ordinary edits and look selection. Explicitly switching to
normal mode disables incompatible AI RAW replacement in the same edit transaction. Decoder revision and mode
participate in source, exposure, WB and neutral-reference cache identities.

On Mac and iOS, selecting normal also disables distortion and transverse chromatic
aberration correction in that same settings update. Lens profile selection and
auto-crop preferences remain saved; returning to legacy does not re-enable the
correction flags. The normal-mode lens tools cannot activate additional correction.

CLI schema 7 carries the identity independently of the existing processing version
and binary request v2. Other RAW formats ignore this format-specific mode and keep
their existing processing. An X3F extension with an invalid signature is rejected.

## Input and output domains

The source RAW is read only. The bridge links x3fuse-core at commit
`00f9ef206a2d629bca35ceead4b3951833b85d3d`; no SPP executable or library is used at
runtime. The decoder applies CAMF-derived black, WB and spatial calibration.
Active crop and source orientation are applied once.

The family renderer returns display-encoded sRGB. The C++ boundary decodes its
transfer function once, then converts display-linear sRGB into the working space.
The scene-neutral shoulder, scene +0.7 EV and embedded-preview exposure matching
are bypassed. Downstream display adjustments and compatible look conversion use
the same engine as other inputs. A display-referred source has already lost some
scene latitude; adjusting it does not reconstruct clipped sensor highlights.

Saved X3F settings establish the source baseline. RawLab exposure and WB are
additional relative edits; neutral WB is 6500/0 as a coordinate, not an estimate of
capture Kelvin. Absolute/automatic RAW WB, FBDD, AI RAW replacement and additional
lens correction are rejected for normal X3F. GPU Auto uses the CPU path; Force
returns an unsupported error instead of claiming GPU processing.

Normal X3F loads use LibRaw for identification only; the pinned renderer owns pixel
decoding. Switching that processor to legacy performs LibRaw unpack lazily. The
orientation/transfer-function conversion and working-space conversion use the
existing bounded CPU pixel executor without changing per-pixel arithmetic.
The decoder parallelizes TRUE planes and SPP tiles with Rayon. RawLab's pinned
source patch also parallelizes Merrill chroma-offset worker calculations, final
highlight-repair rows and despeckle detection. Chroma-offset contributions merge
one at a time in their original order, including overlapping worker windows;
donor accumulation, bad-pixel repair and tile blending keep their required order.
These changes preserve output pixels across thread counts. The Merrill SPP path
still includes serial stages and rejects GPU execution. Platforms without hardware
fused multiply-add use the existing software implementation to preserve rounding.
Output resizing happens after full-resolution development, so a small export does
not avoid that initial cost. Ordinary scene-view GPU shaders cannot be enabled
for this display-referred path without implementing its separate tone contract.

## Camera and saved-setting admission

| Camera family | Renderer | Saved-setting boundary |
| --- | --- | --- |
| DP1S | CAMF scene calibration and a frozen empirical response | EV [-8,8], positive RGB color-wheel gains, contrast/highlights/shadows/saturation [-0.5,0.5], Fill Light [-0.5,0.6]; zero sharpness, supported color rendering; unknown nonzero controls rejected |
| Merrill | Pinned native SPP-style renderer | Neutral color mode, verified neutral seven controls, identity color wheel and matching neutral extension profile |
| Quattro | Pinned native AsShot renderer | Camera AsShot when SPPA is absent, or the exact verified neutral SPPA parameter profile |
| Other Classic cameras | Unavailable in normal-v1 | Explicit error; legacy remains selectable |

Family dispatch does not establish calibration for every camera body. In particular,
the DP1S response must never be applied to SD14, SD15, DP1 or DP2 merely because
they share a sensor generation. Merrill/Quattro coverage is limited by the
available reference photographs. Non-neutral SPPA controls, unsupported color
modes and unknown extension settings fail explicitly rather than being ignored.

The DP1S response approximates SPP from measured photographs. Exact Classic
ColorDQ/Retinex research kernels remain separate experiments: their real sensor
count calibration is unresolved. Diagnostic per-body highlight thresholds and
half-resolution detail heuristics are not production defaults. Remaining green
and clipped-highlight differences must not be represented as SPP equivalence.

## Platforms, export and errors

The product builds enable this renderer on macOS, Windows x64, iOS device/simulator
and Android arm64/x86_64. All clients expose the same explicit normal/legacy mode,
preserve it through reset and restore, and disable normal-mode RAW-only controls.
On mobile, a failed normal import retains its input until the user explicitly
retries with legacy or starts another import. A retry only saves legacy after a
successful render; invalid persisted records are not silently discarded.

Apple JPEG/PNG export preserves ImageIO-readable capture metadata. For a successfully
rendered X3F that ImageIO cannot read, it writes output dimensions, upright
orientation and color information without fabricated capture EXIF. Rendered DNG
uses the existing output-referred pixel contract. Source files are never updated
with RawLab adjustments. Android likewise tolerates missing capture EXIF only
after native rendering has validated the X3F input.

Cancellation is propagated through an independent atomic token and never publishes
partial pixels. Changing a source at the same path invalidates its file identity
cache, including replacement with unchanged length and timestamp. Errors retain a
specific reason so the UI can offer the legacy mode without silently switching.

## Build and maintenance

CMake option `SONY2FUJI_ENABLE_X3F` enables the bridge. Cross builds require
`RAWLAB_X3F_RUST_TARGET`; use one Mac architecture per build. Cargo uses the locked
dependencies. Install Rust 1.88+ and `rust-docs`; packaging gathers dependency and
standard-library notices from the actual toolchain. No downloaded binary decoder
or runtime environment tuning is accepted. Python 3.11+ collects notices, and bindgen
requires host libclang. Product wrappers select these targets:

| Product | Rust target |
| --- | --- |
| macOS | `aarch64-apple-darwin` or `x86_64-apple-darwin` |
| iOS device | `aarch64-apple-ios` |
| iOS simulator | `aarch64-apple-ios-sim`, `x86_64-apple-ios` |
| Android | `aarch64-linux-android`, `x86_64-linux-android` |
| Windows x64 | `x86_64-pc-windows-msvc` |

iOS uses the matching Xcode SDK and deployment target for C and Rust. Android uses
the selected NDK ABI/API compiler, archiver and sysroot. Windows uses MSVC; a GCC
Rust target cannot be substituted. Build jobs prepare Rust 1.99.1 with the listed
targets and `rust-docs`; all packages include dependency and Rust runtime notices.

Changes to profiles require a new renderer identity and independent held-out
photographs. See [bridge provenance](../x3f-bridge/README.md). Core regressions cover
mode/cache isolation, ordinary RAW invariance, invalid signatures and cancellation;
`RawLabMac/tests/X3FWorkflowTests.swift` exercises the real Mac engine, RGB16 export,
CLI parity and persisted edits with a supplied original X3F. iOS provides
`RawLab/tests/x3f-workflow.sh` and the dedicated-simulator `x3f-ui.sh`; Android has
`X3fRenderingTest` and `X3fEditorTest` instrumentation tests; Windows provides
`RawLabWindows.Tests --x3f <repo> <raw> <output>` and the UIA host with
`RAWLAB_X3F_UI=1`. Device tests require external fixtures and run locally, separately
from CI compilation. Build success alone does not establish device or camera coverage.
