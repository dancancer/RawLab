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

The generated app was copied to `build/native-acceptance/RawLab Mac Acceptance.app`, with only bundle identity/name, `LSEnvironment.CFFIXED_USER_HOME` and ad-hoc signatures changed. `codesign --verify --deep --strict` passed. The original and acceptance executables have identical `__TEXT,__text` dumps (SHA-256 `54bf5e1e17c07316eb650389c24fdf2ab53278fce812693909dfc9a757001fa5`). Whole-file hashes differ because of re-signing. No app source has been modified.

Native acceptance is in progress. The app launched and returned live AX state and window screenshots; no lock-screen or approval blocker was returned. Initial background-app attempts at coordinate drags, wheel input, several native menu selections and global shortcuts did not produce the expected transition. The user subsequently confirmed bringing the acceptance app to the foreground. Shortcuts, menus, pointer drags and wheel input then worked; the initial failures are not classified as application defects. The optional documented `cua.computer.launch_app` method is unavailable in this runtime (`is not a function`). No security setting or permission was reset.

## Native-input matrix

| Item | Status | Required observation |
| --- | --- | --- |
| Open button, File menu, Command-O and cancel | PARTIAL | Button/menu opened the system panel; button and Escape cancel returned to empty state. Command-O opened once, but later attempts had no effect; repeatability is not accepted. |
| RAW import and drag/drop | PARTIAL | A imported by native file-list double click; B imported by selected row + Return; A reopened by selected row + Open. Drag/drop NOT REACHED. |
| Eight crop handles and in-frame move | PARTIAL / issue under diagnosis | All nine regions changed correctly with actual pointer drags and Tab/direction keys. Shift-Up fine resize observed. Apply remained disabled after pointer drags until aspect change; this post-drag path is not accepted. |
| Aspect presets and orientation swap | PASS for exercised path | Native 16:9 selection produced W/H 99.0/55.7 percent on square canvas; swap produced 55.7/99.0 percent with portrait selection visibly confirmed. Other presets not repeated. |
| Rotation ruler and wheel | PASS for exercised path | Actual ruler drag changed 3 to 0 degrees; Right changed 0 to 0.1; wheel up 1 over numeric field changed 0.1 to 1.1. Shift-wheel and full-range traversal not claimed. |
| Draft Apply and Cancel | PASS for exercised path | Apply saved crop +3 degree rotation; Cancel discarded subsequent nine-region keyboard edits. Reentry restored the applied geometry. |
| Leave Apply/Discard/Stay | PASS for panel-collapse path | Native three-choice sheet: Stay retained draft; Discard discarded and collapsed panel; Apply-and-leave saved horizontal flip and collapsed panel. Other departure triggers remain separately scoped. |
| Window close and application quit protection | PARTIAL | Foreground Command-W displayed prompt and Stay retained draft. Discard ended draft, but CUA still exposed editor afterward; actual close completion needs diagnosis. Native application Quit/Stay/Discard succeeded, process exit confirmed. Quit/Apply not exercised. |
| Save and reopen recovery | PASS for exercised path | A -> B -> A and full Quit/relaunch/open restored crop X/Y 3.0 percent, W/H 97.0 percent, +3 degree rotation and horizontal flip. Discarded vertical flip remained off. |
| Comparison | PASS | Live screenshots confirmed side-by-side neutral/PROVIA and return to single-image presentation using the toolbar control. |
| Single export | PASS for JPEG original size | Foreground Command-Shift-E opened save-panel; private destination chosen and Save clicked; native success feedback and valid JPEG confirmed independently. PNG/DNG not exercised. |
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
