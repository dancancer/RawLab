#pragma once
#include "core/hdr_rendering.h"
#include <cstddef>
#include <cstdint>
#include <functional>
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
using JPEGRowReader = std::function<const RGB*(uint32_t)>;
using JPEGInputBorrower = std::function<void(bool, const std::function<void(const void*)>&)>;
// 紧凑输入由 codec setter 复制；consume 返回后即可解除映射或释放调用方存储。
float packJPEGInput(const RGB* pixels, size_t count, bool hdr, uint32_t baseColor, void* output);
std::vector<uint8_t> encodeJPEGInputs(uint32_t width, uint32_t height, uint32_t quality,
    uint32_t baseColor, float capacity, const JPEGInputBorrower& borrow);
std::vector<uint8_t> encodeSDRJPEGRows(uint32_t width, uint32_t height, uint32_t quality, const JPEGRowReader& read);
std::vector<uint8_t> jpegBase(const void* data,size_t size);
std::vector<uint8_t> replaceJPEGBase(const void* data,size_t size,const void* base,size_t baseSize);
} // namespace sony2fuji::hdr
