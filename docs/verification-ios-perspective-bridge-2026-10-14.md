# iOS perspective parameter bridge — 2026-10-14

V08-005 non-UI integration, based on development
`dd634415377607582c59ff35d483551041883d79` (including #49/#50).
Isolated checkout: `build/ios-perspective-bridge`, branch
`fix/ios-perspective-bridge`.

## Change

`GeometrySettings` already stores both perspective axes and supplies zero for
older records. The iOS processor only submitted the basic geometry configuration,
so these values never reached the renderer. `configureGeometry` now submits the
complete versioned perspective configuration after the basic geometry setter,
including both zero values on subsequent renders. All RAW, raster and DNG callers
already use that shared configuration entry point.

The only production change is nine lines in
`RawLab/RawLab/Core/RawProcessing/Sony2FujiProcessor+Helpers.swift`.
The #50 white-balance cache, persisted model, UI, core and C ABI are unchanged.
The other changes extend the existing geometry harness and record these results.

## Environment and evidence

- Xcode 27.0, arm64 iPhone 18 Pro Max simulator, iOS 27.0.
- Task-owned simulator: `519B454C-C6A7-4D3D-9BA1-5F3973E7B7AC`.
- The existing simulator framework from
  `build/phase-one-basic-geometry/build/ios-geometry-sim-core/output` was copied
  into this checkout's ignored `build/framework`. Its tracked native sources
  match this development baseline; `git diff 66726f1 HEAD -- lutools` is empty.
- The existing #50 XCFramework's device/simulator package was copied to this
  checkout's ignored `lutools/build-ios` for the complete app build.
- Sony fixture: the authorized local `lutools/examples/DSC06251.ARW` in the
  original checkout, ILCE-7CM2, upright rendered canvas 4672 × 7008.
- DJI fixture: existing `lutools/examples/DJI_20250602164503_0444_D.DNG`.
  Neither source was modified or uploaded.

| Check | Result |
| --- | --- |
| Geometry harness with Sony RAW | 60 PASS, exit 0 |
| Geometry harness with DJI DNG | 60 PASS, exit 0 |
| Existing #50 preview-performance runner | 34 CPU/Force Metal cases, 13 checks, zero failures |
| #50 output preservation | All 34 RGBA files byte-identical to retained `optimized-01` outputs |
| #50 CPU/Force Metal parity | Maximum difference 1 RGB8 value; gate 2 |
| Complete Release arm64 simulator app | BUILD SUCCEEDED |
| Old helper negative control | Exit 1 at the new H=0.5/V=0 pixel-reference assertion |
| Independent read-only review | No must-fix or should-fix findings |
| Shell syntax / diff whitespace | Passed |

The geometry harness checks horizontal-only, vertical-only and mixed perspective
against an independently configured direct C setter reference, including image
bytes and native/output dimensions. It also checks exact preview/FINAL equality
with interactive and viewport flags enabled, rotation/flip/straighten/crop
composition, capped DNG dimensions, journal-frozen batch FINAL pixels, and old
records without perspective fields preserving their geometry and rendered pixels.

For each real RAW, a tinted master recipe first resolves cold camera WB metadata
with active perspective. Preview equals capped FINAL, and resetting both axes
on the same processor's reused RAW preview session exactly restores the output
of a fresh processor. CPU/Auto output differs by at most two RGB8 values.

An identity Force render confirms Metal is available. Active geometry Auto
reports CPU for the common geometry stage; this report does not infer actual
Metal use during a particular active Auto render from that backend value.
Force with active geometry remains unsupported under the existing core contract.

The #50 runner retains all nine metadata-cache invariants, target-URL camera
baseline checks and FINAL equality with an independently expanded recipe in
CPU and Force Metal. No new performance timing claim is made from this run.

Logs and artifacts are confined to this checkout's ignored `build`:
`geometry-processing-sony-02.log`, `geometry-processing-dji.log`,
`geometry-processing/run.xyG3bl`, `geometry-processing/run.fCmotG`,
`baseline-regression.log`, `cache-regression/metrics.jsonl` and `app-build.log`.
The first synthetic run rejected an overly strong backend assertion; it was
corrected to the existing mixed-result CPU reporting contract before acceptance.

## Reproduction and remaining acceptance

```sh
bash RawLab/tests/geometry-processing.sh /path/to/arm64-simulator/sony2fuji.framework \
  <task-owned-simulator-uuid> /path/to/photo.ARW

bash RawLab/tests/preview-performance.sh /path/to/arm64-simulator/sony2fuji.framework \
  <task-owned-simulator-uuid> /path/to/Sony.ARW "$PWD/build/cache-regression-new"
```

The geometry script also accepts `RAWLAB_TEST_RAW`; without a fixture it explicitly
reports the real-RAW/session-reset checks as unverified. Its harness, module cache
and image artifacts are stored under the checkout's ignored `build` directory.

This closes only the non-UI bridge portion of V08-005. Physical-device perspective
verification, native controls, gestures and product UI acceptance remain with the
later approved iOS implementation. No main/release branch or version metadata is
changed.
