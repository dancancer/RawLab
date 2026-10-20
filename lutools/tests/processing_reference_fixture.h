#pragma once

#include "sony2fuji/common.h"
#include <algorithm>
#include <cmath>
#include <cstdint>

inline sony2fuji::ImageData processingReferenceFixture() {
    sony2fuji::ImageData image(512, 256);
    uint32_t state = 0x3a71592u;
    auto noise = [&]() {
        float sum = 0;
        for (int i = 0; i < 12; ++i) {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            sum += static_cast<float>(state & 65535u) / 65536.f - .5f;
        }
        return sum;
    };
    constexpr float means[] = {-.005f, .002f, .18f, 1.2f};
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
        const float value = means[x / 128];
        const float sigma = std::sqrt(.002f * std::max(value, 0.f) + .00002f);
        image.at(x, y) = {value + sigma * noise(), value + sigma * noise(), value + sigma * noise()};
    }
    return image;
}
