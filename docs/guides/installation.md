# Installation

Get current packages and checksums from the [latest release](https://github.com/dancancer/RawLab/releases/latest). Changes are listed in the [changelog](../../CHANGELOG.md).

## Packages

| Platform | Package | Requirements |
| --- | --- | --- |
| Windows | [0.9.2 current-user Setup](https://github.com/dancancer/RawLab/releases/download/v0.9.2/RawLab.Desktop-stable-Setup.exe), [manual ZIP](https://github.com/dancancer/RawLab/releases/download/v0.9.2/RawLab-Windows-0.9.2-x64.zip) | Windows 10/11 x64 |
| macOS Apple Silicon | [0.9.2 arm64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.9.2/RawLab-Mac-0.9.2-arm64.zip) | macOS 14+; HDR editing requires macOS 15+ |
| macOS Intel | [0.9.2 x86_64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.9.2/RawLab-Mac-0.9.2-x86_64.zip) | macOS 14+; HDR editing requires macOS 15+; no AI denoising |
| Android | [0.9.2 signed APK](https://github.com/dancancer/RawLab/releases/download/v0.9.2/RawLab-Android-0.9.2.apk) | Android 8+, ARM64 or x86_64 |
| iOS | [0.9.2 unsigned IPA](https://github.com/dancancer/RawLab/releases/download/v0.9.2/RawLab-iOS-0.9.2-unsigned.ipa) | iOS 18+; valid user signing/provisioning required |

[0.9.2 SHA-256 checksums](https://github.com/dancancer/RawLab/releases/download/v0.9.2/SHA256SUMS.txt)
cover this release's assets. No directly installable iOS package is published.

## Windows

Use the current-user Setup for automatic-update support. Alternatively, extract
the manual ZIP and run `RawLab.exe`, keeping the entire directory; ZIP installs
require manual updates. The packages include .NET 8, runtime libraries, LUTs,
ExifTool and GPU AI models. AI denoising requires a hardware DirectML/D3D12 GPU.

The packages do not use Authenticode. SmartScreen may require **More info → Run
anyway** on first installation. Later updates verify a signed release manifest
that binds the package size and SHA-256. Automatic checks are enabled by default;
automatic download and installation on quit require the user to enable that
option. Upgrading from 0.8.2 requires one manual installation of 0.9.0 or later.
See the [Windows documentation](../../RawLabWindows/README.md) for source builds.

## macOS

Choose the architecture matching your Mac and move `RawLab Mac.app` to a location
the current user can write to, such as Applications. Apps use a fixed self-signed
certificate and Sparkle EdDSA update signatures; they are not notarized. First
launch may require **System Settings → Privacy & Security → Open Anyway**.
Automatic checks are enabled by default; automatic download and installation on
quit require the user to enable that option.

Apple Silicon packages include GPU AI denoising with Core ML; Intel packages
omit AI models and controls. Ordinary editing targets macOS 14, while HDR
editing/export requires macOS 15+. A newer-system build does not establish
minimum-OS or physical Intel acceptance; see the exact coverage in the
[release notes](../releases/v0.9/v0.9.2.md) and
[macOS documentation](../../RawLabMac/README.md).

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
licenses. See [licensing](../reference/licensing.md) and the [release notes](../releases/v0.9/v0.9.2.md).

RAW files and private signing material are never included in source packages.
