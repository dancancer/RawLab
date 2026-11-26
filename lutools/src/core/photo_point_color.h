#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <cstddef>
#include <cstdint>

namespace sony2fuji {

constexpr size_t kPointColorMaxSwatches = 8;

struct PointColorSwatch {
    float srcHue = 0.0f;          // [0, 360)
    float srcSaturation = 0.0f;   // [0, 1]
    float srcLuminance = 0.0f;    // [0, 1]
    float hueShift = 0.0f;        // [-100, 100]
    float saturationShift = 0.0f; // [-100, 100]
    float luminanceShift = 0.0f;  // [-100, 100]
    float variance = 0.0f;        // [-100, 100]
    float range = 50.0f;          // [0, 100]
    float hueRange = 50.0f;       // [0, 100]
    float satRange = 50.0f;       // [0, 100]
    float lumRange = 50.0f;       // [0, 100]
    bool enabled = true;

    bool valid() const;
    bool active() const {
        return enabled && (hueShift != 0.0f || saturationShift != 0.0f ||
                           luminanceShift != 0.0f || variance != 0.0f);
    }

    bool operator==(const PointColorSwatch& other) const {
        return srcHue == other.srcHue && srcSaturation == other.srcSaturation &&
               srcLuminance == other.srcLuminance && hueShift == other.hueShift &&
               saturationShift == other.saturationShift && luminanceShift == other.luminanceShift &&
               variance == other.variance && range == other.range &&
               hueRange == other.hueRange && satRange == other.satRange &&
               lumRange == other.lumRange && enabled == other.enabled;
    }
};

struct PointColorOptions {
    std::array<PointColorSwatch, kPointColorMaxSwatches> swatches{};
    uint32_t swatchCount = 0;

    bool valid() const;
    bool active() const;
    bool isDefault() const { return swatchCount == 0; }

    bool operator==(const PointColorOptions& other) const {
        if (swatchCount != other.swatchCount) return false;
        for (uint32_t i = 0; i < swatchCount; ++i) {
            if (!(swatches[i] == other.swatches[i])) return false;
        }
        return true;
    }
};

void applyPointColor(ImageData& image, const PointColorOptions& options);

} // namespace sony2fuji
