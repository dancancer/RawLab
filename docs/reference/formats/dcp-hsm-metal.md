# DCP Calibration Stages And Metal

## Scope

Extend the existing native look path with single/dual-illuminant D65
ProfileHueSatMap and real Metal execution. Preserve target RAW development,
request v2, existing CUBE behavior and `.rlook` v1 reading. Windows/GLES keep
the current CPU Auto fallback and explicit Force failure for native looks.

## DCP Policy

The supported order is input matrix, optional HSM, explicit profile EV, optional
LookTable, hue-preserving tone, output matrix and sRGB transfer. HSM uses the
same HSV interpolation/encoding kernel as LookTable. A single Data1 applies to
both matrices; with two tables choose the table paired with the explicit D65
illuminant. Triple-illuminant HSM is rejected until its interpolation is implemented.
Malformed or partially declared tables are errors, not omitted stages.

LookTable may be absent. ToneCurve remains required unless the caller explicitly
supplies JSON `[x,y]` pairs through `compile-dcp --tone-curve path.json`.
An external curve cannot replace an existing profile curve. New HSM/external-tone
profiles that request or default to Auto black require `--no-auto-black`;
metadata records this omission. No implicit ACR3, identity tone or black default
is introduced. Existing no-HSM profile behavior remains compatible.

## Native Format

Keep v1 for profiles with an existing look and no HSM. Version 2 extends the
40-byte v1 header with four uint32 fields: HSM encoding, hue count, saturation
count and value count. Zero dimensions with encoding 0 mean an absent table;
partially zero dimensions are invalid. The original header describes LookTable,
which may also be absent in v2. After the matrices/exposure, serialize HSM triples,
then LookTable triples, tone samples and metadata. All endian/type rules remain.
The combined table count is at most 4 million cells; the file limit stays 64 MiB.

Expose an immutable typed stage payload from DcpLook for the CPU and Metal
evaluators. Both share the same decoded values and stage order. No RGB CUBE bake.

## Metal

Add a dedicated base-and-DCP kernel to the existing photo pipeline. Keep the
legacy PhotoParams/CUBE kernel unchanged. Upload matrices/controls and packed
HSM/look/tone buffers once per immutable profile, using the existing pointer
identity cache pattern. Retain ownership while GPU resources are cached.

GPU uses float32 arithmetic and is compared with the double CPU reference.
The dedicated DCP library uses `MTLMathModeSafe` on macOS 15+/iOS 18+ so that
nonfinite checks remain meaningful. Earlier systems retain CPU fallback; the
legacy CUBE library and its compile options are unchanged.
Nonfinite stage results must cause Auto fallback/Force failure, not a successful
render with corrupt colors. CPU remains the precise reference and Off option.
The result is marked Metal only after the command buffer and stage checks succeed.
Pixel/resize/WB/strength/detail/export ordering is unchanged.

## Validation

Add red tests for noncommuting HSM/look order, profile exposure position, D65
selection/shared Data1, optional LookTable, external-tone/black policies and v2
corruption. Keep v1 regressions. Require CPU/Python error <=2e-6 on identical
float32 input; GPU synthetic/real photo output within the existing 2-DN tolerance.
Exercise actual Metal, CPU fallback, Force, cache changes and file export.
Use real Adobe Standard calibration tables only in ignored local artifacts, with
explicit externally supplied identity tone and no-auto-black for stage validation,
not as a claim of Lightroom equivalence. Rebuild Mac and run core/Python gates.
