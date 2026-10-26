#include "ai/dualdn_geometry.h"
#include "ai/noise_profile.h"
#include "sony2fuji/raw_processor.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace sony2fuji::ai;
void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
template <typename Error, typename Function> void rejects(Function fn) {
    bool failed = false; try { fn(); } catch (const Error&) { failed = true; }
    require(failed, "expected rejection");
}

int main() {
    try {
        const std::array<std::array<int, 4>, 4> patterns{{{0, 1, 3, 2}, {1, 0, 2, 3},
                                                        {3, 2, 0, 1}, {2, 3, 1, 0}}};
        for (const auto& pattern : patterns) for (int width : {2, 7, 8}) for (int height : {2, 5, 8}) {
            BayerFrame frame{width, height, {}, pattern, {32, 48, 64, 80}, 1000};
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x)
                frame.pixels.push_back(uint16_t(20 + y * 120 + x * 130));
            const auto original = frame.pixels;
            auto packed = packBayer(frame);
            size_t count = 0;
            const auto predicted = runTiles(packed.tensor, {8, 2}, 4,
                [&](const Tensor& tile) { ++count; return tile; });
            const auto mosaic = unpackBayer(predicted, packed);
            const auto pair = pairBayerMosaics(packed, mosaic.values);
            const size_t pairPlane = size_t(pair.width) * pair.height;
            require(pair.channels == 2, "canonical mosaic pair channels changed");
            require(std::equal(pair.values.begin(), pair.values.begin() + pairPlane, pair.values.begin() + pairPlane),
                    "clean/noisy canonical CFA phase differs for identity RAW output");
            require(mosaic.width == width && mosaic.height == height && mosaic.channels == 1, "active crop changed");
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                const size_t index = size_t(y) * width + x;
                const float black = frame.black[pattern[(y % 2) * 2 + x % 2]];
                const float expected = std::max((frame.pixels[index] - black) / (frame.white - black), 1e-8f);
                require(mosaic.values[index] == expected, "CFA packing or identity reconstruction changed pixels");
            }
            require(frame.pixels == original && count > 0, "source changed or no inference");
        }
        Tensor input{13, 9, 1, std::vector<float>(117)};
        for (size_t i = 0; i < input.values.size(); ++i) input.values[i] = float(i) / 64;
        const auto copy = input.values;
        size_t calls = 0;
        rejects<Cancelled>([&] { runTiles(input, {8, 2}, 1,
            [&](const Tensor& x) { ++calls; return x; }, [](size_t, size_t) { return false; }); });
        require(calls == 0, "cancel before start still ran inference");
        rejects<Cancelled>([&] { runTiles(input, {8, 2}, 1,
            [&](const Tensor& x) { ++calls; return x; }, [](size_t n, size_t) { return n < 2; }); });
        require(calls == 2 && input.values == copy, "cancellation did not stop at tile boundary");
        rejects<ModelContractError>([&] { runTiles(input, {8, 2}, 1, [](const Tensor& x) {
            auto bad = x; bad.values[0] = std::numeric_limits<float>::quiet_NaN(); return bad;
        }); });
        calls = 0;
        rejects<std::runtime_error>([&] { runTiles(input, {8, 2}, 1, [&](const Tensor& x) {
            if (++calls == 2) throw std::runtime_error("GPU provider failed");
            return x;
        }); });
        require(calls == 2 && input.values == copy, "GPU failure published partial output or retried another backend");
        const auto low = selectNoiseProfile("ILCE-7CM2", 100);
        const auto high = selectNoiseProfile("ILCE-7CM2", 12800);
        require(low.k == 1.4017175356283488e-05f && low.b == 4.012456627349693e-09f && !low.interpolated,
                "measured ISO anchor changed");
        require(high.k == 0.0018241977770013236f && high.b == 5.150549402363373e-06f, "high ISO anchor changed");
        const auto mid = selectNoiseProfile("ILCE-7CM2", 1600);
        const auto a = selectNoiseProfile("ILCE-7CM2", 800), b = selectNoiseProfile("ILCE-7CM2", 3200);
        require(mid.interpolated && std::abs(mid.k - std::sqrt(a.k * b.k)) < 1e-10f, "ISO interpolation is not log-log");
        rejects<std::invalid_argument>([] { selectNoiseProfile("ILCE-7M4", 100); });
        rejects<std::invalid_argument>([] { selectNoiseProfile("ILCE-7CM2", 51200); });
        rejects<std::invalid_argument>([] { selectNoiseProfile("ILCE-7CM2", 50); });
        rejects<std::invalid_argument>([] { selectNoiseProfile("ILCE-7CM2", std::numeric_limits<float>::quiet_NaN()); });
        sony2fuji::RAWBayerSource calibrated;
        calibrated.cameraModel = "ILCE-7CM2"; calibrated.iso = 100; calibrated.rawBits = 14; calibrated.sonyRawType = 4;
        calibrated.width = 7008; calibrated.height = 4672; calibrated.white = 16383; calibrated.black.fill(512);
        require(selectNoiseProfile(calibrated).k == low.k, "matching RAW metadata rejected");
        for (int field = 0; field < 5; ++field) {
            auto mismatch = calibrated;
            if (field == 0) mismatch.rawBits = 12;
            if (field == 1) mismatch.sonyRawType = 2;
            if (field == 2) mismatch.width /= 2;
            if (field == 3) mismatch.white = 4095;
            if (field == 4) mismatch.black[3] = 511;
            rejects<std::invalid_argument>([&] { selectNoiseProfile(mismatch); });
        }
        std::cout << "PASS DualDn CFA, normalization, tiling, cancellation, GPU failure and noise profile\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
