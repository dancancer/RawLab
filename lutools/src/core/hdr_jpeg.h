#pragma once
#include "core/hdr_rendering.h"
#include <cstddef>
#include <cstdint>
#include <vector>

namespace sony2fuji::hdr {
struct JPEGInfo { uint32_t width=0,height=0,color=0; float headroom=0; };
JPEGInfo probeJPEG(const void* data,size_t size);
JPEGInfo probeAppleJPEG(const void* data,size_t size);
struct AppleGainMapMetadata;
ImageData decodeJPEG(const void* data,size_t size,uint32_t longEdge=0);
ImageData decodeJPEGPreview(const void* data,size_t size,uint32_t longEdge);
ImageData decodeSDRJPEG(const void* data,size_t size,uint32_t longEdge=0,uint32_t declaredColor=0);
std::vector<uint8_t> jpegGainMapXMP(const void* data,size_t size);
ImageData decodeAppleJPEG(const void* data,size_t size,float headroom,uint32_t longEdge,const AppleGainMapMetadata& metadata,uint32_t declaredColor);
std::vector<uint8_t> encodeSDRJPEG(const ImageData& image,uint32_t quality);
std::vector<uint8_t> encodeJPEG(const HDRImagePair& image,uint32_t quality,uint32_t baseColor);
std::vector<uint8_t> jpegBase(const void* data,size_t size);
std::vector<uint8_t> replaceJPEGBase(const void* data,size_t size,const void* base,size_t baseSize);
} // namespace sony2fuji::hdr
