# Cross-Platform Denoise Implementation Plan

**Goal:** Bring the approved Mac denoise controls and interaction fixes to macOS,
Windows, iOS and Android, then merge a reviewed PR into a new development branch
created from main.

**Architecture:** Keep one additive C ABI and the tested linear db2 SWT pipeline.
Each native client owns its controls and fixed original preview. Interactive
proxies never become export input, and proxy replacement never resets the viewport.

**Scope:** The existing Mac implementation and the user's cross-platform delivery
request are the specification. Do not include pending AI color-match, batch-export,
or persistent-edit features from the original checkout. Preserve main's camera
compatibility and version metadata. No release upload is requested.

## Shared Core and macOS
- [x] Port only denoise core, optimized wavelib patches and related regressions.
- [x] Provide pinned OpenCV core/imgproc and wavelib target builds for cross-compilers;
      retain the Mac legacy chroma path without requiring it on new clients.
- [x] Port Mac controls, fixed-original cache and source-sized proxy presentation.
- [x] Run core CTest, Mac settings/viewport/model/RAW-export regressions and app build.

## Native Clients
- [x] Add failing settings and request-mapping tests on each platform: Off by default,
      detail 0/46/50, clean 10/72/100, finite 0..100 values, disable preserves values,
      reset disables, and same settings feed exact preview and export.
- [x] Connect each client's native render session to the additive wavelet config.
- [x] Add native switch, preset selector, three numeric controls and reset actions.
- [x] Keep original rendering independent of adjustments and preserve zoom/pan across
      reduced/full-resolution frame replacement. Test the state and geometry.
- [x] Build Android JNI/APK and run unit/lint/device tests where available.
- [x] Build iOS device/simulator framework and app, run host/simulator tests.
- [x] Build Windows WPF/native targets using the existing verified build environment;
      distinguish hardware-GPU tests from CPU/VM coverage.

## Delivery
- [x] Review the exact feature diff against origin/main and run affected gates.
- [ ] Commit only feature-owned paths and push codex/cross-platform-denoise.
- [ ] Refresh main, create development at that exact commit without overwriting refs.
- [ ] Create and attach the PR targeting development; check exact-head CI/review.
- [ ] Merge the PR without bypassing required checks, verify remote development HEAD.
- [ ] Report PR, commits, tested platforms and any concrete runtime limitations.
