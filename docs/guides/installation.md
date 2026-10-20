# Installation

Get current packages and checksums from the [latest release](https://github.com/dancancer/RawLab/releases/latest). Changes are listed in the [changelog](../../CHANGELOG.md).

## Packages

| Platform | Package | Requirements |
| --- | --- | --- |
| Windows | [v0.8.2 x64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.8.2/RawLab-Windows-0.8.2-win-x64.zip) | Windows10/11 x64 |
| macOS Apple Silicon | [v0.8.2 arm64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.8.2/RawLab-Mac-0.8.2-macOS14-arm64.zip) | macOS14 deployment target |
| Android | [v0.8.2 signed APK](https://github.com/dancancer/RawLab/releases/download/v0.8.2/RawLab-Android-0.8.2.apk) | Android8+, ARM64 or x86_64 |
| macOS Intel | [v0.8.2 x86_64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.8.2/RawLab-Mac-0.8.2-macOS14-x86_64.zip) | macOS14 deployment target |
| iOS | [v0.8.2 unsigned IPA](https://github.com/dancancer/RawLab/releases/download/v0.8.2/RawLab-iOS-0.8.2-unsigned.ipa) | iOS18+; unsigned IPA needs valid user signing/provisioning |

[v0.8.2 SHA-256 checksums](https://github.com/dancancer/RawLab/releases/download/v0.8.2/SHA256SUMS.txt)
cover this release's assets. No directly installable iOS package is published.

## Windows

Extract the ZIP and run `RawLab.exe`, keeping the entire directory. The package
includes .NET 8, Visual C++/OpenMP runtime libraries, LUTs and ExifTool. It is
unsigned. See the [Windows documentation](../../RawLabWindows/README.md) for source
builds and [performance measurements](../../RawLabWindows/performance.md).

## macOS

Choose the architecture matching your Mac and move `RawLab Mac.app` to
Applications. Apps are ad-hoc signed, not Developer ID signed or notarized;
macOS may block opening them. The executable and dependencies target macOS 14;
actual minimum-OS runtime acceptance remains limited. Hosted Apple Silicon and
Intel macOS 26 build/parity results do not establish a macOS 14 physical-device
pass. See the [macOS documentation](../../RawLabMac/README.md).

## Android

The APK retains the release signing identity, so it can update earlier
release-signed versions. It cannot replace a differently signed debug build.
Export any unsaved work before uninstalling a debug build. See the
[Android documentation](../../RawLabAndroid/README.md).

## iOS

For step-by-step personal-device installation, see the
[iPhone installation guide](ios-installation.md)
([Simplified Chinese](ios-installation.zh-CN.md)), including an executable
workflow for AI agents.

**Unsigned IPAs cannot be installed directly.** This release has no valid Apple
signing/provisioning configuration, so the supplemental unsigned IPA is not an
installable download. Re-sign the application and
embedded framework with your own valid certificate and provisioning profile.
It is not an App Store or TestFlight package. Physical-device installation,
memory and thermal validation remain outstanding. See the
[iOS build documentation](../../lutools/platform/ios/README.md).

## Source and Licenses

The release provides corresponding source, pinned dependency sources and build
instructions alongside the binaries. Original project code is distributed
under [GPLv3 only](../../LICENSE); dependencies and resources retain their own
licenses. See [licensing](../reference/licensing.md) and the [release notes](../releases/v0.8/v0.8.2.md).

RAW files and private signing material are never included in source packages.
