#include "png16_color.h"
#include <array>
#include <cassert>
#include <cmath>
#include <vector>

static float srgbEncode(float value) {
    return static_cast<float>(value <= 0.0031308f ? value * 12.92 :
        1.055 * std::pow(static_cast<double>(value), 1.0 / 2.4) - 0.055);
}

int main() {
    std::vector<float> eotf(65536), oetf(65536);
    std::vector<uint16_t> pixels(65536 * 4);
    const std::array<float, 9> p3ToSrgb{1.224745f, -0.042058f, -0.019642f,
        -0.224904f, 1.042081f, -0.078655f, 0, 0, 1.098537f};
    for (int i = 0; i < 65536; ++i) oetf[i] = srgbEncode(i / 65535.0f);
    for (double gamma : {1.8, 2.2, 2.6}) {
        for (int i = 0; i < 65536; ++i) eotf[i] = std::pow(static_cast<double>(i / 65535.0f), gamma);
        for (int sweep = 0; sweep < 4; ++sweep) {
            for (int i = 0; i < 65536; ++i) {
                pixels[i * 4] = i;
                pixels[i * 4 + 1] = sweep == 0 ? i : (i * 251 + sweep * 17) & 65535;
                pixels[i * 4 + 2] = sweep == 0 ? i : (i * 97 + sweep * 127) & 65535;
                pixels[i * 4 + 3] = 65535;
            }
            const auto original = pixels;
            rawlab::convertPng16ToSrgb(pixels.data(), 65536, eotf.data(), p3ToSrgb.data(), oetf.data());
            for (int i = 0; i < 65536; ++i) {
                const float r = eotf[original[i * 4]], g = eotf[original[i * 4 + 1]], b = eotf[original[i * 4 + 2]];
                for (int c = 0; c < 3; ++c) {
                    const float linear = p3ToSrgb[c] * r + p3ToSrgb[c + 3] * g + p3ToSrgb[c + 6] * b;
                    const int expected = std::lround(std::clamp(srgbEncode(linear), 0.0f, 1.0f) * 65535);
                    assert(std::abs(int(pixels[i * 4 + c]) - expected) <= 1);
                }
                assert(pixels[i * 4 + 3] == 65535);
            }
        }
    }
}
