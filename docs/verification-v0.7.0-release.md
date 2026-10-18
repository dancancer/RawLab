# v0.7.0 Release Verification

Version 0.7.0/build11; existing five-feature baseline 3f252a1 and Sony repair
`627d45e7` are combined at `2dac9d90558a8e899066d3cb01508767d3e4eeed`.
Subsequent release edits concern documentation/download links only. Final
tag/tree and all downloadable assets are recorded in Release
`BUILD-PROVENANCE.json` and `SHA256SUMS.txt`.

## Final Packages

| Platform | Asset | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| macos | `RawLab-Mac-0.7.0-macOS15-arm64.zip` | 95,935,586 | `e27eed99fd735325f1dc784bf96347fc9d90a412b9a18bfebff8127540eccc42` |
| android | `RawLab-Android-0.7.0.apk` | 129,350,342 | `3911208884064ce1bc780d4c3841bfad6b4427f5b2a1bc53fb6d3e13306f09b7` |
| windows | `RawLab-Windows-0.7.0-win-x64.zip` | 176,241,563 | `a92e06add9de8e9dd7ec7574116c8c9bf2d04168dd22c206324faa9fed72cddb` |

Android recompiled affected native sources for both ABIs and assembled Release,
then used the existing release key. Version 0.7.0/code 11, minSDK 26,
non-debuggable, eight native ZIP/ELF 16KB alignments and APK v2/v3 signatures
pass. Certificate SHA256 is
`9fd68e245a597cde2abb949ff807819a89afdd4b000b5ad02391181f38a06048`,
matching the existing v0.6.0 signing identity.

Mac rebuilt affected core and relinked the existing target 15 app with Xcode 27.
Version 0.7.0/build11, eighteen arm64/min15 Mach-O files, unchanged bundle
resources/licenses, dependency/RPATH closure, per-binary and deep strict
ad-hoc signatures, and ZIP CRC pass. Existing runtime evidence is retained;
this final packaging does not repeat smoke/device experiments.

Windows incrementally rebuilt the affected native DLL in its existing x64
toolchain and retained the accepted unchanged 0.7.0/build11 WPF/.NET8 runtime
and resource payload. The new package records native/source hashes and
passive package checks. No security setting, anti-malware policy, native
runtime/GUI/GPU test or Windows signing was added.

Corresponding source is generated from the exact release Git tree, with
fixed dependency archives, actual patched LibRaw, wrapper, build support
and notices. Both different pinned zlib 1.3.1 source archives are preserved
by URL/hash. Private RAWs/photographs, build binaries and credentials are
excluded. Final source asset checksums belong in the downloadable checksum
manifest, not this earlier committed build report.

## Reused Acceptance

[Sony verification](https://github.com/dancancer/RawLab/blob/a38ac6065f747cc43ddbee1c8df232c049b288d2/docs/verification-android-sony-dng-memory-2026-10-14.md) and
[dual review](../reviews/self-android-sony-dng-memory-20261014-0025.md) bind
the exact nine-code-file manifest
`60f5442e5ccd47525d567a0125fd0e8731b1ef2607c562fce79c5229e4027ecf`.
The release absorbed those same source files without alteration. Existing
core CPU 23/23, Metal 4/4, focused wavelet/fallback, disabled-core build,
Android 68 unit tests/lint and full-size CPU/GLES byte equality are reused.
Two independent reviews have no Must/Should. No additional tests or review
were commissioned for this delivery; changed artifacts received build and
package/signature checks only.

## Limits

iOS distribution is blocked by missing valid Apple signing identity and
provisioning profile. The stale unsigned pre-fix IPA is not a release asset;
users can build and sign from current source. Intel Mac has no 0.7 package.
Mac remains ad-hoc signed/unnotarized and Windows unsigned.

GPU acceptance is ≥6GB by user confirmation; actual Force GLES is on an
approximately 12GB Lenovo device, not an exact 6GB measurement. Physical
macOS15, iOS Files cancellation and Windows desktop SaveFileDialog/Explorer
remain outside existing proof. All results are local rather than hosted CI.
Original pre-fix candidates are retained locally with their original hashes.
