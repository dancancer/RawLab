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

Native acceptance is partial. The app launched and returned live AX state and window screenshots; no lock-screen or approval blocker was returned. CUA button actions, file-list interaction, Tab traversal and focused typing worked. Coordinate drags, wheel input, several native menu selections and close/global shortcut actions did not produce the expected transition. The cause has not been established, so these are not recorded as app defects or passes. The optional documented `cua.computer.launch_app` method is unavailable in this runtime (`is not a function`). A foreground-state question was sent once; no security setting, permission reset or other application's focus was changed to work around this.

## Native-input matrix

| Item | Status | Required observation |
| --- | --- | --- |
| Open button, File menu, Command-O and cancel | PARTIAL | Button/menu opened the system panel; button and Escape cancel returned to empty state. Command-O opened once, but later attempts had no effect; repeatability is not accepted. |
| RAW import and drag/drop | PARTIAL | A imported by native file-list double click; B imported by selected row + Return; A reopened by selected row + Open. Drag/drop NOT REACHED. |
| Eight crop handles and in-frame move | PARTIAL | All nine regions reached by Tab and changed by actual direction keys; Shift-Up fine resize observed. Pointer drags remain unverified. |
| Aspect presets and orientation swap | NOT REACHED | Crop retains selected physical ratio and swaps orientation |
| Rotation ruler and wheel | NOT REACHED | Real drag/wheel updates angle; precision behavior checked |
| Draft Apply and Cancel | PASS for exercised path | Apply saved crop +3 degree rotation; Cancel discarded subsequent nine-region keyboard edits. Reentry restored the applied geometry. |
| Leave Apply/Discard/Stay | PARTIAL | Collapsing adjustment panel displayed the native three-choice sheet. Stay retained the flipped draft; Discard dismissed draft and collapsed panel. Apply-and-leave NOT REACHED. |
| Window close and application quit protection | NOT REACHED | Native close button, Command-W and File Close attempts did not close or show a prompt. Quit still pending; this does not prove protection works. |
| Save and reopen recovery | PASS for exercised path | A -> B -> A displayed restored-adjustments feedback; crop and +3 degree rotation were confirmed on reentry. Private registry matches these values. Relaunch recovery still pending. |
| Comparison | PARTIAL | Native toolbar toggle changed AX value from enabled to disabled and removed neutral-view label. Final two-way visual check pending. |
| Single export | NOT REACHED | JPEG menu was exposed and selected, but no save panel or output appeared. |
| Batch export | NOT REACHED | Native selection/destination/start produces valid private outputs |
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

Private and original RAW SHA-256 at setup: `0ecdc8087d566c5ba39f9bd40eef4dfc5f3884ccb016f311a606508751c79eaf`. The user's existing `~/Library/Application Support/RawLab/Edits/edits.json` remained `1bc106526236f30b335af381446385ea4b0a8fc3131abad4bc2fceda55ad6e52` after Apply. The private registry hash after Apply, Cancel and Discard was `7c766c81bbfcd5c5c70f03a57a8272c670b519e319a0a3311db5b0ec8274e1a3`.
