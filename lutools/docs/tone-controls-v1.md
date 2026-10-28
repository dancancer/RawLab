# Tone controls algorithm v1

Status: CPU numerical v1 admitted for GPU/client integration after synthetic
reference checks and the fixed five-image quality set below. GPU, client and
joint acceptance remain separate; this is not the full ITER-05 acceptance record.

The additive `sony2fuji_tone_controls_config` v1 carries `black_point`,
`white_point`, and `vibrance`, each finite and in `[-1,1]`. All default to zero.
The UI and transfer field catalogue use `[-100,100]`; only the native/Agent
boundary divides by 100. Request v2 and processing identities 1/2 retain their
existing layouts and behavior. These controls have no sensor, demosaic, exposure
baseline or RAW-cache meaning and are independent of master-recipe strength.

## Stage and identity

Both operations consume **display-encoded sRGB**, after neutral/look mixing.
Black/white precede the existing highlights/shadows, curve, contrast/saturation
sequence. Vibrance follows that sequence and precedes HSL. Source geometry,
chroma/detail/effects and output resizing retain their existing relative order.

Black/white zero and vibrance zero each return their original float pixels without
arithmetic or clamping. Thus the complete zero configuration keeps the old
pipeline byte-for-byte, including out-of-range working pixels. Active black/white
produces bounded SDR output as specified for endpoint control. Vibrance keeps
SDR input bounded while preserving the existing out-of-gamut working values
that legacy contrast/saturation may produce before HSL.

All formulas below use `S(t)=clamp(t,0,1)^2*(3-2*clamp(t,0,1))`. Luminance is
`Y=.2126R+.7152G+.0722B`. Implementations evaluate it as
`G+.2126*(R-G)+.0722*(B-G)` so gray has exactly its original channel value.
The coefficients are normalized and describe this display-space operation.

## Black and white endpoints

```
D(Y) = 1-S(Y/.35)
H(Y) = S((Y-.65)/.35)
delta = .20*(black_point*D(Y)+white_point*H(Y))
output = clamp(input + (delta,delta,delta), 0, 1)
```

The weights are evaluated from the original input luminance. Black lift works at
exact zero. The middle interval `[.35,.65]` stays unchanged. An unclipped color
moves along the neutral axis. The two transition intervals do not overlap, and
the derivative of the unclipped grayscale mapping is at least `1/7`; output
clamping cannot reverse its order. This bound depends on amplitude `.20` and
transition width `.35`. Changing either requires a new numerical review.

## Vibrance

Let `M=max(R,G,B)`, `m=min(R,G,B)` and `C=M-m`. If `C=0`, return the original
gray without introducing chroma. Positive vibrance leaves already out-of-gamut
pixels unchanged: there is no available SDR chroma gain. Otherwise define
`s=C/M`; `M` is then positive whenever division is needed. Negative vibrance
uses the original input and luminance, including existing out-of-gamut values.

Negative `v` uses gain `1+v`, reaching exactly gray at `v=-1`. Positive `v` uses
`1+v*(1-s)^2*(1-.75*skinMask)`. The mask is a smooth color heuristic:

- Hue uses the conventional RGB hexcone angle in `[0,360)`. Its weight is
  `1-S(circularDistance(hue,35°)/45°)`.
- Luminance weight is `S((Y-.08)/.12)*(1-S((Y-.75)/.20))`.
- Chroma weight is `S((C-.02)/.08)*(1-S((C-.60)/.25))`.
- `skinMask` is the product of these three weights. It reduces positive gain;
  it does not prevent intentional negative desaturation.

Reconstruct each channel as `Y+(channel-Y)*gain`. Limit positive gain by the
first intersection of this constant-luminance ray with the RGB cube: for positive
`channel-Y`, the bound is `(1-Y)/(channel-Y)`; for negative differences it is
`-Y/(channel-Y)`. This avoids changing hue by separately clipping enlarged
channels. A final `[0,1]` clamp only contains float rounding when the input was
already SDR. Negative gain in `[0,1]` is a convex interpolation between each
original channel and its normalized luminance, so it cannot expand the existing
input range. Gain 1 returns the original input exactly. This policy preserves
continuity through zero, including with legacy contrast and downstream HSL;
pre-clamping working pixels produces a visible jump in the combined native regression.
Near-gray chroma is never thresholded
into a different hue class; the smooth chroma mask tends to zero.

## Reference and quality gates

The original synthetic vectors are in
[`tone-controls-v1-reference.json`](../tests/fixtures/tone-controls-v1-reference.json),
fixture ID `rawlab-tone-controls-v1-reference`, SHA256
`273d0664fc6f4967619695720c2ca4693b149b63b2e12d5d301b0920cc9f5377`.
They contain input RGB, parameters and binary64 reference output; no photograph
is embedded. CPU float tolerance is `5e-6` per channel. Separate property tests
cover 81 black/white combinations with 10001 gray samples each, the previous
`.25` counterexample and its white-end counterpart, exact gray/identity,
monotone desaturation, finite/bounded output and local color continuity.

GPU admission compares float output within `5e-5` and RGB8 within 2 DN on matched
inputs and sizes, checks actual backend execution, and includes simultaneous
legacy tone, LUT, HSL and final-size combinations. An unavailable or unfinished
backend must use CPU in Auto and fail explicitly in Force.

Real-image admission uses the fixed, hash-identified
[`tone-controls-v1-quality.json`](../tests/fixtures/tone-controls-v1-quality.json)
set with source/license and region coordinates: three RAW scenes and two raster
photographs, each with five recorded parameter combinations. All use processing
v2, raw scene exposure or raster sensor exposure, and CPU FINAL native sizing.
Compare neutral and signed controls at matched size and at
100%: common skin colors, high-saturation objects, sky/gradients, highlights and
shadow noise. Check that positive vibrance does not create hue bands, gray color
casts or unintended clipping; endpoint controls must not reverse tonal structure.
The mean absolute display-luminance change from vibrance must stay below 0.5 DN
after RGB8 inspection quantization; the selected set measured at most 0.303 DN.
Full-source output hashes and 1:1/overview evidence are retained in the task/PR
quality record. The numerical grid is not a substitute for visual checks.
This set is observational, without a clean/colorimetric ground truth; passing it
does not claim universal skin-tone/camera calibration. Negative black/positive
white deliberately discard endpoint detail, and positive vibrance can strengthen
existing chroma noise within its bounded gain. These controls are not recovery
or denoising algorithms.
