# Windows Agent v08 Verification

## Scope And Sources

Milestone 1 (complete Agent v4) is verified. Ordinary-image integration and the
single-preview default are subsequent milestones, not acceptance claims in this
section. No push, PR update, merge or release is authorized by this record.

- Windows base: `3199c915d20b77f38c00a6b7c1edbc9a286807ea`, branch `feature/windows-v08-editor`.
- Frozen Mac source: `82946eb4d3c99b0e6edffdc868c3c393539fc2e2`.
- Common ancestor: `440b9788ff4cfd8a3f5dfa781b16a33997ccd801`.
- Selectively applied the 19-file `lutools/` closure from that frozen source. No Mac UI was copied and no whole `4f95bceb` cherry-pick was performed. The source/input/recipe/look alias guards and their regressions are retained.
- Additional shared-file changes are Windows CLI UTF-16-to-UTF-8 entry handling, Windows CLI fixture selection in CMake, and an explicit `<string>` include needed by MSVC in `display_render_tests.cpp`. No new rendering algorithm, color contract or ABI layout was introduced.

Windows `RenderEngine.AgentRecipe` resolves the target RAW through the existing
`PrepareRecipe`, then serializes the actual `Request`, HSL/effects/denoise/lens
and geometry/perspective settings. Windows simultaneous wavelet and display
chroma settings remain effective. FBDD is always zero; no FBDD control was added.
The actual Windows CLI and v1-v4 schemas are built and packaged with the editor.

## Source Snapshots

Evidence is retained under ignored `build/windows-agent-v08/`. The prepared
Windows workspace is `C:/RawLabBuild/a8fdd7-231344`; no earlier DLL is substituted
for the newly compiled core. Archives and per-file SHA-256 manifests distinguish
the following runs:

| Snapshot | Source ZIP SHA-256 | Source Files | Result |
| --- | --- | --- | --- |
| `unicode-red-20261015-234614` | `c0827701e8bc0ef6aed98d42a8ca4868df6baaf0825f7ab8a882ca04244576e1` | 511 | Fresh native compile/package; 38/41 CTest passed, three CLI Unicode tests failed. Not a green full wrapper. |
| `cli-green-20261016-000750` | `f8c93036efd459ab3e2eccf4e295ff753911232a354640c91abdc713f477ec9f` | 511 | Fixed Windows CLI, six CLI CTest groups and fresh managed Agent/isolation/runner checks passed. |
| `m1-final` | `c66d7b2942e4a5f4837bff30dd3826a308644ec3c708e209692300264866cb50` | 510 | M1-only staged source tree `1c8e5c636a7c544e6d5444627e0c660e75b66b78`; every listed file was hash-checked on Windows before final compilation/Unicode/UI checks. |

The first two archives also contain an unwired ordinary-image test source. It
was not executed as part of M1 and is excluded from the final M1-only archive.
From the first to the second snapshot, runtime changes are limited to
`lutools/CMakeLists.txt` and `lutools/src/cli/main.cpp`; the other changes are the
independent target-WB oracle and the unwired ordinary-image test. From the second
to the final snapshot, only `main.cpp` changes, adding its explicit `<utility>`
include. Subsequent milestone-status/verification prose is not executable code.

The unchanged native rendering tests are not needlessly repeated after a CLI-only
change. These results are not described as a single final-snapshot 41/41 run.

## Executed Gates

The task harness uses the real `RawLabWindows/build.ps1 -Test -RawPath <external
ARW>`, CMake/MSVC, CTest, and the existing managed test projects on Windows 11
22631 / SDK 9.0.318. Failed wrapper runs and their actual exit codes are retained.

| Gate | Actual Result |
| --- | --- |
| Fresh native build and package | Passed after correcting the missing standard header and CLI package path. |
| Initial full CTest | 38/41 passed in 1079.85 s; `agent_preview`, `raw_info_cli`, `agent_commands` failed. RAW/WB/geometry/perspective/denoise/display-buffer groups completed. |
| Targeted CLI rerun | 6/6 groups passed in 125.52 s: geometry, exact preview, info, Agent commands, legacy recipe parity and v4 schema/normalization. Windows uses the supplied external RAW rather than silently skipping a missing hard-coded sample. |
| Full schema gate with dependency present | 8/8 Python tests passed, no skips. `jsonschema==4.25.1` and Windows wheels are in a private, checksum-verified verification directory; no global Python installation/configuration changed. |
| Fresh managed test build | Passed, zero warnings/errors. |
| Agent effective-state regressions | 132 checks passed. |
| Default admission/isolation | 142 checks passed, including the new four-argument Agent entry with pre-existing private journal/staging refusal controls. |
| Runner selection/failure propagation | 37 checks passed. |
| Final explicit Unicode recipe-path probe | Passed using Chinese plus a supplementary-plane emoji; the same probe had failed on the fresh narrow-entry CLI before the fix. |
| Final About / default UI-only regressions | 40 / 98 checks passed on source-hash-verified inputs. |
| Default profile | Before/after snapshots are identical, remaining `ABSENT`. |
| Formatting | `git diff --check` passed. |

The ordinary CTest schema invocation has an optional-module skip in the embedded
build-tool Python. The separate complete schema gate above removes that gap;
the optional skip is not represented as full schema validation.

The Agent checks independently decode PNG16 from GUI, shared CLI and frozen
BatchRunner outputs. Same-size FINAL pixels match exactly for non-default tone,
all 24 HSL components, effects, wavelet plus display chroma, geometry/perspective,
manual lens calibration, saved-state restoration and master strength
0/50/100/200%. Buffer/PNG16 comparisons allow only the independently quantized
one-code-value difference. The target-WB oracle probes each target neutral RAW
and checks serialized temperature/tint, rather than trusting GUI/Agent agreement
alone. Captured fake source WB and both input-file hashes remain unchanged.
This proves FINAL pixels, not GUI/CLI EXIF metadata equality.

Final binaries:

- `sony2fuji.dll`: `00d28658e99473e9727f278ed766840c696b2586525ae58f55cfa3effb406f54`.
- `sony2fuji.exe`: `ea89cc162dfc232680a9e6753056b45824065b433584c5a5fc73b4f1144882f3`.

## Resources And Limits

The VM had exhausted C:. User-authorized cleanup removed 244 historical managed
`bin/obj` directories, reclaiming 28.11 GiB and raising free space from 1.42 to
29.53 GiB. Source archives, RAW, current native cache, staging and validation
evidence remain. All 339 protected profile/RAW/archive/top-level-log records are
byte-identical before/after cleanup. No virtual disk resize or reboot was needed.

The final UI-only child took 20.01 s. At 250 ms sampling, maximum working set was
1,341,804,544 bytes and private bytes 1,267,040,256; the observed OS peak working
set was 1,443,614,720 bytes. These are one short process run, not a memory cap,
leak/soak test, large mixed-batch benchmark or GPU-memory acceptance result.

NOT REACHED: physical Windows GPU identity/performance/memory, physical OLE/file
drag input, real mouse/touch/pen and keyboard interaction, multi-monitor/DPI/Snap,
Narrator and actual OS high-contrast/text-scale changes, long-running memory soak
and broad camera coverage. The VM reports Microsoft Basic Display Adapter;
backend 3 or a legacy test's word "hardware" does not prove physical GPU coverage.
UI-only tests use the existing WPF fixture, not the real native interaction gate
required for the later comparison-default milestone. No hosted CI was run.
