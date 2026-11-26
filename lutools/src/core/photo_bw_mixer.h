#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <cstddef>

namespace sony2fuji {

constexpr size_t kBwMixerChannelCount = 8;

struct BwMixerOptions {
    bool enabled = false;
    // Order: red, orange, yellow, green, aqua, blue, purple, magenta.
    std::array<float, kBwMixerChannelCount> weights{};

    bool valid() const;
    bool active() const { return enabled; }
    bool isDefault() const;

    bool operator==(const BwMixerOptions& other) const {
        return enabled == other.enabled && weights == other.weights;
    }
};

void applyBwMixer(ImageData& image, const BwMixerOptions& options);

} // namespace sony2fuji
