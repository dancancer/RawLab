#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace sony2fuji::hdr {
std::vector<uint8_t> jpegExif(const void* jpeg,size_t size);
uint32_t exifOrientation(const void* tiff,size_t size);
std::vector<uint8_t> sanitizedExif(const void* tiff,size_t size,uint32_t width,uint32_t height);
std::vector<uint8_t> withJPEGExif(const void* jpeg,size_t size,const void* tiff,size_t tiffSize);
uint32_t jpegColorDescription(const void* jpeg,size_t size,bool allowExifSRGB=false);
uint32_t iccColorDescription(const void* icc,size_t size,bool requireSRGBTransfer=false);
float appleHeadroom(const void* tiff,size_t size);
struct AppleGainMapMetadata {
    float headroom=0,minBoost=1,maxBoost=1,gamma=1,offsetSDR=0,offsetHDR=0;
    bool logarithmic=false;
};
AppleGainMapMetadata appleGainMapMetadata(const void* xmp,size_t size);
float appleXMPHeadroom(const void* xmp,size_t size);
}
