# Nikon High Efficiency Decoder

This locally maintained C++17 decoder replaces LibRaw 0.22.2's unsupported
`nikon_he_load_raw` placeholder. It decodes the Nikon 14-bit, four-component
JPEG XS profile to the original RGGB sensor mosaic. Metadata, active crop,
white balance, demosaic and rendering remain in the existing LibRaw pipeline.
Unknown capabilities, component layouts and transfer-function variants fail
closed rather than producing an approximate image. It is not a general JPEG XS
implementation or a claim of support for every Nikon camera or compression mode.

## Sources And Changes

- Entropy, bit reading, header/topology and inverse wavelet stages are a C++
  adaptation of Nicolai Buchwitz's dnglab contribution, commit
  `0f044c2c30d78c4ed5fcede6ab4e8db893d566f6`, under LGPL 2.1:
  https://github.com/nbuchwitz/dnglab/tree/0f044c2c30d78c4ed5fcede6ab4e8db893d566f6/rawler/src/decompressors/jpegxs
  The original source notices state `Copyright 2026` and `LGPL-2.1`.
  Changes include bounded packet reads, explicit signed floor shifts, checked
  coefficient arithmetic, strict Nikon profile validation and allocation limits.
- Bayer reconstruction is a whole-plane adaptation of Dmitri Sotnikov's LibRaw
  contribution, including RdWing's bottom-row correction and file-derived integer
  nonlinear transfer: https://github.com/LibRaw/LibRaw/pull/826
  https://github.com/LibRaw/LibRaw/pull/826#issuecomment-5639654673
  https://github.com/LibRaw/LibRaw/pull/826#issuecomment-5639699213
  It does not use dnglab's experimentally fitted chroma gains or companding curve.
- RawLab integration and C++ adaptation: Copyright 2026 RawLab contributors.
  `codec.h` is the only supported entry point; `internal.h` describes private
  stages whose geometry is created by the validated parser/topology builder.

The added decoder is LGPL 2.1, not CDDL. The combined patched LibRaw is used
under LibRaw's LGPL option. Preserve this notice and `LICENSE.LGPL-2.1` in binary
packages and corresponding source, including standalone patched LibRaw archives.
This notice does not establish patent rights or replace a release licensing review.

Adobe DNG Converter is not a dependency and is not distributed. It is used only
as an optional offline reference during development. The codec has no Adobe
executable, SDK dependency, external process, fitted per-camera LUT or network use.

## Tests

`nikon_he_codec` exercises synthetic raw-GCLI packets, sign modes, partial
widths, slice boundaries, per-file transfer parameters and malformed streams.
Real photographs and proprietary reference outputs are not included in source.
Pixel-reference and application integration checks require local NEF fixtures;
passing synthetic tests alone does not establish camera coverage.

`nikon_he_reference_tests input.NEF reference.pgm` compares every sensor sample
after the actual patched LibRaw `unpack()`, before black subtraction/demosaic.
The reference must be an unrotated big-endian 16-bit P5 PGM, such as the output
of `dnglab analyze --raw-pixel reference.dng` from an offline reference DNG.
It reports mismatched sample count and maximum absolute error; exact equality
is required. Keep both inputs outside the repository.
