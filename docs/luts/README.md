# Bundled RawLab Looks

Status: private local validation on 2026-10-16. The 28 third-party derivatives
are technically integrated, but redistribution permission remains UNCONFIRMED.
Do not push or distribute these files or an app containing them until the
per-source license review is resolved. Color adaptation is not license clearance.

## Inventory and Identity

The shared source is [Shared/BundledLooks](../../Shared/BundledLooks/).
[catalog.json](../../Shared/BundledLooks/catalog.json) owns names, filenames,
artwork mappings, SHA-256 hashes and color contracts. There are 29 additions:
28 adapted local source files plus the previously authored Ektar v2. Existing
Fuji effects and master recipes are unchanged.

| Picker Name | Catalog ID / Filename Stem |
| --- | --- |
| EKTAR 100 RawLab edition | `EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65` |
| Contax ND STD | `RawLab_camera_contax_nd_std_sRGB_v1` |
| Lumix S1R Vivid | `RawLab_camera_lumix_s1r_vivid_sRGB_v1` |
| Pentax K-5 Reversal | `RawLab_camera_pentax_k5_reversal_sRGB_v1` |
| Ricoh GR II Hi-BW | `RawLab_camera_ricoh_gr2_hibw_sRGB_v1` |
| Ricoh GR II Vivid | `RawLab_camera_ricoh_gr2_vivid_sRGB_v1` |
| Kodak 2383 RGB | `RawLab_look_2383_sRGB_v1` |
| Kodak 2393 RGB | `RawLab_look_2393_sRGB_v1` |
| Kodak BW 400 CN | `RawLab_look_bw_400_cn_sRGB_v1` |
| Kodak E100 GX | `RawLab_look_e100_gx_sRGB_v1` |
| Kodak Ektachrome 100 VS | `RawLab_look_ektachrome_100_vs_sRGB_v1` |
| Ektar 100 G'MIC | `RawLab_look_ektar_100_sRGB_v1` |
| Kodak Elite 100 XPRO | `RawLab_look_elite_100_xpro_sRGB_v1` |
| Kodak Elite Chrome 200 | `RawLab_look_elite_chrome_200_sRGB_v1` |
| Kodak Elite Chrome 400 | `RawLab_look_elite_chrome_400_sRGB_v1` |
| Kodak Elite Color 200 | `RawLab_look_elite_color_200_sRGB_v1` |
| Kodak Elite Color 400 | `RawLab_look_elite_color_400_sRGB_v1` |
| Kodak Elite Extra 100 | `RawLab_look_elite_extracolor_100_sRGB_v1` |
| Kodak HIE Infrared | `RawLab_look_hie_sRGB_v1` |
| Kodak Kodachrome 200 | `RawLab_look_kodachrome_200_sRGB_v1` |
| Kodak Kodachrome 25 | `RawLab_look_kodachrome_25_sRGB_v1` |
| Kodak Kodachrome 64 | `RawLab_look_kodachrome_64_sRGB_v1` |
| Kodak Portra 160 | `RawLab_look_portra_160_sRGB_v1` |
| Kodak Portra 400 | `RawLab_look_portra_400_sRGB_v1` |
| Kodak Portra 800 | `RawLab_look_portra_800_sRGB_v1` |
| Kodak T-MAX 100 | `RawLab_look_tmax_100_sRGB_v1` |
| Kodak T-MAX 400 | `RawLab_look_tmax_400_sRGB_v1` |
| Kodak T-MAX 3200 | `RawLab_look_tmax_3200_sRGB_v1` |
| Kodak TRI-X 400 | `RawLab_look_trix_400_sRGB_v1` |

Names are stock/camera identifiers, not new UI sentences, and remain the same
in the six supported languages. `Ektar 100 G'MIC` and `EKTAR 100 RawLab edition`
are different tables with different identities and artwork. The latter was
previously displayed as `EKTAR 100 Phuket v2 Strong`; only its display name was
changed. Its original file, ID, artwork and saved-photo compatibility remain.

Catalog IDs equal filename stems. iOS/Android use those IDs in their existing
edit stores. Mac/Windows retain their established `builtin:<filename>` identity;
Agent recipes retain resolved file references, and batch jobs freeze LUT copies.
This addition does not migrate existing edit or recipe serialization formats.

## Color Adaptation

The [source audit](source-audit-2026-10-16.json) records all 28 originals without
modifying them: 5 camera tables at 33 cubed and 23 G'MIC tables at 13 cubed,
complete finite rows, no duplicate files/tables. All values are in 0..1. Missing
domain declarations are reported as missing rather than invented metadata.
Original file hashes are checked before every adaptation.

Every new derivative explicitly declares:

```text
#Gamma:sRGB to sRGB
#Gamut:ITU-R BT.709 to ITU-R BT.709
```

The core already accepts this native display-look contract: neutral display-sRGB
is produced once, then the LUT is applied. No new core/C ABI, extra display
curve, camera matrix, OS target or GPU implementation is introduced. See the
[color contract](../../lutools/docs/color-contract.md) for backend behavior;
unsupported GPU paths preserve Auto CPU fallback and do not pretend Force ran
on a GPU.

### Five Camera Looks

The [author's public share](https://www.reddit.com/r/Lumix/comments/1tgii1i/reverseengineering_camera_color_pipelines_instead/)
and [Drive folder](https://drive.google.com/drive/folders/1P6xJW2-x8pFAm6hP8vNdlDe11Pb06DId)
identify the camera files. Their bytes match the supplied local files. The
author's wording, "sRGB / Rec709, gamma 2.4", is not complete CUBE metadata.
RawLab explicitly chooses display BT.709/D65, full range, ideal black-zero
gamma 2.4 on both input and output. This is an interpretation of that statement,
not measured camera calibration, a scene-referred transform, or manufacturer
certification. Gamma 2.4 here is not the Rec.709 camera OETF or the sRGB transfer.

The baked adapter is:

```text
RawLab neutral display-sRGB
 -> sRGB decode -> gamma 2.4 encode
 -> original CUBE (OCIO linear interpolation)
 -> gamma 2.4 decode -> sRGB encode
 -> display-sRGB
```

The primaries are identical; no unnecessary XYZ matrix round trip is applied.
An identity-table regression verifies there is no additional display curve.
The adapter tries 33 then 65 cubed with deterministic sampling. Thresholds are
maximum channel error <= 0.025 and p99 <= 0.002 over 14,130 RGB samples, not
a proof of a global error bound or visual equivalence to a camera.

| Look | Output Grid | Sampled Max | Sampled P99 |
| --- | ---: | ---: | ---: |
| Contax ND STD | 65 | 0.002502 | 0.000831 |
| Lumix S1R Vivid | 33 | 0.007332 | 0.001761 |
| Pentax K-5 Reversal | 33 | 0.017153 | 0.001889 |
| Ricoh GR II Hi-BW | 65 | 0.021021 | 0.000838 |
| Ricoh GR II Vivid | 65 | 0.013879 | 0.001968 |

### Twenty-Three G'MIC RGB Looks

The local files match [Film-Luts](https://github.com/YahiaAngelo/Film-Luts) at
`af957b631a304e6be94778b96cb3395de3438e9f`, not the current G'MIC download bytes.
Their original transfer/gamut semantics remain unknown. G'MIC documents ordinary
sRGB-image use and applies `map_clut` directly to RGB data; its CUBE exporter
normalizes 0..255 to 0..1 without declaring a transfer. See the inspected
[official source snapshot](https://github.com/GreycLab/gmic/blob/c79f54dfb9a7486e6bc668263f50e14ef133894c/src/gmic_stdlib.gmic),
especially `fx_simulate_film`, `map_clut` and `output_cube`.

RawLab therefore defines a NEW display-sRGB creative RGB interpretation of
these numeric tables, following that direct-image use. The source payload is
preserved byte-for-byte, with an explicit RawLab header/provenance added. No
invented Cineon, LogC or film-scanner bridge is baked into undocumented tables.
This makes their use in RawLab explicit; it does not recover their original
authoring contract or establish accurate film emulation.

In particular, [Juan Melara's original PFE instructions](https://juanmelara.com.au/blog/print-film-emulation-luts-for-download)
describe Log film-scan input. The G'MIC snapshot does not prove how its internal
2383/2393 tables were derived. Picker names `Kodak 2383 RGB` and `Kodak 2393 RGB`
intentionally do NOT claim to be the original Log-input PFE transforms.

### Existing Ektar v2

The independently authored Ektar v2 is copied without conversion from the prior
generated output. SHA-256:
`5ddd5c15d8e3ffcebf17c8203a61701d736bbbf7d8d404b4f986e1872fa8cea4`.
Its F-Log2/F-Gamut input and display-sRGB output are unchanged. Regenerating
[generate.py](../../experiments/ektar100-phuket-v2/generate.py) reproduces it
byte-for-byte. Its existing `ektar-100-phuket.png` and provenance are reused
from the original Mac resources, not duplicated or replaced.

## Artwork and Packaging

The 28 new 256x256 bitmap illustrations live once in the shared `Artwork/`
directory. They are original image_gen concept labels, not official packaging,
endorsement or LUT-rendered samples. Prompts, original output paths and hashes
are retained in `Artwork/generated-*.json`. The existing Ektar icon is the
intentional old-resource exception, referenced from its existing source.

Mac packages CUBEs under `LUTs`, catalog/artwork in app resources; iOS packages
the `BundledLooks` folder reference and separately reuses the old Ektar artwork.
Android packages `films`, `artwork` and `bundled-looks.json`; Windows uses the
same catalog and sources through its project resource items. Each packages the
permanent [NOTICE.md](../../Shared/BundledLooks/NOTICE.md).

Only the new picker entries receive wider two-line name layouts. Existing
horizontal picker behavior, legacy widths and custom-look artwork behavior
are preserved. iOS reserves 34 scaled caption points for new two-line labels;
native UIFont measurement found that 30 points clipped a 32-point caption.

The Mac film picker remains one flat horizontal list, ordered Fujifilm, Kodak,
then Other, with vertical dividers between groups and no tabs or filtering.
The 10 legacy Fuji looks stay together; Kodak contains 23 G'MIC looks plus
Ektar v2; the 5 camera looks and every imported look follow in Other. Neutral
and import remain common actions. Grouping does not change selected LUTs or IDs.

## Reproduction

Run from the repository root. Keep source and output trees disjoint. These
commands write only temporary outputs, not the original LUT directory:

```bash
python3 -m venv /tmp/rawlab-lutprep-env
/tmp/rawlab-lutprep-env/bin/python -m pip install -r lutools/requirements-lutprep.txt
python3 Shared/audit-lut-sources.py /absolute/path/to/original/luts > /tmp/rawlab-source-audit.json
cmp docs/luts/source-audit-2026-10-16.json /tmp/rawlab-source-audit.json
/tmp/rawlab-lutprep-env/bin/python Shared/prepare-bundled-looks.py /absolute/path/to/original/luts /tmp/rawlab-adapted-looks
python3 experiments/ektar100-phuket-v2/generate.py --output /tmp/rawlab-ektar-v2.cube
cmp Shared/BundledLooks/EKTAR_100_Phuket_v2_Strong_FLog2_FGamut_65.cube /tmp/rawlab-ektar-v2.cube
/tmp/rawlab-lutprep-env/bin/python -m unittest Shared/tests/test_bundled_looks.py Shared/tests/test_lut_source_audit.py Shared/tests/test_prepare_bundled_looks.py -v
```

The adapter emits the 28 derivatives and their report/catalog; the retained
Ektar entry in that catalog refers to the separately maintained Ektar file.
Generation used NumPy 2.5.4 and OpenColorIO 2.6.0. Dependency version changes
require comparing actual output and error metrics, not assuming byte identity.
`--force` is required to replace generated derivatives; it is not a release flag.

## Verification and Limits

Verified locally on this branch:

- Shared audit/catalog/adapter tests, including source-tree write prevention,
  native sRGB identity behavior, resource uniqueness, PNG decode structure and
  content hashes. All originals remain unchanged after generation.
- Mac private app build, bundle resource byte equality and signatures, native
  name/artwork presentation, and actual picker inspection with Ektar, Ricoh
  Hi-BW and Kodak 2383 RGB. The user's pre-existing custom looks remain present.
- All 29 looks at strength 0/100/200% on a real Sony RAW: CPU versus forced
  Metal differs by at most 2 DN in the 8-bit comparison; zero is exactly neutral.
- Ektar v2, Contax and 2383 RGB: Agent/direct FINAL and exact preview agree as
  decoded 16-bit PNG pixels; frozen batch output agrees; built-in edit identity
  persists. The source RAW identity is unchanged.
- Existing shared-core CTest: 36/36 passed. No core implementation was changed.
- Android Debug unit tests and generated assets; per-file equality of all 29
  CUBEs, mapped artwork, catalog and NOTICE against the prepared asset output.
- iOS Foundation presentation tests and actual UI-source typecheck. A minimal
  Xcode native resource bundle using the same folder-reference form was built;
  iPhone/iPad simulator UIKit checks decoded all 29 icons, checked CUBE hashes
  and measured every default caption within the reserved two-line height.
  This was not a full RawLab iOS app build or screen-level test.
- Release blockers were checked for Mac and Android; iOS PBX and Windows XML
  configurations were inspected. No Release/public artifact was produced.

The generic LUT validator accepts all 29 files in non-strict mode, but reports
real artistic quality warnings: camera-table interior clipping is 4.89% Lumix,
7.39% Pentax, 23.06% Ricoh Hi-BW and 11.19% Ricoh Vivid. Elite Chrome 200 is
1.23%. It also reports luminance reversals for Ektar v2 (8807), 2383 (51), 2393
(36), E100 GX (62), Elite Color 400 (40), HIE (140), Kodachrome 25 (48), and
neutral-axis drift 0.2284 for Elite 100 XPRO. These warnings are not erased by
adding metadata. Strong clipping/BW effects are not retuned as calibration LUTs.

A second synthetic linear-DNG run reached the LUT preview comparisons but its
Agent/full-resolution step failed `unreadableSource`; it is not counted as a
successful full-workflow fixture. The real Sony RAW workflow above passed.
The broader localization suite has two pre-existing baseline source-coverage
failures (Android `output_destination`, Apple crop hint); this change adds no
new translatable UI key and does not silently fix those unrelated issues.

Not verified: full iOS/Android app/native builds, mobile device/GLES runs,
Windows build/D3D11 (no local .NET toolchain), macOS 14 hardware, CI, every
dynamic-type size, or global camera/film fidelity. Do not infer those results
from shared table/resource tests.

## Redistribution Gate

The camera author's public sharing and credits are not treated as an explicit
redistribution grant. Film-Luts' MIT text is not treated as permission from the
underlying LUT authors; G'MIC software licensing is not automatically a license
for every contributed preset. [G'MIC credits](https://gmic.eu/color_presets/),
[Pat David's article](https://patdavid.net/2013/08/film-emulation-presets-in-gmic-gimp/)
and the PFE page are evidence leads, not a completed per-file license review.

While [REDISTRIBUTION_BLOCKED.md](../../Shared/BundledLooks/REDISTRIBUTION_BLOCKED.md)
exists, iOS/Android/Windows Release and the default Mac package command reject
the bundled candidates. Explicit Mac private validation is available with
`RAWLAB_ALLOW_UNCLEARED_LUTS=1 bash RawLabMac/build.sh`; setting Release still
rejects. Use explicit Android Debug tasks, not `build` or `assemble` aggregates.
These are ordinary build guards, not authorization to distribute Debug outputs.

Before clearing the gate, record permission for each source (including derivative
redistribution), retain required author/license notices, update catalog and
reports together, and re-check packaging. Remove only the temporary marker;
keep the permanent NOTICE. Ektar v2 remains a separate project-authored look.
