# Scene Development Verification

This supersedes the default preview-matching policy in `verification-2026-09-27.md`.

## Implemented

- Default RAW exposure no longer decodes or measures the embedded JPEG. The declared workflow baseline is +0.7 EV plus valid DNG BaselineExposure, not an absolute camera calibration. Sony: +0.7; DJI: +1.05 including its +0.35 metadata.
- Camera/auto/custom white balance now uses LibRaw's WB-before-demosaic order. After its maximum-WB-normalized 16-bit camera-channel demosaic, green normalization is restored in float; the camera matrix, user exposure and F-Log2 path retain negatives and super-whites. Nominal sensor-overrange clipping and integer demosaic precision are not claimed recoverable.
- Neutral output uses a middle-gray-anchored log-logistic display curve. Full-strength Fuji output bypasses that curve entirely. Intermediate strength blends only the two completed display outputs.
- Mac and CLI expose scene, preview-match and sensor exposure modes. Request v2 layout is unchanged; new session APIs choose the mode and report actual base/metadata EV. Cache keys include the mode.
- The Mac inspector shows the selected mode and base EV, separately from user EV.

## Evidence

- Before implementation, tests failed because preview matching was enabled by default and neutral rendering clipped linear 1/2/4 to identical white.
- A separate LibRaw normal-WB/demosaic reference exposed DJI mean RGB error 0.0102231 in the old unbalanced-demosaic path. Both RAW fixtures pass the reference comparison after restoring WB-before-demosaic.
- CTest (with real Metal comparison): 3/3 pass. Coverage includes gray anchor, highlight roll-off, exact direct-LUT reference, half-strength blending, +1 EV linearity, baseline metadata, sensor mode, optional preview matching, source protection and PNG16.
- ASan/UBSan CTest: 3/3 pass.
- Native Mac build and export smoke pass on Sony and DJI, including scene -> preview -> scene cache isolation and JPEG/16-bit PNG export. Last outputs: `/tmp/rawlab-mac-smoke.y3NeRg/`.
- Native UI inspection verified the standard mode, +0.70 base EV / +0.00 user EV, correct 2000x1333 preview and non-overlapping controls in an isolated validation app. The user's old running instance was not reset or closed.
- UI testing found a stack overflow in optional preview extraction: local `LibRaw` exceeded a 512 KiB dispatch-worker stack. Moving it to the heap fixed a dedicated small-stack test (which first failed with Bus error). This is why main-thread headless smoke alone was not sufficient.
- After that fix, native UI testing successfully switched to preview matching (+2.05 EV) and reset back to scene (+0.70 EV), with user EV remaining 0. The isolated validation instance was then closed; the original user's instance was preserved.

## Independent darktable Reference

Official darktable 5.4.0 arm64 was run directly from its DMG, with isolated configuration, cache and database, CPU rendering and sRGB output. No application was installed into Applications; its mount was released, and source RAWs/sidecars were not modified.

Reference JPEGs:

- `/tmp/rawtools-darktable-reference/outputs/DSC09067-darktable.jpg`
- `/tmp/rawtools-darktable-reference/outputs/DJI_20250602164503_0444_D-darktable.jpg`

Logs and manifest: `/tmp/rawtools-darktable-reference/`. Default pipeline enabled exposure, sigmoid, color calibration and the ordinary input/output modules. These actual default renders are not as bright as the embedded camera JPEGs either. They provide a visual reference, not pixel equality: Sony crop differs (7032x4688 versus our active inset 7008x4672), the decoder version differs, and profiles/color-calibration policies differ. No Lightroom internal algorithm was reproduced or claimed.

EXR exports in that directory used a linear Rec.709 output encoding **after sigmoid**. They are display-linear and must not be treated as scene-linear intermediate references. For our linear numeric comparison, the test uses a separately configured LibRaw camera-channel result before output-color conversion instead.

## Limits

The +0.7 workflow boost is explicit and content-independent, not a universal camera calibration. We do not silently remove a photographer's ExposureBiasValue. Camera-specific dynamic-range modes beyond the implemented DNG baseline need explicit metadata support and fixtures. White-point conventions differ slightly from darktable's linear_max-based rawprepare (about 0.095 EV Sony / 0.024 EV DJI), not enough to explain the original multi-stop JPEG difference. Color-chart/gray-card calibration and exact Fuji in-camera equivalence remain unverified. iOS/Android binaries were not rebuilt.
