# Third-party components

- Optional experimental AI denoise: DualDn by OpenImagingLab
  (https://github.com/OpenImagingLab/DualDn), CC BY-NC 4.0, OpenImagingLab 2024. The exported package
  carries the upstream license and model/checkpoint provenance. ONNX Runtime
  DirectML 1.23.0 is MIT-licensed; DirectML 1.15.4 is distributed under Microsoft's
  package license. AI-enabled builds include their original notices under
  `Licenses/DualDn`; standard builds do not bundle these components or weights.

- Lens correction: Lensfun 0.3.4 (LGPL-3.0-or-later), GLib 2.84.4
  (LGPL-2.1-or-later), PCRE2 10.44 (BSD), proxy-libintl (LGPL-2.0-or-later)
  and upstream bundled TRE. Statically linked into sony2fuji.dll.
  Sources and SHA256 pins: `lutools/cmake/lens-dependencies.json`; build script:
  `lutools/cmake/build-lens-dependencies.py`. Original texts/attribution are in
  `Licenses/lensfun`. The unmodified offline DB1 snapshot (2026-10-12) uses
  CC BY-SA 3.0; it is separately licensed from the library and stored in `Lensfun`.
  https://lensfun.github.io/ and https://gitlab.gnome.org/GNOME/glib
  https://github.com/PCRE2Project/pcre2 and https://github.com/frida/proxy-libintl


- Lucide Film icon: https://lucide.dev/icons/film, ISC license. Converted from
  the upstream SVG to WPF vector geometry; notice in `Licenses/Lucide-LICENSE.txt`.

- LibRaw 0.22.2: https://github.com/LibRaw/LibRaw/tree/0.22.2
  Built as a replaceable `raw.dll`; redistribution here uses the LGPL 2.1 option.
  Copyright and both upstream license options are in `Licenses/LibRaw-*`.
  Corresponding source: https://www.libraw.org/data/LibRaw-0.22.2.tar.gz
  The exact source archive and SHA-256 are pinned in `native/CMakeLists.txt`.
  Local crop, X-Trans concurrency and Nikon recognition changes are applied by
  `lutools/cmake/patch-libraw.cmake` in the RawLab source repository.
  R6 III layout/matrix evidence is from ErikCJohansson's contribution at
  https://github.com/LibRaw/LibRaw/issues/821; the parser reuses LibRaw v12 offsets.
  This local correction does not imply upstream R6 III support.
- Nikon HE decoder: local C++ adaptation of Nicolai Buchwitz's dnglab commit
  0f044c2c30d78c4ed5fcede6ab4e8db893d566f6 and LibRaw PR 826 by Dmitri Sotnikov,
  with RdWing's reconstruction/transfer corrections. LGPL 2.1, not CDDL.
  Attribution, source links and modification details: `Licenses/nikon-he/README.md`;
  full license: `Licenses/nikon-he/LICENSE.LGPL-2.1`.
- Additional camera matrix data: adapted from RawSpeed contributors' cameras.xml,
  https://github.com/darktable-org/rawspeed/blob/c835b05aecfacb7343f7c424abd620aa12116c3f/data/cameras.xml
  CC BY-SA 3.0, https://creativecommons.org/licenses/by-sa/3.0/.
  The adapted data remains under that license in
  `lutools/third_party/rawspeed-camera-calibration.inc`. Changes: four exact-model
  matrices extracted into LibRaw table syntax; black/white levels remain metadata-driven.
- zlib 1.3.1: https://github.com/madler/zlib/tree/v1.3.1, zlib license.
- libjpeg-turbo 3.1.3: https://github.com/libjpeg-turbo/libjpeg-turbo/tree/3.1.3.
  Static JPEG8 support for JPEG-compressed lossy DNG. IJG/BSD/zlib license notices
  are included in `Licenses/libjpeg-turbo/`.
- LibRaw's Sigma X3F tools are enabled; Roland Karlsson's BSD-style notice is
  included in `Licenses/LibRaw-X3F-BSD.txt`.
- OpenCV 4.12.0: https://github.com/opencv/opencv/tree/4.12.0, Apache 2.0.
  Static core/imgproc libraries support linear-light wavelet denoising.
  See `Licenses/OpenCV-LICENSE`.
- libtiff 4.7.1: https://gitlab.com/libtiff/libtiff, libtiff license.
  The static Windows build is used only by the rendered-DNG writer. The exact
  source archive and SHA-256 are pinned in `lutools/cmake/tiff-dependencies.cmake`;
  its `LICENSE.md` is included in `Licenses/libtiff/`.
- wavelib: https://github.com/rafat/wavelib/tree/7f61bf592f3c470b2a7d8199431fde821d7253ac, BSD 3-Clause.
  The exact revision and source hash are pinned in `lutools/cmake/denoise-dependencies.cmake`.
  Local stationary-wavelet column and inverse-transform optimizations are in
  `lutools/cmake/wavelib-swt-columns.c.inc` and `wavelib-iswt2.c.inc`.
  See `Licenses/wavelib-COPYRIGHT`.
- ExifTool 13.59: https://exiftool.org/, copyright Phil Harvey, distributed under
  the same terms as Perl (Artistic License or GNU GPL). The Windows x64 package
  is from the Windows packager linked by ExifTool:
  https://oliverbetz.de/pages/Artikel/ExifTool-for-Windows.
  The complete distribution, sources and Perl runtime notices are retained under
  `ExifTool/exiftool_files/`, including `LICENSE` and `Licenses_Strawberry_Perl.zip`.
  The Windows launcher is CC0; see `readme_windows.txt` in that directory.
  Archive URL and SHA-256 are pinned in `build-exiftool.ps1`.
- stb image and image write: MIT option; license in `Licenses/stb-MIT-LICENSE.txt`.
- Adobe DNG SDK temperature conversion: retained notice in
  `Licenses/Adobe-DNG-SDK-LICENSE.txt`.
- Adobe DNG SDK 1.7.1 Build 2724 and its bundled JPEG XL, Brotli, Highway and
  skcms sources: version and archive hash in `lutools/cmake/dng-sdk.cmake`.
  Source: https://download.adobe.com/pub/adobe/dng/dng_sdk_1_7_1_2724_20260908.zip
  Statically linked for JPEG XL DNG decoding. XMP editing and the validator are
  disabled; the local adapter adds missing XMP guards to `dng_jxl.cpp`.
  Full original licenses are included in `Licenses/dng-sdk/`.
  This product includes DNG technology under license by Adobe.
- Fujifilm F-Log2 LUTs: existing repository assets, copied unchanged. See the
  included `LUTs/F-Log2_LUT_overview_Ver.2.0E.pdf`. Names identify simulations;
  this client is not affiliated with Fujifilm.
- Film artwork and app icon reuse the Mac client's generated assets. Provenance
  is recorded in `RawLabMac/Resources/AppIcon.md` and `FilmIcons/generated-set-*.md`.
- Microsoft .NET / WPF: https://github.com/dotnet/wpf, MIT.
  Framework-dependent builds require the .NET 8 Desktop Runtime. Self-contained
  packages include Microsoft's runtime license and third-party notices.
- Microsoft Visual C++ runtime: app-local redistributable DLLs supplied by the
  installed Visual Studio Build Tools, under Microsoft's distribution terms.
- Alibaba Cloud RUM PC SDK 0.4.4 for Windows (`alibabacloud_rum.dll`, x64 Release),
  used only for opt-out usage analytics. Unmodified vendor binary from
  https://rum-sdk.oss-cn-hangzhou.aliyuncs.com/native/AlibabaCloud_RUM_Windows_0.4.4.zip
  (the vendor guide https://help.aliyun.com/zh/cms/cloudmonitor-2-0/access-pc-platform-application
  links the same bytes as `AlibabaCloud_RUM_Windows.zip`). The archive and DLL SHA-256
  are pinned in `RawLabWindows.csproj`. The archive ships no license text; the SDK's
  license and redistribution terms are pending written confirmation from the vendor.
  RawLab's own code is combined with it under `Licenses/RawLab-Aliyun-RUM-Exception.txt`,
  which grants no rights in the SDK itself. Only custom usage events are enabled;
  automatic crash, network and CEF collection are turned off. Offline packages built
  with `build.ps1 -NoRumSdk` omit the DLL.

The shared DCP compiler uses JSON for Modern C++ (Niels Lohmann), under MIT.
Its original notice is included as `Licenses/nlohmann-JSON-MIT.txt`.

No binaries are checked into source control. The build downloads version-pinned
LibRaw, zlib, libtiff, DNG SDK/JPEG XL, OpenCV and wavelib source archives and verifies their hashes before compilation.
The ExifTool runtime archive and the RUM SDK archive are also version-pinned and hash-verified.

Sony ARW6 decoding and A7 V metadata are backported from LibRaw e419de0;
A1 II, EOS R50 V and PowerShot V1 metadata come from upstream PRs 775/846,
784 and 856 under the original LibRaw LGPL/CDDL terms. Pinned sources and
format boundaries: docs/reference/raw-format-support.md.
