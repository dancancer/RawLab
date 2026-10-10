#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <cstddef>
#include <cstdint>

namespace sony2fuji {

class ColorRecipe {
public:
    static ColorRecipe fromParameters(uint32_t version, const float* values, size_t count);
    // Input must be finite display-sRGB channels in [0, 1].
    RGB apply(const RGB& displaySrgb) const;

private:
    std::array<float, 40> values_{};
    std::array<double, 4> regions_{.2, .6, .4, .8};
};

} // namespace sony2fuji
