#include "ai/noise_profile.h"
#include "sony2fuji/raw_processor.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <random>
#include <stdexcept>

using namespace sony2fuji;
using namespace sony2fuji::ai;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }

RAWBayerSource noisy(const std::array<int, 4>& pattern, float white, bool flat = false, bool texture = false,
                     float flatSignal = .18f, float blackOffset = 0) {
    RAWBayerSource source;
    source.width = 768; source.height = 512; source.cameraModel = "Unknown Bayer";
    source.iso = 0; source.rawBits = white > 4095 ? 14 : 12;
    source.white = white; source.pattern = pattern; source.black = {32, 40, 48, 56};
    for (auto& black : source.black) black += blackOffset;
    source.whiteBalance = {2, 1, 1.5, 1};
    std::mt19937 random(20261023);
    std::normal_distribution<float> gaussian;
    for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
        float signal = flat ? flatSignal : .015f + .65f * x / source.width;
        if (texture && y < 96) signal = ((x / 2 + y / 2) & 1) ? .1f : .8f;
        const float pixel = signal + std::sqrt(.0015f * signal + .000006f) * gaussian(random);
        const int phase = pattern[(y % 2) * 2 + x % 2];
        source.pixels.push_back(static_cast<uint16_t>(std::clamp(std::round(source.black[phase] +
            pixel * (white - source.black[phase])), 0.f, 65535.f)));
    }
    return source;
}

int main() {
    try {
        const std::array<std::array<int, 4>, 4> patterns{{{0,1,3,2}, {1,0,2,3}, {3,2,0,1}, {2,3,1,0}}};
        for (const auto& pattern : patterns) for (float white : {4095.f, 16383.f}) {
            auto source = noisy(pattern, white);
            const auto original = source.pixels;
            const auto estimate = selectNoiseProfile(source);
            require(estimate.k > 0 && estimate.b >= 0 && std::isfinite(estimate.k + estimate.b), "invalid estimate");
            for (float signal : {.02f, .15f, .6f}) {
                const float expected = .0015f * signal + .000006f;
                require(std::abs(estimate.k * signal + estimate.b - expected) < expected * .25f,
                        "single-frame noise prediction exceeds 25 percent error");
            }
            require(source.pixels == original, "noise estimation mutated RAW pixels");
            auto changed = source; changed.cameraModel = "Other brand"; changed.iso = 51200; changed.rawBits = 16;
            const auto other = selectNoiseProfile(changed);
            require(other.k == estimate.k && other.b == estimate.b, "generic estimate guessed noise from brand or ISO");
        }
        const auto flat = selectNoiseProfile(noisy(patterns[0], 16383, true));
        const float flatExpected = .0015f * .18f + .000006f;
        require(std::abs(flat.k * .18f + flat.b - flatExpected) < flatExpected * .25f,
                "constant scene did not retain its observed variance");
        const auto contaminated = selectNoiseProfile(noisy(patterns[0], 16383, false, true));
        require(std::abs(contaminated.k - .0015f) < .000375f, "minority structured tiles dominated noise fit");
        const auto dark = selectNoiseProfile(noisy(patterns[0],16383,true,false,.0001f,1024));
        require(std::abs(dark.b-(.0015f*.0001f+.000006f)) < .0000015f,
                "below-black samples were clipped before noise estimation");
        auto unknown = [&](const RAWBayerSource& source) {
            try { selectNoiseProfile(source); } catch (const NoiseEstimateUnavailable&) { return true; }
            return false;
        };
        for (const auto& pattern : patterns) for (float white : {4095.f,16383.f}) {
            for (const auto& periods : {std::array<int,2>{5,3}, {3,5}, {7,9}, {9,7}}) {
                for (float randomSigma : {0.f,.002f}) {
                    auto periodic = noisy(pattern,white,true);
                    std::mt19937 random(20261024);
                    std::normal_distribution<float> gaussian;
                    for (int y = 0; y < periodic.height; ++y) for (int x = 0; x < periodic.width; ++x) {
                        const int phase = pattern[(y%2)*2+x%2];
                        const double signal = .18+.08*std::sin(2*3.141592653589793*(double(x)/periods[0]+double(y)/periods[1]))+
                            randomSigma*gaussian(random);
                        periodic.pixels[size_t(y)*periodic.width+x] = uint16_t(std::round(periodic.black[phase]+
                            signal*(white-periodic.black[phase])));
                    }
                    require(unknown(periodic), "periodic texture was accepted as a confident noise estimate");
                    auto mixed = noisy(pattern,white);
                    std::copy_n(periodic.pixels.begin(),96*mixed.width,mixed.pixels.begin());
                    const auto estimate = selectNoiseProfile(mixed);
                    require(std::abs(estimate.k-.0015f) < .000375f,
                            "periodic minority prevented recovery of the actual random noise");
                }
            }
        }
        auto clipped = noisy(patterns[0],16383);
        std::fill(clipped.pixels.begin(),clipped.pixels.end(),16383);
        require(unknown(clipped), "clipped RAW manufactured a noise profile");
        auto structure = clipped;
        for (int y = 0; y < structure.height; ++y) for (int x = 0; x < structure.width; ++x)
            structure.pixels[size_t(y)*structure.width+x] = ((x/2+y/2)&1) ? 4000 : 8000;
        require(unknown(structure), "deterministic texture was treated as random noise");
        auto phases = noisy(patterns[0],16383,true);
        for (int y = 0; y < phases.height; y += 2) for (int x = 0; x < phases.width; x += 2) {
            const float center = phases.black[0]+.18f*(phases.white-phases.black[0]);
            auto& value = phases.pixels[size_t(y)*phases.width+x];
            value = uint16_t(std::max(0.f,center+4*(value-center)));
        }
        require(unknown(phases), "incompatible phase noise was fitted with one shared model");
        auto invalid = noisy(patterns[0], 16383);
        invalid.white = invalid.black[0];
        bool rejected = false;
        try { selectNoiseProfile(invalid); } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "invalid normalization accepted");
        std::cout << "PASS cross-brand Bayer noise units, phase mapping, ISO independence, flat-field and texture robustness\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
