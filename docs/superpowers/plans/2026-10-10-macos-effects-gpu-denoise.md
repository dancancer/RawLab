# macOS Effects and GPU Denoising

**Goal:** Move the vignette/grain work onto a branch based on development and add Metal acceleration to the existing wavelet and display-chroma denoisers.

**Architecture:** Keep the existing noise estimators, color conversions, tile boundaries and parameter contracts. Accelerate the dominant per-tile SWT/threshold/inverse and three-channel guided-filter operations with Metal. CPU calibration is not relabeled as GPU work. Auto may fall back; Force must fail if a required GPU filter fails. Preserve the existing CPU implementations as numerical references.

**Spec:** `lutools/docs/color-contract.md`, the existing wavelet/chroma code, and the user's request in this chat.

## Constraints

- Base: `origin/development` at `c3a2e4c`; branch `codex/macos-effects-gpu-denoise`.
- Mac only; preserve development's separate wavelet/chroma build flags and other clients.
- No AI-color-match, batch-export or unrelated RAW changes in the migration.
- No change to request v2 or existing saved denoise/effects parameters.
- Keep the patched db2 SWT phase convention and original tile/halo dimensions.
- Do not replace OpenCV's Lab conversion or resize conventions with approximate alternatives.

## Work

1. Migrate only effects files/hunks and their tests, adapting tests to development's APIs. Build and run the existing effects regressions before further changes.
2. Add `gpu/metal_denoise.h` with two bounded operations: a contiguous float wavelet-plane filter (4/6 levels, 18 sigmas and six threshold strengths), and a packed float3-guide/float2-source guided filter. Outputs are committed only on success. Add CPU-reference tests using wavelib and OpenCV before implementing kernels.
3. Implement db2 analysis and transpose synthesis, source-level band normalization, REFLECT_101 box energy and soft thresholds. Serialize bounded tile jobs to avoid unbounded coefficient-buffer allocation. Test zero-threshold reconstruction, modified bands, 4/6 levels and nontrivial boundaries against wavelib.
4. Implement guided-filter moments, covariance inverse, alpha/beta and reconstruction with BORDER_REFLECT. Keep guide preblur, Lab conversion, profile estimation and coarse resizing in the established CPU driver. Test constant/ramp/noisy guides, radius 4/8, tiny and tile-sized inputs against OpenCV.
5. Pass an internal GPU mode into both denoisers. Preserve CPU defaults for existing direct callers; Auto falls back and Force reports processing failure. Track actual GPU filter execution in internal diagnostics. Verify whole-denoiser CPU/Metal error and noise reduction, including off/no-estimate cases.
6. Integrate wavelet preprocessing before the photo Metal pipeline, key its cache by execution mode, and split tone/detail Metal dispatch around display-chroma processing. Ensure fallback never filters twice, never modifies the immutable RAW cache, and never exports a failed partial result.
7. Run synthetic denoiser regressions, full core tests, real RAW CPU/Metal/effects/export checks, and the Mac build. Record measured tolerances/performance rather than claiming a fully GPU-only decoder or estimator.
8. Review the scoped diff. Remove only the migrated effects changes from the original working directory after verifying the destination, retaining a reversible local patch and preserving unrelated work.

## Verification Commands

```sh
bash RawLabMac/build.sh
ctest --test-dir lutools/build-macos --output-on-failure
bash RawLabMac/tests/presentation.sh
bash RawLabMac/tests/photo-effects-render.sh /path/to/sample.ARW
```

New low-level and integrated Metal denoise tests will be registered with CTest. A passing test must assert numerical agreement and actual GPU execution; backend labels alone are insufficient.
