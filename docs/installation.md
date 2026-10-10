# Installation

Get current packages and checksums from the [latest release](https://github.com/dancancer/RawLab/releases/latest). Changes are listed in the [changelog](../CHANGELOG.md).

## Packages

| Platform | v0.5.0 package | Requirements |
| --- | --- | --- |
| Windows | [x64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Windows-0.5.0-win-x64.zip) | Windows 10/11 x64 |
| macOS Apple Silicon | [arm64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Mac-0.5.0-macOS15-arm64.zip) | macOS 15+ |
| macOS Intel | [x86_64 ZIP](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Mac-0.5.0-macOS15-x86_64.zip) | macOS 15+ |
| Android | [Signed APK](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-Android-0.5.0.apk) | Android 8.0+, ARM64 or x86_64 |
| iOS | [Unsigned IPA](https://github.com/dancancer/RawLab/releases/download/v0.5.0/RawLab-iOS-0.5.0-unsigned.ipa) | iOS 18+, iPhone; re-signing required |

[SHA-256 checksums](https://github.com/dancancer/RawLab/releases/download/v0.5.0/SHA256SUMS.txt) cover the release assets.

## Windows

Extract the ZIP and run `RawLab.exe`, keeping the entire directory. The package
includes .NET 8, Visual C++/OpenMP runtime libraries, LUTs and ExifTool. It is
unsigned. See the [Windows documentation](../RawLabWindows/README.md) for source
builds and [performance measurements](../RawLabWindows/performance.md).

## macOS

Choose the architecture matching your Mac and move `RawLab Mac.app` to
Applications. Apps are ad-hoc signed, not Developer ID signed or notarized;
macOS may block opening them. The executable and dependencies target macOS 15,
but physical macOS 15 testing is still pending. Intel validation uses Rosetta,
not native Intel hardware. See the [macOS documentation](../RawLabMac/README.md).

## Android

The APK retains the release signing identity, so it can update earlier
release-signed versions. It cannot replace a differently signed debug build.
Export any unsaved work before uninstalling a debug build. See the
[Android documentation](../RawLabAndroid/README.md).

## iOS

**The unsigned IPA cannot be installed directly.** Re-sign the application and
embedded framework with your own valid certificate and provisioning profile.
It is not an App Store or TestFlight package. Physical-device installation,
memory and thermal validation remain outstanding. See the
[iOS build documentation](../lutools/platform/ios/README.md).

## Source and Licenses

The release provides corresponding source, pinned dependency sources and build
instructions alongside the binaries. Original project code is distributed
under [GPLv3 only](../LICENSE); dependencies and resources retain their own
licenses. See [licensing](licensing.md) and the [release notes](releases/v0.5.0.md).

RAW files and private signing material are never included in source packages.
