# Phone HDR color contract

HDR processing versions 1 through 7 have their own versioning, separate from RAW
processing. Version 2 adds a luminance stage after the version 1 adjustments.
The supported input and state rules are in the
[HDR design](../../docs/design/hdr-photos/technical-design.md).

## Working values and order

Each source owns an HDR rendition and the original SDR rendition. Both are
oriented, opaque, display-referred, D65 extended-linear sRGB RGB32F. A value of
1 is SDR reference white; 2, 4 and 8 are +1, +2 and +3 EV. Finite negative
components and super-whites survive processing. There is no RAW baseline,
camera WB, scene sigmoid or display-headroom input.

The version 1 order is relative WB, linear exposure, rendition-specific tone, saturation,
shared geometry, then optional final resize. Identity bypasses color arithmetic
and preserves float bits. Exposure alone multiplies both renditions by `2^EV`.
The input remains immutable. Geometry follows the existing
[geometry contract](edit-json.md). Resize is bilinear with aligned end points;
a one-pixel output dimension samples the center. A long-edge limit never enlarges.
Apple builds use the existing OpenCV worker pool for independent edit/resize
pixels when available. Pixel operation order and float results are unchanged;
small inputs and builds without that backend retain the serial path. This is
CPU parallelism, separate from Metal presentation and the GPU Force policy.

## Relative WB

Temperature is a relative UI coordinate, not the capture Kelvin. With temperature
`T` in 2000..50000 and tint `t` in -150..150:

```
m = 1 - 6500/T
g = (2^(m/2), 2^(-t/600), 2^(-m/2))
gain = g / dot((0.2126, 0.7152, 0.0722), g)
```

Each channel is multiplied by its gain. `6500/0` is an exact bypass. Increasing
temperature warms, and positive tint is magenta. Normalization preserves the
luminance of a neutral gray. This is a reproducible relative transform, not a
camera illuminant reconstruction or a Lightroom pixel match.

## Automatic exposure

Meter an unedited HDR source preview with the current relative WB. Sample
linear luminance on the same bounded grid as ordinary automatic exposure and
set an absolute EV toward a median of 0.1845. A positive correction is limited
by the 99.5th percentile relative to 4.0 (+2 EV above reference white). If the
percentile is already at or above 4.0, that guard permits zero additional EV.
A scene whose midtones are too bright can still receive a negative correction.
The result is clamped to [-4, 4] EV. The current exposure and display headroom
are independent of metering, so repeating the action with the same source and
relative WB returns the same value. An unusable sample leaves the edit intact.

## HDR tone

Let `Y = dot((0.2126, 0.7152, 0.0722), RGB)`. At `Y <= 0`, tonal luminance
adjustment bypasses; saturation still has its ordinary meaning. For positive Y:

```
smooth(x,a,b): u=clamp((x-a)/(b-a),0,1); return u*u*(3-2*u)
Yc = 0.18 * 2^(log2(Y/0.18) * 2^(contrast/100))
h = smooth(log2(Yc), -2, 1)
s = 1 - smooth(log2(Yc), -5, -1)
Ye = Yc * 2^((highlights*h + shadows*s)/50)
RGB *= Ye/Y
```

Zero contrast bypasses its expression; zero highlight/shadow settings bypass
their expressions. Gray 0.18 anchors contrast. Smooth weights refer to reference
white and remain continuous across 1. The luminance ratio preserves chromaticity
for these tone operations; no upper clip or plateau is introduced. Increasing
highlights/shadows brightens their corresponding ranges. Saturation is
`RGB = Y + (RGB-Y)*(1+saturation/100)` after tone; -100 produces luminance gray.

Independent anchor vectors include neutral HDR 4 with contrast +100 ->
88.8888889; HDR 4 with highlights +100 -> 16, with highlights -100 -> 1;
RGB (0.2,0.5,0.8) with saturation -100 -> (0.45788,0.45788,0.45788).
The frozen test vectors and direction/continuity regressions run as
`hdr_render_*`. Float arithmetic tolerances are at most 1e-6 relative to the
reference values. Overflow is a recoverable error, never an output containing Inf.

## SDR rendition

WB and exposure operate on the original linear SDR base. Active SDR tone uses
the established display-domain directions: sRGB encode; shadow gamma
`1-shadows/200`; complementary highlight gamma `1+highlights/200`; luminance-ratio
application; contrast about encoded 0.5 with factor `1+contrast/100`; saturation
mix in that domain; inverse sRGB. A nonpositive luminance bypasses the gamma
tone adjustment. Negative channels use the linear segment of sRGB. There is no
gamma round trip when tone and saturation are neutral. SDR output gamut mapping
and quantization belong to the writer, not the HDR master.

## Version 2 black and white points and curves

Apply the following stage to each rendition independently after the version 1
color operations and before geometry. For positive luminance, let `s = log2(Y)`
and use the smooth weights defined above.

```
target = s + (black_point * (1 - smooth(s, -7, -3))
              + white_point * smooth(s, -1, 3)) / 50
RGB *= 2^(target - s)
```

Black and white point each accept [-100,100]. They shift their respective
ranges by at most two stops. An active curve remaps `target` before the RGB
scale. Its coordinates cover [-8,+8] EV, with reference white at 0.5.
Custom mode uses monotone PCHIP with fixed endpoints (0,0) and (1,1) and
allows up to 33 points. Legacy mode uses a generated S curve whose strength
in [-100,100] shifts the quarter points by up to one stop, keeping 0 EV fixed.
Values outside the curve domain retain their pre-curve target. Nonpositive
luminance bypasses the stage. A neutral stage preserves the version 1 result
bit for bit.

Pass `sony2fuji_hdr_request_v2.base` to the existing render and stream
entry points. The base retains the 88-byte version 1 layout and ABI version
field. Its processing version is 2 and its size describes the full 648-byte
request, including the three parameters and the existing tone-curve config.
Version 1 callers continue to pass their original request. Both lengths and
parameter ranges are checked before rendering or writing output.

## Version 3 color controls and sampling

Version 3 applies vibrance, HSL and color grading after version 2 tone, before
geometry and resize. It applies the same controls separately to both linear
renditions. With neutral color controls, version 3 preserves the version 2
result bit for bit.

Vibrance scales chroma around luminance. Positive values favor low relative
chroma and protect skin hues. Negative values reduce chroma across hues.
HSL uses the same eight hue ranges as the SDR mixer. It rotates hue by up to
30 degrees, scales chroma between 0 and 2, and moves luminance by up to one
stop with a smooth near-neutral bypass. Both operators derive relative chroma
from channel spread and positive luminance, independent of exposure.
Color grading adds a luminance-preserving tint from the three wheels. Shadow
weight falls from 1 to 0 between -5 and -2.5 EV. Highlight weight rises from
0 to 1 between -1 and +1 EV. Midtones use the remaining weight. The operations
retain signed and super-white values in the working gamut.

Pass `sony2fuji_hdr_request_v3.base.base` to the existing HDR entry points.
The request keeps the version 2 prefix and adds vibrance, the existing HSL
and color grading configs, and reserved padding. The full request is 792
bytes. Its ABI version remains 1 and its processing version is 3.
`sony2fuji_hdr_create_hsl_probe` accepts processing versions 1 through 7 and samples the
HDR plane after tone, vibrance, geometry and resize. HSL, grading and the HDR look are
excluded from the probe so dragging does not feed back into the selected hue
range. Probe RGB is linear and can contain signed and super-white values.
Probe lightness is the bounded ratio `Y / (1 + Y)`. The result carries the
caller's source and request revisions and uses normalized post-geometry
coordinates.

## Version 4 HDR peak and SDR base

After version 3 color and before geometry and resize, apply the peak control to
the HDR master. Zero EV selects an unlimited peak. A positive value in (0,6]
selects a luminance ceiling at `P = 2^EV`, measured relative to SDR white.
Luminance through `K = max(1, P/2)` stays the same. Above the knee, use
`Y' = K + (P-K)*(Y-K)/(P-K+Y-K)` and scale all channels by `Y'/Y`. This
keeps the RGB ratios and preserves finite signed components. Screen capacity
and the gain map's component-based activation capacity are separate values.

The SDR base applies a separate linear exposure in [-4,4] EV and the
established SDR contrast and saturation operations in [-100,100]. Each
rendition's controls operate on its own result from version 3. Neutral
controls preserve version 3 bits. The HSL probe samples before these controls.
Gain-map JPEG export rebuilds the gain map from the adjusted pair.

The full 808-byte `sony2fuji_hdr_request_v4` retains the 792-byte version 3
prefix. Pass `base.base.base` to the existing HDR entry points with ABI
version 1 and processing version 4. Older requests retain their processing.

## Version 5 vignette and grain

Apply the existing spatial vignette shape and deterministic grain field after
geometry and resize. Both renditions use the full output canvas and absolute
pixel centers, so strip boundaries and thread order leave the effect unchanged.
Grain size is measured on that output canvas.

Negative vignette scales linear RGB and protects luminance from 0.5 through
1 according to the highlight protection setting. Positive vignette blends
toward reference white, fading from 0.5 to 1. Grain scales linear RGB by
`2^(noise * amount * 0.002 * 2 * sqrt(Y)/(1+Y))` for positive luminance.
The working pixels retain signed channels and super-whites. If an HDR peak
limit is active, the finishing stage scales any luminance raised past that
ceiling back to the ceiling. The stage bypasses both planes exactly when
vignette and grain amounts are zero. HSL sampling stays before these effects.

The 848-byte `sony2fuji_hdr_request_v5` contains the version 4 request and
`sony2fuji_photo_effects_config`. Pass `base.base.base.base` to existing HDR
entry points with ABI version 1 and processing version 5.

## Detail processing (v6)

Version 6 applies detail after geometry and resize, before vignette and grain.
Sharpening uses a weighted 3×3 log-luminance neighborhood with a noise
threshold and limits its gain to ±0.45 EV. Clarity uses the same shape at
radius `max(round(max(width, height) / 200), 2)` and a ±0.8 EV limit.
The radius scales with the output canvas, including exports above 4.7k. The
stream/JPEG output edge limit keeps its halo at most 328 pixels. Direct
buffer rendering retains the same relative rule for larger dimensions. As in SDR
clarity's proportional analysis grid, preview and export preserve the relative
neighborhood scale; HDR uses a different log-luminance operator and does not
promise pixel equivalence with SDR. Rounding and the two-pixel minimum can
still affect small previews.
Dehaze estimates a veil from the tenth percentile of a bounded grid of
output-canvas luminances. Its effect falls off as luminance rises. Rendered
RGB denoise mixes a weighted 3×3 neighborhood into the center, with less
weight across differences in log luminance. Each rendition uses its own
luminance and source samples. Canvas edges repeat the closest pixel.

Streaming reads neighboring rows on both sides of each output band and
uses the same whole-canvas dehaze grid as a full-frame render. Both memory
admission and strip reads include the clarity halo, at most 328 rows per side
for streamed exports. Signed RGB channels remain valid. A configured HDR peak
limit caps the final positive luminance. All four zero controls bypass the stage exactly.

The 864-byte `sony2fuji_hdr_request_v6` appends sharpening [0,2], clarity and
dehaze [-1,1], and rendered RGB denoise [0,1] to the v5 prefix. Pass
`base.base.base.base.base` to the existing HDR entry points with ABI version 1
and processing version 6.

## Declared HDR look (v7)

An HDR CUBE declares `# RawLabHDRLook: display-linear-srgb-v1` before
`LUT_3D_SIZE`. The profile fixes both input and output to full-range,
display-referred D65 extended-linear sRGB, with SDR reference white at 1.0.
The CUBE uses a grid of 2–65 samples per axis, an explicit `DOMAIN_MAX`,
and `DOMAIN_MIN` of zero when omitted. Each axis covers zero through at
least 2.0. Domain and table components lie between -16 and 64. The profile
uses R-fast table order and trilinear interpolation.

For each input RGB `p`, let `b` be its projection onto the declared domain.
The result is `p + strength * (table(b) - b)` for strength in [0,2]. This
keeps the original amount outside the table domain and is continuous at its
edges. The look runs on each rendition after HSL and color grading, before
the HDR peak limit, SDR base trims and geometry. HSL sampling stays before
the look. Zero strength bypasses the pixel operation exactly.

The v7 request appends a UTF-8 path, strength and a lowercase SHA-256
fingerprint to the v6 prefix. `sony2fuji_hdr_probe_look` returns the verified
fingerprint and table bounds. Render and stream verify the bytes they use
against the expected fingerprint before applying the table. A null path and
a zero tail select no look. SDR CUBE and native DCP looks keep their own
input and output contracts.

## Camera RAW development

The separate `sony2fuji_hdr_camera_development_v1` decode request applies to
supported Bayer and X-Trans sources. The default uses as-shot white balance, metadata
exposure and no optional denoising or lens corrections. Explicit camera-space
white balance accepts 2000–50000 K and tint in [-150,150]. Metadata exposure
maps scene RGB by `2^(2 + BaselineExposure)`. The sensor setting uses `2^2`.

FBDD level 1 or 2 uses full Bayer demosaic before any preview resize.
Distortion and transverse chromatic aberration share one calibrated lens
transform before the camera matrix. Auto-crop preserves the output canvas
size. A missing or inapplicable calibration rejects the request. The decoder
configuration participates in the source cache identity and stays separate
from the rendering request and its processing version.

A successful camera RAW probe does not guarantee custom temperature calibration.
Sources without a usable camera white-balance model can retain as-shot decoding;
requesting custom temperature without a profile returns `CAMERA_DEVELOPMENT` on
the camera-development field. A supplied D65 profile uses its own ColorMatrix
without requiring the source camera's white-balance calibration to be valid.

### Fixed D65 camera profiles

`sony2fuji_hdr_camera_development_v2` adds a UTF-8 profile path and a
required lowercase SHA-256 fingerprint to the v1 prefix. Probe the resource
with `sony2fuji_hdr_probe_camera_profile`. Decoding uses the same bytes it
hashes and rejects a different fingerprint before publishing a pair. Keep the
profile fingerprint in any cache key for the developed source. The photo
digest in the pair continues to identify the original RAW.

The first subset extracts the unique D65 ColorMatrix and ForwardMatrix from
a standalone DCP with Adobe's extended profile magic `0x4352`.
The profile's UniqueCameraModel must match the DNG UniqueCameraModel
or the RAW decoder's normalized make and model (ASCII case insensitive).
Supported Bayer DNGs are below version 1.6 and require identity or absent
AnalogBalance and CameraCalibration. As-shot white balance uses the source multipliers.
Custom temperature and tint use the fixed D65 ColorMatrix before demosaic.
The ForwardMatrix maps white-balanced camera channels to XYZ D50.
It must map unit camera white to within 0.01 per channel of D50 and is
then normalized to that white. Bradford adaptation converts it to linear
sRGB at D65. Both matrices must have full rank, and the converted matrix
has finite coefficients with magnitudes at most 16. The transform preserves signed and above-white samples through
camera development. The calibrated scene supplies both renditions.

`sony2fuji_compile_hdr_camera_dcp` serializes the selected matrices as a
matrix-only `RLOOKHDR` resource. Its eight-byte magic is followed by
little-endian uint32 version 1 and the model byte count, two row-major
3×3 float64 matrices (ColorMatrix, ForwardMatrix), and 1–63 printable
ASCII model bytes. The matrix operation has no tone curve, HueSatMap,
LookTable, black rendering, profile exposure offset or interpolation
between illuminants. Existing SDR `RLOOKDCP` and the HDR CUBE render stage
retain their separate contracts. HDR AI currently takes the v1 camera
development request.

## Provenance and headroom

Source content headroom is immutable and may be unknown (0). Edited headroom
is measured as `max(1, max(Y))` over the output HDR rendition. Neither value is
display headroom. Source PREVIEW/proxy data cannot produce a FINAL render;
rendering a FINAL source then intentionally reducing output size retains FINAL
provenance. Preview outputs remain proxies even when dimensions happen to match.
Export must verify source and render provenance separately.

JPEG gain-map activation capacity is a separate file-format quantity. The
encoder uses the maximum positive component in the writer's output gamut
(at least 1.001 so ISO rational and XMP can express a nonzero interval) for
`HDRCapacityMax`. It is not the edited luminance statistic `max(Y)`, nor the
largest HDR/SDR gain ratio. A saturated channel can require more activation
capacity while its luminance stays below reference white. This metadata never
replaces measured working headroom or accepts current screen headroom.

The pinned libultrahdr 2.0.2 build disables `UHDR_ENABLE_INTRINSICS`: its arm64
NEON RGB-to-YCbCr selector exchanges the Display P3 and BT.2100 coefficients.
The scalar path is required until an upgraded codec passes the same sRGB/P3,
ISO-only/XMP-only/dual ROI regression. JPEG-turbo remains a separate pinned
dependency; this choice does not alter HDR editing math or GPU reporting.

`native_width/native_height` retain the oriented original source canvas for
FINAL admission. `output_native_width/output_native_height` report the current
geometry at that original resolution, using the core geometry rounding and
ignoring `long_edge`. UI zoom and native-size labels use these output bounds,
never a ratio inferred from cropped preview pixels. Borrowed input pairs may
leave the output bounds zero; decoder/render results always populate them.
SDR editing of an HDR container uses a bounded PREVIEW decode too. Its RGB8
proxy retains the oriented native canvas and cannot become a FINAL input.
`sony2fuji_hdr_geometry_size` computes proxy UI bounds without pixel allocation
or an inferred scale ratio. JPEG/DNG export reloads the complete source.
Mac SDR automatic-exposure analysis also requests PREVIEW with a 1280-pixel
long-edge limit before decoding an HDR container.

Native clients share one source-only 128 MiB LRU per process. A different source
URL or fingerprint invalidates prior entries; edited results and current
comparison owners are not copied into the LRU. Decode, render and output admit
estimated additional scratch memory separately before allocation. Physical iOS
uses the current process memory allowance; Simulator has a bounded fallback
when that API returns zero. Mac budgets against half of physical RAM minus the
current process footprint. Admission is conservative and cannot substitute for
the required physical-device size/recovery measurements.

## Adaptive HDR HEIF export

`sony2fuji_hdr_export_heif` takes a FINAL pair and the ISO metadata policy.
The Apple adapter encodes the edited SDR base as an opaque 8-bit sRGB or
Display P3 primary image. Core Image derives an ISO RGB gain map from the
edited HDR rendition. The HDR input's positive RGB peak determines its
encoding headroom, with a minimum of 1.001 for below-white edits.

Before publishing, the adapter reads the HEIF back and checks its dimensions,
normalized orientation, color, bit depth and ISO gain map. It checks the SHA-256
of the metadata source when provided, then publishes atomically. The encoder
uses full-frame memory admission. `sony2fuji_hdr_heif_export_available` requires
a successful in-memory encode and ISO HDR readback on the current Apple runtime.
Windows and Android use the portable HEIF reader and export gain-map JPEG.


## Complete-source streamed JPEG export

`sony2fuji_hdr_export_stream` accepts a versioned row source, not a partial
`sony2fuji_hdr_image_pair_v1`. The source supplies both complete oriented FINAL
renditions, original dimensions, decoder identity, decode revision and a nonzero
SHA-256 matching the frozen metadata source. Preview provenance is rejected.
Apple clients supply Core Image rows through this entry. Android and Windows use
`sony2fuji_hdr_export_proraw`, which supplies DNG SDK rows to the same stream
pipeline. The portable file adapter preserves the same publication contract.

Bounded color strips feed private float spools. Geometry uses the same global
mapping as the full-frame path; resize samples four geometry results as a second
bilinear operation. The result separately reports original dimensions, geometry
bounds at original resolution, encoded dimensions, source and edited headroom.
Neither source statistics nor FINAL provenance may be inferred from one strip.

The codec receives compact inputs one at a time and owns its copies. Source
resources are released before codec allocation. Memory admission runs before
decode, codec and compressed-data/metadata work; disk admission includes both
float renditions and compact outputs. This limits simultaneous storage but is not
constant-memory encoding: libultrahdr retains full-image buffers.

A successful operation publishes one JPEG through an adjacent temporary file and
atomic rename. Source fingerprint and cancellation are checked before publication;
failure preserves an existing destination and clears task scratch. Each scratch
directory publishes a marker only after acquiring its exclusive file lock. The
next export recovers marked directories whose locks are no longer held; active
and unmarked directories remain untouched. Cancellation
inside an uninterruptible codec is observed when it returns. `finish_decode` runs
after both renditions are read successfully. Callers must also release callback
resources after any earlier error or cancellation. Source files and hardlinks are
never valid destinations. The SDR stream writer uses the shared scalar JPEG
conversion with an sRGB ICC profile; metadata mapping excludes MakerNote/RAW data.

## Portable ProRAW development

`SONY2FUJI_HDR_CONTAINER_PRORAW` is a distinct source capability, checked from the
Apple iPhone linear DNG, linearization, embedded profile and profile gain-table
metadata. Generic camera RAW or raster HDR support does not imply this capability.
The probe reads metadata; the decoder and final export compute and revalidate the
source SHA-256. Clients also invalidate preview leases when the file stamp changes.

Portable decode revision 2 uses DNG SDK 1.7.1, original camera white balance,
baseline exposure and the embedded gain table. SDR uses the original embedded
profile. HDR uses a copy with HDR dynamic-range information and a maximum-output
hint of 4, enabling the SDK's overrange path. Both renditions are oriented linear
sRGB float32. This is a separately versioned interpretation; it is not pixel
equivalent to Apple Core Image revision 1. Neither rendition is normalized by its
sample peak. A saved incompatible decode revision is rejected without rewriting it.

SDK stage and render images use private file storage with bounded tile access.
The SDK allocator also checks allocations that bypass image storage, including
JPEG XL decode buffers. PREVIEW limits the returned pair to 2048 pixels on its
long edge; Android uses a smaller source-preview limit. FINAL reads the complete
original even for a reduced output. Stage files add to the stream's disk budget,
and JPEG XL/codec allocations remain subject to runtime memory admission.
Portable export also checks the combined stage and stream disk budget before
starting SDK development. Per-phase checks remain in place. This is admission,
not a cross-process space reservation; later I/O failures still preserve the
existing destination.


For pinned libultrahdr 2.0.2, the major simultaneous gain-map allocations are
12 bytes/pixel of raw clones, 6 bytes/pixel of output capacity, 12 bytes/pixel of
float gain-map scratch and 3 bytes/pixel of RGB gain map. The later compressed
repack releases the first encoder and does not add these working sets together.
Admission retains a conservative 42 bytes/output-pixel plus 128 MiB for codec
scratch, alignment and allocator retention, then independently reserves the
greater of 256 MiB and 20% of currently available process memory. Metadata
rewriting has its own compressed-size-based admission after encoding. These
estimates must be rechecked when codec version, format or ownership changes.
