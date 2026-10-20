# LibRaw e419de0：ARW6 解码、A7 V 元数据及后续黑白电平修正，保留 0.22.2 ABI。
configure_file("${CMAKE_CURRENT_LIST_DIR}/../third_party/libraw/sony_arw6.cpp"
    "${LIBRAW_SOURCE_DIR}/src/decoders/sony_arw6.cpp" COPYONLY)
replace_libraw(internal/libraw_internal_funcs.h
    "void        sony_arw2_load_raw();"
    "void        sony_arw2_load_raw();\n\tvoid        sony_arw6_load_raw();")
replace_libraw(src/metadata/tiff.cpp "    case 32767:" [=[
    case 32766:
      if (!dng_version && !strncasecmp(make, "Sony", 4) &&
          tiff_ifd[raw].phint == 32803 && tiff_ifd[raw].samples == 1 &&
          (tiff_bps == 12 || tiff_bps == 14) && raw_width > 0 && raw_height > 0)
      {
        load_raw = &LibRaw::sony_arw6_load_raw;
        tiff_bps = 14;
      }
      break;
    case 32767:
]=])
replace_libraw(src/utils/decoder_info.cpp
    "  else if (load_raw == &LibRaw::sony_arq_load_raw)" [=[
  else if (load_raw == &LibRaw::sony_arw6_load_raw)
  {
    d_info->decoder_name = "sony_arw6_load_raw()";
    d_info->decoder_flags = LIBRAW_DECODER_HASCURVE | LIBRAW_DECODER_FIXEDMAXC;
  }
  else if (load_raw == &LibRaw::sony_arq_load_raw)
]=])
replace_libraw(src/utils/open.cpp [=[
        S.width = S.raw_width - 32;
    }
]=] [=[
        S.width = S.raw_width - 32;
      if (load_raw == &LibRaw::sony_arw6_load_raw)
      {
        C.black = 1024;
        for (int c = 0; c < 6; c++)
          C.cblack[c] = 0;
        C.maximum = 39002;
        for (int c = 0; c < 4; c++)
          C.linear_max[c] = 32800;
      }
    }
]=])
file(READ "${LIBRAW_SOURCE_DIR}/internal/libraw_cameraids.h" camera_ids)
if(NOT camera_ids MATCHES "#define SonyID_ILCE_7M5")
    replace_libraw(internal/libraw_cameraids.h
        "#define SonyID_ILME_FX2         0x196ULL"
        "#define SonyID_ILME_FX2         0x196ULL\n#define SonyID_ILCE_7M5         0x197ULL")
endif()
replace_libraw(src/metadata/normalize_model.cpp
    "{ SonyID_ILME_FX2,       \"ILME-FX2\"},"
    "{ SonyID_ILME_FX2,       \"ILME-FX2\"},\n      { SonyID_ILCE_7M5,       \"ILCE-7M5\"},")
replace_libraw(src/metadata/sony.cpp [=[
      {SonyID_ZV_E10M2, sbfILCE_DX,
       LIBRAW_SONY_Tag2010None, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff},
]=] [=[
      {SonyID_ZV_E10M2, sbfILCE_DX,
       LIBRAW_SONY_Tag2010None, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff},
      {SonyID_ILCE_7M5, sbfILCE_FF,
       LIBRAW_SONY_Tag2010None, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff},
]=])
replace_libraw(src/metadata/sony.cpp
    "  case SonyID_ILCE_9M3:\n  case SonyID_ZV_E10M2:"
    "  case SonyID_ILCE_9M3:\n  case SonyID_ILCE_7M5:\n  case SonyID_ZV_E10M2:")
replace_libraw(src/metadata/identify.cpp
    "(unique_id == SonyID_ILCE_7M4)|| (unique_id == SonyID_ILCE_7CM2) || (unique_id == SonyID_ILME_FX2)"
    "(unique_id == SonyID_ILCE_7M4)|| (unique_id == SonyID_ILCE_7CM2) || (unique_id == SonyID_ILME_FX2) || (unique_id == SonyID_ILCE_7M5)")
replace_libraw(src/tables/colordata.cpp
    "    { LIBRAW_CAMERAMAKER_Sony, \"ILCE-7M4\", 0, 0," [=[
    { LIBRAW_CAMERAMAKER_Sony, "ILCE-7M5", 0, 0,
      { 9089, -3577, -787, -3563, 11326, 2557, -114, 928, 5904 } },
    { LIBRAW_CAMERAMAKER_Sony, "ILCE-7M4", 0, 0,
]=])
replace_libraw(src/tables/cameralist.cpp
    "\"Sony ILCE-7M4 (A7 IV)\","
    "\"Sony ILCE-7M4 (A7 IV)\",\n\t\"Sony ILCE-7M5 (A7 V)\",")
