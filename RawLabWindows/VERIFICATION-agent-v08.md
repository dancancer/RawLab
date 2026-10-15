# Windows Agent v08 Verification

## Scope And Sources

Milestone 1 (complete Agent v4) and milestone 2's bounded ordinary-image paths
have completed their functional validation. Milestone 3's single-preview behavior
is implemented and functionally verified, but its real native interaction gate
is NOT REACHED because no interactive desktop is available. The first sections
record M1; the follow-up section records M2/M3 separately. No push, PR update,
merge or release is authorized by this record.

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
| Default profile | Existing `Edits/edits.json` and `updates.json` retain identical file lists, SHA-256 and modification ticks before/after. No default journal exists. |
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

M1 verified binaries:

- `sony2fuji.dll`: `00d28658e99473e9727f278ed766840c696b2586525ae58f55cfa3effb406f54`.
- `sony2fuji.exe`: `ea89cc162dfc232680a9e6753056b45824065b433584c5a5fc73b4f1144882f3`.

## Resources And Limits

The VM had exhausted C:. User-authorized cleanup removed 244 audited historical
managed `bin/obj` directories (27.88 GiB of listed file contents). C: free space
increased by 28.11 GiB, from 1.42 to 29.53 GiB immediately after cleanup; later
builds consume space again. Source archives, RAW, current native cache, staging
and validation evidence remain. The two independent protection snapshots contain
339 byte-identical profile/RAW/archive/top-level-log records. The cleanup JSON's
`protectedFiles=1` is a PowerShell pipeline-count bug, not the protection count.
No virtual disk resize or reboot was needed.

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

## Ordinary Images And Comparison Follow-up

Milestones 2/3 add a Windows-only WIC adapter and keep the shared DISPLAY_BUFFER=2
contract. CMake selects the adapter only on Windows. GUI and CLI share its full
decode; thumbnails share its strict preflight/orientation/color path with bounded
output. RAW-only settings are normalized on a per-target clone, not written into
the captured mixed-batch recipe. A single owned RGBA8 source is released on
replacement, RAW/raster transition, native decoding failure and Dispose. A file
metadata failure before decode can retain the last bounded cache, but does not
publish it as the failed input. This is not a bound on
WIC internals, native float intermediates or total process memory.

The Windows declared formats are JPEG/PNG/classic single-page RGB8 TIFF. HEIF,
BigTIFF, alpha below 255, non-RGB, higher bit depth, floating-point and marked HDR
or multi-frame inputs are refused. Unsupported/ambiguous profiles and non-sRGB
PNG gAMA/cHRM without a supported ICC are refused, not silently flattened.
ICC coverage is explicitly bounded; this is not a claim to accept every legal
ICC class/TRC/LUT encoding. Apple Display P3 is the external non-sRGB fixture.
The ordinary CTest also generates a mandatory matrix/TRC ICC v2 profile with
P3-like D50-adapted primaries and gamma 2.2, then checks PNG/JPEG/TIFF without an
optional ICC skip. It is not claimed to be the exact Apple Display P3 transfer
function. Both references use WIC's CMM: they independently exercise embedding,
metadata discovery and once-only sRGB conversion wiring, not independent CMM math.

| Snapshot | Source ZIP SHA-256 | Actual Result |
| --- | --- | --- |
| `raster-red-20261016-003319` | `18aad802cd929bc874aae889818265866c42c1c30f630540585fdb69a9e7cb8f` | Fresh managed test entry fails at missing IsRaster/IsImage, not a fixture failure; 148 common-admission checks pass. |
| `raster-green-20261016-004921` | `915374e28088b53b5fef8606561bea11193aa16a38f16354bd58d414623200cb` | Real MSVC DLL/CLI, 88 native decoder checks with mandatory P3 PNG, six CLI groups pass in 125.36 s. Managed raster gate fails because the harness incorrectly copied an older packaged RawLab.dll over the fresh app. Not a managed green. |
| `raster-managed-20261016-005336` | `744f07fcb1e8ceadbd77664bfeca7d92c3af4c68528eb58aa688ae47e3ea8600` | Harness copies only native DLLs/CRT; 67 raster checks and 160 admission checks pass, default profile unchanged. Comparison test reaches the expected new-window default RED. |
| `final-20261016-005622` | `42fba5af430a2e2ab633e7181ce4b98b0b3e2e83f5e4b730c5651ac74535f712` | 518 hash-checked files; 96 decoder, 7/7 CLI groups (125.68 s), 132 Agent, 67 raster and 37 runner checks pass. Comparison test fails because it incorrectly raises Button.ClickEvent on a MenuItem; later gates are not reached. Not an overall green. |
| `closure-20261016-011011` | `0c8b15cfe8eb6dce2717554f538678fedd44618d8fb8fe761755c7caf603159d` | 519 hash-checked files; 96 decoder checks, default ICC CTest 1/1, 68 raster, 27 comparison and 37 runner checks pass. Editor-review times out waiting for an offscreen source thumbnail in a contaminated fixture; later gates are not reached. Not an overall green. |
| `remaining-20261016-011913` | `276078643738062e38e2b72d4b4b15ee59a7b93036379a06c96b86e618bae649` | 519 hash-checked files; 68 raster, 23 resources, 40 About, six-language catalog, 98 UI-only and 160 isolation checks pass. Formal native UIA entry returns 2 / NOT REACHED; the two existing default profile files remain unchanged. UIA build has four warnings, corrected in the subsequent test-only closure. |
| `editor-final-20261016-012418` | `8eb1213154ba486dde73feb674d1a2d9adc7f99931669f1be7fa580a58b6af20` | 519 hash-checked files; 153 editor assertions across all 17 scenarios, 10 profile, 384 status layout, 262 appearance, 37 runner and 160 isolation checks pass. Managed host and UIA driver build with zero warnings/errors. Native entry returns 2 with the captured reason `No interactive desktop window is available.` Default profile unchanged. |
| `raster-final-20261016-013401` | `326debdade3ea4a610cae0761a1a8b85fbbbf056c27e43ca62e57b9f7833f970` | 519 hash-checked files; 79 raster checks now include classic TIFF managed identity/thumbnail, GUI-renderer/CLI FINAL parity and four-target frozen RAW/PNG/JPEG/TIFF batch parity. Fresh managed build has zero warnings/errors; 160 isolation checks pass and default profile unchanged. |

Earlier native attempts are retained, not counted as green: the first rejected
valid WIC sRGB+gAMA PNG, then the float-TIFF WIC encoder fixture terminated before
emitting a complete TIFF. The final fixture uses the existing pinned libtiff to
write actual IEEE float samples and requires rejection without an optional skip.
An intermediate PowerShell Process.ExitCode collection bug also kept that run
non-green despite its 87 assertion lines. Direct System.Diagnostics.Process exit
collection now gates the real exit code. The harness additionally checks that
the fresh managed RawLab.dll was not replaced by an old packaged managed DLL.
The native rebuild still emits the existing MSVC C4127 constant-condition warning
in shared `sony2fuji_c.cpp:1406`; it is not represented as a warning-free native
build and was not changed as part of Windows integration.

The editor timeout was a test-fixture regression: earlier scenarios created
profile directories and PNG exports next to the two RAW inputs. The newly
broadened image tree put the selected RAW below the visible viewport, where
loading its thumbnail would be incorrect. The same pre-fix binary passed the
individual close-journal scenario. The full-suite fix separates `output/inputs`
and asserts exactly two source photos, preserving real visible-thumbnail
scheduling and the journal failure/pending resize recovery path. The full suite,
not merely the individual scenario, then passes all 153 assertions.

The raster regressions independently decode GUI-renderer/CLI/frozen BatchRunner
PNG16 outputs and compare same-sized FINAL pixels exactly. They cover saved
recipe restoration, RAW/raster switching, absent RAW WB/baseline/lens, source
hash preservation, damaged-file recovery and actual source-buffer release.
The short 3MP preview exercise records six timings and memory samples; source
and optional preview-cache bounds are asserted. It is not a working-set limit
or a long-running leak/64M-input/GPU-memory proof.

The raster-final 2048x1536 CPU preview takes 285.52 ms cold and 144.16-147.02 ms for
the next five calls. Its owned RGBA8 input is 12,582,912 bytes and cached preview
307,200 bytes. Post-call working-set samples are 111,996,928-113,332,224 bytes;
private bytes 66,818,048-68,382,720. The process OS peak is 1,332,305,920 bytes,
including earlier mixed FINAL work, so the small post-call samples are not a
decode/render peak-memory claim. No performance improvement is inferred.

The separate real-RAW CPU resource run uses one warmup plus three editor cycles,
632 samples and 23 passing checks. Every closed window is collectible after the
dispatcher/timer drain, and its native engine is disposed. Sampled peaks are
1,368,256,512 private bytes, 1,447,038,976 working-set bytes and 131,358,720 optional
preview-cache bytes, below the existing 256 MiB cache budget. These observations
do not establish an overall memory cap or exclude every long-running leak. After
each close/collection cycle private bytes are 50.3-54.4 MiB. The retained
`resources.json` identifies its scope and every round, including the warmup.

Comparison defaults are reset only at new/open/restore boundaries. Same-image
adjustments and async publication do not reset a manual side/swipe choice.
Both menu locations, button selection/ItemStatus, label alignment and canvases
share one state refresh. A cancelled transform prompt restores the check marks.
The separate native UIA project has no application-assembly reference and uses
real HWND/UIA controls and the Windows common OpenFileDialog, not RaiseEvent.
Its host redirects all stores before showing the window and uses a separate
process for profile-restart acceptance. Routed-event/drop/batch tests remain
functional regressions, not physical OLE/keyboard acceptance.

Windows commands actually executed from the prepared workspace include:

```powershell
dotnet build RawLabWindows/tests/RawLabWindows.Tests.csproj -c Release --no-incremental
dotnet $runner --agent-recipe $repo $raw $cli
dotnet $runner --raster $repo $raw $cli
dotnet $runner --comparison-default $repo $raw
dotnet $runner --editor-review $repo $raw
dotnet $runner --resources $repo $raw
./RawLabWindows/tests/RunnerSelectionChecks.ps1 -Output $results/runner
./RawLabWindows/tests/run-comparison-native.ps1 -RawPath $raw -NativeArtifacts $native -Output $results/native-entry
```

Here `$runner` is the freshly built test DLL, `$raw` is the external read-only ARW
and `$cli`/`$native` point to the actually built native output. The native decoder
probe is executed both directly with the external Apple ICC and through CTest
without that argument. CTest's seven CLI/render/schema groups are run separately
from the mandatory generated-ICC decoder gate. Named profile/layout/appearance,
About/catalog/UI-only and admission commands have individual logs. The 132 RAW
Agent checks are not needlessly repeated after later GUI/test-only changes.

The two readonly reviewers' concrete integration findings were closed together:
mandatory ICC coverage in default CTest; actual owner/AddInputs/primary-action
mixed export assertions and accurate raster labels; RAW Force GPU -> raster
visible CPU selection with RAW selection restoration; and an independent native
runner that captures the external driver's exit/reason and preserves default
profile files. No parser, shared rendering math or ABI layout was changed for
those fixes. The native desktop gate remains open, not a functional-test pass.

Final sampled binary SHA-256 values after the last managed build:

- `sony2fuji.dll`: `3731dfc1fbb1b69197a77a36e62881a4e7d82f9ca1c98d653b84f2a34cb4f7b4`.
- `sony2fuji.exe`: `cd5ca9232e9f5de7b40302f2dcb48bc26f17c25a0ed3c8c072704c2f98b457cd`.
- App and test-output `RawLab.dll` both: `fb68357bfca99847ba24267163ef705be282733c5183993a39aabe1e06f78766`.
- `RawLabWindows.Tests.dll`: `8b36773cd9a9a1e3ff6def35ea125b0bbc8c4678367ac941c3ef7a8a617bb5c3`.

The final process audit finds no task-owned product/test/CLI/CMake workers. C:
has 29,327,028,224 free bytes (27.31 GiB) after validation. PR #53 is still OPEN
against `development` at `3199c915d20b77f38c00a6b7c1edbc9a286807ea`, with no
hosted checks reported; no push or PR mutation was performed.

The M2 decoder scope does not claim unmarked/adversarial HDR-profile recognition,
hostile metadata decompression peak bounds or full 64M-input acceptance. Native
CMYK JPEG and HDR/gain-map marker probes are preflight/header refusal controls,
not complete HDR/gain-map image fixtures; complete RGB8 TIFF and float/CMYK TIFF
fixtures are separately exercised. HEIF is not advertised or accepted.
