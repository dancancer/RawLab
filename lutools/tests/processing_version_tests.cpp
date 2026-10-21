#include "core/wavelet_denoise.h"
#include "nlohmann/json.hpp"
#include "processing_reference_fixture.h"
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;

static void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

static void cacheChecks() {
    WaveletDenoiseAnalysisCache cache;
    WaveletDenoiseOptions options{true, 65, 72, 100};
    ProcessingVersion previous = ProcessingVersion::C5V2;
    bool first = true;
    for (const auto version : {ProcessingVersion::Legacy, ProcessingVersion::Legacy, ProcessingVersion::C5V2,
                               ProcessingVersion::C5V2, ProcessingVersion::Legacy}) {
        options.processingVersion = version;
        auto cached = processingReferenceFixture();
        auto fresh = cached;
        WaveletDenoiseDiagnostics diagnostics;
        require(applyWaveletDenoise(cached, options, &diagnostics, GpuMode::Off, &cache, "same-input") ==
                ErrorCode::Success, "cached filtering");
        require(diagnostics.analysisReused == (!first && previous == version), "analysis must be isolated by version");
        require(applyWaveletDenoise(fresh, options) == ErrorCode::Success, "fresh filtering");
        require(std::memcmp(cached.pixels.data(), fresh.pixels.data(), fresh.pixels.size() * sizeof(RGB)) == 0,
                "version switches equal fresh filtering");
        previous = version;
        first = false;
    }
    options.processingVersion = static_cast<ProcessingVersion>(99);
    auto invalid = processingReferenceFixture();
    const auto unchanged = invalid;
    require(applyWaveletDenoise(invalid, options) == ErrorCode::InvalidFormat, "unknown version rejected");
    require(std::memcmp(invalid.pixels.data(), unchanged.pixels.data(), unchanged.pixels.size() * sizeof(RGB)) == 0,
            "unknown version leaves pixels untouched");
}

int main() {
    try {
        std::ifstream stream(std::string(TEST_FIXTURE_DIR) + "/processing-wavelet-reference.json");
        const auto reference = nlohmann::json::parse(stream);
        for (const auto& expected : reference.at("cases")) {
            const auto& values = expected.at("options");
            WaveletDenoiseOptions options{true, values.at("luma"), values.at("chroma"), values.at("coarse")};
            options.processingVersion = static_cast<ProcessingVersion>(expected.at("version").get<int>());
            auto image = processingReferenceFixture();
            WaveletDenoiseDiagnostics diagnostics;
            require(applyWaveletDenoise(image, options, &diagnostics) == ErrorCode::Success, "filter failed");
            const std::string label = "v" + std::to_string(expected.at("version").get<int>()) + " " +
                expected.at("name").get<std::string>();
            require(diagnostics.applied && diagnostics.flatTiles == expected.at("flat_tiles"), label + " analysis");
            const auto& coordinates = reference.at("coordinates");
            for (size_t i = 0; i < coordinates.size(); ++i) {
                const auto& pixel = image.at(coordinates[i][0], coordinates[i][1]);
                const std::array<float, 3> actual{pixel.r, pixel.g, pixel.b};
                for (size_t c = 0; c < actual.size(); ++c)
                    require(std::abs(actual[c] - expected.at("pixels")[i][c].get<float>()) < 1e-5f,
                            label + " released pixel " + std::to_string(i) + "/" + std::to_string(c));
            }
            std::array<double, 3> sum{}, squared{};
            for (const auto& pixel : image.pixels) {
                const std::array<double, 3> values{pixel.r, pixel.g, pixel.b};
                for (size_t c = 0; c < values.size(); ++c) {
                    sum[c] += values[c];
                    squared[c] += values[c] * values[c];
                }
            }
            for (size_t c = 0; c < sum.size(); ++c) {
                require(std::abs(sum[c] / image.pixels.size() - expected.at("mean")[c].get<double>()) < 2e-6,
                        label + " frame mean");
                require(std::abs(std::sqrt(squared[c] / image.pixels.size()) -
                                 expected.at("rms")[c].get<double>()) < 2e-6, label + " frame rms");
            }
        }
        cacheChecks();
        std::cout << "Processing version references and cache isolation passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
