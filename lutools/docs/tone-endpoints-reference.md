# Black and white endpoint CPU reference

Status: internal reference for ITER-05. This module is compiled and tested, but
is not connected to a session, C ABI, Agent recipe, GPU backend or native UI.
Vibrance, photographic quality acceptance and the complete parameter chain are
still outstanding. It does not change the application's existing rendering.

## Domain and operation

`ToneEndpointOptions` has finite `blackPoint` and `whitePoint` values in `[-1,1]`.
Both default to zero. Callers must check `valid()` before applying a configuration.
The pixel input must contain finite floats in RawLab's display-encoded RGB
convention; these controls do not alter RAW sensor black/white levels.

Both zero values return the original RGB or image immediately. The bypass keeps
all bytes, including signed zero and finite channels outside `[0,1]`; it does not
add a clamp or color-space conversion to an existing rendering.

For an active configuration, use double intermediate values and the encoded-luma
scalar:

```text
Y = G + 0.2126 * (R - G) + 0.0722 * (B - G)
S(t) = clamp(t, 0, 1)^2 * (3 - 2 * clamp(t, 0, 1))
D(Y) = 1 - S(Y / 0.35)
H(Y) = S((Y - 0.65) / 0.35)
delta = 0.20 * (blackPoint * D(Y) + whitePoint * H(Y))
output[channel] = clamp(input[channel] + delta, 0, 1)
```

The BT.709 coefficients sum to one; the difference form preserves `Y=G` exactly
for gray input. This is encoded luma, not scene-linear luminance. Add the same
offset to all channels, preserving gray and RGB differences until SDR clipping.
Active output clips to `[0,1]`, including out-of-range input. A positive black
control raises the dark end; a positive white control raises the light end.
The interval `[0.35,0.65]` has no endpoint displacement.

## Monotonicity and reference values

The two smoothstep transitions do not overlap. Inside either transition,
`|S'| <= 1.5`, so for every valid pair of controls the unclipped grayscale
mapping `F(Y)=Y+delta` satisfies:

```text
F'(Y) >= 1 - 0.20 * 1.5 / 0.35 = 1/7 > 0
```

The subsequent monotone SDR clamp can flatten an endpoint but cannot reverse
the grayscale ordering. The former candidate amplitude `0.25` fails this bound:
at `blackPoint=1, whitePoint=0`, `F(0.15)=0.3016034985` is greater than
`F(0.20)=0.2983965015`. With amplitude `0.20` these become `0.2712827988` and
`0.2787172012`. The white-reduction case has a symmetric counterexample.

The automated reference grid covers 81 pairs of controls at quarter steps from
`-1` to `1`, and 10001 grayscale positions per pair. It checks the unclipped
double formula and the production float result separately, plus transition
boundaries, fixed vectors, color offsets, exact bypass, validation and image/pixel
parity. Test checks remain active with `NDEBUG`; they do not use `assert`.

## Validation and remaining gates

The standalone target needs only C++17 and can be run without native dependencies:

```bash
c++ -std=c++17 -O2 -DNDEBUG -Wall -Wextra -Werror \
  -Ilutools/include -Ilutools/src \
  lutools/tests/photo_tone_endpoints_tests.cpp \
  lutools/src/core/photo_tone_endpoints.cpp -o /tmp/rawlab-tone-endpoints
/tmp/rawlab-tone-endpoints
```

It is also registered as CTest `photo_tone_endpoints` in the regular core build.
The reference is a prerequisite, not an ITER-05 completion record. Before public
integration, validate fixed photographic samples (skin, saturated colors,
highlights, shadows and gradients), freeze fixture identifiers/hashes and quality
criteria, implement vibrance, and wire the versioned config through all consumers.
Any changed amplitude, transition or overlap requires a new derivative bound and
the same grid. GPU consumption must use the frozen constants and explicit fallback
rules. Existing request v2 and schemas v1–v5 remain unchanged.
