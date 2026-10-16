# Android v0.8 Geometry Integration Verification

## Scope and Source

Integration base: `435feda1d6e44cc5a53a4a0c73208ce96fc6ee0b` (`development`, including PR56 and PR57).
Preserved PR45 parent: `59d66dae9a7b9f637771e79e4111b28096b99116`.
The integration uses a detached HEAD in the existing isolated `56c3/rawtools` worktree.
The old `build/phase-one-android-geometry-ux` checkout and its unknown Windows artifact deletions are not changed.
The integration will also merge `development` at `7da15e57b1f2178d12cabc823c249dc589578547`
before final native/batch verification. That target adds display-input C ABI/core code but does not
change Android sources; Android continues to use RAW, not the desktop raster adapter.

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
| Updated-core native/batch matrix and unobstructed visual captures | Pending |

The initial native and language invocation ran five tests and failed two; its overall result is **FAILED**.
The three native methods completed without failure, but this does not turn the combined invocation green.
The same OEM locale restriction was previously established in `batch-gpu-preference-verification.md`.
No locale, region or security bypass is applied.

Other failed invocations are retained rather than reported as green: the first original-ratio fixture
competed with the live canvas over preview size and timed out; the owned-ViewModel fixture above passed.
The first summary fixture lost the ActivityResultRegistry through a localized context and was corrected
without production changes. A summary/layout invocation passed the summary but failed layout because
its test APK lacked `sample.RAW`; the next test build must explicitly provide `RAWLAB_TEST_RAW`.

Independent review found no production P1/P2 defect in the integrated geometry paths. Its coverage
requests for native Original ratio, late crop, process restart and AUTO FINAL were added and checked.
The batch CPU/Auto x new/resumed matrix is implemented and awaits the new core. A coordinator review
identified the two omitted batch perspective summary rows; these are restored with a focused Compose
regression. Malformed geometry decoding still throws; there is no identity fallback.

## Resource Ownership

Physical device: Lenovo TB320FC, `HA1ZKK0Q`, private ADB `5063`.
Only initially absent `com.rawlab.android.batchprobe56c3[.test]` is installed.
At this run's start the original `com.rawlab.android` package is absent; both Sony-memory packages are retained.
Shared ADB `5037`/`5047` processes are not restarted. The idle USB transport is detached from `5037`
and attached to the private server; it will be returned during teardown.
The user explicitly requested that USB connection prevent automatic locking. On this Lenovo device,
the current USB connection reports AC power, so `stay_on_while_plugged_in` changed from `0` to `3`
(AC plus USB), with `mStayOn=true` verified. This setting remains enabled after testing by request.
The 600000ms timeout, PIN, CPU/GPU, global security and personal gallery settings are unchanged.
The OEM application-list prompt is denied, never granted.

## Final Status

Pending final gates, independent review, commit/push and PR45 update. The Android owner does not merge the PR,
create a main/tag/Release, or claim hosted CI from local results. The 240-second budget and quality assertions remain unchanged.
