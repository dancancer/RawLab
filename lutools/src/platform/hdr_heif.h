#pragma once
#include "platform/hdr_image.h"
#include <vector>

namespace sony2fuji::hdr {
sony2fuji_hdr_source_info_v1 probeHEIF(const void* data,size_t size);
DecodedImage decodeHEIF(const void* data,size_t size,uint32_t longEdge);
std::vector<uint8_t> heifExif(const void* data,size_t size);
}
