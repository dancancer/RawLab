# Third-party components

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
LibRaw and zlib source archives and verifies their hashes before compilation.
The ExifTool runtime archive is also version-pinned and hash-verified.
