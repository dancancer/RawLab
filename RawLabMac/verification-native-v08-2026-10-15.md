# RawLab 0.8 macOS Native Acceptance

## Scope and isolation

- Date: 2026-10-15 (Asia/Shanghai).
- Session: `01a13d7e-530a-77d0-b2b4-ff08a2865ffa`.
- Source: `0856eadf165129eeed276f473ce7f38588c56866`.
- Branch: `feature/macos-v08-native-acceptance`.
- Worktree: `/Users/xupeng/.codex/worktrees/macos-v08-native-acceptance/rawtools`.
- Preserved old worktree: `/Users/xupeng/mycode/rawtools/build/macos-v08-editor`.
- The old worktree was clean at audit; its actual HEAD matched the source above.
- The old session confirmed that it had stopped all desktop/CUA, build and edit activity, with no running child agents or acceptance application.
- `origin/development` was refreshed without rebasing or merging. This continuation intentionally starts from the verified macOS implementation, not the integration branch.
- Root `AGENTS.md` and `agent.md` were read from the implementation tree. The main checkout currently has no root `AGENTS.md`; no file was added there.

## Existing evidence (not rerun)

The old tree's `build/local-verification.json` and `build/empty-state-copy-verification.json` record the standard build, 132 draft regressions, 50 perspective checks including actual Metal, 72 six-language view snapshots and 12 empty-state snapshots. These are inherited evidence, not new native-input passes. Their historical lock-screen conclusions are not reused for the present desktop state.

## Test assets

- Private RAW copies: `build/native-acceptance/fixtures/acceptance-a.DNG` and `acceptance-b.DNG`.
- Independent outputs: `build/native-acceptance/exports/single` and `exports/batch`.
- Private home: `build/native-acceptance/home`.
- A Foundation probe with `CFFIXED_USER_HOME` confirmed that `NSHomeDirectory()`, the user application-support directory and `homeDirectoryForCurrentUser` resolve under the private home. The actual acceptance process also exposed this environment variable, and Apply wrote its registry under this private home.
- No RAW, screenshot, generated build or output file is committed.

## Current stage

Latest checkpoint: the precise-crop focus teardown fix is committed in `0f8a912997b9cb362309b01f7c7d08e78036ca59`; affected regression 171/171 and real native legal/invalid correction checks passed. PNG and rendered DNG exports are verified in `34df9530cdcfccc46b1f35c82287846ca92fd493`; post-unlock native batch cancel/retry/crash recovery is verified in `8606068c4876cf13b883527459b37c5b4c872b1b`. Human hand-drag plus Apply also succeeded. The separate intermittent CUA pointer-release Apply refresh failure remains open; its captured callbacks were on the main thread. No speculative thread or delay fix has been shipped.

The initial worktree build completed with exit 0 and `PASS: all non-system dynamic dependencies are bundled and signed`, logged in `build/native-acceptance/build.log`. The build script's built-in DNG check also passed; the inherited 132/50/snapshot suites were not rerun at that initial checkpoint.

The initial generated app was copied to `build/native-acceptance/RawLab Mac Acceptance.app`, with only bundle identity/name, `LSEnvironment.CFFIXED_USER_HOME` and ad-hoc signatures changed. `codesign --verify --deep --strict` passed. The initial original and acceptance executables had identical `__TEXT,__text` dumps (SHA-256 `54bf5e1e17c07316eb650389c24fdf2ab53278fce812693909dfc9a757001fa5`). Whole-file hashes differ because of re-signing. The later window-close fix and final build are recorded below.

Native acceptance is in progress. At initial launch the app returned live AX state and window screenshots without a lock-screen or approval blocker. Initial background-app attempts at coordinate drags, wheel input, several native menu selections and global shortcuts did not produce the expected transition. The user subsequently confirmed bringing the acceptance app to the foreground. Shortcuts, menus, pointer drags and wheel input then worked; the initial failures are not classified as application defects. The optional documented `cua.computer.launch_app` method is unavailable in this runtime (`is not a function`). No security setting or permission was reset.

## Native-input matrix

| Item | Status | Required observation |
| --- | --- | --- |
| Open button, File menu, Command-O and cancel | PASS for exercised paths | Button/menu opened the system panel; button and Escape cancel returned to empty state. Foreground Command-O was repeated successfully across diagnostic and final builds, including Escape then reopen. Earlier background attempts are not app failures. |
| RAW import and drag/drop | PASS for exercised paths; human-assisted drop | A imported by native file-list double click; B imported by selected row + Return; A reopened by selected row + Open. The user physically dragged private B from Finder into the empty final-build editor; subsequent live CUA AX/screenshot confirmed its full private path, rendered preview and enabled editing controls. Drop during an active draft was not exercised. |
| Eight crop handles and in-frame move | Movement PASS; release-to-Apply FAIL, intermittent | All nine regions changed correctly with actual pointer drags and Tab/direction keys; Shift-Up fine resize observed. An earlier all-nine replay kept Apply enabled, but the latest non-instrumented first TL drag reproduced disabled Apply without busy/invalid state. A grid toggle refreshed it. See separate open pointer-release investigation; do not treat the prior replay as a complete pass. |
| Aspect presets and orientation swap | PASS for exercised path | Native 16:9 selection produced W/H 99.0/55.7 percent on square canvas; swap produced 55.7/99.0 percent with portrait selection visibly confirmed. Other presets not repeated. |
| Rotation ruler and wheel | PASS for exercised path | Actual ruler drag changed 3 to 0 degrees; Right changed 0 to 0.1; wheel up 1 over numeric field changed 0.1 to 1.1. Shift-wheel and full-range traversal not claimed. |
| Draft Apply and Cancel | PASS for exercised path | Apply saved crop +3 degree rotation; Cancel discarded subsequent nine-region keyboard edits. Reentry restored the applied geometry. |
| Leave Apply/Discard/Stay | PASS for panel-collapse path | Native three-choice sheet: Stay retained draft; Discard discarded and collapsed panel; Apply-and-leave saved horizontal flip and collapsed panel. Other departure triggers remain separately scoped. |
| Window close and application quit protection | PASS for exercised paths after fix | Foreground Command-W displayed prompt and Stay retained draft. Native Discard and Apply closed the actual window, proven by same-window lifecycle callbacks and `isVisible=false` before another CUA state query. Native Quit/Stay/Discard/Apply succeeded; both completed Quit paths have process-exit evidence. |
| Save and reopen recovery | PASS for exercised path | A -> B -> A and full Quit/relaunch/open restored crop X/Y 3.0 percent, W/H 97.0 percent, +3 degree rotation and horizontal flip. Discarded vertical flip remained off. |
| Comparison | PASS | Live screenshots confirmed side-by-side neutral/PROVIA and return to single-image presentation using the toolbar control. |
| Single export | PASS for exercised JPEG, 16-bit PNG and rendered DNG original-size paths | Native export menus/save panels, private destinations and success feedback; files independently decoded and checked. See format follow-up below. |
| Batch export | PASS for exercised JPEG and PNG cancel/retry/recovery paths | Original two-photo JPEG plus eight-photo PNG native run: cancel at 2/0/6, controlled process interruption, relaunch recovery at 4/0/4, missing-private-copy failure at 7/1/0 and native Retry to 8/0/0. Independent journal/output checks passed; process termination and file rename are explicit fault injections, not keyboard/mouse passes. |
| Tab focus and available accessibility | PASS for exercised crop Tab cycles; accessibility PARTIAL | Actual forward/reverse Tab reached all nine crop regions, rotation and four expanded precise fields. Normal editing Tab cycled the exposure field under current system settings. Crop AX adjustment worked, but handle descriptions remain generic PROVIA and precise child identifiers repeat the disclosure ID; full button traversal/VoiceOver quality is not accepted. |

VoiceOver, increased contrast or global keyboard-access settings will not be enabled or changed as part of this task. Unavailable coverage will be recorded rather than inferred from snapshots or model tests.

## Native observations and evidence

The CUA calls and live screenshots are retained in this session's tool transcript. Useful call titles, in chronological order:

1. `Launch isolated RawLab acceptance app`: live empty editor and localized Open RAW button.
2. `Test empty-state Open RAW button`, `Cancel button panel and inspect File menu`, `Test File menu opening, cancel, and Command-O`: actual `open-panel` dialogs and cancellation.
3. `Focus native path field and type fixture path`, `Confirm private RAW path`: native Go To sheet and fixture list. A path-only selection followed by Open initially returned to empty state; later explicit file-row selection + Open succeeded. No root cause or code fix is inferred from that initial attempt.
4. `Import RAW by double-clicking selected native file row`: rendered A, `1024 x 1024`, PROVIA and histogram.
5. `Toggle comparison and enter geometry draft workspace`: live crop overlay and disabled comparison/zoom during draft; export help states the draft restriction.
6. `Audit current native Tab focus order without changing global settings`: eight handles, move region and rotation text field all traversed. AX descriptions currently say `PROVIA`, while the Help and IDs identify each handle; screen-reader announcement quality is not accepted without VoiceOver.
7. `Type rotation into the Tab-focused native field`, `Commit rotation with Tab and test native numeric wheel input`: +3 degrees committed; wheel produced no change.
8. `Apply the native geometry draft`: saved feedback and return to ordinary editing. Actual private registry: `build/native-acceptance/home/Library/Application Support/RawLab/Edits/edits.json`.
9. `Import private RAW B with native Return confirmation`, `Confirm selected RAW A using native Open button`, `Reenter geometry workspace and verify restored parameters`: restored crop X/Y 3.0 percent, W/H 97.0 percent and +3 degree rotation.
10. `Test keyboard resize on all eight crop handles and move region`: each keyboard action visibly changed its expected coordinate/dimension. `Check fine crop key input and cancel the geometry draft`: fine input changed height 88.8 to 88.6 percent, then Cancel returned to ordinary editor. Reentry returned to committed 3.0/97.0 percent geometry.
11. `Trigger geometry departure prompt by collapsing adjustment panel`, `Stay in the native geometry draft`, `Discard draft and leave the geometry workspace`: native sheet and observed decisions.

Private and original RAW SHA-256 at setup and after export: `0ecdc8087d566c5ba39f9bd40eef4dfc5f3884ccb016f311a606508751c79eaf`. The user's existing `~/Library/Application Support/RawLab/Edits/edits.json` remained `1bc106526236f30b335af381446385ea4b0a8fc3131abad4bc2fceda55ad6e52`. The private registry hash at the first Apply/Cancel/Discard checkpoint was `7c766c81bbfcd5c5c70f03a57a8272c670b519e319a0a3311db5b0ec8274e1a3`; after the later Apply-and-leave of horizontal flip it became `90f0b4376758c9b671669d1fc6a64e01279aed2b1d26befd9015f58a7ec599ac`, unchanged by Quit/Discard, relaunch or batch export.

## Foreground phase evidence

- `Apply draft and leave via native confirmation sheet`: saved horizontal flip and collapsed panel.
- `Verify visible before-and-after comparison view` and `Verify comparison returns to single-image presentation`: live two-pane and one-pane screenshots.
- `Invoke native Quit with unapplied geometry changes`, `Cancel native Quit by choosing Continue Editing`, `Discard unapplied draft and finish native Quit`: native prompt, retention and process exit. CUA reported `procNotFound` after successful Quit; `pgrep -x RawLabMac` returned no process. Relaunch and `Verify crop, rotation and flip state survived application restart` confirmed saved geometry and no discarded vertical flip.
- User foreground confirmation preceded `Open JPEG save panel from foreground keyboard shortcut`. `Save native JPEG export to private output directory` returned native exported feedback.
- `Verify batch selection controls and run the two-photo export` and `Verify native batch export completion status`: actual batch run, completed 2/0/0.
- `Verify foreground top-left crop handle pointer drag`, `Check whether a second crop-edge drag starts after release`, and the subsequent paired handle-drag calls: all eight handles and move changed the expected values. The retained disabled Apply state is under investigation, not a pass.
- `Apply native 16:9 crop preset`, `Verify committed aspect preset and orientation control`, `Swap the native crop aspect from landscape to portrait`: preset and swap confirmed in live AX state and screenshot.
- `Drag the native rotation ruler`, `Test ruler keyboard step and native rotation numeric wheel`, `Apply one native wheel scroll over the rotation value`: actual angle changes.

Independent output checks (read-only subagent; no UI automation or model calls):

| Output under `build/native-acceptance/exports` | Bytes | SHA-256 |
| --- | --- | --- |
| `single/acceptance-a-PROVIA.jpg` | 3977500 | `fb45c6b988dc0a67baa081e334a5845f81de3de31824241a3163124db4aa9c93` |
| `batch/acceptance-a-PROVIA.jpg` | 3977500 | `9d812984d666bd041f3d1ebac72c775e090631767bd208f89b137cc865891c56` |
| `batch/acceptance-b-PROVIA.jpg` | 3977500 | `fb45c6b988dc0a67baa081e334a5845f81de3de31824241a3163124db4aa9c93` |

All three decode as 2835x2835, 8-bit JPEG. FFmpeg decoded-pixel comparison of each batch output against the single output gave MSE 0, PSNR inf and SSIM 1.000000. Nonblank decoded luminance: min 1, max 240, average 111.238. File bytes may differ because of metadata; pixel equivalence is the asserted contract.

## Window-close repair and verification

- Confirmed defect: the old close retry ran while the SwiftUI confirmation sheet was still attached. `build/native-acceptance/home/native-callbacks.log` records `close retry ... sheet=true`, followed by `visible=true` and no later retry.
- Minimal macOS repair: retain only a weak pending window, forward `windowDidEndSheet` to the prior delegate, then retry on the main queue after checking the window's delegate, sheet and pending-draft state. The model's departure timing and other platforms are unchanged. AppKit defines this callback as notification that the sheet has closed: [Apple documentation](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidendsheet(_:)).
- Regression RED: `build/native-acceptance/close-regression-red.log`, exit 133 from the test's top-level failure, specifically `native close completes after sheet dismissal except for Stay (discard)`. This was a behavioral assertion failure against the old guard, not a compile failure.
- Regression GREEN: `build/native-acceptance/close-regression-green.log`, exit 0, **154 checks passed**. This is the affected 132-check draft suite plus 22 window checks: Discard/Apply/Stay, prior-delegate callback counts, and an unrelated sheet after Stay. These AppKit integration checks are not counted as real keyboard/mouse acceptance.
- Build: `build/native-acceptance/final-build.log`, exit 0 and bundled/signature validation passed. The prior 50 perspective and snapshot suites were not rerun because no renderer, layout or localization changed.
- Independent read-only review found no evidenced code defect in the final guard/test diff. The reviewer identified the SwiftUI lifecycle gap in programmatic tests; the real native checks below address the exercised paths.

Native lifecycle verification used temporary logging only, built in `build/native-acceptance/window-lifecycle-build.log` (exit 0). Real CUA Command-W and native prompt buttons produced:

- `Discard the draft without a follow-up AX query`: window 8304, object `0x0000007972abc600`, `departureAction sheet=true` -> `didEndSheet sheet=false` -> `retryClose` -> `willClose` -> `afterRetryClose visible=false`.
- `Apply and close without causing a query-driven window reopen`: the same ordered events and `visible=false`; the private registry contained vertical flip `true` afterward.
- Evidence: `build/native-acceptance/home/window-lifecycle.log`, first 7 lines for Discard and next 7 for Apply. Native input caused the actions; the app's own lifecycle log proves completion without an additional UI automation method.
- A subsequent CUA `getAXState` re-shows the closed editor window. Thus a visible editor returned by that query alone is not reliable evidence that closing failed. An initial suspected second repair was rejected; no broader model/action deferral was shipped.
- `Apply the draft and complete native Quit`: the prompt applied vertical flip back to `false`, and `pgrep -x RawLabMac` returned exit 1. Final private geometry is the original saved 3.0/97.0 percent crop, +3 degrees, horizontal flip on, vertical flip off. Private registry SHA-256 is now `a0cdaa46e6ea8354adab553249a211d30085cd41a5ee54ffcbbf21e2284ba63e`; user registry is still `1bc106526236f30b335af381446385ea4b0a8fc3131abad4bc2fceda55ad6e52`.

All temporary logging was removed. Both generated bundles were restored to the non-instrumented final-build executable and re-signed/verified. Their `__TEXT,__text` dump hashes match: `b90c293e2c63724b1ffdbc1fd49aa3a222a597e1b093227baf2a58c1d8e22888`. No generated artifact is staged.

Final crop replay evidence: `Replay all nine native crop drags and inspect Apply after every release`, followed by focused-numeric-field pointer checks. All nine releases preserved enabled Apply. An intentionally invalid numeric entry (`4+3`) correctly disabled Apply, preserved the draft on Stay and allowed Discard; it is not the earlier unexplained observation.

## Human-assisted native RAW drop

- On 2026-10-15 the user confirmed `已拖入` after being asked to drag `acceptance-b.DNG` from the task-created private fixtures Finder window into the empty `RawLab Mac Acceptance` editor.
- `Verify the human-performed private RAW drop in the final app` captured live AX state and a window screenshot. The status line was `acceptance-b.DNG 预览 1024 × 1024 · sRGB`, with Help pointing to `/Users/xupeng/.codex/worktrees/macos-v08-native-acceptance/rawtools/build/native-acceptance/fixtures/acceptance-b.DNG`. The image was visibly rendered, the RGB histogram was populated, and geometry/comparison/export controls were enabled. No error or busy state was present.
- This is a real human-performed Finder drag followed by CUA result verification, not an automated CUA drag, model function call or offscreen snapshot. The app was the non-instrumented final build from the preceding phase; no source or build change was needed.
- Independent read-only post-drop audit confirmed all three RAW hashes are still `0ecdc8087d566c5ba39f9bd40eef4dfc5f3884ccb016f311a606508751c79eaf`, each 19,545,856 bytes. User registry remains `1bc106526236f30b335af381446385ea4b0a8fc3131abad4bc2fceda55ad6e52`; private registry remains `a0cdaa46e6ea8354adab553249a211d30085cd41a5ee54ffcbbf21e2284ba63e`, containing only the saved A record. The old implementation worktree remains clean at its original HEAD.

## Remaining coverage and handoff

### Follow-up crop investigation

- Continued from `b6f7a716ab56591b0135038444eaf6a2e2b59783` in the same isolated worktree. Before instrumentation, 20 alternating native TL drags and legal uncommitted rotation input followed by crop dragging did not reproduce the stuck state.
- A stable failure was then observed twice: open precise crop, type a legal width `80` without Enter/Tab, collapse the disclosure, then drag TL. The legal width is lost and Apply remains disabled with a busy indicator.
- Buffered diagnostic evidence: `build/native-acceptance/crop-collapse-repro1.log` and `crop-gates-stage1.log`. The field begins editing, but removal produces no numeric-end callback. Final gate snapshot is `ready=true busy=true crop=false valid=true invalid=[] scheduler=true pending=false inFlight=false worker=false`. Both pointer end and finish callbacks are present. This is a retained numeric-interaction state, not a missing crop-pointer end or actual rendering work.
- A distinct Enter-before-collapse control once left the native Apply control disabled while model gates had already returned to `canApply=true`; selecting 1:1 refreshed it. With additional workspace body logging, four repetitions and 20 more pointer drags did not reproduce that model/UI discrepancy. It is not attributed to the confirmed retained-interaction cause or claimed fixed.
- Diagnostic builds exited 0: `crop-gate-diagnostic-build.log` and `crop-workspace-diagnostic-build.log`. Logs buffer in memory and flush after input rather than synchronously writing each drag event. All temporary diagnostic source changes were removed before recording this phase. No production behavior fix has been applied at this checkpoint.

### Precise crop focus teardown repair

- The unmodified non-instrumented app reproduced the numeric-collapse failure once more, in addition to the two buffered-log reproductions. This establishes 3/3 for that exact legal-input sequence, not for every disabled-Apply observation.
- A hosted AppKit regression uses a real `NumericTextField`/field editor and sends mouse-down/up events only to its own offscreen `NSWindow`. The RED log `build/native-acceptance/precise-collapse-red.log` explicitly passes native input ownership, uncommitted width and actual Disclosure collapse, then fails `collapsing precise crop ends native numeric interaction` (exit 1). Earlier fixture activation/AX-discovery failures are setup failures, not product RED evidence.
- Minimal repair in `GeometryControls`: commit the key window's focused native input before collapsing. If any of the four precise crop values is invalid, retain the expanded controls for correction. No scheduler flag is forcibly cleared; no renderer, crop math or Shared source is changed.
- Focused GREEN: `precise-collapse-green.log`, exit 0, 21 checks. Complete affected draft GREEN: `precise-collapse-full-green.log`, exit 0, **171 checks** (the previous 154 plus 17 hosted lifecycle checks). These synthetic test-owned window events are not counted as real native keyboard/mouse acceptance. Independent read-only review found no blocking issue; the fixed-size host's relative click location remains a test-layout limitation.
- Standard build: `precise-collapse-build.log`, exit 0. The acceptance executable was copied from that build, ad-hoc signed and verified; no diagnostic environment variable or source logging is present.
- Real CUA verification in that non-instrumented build: `Verify legal collapse commits width and releases Apply in the final app`, `Verify legal collapse repeat two and prepare repeat three`, and `Verify legal collapse repeat three and enter a retained invalid crop value`. All three legal collapses committed width 80.0 percent, removed precise controls, cleared the busy indicator and enabled Apply. `Verify invalid crop input remains visible when collapse is requested` retained `invalid`, expanded controls and validation feedback, while ending busy state. Correction to 80 followed by collapse and actual Apply succeeded with `调整已保存` and preview 845x1024.
- The private registry now records crop width `0.8`, with the previous X/Y/height, +3 degrees and horizontal flip unchanged; SHA-256 `9cdcfb6c04dba46bb2f60c35ae4985c356123d09ed1df36744c01cab074bbbc9`.
- **The distinct pointer-release issue reproduced again after the first successful legal collapse.** `Verify post-collapse crop drag preserves the legal width and enabled Apply` changed crop to 11.2/11.2/71.9/88.8 percent but left Apply disabled, without busy/invalid feedback. The full AX tree and screenshot in `Capture the separate post-drag disabled Apply state without diagnostic instrumentation` confirm it. An unrelated grid checkbox toggle immediately re-enabled Apply (`Test whether an unrelated grid toggle refreshes the stuck native Apply control`). The legal width was preserved, so the numeric teardown repair worked; the pointer/model-to-view update issue remains unresolved. Subsequent cancellation discarded that dragged crop before the separate corrected-width Apply above.
- Historical transcript audit also found the original first pointer failure started with precise controls collapsed and no numeric-field focus or busy state. It must not be merged with the numeric-collapse root cause.

### Additional export formats

- Returned both generated bundles to the non-instrumented `0f8a912` build after a buffered view-read diagnostic. Nine diagnostic native drags passed; `apply-view-trace.log` shows model `canApply=true` and a final workspace `true` read in those passing runs. No failure was captured with the extra body expression, so this is inconclusive diagnostic evidence, not a pointer-release repair. Temporary source and `RAWLAB_APPLY_TRACE_PATH` were removed.
- `Save a native original-size 16-bit PNG export` and `Save a native rendered DNG from the committed crop` exercised actual format menus and native save panels, choosing separate task-owned output directories. Both returned `已导出` feedback. These used the committed 80 percent width, +3 degree rotation and horizontal flip, not a model export call.
- Independent read-only checks confirmed both outputs are 2340x2835 and decode to nonblank images. PNG: 34,560,303 bytes, 16-bit RGB (`rgb48be`), three samples/no alpha, sRGB IEC61966-2.1; SHA-256 `71fb7faaa6e283fc3e0042ae9b123f1372d576572422e667e2a9a99b21747bd5`. DNG: 79,609,454 bytes, 32-bit float/three samples, LinearRaw photometric 34892, DNG 1.4.0.0, explicit baked display-sRGB/not-sensor-RAW metadata; SHA-256 `229c6ccf54a5b892db5bbb196ba353368f7cd1401e071c318907bd0568691274`. All 19,901,700 decoded float samples were finite, with range `1.1840675e-07..0.9985507`. Different encoding/precision means no byte or pixel identity between PNG and DNG is asserted.
- Files: `build/native-acceptance/exports/png/acceptance-a-PROVIA.png`, `exports/dng/acceptance-a-PROVIA.dng`; detailed command/output audit: `build/native-acceptance/export-format-audit/report.md`. Original/private RAW hashes and user registry remain unchanged; private registry remains the post-correction hash above.
- A new native batch window was opened with the saved A adjustments and zero inputs. The next `Add the separate disposable batch RAW copies through the native file picker` call returned a **current** CUA Mac-locked error. No batch-cancel/retry/recovery result is claimed from this attempt. The user was asked once to unlock manually; no security setting or unlock workaround was attempted. Non-desktop output validation and offscreen diagnosis continue independently.

### Pre-unlock diagnostic boundary

- Independent offscreen model-to-workspace probe: `build/native-acceptance/apply-presentation-probe/run.sh`, source `ApplyPresentationProbe.swift`, result `report.json`. It compiled and exited 0, using only a prohibited-activation, unshown borderless test window. Both contiguous and yielding main-thread event sequences ended with `canApply=true`, `busy=false`, preview ready, crop interaction false and no invalid input. However, all six 1520x600 cached bitmaps were entirely black. Native Apply presentation was therefore **NOT REACHED**, not passed; this cannot distinguish missed view invalidation from native button state synchronization. No desktop activation or global input was used.
- Local SDK inspection found `Gesture.onEnded` declared `nonisolated` while `onChanged` is declared `MainActor` in `SwiftUICore.swiftinterface` (SDK 26.5, lines 5711/5719). This is only a thread-affinity hypothesis to measure with a low-frequency callback-thread trace after manual unlock. It is not evidence that the actual failing callback ran off-main, and no actor/dispatch/delay repair has been applied on that basis.
- Planned at that checkpoint: capture callback thread and final workspace/button state after unlock, then continue batch cancellation/retry/recovery and current Tab/AX traversal. The following post-unlock sections supersede this plan with actual results. Shift-wheel/VoiceOver and active-draft drop guard remained unverified.
- Final non-desktop audit at this checkpoint: old tree clean at `0856eadf165129eeed276f473ce7f38588c56866`; original, A/B and eight additional task-owned batch RAW copies all retain SHA-256 `0ecdc8087d566c5ba39f9bd40eef4dfc5f3884ccb016f311a606508751c79eaf`. User registry remains `1bc106526236f30b335af381446385ea4b0a8fc3131abad4bc2fceda55ad6e52`. Both generated bundles pass strict deep signature verification and share clean executable text hash `942854571c7081019d03aa27cd71f81a5a40fa9745f8486caada298d887773c0`. The only running RawLab process is the isolated acceptance bundle (last audited PID 41228); no diagnostic/test/build process remains.

### Post-unlock native batch completion

- The user confirmed manual unlock. Fresh CUA inspection returned the existing private batch window; the old lock error was not reused as a blocker. All batch actions below ran on the non-instrumented precise-collapse repair build.
- `Select all eight private RAW copies in the native multi-selection panel` selected one item; native Shift-click in `Extend native RAW selection across all disposable fixtures` selected all eight. Open imported them and native validation completed. The PNG segmented control and output-directory system panel selected `exports/batch-resume`.
- `Start the native eight-file PNG batch and observe the running state` -> `Cancel the running PNG batch with the actual native button` -> `Verify cancellation settled with completed outputs retained and unfinished items resumable`: settled at 2 successes (08/07), 0 failures, 6 waiting, with Continue 6. Independent audit: `batch-audit/cancel.md`, `cancel-job.json`; original compact journal SHA-256 `bc766bf8e2ee0e6869ce11338710409a784cf71158919a0870cb89dad23cb815`. No temporary output remained.
- A disposable copy `fixtures-batch/acceptance-01.DNG` was temporarily renamed to `.DNG.held`, preserving inode `150484486`, size `19545856`, mtime `1791994717`. This is safe missing-input fault injection, not an original-photo edit.
- Native Continue 6 started. The root agent had verified the sole RawLab process PID 41228 and its full private acceptance-bundle path before sending `kill -KILL 41228`. This is intentional process-failure injection, not a native keyboard/mouse action. The process exited. `batch-audit/interrupted-before-relaunch.json` records 4 succeeded (08..05), 04 running and 03..01 waiting.
- `Relaunch the isolated app after controlled batch process termination` restored the actual batch window with `导出已中断`, 4/0/4 and Continue 4; 04 was visibly waiting again. Independent audit `batch-audit/recovery.md` distinguishes normalized in-memory UI from unchanged on-disk journal (SHA-256 `2996c2fc5dca4719ff4512132e03b0559fe6b6ea4e0427fa5b8d3c41889e07d4`). Four existing outputs remained intact and no `.rawlab-*` remained.
- `Resume only four unfinished exports from the recovered native batch` finished at 7 successes, 1 expected failure, 0 waiting. `Verify the safe missing-private-copy failure and native retry control` showed the missing 01 file error and Retry 1. Snapshot: `batch-audit/missing-copy-failure.json`.
- The same 01 inode was restored to its original private path. `Retry the single failed export after restoring the same private RAW inode` -> `Verify native retry completed with eight successes and no remaining failures`: 8/0/0. Independent audit `batch-audit/final.md` / `final-job.json`; compact final journal SHA-256 `175e111979a8b162b66af007bd3e81dfecc7253efe0b9d2015023e7f2d036d45` (also independently rechecked by the root agent).
- Exactly eight PNGs exist, no `-1` duplicate names or temporary files. All decode as 2340x2835 16-bit RGB, each 34,560,303 bytes and SHA-256 `71fb7faaa6e283fc3e0042ae9b123f1372d576572422e667e2a9a99b21747bd5`, identical to the earlier single PNG. The 05..08 output hashes and mtimes were unchanged by recovery/retry. All eight private RAW copies retain their original hashes; the temporarily held 01 path is fully restored.
- A separate model-only crop thread diagnostic then reproduced the stuck native Apply state (`Check whether model-only delayed thread sampling preserves the native failure`, `Capture the stuck native Apply control in the model-thread diagnostic build`). `crop-thread-trace.jsonl` confirms both callback boundaries were on the main thread, final `cropInteracting=false`, `busy=false`, preview ready, no invalid input and `canApply=true`. A subsequent focus-only Tab event did not restore Apply. This refutes the proposed off-main completion cause for this captured failure. The workspace source was not instrumented in this diagnostic; investigation remains open.

### Post-unlock crop and focus checks

- Further diagnostics only: `crop-gate-read-diagnostic-build.log` built with exit 0. `crop-gate-read-EditorModel.swift` preserves the temporary source; it buffered getter and setter-phase records in memory (bounded at 1024) and flushed only on Cancel. It added no timer and changed no workspace expression. The first drag, 10 fresh-draft drags and 30 alternating drags all kept Apply enabled: **41 passing diagnostic drags, no failed getter trace captured**. This is not a repair or a clean-app release-to-Apply pass.
- Independent `crop-read-audit.md` and root `jq` check: 12 flushes, 350 records, 174 reads, 82 before/82 after writes, all on main. In 28/41 release phases the getter synchronously read old `crop=true/result=false` between beforeWrite(false) and afterWrite(false), then read true after assignment. These passing records demonstrate possible pre-assignment reentry, but do not establish why the uninstrumented UI sometimes stays disabled. Apple documents `ObservedObject` as invalidating a view when published properties change; no unsupported claim that computed properties are unobserved is made ([Apple documentation](https://developer.apple.com/documentation/swiftui/observedobject)).
- All getter/thread diagnostic source was removed; `EditorModel` again has no diff. Both generated bundles were restored to the clean precise-collapse repair executable, re-signed and strict-deep verified. The acceptance plist contains only the private `CFFIXED_USER_HOME`, no tracing variable.
- The user independently performed a physical TL hand drag and clicked Apply in that non-instrumented app, replying `保存成功`. `Verify the human-performed crop Apply in the non-instrumented app` confirmed the draft had closed and live preview was 826x1024; the private registry saved X `0.09719450101832994`, Y `0.09051171079429732`, width `0.7331720977596742`, height `0.9094882892057027`, with +3 degrees/H flip unchanged. Its new SHA-256 is `2c68a2460eb80cfa97c1a46dac16abab9959bf15fa9272c539a4caad64de94a7`. This is a human-input success, not proof that intermittent fast CUA release is fixed.
- `Verify the current macOS editing Tab cycle without changing keyboard-access settings`: under the current system settings Tab cycled the exposure numeric field. No global setting was changed and full button traversal is not claimed.
- `Verify the current crop Tab cycle and focus labels in the clean app`: a complete actual Tab cycle covered TL, move, top, TR, left, right, BL, bottom, BR and rotation, then returned to TL. `Verify all precise crop numeric fields participate in the native Tab cycle` additionally reached X/Y/width/height before wrapping. `Verify reverse Tab traversal and discard the focus-only crop session` returned from move -> TL -> height -> width. No numeric text or geometry was changed in these focus checks; Cancel discarded the session.
- Available AX limitations remain: handles have specific Help/IDs but Description `PROVIA`; expanded precise field IDs repeat `geometry.preciseCrop` even though native identifiers differ. VoiceOver announcements and full keyboard-access settings were not enabled, so announcement quality and access to every command are not accepted.

- Basic external RAW drag/drop is now verified as described above. The CUA cross-window targeting limitation was handled by human native input, without security changes or guessing a destination over another app. Active-draft drag/drop departure choices remain outside the exercised drop path.
- Shift-wheel, VoiceOver announcements and complete application-wide Tab traversal were not exercised. No global accessibility or security setting was changed.
- The separate disabled-Apply observation after crop dragging is now reproduced again but remains unexplained. An earlier native replay passed all nine regions without changing crop production code; no claim is made that the intermittent release-to-Apply failure has been fixed.
- A broader action-deferral hypothesis was rejected after the window lifecycle evidence. Its temporary assertion intentionally failed in `build/native-acceptance/dismissal-regression-red.log`; that assertion was removed, not counted as an established product failure or part of the 154-check suite. `EditorModel` and `EditorView` have no diff.
- Independent audit confirmed the old worktree is still clean at `0856eadf165129eeed276f473ce7f38588c56866`; original RAW/private fixture hashes and the user's original registry hash remain unchanged. Committed production changes are limited to the macOS window guard and precise-crop collapse binding.

Local phase commits (no push, PR, merge or release):

1. `d382db15a742f3ad4b36f6a961bdbd97e6425226`: isolated audit and build baseline.
2. `28b77d22dafbbb9df0833e15806dca38fb9ebcd8`: native import, draft and keyboard evidence.
3. `65f45bb9340163fc348dd86b6a233b8f1d705dbf`: foreground geometry and export evidence.
4. `6ac075320e4708ea6c116121f682376baa897b2c`: window-close repair, affected regression and native lifecycle verification.
5. `3a76f81e2d83711112a81cb75113d8597578918a`: pre-drop final audit and explicitly unexercised coverage.
6. `b6f7a716ab56591b0135038444eaf6a2e2b59783`: human-assisted native RAW drop evidence.
7. `ce3634f1bf22e5195d96e5390d368d41ab0b52a0`: separated reproducible numeric teardown from the pointer-release observation.
8. `0f8a912997b9cb362309b01f7c7d08e78036ca59`: precise-crop focus teardown repair, 171 checks and real native correction verification.
9. `34df9530cdcfccc46b1f35c82287846ca92fd493`: native PNG and rendered DNG export evidence.
10. `8606068c4876cf13b883527459b37c5b4c872b1b`: native batch cancellation, process-failure recovery and missing-copy retry evidence.
