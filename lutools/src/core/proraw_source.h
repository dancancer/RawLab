#pragma once

#include "core/hdr_stream.h"
#include "platform/hdr_image.h"
#include <memory>

namespace sony2fuji::hdr {
// DNG SDK 1.7.1 显影配置 v2；Apple Core Image 的配置 v1 保持独立。
constexpr uint64_t portableProRAWRevision = 2;
constexpr uint64_t proRAWStageBytes(uint64_t pixels) { return pixels * 88 + (128ull << 20); }
sony2fuji_hdr_source_info_v1 probeProRAW(const char* path);
DecodedImage decodeProRAW(const char* path, const sony2fuji_hdr_decode_options_v1& options,
    const std::filesystem::path& temporaryRoot);
HDRRowSource openProRAW(const char* path, const std::filesystem::path& temporaryRoot);
}
