# Third-party components

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
  Built as a replaceable `raw.dll`; redistribution here uses the CDDL 1.0 option.
  Copyright and both upstream license options are in `Licenses/LibRaw-*`.
  Corresponding source: https://www.libraw.org/data/LibRaw-0.22.2.tar.gz
  The exact source archive and SHA-256 are pinned in `native/CMakeLists.txt`.
  Local crop, X-Trans concurrency and Nikon recognition changes are applied by
  `lutools/cmake/patch-libraw.cmake` in the RawLab source repository.
  R6 III layout/matrix evidence is from ErikCJohansson's contribution at
  https://github.com/LibRaw/LibRaw/issues/821; the parser reuses LibRaw v12 offsets.
  This local correction does not imply upstream R6 III support.
- Additional camera matrix data: adapted from RawSpeed contributors' cameras.xml,
  https://github.com/darktable-org/rawspeed/blob/c835b05aecfacb7343f7c424abd620aa12116c3f/data/cameras.xml
  CC BY-SA 3.0, https://creativecommons.org/licenses/by-sa/3.0/.
  The adapted data remains under that license in
  `lutools/third_party/rawspeed-camera-calibration.inc`. Changes: four exact-model
  matrices extracted into LibRaw table syntax; black/white levels remain metadata-driven.
- zlib 1.3.1: https://github.com/madler/zlib/tree/v1.3.1, zlib license.
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

No binaries are checked into source control. The build downloads version-pinned
LibRaw, zlib, libtiff, DNG SDK/JPEG XL, OpenCV and wavelib source archives and verifies their hashes before compilation.
The ExifTool runtime archive is also version-pinned and hash-verified.
