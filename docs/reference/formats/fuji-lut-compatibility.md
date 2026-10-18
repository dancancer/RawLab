# Fujifilm LUT Compatibility

## Scope

Accept the user's GFX ETERNA 55 v1.10 33-grid and GFX100S II v1.00
packs through the shared PHOTO importer and renderer, including their technical
Log-output transforms. Preserve the existing F-Log2 display path, RAW development,
strength blend, C ABI, managed library storage and unrelated workspace changes.

## Color Contract

- Parse input F-Log/F-Log2 with F-Gamut, or F-Log2C with F-Gamut C.
- Require BT.709 output primaries and a nonempty output declaration.
- Named display outputs retain the existing application sRGB interpretation.
- Explicit F-Log/F-Log2/F-Log2C output is scene-referred: decode that curve,
  then apply the existing neutral display rendering in linear BT.709/sRGB.
- F-Log uses its own published curve. F-Log2C reuses F-Log2's curve but
  uses a matrix derived from its published F-Gamut C primaries and D65 white.
- New input contracts and all Log outputs use CPU. Auto falls back honestly;
  Force fails. Existing F-Log2 display GPU behavior remains unchanged.
- `lutprep` distinguishes native compatibility from canonical F-Log2 display
  input. Preparation must not silently relabel or rebake the new contracts.

## Sources

- [F-Log v1.2](https://dl.fujifilm-x.com/technical-data/F-Log_DataSheet_E_Ver.1.2.pdf)
- [F-Log2C v1.0](https://dl.fujifilm-x.com/technical-data/F-Log2C_DataSheet_E_Ver.1.0.pdf)
- Included LUT overviews distinguish black-zero WDR display outputs from
  Log-output gamut conversions that preserve the Log pedestal.

This is compatibility with declared LUT color transforms, not a claim of
camera-specific Fuji JPEG emulation or newly measured sensor calibration.

## Verification

Failing contract/render regressions first; independent curve anchors and gamut
matrix checks; technical output decode, strength and CPU/Auto/Force tests;
existing native/Metal regression suite; Python classification/preparation tests;
all 36 user files through the real managed Mac importer; representative real RAW
render/export checks; rebuild Mac and Android, checking affected client tests.
No commit, publishing or deployment is part of this request.
