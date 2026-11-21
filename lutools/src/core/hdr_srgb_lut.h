#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace sony2fuji::hdr {

inline float linearToSrgbUnit(float value) {
    value = std::clamp(value, 0.0f, 1.0f);
    return value <= 0.0031308f ? 12.92f * value : 1.055f * std::pow(value, 1.0f / 2.4f) - 0.055f;
}

inline uint8_t exactSrgbToUInt8(float value) {
    return static_cast<uint8_t>(std::lround(linearToSrgbUnit(value) * 255.0f));
}

// 16384 个 2 的幂分桶 + nextafter 守卫区间：桶内上下界量化值一致时免去 std::pow，
// 边界桶回落精确计算，确保对全部 IEEE-754 float 与直接计算逐位一致。
inline uint8_t srgbToUInt8(float value) {
    if (!(value > 0.0f)) {
        return 0;
    }
    if (value >= 1.0f) {
        return 255;
    }
    struct Bucket {
        uint8_t qLo;
        uint8_t qHi;
    };
    static constexpr size_t kBuckets = 16384;
    static const auto table = []() {
        std::array<Bucket, kBuckets> entries{};
        for (size_t i = 0; i < kBuckets; ++i) {
            const float lo = std::max(0.0f, std::nextafter(static_cast<float>(i) / static_cast<float>(kBuckets), -1.0f));
            const float hi = std::min(1.0f, std::nextafter(static_cast<float>(i + 1) / static_cast<float>(kBuckets), 2.0f));
            entries[i] = {exactSrgbToUInt8(lo), exactSrgbToUInt8(hi)};
        }
        return entries;
    }();
    const size_t idx = std::min(kBuckets - 1, static_cast<size_t>(value * static_cast<float>(kBuckets)));
    const auto bucket = table[idx];
    return bucket.qLo == bucket.qHi ? bucket.qLo : exactSrgbToUInt8(value);
}

} // namespace sony2fuji::hdr
