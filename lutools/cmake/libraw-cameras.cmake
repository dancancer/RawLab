# LibRaw PR #775/#846 (A1 II), #784 (R50 V), #856 (PowerShot V1)，回移植到 0.22.2。
replace_libraw(internal/libraw_cameraids.h
[=[#define SonyID_ILME_FX2         0x196ULL
]=]
[=[#define SonyID_ILME_FX2         0x196ULL
#define SonyID_ILCE_1M2         0x190ULL
]=])

replace_libraw(src/metadata/identify.cpp
[=[        else if ((unique_id == SonyID_ILCE_7M4)]=]
[=[        else if(unique_id == SonyID_ILCE_1M2)
        {
			if (raw_width == 8672 && raw_height == 5784) // ILCE-1M2 FF uncompressed (4:3)
          {
            width = 8660;
            height = 5784;
          }
          if (raw_width == 8704 && raw_height == 6144) // ILCE-1M2 FF uncompressed (4:3)
          {
            width = 8660;
            height = 5784;
          }
		  else if (raw_width == 6144 && raw_height == 4096) // ILCE-1M2 FF uncompressed/lossy (3:2)
          {
            width = 5636;
            height = 3768;
          }
          else if (raw_width == 5664 && raw_height == 3768) // ILCE-1M2 FF uncompressed/lossy (3:2)
          {
            width = 5636;
            height = 3768;
          }
          else if (raw_width == 5632 && raw_height == 4096) // ILCE-1M2 FF lossless (4:3)
          {
            width = 5628;
            height = 3756;
          }
          else if (raw_width == 4608 && raw_height == 3072) // ILCE-1M2 lossless medium
          {
            width = 4332;
            height = 2892;
          }
          else
            imgdata.process_warnings |= LIBRAW_WARN_VENDOR_CROP_SUGGESTED;
        }
        else if ((unique_id == SonyID_ILCE_7M4)]=])

replace_libraw(src/metadata/normalize_model.cpp
[=[      { SonyID_ILCE_1,         "ILCE-1"},
]=]
[=[      { SonyID_ILCE_1,         "ILCE-1"},
      { SonyID_ILCE_1M2,       "ILCE-1M2"},
]=])

replace_libraw(src/metadata/sony.cpp
[=[      {SonyID_ILCE_1, sbfILCE_FF,
       LIBRAW_SONY_Tag2010None, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff},
]=]
[=[      {SonyID_ILCE_1, sbfILCE_FF,
       LIBRAW_SONY_Tag2010None, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff},
      {SonyID_ILCE_1M2, sbfILCE_FF,
       LIBRAW_SONY_Tag2010None, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff},
]=])

replace_libraw(src/metadata/sony.cpp
[=[  case SonyID_ILME_FX2:
]=]
[=[  case SonyID_ILME_FX2:
  case SonyID_ILCE_1M2:
]=])

replace_libraw(src/tables/cameralist.cpp
[=[	"Sony ILCE-1 (A1)",
]=]
[=[	"Sony ILCE-1 (A1)",
	"Sony ILCE-1M2 (A1 II)",
]=])

replace_libraw(src/tables/colordata.cpp
[=[    { LIBRAW_CAMERAMAKER_Sony, "ILCE-1", 0, 0,
]=]
[=[    { LIBRAW_CAMERAMAKER_Sony, "ILCE-1M2", 0, 0,
      { 10058, -4074, -932, -4777, 12731, 2274, -544, 1282, 6102}},
    { LIBRAW_CAMERAMAKER_Sony, "ILCE-1", 0, 0,
]=])

replace_libraw(internal/libraw_cameraids.h
[=[#define CanonID_EOS_M50_Mark_II   (0x80000000ULL + 0x468ULL)
]=]
[=[#define CanonID_EOS_M50_Mark_II   (0x80000000ULL + 0x468ULL)
#define CanonID_EOS_R50_V         (0x80000000ULL + 0x516ULL)
]=])

replace_libraw(src/metadata/canon.cpp
[=[           || (id == CanonID_EOS_R50)
]=]
[=[           || (id == CanonID_EOS_R50)
           || (id == CanonID_EOS_R50_V)
]=])

replace_libraw(src/metadata/canon.cpp
[=[    case 3973: // R3; ColorDataSubVer: 34
    case 3778: // R6 Mark II, R7, R8, R10, R50; ColorDataSubVer: 48
]=]
[=[    case 3973: // R3; ColorDataSubVer: 34
    case 3778: // R6 Mark II, R7, R8, R10, R50, R50 V; ColorDataSubVer: 48
]=])

replace_libraw(src/metadata/normalize_model.cpp
[=[      { CanonID_EOS_M50_Mark_II,   "EOS M50 Mark II"}, // M50m2, Kiss M2
]=]
[=[      { CanonID_EOS_M50_Mark_II,   "EOS M50 Mark II"}, // M50m2, Kiss M2
      { CanonID_EOS_R50_V,         "EOS R50 V"},
]=])

replace_libraw(src/tables/cameralist.cpp
[=[	"Canon EOS R10",
]=]
[=[	"Canon EOS R10",
	"Canon EOS R50 V",
]=])

replace_libraw(src/tables/colordata.cpp
[=[	  { 9423,-2839,-1195,-4532,12377,2415,-483,1374,5276 } },
]=]
[=[	  { 9423,-2839,-1195,-4532,12377,2415,-483,1374,5276 } },
	{ LIBRAW_CAMERAMAKER_Canon, "EOS R50 V", 0, 0,
	  { 9089, -1810, -1209, -4294, 12116, 2454, -498, 1862, 4923 } },
]=])

replace_libraw(src/tables/cameralist.cpp
    "\"Canon PowerShot SX30 IS (CHDK hack)\","
    "\"Canon PowerShot SX30 IS (CHDK hack)\",\n\t\"Canon PowerShot V1\",")
replace_libraw(src/tables/colordata.cpp
    "\t{ LIBRAW_CAMERAMAKER_Canon, \"PowerShot Pro1\", 0, 0," [=[
    { LIBRAW_CAMERAMAKER_Canon, "PowerShot V1", 0, 0,
      { 12600,-4747,-2027,-6110,15868,-29,110,479,6011 } },
	{ LIBRAW_CAMERAMAKER_Canon, "PowerShot Pro1", 0, 0,
]=])

# 单一型号的 feature row 必须唯一，避免宽泛锚点把补丁插入整个相机表。
file(READ "${LIBRAW_SOURCE_DIR}/src/metadata/sony.cpp" sony_metadata)
string(REGEX MATCHALL "\\{SonyID_ILCE_1M2, sbfILCE_FF," a1_rows "${sony_metadata}")
list(LENGTH a1_rows a1_count)
if(NOT a1_count EQUAL 1)
    message(FATAL_ERROR "Unexpected A1 II metadata rows; use a pristine LibRaw 0.22.2 source")
endif()
