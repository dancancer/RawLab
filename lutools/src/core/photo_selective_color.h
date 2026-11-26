#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <cstddef>
#include <cstdint>

namespace sony2fuji {

enum class SelectiveColorMethod : uint8_t {
    Relative = 0,
    Absolute = 1
};

constexpr size_t kSelectiveColorBandCount = 9;

struct SelectiveColorBand {
    float cyan = 0.0f;    // [-100, 100]
    float magenta = 0.0f; // [-100, 100]
    float yellow = 0.0f;  // [-100, 100]
    float black = 0.0f;   // [-100, 100]

    bool valid() const;
    bool active() const {
        return cyan != 0.0f || magenta != 0.0f || yellow != 0.0f || black != 0.0f;
    }

    bool operator==(const SelectiveColorBand& other) const {
        return cyan == other.cyan && magenta == other.magenta &&
               yellow == other.yellow && black == other.black;
    }
};

struct SelectiveColorOptions {
    SelectiveColorMethod method = SelectiveColorMethod::Relative;
    // Order: reds, yellows, greens, cyans, blues, magentas, whites, neutrals, blacks.
    std::array<SelectiveColorBand, kSelectiveColorBandCount> bands{};

    bool valid() const;
    bool active() const;
    bool isDefault() const { return method == SelectiveColorMethod::Relative && !active(); }

    bool operator==(const SelectiveColorOptions& other) const {
        return method == other.method && bands == other.bands;
    }
};

RGB applySelectiveColorPixel(const RGB& pixel, const SelectiveColorOptions& options);
void applySelectiveColor(ImageData& image, const SelectiveColorOptions& options);

} // namespace sony2fuji
