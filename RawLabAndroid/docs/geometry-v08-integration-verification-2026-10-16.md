# Android v0.8 Geometry Integration Verification

## Scope and Source

Integration base: `435feda1d6e44cc5a53a4a0c73208ce96fc6ee0b` (`development`, including PR56 and PR57).
Preserved PR45 parent: `59d66dae9a7b9f637771e79e4111b28096b99116`.
The integration uses a detached HEAD in the existing isolated `56c3/rawtools` worktree.
The old `build/phase-one-android-geometry-ux` checkout and its unknown Windows artifact deletions are not changed.
The integration merged `development` at `7da15e57b1f2178d12cabc823c249dc589578547`
before final native/batch verification. That target adds display-input C ABI/core code but does not
change Android sources; Android continues to use RAW, not the desktop raster adapter.
The later normal merge `ec8756356823b7666e042eef232b575734a121f4` includes target
`62c1080348c9654702b8e1d59746c088ed78ab96`. The 7da15e57-to-62c10803 diff changes only
Mac files and documentation. Android, `lutools` and `Shared` trees are identical, so the native/device
results below remain applicable without repeating unchanged tests.
The final target is `cfcbf8df9de28b25610bbe854b57f6e971b63098`, included by normal merge
`df3cc27d031f45d25642545f232980f79c25084a`. Its delta from 62c10803 is iOS/design documentation
only; Android, `lutools`, `Shared` and Android build/configuration files again have no diff.

Only Android files change. The current generic `AdjustmentDraft`, v0.8 editor/canvas,
RUM events, batch preview ownership, cleanup, GPU preference and actual backend reporting remain.
The old standalone geometry reducer/editor is not restored. This PR does not edit shared C ABI/core code.

New functionality:

- Horizontal and vertical perspective use the existing shared setter, including identity reset.
- Geometry record v2 has 11 fields; v1's nine fields preserve their crop/rotation/flip/straighten with zero perspective.
- Free, Original, 1:1, 3:2, 4:3 and 16:9 support orientation swapping and constrained corner resizing.
- The original ratio comes from the identity native frame's oriented source dimensions, not an edited bitmap or EXIF thumbnail.
- Transform previews refit the current crop before enabling Apply. Numeric size edits that break the selected ratio unlock it; movement does not.
- Four missing RUM translations from the integration baseline are supplied to close 12 existing MissingTranslation lint errors. RUM behavior and consent text meaning are unchanged; no suppression is added.

## Evidence Location

Untracked logs and APK/device artifacts are stored outside build output at
`/Users/xupeng/mycode/rawtools-worktrees/android-geometry-evidence-20261016/`.
RAW fixture: `DSC00316.ARW`, SHA-256
`93a37abeaa3cd199773d25978a1045e580e26dbf884755f5d69c530e0bed5014`.
No RAW, screenshot or APK is committed.

## Checks

| Check | Result |
| --- | --- |
| Clean development JVM baseline | 102 tests, zero failures/errors/skips |
| v2/v1 regression RED on development | Two expected assertion failures |
| Draft ratio/reset RED | Two expected assertion failures; first resource-merge failure is not counted as RED |
| Integrated JVM suite | 129 tests, zero failures/errors/skips |
| Initial debug and instrumentation APKs | Both ABIs built successfully |
| Initial native APK alignment | All eight libraries pass 16 KB ELF/ZIP alignment |
| Initial lint | Failed: 12 baseline RUM MissingTranslation errors, 25 warnings; translations added and rerun passed |
| Physical native geometry | Three selected native tests pass, including both individual axes, FINAL exports, Force rejection and identity reset |
| Physical six-language suite | Two failures: PRC Lenovo firmware forces non-Chinese locales; not reported as a pass |
| Integrated debug/test build and lint | Passed; lint has zero errors and 25 warnings |
| Canonical application-ID build and native alignment | Passed; all eight libraries pass 16 KB ELF/ZIP alignment |
| Physical native/GPU and preview-owner lifecycle | 10 tests pass in 80.765s |
| Physical draft prepare and separate-process resume | Both phases pass; force-stop and an absent PID verified between invocations |
| Original ratio and late crop RED | Two expected assertion failures from temporary production mutations, both restored |
| Original ratio GREEN | One test passes in 59.468s with an owned ViewModel and real native source geometry |
| Late crop and process-resume/AUTO FINAL GREEN | Prepare passed; separate resume plus AUTO FINAL pass in 102.722s |
| Private API35 emulator controls/languages | Eight tests pass; emulator and private server stopped |
| Batch perspective summary RED/GREEN | Missing horizontal value fails before two summary rows are restored; both signed values then pass |
| Updated-core isolated and canonical APK builds | Passed; incremental native build 56s, canonical build/lint 22s; both ABIs, eight aligned libraries |
| Updated-core per-axis native FINAL | Passes horizontal-only, vertical-only and combined axes; CPU/Auto backend 0, fresh-session byte parity, Force rejection with existing output preserved, identity reset and RAW hash |
| Updated-core four-state batch perspective | One test passes in 192.249s; CPU/Auto x new/resumed, preview/fresh FINAL pixel parity, actual backend 0, both RAW hashes unchanged |
| Updated-core identity-geometry GLES batch | One test passes in 87.106s; new/resumed actual backend 2, Force pixel parity, pixels distinguish CPU |
| Fresh-process batch cleanup | Two separate cleanup invocations pass after force-stop; all six owned outputs removed |
| Final layout functional test | One test passes in 9.839s after removing a test-only focus guard incompatible with the export modal |
| Physical visual inspection | Clean exposure/geometry frames and a clean DNG export sheet inspected; full four-screen unobstructed capture is not claimed |

The initial native and language invocation ran five tests and failed two; its overall result is **FAILED**.
The three native methods completed without failure, but this does not turn the combined invocation green.
The same OEM locale restriction was previously established in `batch-gpu-preference-verification.md`.
No locale, region or security bypass is applied.

Other failed invocations are retained rather than reported as green: the first original-ratio fixture
competed with the live canvas over preview size and timed out; the owned-ViewModel fixture above passed.
The first summary fixture lost the ActivityResultRegistry through a localized context and was corrected
without production changes. A summary/layout invocation passed the summary but failed layout because
its test APK lacked `sample.RAW` because that build omitted `RAWLAB_TEST_RAW`.
That asset omission was fixed in the test build, without production changes. The new-core native/layout
invocation ran two tests: native FINAL passed, while an experimental screenshot focus guard timed out
on the legitimate DNG modal. The guard was removed and the focused layout test passed. These combined
invocations remain **FAILED**, not aggregate passes.

The Lenovo application-list permission prompt can obscure automated screenshots even when Compose
semantics pass. `new-core-v08-layout/exposure.png` and `geometry.png`, plus
`new-core-after-deny.png` (DNG), are the unobstructed visual evidence. The film frames and some later
automated captures remain obscured or transitional and are excluded from visual acceptance.

Independent review found no production P1/P2 defect in the integrated geometry paths. Its coverage
requests for native Original ratio, late crop, process restart and AUTO FINAL were added and checked.
The batch CPU/Auto x new/resumed matrix then passed against the new core. A coordinator review
identified the two omitted batch perspective summary rows; these are restored with a focused Compose
regression. Malformed geometry decoding still throws; there is no identity fallback.

An independent incremental review bound to `50b6b45ed2ffbc4c14d4a2e894f8eefd32139c89`
and base `7da15e57` found no P1/P2 issue in the additive ABI, Android link closure, RAW/JNI/backend
paths or the restored summary rows. No production code changed after that review. The screenshot
guard observation was superseded by the runtime modal failure and test-only removal above.
The requested auto-exposure setter-tracing hook was not added: geometry intentionally does not change
auto-exposure metering. The behavioral invariance assertion and direct inspection of the complete
configuration call in preview/export/autoExposure cover the existing contract without adding a
production test hook for an otherwise unobservable internal call.

## Source-to-Evidence Binding

The rebuilt native/runtime source is `50b6b45ed2ffbc4c14d4a2e894f8eefd32139c89`.
The following production tree IDs are unchanged in the later merge and final documentation update:

| Tree | Git object |
| --- | --- |
| `RawLabAndroid/app/src/main` | `e7ba111c4bbb0f85389a8439aa96622753681434` |
| `lutools` | `dcf78dcf15b0860383eb9d7e678c4b84631b52d0` |
| `Shared` | `bc401d9573b324ce8712e07d12d8ef637c2900c8` |

Android build/configuration files also have no diff from the runtime source. The final test-only change
removes the experimental window-focus guard; native and batch test methods are unchanged.

| Artifact | SHA-256 / evidence |
| --- | --- |
| Isolated main APK used for new-core runtime | `250a72513f81a7a7989bdd3c8b4654e6a86c78aa7cdb750a2263de765298b370` |
| Native/batch test APK | `8eaad4a0ed37f69415a2f6bee66d841af29f2ed8a147a268e791a924ed78efe8` |
| Corrected layout test APK | `346bc3e9c56c321c9bb265ecf7940b03051b5b23928dd5068ecbe29143dd0228` |
| Canonical main APK (not installed on the user's device) | `258b344cd0e449ebd7c9b73d471541a71d849df51b65979c2445c8abc8966385` |
| Incremental native APK build | `new-core-incremental-build.log`, `new-core-check-native.log` |
| Canonical package build/lint/alignment | `new-core-canonical-build-lint.log`, `new-core-canonical-check-native.log` |
| Per-axis native FINAL | Passing native method in `new-core-native-layout.log`; overall invocation failed on the independent screenshot guard |
| Four-state batch and GLES baseline | `new-core-batch-run.log` and individual logs under `new-core-batch/`; wrapper exit 0 |
| Functional layout after test correction | `visual-test-fixture-build.log`, `final-layout-green.log` |

Native compilation retains two unused-symbol warnings in the newly merged non-Apple display-image
stub per ABI. No dependency was deleted, re-downloaded or rebuilt merely to refresh target history.

## Resource Ownership

Physical device: Lenovo TB320FC, `HA1ZKK0Q`, private ADB `5063`.
Only initially absent `com.rawlab.android.batchprobe56c3[.test]` is installed.
At this run's start the original `com.rawlab.android` package is absent; both Sony-memory packages are retained.
Shared ADB `5037`/`5047` processes are not restarted. The idle USB transport is detached from `5037`
and attached to the private server; it was returned to `5037` during teardown.
The user explicitly requested that USB connection prevent automatic locking. On this Lenovo device,
the current USB connection reports AC power, so `stay_on_while_plugged_in` changed from `0` to `3`
(AC plus USB), with `mStayOn=true` verified. This setting remains enabled after testing by request.
The 600000ms timeout, PIN, CPU/GPU, global security and personal gallery settings are unchanged.
The OEM application-list prompt is denied, never granted.
Both isolated probe packages were uninstalled after the tests. The original package remains absent,
and both pre-existing Sony-memory packages remain installed. Private ADB `5063` and emulator server
`5065` are stopped; shared `5037` PID 23749 and `5047` PID 51027 are unchanged.
The old checkout retains HEAD `e029d4f40bae525886a37ed0792af55938be2c49`, its two original deletions,
and the unchanged `git diff` SHA-256 `764081915d2ede2b293b36dc549f3591024c06209cdcd516a0b971dd84de0c47`.

## Final Status

Local integration gates and independent review are complete, with the OEM locale/visual boundaries
and failed diagnostic invocations recorded above. Delivery updates the existing PR45 and marks it
Ready; only the coordinator merges. No main/tag/Release is created and local results are not hosted CI.
The 240-second budget and quality assertions remain unchanged.
