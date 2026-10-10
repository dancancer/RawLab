# macOS AI Color Match Verification

Date: 2026-10-09. Branch: `codex/macos-ai-color-match`.

## Status

Implemented in the current working tree and built as `build/RawLab Mac.app`.
No commit, push or release was performed. Other work already present in this
checkout, including edit persistence, batch export and denoising, was preserved.

Automated integration and native rendering checks pass. Native window/picker
acceptance is **NOT REACHED** because the Mac is locked. Actual photographic
reference-match quality is **NOT TESTED**: live requests used synthetic patches,
not private RAW photographs or reference photographs.

## Implemented Scope

- Current RAW plus 1-6 raster references; source preparation preserves input
  exposure, white balance and detail settings, and resets output tone/color.
- User-configured HTTPS service and model; default DeepSeek `deepseek-flash`;
  address-isolated Keychain storage. The application does not read `.env`.
- Bounded, oriented, ICC-converted sRGB JPEG uploads without source paths or
  capture metadata; strict recipe validation, finite response limits,
  cancellation, no automatic inference retry and no authenticated redirects.
- Local deterministic version-1 recipe compiler; 65-grid then at most 129-grid;
  native-parser round-trip maximum sampled channel error must be <= 0.02.
- Explicit display-sRGB CUBE input after the existing precise neutral render,
  supported by CPU and Metal. Existing Log CUBE and DCP paths remain separate.
  GLES/D3D11 reject the new GPU type, allowing Auto CPU fallback and Force errors.
- Candidate comparison, 0-200% strength, follow-up requests, conditional apply,
  managed-look persistence and restoration of the complete pre-AI edit.
- Sanitized CUBE export and native file-share provider for both candidates and
  saved AI looks. Export preserves the 100% table and color contract, not the
  current strength, RAW development or output/detail controls.

## Automated Evidence

| Check | Result |
| --- | --- |
| `bash RawLabMac/build.sh` | PASS; Swift app, native core, bundled dependencies and ad-hoc signatures |
| `ctest --test-dir lutools/build-macos --output-on-failure` | PASS, 19/19 after the final build (63.60 seconds); includes `color_recipe`, `srgb_look`, existing color/GPU/RAW checks |
| `bash RawLabMac/tests/ai-data.sh` | PASS; recipe validation, HTTPS, upload resize/color/metadata/orientation, mock API success/errors, bounded streaming, no retry and cancellation |
| `bash RawLabMac/tests/ai-workflow.sh lutools/examples/DSC06251.ARW` | PASS; real Sony RAW, mock HTTP, compile/render, preparation/reference/generation cancellation, strength, apply/restore, persistent managed look, stale-edit rejection |
| Workflow export/share checks | PASS; header sanitization, no-key reimport, RAW and hard-link protection, overwrite policy, real `NSItemProvider` file representation |
| `bash RawLabMac/tests/ai-live.sh` | PASS; explicit `.env` developer test with one and two synthetic references |
| `bash RawLabMac/tests/ai-render.sh <DJI DNG> <live reference-2.cube>` | PASS; actual Metal backend, strength 0/1/2, CPU/Metal max 1 DN, full 3072x3072 JPEG and 16-bit PNG, single/batch pixels identical, RAW identity unchanged |
| Native `acceleration_tests` with live CUBEs and Sony/DJI RAWs | PASS; actual Metal, max 1 DN |
| `bash RawLabMac/tests/adjustments.sh` | PASS; seven real RAW fixtures and existing input/detail/output adjustment regressions |
| `edit-memory.sh`, `edit-model.sh`, `look-library.sh`, `look-import-model.sh` | PASS; related persistence/library regressions |
| `git diff --check` | PASS |

The Android fallback test was syntax-checked locally; Android/Windows device
execution and iOS delivery are outside this macOS implementation. No claim is
made that those applications have acquired the new UI or rebuilt native core.

## Live DeepSeek Results

Only artificial color-patch source/reference images were uploaded. The configured
model was `deepseek-flash`; each case made one explicit generation request.

| References | Grid | Max Sampled Error | p99 Sampled Error | Recorded Elapsed Seconds |
| --- | --- | --- | --- | --- |
| 1 | 65 | 0.00383559 | 0.00046258 | 2.704 |
| 2 | 65 | 0.00333131 | 0.00023949 | 3.221 |

Local artifacts: `output/ai-color-match-live/DE5BF666-14EE-40E0-AD7B-ABF3E11F91EE/`.
This ignored directory contains synthetic images, validated recipes, CUBEs and
reports, not credentials. Timings are observations, not latency guarantees.
Errors measure the recipe-to-CUBE approximation, not visual matching quality.

The earlier attempt to bake neutral development into a Log CUBE failed its
unchanged 0.02 gate. The user approved the display-sRGB runtime revision rather
than loosening that gate. Evidence remains in
[the initial bake report](verification-ai-lut-bake-2026-10-09.md).

## Review And Remaining Gates

Independent read-only reviews covered the compiler/runtime contract and Swift
data/edit integration. The final review found that preparation/reference loading
discarded stale results without cancelling queued local work. Both stages now
share an explicit thread-safe cancellation token with the worker. Regression
tests cover stop/retry and retaining the previous validated candidate. Synchronous
LibRaw/ImageIO calls already in progress cannot be preempted; their results are
discarded and later queued stages are skipped. Cancel does not promise remote
billing cessation.

Still required before claiming complete visual acceptance:

- Unlock the Mac and check minimum 950x620 and normal-size windows, long names,
  loading/error states, settings, apply/restore and native save/share cancellation.
- Check actual Keychain prompts and system sharing-service availability through
  the application. The file provider is tested, but no recipient delivery occurred.
- Use explicitly authorized real reference photographs for single/multiple
  reference comparison, including skin, grays, highlights and gradients.

The strict compiler may reject a numerically valid but steep recipe even at
129-grid. This is deliberate; no candidate is installed when the measured gate
fails. LUTs cannot reproduce spatial lighting, local semantic masks or texture.
