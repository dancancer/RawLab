# Mac DCP Import Implementation Plan

**Goal:** Import supported DCP files on Mac, compile them to managed RLOOK files without Python, and report unsupported configurations precisely.

**Spec:** User-approved scope in this chat: Mac first; automatic DCP-to-RLOOK conversion and library installation; no user-installed Python; explicit unsupported-profile errors; start from `origin/development` in a worktree. Other clients, publication and merging are out of scope.

**Architecture:** A Mac-only Swift compiler uses Foundation and simd to implement the existing D65 adaptation and RLOOK v1/v2 contracts, with system Accelerate SVD for numerical rank validation. Existing native rendering and the shared ABI remain unchanged. LookLibrary compiles on its existing background queue and uses its current staging, validation and registry rollback. Python is only an independent implementation used in development tests.

## Constraints And Decisions

- Preserve source bytes, existing CUBE/RLOOK imports, mixed-batch partial success, stable IDs and managed-library persistence.
- Retain the existing limits: 128 MiB DCP, 4096 IFD entries, 4 million combined HSV cells, 8192 tone points, 64 MiB RLOOK, 65536 metadata bytes.
- Reject missing/ambiguous D65 matrices, missing tone curves, automatic black rendering, triple-illuminant HSM, unsupported spatial/HDR/RGB stages and malformed data. Do not infer Adobe defaults or add policy controls in this first version.
- Automatic import is stricter than the legacy CLI for no-HSM profiles that default to automatic black: fail explicitly instead of silently omitting the unsupported stage.
- Keep D65 adaptation, matrix normalization, HSV normalization, exposure and natural-cubic tone sampling aligned with the existing Python reference. No intermediate RGB CUBE.
- No bundled Python, shell-out conversion, new third-party dependency or shared rendering change.

## Tasks

1. [x] Add standalone compiler tests first, observe the missing-compiler failure, then implement the bounded TIFF/DCP reader and native RLOOK compiler. Cover endian variants, supported tables/matrices/tone/EV, malformed/oversized input and precise unsupported reasons. Differential tests compare decoded stages against the existing Python compiler.
2. [x] Add failing LookLibrary/model tests for DCP import, then connect conversion to staging and native validation. Preserve original sourceName while storing `.rlook`; test restart, duplicate names, failure cleanup, registry rollback and mixed DCP/CUBE/RLOOK batches. Extend the file picker and localize diagnostics in supported Mac languages.
3. [x] Build the Mac app, run compiler differential tests, library/model/localization tests and core CTest. Verify the packaged app has no Python runtime requirement, exercise import/render/export with isolated storage, and independently review the final diff. Record actual results and remaining device/reference limitations.

## Review Focus

- A DCP without an explicit tone curve must not be accepted as identity.
- Default/missing Auto black must not be silently omitted.
- Malformed dimensions/counts/offsets and nearly singular matrices must fail without traps or unbounded allocations.
- Conversion or registry failure must not leave installed files or change the current selection.
- DCP source paths and source bytes must remain unchanged, including same-name imports and source deletion after successful import.

## Progress

- Branch `feature/mac-dcp-import` in an isolated managed worktree; implementation baseline `a883b91c547e9cc6d5f463d9ece25720dc33e8cd`.
- Baseline Mac build started with `RAWLAB_RUM=0 JOBS=8 bash RawLabMac/build.sh`; no production code changed yet.
- Completed the red/green compiler, library and model cycles. Independent review identified near-singular calibration and overlapping Rational-work amplification; both received failing regression tests and fixes, then an independent re-review found no remaining must-fix issues.
- Final results and platform/reference limits: [verification](../../verification-mac-dcp-import-2026-10-18.md).
