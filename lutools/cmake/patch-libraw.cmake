# Keep the released 0.22.2 ABI while backporting narrowly scoped fixes.
if(NOT DEFINED LIBRAW_SOURCE_DIR)
    message(FATAL_ERROR "LIBRAW_SOURCE_DIR is required")
endif()

function(replace_libraw relative before after)
    if("${before}" STREQUAL "")
        message(FATAL_ERROR "Empty LibRaw patch anchor: ${relative}")
    endif()
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

include("${CMAKE_CURRENT_LIST_DIR}/libraw-sony-arw6.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/libraw-cameras.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/libraw-vng.cmake")

# 只替换 Nikon HE 像素解码，保留 LibRaw 的元数据、白平衡与显影流程。
set(nikon_he_source "${CMAKE_CURRENT_LIST_DIR}/../third_party/nikon_he")
file(MAKE_DIRECTORY "${LIBRAW_SOURCE_DIR}/src/decoders/rawlab_nikon_he")
foreach(name codec.h internal.h parser.cpp entropy.cpp dwt.cpp output.cpp libraw_adapter.inc README.md LICENSE.LGPL-2.1)
    configure_file("${nikon_he_source}/${name}"
        "${LIBRAW_SOURCE_DIR}/src/decoders/rawlab_nikon_he/${name}" COPYONLY)
endforeach()
replace_libraw(src/decoders/decoders_libraw_dcrdefs.cpp
    "#include \"../../internal/dcraw_defs.h\""
    "#include \"../../internal/dcraw_defs.h\"\n#include \"rawlab_nikon_he/codec.h\"")
set(nikon_he_placeholder "void LibRaw::nikon_he_load_raw()\n{\n    if(dng_version)\n    \tthrow LIBRAW_EXCEPTION_UNSUPPORTED_FORMAT; // Never reached\n    throw LIBRAW_EXCEPTION_UNSUPPORTED_FORMAT;\n}\n")
replace_libraw(src/decoders/decoders_libraw_dcrdefs.cpp "${nikon_he_placeholder}"
    "#include \"rawlab_nikon_he/libraw_adapter.inc\"\n")
replace_libraw(src/utils/decoder_info.cpp [=[
    d_info->decoder_name = "nikon_he_load_raw()";
    d_info->decoder_flags = LIBRAW_DECODER_UNSUPPORTED_FORMAT;
]=] [=[
    d_info->decoder_name = "nikon_he_load_raw()";
    d_info->decoder_flags = 0;
]=])
foreach(model "Z 6 III" "Z 8" "Z 9" "Z f")
    replace_libraw(src/tables/cameralist.cpp
        "\"Nikon ${model} (HE/HE* formats are not supported yet)\""
        "\"Nikon ${model}\"")
endforeach()

# SDK 的平台和类布局开关必须与调用方一致，不能把 iOS 强制当成 macOS。
replace_libraw(libraw/libraw_datastream.h [=[
#if defined LIBRAW_WIN32_CALLS
#define qWinOS 1
#define qMacOS 0
#elif defined(__APPLE__)
#define qWinOS 0
#define qMacOS 1
#else
/* define OS types for DNG here */
#endif
#define qDNGXMPDocOps 0
#define qDNGUseLibJPEG 1
#define qDNGXMPFiles 0
#define qDNGExperimental 1
#define qDNGThreadSafe 1
]=] [=[
#if !(defined(qMacOS) || defined(qWinOS) || defined(qiPhone) || defined(qAndroid) || defined(qLinux))
#if defined LIBRAW_WIN32_CALLS
#define qWinOS 1
#define qMacOS 0
#elif defined(__APPLE__)
#define qWinOS 0
#define qMacOS 1
#endif
#endif
#ifndef qDNGXMPDocOps
#define qDNGXMPDocOps 0
#endif
#ifndef qDNGUseLibJPEG
#define qDNGUseLibJPEG 1
#endif
#ifndef qDNGXMPFiles
#define qDNGXMPFiles 0
#endif
#ifndef qDNGExperimental
#define qDNGExperimental 1
#endif
#ifndef qDNGThreadSafe
#define qDNGThreadSafe 1
#endif
]=])

# JPEG XL 没有备用解码器，SDK 失败必须中止，不能回落到占位器或使用半解码数据。
file(READ "${LIBRAW_SOURCE_DIR}/src/decoders/unpack.cpp" unpack_source)
string(FIND "${unpack_source}" "if (dng_result == LIBRAW_UNSUFFICIENT_MEMORY)" has_memory_mapping)
if(has_memory_mapping EQUAL -1)
    replace_libraw(src/decoders/unpack.cpp
        "      try_dngsdk();"
        "      const int dng_result = try_dngsdk();\n      if (load_raw == &LibRaw::jxl_dng_load_raw_placeholder && dng_result != LIBRAW_SUCCESS)\n        throw LIBRAW_EXCEPTION_DECODE_RAW;")

    # 兼容已打过旧补丁的源码缓存，并保留 SDK 返回的内存不足类别。
    replace_libraw(src/decoders/unpack.cpp
        "      if (load_raw == &LibRaw::jxl_dng_load_raw_placeholder && dng_result != LIBRAW_SUCCESS)\n        throw LIBRAW_EXCEPTION_DECODE_RAW;"
        "      if (load_raw == &LibRaw::jxl_dng_load_raw_placeholder && dng_result != LIBRAW_SUCCESS)\n      {\n        if (dng_result == LIBRAW_UNSUFFICIENT_MEMORY)\n          throw LIBRAW_EXCEPTION_ALLOC;\n        throw LIBRAW_EXCEPTION_DECODE_RAW;\n      }")
endif()

# Stage2 的像素已经去掉 ActiveArea 外边缘；DefaultCrop 也要换成新图像坐标。
replace_libraw(src/integration/dngsdk_glue.cpp
    "\t\t\tS.raw_width = S.width = stage2->Bounds().W();"
    "\t\t\tif (stageBits & 2)\n\t\t\t{\n\t\t\t\tfor (auto &crop : S.raw_inset_crops)\n\t\t\t\t{\n\t\t\t\t\tif (crop.cleft == 0xffff || crop.ctop == 0xffff)\n\t\t\t\t\t\tcontinue;\n\t\t\t\t\tif (crop.cleft < S.left_margin || crop.ctop < S.top_margin)\n\t\t\t\t\t\tcrop.cleft = crop.ctop = 0xffff;\n\t\t\t\t\telse\n\t\t\t\t\t{\n\t\t\t\t\t\tcrop.cleft -= S.left_margin;\n\t\t\t\t\t\tcrop.ctop -= S.top_margin;\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t\tS.raw_width = S.width = stage2->Bounds().W();")
replace_libraw(src/integration/dngsdk_glue.cpp
    "#include \"dng_host.h\""
    "#include \"dng_host.h\"\n#include \"dng_exceptions.h\"\n#include <new>")
replace_libraw(src/integration/dngsdk_glue.cpp [=[
  catch (...)
  {
    imgdata.process_warnings |= LIBRAW_WARN_DNG_NOT_PROCESSED;
    return LIBRAW_UNSPECIFIED_ERROR;
  }
]=] [=[
  catch (const dng_exception &error)
  {
    imgdata.process_warnings |= LIBRAW_WARN_DNG_NOT_PROCESSED;
    return error.ErrorCode() == dng_error_memory ? LIBRAW_UNSUFFICIENT_MEMORY
                                               : LIBRAW_UNSPECIFIED_ERROR;
  }
  catch (const std::bad_alloc &)
  {
    imgdata.process_warnings |= LIBRAW_WARN_DNG_NOT_PROCESSED;
    return LIBRAW_UNSUFFICIENT_MEMORY;
  }
  catch (...)
  {
    imgdata.process_warnings |= LIBRAW_WARN_DNG_NOT_PROCESSED;
    return LIBRAW_UNSPECIFIED_ERROR;
  }
]=])

configure_file("${CMAKE_CURRENT_LIST_DIR}/../third_party/rawspeed-camera-calibration.inc"
    "${LIBRAW_SOURCE_DIR}/src/tables/rawlab_camera_calibration.inc" COPYONLY)
replace_libraw(src/tables/colordata.cpp
    "  } table[] = {"
    "  } table[] = {\n#include \"rawlab_camera_calibration.inc\"")

# These new Nikon model strings must reach the existing JPEG-XS marker check,
# not the legacy lossless decoder; HE/HE* decoding has its own validated path.
replace_libraw(src/metadata/tiff.cpp
    "|| !strcmp(model, \"NIKON Z6_3\")) &&"
    "|| !strcmp(model, \"NIKON Z6_3\") || !strcmp(model, \"NIKON Z5_2\") || !strcmp(model, \"NIKON Z50_2\")) &&")

# PowerShot V1 subversion 65 and R6 III subversion 66 use the existing v12 offsets.
# Layout and Adobe-derived matrix: https://github.com/LibRaw/LibRaw/issues/821
# This is a sample-verified local fix, not a claim of upstream camera support.
# 兼容已缓存的 R6 III 补丁；V1 与 R6 III 共享 V12 布局。
file(READ "${LIBRAW_SOURCE_DIR}/src/metadata/canon.cpp" canon_source)
string(FIND "${canon_source}" "if (len == 3778 && imCanon.ColorDataSubVer == 66)" old_canon_layout)
if(NOT old_canon_layout EQUAL -1)
    replace_libraw(src/metadata/canon.cpp
        "if (len == 3778 && imCanon.ColorDataSubVer == 66)"
        "if (len == 3778 && (imCanon.ColorDataSubVer == 65 || imCanon.ColorDataSubVer == 66))")
endif()
replace_libraw(src/metadata/canon.cpp [=[
      imCanon.ColorDataVer = 11;
      AsShot_Auto_MeasuredWB(0x0069);
]=] [=[
      imCanon.ColorDataVer = 11;
      AsShot_Auto_MeasuredWB(0x0069);
      if (len == 3778 && (imCanon.ColorDataSubVer == 65 || imCanon.ColorDataSubVer == 66))
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
