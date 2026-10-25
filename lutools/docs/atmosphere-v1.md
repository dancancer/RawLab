# Atmosphere algorithm v1

Status: CPU numerical v1 admitted for client integration after the synthetic
checks and fixed seven-image quality review. Full platform and client/joint
gates remain separate; this document does not close ITER-10 or IT-12/15.

`sony2fuji_atmosphere_config` v1 is an additive 16-byte configuration containing
`version`, `struct_size`, `clarity`, and `dehaze`. Both values are finite, in
`[-1,1]`, and default to zero. UI/storage/transfer values use `[-100,100]`, with
division by 100 only at the native/Agent boundary. The exchange IDs are
`effects.clarity` and `effects.dehaze`. Request v2 and photo-effects config v1
retain their layouts. Invalid setters preserve the previous complete state;
clients must explicitly set identity when reusing a session.

## Pipeline, source scale and backend

Dehaze consumes the display-sRGB result of the neutral/look blend and precedes
black/white, tone/curve, vibrance, HSL and grading. Clarity follows chroma/legacy
denoising and precedes the existing sharpening, vignette/grain, geometry and
final resize. Clarity is a separate medium-scale operation, not an alias for the
old pixel-radius sharpen filter. Neither value is multiplied by legacy recipe
strength.

Each zero value bypasses its operation without arithmetic or clamping. Both
zero preserve the previous pipeline, including its fast-preview choices and
extended working values. Any nonzero atmosphere value selects a complete-source
CPU render: RAW uses the exact decode, viewport/interactive early resizing is
disabled, and final resize follows the effects. Thus a nonzero preview at a
given output size is the same as the corresponding FINAL render. Enabling the
first nonzero value can also refine the old zero-state proxy detail. This is a
quality/performance policy, not a claim that the zero proxy was full resolution.

GPU Auto uses the whole CPU path, including denoising/look. GPU Force returns
`UNSUPPORTED` before rendering. It never reports a successful GPU atmosphere
pass. This applies on Metal, D3D11 and GLES builds. GPU acceleration of these two
spatial stages is not part of v1.

## Shared analysis and arithmetic

All analysis uses display-linear sRGB, with the standard sRGB inverse/forward
transfer functions. Luminance is `Y=G+.2126*(R-G)+.0722*(B-G)`, preserving exactly
equal gray channels. Let `S(x)=u*u*(3-2*u)`, where `u=clamp(x,0,1)`.

The analysis grid has scale `min(1,1024/max(sourceWidth,sourceHeight))` and each
dimension is rounded to the nearest integer, minimum one. Every analysis pixel
is an area-weighted average of the source footprint **after inverse sRGB**.
Only analysis clamps extended RGB to `[0,1]`; application uses the original
working pixel. Full-source dimensions and this fixed grid determine spatial
scale, never window size, requested preview edge or current crop.

Box means use a square radius, truncate at image boundaries and normalize by the
actual sample count. Separable sums accumulate in double. Minimum filters use
the same truncated square footprint. No reflected or wrapped pixels are added.
Upsampling is bilinear at aligned pixel centers, with edge extension. All
constants below apply in display-linear units.

The scalar guided filter follows the local linear model described by
[He, Sun and Tang](https://people.csail.mit.edu/kaiming/publications/eccv10guidedfilter.pdf):
`a=(mean(I*p)-mean(I)*mean(p))/(var(I)+epsilon)`,
`b=mean(p)-a*mean(I)`, then output `mean(a)*I+mean(b)`. Variance is bounded below
by zero to contain floating-point roundoff. This implementation uses its own
separable box/minimum code and has no new filtering-library dependency.

## Clarity

On the analysis grid, let `r=max(1,round(.01*longEdge))`.

1. `M=boxMean(Y,max(1,r/8))`, using integer division for the small radius.
2. Compute self-guided base coefficients for `M`, radius `r`, epsilon `.001`.
   Let `B=mean(a)*M+mean(b)` and `V` be the guide variance from that window.
3. `D=M-B`. The protected medium residual is
   `R=clamp(D,-.08,.08)/(1+V/.002)^2 * S(abs(D)/.001)`.
4. At each original pixel, bilinearly sample `M` and `R`. With original linear
   luminance `Y`, use `fineGuard=1-S(abs(Y-M)/.08)` and
   `lightGuard=S((Y-.01)/.12)*(1-S((Y-.65)/.3))`.
5. `deltaY=1.5*clarity*R*fineGuard*lightGuard`. A magnitude below `1e-8` or
   nonpositive luminance leaves the original pixel untouched. Otherwise use
   luminance gain `max(-1,deltaY/Y)` along the original linear RGB direction.

The small prefilter removes pixel-frequency noise from the residual. Variance
protection reduces broad bright/dark edge halos; the full-resolution fine guard
protects detail that the analysis grid averages. The shadow weight is deliberately
conservative. Positive/negative values respectively increase/decrease medium
local contrast; neither promises optical refocusing or texture recovery.

For SDR input, move along the RGB direction only as far as the first cube
boundary, then clamp final rounding error. Extended working values may contract
toward zero continuously; outward expansion stops at the SDR boundary. They are
not pre-clamped, avoiding a jump when legacy tone moves a channel across zero or
one. Nonfinite working pixels are not modified by this stage.

## Dehaze

The atmospheric model is `I=J*t+A*(1-t)`, based on the dark-channel method of
[He, Sun and Tang](https://people.csail.mit.edu/kaiming/publications/pami10dehaze.pdf).
The bounds, color/sky/noise protections and negative mode below are RawLab
engineering choices, not the paper's constants or a Lightroom reproduction.

Let `r=max(1,round(.0075*analysisLongEdge))`.

1. Compute the local minimum of `min(R,G,B)`, radius `r`.
2. Select the largest `max(1,floor(pixelCount/500))` dark-channel samples. Equal
   values use ascending pixel index, making selection deterministic. Average
   their RGB to `C`; let `L=luminance(C)`. Airlight components are
   `A[c]=clamp(.85*L+.15*C[c],.1,.95)`. The neutral component limits global tint
   from bright colored objects; it is not white-balance calibration.
3. Compute `d=minWindow(min(R/A.r,G/A.g,B/A.b),r)`, then
   `t0=clamp(1-.85*d,.5,1)`. Guide `t0` by analysis luminance, radius `2*r`,
   epsilon `.001`. Store the smoothed linear coefficients and guide variance.
4. At each original pixel sample those fields and evaluate
   `t=clamp(mean(a)*Y+mean(b),.5,1)` with full-resolution luminance.

For positive `d`, define
`flatBright=S((Y-.08)/.22)*(1-S(V/.001))` and
`protection=Y/(Y+.03)*(1-.8*S((Y-.5)/.4))*(1-.75*flatBright)`.
Effective transmission is `max(.5,1-d*protection*(1-t))`, and the desired RGB
change is `(I-A)*(1/effectiveTransmission-1)`. Shadow protection uses a rational
weight: a steeper shadow smoothstep produced a measurable gray-ramp reversal.
Flat bright regions receive stronger protection because low texture gives weak
evidence for the dark-channel prior and can amplify sky noise.

For negative `d`, mix toward airlight with
`h=-d*.45*(.25+.75*(1-t))`, giving change `(A-I)*h`. This adds a bounded haze
layer rather than reversing a global contrast control. It can lift exact black.

Positive SDR changes use a soft approach to the RGB cube boundary. For each
channel change `delta`, boundary pressure is `delta/(1-I)` when positive or
`-delta/I` when negative. Let `P` be the maximum pressure, initially zero;
apply `delta/(1+P)` uniformly to all channels. A zero headroom gives infinite
pressure and zero movement. This preserves the modeled direction while avoiding
flat clipped patches in warm textured highlights. Negative haze is already a
convex mix within the cube. Final clamping only contains rounding error.
Positive dehaze leaves already extended
working values unchanged, consistent with zero available outward movement at the
boundary. Negative haze mixes them toward the bounded airlight without first
clipping them. Changes below `1e-8` leave original bytes untouched.

## Analysis cache identity

The session stores airlight, guided coefficients and variance. Cache identity is
the analysis-grid float content (64-bit FNV-1a over explicit float bits) plus full
source dimensions. This represents all inputs to that analysis: source content,
RAW/WB/exposure/processing/lens/AI results, wavelet and look changes that affect
those samples. It excludes dehaze amount and downstream tone/HSL/clarity.

The complete-source analysis image and its fingerprint are still produced on
each request. A hit avoids dark-channel selection and guided-statistics work;
it does not avoid the source scan, source development or area average. This
tradeoff makes mutable buffer input safe without assuming pointer identity.
Different sources or requests yielding exactly the same analysis values may
reuse the same analysis, which is mathematically equivalent to rebuilding it.
The full-resolution application always reads current pixels. A regression swaps
pixels within one downsample footprint and checks cached output against fresh
analysis byte-for-byte. This is not a full-source provenance hash.

## Quality and regression gates

The fixed source/license/hash/region/parameter matrix is
[`atmosphere-v1-quality.json`](../tests/fixtures/atmosphere-v1-quality.json).
It contains seven external photographs: clear sky/grass/colored objects, a
high-ISO X-Trans interior, a night street, two NASA photographic portraits,
real country fog and a backlit flower. No source photograph is bundled. The
runner retains source credits and marks comparison images as modified tests;
the CC BY flower's attribution and license apply to the derived comparisons.

The independent binary64 one-pixel reference is
[`atmosphere-v1-reference.json`](../tests/fixtures/atmosphere-v1-reference.json),
generated by `make_atmosphere_reference.py`. In this boundary case the minimum
and guided filters reduce algebraically to their inputs. The 45 vectors check
the model, signed mode, transfer and gamut formulas at `5e-6` float tolerance;
they do not replace the following spatial properties.

The synthetic/native gates cover:

- Zero byte identity, valid inclusive ranges, rejection without losing session
  state, bounded finite SDR extrema and exact neutral gray.
- Both signs of medium-scale contrast, a strong edge's maximum change below
  `.008` encoded RGB, and dark noise change MSE below `1e-7` in linear luminance.
- Known synthetic haze: positive endpoint reconstruction MSE below 75% of the
  hazy input error; negative haze lifts a dark object toward atmospheric light.
- A smooth bright sky noise standard-deviation ratio below 1.5 in encoded RGB;
  this is a specific synthetic fixture, not a universal photo-quality score.
- No newly clipped channel in the frozen warm textured-highlight fixture.
- No reversals on the frozen gray ramp; continuity at finite gamut boundaries;
  twice-resolution medium-scale comparison below `.002` encoded RGB.
- Strength-independent analysis reuse, current-pixel behavior with identical
  downsample averages, small/large/small preview equality, and a real-RAW exact
  decode/clear round trip. The pre-HSL probe includes Dehaze before black/white
  and excludes downstream Clarity.

The fixed-set review includes the six variants (identity, each signed endpoint,
and half-strength combination) at native-resolution crops and matched overviews.
It admits the bounded local contrast/haze behavior without new visible edge
rings, broken structures or broad color patches in these samples. Maximum
positive dehaze can make existing skin grain, JPEG blocks and color texture more
visible, and can warm existing skin colors; it is not a denoiser or a skin-color
preservation mode. The final synthetic gray ramp remains monotone and the warm
highlight fixture retains headroom. The lower transmission floor and soft gamut
map are part of this quality decision, not deferred optimizations.

Real-image measurements are descriptive: there is no haze-free ground truth for
those photos, and an increase in texture variation is not proof of recovered
detail or lower noise. Admission applies to this version and fixed set, not all
cameras/scenes. Physical GPU qualification is inapplicable to the v1 CPU stage;
native builds must still verify honest backend selection.
