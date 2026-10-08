# Cross Camera Presets First Milestone Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for independently owned tasks. Use test-driven-development and verify each task before marking it complete. Do not commit or publish without a new user request.

**Goal:** Deliver reproducible preset diagnostics and a persistent Mac/Android workflow for prepared CUBE/RLOOK looks, with rendering evidence separated from appearance-reference evidence.

**Architecture:** Keep the existing RAW and look math. Python performs source inspection and optional temporary compilation checks. A small read-only C API validates native look files without decoding a photograph. Clients copy validated looks into application-owned persistent storage and reference them by stable IDs.

**Tech Stack:** Python unittest/NumPy/OCIO, C++17/CTest, Swift/AppKit/SwiftUI, Kotlin/Compose/JUnit/Android instrumentation.

**Spec:** `docs/superpowers/specs/2026-10-07-cross-camera-presets-roadmap.md`

## Global Constraints

- Preserve target RAW calibration/WB/exposure and PHOTO v2 layout; no renderer or shader changes unless a new failing regression proves the need.
- Native input remains compatible `.cube` or `.rlook` v1/v2; mobile apps do not require Python/OCIO.
- Source RAW/profile/reference files are read-only. Proprietary profiles and outputs stay under ignored `output/`.
- Parsing, compilation, runtime execution, and appearance-reference agreement have distinct statuses. Missing reference evidence never becomes a pass.
- Preserve existing built-in film IDs, strength behavior, album UI, preview scheduling and export metadata.
- Only this feature's files are owned. No commit, push, version bump or release in this execution.

## Task 1: Source Inventory And Compilation Diagnostics

**Files:** Create `lutools/lutprep/audit.py`, `lutools/tests/test_preset_audit.py`; modify `lutools/lutprep/__main__.py`; document in `lutools/docs/lut-preparation.md` after integration.

**Interfaces:** `audit_sources(paths, verify_compile=False) -> dict` returns a versioned JSON report. Per-file entries contain path relative to the supplied root, format, metadata, diagnostics, read status, compile status and appearance status. The CLI command is `audit PATH [PATH ...] [--verify-compile]`. It reports all known source files recursively, deterministically, without writing source directories or following directory symlinks.

- [x] Add CLI regression tests before implementation: a supported synthetic DCP reports read success but compile `not_run` by default; `--verify-compile` actually compiles and reads back a temporary RLOOK; the source directory remains unchanged.
- [x] Add mixed-corpus tests for missing ToneCurve, corrupt DCP, XMP profile dependencies and embedded-table references, untagged CUBE and valid compiled RLOOK. One bad file cannot suppress other entries.
- [x] Run `python -m unittest discover -s lutools/tests -p test_preset_audit.py -v` and observe failure because the command/API is missing.
- [x] Implement bounded format inspection using existing parsers. XMP uses standard XML parsing and reports fields/requirements, never decodes tables or advertises execution support. Preserve existing `inspect`/`prepare` behavior.
- [x] Run focused and existing Python tests. Audit the local Panasonic/Ricoh corpus and the three selected donor profiles; keep JSON reports under `output/cross-camera-p0/`.

Examples of assertions:

```python
self.assertEqual(entry['read']['status'], 'passed')
self.assertEqual(entry['compile']['status'], 'not_run')
self.assertEqual(entry['appearance']['status'], 'unverified')
self.assertEqual(source.read_bytes(), before)
```

## Task 2: Shared Native Look Validation

**Files:** Modify `lutools/include/sony2fuji/ffi/sony2fuji_c.h`, `lutools/src/ffi/sony2fuji_c.cpp`, `lutools/include/sony2fuji/dcp_look.h`, `lutools/src/core/dcp_look.cpp`; extend native CUBE and DCP tests.

**Interface:** Add `sony2fuji_validate_look(const char* path, sony2fuji_look_format* format, uint32_t* format_version)`. Output pointers are optional and initialized to unknown/zero on failure. Formats are `SONY2FUJI_LOOK_UNKNOWN=0`, `SONY2FUJI_LOOK_CUBE=1`, `SONY2FUJI_LOOK_RLOOK=2`; CUBE version is zero (unversioned text), RLOOK version is its validated header version. Validation does not require a RAW, session, or GPU.

- [x] Add tests that require compatible CUBE and valid v1/v2 RLOOK to pass, reject untagged/malformed/unsupported files, distinguish missing-file I/O errors, allow null output pointers and leave source bytes unchanged.
- [x] Confirm failure before implementation; then reuse the production CUBE/DCP loaders and PHOTO contract checks. Do not add a second parser or change accepted render semantics.
- [x] Expose the already parsed RLOOK version from the immutable profile; contain exceptions at the C boundary.
- [x] Run affected CTests, then the whole existing core suite and Python/native parity regressions.

```cpp
sony2fuji_look_format format = SONY2FUJI_LOOK_UNKNOWN;
uint32_t version = 99;
check(sony2fuji_validate_look(path.c_str(), &format, &version) == SONY2FUJI_STATUS_OK,
      "native look validation needs no RAW/session/GPU");
```

## Task 3: Managed Mac Look Library

**Files:** Create `RawLabMac/Sources/LookLibrary.swift` and dedicated storage tests/script; modify `EditorModel.swift`, `FilmDock.swift`, and the smallest necessary app/engine callers.

**Interfaces:** A library owns immutable copies in Application Support, an atomically written JSON registry, stable IDs, display names, formats/versions and original filenames. Its operations are import, rename, remove, list and reload. Use the Task 2 validator; the source URL is needed only for the import copy.

- [x] Write real temporary-directory tests for import/reload after removing the original, same-name imports, invalid content rejection, safe rename/delete, source preservation and unusable stored files.
- [x] Observe failure, then implement storage with injected base directory for tests, file-copy staging, native validation, atomic registry replacement and rollback if installation fails.
- [x] Restore custom looks at startup; keep existing built-in IDs and photo-session behavior. Import errors preserve the previous selection. Delete only managed files and reset selection safely if necessary.
- [x] Add compact rename/remove actions to user looks using existing native UI patterns. Do not create an unrelated library redesign or change photo navigation.
- [ ] Build the app; run model/storage tests and a live import/render/export/restart flow using locally prepared looks.

The build, storage/model integration, real RAW progressive checks and packaged-app export smoke pass. The remaining live GUI import/restart flow is blocked by the locked Mac; it is not marked passed.

```swift
let imported = try library.importLook(from: source)
try FileManager.default.removeItem(at: source)
let restored = LookLibrary(directory: directory)
assert(restored.looks.contains { $0.id == imported.id })
assert(FileManager.default.fileExists(atPath: restored.url(for: imported).path))
```

## Task 4: Managed Android Look Library And Import

**Files:** Create a focused library/store and tests under `RawLabAndroid/app/src/`; modify `NativeProcessor.kt`, `rawlab_jni.cpp`, `EditSettings.kt`, `PhotoStorage.kt`, `EditorViewModel.kt`, `MainActivity.kt`, `EditorScreen.kt`, and strings as needed.

**Interfaces:** JNI exposes the Task 2 validation result (format and version) or an actionable error. The library copies a user-selected document into `filesDir/looks`, not `cacheDir`, and persists stable IDs and metadata. Rendering resolves built-in IDs through existing assets and imported IDs through the managed library; neither uses a persisted external URI as the render path.

- [x] Write tests before implementation for imported look survival after source removal/recreation, collisions, invalid-file rollback, rename/delete and existing built-in resolution.
- [x] Add SAF document import for CUBE/RLOOK independent of the photo picker, using an input stream and owned temporary file. Do not add storage permissions, Python, OCIO or remote services.
- [x] Extend the existing film strip with an import icon and compact management actions; keep photo selection, album state, sliders and zoom unchanged. Run imports/validation on an I/O dispatcher.
- [x] Test actual JNI validation and actual native rendering with a synthetic non-proprietary compatible CUBE and RLOOK fixture; do not use mocks as evidence of native support.
- [x] Run JVM tests, lint, build, instrumentation and phone/tablet UI checks. Verify restarting and deleting the transferred original does not remove the stored look.

JVM 33/33, API 35 arm64 device tests 36/36, and separate dark/large-font tablet UI flow pass. Library reconstruction and Activity recreation are covered; abrupt process death during import and manual third-party SAF provider round trips remain unverified.

## Task 5: Fixed Samples And Explicit Reference Evidence

**Files:** Add only focused validation tooling/tests and a reference-protocol document under `lutools/`/`docs/`; local reports and exports go under `output/cross-camera-p0/`.

- [x] Freeze named synthetic scene-linear samples and the three donor files before changing rendering math. Record the file identities and all compilation policies in the local report.
- [x] Prepare representative DCP looks, one declared display-domain LUT and one declared Log-domain LUT; keep baked approximation failures visible instead of increasing the gate.
- [x] Run actual native preview/final/export and CPU/GPU comparisons on existing Sony/DJI RAWs.
- [x] Seek an independent source-software or SDK reference using isolated test inputs, never modify the user's Lightroom catalog. Record which source is used and what it proves.
- [x] Define reference metadata requirements and comparison outputs (sample count, channel errors, gray/highlight checks, declared reference and thresholds). Reject mismatched/missing reference conditions; do not generate a reference with the same evaluator and call it independent.
- [x] Document controlled same-scene RAW requirements. If these or a source reference cannot be obtained, leave the corresponding P0/P1 quality checks incomplete and continue independent product work.

Three DCPs and the canonical Log-domain CUBE succeeded. Display-domain baking failed the existing `.02` gate at size 129; no approximate file was installed. Reference acquisition was attempted but did not succeed: Lightroom could not launch, the local SDK has no built reference renderer, and no paired RAW set is available. These are incomplete quality gates, not passes.

## Task 6: Integration, Review And Progress Record

- [x] Run scoped reviews of native validation and client persistence/import boundaries; fix supported findings and rerun affected gates.
- [x] Run the final Python/native/Mac/Android checks for the exact local changes; do not reuse old binaries as evidence for new APIs.
- [x] Record completed roadmap boxes and concrete remaining external/reference/P3/P4 conditions, with commands and reports in `docs/verification-cross-camera-presets-2026-10-07.md`.
- [x] Check only owned diffs and package/source safety; leave changes uncommitted. Do not mark the full roadmap complete when only its first milestone is implemented.

Final engineering checks pass; the full product/quality milestone is not complete because independent appearance reference, paired RAW evidence and the locked-Mac GUI gate remain outstanding. See the verification record for the display-domain approximation failure and platform limits.

## Task Dependencies And Ownership

- Task 1 and Task 2 share no source files; Task 5 reuses Task 1 reports and existing preparation functions without changing their semantics.
- Task 3 and Task 4 consume exactly the Task 2 C API. Mac and Android storage use the same behavior contract, not a new cross-language storage framework.
- Task 3/4 may proceed independently once Task 2's signature is fixed; final device builds require the implemented core.
- Task 6 integrates all results. Source-reference and paired-RAW gaps block only the associated quality claims, not unrelated import/storage tests.

## Baseline

- Python: 73/73 passed with the real local Canon profile and native probe enabled.
- macOS arm64 CTest: 10/10 passed, including actual Metal and Sony/DJI acceleration checks.
- Initial worktree contains only the approved, previously untracked roadmap document; no unrelated source changes.
