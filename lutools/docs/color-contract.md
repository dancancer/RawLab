# Photo Rendering Contract

## RAW Input

The C API session and CLI keep their scene-mode default for compatibility. New
photo settings in all four native clients instead select `preview` (embedded
preview matching); a full/input-group reset also selects `preview`. Restoring a
saved exposure mode never replaces it with the new default. Older saved records
without an exposure-mode field retain `scene`, preserving their previous pixels.
The scene-mode 0 EV baseline described below applies when that mode is selected.

LibRaw performs black subtraction, active-area crop, white balance, demosaic and highlight blending in camera channels. WB must precede demosaic: the earlier no-auto-scale path produced a measurable difference from LibRaw's normal WB-before-demosaic processing. Histogram auto-bright, content-dependent maximum adjustment and integer output-color conversion remain disabled. `highlight=2` retains maximum-normalized WB before 16-bit demosaic and blends clipped highlight chroma after demosaic, before our camera matrix and LUT. The former `highlight=1` unclip mode preserved false magenta in saturated DSC06251 car-body highlights. Blending is not darktable's opposed-chroma reconstruction and cannot recover lost sensor detail; bright colors can become less saturated. We recover green-normalized camera RGB as `image16 / (65535 * post_scale_pre_mul[1])`, then apply the camera-to-sRGB matrix in float. Matrix negatives and values above 1 survive; we do not globally clamp scene RGB to 1. This is not an all-float demosaic: quantization and LibRaw's treatment of sensor-overrange values remain. The raw source is never written.

Default 0 EV is a declared scene-development baseline: **+0.7 EV plus valid DNG BaselineExposure**. The +0.7 is a workflow starting point, inspired by darktable's scene defaults, NOT sensor calibration or a claim that every camera needs this exact offset. DNG metadata is applied once (DJI fixture: +0.35, total +1.05 EV; Sony without that tag: +0.7 EV). Missing/sentinel/non-finite/out-of-range metadata falls back to zero metadata offset. User +1 EV still doubles the linear input. The default never decodes or meters the embedded JPEG. We deliberately do not undo a photographer's EXIF ExposureBiasValue, and do not invent undocumented camera-specific dynamic-range compensation.

Optional `preview` mode retains the earlier median matching approximation: it samples 128x128 luminance values and applies `preview_median / raw_median` instead of the scene baseline, not on top of it. Preview styles, profiles, cropping and black borders can bias it. Untagged previews assume sRGB; known non-sRGB DNG previews are skipped, gray gamma 2.2 is handled explicitly. Missing/invalid references fall back to the scene baseline. Sensor mode applies neither metadata nor the workflow boost. In C++, disable both `applyBaselineExposure` and `matchEmbeddedPreviewExposure` for sensor mode. The C ABI exposes `sony2fuji_session_set_raw_exposure_mode` without changing the v2 request layout; the mode is part of the RAW cache key. Mac exposes all three modes and the actual base offset. Sensor saturation is not recoverable, and film LUTs may deliberately change apparent brightness.

`RAWProcessor` returns float working data. `outputBitsPerSample=8/16` only quantizes the non-linear display path; the linear path always retains float precision. The legacy `getNativeColorSpace()` name returns the last processed working space. Unspecified camera-native matrix transforms now fail instead of substituting sRGB primaries.

Embedded camera color data is selected independently of white-balance mode
(`use_camera_matrix=3`). Changing from camera WB to Kelvin/tint must not also
switch from an embedded matrix to LibRaw's fallback matrix. Unpack error counts
are fatal even when LibRaw returns success, so damaged decoder output cannot be
exported as a valid image. Preview exposure retains its 64-million-pixel decode
limit and uses a smaller embedded thumbnail when the default preview exceeds it.

Source dependency builds apply `cmake/patch-libraw.cmake` to LibRaw 0.22.2.
X-Trans demosaic tiles read an immutable source copy before parallel processing;
their output must never feed adjacent tiles' overlapping source halos. This
keeps OpenMP enabled but adds eight bytes per active sensor pixel during X-Trans
demosaic (about 304 MiB for a 40 MP image). Camera-specific corrections and their
sample-limited validation are documented in the RAW compatibility report.

JPEG XL DNG (compression 52546) uses the pinned Adobe DNG SDK 1.7.1 through
LibRaw, with a per-processor host whose lifetime exceeds LibRaw's. Only this
decoder receives the SDK host. `LIBRAW_RAWOPTIONS_DNG_STAGE2` runs Stage1
opcodes before linearization even when OpcodeList2/3 are absent.
these flags must be present during final LibRaw identification, not just
unpack, so SDK-linearized channels do not receive a second range-based WB
correction. The core first identifies the decoder without retained SDK flags,
then reopens only JXL with its Stage2 flags. Other formats keep their original
single-open identification and cannot inherit JXL state across reuse.
`LIBRAW_RAWOPTIONS_DNG_STAGE23_IFPRESENT_JPGJXL` also applies Stage3 when present.
`LIBRAW_RAWOPTIONS_DNG_ALLOWSIZECHANGE` lets LibRaw synchronize the SDK's
ActiveArea-cropped dimensions and clear the storage margins. The glue also
translates inset crop origins into the cropped image coordinates, avoiding
rejection, a second ActiveArea crop or a shifted DefaultCrop. Unsupported
required opcodes fail rather than being ignored.
LibRaw then develops the decoded camera channels using the existing exposure
and color pipeline. SDK memory exceptions retain their OutOfMemory category
through initial load, white-balance reload and the C ABI.
Other RAW/DNG formats retain their previous decoder paths. SDK and LibRaw must
share the same platform and `qDNGThreadSafe` definitions to preserve SDK class
layout, including on iOS/Android. XMP editing and the SDK validator are not
included. Synthetic lossless 16-bit LinearRaw fixtures compare JXL with the
same uncompressed pixels, including a Stage1-only required MapTable, a required
Stage2 GainMap with internal ActiveArea, orientation, WB reload and decoder
reuse. The SDK allocation-failure hook verifies the C ABI memory status.

### Display-Referred Raster Input

The additive `SONY2FUJI_INPUT_DISPLAY_BUFFER=2` consumes tightly packed opaque
RGB8/RGBA8 display-sRGB. Existing `RAW=0`, scene `BUFFER=1`, request v2 layout and
their rendering are unchanged. The shared macOS/iOS ImageIO adapter applies EXIF orientation
once and converts tagged RGB to sRGB; untagged RGB assumes sRGB. It accepts
single-frame 8-bit SDR JPEG, PNG, TIFF and HEIF. Transparency, higher bit depth,
floating-point/HDR, multi-frame/page and CMYK inputs are rejected, not flattened
or silently quantized. Untagged grayscale/indexed images are not inferred to use
a particular gray transfer function and are rejected.

Display input is inverse-sRGB-decoded once, uses the existing linear exposure,
wavelet, look, tone/HSL, chroma/detail/effects and geometry stages, and re-encodes
sRGB instead of adding the RAW scene sigmoid. With defaults its RGB8 pixels
round-trip exactly. It receives no RAW exposure baseline, as-shot WB, FBDD or
lens calibration. The native clients disable camera-specific controls; mixed
batch snapshots resolve those controls independently for each input. Agent v4
uses explicit `input.type=raster`, `exposure.mode=sensor` and WB `none` and rejects
explicit RAW-only edits. A RAW film/DCP look applied to already rendered pixels
is a creative effect, not recovery of sensor latitude or a calibrated camera match.

This display-referred path reuses the reference CPU stages. GPU Auto explicitly
falls back to CPU and Force returns unsupported until the scene-view GPU
shaders have a matching display-input mode. Rendered DNG output preserves the
result as output-referred float RGB; it does not turn an 8-bit source into RAW/HDR.
The Apple adapter uses ImageIO. Windows has a separate WIC adapter for JPEG/PNG
and classic single-page RGB8 TIFF, verified on Windows rather than inferred from
Mac results; HEIF and BigTIFF are not enabled. Unknown non-sRGB PNG color metadata
without a supported ICC profile is rejected instead of guessed. Android uses a
separate API-26-compatible platform decoder for validated JPEG/PNG files and
passes their oriented opaque display-sRGB pixels through the same explicit
display-buffer C API. Android does not enable TIFF or HEIF; its native file-loader
entry point remains unsupported rather than pretending to decode those files.
The native clients resolve camera-only settings separately for every mixed-batch
target and retain the original frozen recipe. A raster source's dormant camera
WB, lens and exposure-baseline values do not become active on a RAW target:
the target uses its own as-shot WB and the client's default RAW exposure mode.
An active master recipe's tint remains a relative style offset against that
target WB, not a source-camera WB value to copy or discard.
Mobile Agent interfaces remain out
of scope. Desktop evidence and remaining ICC/physical-device limits are recorded
in `RawLabWindows/VERIFICATION-agent-v08.md`; mobile evidence is recorded in
`../../docs/verification-raster-input-all-platforms-2026-10-16.md`.

## Rendering Order

1. Decode RAW to linear RGB with the selected exposure baseline, or inverse-sRGB-decode an explicitly tagged raster buffer. Buffer inputs receive neither RAW metadata nor the +0.7 baseline.
2. Run optional linear-sRGB wavelet denoising, then apply relative white balance and `2^exposure_ev * brightness` in linear sRGB. Custom RAW WB multipliers are applied once, during decode.
3. Generate the neutral reference with a fixed log-logistic display curve, then sRGB encode. For positive x the linear display value is `1 / (1 + ((1-g)/g) * (g/x)^1.5)`, with `g=0.1845`; black is 0 and highlights approach 1 smoothly. This independently implemented mathematical subset follows the same curve family as darktable sigmoid, but does not reproduce its primaries adjustment, hue-preservation or full default pipeline.
4. For a film CUBE: start from the un-tonemapped linear input, transform to its declared F-Gamut or F-Gamut C and encode F-Log, F-Log2 or F-Log2C, then interpolate the CUBE. Named display outputs bypass the neutral curve. Explicit Log outputs are decoded back to linear BT.709/sRGB, then rendered with the neutral display curve. A compiled DCP `.rlook` instead evaluates its preserved matrix/HSV/tone stages directly from common linear sRGB, without F-Log2, an RGB CUBE or an extra neutral curve. Log encoding itself never normalizes exposure, and there is no linear clamp at 1 before it.
5. Blend neutral and film outputs in the same display-encoded RGB convention. Strength 0 is continuous with the no-LUT rendering. Contrast, saturation and curves follow, then HSL, optional display-chroma denoising, detail adjustments, vignette and grain, optional geometry, and final resizing.

Geometry uses the oriented, lens-processed full source: clockwise quarter turns,
flips in that canvas, centered horizontal/vertical perspective, centered inscribed
straightening, then normalized crop. Perspective and straightening share one
bilinear sampling pass; zero perspective preserves basic geometry exactly.
It bypasses interactive proxies and early resizing while active. Integer geometry
copies pixels; straightening samples once with bilinear edge extension, without
clipping linear values. Identity preserves existing rendering. The common CPU
geometry stage also finishes GPU Auto output; Force with active geometry returns
unsupported. Units, canvas rounding and API lifecycle are in [Edit JSON](edit-json.md#geometry-in-recipe-v2).
6. Write RGB/RGBA preview, JPEG, actual 16-bit PNG, or rendered DNG. PNG includes an sRGB chunk. Photo outputs use an sRGB display interpretation; the film-simulation names alone do not establish camera-to-camera colorimetric equivalence or a measured display EOTF. JPEG consumers must use this sRGB interpretation.

### Rendered DNG

`SONY2FUJI_OUTPUT_DNG=4` is an additive FILE-only format; request v2 layout and
existing format values are unchanged. It consumes the same FINAL display-sRGB
float RGB after LUT/recipe strength, WB/exposure, tone, HSL, denoising, detail,
effects and final resize. It never serializes interactive proxies or scene RAW.

The encoder rejects nonfinite values, clips SDR channels to [0,1] like PNG, and
inverse-sRGB-decodes them to float32 RGB. DNG 1.4 LinearRaw stores this
output-referred image (`ColorimetricReference=1`) under a virtual linear-sRGB
camera, Bradford D65-to-D50 ColorMatrix/ForwardMatrix, D50 white, zero baseline,
identity tone curve and DefaultBlackRender None. Neutral Adobe XMP disables
initial tone, sharpening, noise reduction and effects. The already oriented
pixels have orientation 1. No original sensor pixels, capture EXIF, old preview,
MakerNotes or source camera calibration is copied into this virtual profile.

The preserved result is appearance, not original RAW latitude or separately
reversible RawLab controls. Lightroom import presets or later edits can change
the appearance. Serialization uses libtiff, with an uncompressed three-channel
float image and no ExtraSamples. There is no JPEG/PNG intermediate quantization.

DNG writes stage in the destination directory and atomically replace the target
only after a successful flush. Failed writes preserve existing output files.
Classic TIFF size is preflighted below 4 GiB; BigTIFF is not emitted. The additive
`SONY2FUJI_STATUS_OUTPUT_IO_ERROR=6` distinguishes output storage failures from
source `IO_ERROR=3`, without renumbering existing statuses or changing requests.

In exact/default rendering, sharpening skips the early preview downsample. The fixed pixel-radius filter runs at source resolution before the final preview resize, matching its export footprint. The separately opted-in viewport approximation below filters the reduced input instead. At zero sharpening the existing fast preview path remains unchanged. Mac's contrast/saturation controls use percent offsets from the core's identity value 1; highlight signs are reversed at the UI boundary so positive values consistently brighten. All six output adjustments default to an identity result.

The film output interpretation is a declared application convention. It is not a claim that Fujifilm's short LUT overview specifies every viewing parameter. No guessed extra gamma is applied to an already rendered film LUT output.

### HSL Mixer

`sony2fuji_session_set_hsl` takes a versioned 104-byte configuration without
changing request v2. Hue, saturation and lightness each have eight values in
red/orange/yellow/green/aqua/blue/purple/magenta order, all in [-100,100]. Clients
set the complete configuration on every render and freeze it in batch snapshots.
Invalid/nonfinite values leave the session's previous configuration intact.

HSL runs on display-encoded sRGB, after existing tone/color adjustments and
before chroma denoising, detail and effects. Circular hue centers are
0/30/60/120/180/240/270/300 degrees. Smoothstep interpolation mixes the adjacent
channels. Hue shifts by 0.3 degrees per control unit, saturation multiplies by
`1 + value/100`, and lightness adds `value/200`; saturation/lightness clamp to
[0,1]. Achromatic pixels remain unchanged. A zero configuration is an exact
bypass. These controls are an application convention, not a Lightroom match.
For RGB channel spreads below one RGB8 code value (`1/255`), hue-dependent
lightness offsets fade with `smoothstep(0,1/255,max(rgb)-min(rgb))`. Hue is
ill-conditioned near gray; applying a full lightness offset there amplified
CPU/GPU floating-point differences into visible brightness speckles. This fade
is shared by CPU and all three GPU backends, leaves hue/saturation controls
unchanged and becomes exactly one at or above `1/255`.
RGB/HSL conversion follows the standard definition in
[CSS Color](https://www.w3.org/TR/css-color-4/#hsl-to-rgb).

HSL executes in the Metal, GLES or D3D11 photo shader after tone/color and before
chroma filtering, detail and effects. Metal also supports HSL with native DCP
looks; GLES/D3D11 retain their existing CPU-only native-DCP fallback. GPU Auto
uses the complete photo GPU pipeline when available and falls back on failure;
GPU Force requires real platform-GPU success, never a hidden CPU HSL stage.
Identity HSL bypasses exactly. RAW upload caches retain only linear input, not
the current HSL result, so HSL changes do not reuse stale display pixels.

CPU remains the reference. GPU tests compare every HSL axis/channel, mixed
extremes, hue wrap, resized previews and final output within two RGB8 code values.
The combined Metal native-DCP/HSL/effects float test allows 1e-4 for propagated
DCP rounding, while the isolated HSL/effects stage stays within 5e-5. HSL does
not alter exposure metering or camera white balance.

### Automatic Exposure

`sony2fuji_session_estimate_auto_exposure` is an additive, non-rendering operation.
It returns an absolute user EV in [-4,4], not a delta to the current EV. It uses
the selected RAW baseline and camera-space WB, or an explicitly tagged raster
buffer. RAW metering always uses the exact decode, not an interactive proxy or
the embedded preview pixels. The current user EV, LUT, HSL and output adjustments
do not enter the calculation.

The estimator samples at most 256x256 linear-sRGB luminance values, targets a
median of 0.1845 and constrains positive boosts using the 99.5th percentile and a
linear highlight target of 4. It is a bounded starting-point heuristic, not a
scene-understanding algorithm or a promise of unclipped sensor highlights.
All-black/unusable input returns UNSUPPORTED without changing the caller's EV.
The operation does not apply its result to the session. Clients meter off the
UI thread and discard results when the photo or captured settings changed.

### Vignette and Film Grain

`sony2fuji_session_set_photo_effects` adds a versioned configuration without
changing request v2. Amounts default to zero, an exact bypass even if auxiliary
settings are retained. Invalid/nonfinite configuration leaves session state intact.
Clients set the full configuration on every render, including neutral renders.

Vignette Amount spans -100..100: negative darkens, positive lightens. Midpoint
restricts coverage as it increases; Roundness changes a rounded rectangle through
an image-aspect ellipse to a circle. Feather smooths the boundary; Highlights
protects bright areas only for negative Amount. Defaults are 0/50/0/50/0. Controls
reference [Lightroom post-crop vignette](https://helpx.adobe.com/ie/lightroom-classic/desktop/process-and-develop-photos/retouch-photos.html),
not lens correction or Adobe's proprietary rendering styles.

Grain Amount/Size/Roughness span 0..100, defaulting to 0/25/50. Two scales of
normalized interpolated spatial noise share a fixed integer hash. Amplitude
decreases toward black and white. A common RGB delta avoids independent colored
speckles, although final channel clipping can affect saturated colors. Size is
measured in source pixels, not preview pixels. This is a deterministic artistic
approximation, not measured film stock or physical silver-halide simulation.

The stage runs after sharpening and before final resize on CPU, Metal, GLES or
D3D11. Neutral/CUBE output supports every backend; native DCP rendering remains
CPU/Metal only. Active effects use full RAW resolution in default/exact rendering,
including legacy interactive previews. The viewport opt-in below is an
approximation. Off restores the existing early-resize/proxy paths. Auto retains CPU
fallback; Force reports a failure when the platform GPU cannot complete the job.

References considered: [darktable lightness grain](https://docs.darktable.org/usermanual/development/en/module-reference/processing-modules/grain/),
[AOMedia parameterized grain](https://aomediacodec.github.io/afgs1-spec/), and
[IPOL Monte Carlo film grain](https://www.ipol.im/pub/art/2017/192/). None of these
implementations is copied or embedded.

### GPU Denoising

The existing denoise controls and saved parameters are unchanged. Optional
`SONY2FUJI_ENABLE_WAVELET_DENOISE` and `SONY2FUJI_ENABLE_CHROMA_DENOISE` builds remain
independent. Mac/iOS use Metal, Android uses GLES 3.1 compute, and Windows uses
hardware D3D11 compute for heavy filtering; GPU failures in Auto fall back to CPU.
Force requires successful platform filters and photo rendering, never a
silent CPU replacement. A reliable-noise estimate is still required; off/zero
strength and insufficient-evidence cases remain no-ops.

Wavelet denoising stays in linear sRGB before user exposure and LUT evaluation.
CPU retains flat-sample selection, noise-model fitting, normalization, opponent
conversion, band calibration and variance-aware restoration. The GPU executes db2
SWT analysis, box-energy thresholds and the transpose inverse per tile/channel.
The original 4/6 levels, periodic SWT indices, REFLECT_101 energy boundaries and
512/1024 tile centers with 96/256 halos are preserved. Bounded GPU tile jobs are
serialized to avoid allocating full-image wavelet coefficients. Float GPU results
are tested against the existing double wavelib implementation, not substituted
with a different denoising algorithm.

Filtered RAW results use one exact slot and two recent viewport slots, with a
128 MiB retained preview-image budget. Source keys include file identity, RAW
decode settings/quality, the actual decoded baseline EV and viewport dimensions;
baseline EV uses exact float identity, including the mutable embedded-preview
anchor across camera-WB/FBDD transitions. Output matching also requires
the complete denoise options and execution mode. CPU/Auto/Force cannot reuse
each other's filtered results. The small source-analysis cache retains flat
samples, the fitted noise model and calibrated bands across strength changes;
it does not retain full-image coefficients or replace filtering. Coarse-band
analysis is prepared lazily when needed. Source/quality/size changes invalidate
that entry's analysis. Interactive wavelet previews may remain approximations;
final/file requests never reuse viewport results.
Active chroma or photo effects require the exact source-resolution path unless
the caller explicitly opts into the viewport approximation below.

Display-chroma denoising stays after tone/LUT and before sharpening. The GPU
completes the source-resolution tone stage, then CPU performs the original
OpenCV Lab conversion and sampled profile estimation. The GPU executes the
three-channel-guide/two-channel-source guided filters with BORDER_REFLECT means;
CPU keeps the original preblur, protection mask, coarse resize/correction and
Lab-to-RGB conversion. GPU rendering resumes detail, effects and
final resize. This deliberate readback preserves OpenCV's LUT-based Lab and
half-pixel/area-resampling semantics; it is not an all-GPU pipeline.

Direct core denoiser calls default to CPU for backward compatibility. Internal
diagnostics distinguish an applied filter from an actual GPU filter. Failed
GPU calls commit no output. RAW originals/cache remain immutable. Legacy LibRaw
FBDD, RAW decoding and file encoding remain CPU operations. GLES/D3D11 share the
same filter graph and formulas, with platform-specific buffer/dispatch adapters.
GLES limits each storage buffer to the driver's block-size limit and preserves
the previous EGL context. All compute jobs are serialized per backend. Effects
and GLES detail process bounded row strips before final resizing; grain hash and
vignette geometry always use full-image coordinates.

`metal_denoise` (or Android's `gpu_filter_tests`) compares individual filters and complete denoisers against
wavelib/OpenCV; `wavelet_render`, `chroma_denoise`, `gpu_photo`, `photo_effects`
and `native_dcp_metal` cover pipeline/backend contracts. Mac
`photo-effects-render.sh RAW LUT wavelet|chroma` tests real RAW CPU/Metal parity,
combined effects, stable exact/interactive rendering and JPEG/16-bit PNG export.

### Profile-Based Lens Correction

Optional Lensfun 0.3.4 correction runs after LibRaw demosaic/highlight handling
but before `rgb_cam` mixes camera channels. Distortion and lateral chromatic
aberration (TCA) share one inverse-coordinate sampling pass. Bilinear sampling
preserves float values through the existing camera matrix and exposure baseline;
WB remains before demosaic. Lensfun supplies coordinates, not the pixel sampler.
The existing GPU photo pipelines receive corrected working RGB; lens sampling
itself remains on CPU, like RAW decoding.

`sony2fuji_session_set_lens_correction` uses a versioned configuration without
changing request v2. Both corrections default off, an exact no-resampling bypass.
NULL/empty profile ID means automatic matching for each input, never a remembered
resolved lens from another photograph. Multiple matches are reported as ambiguous
and skipped. Manual IDs come from the metadata-only catalog API. Missing camera
crop information, focal length or requested calibration is reported; absent
corrections do not silently become a different algorithm. Four-channel camera
data can use common distortion, but not three-channel TCA.

Known cameras receive a mount-compatible catalog; unknown/ambiguous cameras
receive the full catalog for manual selection, but correction still requires
usable sensor crop information. Inspection reports eligibility for the current
switches; only the post-render report records applied correction and crop scale.

Auto crop defaults on and finds an inscribed zoom covering the full image
perimeter for all three channel maps. Output dimensions and aspect ratio stay
unchanged; field of view decreases. With auto crop off, samples outside the active
image become black, not edge smears or unchecked array accesses. Orientation is
applied once, using unrotated active-image coordinates. Interactive half-size
processing constructs the map at its actual dimensions; an approximate result
cannot serve exact/file requests. Correction switches, manual ID and database
revision join the decoded RAW cache key, so downstream denoise/GPU caches cannot
reuse another lens configuration.

The camera-WB exposure anchor in preview-matching mode uses the same lens
configuration/database identity. Changing the profile or crop settings while
using temperature WB must recompute that anchor, not reuse an uncorrected one.
The RAW lens report is cached with its pixels and restored on RAW cache hits,
including after the session processes a display buffer.

`sony2fuji_session_set_lens_database` explicitly loads an offline DB1 XML file or
directory. Failed loads preserve existing session state. Builds without Lensfun
retain the new C symbols and old request layout, accept disabled configuration,
and reject enabling it with UNSUPPORTED. macOS bundles the unmodified DB snapshot
and dependency notices. JPEG/display buffer inputs are not treated as camera
channels; they remain unchanged and report unsupported lens input.

The current JXL DNG SDK path conservatively skips additional lens correction
when successful unpack reports `LIBRAW_WARN_DNG_STAGE3_APPLIED`. This records
actual SDK processing, not merely presence of an opcode list; it does not claim
that every Stage3 list contains a geometry warp. The Stage3 warning bit is cleared
before each open/unpack because LibRaw recycle retains warnings across inputs;
WB reload and a later ordinary/no-Stage3 file must not inherit this state.
Metadata-only inspection does
not claim to have applied SDK operations. Manufacturer-specific embedded lens
models outside that path are not implemented. Defringe, axial CA correction,
profile vignetting, perspective correction and Adobe rendering equivalence are
outside this feature.

References: [Lensfun architecture](https://lensfun.github.io/manual/latest/basearch.html)
and [stable combined-coordinate API](https://github.com/lensfun/lensfun/blob/v0.3.4/include/lensfun/lensfun.h.in).

## LUT Contracts

The generic CUBE library implements standard R-fast storage, DOMAIN_MIN/MAX, float outputs and trilinear interpolation. It does not clamp table values. CPU and GPU normalize the same input domain.

The PHOTO API is narrower. Supported files declare comments such as:

```text
#Gamma:F-Log2 to PROVIA
#Gamut:F-Gamut to ITU-R BT.709
```

Inputs are `F-Log`/`F-Log2` with `F-Gamut`, or `F-Log2C` with `F-Gamut C`.
Output gamut must be `ITU-R BT.709`. Whitespace, case and punctuation in these
declarations are normalized. F-Log2C uses F-Log2's curve but not its gamut matrix.
The F-Gamut C matrix is derived from the primaries and white in the
[official F-Log2C data sheet](https://dl.fujifilm-x.com/technical-data/F-Log2C_DataSheet_E_Ver.1.0.pdf);
F-Log uses the separate [official F-Log curve](https://dl.fujifilm-x.com/technical-data/F-Log_DataSheet_E_Ver.1.2.pdf).

The nonempty output look name is not allowlisted: custom names such as EKTAR 100
Phuket are accepted as display output. Explicit `F-Log`, `F-Log2` or `F-Log2C`
outputs instead receive Log decoding and neutral display rendering. This makes
technical gamut conversions usable in PHOTO without mistaking Log values for
display RGB. JPEG/PNG outputs are still display-sRGB, never Log intermediates.
Missing/incompatible declarations remain rejected. Display-sRGB creative CUBEs
declare `#Gamma:sRGB to sRGB` and `#Gamut:ITU-R BT.709 to ITU-R BT.709`.
Their input is the neutral display-sRGB result from step 3, not F-Log or scene
linear RGB. CPU and Metal support this path; GLES/D3D11 return to CPU in Auto
and reject Force until their shaders support display input. HSL retains its
normal post-blend stage and is not baked into these creative tables.
This validates declarations, not the table's actual transfer behavior;
`OutputTransfer` comments are not interpreted. Custom named display LUTs must
match the application's sRGB convention. Generic mathematical CUBE application
remains available through LUTApplicator.

F-Log/F-Log2/F-Log2C inputs and named display or explicit Log outputs are implemented
in the CPU, Metal, GLES and D3D11 photo paths. The GPU receives the same input
gamut matrix and chooses input encoding and output decoding independently.
Auto falls back on backend failure; Force returns an error instead of hiding CPU
execution. GLES detail filters now run before final resize. Strength zero bypasses
look loading. Current Fuji runtime verification covers Metal and Android GLES on
an emulator; D3D11's matching shader/host changes await Windows verification.

`FLog2 -> FLog2 BT.709` is a technical color-gamut conversion, not a film simulation. It remains excluded from built-in film pickers but may be imported as a custom look. The experimental `SONY2FUJI_ACES_MODE` switch is superseded by the single float camera-matrix path; it no longer changes rendering.

### Prepared External Looks

The optional [offline LUT preparer](lut-preparation.md) composes explicitly
declared source transforms into this same native contract. Scene-to-display LUTs
receive no additional neutral curve; display-input creative LUTs receive neutral
rendering before the source transform, and scene-output looks receive it after
output decoding. Signals declare gamut/transfer, scene/display reference and
numeric range separately. Unknown contracts fail rather than weakening the PHOTO
API checks. Prepared output is clipped SDR display-sRGB, with serialized-cube
trilinear sampling error recorded and gated. Legacy canonical CUBEs can pass
through without resampling. Native-compatible Fuji inputs/Log outputs are reported
separately from canonical display CUBEs; direct native import needs no preparation.
The C ABI is unchanged.

DCP adaptation is separate from generic RGB LUT composition. Version 1.1 uses an
explicit D65 ColorMatrix/ForwardMatrix pair to reconstruct a white-relative virtual
source-camera input from already developed common RGB, then applies the profile
look/tone in ProPhoto RGB. The donor matrices never replace the target RAW's own
sensor calibration or WB. Missing/invalid D65 matrices are rejected. Version 1.0 omitted this input adapter and could
produce purple skies; its DCP-derived CUBEs must be regenerated from source.
Profile exposure remains an explicit, recorded linear EV adaptation that can be
disabled. DCP rendering, finite-grid baking and cross-camera accuracy are separate
verification questions; successful CPU/GPU parity alone does not establish color
accuracy or Lightroom equivalence.

Preparer 1.2 adds `.rlook` compilation for the supported DCP subset. The core reads
a bounded versioned package containing the original normalized HSV table, tone
samples and matrices. Double intermediate arithmetic avoids the full-transform
RGB-CUBE approximation; output remains float display-sRGB for the same strength
blend and adjustments. The PHOTO v2 `lut_path` accepts either format, and zero
strength bypasses file loading. Existing CUBE GPU execution is unchanged.

Preparer 1.3 adds single/dual-illuminant D65 HueSatMap calibration before profile
EV and LookTable; LookTable may be absent. `.rlook` v2 stores both tables and v1
remains readable. Missing profile tone requires an explicitly supplied external
curve, not an inferred identity/Adobe curve. New HSM/external-tone profiles that
default to Auto black require an explicit omission policy. Triple-illuminant HSM,
HDR/spatial/RGB stages and full Adobe rendering remain unsupported.

Native DCP now has a dedicated Metal kernel on macOS 15+/iOS 18+, using the same
immutable decoded stages and float32 arithmetic. CPU double evaluation remains
the reference. Stage nonfiniteness or Metal failure returns to CPU in Auto and
fails in Force; successful Metal execution reports the actual backend. The old
CUBE shader/parameter layout is unchanged. Windows/GLES still use CPU Auto
fallback and reject Force for native DCP looks.

## Verification Boundaries

### RAW Kelvin White Balance

Request v2 remains ABI-compatible. `SONY2FUJI_WB_TEMPERATURE` is a new RAW-only mode:
`temperature` is 2000-50000 Kelvin and `tint` is -150 to +150. Increasing Kelvin
warms the result; positive tint adds magenta. Gains are calculated in camera space
and passed to LibRaw before demosaic/highlight blending, not applied as an sRGB tint.
Changing these controls invalidates the decoded RAW cache; neutral and film renders
with the same controls share that decode. The session retains unpacked sensor data,
so numeric Kelvin/tint changes do not reopen and unpack the file. Changing the
identification-dependent camera/auto/custom WB mode still reopens it.

`sony2fuji_session_set_interactive_preview` opts PREVIEW+BUFFER requests into
LibRaw half-size processing. An exact cache can serve an interactive request, never
the reverse. FINAL requests and all file outputs ignore the flag. The Mac scheduler
uses viewport-sized proxies during dragging and always submits a settled pass on release.
No post-demosaic RGB tint approximation replaces camera-space white balance.

`sony2fuji_session_set_viewport_preview` is a separate, default-off session opt-in
for PREVIEW+BUFFER only, without changing request v2. It reduces linear input to
the requested dimensions before wavelet, tone/LUT, chroma, sharpening and photo
effects on CPU/Metal. The immutable RAW cache is sampled directly without first
copying the entire image. Wavelet cache keys include the viewport dimensions and
quality mode; reduced results cannot serve exact requests. GPU Auto fallback
preserves the reduced source, while Force still requires GPU success.

Mac fit/zoom previews derive their long edge from the actual photo pane, display
scale and magnification, rounded upward in 64-pixel steps and capped by source
resolution. Window, comparison and panel resizing update this size. With denoise
enabled, continuous layout changes keep the current proxy size until 200 ms of
quiet, then render the latest requested size. Other adjustments can still update
the held proxy. Export stays blocked while this final size is pending; opening
another photo or switching to actual pixels cancels obsolete resize work. Both
numeric edits and settled fit previews opt in; actual-pixel viewing returns to the exact
source-resolution path after dragging ends. Original comparison frames remain
native and immutable. Exports and FINAL requests always ignore the opt-in.
Pixel-radius denoising/sharpening and grain appearance in the viewport are
approximations, not export-detail proofs. Inspect them at 100% when settled.
Initial RAW decode, absolute WB reprocessing and legacy FBDD still incur their
CPU costs; this mode does not perform viewport-region RAW decoding.

Windows uses the same physical-pixel demand and quiet resize policy. Its explicit
actual-pixel view remains native when settled; adjustments in that mode use a
bounded 2000-pixel proxy until release. iOS and Android retain their existing
1280/1600-pixel preview ceilings, respectively, and their 100% gesture still
refers to the fixed comparison-preview pixels, not full RAW detail. Mobile pane
resizing and zoom update demand within those ceilings without changing the
comparison geometry. iOS reuses a serialized RAW preview session for denoise
cache hits, while native exports use separate short-lived sessions. Android and
Windows reset both session preview flags for each native/file export. All
clients block export while a denoise resize is pending and preserve original
export dimensions when no explicit export-size cap is selected.

The illuminant xy/Kelvin conversion is adapted from Adobe DNG SDK's Robertson
isotherm implementation. Its copyright and license are retained in
`third_party/Adobe-DNG-SDK-LICENSE.txt` and bundled in the Mac app. Camera calibration
comes from LibRaw's XYZ-to-camera matrix, or DNG ColorMatrix/CameraCalibration and
AnalogBalance with reciprocal-temperature dual-illuminant interpolation.

`sony2fuji_session_get_raw_white_balance` reports the last decoded file's estimated
as-shot Kelvin/tint. It is not an EXIF Kelvin reader or Adobe profile emulation.
Missing, singular, four-channel, or out-of-range calibrations return UNSUPPORTED;
camera white balance still works. The Mac client disables absolute controls in that
case. As-shot reset uses the original camera gains, not a rounded Kelvin round trip.
Optional embedded-preview exposure matching stays anchored to camera WB, so a user
white-balance edit does not also re-meter the scene.

### Hardware Acceleration

Windows uses a session-owned Direct3D 11 compute pipeline with hardware feature
level 11.0 adapters. It mirrors the CPU order for gamut matrices, exposure,
neutral/F-Log2/LUT blending, tone/color, box-blur-based detail and resizing.
Preview reduction occurs before effects only when sharpening is zero; FINAL
resizes display output after effects. Immutable RAW uploads are keyed by decode
revision, including interactive/exact quality transitions. LUTs use explicit
trilinear interpolation with their declared domains. `SONY2FUJI_BACKEND_D3D11`
reports completed hardware processing. WARP is excluded. Auto falls back to CPU
on device/resource/dispatch/readback failure; Force returns a processing error.
Windows histogram/clipping statistics remain on CPU for already-read-back pixels.
The C ABI path encoding is UTF-8 on Windows, converted to Unicode for filesystem
access. The request v2 layout is unchanged.

The Metal photo pipeline mirrors CPU operation order: optional preview resize,
input-gamut to linear sRGB, relative WB/exposure, neutral display or F-Gamut/F-Log2
and LUT, strength blend, tone/color, detail, final resize. RAW absolute WB and
highlight reconstruction remain in LibRaw. Auto falls back to the unchanged CPU
reference if Metal cannot render; Force reports an error. Request v2 layout is
unchanged. `sony2fuji_session_get_last_backend` diagnoses the pixel pipeline, not
LibRaw or file encoding. Two processing buffers are reused between GPU kernels.

Android uses an OpenGL ES 3.1 compute photo pipeline with the same operation
order and explicit trilinear LUT interpolation. Pointwise processing and resizing
run on GPU; neighborhood detail filters use CPU in Auto and fail in Force.
Source uploads are bounded row bands, and only a reduced linear preview is
cached by RAW decode revision. Native-resolution exports never use that preview.
`SONY2FUJI_BACKEND_GLES` reports actual GPU completion, including neutral renders;
Auto preserves the CPU source when GPU work fails. RAW decoding and encoding
remain on CPU. Physical-device parity and timing are recorded in
`../../RawLabAndroid/gpu-verification.md`.

`sony2fuji_analyze_image` returns exact channel-major 256-bin RGB counts and an
optional RGBA clipping mask. Its Auto mode prefers CPU for CPU-resident bytes,
based on measured transfer/synchronization overhead; Force requires Metal. Both
backends use identical bins and clipping criteria.

Legacy non-temperature modes retain relative controls but correct their former
reversed direction: the illuminant response is inverted, so warmer/positive-magenta
directions now match the UI. Existing clients must rebuild the core to receive this
intentional behavior fix; the legacy 6500/0 identity and struct layout are unchanged.

The Mac histogram remains an sRGB output histogram. Its shared linear count scale
and RGB/CMY/gray filled overlaps follow the conventional Lightroom presentation;
it does not claim matching Adobe Develop color-space values or proprietary scaling.

Numerical anchors: F-Log2 black/18%/90% -> approximately 95/400/570 at 10-bit; linear 2 -> 0.64144017. Tests cover super-whites, CUBE domains/order/range, strength continuity, exposure, photo LUT rejection, PNG data/bit depth, native-matrix rejection, RAW exposure linearity, active crop and optional Metal/CPU parity.

Regression checks compare the float result to a separately configured LibRaw WB-before-demosaic reference, validate DNG baseline application, mode-cache isolation and user-EV independence. Neutral tests cover middle-gray invariance and distinguish linear 1/2/4 instead of clipping them all to white. A direct LUT reference proves full-strength film bypasses the neutral display curve. Preview median matching within 0.15 EV is tested only in optional preview mode, not as a definition of correct default exposure. A 512 KiB worker-stack test covers desktop background preview extraction.

Reference sources: [darktable exposure](https://github.com/darktable-org/darktable/blob/release-5.4.0/src/iop/exposure.c), [sigmoid](https://github.com/darktable-org/darktable/blob/release-5.4.0/src/iop/sigmoid.c), and [raw black/white point](https://docs.darktable.org/usermanual/5.6/en/module-reference/processing-modules/raw-black-white-point/). Actual darktable 5.4.0 default JPEGs were exported with isolated configuration for both samples. This is a visual reference, not pixel parity: demosaic, profile, crop and metadata policies differ. An EXR with linear output encoding after sigmoid is display-linear, not a scene-linear intermediate.

Embedded JPEG decoding uses vendored [stb_image v2.30](https://github.com/nothings/stb/blob/master/stb_image.h), with JPEG-only and memory-only decoding enabled. The upstream license is retained in the header; no additional system package is required.

The bundled Sony ILCE-7CM2 sample has a 7008x4672 active inset within its padded RAW storage; the renderer applies LibRaw's inset crop before demosaic. iOS and macOS must not apply the original EXIF rotation a second time.

Actual cross-brand accuracy requires controlled lighting, exposure/gray and color-chart measurements. Current sample smoke checks prove decoding/rendering, not calibrated Fuji JPEG equivalence. iOS/Android binaries must be rebuilt with the updated core; changing Swift source alone does not update an old xcframework.
