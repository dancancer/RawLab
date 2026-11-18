# Windows Agent v08 Verification

## Scope And Sources

Milestone 1 (complete Agent v4) and milestone 2's bounded ordinary-image paths
have completed their functional validation. Milestone 3's single-preview behavior
is implemented and functionally verified. Its native desktop gate subsequently
passed on the connected VM and on physical host 125, including CPU/Force/Auto
runs, as recorded in Native Desktop Follow-up below. Earlier NOT REACHED results
remain historical evidence, not current completion claims. The first sections
record M1; the follow-up sections record M2/M3 separately. No push, PR update,
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

At the M1 checkpoint, NOT REACHED included physical GPU identity/memory and
native desktop interaction. The later desktop section supersedes those two
limits with physical-host measurements. Still NOT REACHED: physical OLE/file
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
those fixes. At that pre-desktop checkpoint the native desktop gate remained
open, rather than being counted as a functional-test pass. It is closed by the
separate native runs below.

Pre-desktop sampled binary SHA-256 values after that managed build:

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

## Native Desktop Follow-up (2026-10-16)

This follow-up changes only three Windows test sources; no production editor,
shared core, ABI, driver, display policy or firewall code/configuration was
changed. The source base is local `725fbda73d5920ced3f2ac350c610dbbfab3b1c3`.
The 519-file archive is `build/windows-agent-v08/native-desktop-source/source.zip`,
SHA-256 `691b3b9628161491b14d0efd48c85834e0c4d1d8b677a900d17acfb4adfb244f`.
At the Windows hash-audit checkpoint, 517 files matched; only the existing
implementation/verification Markdown files differed. All executable source,
tests and assets still match. README's GPU/native acceptance notes and this
acceptance prose were updated after that archive/audit and are not included in
its 517-file count.

The changed test-source SHA-256 values are:

- `tests/ComparisonDefaultChecks.cs`: `c4b11b7082639d3e80681a119f5c2510b858efcbf7c4a4fa6f49848dccfac776`.
- `tests/EntrySelectionChecks.cs`: `7ec423da467b51ef83eb8ce313b77942cda382a509194e7d4f3b4ef558a6cc3c`.
- `tests/ui-automation/Program.cs`: `aa9bf2a2607d51752f27cb45fe57249be80f06933a913a3f282deb845111ccea`.

The VM uses an actual logged-on RDP Session 1, not SSH Session 0. Temporary
InteractiveToken tasks run only this task's host/probe and were removed after
completion. Physical host 125 uses the existing authenticated RDP Session 2,
with the existing x64 Windows Desktop Runtime 8.0.11. No SDK/runtime installation
was needed there. The user confirmed certificate warnings themselves. Only the
explicitly authorized `physical-transfer` directory was redirected; its row was
removed, redirection disabled and the 125 RDP transport disconnected afterward.

### Failure, Fix And Gates

The first VM interactive run genuinely failed with exit 1: the native open
dialog is a child of the main window in the UIA tree, while the old driver only
searched the root's direct children. It timed out at OpenPhoto/FindDialog after
eight minutes. The fixed driver searches the owner children first, then the
root, always filtered by host PID, with a 15-second dialog lookup timeout.
The same VM's complete rerun passes. The noninteractive preflight regression
also failed before its fix, entering fixture/native initialization instead of
returning 2; after the fix, Session 0 returns NOT REACHED before creating profile
or WPF state. Default-journal admission still runs before that preflight.

The external driver now checks native comparison menu TogglePattern selection,
canvas RangeValue support, neutral-canvas visibility and the retained 35% swipe
divider after asynchronous exposure. CPU is the default; test-only environment
`RAWLAB_COMPARISON_GPU=Cpu|Auto|Force` selects the initial mode for both processes.
Force requires the completed RAW preview's actual GPU backend, never fallback.

| Run/Gate | Actual Result |
| --- | --- |
| Fresh managed host and independent UIA driver builds | Passed, zero warnings/errors; separate new outputs, no old managed DLL substitution. |
| VM `native-desktop-green` | Exit 0, 60 native UIA checks, first and restarted processes; default profile unchanged. |
| 125 `Cpu-20261016-015519` | Exit 0, 60 native UIA checks; RAW and raster backend CPU. |
| 125 `Force-20261016-015642` | Exit 0, 60 native UIA checks; each RAW open/reopen/restart uses D3D11, PNG/JPEG CPU. |
| 125 `Auto-20261016-015811` | Exit 0, 57 native UIA checks; logs confirm D3D11 on all RAW stages and CPU on raster. Auto intentionally does not require GPU availability. |
| Entry selection / default isolation / comparison default / profile isolation | 59 / 160 / 29 / 10 passed, respectively; all exit 0. |
| Default stores | VM's existing two files and 125's existing `folders.json` retain file lists, SHA-256 and modification ticks; no default journal/staging is loaded or changed. |

Each native run opens the real OpenFileDialog, switches RAW -> PNG -> JPEG ->
RAW, changes side/swipe via the real context menu, edits exposure through UIA,
and restores 1.25 EV in a separate restarted host. Routed-event functional
tests are not counted as native input. An initial 125 CPU run completed the
assertions but its orchestration recorded a null exit code; it is not a green
gate. The repeated CPU run above writes and verifies an explicit `exit.txt=0`.

The portable base archive SHA-256 is
`7ccbdd00fe011424fc1b8b82896805fc655f098189bd5813db7b4887b7bba141`;
the managed overlay is
`35180d7db1879d5e21e239af30be44f58647e4a051c6605d6528ceec5c9bdbbc`.
The physical runner validates every packaged file against the resulting binary
manifest before launch. Actual final binary SHA-256 values used by both hosts:

- `RawLab.dll`: `6e577a7f906d081f6408255fc088013a9704737ec4b451fa8790bc5c1a4f348f`.
- `RawLabWindows.Tests.dll`: `8eae362f1fcde5b54b7717f020d12774105490f8412451d85ad69ef24a8b989f`.
- `RawLabWindows.UiAutomation.dll`: `59544f3a4c8a957ee9b5f38ebc1896e053a318b957b6e279c037d63a0c4666d3`.
- `sony2fuji.dll`: unchanged `3731dfc1fbb1b69197a77a36e62881a4e7d82f9ca1c98d653b84f2a34cb4f7b4`.

### Physical GPU And Memory

125 reports NVIDIA GeForce RTX 4090 D, driver 616.56; `nvidia-smi` reports
49,140 MiB total memory. CIM also lists the RDP display adapter. A read-only
DXGI probe identifies NVIDIA PCI `10DE:2685`, subsystem `169710DE`, revision A1,
Flags 0 (neither software nor remote). The sampled RawLab PID instances map
exactly to its `luid_0x00000000_0x0000D355`. A second DXGI record has identical
device fields but another LUID; it is retained in the evidence, not guessed to
be a second physical card or the renderer's selected device.

GPUProcessMemory samples are taken roughly every 1.06-1.18 seconds, median about
1.1 seconds. Per-record values are summed only within the same PID/time before
taking maxima. Dedicated and shared columns are independent sample maxima, not
their simultaneous sum. Units below are MiB (2^20 bytes).

| Run/Host PID | Dedicated GPU Max | Shared GPU Max | Private Max | Working Set Max |
| --- | ---: | ---: | ---: | ---: |
| CPU first / 19852 | 61.12 | 11.34 | 769.54 | 820.17 |
| CPU restart / 5632 | 50.65 | 9.14 | 837.55 | 774.20 |
| Force first / 11808 | 558.75 | 417.40 | 1629.39 | 1155.32 |
| Force restart / 16436 | 137.70 | 83.40 | 860.43 | 815.21 |
| Auto first / 13848 | 558.75 | 86.75 | 1270.94 | 834.33 |
| Auto restart / 14480 | 128.09 | 69.43 | 860.92 | 825.54 |

The Force transient is materially higher than CPU in this short scenario, but
there is no measured accumulation after window/process closure. Prior host GPU
allocations sample down to zero before restart; the final independent audit at
02:00:47Z finds none of all eight sampled task PID processes or GPU counter
instances remaining. This is not a long-running leak or memory-upper-bound proof.
CPU mode itself has GPU allocations, so these are whole-process values including
WPF composition, not native D3D11-only allocations. No ETW/GPUView attribution
to individual queues/allocations was performed. Whole-card before/after readings
are about 1473-1474 MiB and are not substituted for RawLab process VRAM.

Evidence and reproducible private orchestration are retained under ignored
`build/windows-agent-v08/physical-transfer/`, `native-desktop-baseline/`,
`native-desktop-green/` and `desktop-regressions/`. These measurements do not
justify changing shared GPU allocation policy during a Windows-only task.

### Remaining Physical Acceptance

The listed native desktop workflows and physical-host GPU execution are covered,
but the desktop is delivered through RDP. On-site monitor/color-management/HDR
accuracy, actual Explorer OLE folder/file drag input, physical mouse/keyboard,
touch/pen, multi-monitor DPI/Snap changes, Narrator and live OS high-contrast/
text-scale changes remain unverified. Folder drag still has functional routed-
event regression coverage only. Long soak, large mixed batches, 64M images,
broad camera/driver coverage, and GPU device-loss/TDR recovery were not added to
this bounded run. No global SDK/runtime installation, driver/security policy or
fan settings on 125 were changed. No push, PR update, merge or release was performed
during this validation pass; later delivery requires separate user authorization.

## Development Integration Follow-up

This follow-up merges `development` at
`435feda1d6e44cc5a53a4a0c73208ce96fc6ee0b` into the Windows branch at
`7061b65187ae69707e2e2da3e3c214a66184a123`. The physical desktop/GPU results above
retain their original source scope, not new integrated-source physical coverage.
The new private VM workspace is `C:/RawLabBuild/windows-v08-integration-20261016`.
Later authorization permits commit, push and updating PR #53; this owner does
not merge, tag, release or deploy.

### Conflict Semantics And Repairs

Five conflicts retain both branches' contracts:

- `AboutWindow.xaml`: RUM consent/disclosure/privacy links and dynamic editor
  high-contrast foreground/muted/link resources.
- `BatchExportWindow.xaml.cs`: preflight-plus-running `BusyChanged`, per-run RUM
  completion before the final busy-owner release, and existing cleanup guards.
- `EditWorkflow.cs`: existing busy ownership/recovery plus per-run RUM counts;
  last-owner close waits for active rendering, not an intentionally unstarted
  pending preview.
- `MainWindow.xaml.cs`: image input admission, transform drafts and export reveal
  state plus successful RUM event boundaries and analytics drain before engine disposal.
- Test project: both `ui-automation/**/*.cs` and `usage/**/*.cs` compile exclusions.

Three failures were reproduced before repair: TestWindowState retained the
original analytics consent/transport; batch-last close could be stranded by a
pending preview; and journal cleanup failure after the active render retired
restored the window but left `Busy` with no active worker. Their expected exit-1
logs are `profile-isolation-red.log`, `close-pending-red.log` and
`close-recovery-red.log`. The final case explicitly has no deferred-content or
viewport-size fallback and compares recovered pixels with an independent CPU
render. `ResumePreview` pumps the existing request without submitting a revision
or rendering an unchanged idle editor again.

RUM regressions use real main/About/batch windows, private consent and a fake
transport, with no network events: one launch/import, changed/repeated film,
opt-out/re-enable, successful/refused single export, partial batch and repaired
retry, cancellation, interruption, terminal-before-busy-release ordering, and
in-flight drain before engine disposal. Profile isolation preserves original
consent bytes/timestamps and never starts its transport. Appearance includes
the new consent and links.

No shared runtime was manually changed by these integration repairs. Existing
core protection already covers recipe/input/CUBE look x direct/normalized/
symlink/hardlink x export/preview, 24 combinations. The only extra `lutools/`
edit makes permission/unsupported links explicit test skips; other I/O errors
still fail. A synthetic EACCES/ENOSPC probe proves this against old/new helpers.
No C++ math, ABI layout, other-platform UI or SDK runtime was manually changed
by these repairs; target-branch RUM changes are retained by the normal merge.

### Source Provenance

Ignored evidence is under `build/windows-agent-v08/integration-20261016/`.
Each manifest has 536 source/support files, verified on Windows before every
build/test phase. Archives contain no external RAW. The default native package
is newly built, not an older DLL overlaid onto current managed output.

| Snapshot | SHA-256 | Scope |
| --- | --- | --- |
| `source-native-baseline.zip` | `9fdd66c4a1726d024fd397a1ba8247f653db955c4f4163d5e506881f41b25ccb` | Full native/self-contained build and UIA driver build. |
| `source-close-red.zip` | `2966b3e6f795fc9ef1a9201ddc323da5f5eef730419d7a8cb86daf335139b650` | Complete base for all overlays; close-order RED and link helper. |
| `source-initial-green-delta.zip` | `a67c268acca005c681fc646f5636d804388a952cac10049a5f650c676af20aaa` | Three-file overlay on close-RED, initial complete matrix, tree `70ea11efe13eb4b2b46da3071e8a862465062dfc`. |
| `source-recovery-red-delta.zip` | `48477e5bc15cca417d23077094919ec56fc906c0e285372651803d8ca5bae2df` | Five-file overlay, pending-only journal-failure RED without ResumePreview fix. |
| `source-final-green-delta.zip` | `e5cbbfc87dac85829560f19738e45020496ca0e2828460ff09ba014096b77afc` | Six-file overlay, final executable tree `92a3e713e5ee7f59cd2ab07558390c1b238ae1ae`. |
| `source-assertion-green-delta.zip` | `17315ba22f11dbc581af04e97fe7b983ef25c0ddeb1179e89de44e77ac3ef8aa` | One test-file overlay on final-green; explicit recovery Revision invariant, tree `80545fca897bfd3777939c4bd7e0e2664f389447`. |
| `source-assertion-clean-delta.zip` | `6a4fbb64fb218a3120cc430fd3644fc77f44ff1be43c58e534d3d8329621b9d4` | Replaces the assertion overlay on final-green; same invariant with explicit non-null lock annotation, tree `f220c7c7eca05aea4593f1921a6f977f36fd8ee9`. |

These deltas are not complete ZIPs. Full-matrix manifest
`source-final-green-hashes.json` SHA-256 is
`4b69f47104e540d77aadb13a8b8712c176141ba396a21a9cad82d823aa012e0b`.
The assertion-only full manifest `source-assertion-green-hashes.json` SHA-256 is
`96df10b5975fb8906ec63d7d3341c0164411b1e92b88c1f5429ea749811952df`.
The final `source-assertion-clean-hashes.json` SHA-256 is
`dcac72173fb99db90e8b0b54832d350d3c11ba9f46bd08fd3afd59e27b7fd2d6`.
Native C/C++ sources/headers, CMake, shaders and runtime assets match the fresh
native-build baseline throughout. Only managed app/tests, the Python test helper
and README differ. Managed binaries are rebuilt and republished after production
changes. Later verification/checklist prose is documentation-only and outside
the executable source freeze.

### Initial Integrated Gates

The local SSH observer was interrupted during the long matrix. Its original
remote PowerShell continued to completion; all remaining process-exit files and
the final unchanged-profile summary were collected. No exit-0 is claimed for
the interrupted local wrapper. These are local Windows results, not hosted CI.
Initial logs are retained separately in `results-initial-green/`; later builds
in `results/` do not silently replace that source's zero-warning evidence.

| Gate | Recorded initial integrated result |
| --- | --- |
| Fresh native/default self-contained package | Exit 0; existing native dependency/MSVC warnings remain. |
| Managed test host, UIA driver and republish | Exit 0; both test builds zero warnings/errors. |
| Profile / default admission / entry selection | 13 / 160 / 61 checks, exit 0. |
| Comparison / appearance / About | 29 / 283 / 40 checks, exit 0. |
| Complete editor / isolated RUM owner | 188 assertions across 19 editor parts / 25 assertions including common entry checks, exit 0. |
| Agent / raster FINAL parity | 132 / 79 checks, exit 0. |
| Status layout / resources / runner selection | 384 / 23 / 37 checks, exit 0. |
| Portable usage, license fixtures, real default package | All exit 0; default output contains no local RUM SDK. |
| Release plus local SDK | Expected exit 1 at the explicit non-Release-only admission gate. |
| Display/Agent/recipe/CLI/schema CTest | 11/11 groups, 126.30 s, exit 0. |
| Complete schema with hash-verified private wheels | 8/8 tests, no skips, exit 0. |
| Link availability negative controls | Old helper expected exit 1; new helper exit 0. EACCES: 12 skips; ENOSPC: 12 diagnostic errors, zero skips. |

Embedded CTest schema can lack its optional module; the separate complete gate
closes that gap. The first RAW resource run records 632 samples, one warmup and
three cycles, with all closed windows collectible/native sessions disposed.
Peak sampled private/working set is 1,367,842,816 / 1,446,113,280 bytes; optional
preview cache 131,358,720 bytes is within its existing 256 MiB budget. Collected
private memory is 49.06, 53.47, 50.59 and 50.15 MiB. This short run proves neither
a process-memory cap nor long-soak leak freedom, physical GPU attribution or a
performance improvement.

### Final Recovery And Assertion Gates

On tree `92a3e71`, the new managed build and self-contained republish both exit
0. This test build has one CS8602 nullable-flow warning at the recovery fixture's
journal lock, not a production build error. The complete editor rerun passes 195 assertions across all 19 parts,
comparison passes 29 checks, resources passes 23, and the actual default-package
license gate passes. All four process exits are 0. Logs are
`editor-review-final.log`, `comparison-default-final.log`, `resources-final.log`
and `default-package-license-final.log`; `summary-recovery-green.json` confirms
the default profile is unchanged. The retained recovery RED is now collected
with its actual failure assertion and exit 1, not just its outer-run summary.

An independent reviewer then requested an explicit unchanged-Revision assertion
in the recovery branch. This changes only one test file: tree `80545fca` has
identical runtime source to `92a3e71`. Its test build exits 0 with the same one
warning, and the selected `close-pending` run passes 21 assertions/exit 0, including recovery
pixels, all three successful close orders and no new revision. This test-only
increment does not trigger another complete editor/Agent/raster/native/package
run. Its evidence is `managed-build-managed-assertion.log` and
`close-pending-assertion.log` with `summary-assertion-green.json`.
The fixture then makes its established non-null lock invariant explicit with
`!` (no runtime behavior change), tree `f220c7c7`. The final test build has zero
warnings/errors and the same selected 21 assertions pass again; see
`managed-build-managed-clean.log`, `close-pending-clean.log` and
`summary-assertion-clean.json`. The earlier warning logs remain retained.

Because the private helper is linked into the independent StartupUri executable,
that executable is also freshly rebuilt (zero warnings/errors). Its 22
existing-journal/staging admission checks, 160 six-language startup/UI checks
and the build-script PowerShell parser gate all exit 0. See
`localization-ui-build.log`, `localization-admission.log`, `localization-ui.log`,
`build-script.log` and `summary-standalone.json`. The real default profile's
entire before-first-RED and after-final-clean file/hash/write-tick snapshots
match byte-for-byte across all phases, including standalone startup, not only
within each individual test process. The final task-path/command-line process
audit has no remaining test workers; no unrelated process is stopped.
The local remote-packaging unittest and Python syntax check also pass; their
outputs are retained in `local-remote-packaging.log` and `local-python-syntax.log`
in the task evidence directory.

The final CPU resource rerun records 637 samples, one warmup plus three cycles,
all four windows collectible and native sessions disposed. Peak sampled
private/working set is 1,369,296,896 / 1,448,583,168 bytes; optional cache remains
131,358,720 bytes. Collected private bytes are 52,600,832, 57,085,952, 56,016,896
and 55,767,040. Recorded non-warmup cycles take 16.58-16.63 s, not a benchmark
speedup claim. No process/native/GPU cap or long-soak conclusion is inferred.

Final package/test binary SHA-256 values:

- `RawLab.dll`: `c18d00bb21f29f15b77b84b7d7c853af2892fd43d70f5e4c3e656a2222d1f1aa`.
- `RawLabWindows.Tests.dll`: `aa9d8c3a3fa05026b5e1766fb34277ba87cca914c81253b64fbaa8f565307306`.
- `sony2fuji.dll`: `06dacb38dd6fe0836e968a05890983ada2275ec9ddbc67575040807df477d776`.
- `sony2fuji.exe`: `bbbcb2ba93bc62a19628cbc3f62fc1629a8c84b759a49558c42d807c33be8645`.

The final merge differs from tree `f220c7c7` only in this verification document
and the implementation checklist; runtime, tests and assets remain frozen.
Unchanged native/core and earlier physical experiments retain their respective
source scopes. No new physical GPU matrix or local-SDK network-delivery run is
claimed. On-site color/HDR, Explorer OLE and real SaveFileDialog/input-device
workflows, multi-monitor DPI/Snap, Narrator/live OS contrast/text scaling, long
soak/large queues/64M inputs and device-loss/TDR remain unverified here. Existing
RUM copy localization remains a known release follow-up. Hosted CI status must
be checked against the pushed head; an empty check set is not a CI pass.
