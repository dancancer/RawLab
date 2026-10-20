# lutools

These instructions apply to `lutools/`, the C++17 RAW/LUT core and CLI shared by RawLab clients.

## Scope and Completion

- Follow the user's requested scope. Implement requested changes through relevant verification; keep reviews read-only.
- Make routine, reversible implementation decisions without extra approval. Ask when missing information changes the result materially, or an unrequested destructive/publishing action would be needed.
- Preserve existing work and original RAW files. Keep unrelated refactors and generated outputs out of the change.
- Treat skills as task-specific guidance within higher-priority instructions. If a skill blocks the requested work, identify the exact rule rather than silently adding an approval step.
- Finish with the result, checks actually run and any concrete remaining blocker. Do not imply unrun checks passed.

## Read Only Relevant Context

- Rendering or color changes: [color contract](docs/color-contract.md).
- Public interfaces: `include/sony2fuji/`; the shared C ABI is `include/sony2fuji/ffi/sony2fuji_c.h`.
- Mobile integration: [iOS](platform/ios/README.md) or [Android](platform/android/README.md).
- Desktop UI or packaging: [RawLab Mac](../RawLabMac/README.md).
- Do not load every document or re-read unchanged files for a small edit.

## Rendering Constraints

- Preserve the documented linear RAW -> F-Gamut/F-Log2 -> compatible display LUT contract. Do not apply Log-input LUTs directly to display-encoded RGB.
- Apply absolute RAW white balance before demosaic; preserve exposure baselines, highlight handling, active crop and orientation.
- Keep interactive proxies separate from exact rendering and export. GPU Auto must retain CPU fallback; Force must not disguise a GPU failure as success.
- Public C/C++ interfaces are shared across clients. Check affected callers when changing them, and never claim all camera models are calibrated from a few sample files.
- Follow existing C++17 patterns and four-space indentation. Add abstractions only for a concrete benefit, not to meet arbitrary line-count or folder-size limits.

## Verification

Commands below run from the repository root. Local tests use sample inputs and temporary outputs, not production services; run and repair checks affected by the request without asking at each step.

- Core changes: `bash lutools/test.sh`. For a configured Mac build: `ctest --test-dir lutools/build-macos --output-on-failure`.
- RAW/WB/highlight, GPU or C ABI changes: include the relevant real-RAW and CPU/Metal regressions; optional local fixtures may be absent, so distinguish skipped coverage.
- Mac integration: `bash RawLabMac/build.sh`, then the affected checks under `RawLabMac/tests/`. Rendering changes can use `bash RawLabMac/tests/adjustments.sh`; packaging changes use `bash RawLabMac/tests/bundle.sh`.
- Documentation-only changes: check links, examples and formatting; do not rebuild the image pipeline merely for prose.
- After passing checks, repeat only for new changes, failures or a concrete uncovered risk. State when platform tooling or fixtures prevent validation.
