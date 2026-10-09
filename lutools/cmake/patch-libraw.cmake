# Keep the released 0.22.2 ABI while backporting narrowly scoped fixes.
if(NOT DEFINED LIBRAW_SOURCE_DIR)
    message(FATAL_ERROR "LIBRAW_SOURCE_DIR is required")
endif()

function(replace_libraw relative before after)
    set(path "${LIBRAW_SOURCE_DIR}/${relative}")
    file(READ "${path}" source)
    string(FIND "${source}" "${after}" patched)
    if(NOT patched EQUAL -1)
        return()
    endif()
    string(FIND "${source}" "${before}" original)
    if(original EQUAL -1)
        message(FATAL_ERROR "Unexpected LibRaw source: ${relative}")
    endif()
    string(REPLACE "${before}" "${after}" source "${source}")
    file(WRITE "${path}" "${source}")
endfunction()

configure_file("${CMAKE_CURRENT_LIST_DIR}/../third_party/rawspeed-camera-calibration.inc"
    "${LIBRAW_SOURCE_DIR}/src/tables/rawlab_camera_calibration.inc" COPYONLY)
replace_libraw(src/tables/colordata.cpp
    "  } table[] = {"
    "  } table[] = {\n#include \"rawlab_camera_calibration.inc\"")

# These new Nikon model strings must reach the existing JPEG-XS marker check,
# not the legacy lossless decoder, even while HE/HE* decoding is unsupported.
replace_libraw(src/metadata/tiff.cpp
    "|| !strcmp(model, \"NIKON Z6_3\")) &&"
    "|| !strcmp(model, \"NIKON Z6_3\") || !strcmp(model, \"NIKON Z5_2\") || !strcmp(model, \"NIKON Z50_2\")) &&")

# R6 III ColorData subversion 66 uses the existing v12 offsets, not v11.
# Layout and Adobe-derived matrix: https://github.com/LibRaw/LibRaw/issues/821
# This is a sample-verified local fix, not a claim of upstream camera support.
replace_libraw(src/metadata/canon.cpp [=[
      imCanon.ColorDataVer = 11;
      AsShot_Auto_MeasuredWB(0x0069);
]=] [=[
      imCanon.ColorDataVer = 11;
      AsShot_Auto_MeasuredWB(0x0069);
      if (len == 3778 && imCanon.ColorDataSubVer == 66)
      {
        imCanon.ColorDataVer = 12;
        fseek(ifp, save1 + ((0x006d+0x0001) << 1), SEEK_SET);
        Canon_WBpresets(2, 12);
        fseek(ifp, save1 + ((0x0069+0x00d7) << 1), SEEK_SET);
        Canon_WBCTpresets(0);
        offsetChannelBlackLevel2 = save1 + ((0x0069+0x0116) << 1);
        offsetChannelBlackLevel  = save1 + ((0x0069+0x0227) << 1);
        offsetWhiteLevels        = save1 + ((0x0069+0x022b) << 1);
        break;
      }
]=])
replace_libraw(src/tables/colordata.cpp
    "#include \"rawlab_camera_calibration.inc\""
    "#include \"rawlab_camera_calibration.inc\"\n    { LIBRAW_CAMERAMAKER_Canon, \"EOS R6 Mark III\", 0, 0,\n      { 8309,-1786,-1095,-4851,12736,2353,-956,1911,5534 } },")

# Upstream bcb267e0d53808a7db857c79a21a4f6d7f2388a8: X2D II uses the same crop.
replace_libraw(src/metadata/identify.cpp
    "else if ((imHassy.SensorCode == 20) && imHassy.uncropped)"
    "else if ((imHassy.SensorCode == 20 || imHassy.SensorCode == 22) && imHassy.uncropped)")
replace_libraw(src/tables/cameralist.cpp
    "\"Hasselblad X2D 100C\","
    "\"Hasselblad X2D 100C\",\n    \"Hasselblad X2D II 100C\",")

# X-Trans tiles read overlapping halos but write their results into image.
# Snapshot all source reads so adjacent workers cannot consume developed pixels.
set(xtrans src/demosaic/xtrans_demosaic.cpp)
replace_libraw(${xtrans}
    "#include \"../../internal/dcraw_defs.h\""
    "#include \"../../internal/dcraw_defs.h\"\n#include <memory>")
replace_libraw(${xtrans}
    "  size_t buffer_size = LIBRAW_AHD_TILE"
    "  using SourcePixel = ushort[4];\n  const size_t source_count = size_t(width) * height;\n  std::unique_ptr<SourcePixel[]> source(new SourcePixel[source_count]);\n  memcpy(source.get(), image, source_count * sizeof(SourcePixel));\n  const SourcePixel* source_pixels = source.get();\n\n  size_t buffer_size = LIBRAW_AHD_TILE")
replace_libraw(${xtrans}
    "firstprivate(buffers, allhex, passes, sgrow, sgcol, ndir)"
    "firstprivate(buffers, allhex, passes, sgrow, sgcol, ndir, source_pixels)")
replace_libraw(${xtrans}
    "memcpy(rgb[0][row - top][col - left], image[row * width + col], 6);"
    "memcpy(rgb[0][row - top][col - left], source_pixels[row * width + col], 6);")
replace_libraw(${xtrans}
    "ushort (*pix)[4] = image + row * width + col;"
    "const ushort (*pix)[4] = source_pixels + row * width + col;")
replace_libraw(${xtrans}
    "ushort(*pix)[4] = image + row * width + col;"
    "const ushort(*pix)[4] = source_pixels + row * width + col;")
