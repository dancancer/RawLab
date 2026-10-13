# v0.7.0 Local Candidate Verification

This is the preserved pre-Sony-fix candidate record at `baea491e`.
Final rebuilt release packages and signing are documented in
[release verification](verification-v0.7.0-release.md); the old unsigned
mobile candidates below are not the final installable release assets.

## Source and Scope

Accepted development source: `3f252a1006d349c2a3655129a9cf665385dccaca`.
Its complete tree equals the accepted #25 tree
`8cd099efca75c18765ec5db178746d8bd8da3ebd`.
[Final composition verification](verification-final-composition-2026-10-13.md)
records fresh Mac core, unique Lens/NR/viewport/FINAL, client and actual
package-runtime checks, and the source identity for reused client evidence.

The isolated candidate is `release/0.7.0` in
`build/iteration-v070-release`. Version commit
`465bd109f6aee6b6b36d4f9fd6d7d985dca4e7fe` changes only the four client
metadata files to 0.7.0/build11; parent is the accepted development source.
`574ca844146f92087b2f433a56960fbfe5a3d376` adds the two reviewed final
composition documents by cherry-picking `6cdd08b2`. Later candidate
documentation does not change executable source or package resources.

Android, iOS and Windows use the version commit; Mac was built from the
checkout with the two additional reports. No algorithm, shared C ABI,
original RAW, dependency version, minimum-OS source default or security
setting was changed for candidate preparation. The release source keeps the
existing Mac build default; the candidate explicitly supplies target15.

## Local Artifacts

Artifacts remain ignored under `build/candidate-v070/` in that worktree.
`BUILD-PROVENANCE.json` records source and artifact identities;
`SHA256SUMS.txt` contains the four relative paths and checksums. Root read
each final file and matched the producer's final checksum.

| Platform | File | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| macOS arm64 | `RawLab-Mac-0.7.0-build11-macOS15-arm64.zip` | 95,936,692 | `901189b922eba43f4204e22fe5c2af63d9998f996df08c135239cb0de1ddef3a` |
| iOS arm64 unsigned | `RawLab-iOS-0.7.0-build11-unsigned.ipa` | 95,624,834 | `0a329f093c2aab9ac59d0c81c5d617e3790aa92c3b01b72550b897a8ec3e6074` |
| Android unsigned | `RawLab-Android-0.7.0-build11-unsigned.apk` | 129,319,119 | `5e1d7e3e9667e643533eb59a1e94406eed3bdb6af9eaeec5f2546ad68a48c8bb` |
| Windows x64 self-contained | `RawLab-0.7.0-build11-win-x64.zip` | 176,240,753 | `a4c9da0dc2f32b05fd68ee8d9fcdcb35dc611daf0b73ef6078701e6b3396c373` |

These are local preparation artifacts. No v0.7.0 tag, remote Release,
uploaded assets, main merge, notarization or store delivery was performed.
Published downloads remain v0.6.0.

## Platform Package Checks

**Mac.** Fresh arm64 dependency sources and core/app were built with explicit
`MACOSX_DEPLOYMENT_TARGET=15.0`, using the candidate's own prefixes. Only
fixed source archives were seeded; target26 compiled dependencies were not
reused. Host was macOS 27.0.1 / 26A434; actual Mach-O SDK values range from
15.2/15.4 host-library SDKs to 27.0, while all 18 package Mach-O minimum
versions are 15.0. Version/build, six catalogs, Lens DB/notices, source
resource comparisons, architecture, dependencies/RPATH and strict signatures
passed. The build's SDK/JXL assertions passed unchanged.

The target15 app also completed real Panasonic packaged smoke with both own
dependency install prefixes hidden and DYLD overrides cleared. Actual
processing libraries loaded from the app; no external processing-library
load was found. Both prefixes were restored and the input RAW hash remained
unchanged. The package is ad-hoc signed. Target15 build and closure do not
establish physical macOS15 runtime, Intel packaging or fresh interactive GUI.
Evidence: `macos/result.json`, dependency/build/runtime logs and
`package-closure-macos15.sh` under the ignored run directory.

**iOS.** Fresh generic-device Release app build returned 0 with signing
disabled, version 0.7.0/build11, arm64/iOS18. The unchanged previously
verified three-slice framework was copied with all 171 file identities
matching; embedded device core remains identical. Six language catalogs
(317 interface and two permission entries each), 56 Lens XMLs, 27 license
files and look/recipe resources matched source. The complete unsigned IPA
passed per-file identity/ZIP CRC checks, with no private RAW, credentials or
provisioning profile. AccentColor and unused-AppIntents warnings are retained.
No framework, native, UI or device experiment was repeated. Evidence:
`ios/result.json` and its fresh build log.

**Android.** Two ABI Release native builds and `assembleRelease` returned 0
(4m48s, 54 tasks/52 executed). Manifest version is 0.7.0/code11; the package
is non-debuggable and unsigned. Actual arm64-v8a/x86_64 ELF architecture,
16KB archive/ELF alignment, DT_NEEDED closure and stripped Release identities
passed. Six languages (305 compiled keys each), 56 Lens XMLs, LUT/artwork/
recipe assets, 18 root and ten Lens license files matched source; no RAW or
key-file entries were found.

SDK HTTP2 partial downloads, AGP stale-configuration cleanup and a wavelib
TLS download failure are preserved as failed build attempts. Fifteen fixed
source archives were checked; a local ignored Gradle init script supplied
six standard FetchContent source-cache paths to avoid repeated downloads.
Both native ABIs were compiled from those sources, not copied from Debug.
No source, TLS/checksum rule, dependency version or assertion was relaxed.
There was no signing, installation or device test. Evidence:
`android/android-candidate-result.json` and retained attempt/final logs.

**Windows.** Fresh self-contained x64 publish uses source commit `465bd109`,
an independent VM directory and .NET 8.0.31. Readback gives assembly
0.7.0.0, file 0.7.0.11 and informational 0.7.0+build.11. The two unchanged
native DLLs match #25's exact hashes. Six embedded catalogs (414 keys each),
Lens/look/recipe assets, 34 license files and 458 .NET runtime files passed
passive file/resource checks. Complete ExifTool 13.59 contains six public
upstream RAW test fixtures, matched to its pinned archive; no user RAW or
credentials were included.

Two supplementary checking scripts were rejected by Windows anti-malware
before parsing/execution; the specific rule is unknown. No security or
execution policy was changed. Passive PE/CLR inspection replaced them:
23 external DLLs exist in VM System32, while 14 API-set names are retained
as system contracts without separate resolution. No new native/GPU/GUI/RDP
runtime test is claimed. Evidence: `windows/verification-windows-candidate.md`,
package metadata, passive closure summaries and retained blocked-script logs.

The Sony input/output scope below was clarified from the original test and
logs after candidate delivery. See
[the test source](../RawLabAndroid/app/src/androidTest/java/com/rawlab/android/RenderedDngInstrumentedTest.kt):
`processor.export(..., format, 128)` and the CPU-round marker after preview
plus both exports. This documentation correction changes neither production
source nor the four artifact hashes above.

## Remaining Release Coverage

- The two Sony 7008x4672 RAW-input preview/export tests used a 2.5 GiB,
  four-CPU AVD and requested preview and DNG/PNG outputs with longEdge128.
  FINAL still computes at full resolution before output resizing. Guest
  lmkd/SIGKILL occurred before the CPU-round completion marker; the failing
  stage is unknown. These attempts do not establish failure of an
  original-resolution output file or a DNG writer-specific cause.
  Original-resolution DNG output remains unverified. The smaller DJI pass
  retains its fixture scope; Release packaging adds no device-runtime proof.
- iOS Files Save was verified in the accepted source; Files cancellation,
  physical iPhone/iPad and iOS18 runtime remain unverified. iOS has no PNG UI
  gate in these records.
- Mac Intel candidate packaging, physical macOS15 runtime and fresh
  interactive GUI remain unverified. The minimum support target remains 15.
- Windows package inspection does not extend #25's GPU_OFF runtime proof
  to hardware GPU, full CTest or desktop/SaveFileDialog/Explorer acceptance.
  Original #27 D3D11 evidence retains its own source/configuration.
- Existing iOS RAW-to-raster Lens-panel selection and model-level DNG busy
  guard observations remain documented; normal UI export is gated. Larger
  RAWs and unexecuted architectures/OS versions are not marked passed.

The controlled Android memory budget and all pixel tolerances are unchanged.
These are local/dedicated-host results, not hosted CI. Final candidate head
and GitHub checks belong in the draft PR readback; empty checks are not a
passing or running workflow.
