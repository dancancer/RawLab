# Shared DCP Import

## Scope

Move the verified Mac DCP compiler into the existing C++17 shared core. Mac,
iOS, Android and Windows call the same compiler and retain only platform file
selection, durable library storage and localized error presentation. Python is
a development-only differential oracle, never an application dependency.

The branch `feature/shared-dcp-import` starts at `f59d7f9` from Mac PR #82.
That PR targets `development` and is an explicit integration dependency; this
branch does not merge or publish it. The target's current changes must be
integrated and rechecked before delivery.

## Ownership And Steps

1. Shared core owner: bounded TIFF parser, D65 adapter, tone/table conversion,
   RLOOK serialization, typed failure reasons and exception-safe blob C ABI.
2. Root: shared Swift adapter/library, Mac migration, Python differential tests,
   integration checks and verification report.
3. Platform owners: Android JNI/import, Windows P/Invoke/import and iOS custom
   look library/UI. No platform may carry a separate conversion implementation.
4. Localization owner: shared six-language keys and generated client resources.

## Compatibility

- Preserve RLOOK v1/v2, existing C ABI layouts and all renderer behavior.
- Preserve Mac's strict automatic-import policy: one valid D65 calibration,
  explicit embedded tone curve and `DefaultBlackRender=None`.
- Preserve source/output/cell/tone/metadata bounds and the total Rational
  decoding budget; reject unsupported profile stages explicitly.
- A rejected import must not replace the current selection or leave a partial
  managed look/catalog entry.
- GPU Auto/Force contracts are unchanged; importing does not need a RAW or GPU.

## Verification

- Run shared compiler unit/ABI regressions, including malformed input, rank and
  Rational-budget cases, and Python differential tests on synthetic profiles.
- Run existing Mac compiler/library/model regressions after migration.
- Build the Mac app and iOS simulator app; run affected Android and Windows
  tests/builds where toolchains exist. Distinguish unavailable hardware/runtime
  checks from passing local compilation.
- Ensure CI executes shared compiler regressions on desktop platforms and keeps
  the three Mac behavioral scripts plus required synthetic Python parity.
- Check six-language generation, formatting, source diff and temporary files.
