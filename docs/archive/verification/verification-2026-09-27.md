# Fuji Pipeline / RawLab Mac Verification

The exposure policy and decoder ordering below are historical. The current implementation and validation are documented in [Scene Development Verification](verification-scene-2026-09-27.md).

## Delivered

- Branch: `codex/fuji-pipeline-macos`, based on `bb76d42`; no commit or push.
- Native bundle: `build/RawLab Mac.app`, host arm64, macOS 26+ with bundled Homebrew libraries and ad-hoc signing.
- Existing raw sources, including the untracked DJI DNG, were not changed.
- The running earlier Mac validation window was preserved after the user began changing parameters. Quit/reopen the bundle to load the final core/crop/menu/theme changes.

## Checks

- Initial numerical regression suite failed on the expected CUBE order/domain/range, super-white F-Log2, strength, Log-output and PNG16 cases; these now pass.
- Additional failing regressions reproduced and fixed camera XYZ matrix direction, Sony active crop, invalid numeric input and custom buffer WB.
- `SONY2FUJI_TEST_GPU=1 ctest --test-dir lutools/build-macos --output-on-failure`: 3/3 passed, including real Metal/CPU comparison with a tiny buffer and non-unit CUBE domain.
- ASan/UBSan build (`build-sanitize`, GPU off) and CTest: 3/3 passed. The public example also compiles in this build.
- `bash RawLabMac/build.sh`: successful native build and dependency packaging.
- `codesign --verify --deep --strict 'build/RawLab Mac.app'`: passed.
- Mac smoke: Sony ILCE-7CM2 ARW and DJI DNG decoded, neutral and PROVIA results differed, JPEG and 16-bit PNG exported, missing RAW failed as expected.
- Sony export: 7008x4672. DJI export: 3072x3072. These match ImageIO's recorded pixel dimensions.
- PNG readback: 16-bit IHDR, exact synthetic red sample after zlib decompression, sRGB chunk recognized by Pillow, real exports decoded successfully.
- Same-settings Sony PROVIA JPEG from CLI and Mac: `cmp` returned success (byte-identical).
- Real PNG/JPEG per-channel mean absolute differences after 8-bit decoding: Sony 1.655, DJI 1.884, consistent with the JPEG being lossy rather than a swapped-byte PNG.
- `git diff --check`: clean.

## Review Reconciliation

Independent review proposed applying inverse BT.709 OETF to the film output. This was not applied: the bundled header says `#Gamut: ... BT.709`, while `#Gamma` names the film simulation. The official overview does not establish a BT.709 OETF from those primaries alone. The application explicitly documents its sRGB viewing convention rather than introducing an unverified second gamma conversion.

## Default Exposure Follow-Up

The user reported that default rendering was too dark and required RAW exposure to follow the embedded preview. The original sensor-white convention reproduced that problem in both samples. A regression independently decoded each preview and compared linear-light median luminance:

| Fixture | Old RAW median | Preview median | Required baseline EV | New RAW median |
| --- | ---: | ---: | ---: | ---: |
| Sony DSC09067.ARW | 0.0761664 | 0.316288 | +2.05401 | 0.316288 |
| DJI DNG | 0.0509500 | 0.174518 | +1.77622 | 0.174518 |

The regression failed before the fix on both files. The shared RAW decoder now applies this per-file scalar gain in float before user EV, color conversion and the film LUT. Tests verify +1 EV doubles values, the gain is independent of user EV, disabling matching recovers the sensor baseline, and dark/missing/clipped previews are not forced to middle gray. A separate failing regression caught and now rejects non-finite combined exposure gain.

Visual checks used `/tmp/rawtools-exposure-proof/{DSC09067,DJI_20250602164503_0444_D}/{before,after,embedded}.jpg` and the actual Mac PROVIA exports. The middle-tone brightness is aligned; camera contrast, local tone mapping, noise processing and colors are not copied. Both fixtures have unspecified DNG preview-color metadata (0), so sRGB interpretation is an explicit approximation. Known non-sRGB DNG previews are not silently metered as sRGB.

The native bundle was rebuilt and ad-hoc signed with this shared-core change. The user's running earlier window was not closed or reset; it must be reopened to load the new executable. Existing positive exposure compensation should be reset to 0 EV when comparing the new baseline.

## Remaining Limits

- No controlled gray-card/color-chart calibration or Fuji in-camera JPEG equivalence measurement. Relative exposure is deterministic, not an absolute cross-camera reflectance calibration.
- iOS source is updated, but its existing xcframework and app were not rebuilt; Android was not built. Rebuild those platforms before deployment.
- Metal was exercised on this Mac, not on iOS hardware. Other camera models, 4-channel RAWs and rotated-file fixtures need platform/sample coverage.
- Native UI inspection covered the earlier functional comparison window. The final bundle passed build and headless render/export smoke tests; its last visual changes were not allowed to interrupt the user's active window.
