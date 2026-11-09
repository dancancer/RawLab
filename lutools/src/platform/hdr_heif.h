#pragma once
#include "platform/hdr_image.h"
#include <vector>

namespace sony2fuji::hdr {
sony2fuji_hdr_source_info_v1 probeHEIF(const void* data,size_t size);
DecodedImage decodeHEIF(const void* data,size_t size,uint32_t longEdge);
std::vector<uint8_t> heifExif(const void* data,size_t size);

struct DecodedSDRImage {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> pixels;
};

// Decodes a single opaque, non-gain-map HEIF into oriented display-sRGB RGBA8.
// HDR gain-map containers are rejected instead of silently downgrading to the
// SDR base image.
DecodedSDRImage decodeSDRHEIFFile(const char* path);
}
