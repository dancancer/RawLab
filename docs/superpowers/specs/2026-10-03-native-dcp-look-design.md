# Native DCP Look Evaluation

This records the first, CPU-reference phase. The
[HSM and Metal extension](2026-10-03-dcp-hsm-metal-design.md) adds version 2 and
supersedes the CPU-only runtime restrictions below; the version 1 file contract
remains valid.

## Scope

The approved next step is eliminating complete-DCP-to-CUBE approximation before
extending DCP stage coverage. Keep the existing 1.1 D65 adaptation and target RAW
development unchanged. Implement a portable CPU evaluator for that supported
subset, not a new camera calibration system or an Adobe renderer.

## Choice

Increasing a uniform CUBE grid cannot reliably meet the sampled error gate.
Adding DCP stages to three GPU shaders at once would mix arithmetic, resource
layout and device coverage risks with the reference implementation. Use a native
double-precision CPU reference first. Existing CUBE CPU/GPU paths remain intact.

The preparer writes `.rlook` through a new `compile-dcp` command. It preserves
the input/output matrices, exposure choice, original normalized HSV table and
4097 tone samples. There is no intermediate RGB CUBE or F-Log2 encode/decode.
Native apps need neither Python nor OCIO. Source DCP data is still private to
the user's local files; no Adobe tables are committed.

## File Contract

All integers and IEEE floating-point fields are little endian. Version 1:

1. Eight-byte magic `RLOOKDCP`.
2. Eight uint32 fields: version (1), flags (0), table encoding (0/1), hue count,
   saturation count, value count, tone sample count (4097), JSON metadata byte count.
3. Row-major 3x3 input matrix and 3x3 output matrix, each nine float64 values.
4. One float64 exposure multiplier in `[2^-16, 2^16]`.
5. HSV table triples as float32 in value/hue/saturation order, exactly the
   normalized table evaluated by the Python reference.
6. Exactly 4097 float64 tone samples.
7. UTF-8 JSON metadata, at most 65536 bytes, for provenance and inspection.

Native rendering ignores metadata semantics. Header/version/flags, exact length,
dimensions, encoding, numeric finiteness and nonnegative saturation/value scales
are validated before a profile can be used. Table bounds remain 4 million cells;
the file limit is 64 MiB. Matrix/tone magnitudes cannot exceed finite float32
range, keeping double intermediates bounded for finite native float input.
Unknown versions and malformed/trailing payloads fail, never fall back to CUBE.
Writing retains the existing source-alias protection and atomic no-clobber behavior.

## Native Interface

`DcpLook::loadCached(path)` returns an immutable shared profile or null.
`DcpLook::apply(linearSrgb)` returns display-sRGB as the core's float `RGB`.
Evaluation uses double intermediates and the Python reference's operation order:
input matrix, explicit exposure, SDR clamp, HSV interpolation, hue-preserving
tone, output matrix, sRGB transfer, final clamp. Cache identity uses path, mtime
and size, with one immutable cached profile, matching existing LUT behavior.

The PHOTO request keeps ABI version 2 and reuses `lut_path`. `.cube` continues
through the existing validation. `.rlook` uses the new evaluator after common
linear WB/exposure, then the existing strength blend, adjustments and output.
Strength zero does not load either file. GPU Auto/Off render `.rlook` on CPU;
Force returns the existing GPU processing-failure status. No GPU success is
reported for CPU work. Loading before RAW decode selects the correct copy/cache
path. Exact/interactive and file-export rules are unchanged.

macOS and Windows file pickers accept `.rlook` as well as `.cube`. Mobile custom
import UI and GPU execution of native DCP stages are outside this step.

## Verification

Use synthetic redistributable DCP fixtures to test package structure, corruption,
source protection and native math, including hue wrapping, encoded value axes,
tone middle-channel preservation and strength/exposure behavior. Cross-language
tests feed the same float32 scene samples to Python and C++ and require max
display-channel error at most `2e-6`; this is arithmetic parity, not color accuracy.

Re-run seven local profiles across the existing six RAW fixtures and stress
samples without baking. Verify native output against Python directly, Auto CPU
fallback, Force failure, file export and unchanged canonical-CUBE GPU tests.
Run the core suite and Mac build/affected engine checks. Record unrun Windows
and mobile platform tooling rather than implying hardware coverage.
