# RawLab v0.5.0 Release Verification

The release is prepared in an isolated worktree from `origin/development`
`86ddfe9a1904810611670e3753265dee967fa7f8`. The original dirty checkout is
untouched. Runtime sources come from this development snapshot; release edits
update documentation, licenses, packaging and `0.5.0` / build `8` metadata.

The PR targets `main` but is not merged by this workflow. `v0.5.0` identifies
the same verified source commit. The release source archive records that SHA in
`BUILD-PROVENANCE.json`, and `SHA256SUMS.txt` identifies the published assets.

## Builds and Checks

Local Apple builds use macOS 27.0 and Xcode 27.0. Windows is built natively with
MSVC/.NET on the prepared Windows x64 build host, not cross-compiled on macOS.
Only pinned source download archives are reused locally; client executables,
processing libraries and native Mac/iOS dependencies are rebuilt in this tree.
The Windows build retains dependency/compiler caches while recompiling the
current client/core source; it does not reuse a prior published native package.

| Check | Result |
| --- | --- |
| macOS arm64 and x86_64 builds | Passed; executables and embedded dependencies target macOS 15, have the expected architecture, dependency closure and ad-hoc signatures |
| macOS core CTest | arm64 19/19 and x86_64/Rosetta 19/19 passed, including real Sony/DJI RAW and CPU/Metal checks, effects, wavelet/chroma denoising, WB, highlights and export-quality isolation |
| macOS application smoke | Both architectures passed real Sony ARW/DJI DNG previews, native JPEG/16-bit PNG export and missing-input rejection |
| macOS current camera regressions | S5II, R6 III, OM-1 and X-T5 passed RAW, WB and application export; the three GPU-configured fixtures also passed actual CPU/Metal comparison |
| macOS new feature regressions | Edit persistence, batch snapshots/recovery, photo information, update checks, editor/denoise models, exact single/batch native and capped exports, and vignette/grain with wavelet/chroma CPU/Metal parity passed |
| Android release | ARM64/x86_64 APK rebuilt and release-signed; actual package metadata is 0.5.0/8, SDK minimum 26, signature and 16 KB ZIP/ELF alignment checks passed |
| Android host tests | 50/50 unit tests, zero failures/errors/skips; Release lint passed |
| Android signing continuity | Certificate SHA-256 matches the v0.4.1 APK fetched from GitHub: `9fd68e245a597cde2abb949ff807819a89afdd4b000b5ad02391181f38a06048` |
| iOS builds | Device arm64 and simulator arm64/x86_64 XCFramework, unsigned device Release app and arm64 simulator Debug app passed |
| iOS native regressions | S5II, R6 III and OM-1 each passed RAW/WB/Metal checks on the simulator; the real Sony RAW application export test passed, including capped sizing and capture metadata |
| iOS feature/resource tests | Edit persistence, batch snapshots/recovery, photo information and bundled LUT processing passed |
| Windows current-source build | Self-contained x64 WPF/native package rebuilt; six CPU CTests and editing/denoising/update model suites passed |
| Windows camera and file-version checks | Nine cameras passed all 18 RAW/WB checks: S5II, R6 III, OM-1, a7R VI, X-T5, Z5II, GFX100RF, OM-3 and X2D II; Z50II HE* rejection and actual 0.5.0.8 file-version checks passed |
| Client archive checks | All five packages passed version, archive-integrity, matching GPL/attribution and personal-RAW exclusion checks; ExifTool's own tiny upstream test corpus is retained with its distribution |
| Source archive gate | Release packaging verifies corresponding project/native dependency sources, patched LibRaw, the committed source SHA, private-material/RAW/historical-binary exclusion and checksums before upload |

## Test Harness Repairs

The existing Mac `denoise-model.sh` failed to compile because it omitted the
new persistence/batch source files required by `EditorModel`. The script now
includes those modules, and its test injects temporary edit/batch directories
rather than writing shared application state. The repaired real-RAW model test
passed; production rendering code was not changed.

The iOS export/LUT wrappers require an absolute app path for their runtime
framework search path. Initial relative-path invocations failed to load the
framework; the correctly invoked tests passed without source changes.

Windows source-packaging tests also verify that both `LICENSE` and
`docs/licensing.md` are transferred for native builds. All five client packages
include the full GPLv3 text and licensing notice while retaining third-party
attribution and the historical MIT notice.

## Reproduction and Evidence

- [Build commands and corresponding sources](releases/v0.5.0-source.md)
- [Feature release notes](releases/v0.5.0.md)
- [Previous complete camera sample report](verification-raw-compatibility-2026-10-09.md)

Local, Git-ignored evidence is under `build/releases/v0.5.0/`: `logs/`,
`compatibility-arm64/`, `ios-raw-tests/`, `windows-results/` and `assets/`.
The current Windows source transfer and build log are under
`build/windows-remote/20261010-154918/`. These local logs are not distributed
as project source and are not GitHub CI results.

## Remaining Limits

- No GitHub Actions workflow is configured; an absence of PR checks is not a
  passing CI result.
- Windows hardware Direct3D 11, WPF interaction and remote-desktop performance
  are not certified by the build VM/CPU checks.
- This release does not claim Android device instrumentation, physical iOS
  installation/GPU/memory/thermal testing, native Intel hardware or physical
  macOS 15 validation. Intel execution here uses Rosetta.
- Nikon Z6III/Z50II HE* remains unsupported. The v0.4.1 26-camera report is
  historical evidence, not a claim that all 26 fixtures were rerun for v0.5.0.
- A passing fixture does not establish support for every camera mode or exact
  manufacturer/Adobe color rendering. Original RAW files are never modified.
