# Native DCP Look Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate full-DCP RGB-CUBE approximation for the currently supported DCP subset.

**Architecture:** Compile a bounded, versioned `.rlook` containing the original stages. Evaluate them in portable native CPU code after target RAW development; retain canonical CUBE rendering and existing C ABI.

**Tech Stack:** Python struct/unittest/NumPy, C++17, existing CMake/CTest, Swift/WPF file pickers.

**Spec:** `docs/superpowers/specs/2026-10-03-native-dcp-look-design.md`

## Global Constraints

- No new native dependency, no request ABI change, no camera-specific color fixes.
- Version 1 little-endian format; 64 MiB file, 4 million cells, 4097 tone samples, 65536 metadata bytes.
- Sources read-only and writes atomic; no Adobe profile data committed.
- CPU/reference max display-channel arithmetic error <= `2e-6` on identical float32 inputs.
- GPU Auto/Off use CPU for `.rlook`; Force fails explicitly. Existing CUBE paths remain unchanged.
- Preserve all existing work; no commit, push or publication requested.

### Task 1: Package Writer And Reader

**Files:** Create `lutools/lutprep/native.py`, `lutools/tests/test_native_dcp.py`; modify `lutools/lutprep/{__main__,bake}.py`.

**Interfaces:** `compile_dcp(source, destination, *, force=False, dcp_exposure=True) -> dict`; `read_native(path) -> dict` validates and exposes stage arrays plus metadata.

- [x] Add failing tests using `write_dcp` synthetic fixtures:
  ```python
  report = compile_dcp(source, destination)
  self.assertEqual(report['mode'], 'native-dcp')
  np.testing.assert_array_equal(read_native(destination)['table'], profile.table)
  with self.assertRaises(FileExistsError):
      compile_dcp(source, destination)
  ```
- [x] Run `python -m unittest lutools.tests.test_native_dcp -v`; observe missing module failure.
- [x] Implement the exact structured format, source-alias/no-clobber checks, atomic writes and CLI command; add malformed header/length/numeric/metadata tests.
- [x] Run new tests and the existing `test_lutprep*.py` suite.

### Task 2: Portable Native Evaluator

**Files:** Create `lutools/include/sony2fuji/dcp_look.h`, `lutools/src/core/dcp_look.cpp`, `lutools/tests/dcp_look_tests.cpp`; modify `lutools/CMakeLists.txt`.

**Interfaces:** `static std::shared_ptr<const DcpLook> DcpLook::loadCached(const std::string&)`; `RGB DcpLook::apply(const RGB&) const`. Test executable accepts `--evaluate look.rlook input.f32 output.f32` for cross-language comparisons.

- [x] Add synthetic native format and math tests before the implementation:
  ```cpp
  auto look = DcpLook::loadCached(path);
  check(look != nullptr, "load native profile");
  const auto gray = look->apply(RGB(.18f, .18f, .18f));
  check(std::abs(gray.r - .46135613f) < 2e-6f, "linear identity profile");
  ```
- [x] Build the new test target and observe missing implementation failure.
- [x] Implement bounded endian-aware loading, immutable cache and double arithmetic for all supported DCP stages.
- [x] Run native synthetic tests; compare Python-produced packages across deterministic scene/stress samples using the probe mode.

### Task 3: PHOTO And Desktop Integration

**Files:** Modify `lutools/src/ffi/sony2fuji_c.cpp`, C ABI documentation comments, `lutools/tests/dcp_look_tests.cpp`, CLI help, Mac `EditorModel.swift`/`Engine.swift`, Windows `MainWindow.xaml.cs`/`Native.cs`.

**Interfaces:** Existing `request.lut_path` accepts `.rlook`; no request layout change.

- [x] Add red C ABI tests: `.rlook` success, strength-zero bypass, CPU/Auto identical results and reported CPU backend, Force explicit failure, linear exposure before the look and strength blend.
- [x] Dispatch file types before deciding RAW/GPU copying; run native DCP after common linear adjustments, then reuse all existing output processing.
- [x] Add desktop file extensions and accurate unsupported-format wording, keeping picker behavior otherwise unchanged.
- [x] Run native tests, Mac build and relevant existing engine tests; preserve CUBE hardware behavior in existing acceleration checks.

### Task 4: Real Profiles And Delivery

**Files:** Update `lutools/docs/{lut-preparation,color-contract}.md`, `lutools/README.md` and this record. Keep proprietary packages/results under ignored `output/`.

- [x] Compile the seven cross-camera profiles and nine Sony looks without CUBE baking.
- [x] Feed actual six-camera linear samples and deterministic stress samples to C++ and Python; record max/p99 errors, finite output and package sizes.
- [x] Exercise PHOTO with real RAW input, CPU Auto fallback, exact/interactive/file-output behavior, and confirm old CUBE CPU/Metal checks.
- [x] Run `bash lutools/test.sh`, Mac build/affected checks, and Python suites with the real optional Canon fixture and native probe.
- [x] Request one scoped read-only review of file contract, evaluator and PHOTO routing; fix evidence-based findings and re-run affected checks.
- [x] Check changed-file scope and whitespace, document unimplemented GPU/native-stage coverage, then report measured results without claiming universal calibration.

## Verification Record

- Python and C++ missing-feature failures were observed before implementation.
  PHOTO tests then reproduced unsupported `.rlook`, Force, exposure and blending
  failures before the routing change. The same tests pass afterward.
- Full Python suite: 65/65 passed with both `RAWLAB_TEST_CANON_DCP` and
  `RAWLAB_DCP_PROBE=lutools/build-macos/dcp_look_tests` set. No optional case skipped.
- `bash lutools/test.sh`: 9/9 CTests passed in 50.98 s, including native DCP,
  existing CUBE/Metal, RAW, WB and highlight regressions.
- `acceleration_tests` with DJI DNG + Canon Standard `.rlook` and Sony ARW + Sony
  FL `.rlook`: both passed. CPU/Auto differences are exactly 0 DN for camera WB,
  4000 K, 8500 K and adjustments. CPU reporting, Force rejection, interactive
  cache transitions, FINAL and exact file export assertions passed.
- `bash RawLabMac/build.sh`: passed, including bundled-dependency/signature checks.
- `RUN_PROGRESSIVE_RENDER=1 bash RawLabMac/tests/progressive-render.sh
  lutools/examples/DSC06251.ARW output/lutprep/sony-a7c2/FL.rlook`: passed real
  2000-pixel exact preview, 1000-pixel interaction, release-to-exact and final
  settings/histogram equality checks through the Mac model and engine.
- Local `output/native-dcp/verify.py` produced 42 real-image comparisons and 21
  deterministic stress comparisons. All 63 passed; maximum absolute display RGB
  channel error against Python on identical float32 inputs: `2.9802319834e-8`.
  This measures arithmetic parity, not source-camera or Lightroom appearance.
- Tested `.rlook` files are 310209..310228 bytes; their old 129-grid CUBEs were
  38.2..61.8 MB. Reports and render pixels remain under ignored `output/native-dcp/`.
  Nine Sony `.rlook` files are also in `output/lutprep/sony-a7c2/`.
- Native CLI exported `output/native-dcp/dji-canon-native.jpg`. Visual inspection
  confirmed a nonblank correctly oriented photo with blue, not purple, sky.
- A scoped independent read-only review found no concrete file-layout, arithmetic,
  cache or PHOTO-routing defect. Its cross-language probe also passed.

No DCP GPU kernels or new DCP stages were added. Generic RGB LUTs still use their
existing CUBE approximation gate. Windows picker support was edited but not built
on this Mac (no `dotnet` installed); Windows/iOS/Android device runs remain unverified.
No source RAW/DCP files were modified, and no Adobe data, generated packages,
commits or publication are included in this change.
