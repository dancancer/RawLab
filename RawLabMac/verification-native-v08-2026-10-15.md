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
- A Foundation probe with `CFFIXED_USER_HOME` confirmed that `NSHomeDirectory()`, the user application-support directory and `homeDirectoryForCurrentUser` resolve under the private home. The application itself must also be checked before any edits are accepted as isolated.
- No RAW, screenshot, generated build or output file is committed.

## Current stage

Isolation audit complete. An application build from this worktree is in progress, logged in `build/native-acceptance/build.log`. No native interaction item has passed yet.

## Native-input matrix

| Item | Status | Required observation |
| --- | --- | --- |
| Open button, File menu, Command-O and cancel | NOT REACHED | Native file panel appears and cancels without import |
| RAW import and drag/drop | NOT REACHED | Private source renders; dropped source becomes current |
| Eight crop handles and in-frame move | NOT REACHED | Each real drag changes the expected edge/position |
| Aspect presets and orientation swap | NOT REACHED | Crop retains selected physical ratio and swaps orientation |
| Rotation ruler and wheel | NOT REACHED | Real drag/wheel updates angle; precision behavior checked |
| Draft Apply and Cancel | NOT REACHED | Applied result persists; cancel restores committed state |
| Leave Apply/Discard/Stay | NOT REACHED | Native departure prompt honors each choice |
| Window close and application quit protection | NOT REACHED | Draft prevents immediate loss and decisions are honored |
| Save and reopen recovery | NOT REACHED | Private edit record restores the applied state |
| Comparison | NOT REACHED | Real control changes visible before/after presentation |
| Single export | NOT REACHED | Native save panel produces a valid file in private output |
| Batch export | NOT REACHED | Native selection/destination/start produces valid private outputs |
| Tab focus and available accessibility | NOT REACHED | Real focus traversal and exposed labels/actions inspected |

VoiceOver, increased contrast or global keyboard-access settings will not be enabled or changed as part of this task. Unavailable coverage will be recorded rather than inferred from snapshots or model tests.
