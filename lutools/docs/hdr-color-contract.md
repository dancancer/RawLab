# Phone HDR color contract

This contract describes HDR processing version 1. It is separate from the RAW
processing versions. The legacy RAW and SDR paths retain their existing math.
The supported input and state rules are in the
[HDR design](../../docs/design/hdr-photos/technical-design.md).

## Working values and order

Each source owns an HDR rendition and the original SDR rendition. Both are
oriented, opaque, display-referred, D65 extended-linear sRGB RGB32F. A value of
1 is SDR reference white; 2, 4 and 8 are +1, +2 and +3 EV. Finite negative
components and super-whites survive processing. There is no RAW baseline,
camera WB, scene sigmoid, LUT or display-headroom input.

The order is relative WB, linear exposure, rendition-specific tone, saturation,
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
