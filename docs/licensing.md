# Licensing and Attribution

Copyright (c) 2026 RawLab contributors.

## RawLab v0.5.0 and Later

Unless an individual file or resource specifies otherwise, original RawLab
project code in this release is distributed under version 3 of the GNU General
Public License only (base SPDX identifier: `GPL-3.0-only`), with the additional
permission described below. The full GPL terms are in [LICENSE](../LICENSE),
using the unmodified [GNU GPLv3 text](https://www.gnu.org/licenses/gpl-3.0.txt).

RawLab is free software: you can redistribute it and/or modify it under the
terms of version 3 of the GNU General Public License as published by the Free
Software Foundation. It is distributed without any warranty, including the
implied warranties of merchantability or fitness for a particular purpose.

Release packages include `RawLab-GPL-3.0.txt`,
`RawLab-Aliyun-RUM-Exception.txt` and this notice. The release tag identifies
the corresponding project source; the release source archive also includes
pinned native dependency sources and the scripts needed to rebuild them,
subject to the narrow exception below. Signing keys, build-machine
credentials and personal RAW files are not distributed.

## Alibaba Cloud RUM Linking Exception

On 16 October 2026, the owner of the original RawLab project code authorized
the [RawLab Alibaba Cloud RUM SDK Linking Exception](../LICENSE-ALIYUN-RUM-EXCEPTION)
as an additional permission under GPLv3 section 7. GPLv3 remains the base
license; this is not a change to MIT or a general permission to link with
arbitrary non-GPL libraries.

Version 1.0 covers the native macOS/Windows SDK 0.4.4, Android SDK 2.3.2,
and iOS AlibabaCloudRUM/AlibabaCloudRUMSDK 2.4.2. It permits linking and
conveying combinations with those SDKs without requiring their source solely
under RawLab's GPL terms. RawLab's own code, modifications, integration code
and required build/install scripts remain subject to GPLv3 source obligations.
Other SDK releases are not automatically covered; see the exception's exact
scope for bundled runtime components and permitted SDK modifications.

The exception grants no rights in the SDKs or other third-party components.
Their own licenses, redistribution permissions, source obligations and
notices still apply. It does not establish that the SDKs may be redistributed
or that a combined package is ready for release.

Since 2026-10-17 release builds of all four clients include the listed SDK
versions by the copyright holder's decision; debug builds do not, and an
explicit opt-out produces a release package without them. The copyright holder
has taken responsibility for confirming each vendor SDK's redistribution terms;
until written confirmation exists, the packaged notices state that those terms
are pending. The exception itself still grants no rights in the SDKs.

## Third-Party Code and Resources

This change does not relicense third-party components or bundled resources.
Keep their license texts and attribution with redistributed copies:

- [macOS dependency notices](../RawLabMac/Resources/ThirdPartyNotices.md)
- [Windows dependency notices](../RawLabWindows/ThirdPartyNotices.md)
- [Android dependency notices](../RawLabAndroid/app/src/main/notices/ThirdPartyNotices.txt)
- [iOS dependency notices](../lutools/platform/ios/ThirdPartyNotices.md)

LibRaw is used under its LGPL option, with its CDDL alternative and copyright
notice also retained. Its corresponding patched source is supplied with the
release. OpenCV, wavelib, stb, Adobe-derived code, calibration data, ExifTool,
runtime libraries and LUTs retain their respective notices.

Profile-based lens correction uses unmodified Lensfun 0.3.4 (LGPL-3.0).
The vendored DB1 snapshot is separately licensed under CC BY-SA 3.0, with its
provenance, attribution and original license retained in
[the Lensfun dependency directory](../lutools/third_party/lensfun/README.md).
macOS packages also retain the GLib, gettext libintl and PCRE2 runtime notices.
iOS, Android and Windows statically link target-built Lensfun/GLib/PCRE2 and
proxy-libintl; Android also links GNU libiconv/libcharset, Windows bundled TRE.
Their original license texts accompany the clients. Pinned source URLs, hashes,
the iOS GLib availability-probe adjustment and complete rebuild commands live in
`lutools/cmake/lens-dependencies.json`, `build-lens-dependencies.py` and
[the native platform notes](lens-correction-platforms.md). Preserve those sources
and the application's corresponding source when redistributing a binary.

The optional edit JSON CLI adapter uses unmodified nlohmann JSON 3.12.0 (MIT).
Its source and license are retained in
[the dependency directory](../lutools/third_party/nlohmann/README.md).
CLI installations include its MIT license; native clients do not link this adapter.

## Historical MIT Notice

Earlier RawLab releases were published under MIT. Their published license is
not retroactively replaced. The following original notice is retained for
pre-v0.5.0 code incorporated into this GPLv3 distribution:

```text
MIT License

Copyright (c) 2026 RawLab contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
