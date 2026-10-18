# Mac Native DCP Import Verification

## Scope

- Branch `feature/mac-dcp-import`, based on refreshed `origin/development` at `a883b91c547e9cc6d5f463d9ece25720dc33e8cd`.
- Mac-only Swift DCP compiler, existing RLOOK v1/v2 serialization, native look validation and managed-library import. No shared ABI/rendering or other-client changes.
- Local arm64 Mac build, macOS deployment target 14.0. Verification build uses `RAWLAB_RUM=0`; this is not a release, upload, merge or exact-head CI result.
- Automatic import requires an embedded tone curve and explicit `DefaultBlackRender=None` (1). Unlike the legacy CLI, it never silently omits Auto black, even for no-HSM profiles. Existing prepared RLOOK imports remain compatible.

## Automated Results

| Check | Result |
| --- | --- |
| `RAWLAB_RUM=0 JOBS=8 bash RawLabMac/build.sh` | Passed, including bundled dependency/signature verification |
| `bash RawLabMac/tests/dcp-compiler.sh` | 23 assertions passed |
| Compiler differential checks with `RAWLAB_LUTPREP_PYTHON` and `RAWLAB_TEST_CANON_DCP` | 6 tests passed, no skips; synthetic supported-stage combinations plus privately owned Canon EOS R5 Camera Standard |
| `bash RawLabMac/tests/look-library.sh` | 54 assertions passed with the real native core |
| `bash RawLabMac/tests/look-import-model.sh` | Passed, including mixed DCP/RLOOK/CUBE batches, specific error propagation and selection preservation |
| Model test with `RAWLAB_TEST_DCP` and `RAWLAB_TEST_RAW` | Real Canon DCP import and Sony ARW preview/export passed; CPU/Auto and CPU/Force Metal maximum difference 1 RGB8 code value |
| `ctest --test-dir lutools/build-macos --output-on-failure` | 36/36 passed, including native DCP CPU/Metal, RAW and export regressions |
| `bash RawLabMac/tests/edit-model.sh` | Passed |
| `bash RawLabMac/tests/usage-model.sh` | Passed; corrupt-input failures are intentional assertions |
| `python3 scripts/localization/generate.py --check` | All 30 generated catalogs matched; only Mac resources changed |
| `python3 -m unittest discover -s tests -p test_localization.py` | 27/27 passed |
| `bash RawLabMac/tests/localization.sh` | Passed |
| `bash RawLabMac/tests/batch-import-presentation.sh <temporary-output>` | DCP-specific reason visible; result sheet fits 950x620 and 1320x850 editor windows; screenshots visually checked |
| Shell syntax and `git diff --check` | Passed |

The differential tests compare input/output matrices, original normalized HSV tables,
exposure, 4097 tone samples, format version and adaptation metadata against the existing
Python compiler. Matrix/tone tolerance is `atol=2e-12, rtol=1e-12`; float HSV tables match
exactly. Tests also cover endian variants, all three D65 matrix slots, shared/dual HSM,
optional LookTable, omitted zero-saturation planes, unsupported policies, malformed
offsets/counts, oversized input and source preservation.

Native library/model checks cover duplicate names, managed `.rlook` paths and original
`.dcp` provenance, source deletion followed by restart, conversion failure cleanup,
registry-write rollback and mixed-batch partial success. The real-profile run exports
decodable JPEG and actual 16-bit PNG with the expected dimensions. Private source
profiles, RAWs and derived looks are not committed or redistributed.

## Desktop Interaction

The packaged app was launched with an isolated `CFFIXED_USER_HOME` and `HOME`, a unique
temporary test bundle identity, and `PATH=/nonexistent`. Using the native File menu:

1. Selected `Supported camera look.dcp` in the actual import panel; automatic conversion
   succeeded and the app selected `Supported camera look`.
2. Selected `Missing tone.dcp`; the result sheet displayed the original filename and
   the specific missing-`ProfileToneCurve` explanation, not a generic corrupt-file error.
3. Closed the result sheet and verified the previously imported look remained selected.
4. Verified the isolated registry contains a UUID `.rlook`, `format=rlook`, version 1,
   and `sourceName=Supported camera look.dcp`, with no failed-import entry.

The test app was closed before inspecting/removing its isolated files; it was not
queried again after exit. The normal built bundle identity was restored by the final
build. Other running RawLab instances were not modified or stopped.

## Independent Review

Read-only review found two input-validation gaps, both reproduced with failing tests:

- A nonzero determinant can still represent a numerically rank-deficient ColorMatrix.
  The compiler now uses system Accelerate SVD with NumPy's default rank threshold.
- Multiple TIFF tags can alias one Rational payload and multiply parsing work. Total
  Rational elements scanned are now bounded by source byte count divided by eight.

Both regression tests now pass. A follow-up review found no remaining must-fix or
should-fix issues in those fixes.

## Limits

- No claim of Lightroom/Adobe pixel parity, original camera-JPEG matching or controlled
  cross-camera color accuracy. Runtime and implementation agreement are different evidence.
- x86_64 Mac, physical macOS 14/15 devices and other clients were not verified in this task.
- The current system Accelerate `dgesvd_` CLAPACK interface emits a deprecation warning
  on the installed SDK. It remains available on the supported Mac 14 target; adopting
  the newer LAPACK headers across Swift build entrypoints is separate maintenance work.
- One-off logs, screenshots, synthetic transfer files, isolated profiles and obsolete
  build intermediates are cleaned after recording these results. The local app bundle
  is retained as the runnable deliverable.
