#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>
struct heif_image_handle;
namespace sony2fuji::hdr {
std::vector<uint8_t> heifRGBProfile(const heif_image_handle* image);
std::vector<uint8_t> heifItemRGBProfile(const void* data,size_t size,uint32_t item);
}
