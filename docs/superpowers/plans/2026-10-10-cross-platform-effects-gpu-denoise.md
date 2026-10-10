# Cross-Platform Effects and GPU Denoising Implementation Plan

**Goal:** Synchronize Mac vignette/grain and GPU wavelet/display-chroma filtering to iOS, Android and Windows with matching parameters, processing order and fallback semantics.

**Architecture:** Reuse the shared CPU estimators and numerical reference algorithms. Keep Metal and add bounded GLES/D3D11 filter dispatch with the same db2/guided formulas. Clients send full versioned effects state on every render; existing saved records default to effects off.

**Spec:** The explicit user request in this chat and `lutools/docs/color-contract.md`.

## Constraints

- Worktree: `cross-platform-effects-gpu-denoise`; branch `feature/cross-platform-effects-gpu-denoise`, from `origin/development` at `86ddfe9`.
- Follow root `agent.md` Gitflow. Commits, push, PR, merge and release require explicit user authorization.
- Do not change request v2, RAW decode semantics, denoise parameter meanings or output sizing.
- Effects defaults: vignette 0/50/0/50/0; grain 0/25/50. Vignette amount/roundness -100..100; all other effect values 0..100.
- Wavelet preserves 4/6 levels, periodic SWT, REFLECT_101 energy, original tile/halo layout. Guided filtering preserves BORDER_REFLECT, CPU preblur/Lab/outer filters and resampling.
- Auto falls back; Force fails when a required GPU filter fails. No output is committed before complete success.
- Do not upload private RAW fixtures, UI screenshots or build outputs.

## Tasks

1. GPU filter interface and regressions
   - Add `gpu/denoise.h` and platform-neutral dispatch; retain the existing Metal interface for current callers.
   - Extend `metal_denoise_tests.cpp` to exercise `gpuWaveletFilter` and `gpuGuidedFilter`, with wavelib/OpenCV reference comparisons and untouched-output failure checks.
   - Run the baseline tests and prove unsupported backends fail the new GPU assertions before implementing their kernels.
2. GLES/D3D11 filters
   - Add `gpu/compute_denoise.h/.cpp`, a common scalar shader body, and `gles_denoise.cpp` / `d3d11_denoise.cpp`.
   - Use individual wavelet band buffers rather than a single 19-plane SSBO; serialize tile jobs and split dispatches at device limits.
   - Port db2 forward/inverse, box energy and threshold, guide moments/means/covariance/coefficients/reconstruction. Validate parameters and finite output before copying.
   - Include sources in platform CMake builds and run GPU numerical tests where platform tooling is available.
3. Photo pipeline and effects
   - Generalize internal denoiser dispatch to the selected native backend.
   - Enable denoise/effects in GLES/D3D11 FFI gating; preserve wavelet cache execution mode and immutable RAW uploads.
   - Keep source-resolution tone output for chroma; read back for unchanged CPU preparation plus GPU guided filtering, then resume GPU detail/effects and final resize.
   - Test CPU/backend pixels with zero/extreme effects, wavelet/chroma combinations, interactive/exact requests and output export.
4. iOS client
   - Extend `RawSettings`, `AdjustmentKind`, processor setters and native controls with canonical effects state; default old JSON to off.
   - Use Auto by default, handle setter errors, enable chroma dependency/Metal build and retain injectable Force/Off for tests.
   - Test settings/reset/persistence/batch, build framework/app and run simulator rendering checks.
5. Android client
   - Extend `EditSettings`, persistence/batch codecs, tool controls and JNI request/config with all eight effects values.
   - Enable chroma dependency and GLES GPU filters without changing request v2.
   - Run JVM/native/device tests and capture the actual native controls for UI verification.
6. Windows client
   - Add effects snapshot/native config and controls, and include effects in preview cache keys and batch summaries.
   - Enable chroma native dependency and D3D11 GPU filtering.
   - Run portable settings tests, remote native/WPF builds and actual D3D tests when a hardware adapter is available; otherwise report the hardware gate separately.
7. Delivery verification
   - Run relevant full core tests plus client settings/persistence/batch and real RAW export comparisons.
   - Inspect each native UI once, repair concrete layout defects and confirm at most once.
   - Update platform docs and shared rendering contract with actual validated capabilities and unverified hardware limits.

## GPU Interfaces

```cpp
bool gpuWaveletFilter(const float* input, int width, int height,
                     const WaveletFilterSettings& settings, float* output);
bool gpuGuidedFilter(const float* guide, const float* input, int width, int height,
                     int radius, float epsilon, float* output);
```

Both return false without modifying output on validation, allocation, dispatch or numerical failure. Direct core denoisers retain CPU defaults; native photo sessions request the appropriate backend through the existing GPU mode.

## Execution Status

Implementation and platform build/render gates are complete, including actual
Windows D3D11 execution and unlocked-device Android controls instrumentation.
Exact results and remaining screenshot/desktop/physical-device scopes are recorded in
[the verification report](../../verification-cross-platform-effects-gpu-denoise-2026-10-10.md).
