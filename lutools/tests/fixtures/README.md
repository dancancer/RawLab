# Synthetic DNG Fixtures

`bayer-demosaic.dng` is a generated 128 x 96 RGGB mosaic with a slanted color
edge, fine texture and deterministic noise (seed 50918). It has BlackLevel 64,
WhiteLevel 4095, orientation 1 and non-neutral AsShotNeutral. It is not a photo
or a camera-noise calibration. Native tests compare production output with
independent, explicitly configured LibRaw VNG/DHT processing, including WB
reload, method switching, half-size and FBDD behavior.

Regenerate it with
`python3 lutools/tests/make_demosaic_fixture.py lutools/tests/fixtures/bayer-demosaic.dng`
using NumPy and tifffile (generated with tifffile 2026.10.15). Neither Python
package is required to run the native tests. SHA-256:
`aea0ca151072ed6194f90affb855cd4a2bb45135e3869fb8ef90968619d213cb`.

`linear-jxl.dng` and `linear-uncompressed.dng` contain the same generated
32 x 24 RGB ramp, stored as three-channel 16-bit LinearRaw with orientation 6.
They are not photographs and contain no private metadata. The JPEG XL stream
uses lossless compression; tests compare its decoded pixels with the
uncompressed file, independently of the SDK's decoder.

`linear-jxl-gain.dng` stores the original ramp with a required Stage2 GainMap
opcode multiplying all three planes by 2. `linear-doubled.dng` stores the
independently doubled integer samples without any opcode. This pair verifies
that the SDK applies required opcode lists rather than only decompressing JXL.

`linear-jxl-stage1.dng` contains only a required Stage1 MapTable, mapping each
16-bit sample to its integer half. `linear-halved.dng` contains independently
halved samples without an opcode. `linear-jxl-required-unknown.dng` contains an
unsupported required Stage1 opcode and must fail instead of returning pixels.

`linear-jxl-crop-gain.dng` combines the required Stage2 GainMap with an internal
ActiveArea of (top=1, left=1, bottom=23, right=31), inside the stored 32 x 24
image. `linear-crop-doubled.dng` stores independently doubled samples with the
same ActiveArea and no opcode. Both must produce oriented 22 x 30 output, with
no second crop or shifted pixels.

`linear-jxl-default-crop-gain.dng` and `linear-default-crop-doubled.dng` add
DefaultCropOrigin (1,1) and DefaultCropSize (28,20) within that ActiveArea.
They verify the conversion from storage to Stage2 coordinates and must produce
oriented 20 x 28 output with identical pixels.

`linear-jxl-channel-levels.dng` and `linear-channel-levels.dng` contain the
original ramp with BlackLevel (1024,2048,4096) and WhiteLevel
(32767,49151,65535). `linear-normalized.dng` contains independently calculated
16-bit samples, rounded from `(sample - black) * 65535 / (white - black)`, with
zero black and full white levels. Tests compare the first camera-WB decode
with these samples, require identical camera output after a custom-WB round
trip (also through the C ABI), and compare JXL-to-ordinary decoder reuse with
a fresh ordinary DNG processor. This catches stage flags set too late for
LibRaw identification or left behind when changing decoders.

The native suite also uses the SDK's `DNG_SetSimulateMemoryFull` diagnostic hook
to assert OutOfMemory on initial load, white-balance reload and the C ABI.

`linear-jxl-lens.dng` and `linear-lens.dng` add synthetic camera/lens/focal EXIF
that matches `lenses.xml`, with identical JXL/uncompressed samples.
`linear-jxl-stage3-lens.dng` adds a required Stage3 WarpRectilinear opcode
(one shared plane, radial coefficients 1/-0.08/0/0, zero tangential terms,
center 0.5/0.5). Tests require exact Lens-off/on identity after this actual SDK
warp, including WB reload, while JXL without Stage3 and ordinary DNG must still
apply the synthetic distortion/TCA calibration. Reusing a decoder/session must
not retain the previous input's Stage3 warning or Lens report. These fixtures
are generated data, not lens calibration photographs.

Regenerate with `python3 lutools/tests/make_jxl_fixture.py lutools/tests/fixtures`
using `cjxl` 0.11.1. No encoder is needed to run the native regression tests.

## JPEG-compressed DNG

`jpeg-lossy.dng` is a generated 32×32 RGB gradient, not a camera photo. Its TIFF
container uses DNG 1.4, Compression/PhotometricInterpretation 34892, an identity
color matrix and neutral white balance. The JPEG payload was encoded by stb at
quality 95. It was generated with `jpegDng()` in `raw_format_tests.cpp`; the
in-memory desktop regression independently recreates the same fixture.

Android uses this 3 KiB file to prove that its target-built LibRaw actually
decodes JPEG-compressed DNG, without optional external photos or a large test
asset. It is original RawLab test data under the repository license.

## Local Denoise Evaluation

`denoise-holdout-local.json` declares four independently sourced RAW scenes.
The files remain outside Git under the main workspace's `.cache/shared/`;
the manifest records their SHA-256, download and license URLs, content groups,
and fixed regions. They cover two low-ISO Bayer scenes, a high-ISO X-Trans
interior and a high-ISO Bayer still life. None has a clean reference, so their
variation measurements must not be presented as reconstruction accuracy.

The holdout designation refers to selection after freezing the first candidate,
not perpetual blindness. Once a scene has informed a later algorithm or parameter
change, treat it as regression data and acquire new holdouts for that candidate.
The frequently inspected studio scenes in `denoise-raw-local.json` are tuning
or regression inputs, not independent holdouts. See
[`denoise-quality.md`](../../docs/denoise-quality.md) for the runner and reference
registration contract.

## Processing Version References

`processing-wavelet-reference.json` records CPU output from the released
`v0.8.2` binary and the frozen version-2 candidate for the deterministic
`processing_reference_fixture.h` input. Its four intensity bands include
negative, near-black, midtone and over-one values; five strength combinations
cover luma, fine/coarse chroma and mixed filtering. Pixel samples, whole-image
mean/RMS, input/output hashes and binary/source provenance are recorded in the
fixture, rather than generated from the implementation being tested.

`processing_version_tests` checks both profiles and same-input cache isolation.
`processing_session_tests` checks default/invalid setters and profile switches.
`processing_export_probe` is an optional full-resolution RAW export helper;
compile it with `RAWLAB_LEGACY_REFERENCE` against v0.8.2 to compare released
CPU/forced-native-GPU output with the current legacy path. External camera
files and generated full-image exports remain outside Git. These compatibility
checks do not establish image quality or untested GPU-platform parity.
