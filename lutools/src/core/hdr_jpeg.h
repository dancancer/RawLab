#pragma once
#include "core/hdr_rendering.h"
#include <cstddef>
#include <cstdint>
#include <vector>

namespace sony2fuji::hdr {
struct JPEGInfo { uint32_t width=0,height=0,color=0; float headroom=0; };
JPEGInfo probeJPEG(const void* data,size_t size);
ImageData decodeJPEG(const void* data,size_t size,uint32_t longEdge=0);
std::vector<uint8_t> encodeJPEG(const HDRImagePair& image,uint32_t quality,uint32_t baseColor);
std::vector<uint8_t> jpegBase(const void* data,size_t size);
std::vector<uint8_t> replaceJPEGBase(const void* data,size_t size,const void* base,size_t baseSize);
} // namespace sony2fuji::hdr
