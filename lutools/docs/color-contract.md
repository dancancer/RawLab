# Photo Rendering Contract

## RAW Input

LibRaw performs black subtraction, active-area crop, white balance, demosaic and highlight blending in camera channels. WB must precede demosaic: the earlier no-auto-scale path produced a measurable difference from LibRaw's normal WB-before-demosaic processing. Histogram auto-bright, content-dependent maximum adjustment and integer output-color conversion remain disabled. `highlight=2` retains maximum-normalized WB before 16-bit demosaic and blends clipped highlight chroma after demosaic, before our camera matrix and LUT. The former `highlight=1` unclip mode preserved false magenta in saturated DSC06251 car-body highlights. Blending is not darktable's opposed-chroma reconstruction and cannot recover lost sensor detail; bright colors can become less saturated. We recover green-normalized camera RGB as `image16 / (65535 * post_scale_pre_mul[1])`, then apply the camera-to-sRGB matrix in float. Matrix negatives and values above 1 survive; we do not globally clamp scene RGB to 1. This is not an all-float demosaic: quantization and LibRaw's treatment of sensor-overrange values remain. The raw source is never written.

Default 0 EV is a declared scene-development baseline: **+0.7 EV plus valid DNG BaselineExposure**. The +0.7 is a workflow starting point, inspired by darktable's scene defaults, NOT sensor calibration or a claim that every camera needs this exact offset. DNG metadata is applied once (DJI fixture: +0.35, total +1.05 EV; Sony without that tag: +0.7 EV). Missing/sentinel/non-finite/out-of-range metadata falls back to zero metadata offset. User +1 EV still doubles the linear input. The default never decodes or meters the embedded JPEG. We deliberately do not undo a photographer's EXIF ExposureBiasValue, and do not invent undocumented camera-specific dynamic-range compensation.

Optional `preview` mode retains the earlier median matching approximation: it samples 128x128 luminance values and applies `preview_median / raw_median` instead of the scene baseline, not on top of it. Preview styles, profiles, cropping and black borders can bias it. Untagged previews assume sRGB; known non-sRGB DNG previews are skipped, gray gamma 2.2 is handled explicitly. Missing/invalid references fall back to the scene baseline. Sensor mode applies neither metadata nor the workflow boost. In C++, disable both `applyBaselineExposure` and `matchEmbeddedPreviewExposure` for sensor mode. The C ABI exposes `sony2fuji_session_set_raw_exposure_mode` without changing the v2 request layout; the mode is part of the RAW cache key. Mac exposes all three modes and the actual base offset. Sensor saturation is not recoverable, and film LUTs may deliberately change apparent brightness.

`RAWProcessor` returns float working data. `outputBitsPerSample=8/16` only quantizes the non-linear display path; the linear path always retains float precision. The legacy `getNativeColorSpace()` name returns the last processed working space. Unspecified camera-native matrix transforms now fail instead of substituting sRGB primaries.

## Rendering Order

1. Decode RAW to linear RGB with the selected exposure baseline, or inverse-sRGB-decode an explicitly tagged raster buffer. Buffer inputs receive neither RAW metadata nor the +0.7 baseline.
2. Apply relative white balance and `2^exposure_ev * brightness` in linear sRGB. Custom RAW WB multipliers are applied once, during decode.
3. Generate the neutral reference with a fixed log-logistic display curve, then sRGB encode. For positive x the linear display value is `1 / (1 + ((1-g)/g) * (g/x)^1.5)`, with `g=0.1845`; black is 0 and highlights approach 1 smoothly. This independently implemented mathematical subset follows the same curve family as darktable sigmoid, but does not reproduce its primaries adjustment, hue-preservation or full default pipeline.
4. For a film CUBE: start from the un-tonemapped linear input, transform to F-Gamut, encode with the published F-Log2 curve, then interpolate the CUBE. A compiled DCP `.rlook` instead evaluates its preserved matrix/HSV/tone stages directly from common linear sRGB, without F-Log2 or an RGB CUBE. The neutral display curve is NOT applied before or after either look. Log encoding itself never normalizes exposure, and there is no linear clamp at 1 before it.
5. Blend neutral and film outputs in the same display-encoded RGB convention. Strength 0 is continuous with the no-LUT rendering. Contrast, saturation, curves and detail adjustments follow.
6. Write RGB/RGBA preview, JPEG or actual 16-bit PNG. PNG includes an sRGB chunk. Photo outputs use an sRGB display interpretation; the film-simulation names alone do not establish camera-to-camera colorimetric equivalence or a measured display EOTF. JPEG consumers must use this sRGB interpretation.

When sharpening is enabled, the early preview downsample is skipped. The fixed pixel-radius filter runs at source resolution before the final preview resize, matching its export footprint. At zero sharpening the existing fast preview path remains unchanged. Mac's contrast/saturation controls use percent offsets from the core's identity value 1; highlight signs are reversed at the UI boundary so positive values consistently brighten. All six output adjustments default to an identity result.

The film output interpretation is a declared application convention. It is not a claim that Fujifilm's short LUT overview specifies every viewing parameter. No guessed extra gamma is applied to an already rendered film LUT output.

## LUT Contracts

The generic CUBE library implements standard R-fast storage, DOMAIN_MIN/MAX, float outputs and trilinear interpolation. It does not clamp table values. CPU and GPU normalize the same input domain.

The PHOTO API is narrower. Supported files declare comments such as:

```text
#Gamma:F-Log2 to PROVIA
#Gamut:F-Gamut to ITU-R BT.709
```

The output look name is not allowlisted: custom names such as EKTAR 100 Phuket are accepted. Gamma must still declare `F-Log2 to <nonempty look name>`, and Gamut must declare `F-Gamut to ITU-R BT.709`. Missing/incompatible declarations, F-Gamut C and sRGB-input creative LUTs are rejected. The known `F-Log2 to F-Log2` technical conversion remains rejected because it does not produce display RGB. This validates declarations, not the table's actual transfer behavior; `OutputTransfer` comments are not interpreted. Custom LUT authors must provide display output matching the application's sRGB convention. Generic mathematical CUBE application remains available through LUTApplicator.

`FLog2 -> FLog2 BT.709` is a technical color-gamut conversion, not a display film look. It is excluded from client film pickers. The experimental `SONY2FUJI_ACES_MODE` switch is superseded by the single float camera-matrix path; it no longer changes rendering.

### Prepared External Looks

The optional [offline LUT preparer](lut-preparation.md) composes explicitly
declared source transforms into this same native contract. Scene-to-display LUTs
receive no additional neutral curve; display-input creative LUTs receive neutral
rendering before the source transform, and scene-output looks receive it after
output decoding. Signals declare gamut/transfer, scene/display reference and
numeric range separately. Unknown contracts fail rather than weakening the PHOTO
API checks. Prepared output is clipped SDR display-sRGB, with serialized-cube
trilinear sampling error recorded and gated. Legacy canonical CUBEs can pass
through without resampling. The native CUBE contract and C ABI are unchanged.

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
uses 1000-pixel proxies during dragging and always submits an exact pass on release.
No post-demosaic RGB tint approximation replaces camera-space white balance.

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
