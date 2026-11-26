#pragma once

#include <cstddef>
#include <cstdint>

namespace sony2fuji::hdr {

// HDR 亮度直方图：Rec.709 亮度在 [-8, +8] EV 上每 EV 16 档，共 256 档。
constexpr uint32_t kLuminanceBins = 256;

struct LuminanceStatistics {
    uint32_t bins[kLuminanceBins] = {};
    uint32_t aboveWhite = 0;
    float peak = 1.0f;
};

// rowStride 以 float 计。任一分量非有限时返回 false，out 不变。
bool analyzeLuminance(const float* rgb, uint32_t width, uint32_t height, size_t rowStride,
                      LuminanceStatistics& out);

enum DisplayFlags : uint32_t {
    kDisplaySdr = 1u << 0,
    kDisplayFalseColor = 1u << 1,
    kDisplayP3 = 1u << 2,
    kDisplayClampSdr = 1u << 3,
    kDisplayBgra8Srgb = 1u << 4,
    kDisplayAllFlags = (1u << 5) - 1u,
};

enum class DisplayResult { Ok, NonFinite, Unrepresentable };

struct DisplayPlanes {
    const float* hdr = nullptr;
    size_t hdrStride = 0; // float 数
    const float* sdr = nullptr; // 仅假色时可为空
    size_t sdrStride = 0;
    uint8_t* dst = nullptr;
    size_t dstStride = 0; // 字节数
    uint32_t width = 0;
    uint32_t height = 0;
};

// 调用方已校验尺寸、步长与 contentHeadroom（有限且 >= 1）。失败时 dst 内容未定义。
DisplayResult mapDisplay(const DisplayPlanes& planes, float displayHeadroom, float contentHeadroom,
                         uint32_t flags);

} // namespace sony2fuji::hdr
