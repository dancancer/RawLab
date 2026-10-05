# Universal LUT Preparation

## Goal

Apply LUTs with known color contracts to any RAW already supported by RawLab,
without replacing the target RAW's own sensor calibration. This is not
automatic interpretation of untagged files or camera/Lightroom pixel parity.

## Architecture

Keep the existing RAW and native photo pipelines unchanged. A desktop preparation
tool composes color transforms and a source LUT into the existing F-Gamut/F-Log2
to display-sRGB CUBE contract. Preparation happens once, not per frame. OpenColorIO
reads source LUTs and supplies established camera-log transforms; NumPy evaluates
the canonical bridge and DCP look data. These optional dependencies are not added
to native applications or mobile builds.

The tool is `python -m lutools.lutprep`, with `spaces`, `inspect`, and `prepare`
commands. Generic LUTs require a versioned JSON manifest. An explicit canonical
Fuji-style CUBE can instead pass through byte-for-byte. Untagged files are never
silently assigned sRGB or a camera Log curve.

## Color Contract

- `version` is 1; `input` and `output` each declare `space`, `reference`
  (`scene` or `display`), and `range` (`full` or `legal10`).
- `legal10` means normalized 10-bit codes 64..940, not 0..1. CUBE DOMAIN is
  interpreted by the source reader, separately from this signal-range mapping.
- `interpolation` is `linear` or `tetrahedral` for the source transform; native
  output always uses trilinear interpolation.
- Display input receives RawLab's neutral display rendering before input encoding.
  Scene output receives neutral rendering after output decoding. Scene-to-display
  LUTs receive neither extra curve. Display-to-scene contracts are rejected because
  preparation cannot recover scene radiance from a rendered image.
- Output is SDR display-sRGB. Out-of-gamut display values are clipped, not disguised
  as perceptual gamut mapping. LUT input extrapolation follows the source format.
- Built-in spaces cover F-Log2/F-Gamut, linear sRGB/Rec.2020, sRGB, Rec.709 gamma 2.4,
  Display P3, S-Log3/S-Gamut3(.Cine), ACEScg/ACEScc/ACEScct/ACES2065-1, LogC3/4,
  C-Log2/3, V-Log and RED Log3G10. Custom OCIO configs may name additional spaces,
  with an explicitly named scene-linear-sRGB reference space.
- No white balance, camera matrix, RAW baseline exposure, or image-dependent
  operations are inferred or baked into a generic LUT.

## DCP Boundary

DCP is not treated as an RGB LUT. Inspect identifies calibration, look table,
tone curve and profile exposure separately. The supported subset uses an explicit
D65 ColorMatrix/ForwardMatrix pair to reconstruct a white-relative virtual camera
input from common scene RGB before applying ProfileLookTableData, ProfileToneCurve,
and optional BaselineExposureOffset. Donor matrices never replace the target RAW's
own sensor calibration/WB. Version 1.0 incorrectly discarded these input matrices;
cross-camera tests exposed a blue-to-purple sky shift and version 1.1 corrects it.
Missing/invalid D65 calibration, unimplemented ProfileHueSatMap stages, missing
look/curve data and unsupported encodings are explicit errors. Export metadata
records the adapter, selected tags and exposure choice. The result is an adapted
appearance, not a complete Adobe rendering pipeline. Adobe profile data stays in
local ignored output directories and is not redistributed in the repository.

## Safety And Quality

Python 3.10+, NumPy >=1.26,<3, OpenColorIO >=2.4,<3. No change to the C ABI.
Sources are read-only. Existing destinations are not overwritten without `--force`;
source and destination cannot coincide. All validation precedes atomic replacement.
Generated metadata embeds the manifest, source filename, preparation version and
sampled error report. No private absolute paths are embedded.

Grid sizes 2..129 are supported, default 65. Validation compares the direct
composition against the serialized cube under native trilinear interpolation,
using deterministic full-domain, gray-axis and scene-color samples. It reports
max/mean/p99 display RGB error; this is sampled evidence, not a global bound or a
perceptual/cross-camera accuracy measurement. A maximum error above the configured
tolerance (default 0.02) fails unless `--allow-approximation` is explicit.

## First Delivery And Verification

Deliver the preparation CLI, strict contract, DCP appearance adaptation, tests and usage
examples. macOS and Windows can import prepared CUBE files through existing
pickers. iOS/Android native rendering accepts this contract, but adding their
custom-file pickers and in-app generic color selectors is a separate UI phase.

Tests cover unknown contracts, range/domain ordering, channel order, Log round
trips, scene/display curve placement, serialized cube accuracy, malformed DCPs,
DCP input adaptation, target-calibration separation, passthrough and non-destructive errors. Run prepared
looks through existing native CPU/Metal parity tests on Sony ARW and DJI DNG.
Retain existing CTest color/RAW/GPU coverage. Do not claim Windows/Android hardware
validation from a Mac run.
