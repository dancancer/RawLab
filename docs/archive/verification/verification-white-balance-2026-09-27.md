# White Balance and Histogram Verification

## Regression Evidence

- The initial `core_tests` run failed `Increasing temperature warms instead of cooling` and `Positive tint adds magenta instead of green` on the actual FFI pixel path. Both pass after inverse-illuminant compensation replaced direct illuminant multiplication.
- The new RAW Kelvin mode applies camera gains before demosaic, highlight blending, the camera matrix, and the film LUT. Sony ARW and DJI DNG tests cover warm/cool direction, green/magenta direction, cache invalidation, exact as-shot reset, range validation and all four temperature/tint corner gains.
- Custom Kelvin/tint at the inferred as-shot white point preserves each output channel's mean within 0.5% of camera WB. This checks the common LibRaw exposure normalization rather than testing only R/B ratios.
- A synthetic DNG with nonidentity calibration and analog balance validates `AnalogBalance * CameraCalibration * ColorMatrix`, reciprocal-K matrix interpolation and inverse as-shot recovery.
- A new preview-exposure test initially failed after a WB change. The fixed pipeline anchors JPEG-matched exposure to the as-shot decode, and the regression now passes.
- Core CTest: 6/6 passed, including the existing highlight/color/exposure regressions.
- Mac adjustment regression: 8 RAW fixtures passed; artifacts in `/tmp/rawlab-adjustments.dNwqGc`.
- Mac histogram tests: 13 passed, including a 1:100 count ratio, shared channel scaling, neutral triple overlap and CMY pairs.
- Presentation tests cover per-photo as-shot state, custom selection, camera reset, signed ring baseline, and reciprocal Kelvin slider mapping.

## Native UI

In `RawLab WB Preview.app`, loaded `DSC09067.ARW` and verified:

- Default displays 5096 K / tint +17, with `拍摄时设置`, not a universal 6500 K.
- Entering 8500 K changes the mode to `自定义`; the image visibly warms and the filled RGB histogram updates.
- Clicking the temperature reset returns to 5096 K / +17 and `拍摄时设置`.
- Wide-window controls remain readable and the histogram displays filled RGB/CMY/gray overlaps.

Screenshots: `.impeccable/review/mac-wb-as-shot.jpg` and `.impeccable/review/mac-wb-8500.jpg`.

## Boundaries

Kelvin/tint are estimates using LibRaw calibration, not promised to match Lightroom's private camera profile numbers. The histogram counts current sRGB output, not Adobe Develop's internal wide-gamut representation. Existing RAW files are unchanged. White-balance edits currently require a new RAW decode; the subsequent neutral/film render pair reuses that decode. Unsupported calibration leaves camera WB available and disables absolute controls.

Reference: [Adobe white balance and histogram behavior](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html), [Camera Raw parameter ranges](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/), [Adobe DNG SDK](https://www.adobe.com/support/downloads/dng/dng_sdk.html).
