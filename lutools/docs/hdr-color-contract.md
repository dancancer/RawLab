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

Native clients share one source-only 128 MiB LRU per process. A different source
URL or fingerprint invalidates prior entries; edited results and current
comparison owners are not copied into the LRU. Decode, render and output admit
estimated additional scratch memory separately before allocation. Physical iOS
uses the current process memory allowance; Simulator has a bounded fallback
when that API returns zero. Mac budgets against half of physical RAM minus the
current process footprint. Admission is conservative and cannot substitute for
the required physical-device size/recovery measurements.
