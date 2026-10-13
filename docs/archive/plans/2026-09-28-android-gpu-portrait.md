# Android GPU and Portrait Editor

User approved the existing editor's full pixel-stage GPU acceleration and a
portrait-first UI on 2026-09-28. Continue in `codex/android-client`.

## Implementation Contract

- OpenGL ES 3.1 compute, with per-session context/resources. Preserve the
  shared C ABI request layout and color order. Add a GLES backend enum value.
- RAW unpacking, camera-space WB/demosaic and file encoding stay on CPU.
  GPU performs linear preview resizing, matrices/exposure, neutral mapping,
  F-Log2/LUT/strength, and pointwise tone controls. Unexposed neighborhood
  detail filters fall back to CPU in Auto; Force reports unsupported work.
- Stream source row bands within queried SSBO/workgroup limits instead of
  allocating a full-resolution GPU buffer. Cache one reduced linear preview
  per session, keyed by the actual RAW decode key (including WB and quality).
  Export always renders from native RAW data, not the preview cache.
- Restore previous EGL bindings on every call; release session contexts,
  textures and buffers. Failed GPU output must never overwrite CPU source.
- Default Auto, optional CPU in the editor menu. Report actual backend and
  completed render time, not the user's preference as proof of GPU execution.
- Portrait: large single photo with draggable before/after wipe; a compact,
  collapsible bottom panel with fixed-height tool row. Separate temperature
  and tint tools so both avoid hidden second sliders. Numeric edit/reset and
  as-shot reset remain available; preserve edits when collapsing/rotating.
- Use real-device screenshots at portrait phone-sized and tablet-sized
  windows, light/dark and enlarged text. Restore changed device settings.
- Test only repository fixtures and owned temporary directories on the
  authorized TB320FC; do not read other media or remove unrelated apps/data.

## Tasks

- [x] Native regressions: build a standalone Android test executable; first
  prove Force cannot report GLES on the CPU build. Add synthetic CPU/GLES
  comparisons, RAW/WB/proxy/exact cache checks, full-size exports, thread
  rebinding, Auto fallback/Force failure, and timed warm-render samples.
- [x] GLES implementation: `lutools/src/gpu/gles_photo.{h,cpp}` plus shader;
  wire the C API, CMake and backend diagnostics without changing Metal math.
- [x] Android integration: GPU mode in NativeProcessor/JNI, actual backend
  and duration in preview state; lifecycle-safe rendering remains serial.
- [x] Portrait UI: refine EditorScreen's canvas/tool dock and compact menu;
  add Compose regression coverage for wipe, collapse and visible WB tools.
- [x] Verify: dual-ABI builds, JVM/Compose tests, native device regression and
  benchmark, desktop C++/Metal regression, screenshots and native alignment.
  Document measured results and limitations; commit locally, no remote push.

## Evidence

Run `bash lutools/test.sh`, Android Gradle unit/lint/APK gates, and the native
test runner on device with GPU Force plus actual backend assertions. Compare
quantized previews within 2 DN and record maximum/RMS errors, not just hashes.
Warm benchmarks measure complete native render calls with identical settings;
separate first-load/demosaic from repeated edits and full-size file encoding.

Completed evidence is recorded in `RawLabAndroid/gpu-verification.md`: actual
Adreno GLES execution, 6.48x warm single-preview speedup, max 1 DN RAW parity,
and native portrait screenshots with compact/enlarged-text coverage.
