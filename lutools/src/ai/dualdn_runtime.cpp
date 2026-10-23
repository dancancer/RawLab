#include "dualdn_runtime.h"
#include "dualdn_bridge.h"
#include <algorithm>
#include <chrono>
#include <cmath>

namespace sony2fuji::ai {
namespace {
using Clock = std::chrono::steady_clock;
void validateNoise(const NoiseParameters& noise) {
    if (!std::isfinite(noise.k) || noise.k <= 0 || !std::isfinite(noise.b) || noise.b < 0)
        throw std::invalid_argument("invalid DualDn noise parameters");
}

PackedBayer packedSource(const RAWBayerSource& source) {
    return packBayer({source.width, source.height, source.pixels, source.pattern, source.black, source.white});
}

void finishReport(RuntimeReport& report, const InferenceReport& fallback, Clock::time_point start) {
    if (fallback.fallbackUsed) { report.backend = "CPU"; report.fallbackReason = fallback.fallbackReason; }
    report.seconds = std::chrono::duration<double>(Clock::now() - start).count();
}
}

RAWBayerOverride denoiseRaw(const RAWBayerSource& source, const ModelPackage& package,
                            const NoiseParameters& noise, Backend backend, RuntimeReport& report,
                            const Progress& progress) {
    validateNoise(noise);
    report = {};
    const auto start = Clock::now();
    auto packed = packedSource(source);
    NetworkGraph graph(package, GraphKind::Raw, backend);
    report.backend = graph.backend(); report.fallbackReason = graph.fallbackReason();
    std::unique_ptr<NetworkGraph> cpu;
    auto predict = [&](NetworkGraph& session, const Tensor& tile) {
        return Tensor{tile.width, tile.height, 4, session.run({tile.values, {noise.k}, {noise.b}})};
    };
    PredictTile fallback;
    if (backend == Backend::Auto && graph.backend() != "CPU") fallback = [&](const Tensor& tile) {
        if (!cpu) cpu = std::make_unique<NetworkGraph>(package, GraphKind::Raw, Backend::Cpu);
        return predict(*cpu, tile);
    };
    InferenceReport diagnostics;
    auto output = runTilesWithFallback(packed.tensor, {package.tileSize, 128}, 4,
        [&](const Tensor& tile) { return predict(graph, tile); }, fallback, diagnostics, progress);
    auto mosaic = unpackBayer(output, packed);
    finishReport(report, diagnostics, start);
    return {source.width, source.height, std::move(mosaic.values), {}};
}

Tensor denoiseRgb(const RAWBayerSource& source, const RAWBayerOverride& denoised,
                   const ModelPackage& package, const NoiseParameters& noise, Backend backend,
                   RGBOutput mode, RuntimeReport& report, const Progress& progress) {
    validateNoise(noise);
    report = {};
    const auto start = Clock::now();
    auto packed = packedSource(source);
    const size_t sourcePixels = size_t(source.width) * source.height;
    if (mode != RGBOutput::CameraCorrection && mode != RGBOutput::OfficialLinear && mode != RGBOutput::BothForValidation)
        throw std::invalid_argument("invalid DualDn RGB output mode");
    if (denoised.width != source.width || denoised.height != source.height || denoised.normalizedMosaic.size() != sourcePixels ||
        !std::all_of(denoised.normalizedMosaic.begin(), denoised.normalizedMosaic.end(), [](float v) { return std::isfinite(v); }))
        throw std::invalid_argument("invalid DualDn denoised Bayer geometry");
    Tensor mosaics = pairBayerMosaics(packed, denoised.normalizedMosaic);
    const size_t plane = size_t(mosaics.width) * mosaics.height;
    packed.tensor.values.clear(); packed.tensor.values.shrink_to_fit();
    const std::array<float, 4> wb{source.whiteBalance[0], source.whiteBalance[packed.identities[1]],
                                 source.whiteBalance[2], source.whiteBalance[packed.identities[2]]};
    if (!std::all_of(wb.begin(), wb.end(), [](float v) { return std::isfinite(v) && v > 0; }))
        throw std::invalid_argument("invalid DualDn white balance");
    const auto matrix = officialCameraToXYZ(source);
    std::vector<float> matrixValues;
    for (const auto& row : matrix) matrixValues.insert(matrixValues.end(), row.begin(), row.end());
    const std::vector<float> wbValues(wb.begin(), wb.end());
    NetworkGraph isp(package, GraphKind::ISP, backend);
    NetworkGraph rgb(package, GraphKind::RGB, backend);
    report.backend = isp.backend() == rgb.backend() ? rgb.backend() : "ISP:" + isp.backend() + "/RGB:" + rgb.backend();
    report.fallbackReason = isp.fallbackReason().empty() ? rgb.fallbackReason() : isp.fallbackReason();
    std::unique_ptr<NetworkGraph> cpuISP, cpuRGB;
    auto predict = [&](const Tensor& tile, NetworkGraph& ispGraph, NetworkGraph& rgbGraph) {
        const size_t pixels = size_t(tile.width) * tile.height;
        Tensor clean{tile.width, tile.height, 1, {tile.values.begin(), tile.values.begin() + pixels}};
        Tensor noisy{tile.width, tile.height, 1, {tile.values.begin() + pixels, tile.values.end()}};
        std::vector<float> noiseMap(pixels);
        for (size_t i = 0; i < pixels; ++i) noiseMap[i] = std::sqrt(std::max(noise.k * tile.values[pixels + i] + noise.b, 1e-7f));
        Tensor skip{tile.width, tile.height, 3, ispGraph.run({clean.values, wbValues, matrixValues})};
        auto rgbNoise = ispGraph.run({noiseMap, wbValues, matrixValues});
        Tensor result{tile.width, tile.height, 3, rgbGraph.run({skip.values, rgbNoise})};
        if (mode == RGBOutput::CameraCorrection) return rgbCameraCorrection(clean, noisy, skip, result, wb, matrix);
        Tensor correction;
        if (mode == RGBOutput::BothForValidation) correction = rgbCameraCorrection(clean, noisy, skip, result, wb, matrix);
        for (auto& value : result.values) value = inverseRec709(value);
        if (mode == RGBOutput::BothForValidation) {
            correction.channels = 6;
            correction.values.insert(correction.values.end(), result.values.begin(), result.values.end());
            return correction;
        }
        return result;
    };
    PredictTile fallback;
    if (backend == Backend::Auto && (isp.backend() != "CPU" || rgb.backend() != "CPU")) fallback = [&](const Tensor& tile) {
        if (!cpuISP) cpuISP = std::make_unique<NetworkGraph>(package, GraphKind::ISP, Backend::Cpu);
        if (!cpuRGB) cpuRGB = std::make_unique<NetworkGraph>(package, GraphKind::RGB, Backend::Cpu);
        return predict(tile, *cpuISP, *cpuRGB);
    };
    InferenceReport diagnostics;
    const int outputChannels = mode == RGBOutput::BothForValidation ? 6 : 3;
    const auto canonical = runTilesWithFallback(mosaics, {package.tileSize, 64}, outputChannels,
        [&](const Tensor& tile) { return predict(tile, isp, rgb); }, fallback, diagnostics, progress);
    Tensor output{source.width, source.height, outputChannels, std::vector<float>(outputChannels * sourcePixels)};
    for (int c = 0; c < outputChannels; ++c) for (int y = 0; y < source.height; ++y)
        std::copy_n(canonical.values.data() + size_t(c) * plane + size_t(y + packed.offsetY) * canonical.width + packed.offsetX,
                    source.width, output.values.data() + size_t(c) * sourcePixels + size_t(y) * source.width);
    finishReport(report, diagnostics, start);
    return output;
}
} // namespace sony2fuji::ai
