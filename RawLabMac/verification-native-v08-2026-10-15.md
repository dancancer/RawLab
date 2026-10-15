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

The worktree build completed with exit 0 and `PASS: all non-system dynamic dependencies are bundled and signed`, logged in `build/native-acceptance/build.log`. The build script's built-in DNG check also passed; the 132/50/snapshot suites were not rerun.

The initial generated app was copied to `build/native-acceptance/RawLab Mac Acceptance.app`, with only bundle identity/name, `LSEnvironment.CFFIXED_USER_HOME` and ad-hoc signatures changed. `codesign --verify --deep --strict` passed. The initial original and acceptance executables had identical `__TEXT,__text` dumps (SHA-256 `54bf5e1e17c07316eb650389c24fdf2ab53278fce812693909dfc9a757001fa5`). Whole-file hashes differ because of re-signing. The later window-close fix and final build are recorded below.

Native acceptance is in progress. The app launched and returned live AX state and window screenshots; no lock-screen or approval blocker was returned. Initial background-app attempts at coordinate drags, wheel input, several native menu selections and global shortcuts did not produce the expected transition. The user subsequently confirmed bringing the acceptance app to the foreground. Shortcuts, menus, pointer drags and wheel input then worked; the initial failures are not classified as application defects. The optional documented `cua.computer.launch_app` method is unavailable in this runtime (`is not a function`). No security setting or permission was reset.

## Native-input matrix

| Item | Status | Required observation |
| --- | --- | --- |
| Open button, File menu, Command-O and cancel | PASS for exercised paths | Button/menu opened the system panel; button and Escape cancel returned to empty state. Foreground Command-O was repeated successfully across diagnostic and final builds, including Escape then reopen. Earlier background attempts are not app failures. |
| RAW import and drag/drop | PASS for exercised paths; human-assisted drop | A imported by native file-list double click; B imported by selected row + Return; A reopened by selected row + Open. The user physically dragged private B from Finder into the empty final-build editor; subsequent live CUA AX/screenshot confirmed its full private path, rendered preview and enabled editing controls. Drop during an active draft was not exercised. |
| Eight crop handles and in-frame move | PASS on final replay; historical warning | All nine regions changed correctly with actual pointer drags and Tab/direction keys. Shift-Up fine resize observed. Final non-instrumented build replay checked Apply after every release: all nine remained enabled. Earlier disabled-Apply observation was not reproduced or explained; it remains a residual risk, not a claimed code fix. |
| Aspect presets and orientation swap | PASS for exercised path | Native 16:9 selection produced W/H 99.0/55.7 percent on square canvas; swap produced 55.7/99.0 percent with portrait selection visibly confirmed. Other presets not repeated. |
| Rotation ruler and wheel | PASS for exercised path | Actual ruler drag changed 3 to 0 degrees; Right changed 0 to 0.1; wheel up 1 over numeric field changed 0.1 to 1.1. Shift-wheel and full-range traversal not claimed. |
| Draft Apply and Cancel | PASS for exercised path | Apply saved crop +3 degree rotation; Cancel discarded subsequent nine-region keyboard edits. Reentry restored the applied geometry. |
| Leave Apply/Discard/Stay | PASS for panel-collapse path | Native three-choice sheet: Stay retained draft; Discard discarded and collapsed panel; Apply-and-leave saved horizontal flip and collapsed panel. Other departure triggers remain separately scoped. |
| Window close and application quit protection | PASS for exercised paths after fix | Foreground Command-W displayed prompt and Stay retained draft. Native Discard and Apply closed the actual window, proven by same-window lifecycle callbacks and `isVisible=false` before another CUA state query. Native Quit/Stay/Discard/Apply succeeded; both completed Quit paths have process-exit evidence. |
| Save and reopen recovery | PASS for exercised path | A -> B -> A and full Quit/relaunch/open restored crop X/Y 3.0 percent, W/H 97.0 percent, +3 degree rotation and horizontal flip. Discarded vertical flip remained off. |
| Comparison | PASS | Live screenshots confirmed side-by-side neutral/PROVIA and return to single-image presentation using the toolbar control. |
| Single export | PASS for exercised JPEG, 16-bit PNG and rendered DNG original-size paths | Native export menus/save panels, private destinations and success feedback; files independently decoded and checked. See format follow-up below. |
| Batch export | PASS for two-photo JPEG path | Native batch window, Add RAW twice, destination panel, All/None selection and Export 2; UI completed with 2 success, 0 failed, 0 remaining. Independent decode and pixel comparison passed. Cancel/retry/interruption not exercised. |
| Tab focus and available accessibility | PARTIAL | All crop handles, move region and rotation field reached with real Tab; direction keys and typing worked. Crop AX Decrement shrank top-left by 1 percent. Full app/VoiceOver coverage not claimed. |

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

- Basic external RAW drag/drop is now verified as described above. The CUA cross-window targeting limitation was handled by human native input, without security changes or guessing a destination over another app. Active-draft drag/drop departure choices remain outside the exercised drop path.
- Shift-wheel, VoiceOver announcements, complete application-wide Tab traversal and batch cancel/retry/interruption were not exercised. No global accessibility or security setting was changed.
- The initial disabled-Apply observation after crop dragging remains unexplained. Final native replay passed all nine regions without changing crop production code; no claim is made that this historical observation has been fixed.
- A broader action-deferral hypothesis was rejected after the window lifecycle evidence. Its temporary assertion intentionally failed in `build/native-acceptance/dismissal-regression-red.log`; that assertion was removed, not counted as an established product failure or part of the 154-check suite. `EditorModel` and `EditorView` have no diff.
- Independent final audit confirmed the old worktree is still clean at `0856eadf165129eeed276f473ce7f38588c56866`; original RAW/private fixture hashes and the user's original registry hash remain unchanged. The only committed production source change is the macOS window guard.

Local phase commits (no push, PR, merge or release):

1. `d382db15a742f3ad4b36f6a961bdbd97e6425226`: isolated audit and build baseline.
2. `28b77d22dafbbb9df0833e15806dca38fb9ebcd8`: native import, draft and keyboard evidence.
3. `65f45bb9340163fc348dd86b6a233b8f1d705dbf`: foreground geometry and export evidence.
4. `6ac075320e4708ea6c116121f682376baa897b2c`: window-close repair, affected regression and native lifecycle verification.
5. `3a76f81e2d83711112a81cb75113d8597578918a`: pre-drop final audit and explicitly unexercised coverage.
