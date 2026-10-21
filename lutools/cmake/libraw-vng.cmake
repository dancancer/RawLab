# 固定 256 行快照保留 VNG 的两行读邻域，避免并行写回覆盖下一批输入。
configure_file("${CMAKE_CURRENT_LIST_DIR}/../third_party/libraw/vng_parallel.inc"
    "${LIBRAW_SOURCE_DIR}/src/demosaic/rawlab_vng_parallel.inc" COPYONLY)
replace_libraw(src/demosaic/misc_demosaic.cpp
    "#include \"../../internal/dcraw_defs.h\""
    "#include \"../../internal/dcraw_defs.h\"\n#include <memory>\n#ifdef LIBRAW_USE_OPENMP\n#include <omp.h>\n#endif")
replace_libraw(src/demosaic/misc_demosaic.cpp
    "  static const signed char *cp,\n      terms[] ="
    "  const signed char *cp;\n  static const signed char terms[] =")
replace_libraw(src/demosaic/misc_demosaic.cpp
    "  brow[4] = (ushort(*)[4])calloc(width * 3, sizeof **brow);"
    "#include \"rawlab_vng_parallel.inc\"\n  brow[4] = (ushort(*)[4])calloc(width * 3, sizeof **brow);")
