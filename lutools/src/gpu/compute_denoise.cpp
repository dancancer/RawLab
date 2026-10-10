#include "compute_denoise.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace sony2fuji {
namespace {
bool finiteOutput(FilterDevice& device, FilterBuffer& buffer, size_t count, float* output) {
    std::vector<float> result(count);
    device.read(buffer, count, result.data());
    if (!std::all_of(result.begin(), result.end(), [](float value) { return std::isfinite(value); })) return false;
    std::memcpy(output, result.data(), count * sizeof(float));
    return true;
}

void dispatch(FilterDevice& device, FilterParams& params, FilterStage stage,
              FilterBuffer& input, FilterBuffer* other, FilterBuffer& output, FilterBuffer* second = nullptr) {
    params.stage = static_cast<uint32_t>(stage);
    device.dispatch(params, input, other, output, second);
}

bool imageFilter(FilterDevice& device, ImageData& image, FilterParams params) {
    if (image.width <= 0 || image.height <= 0 || image.pixels.size() != size_t(image.width) * image.height) return false;
    ImageData result(image.width, image.height);
    params.width = image.width; params.height = image.height;
    const size_t rowFloats = size_t(image.width) * 3;
    // Independent effects need no halo; a detail pass needs one source row each side.
    const bool detail = params.stage == static_cast<uint32_t>(FilterStage::Detail);
    const size_t maxRows = 8 * 1024 * 1024 / (rowFloats * sizeof(float));
    if (maxRows <= 2) return false;
    for (uint32_t row = 0; row < params.height;) {
        const auto rows = static_cast<uint32_t>(std::min<size_t>(maxRows - 2, params.height - row));
        const auto first = detail && row > 0 ? row - 1 : row;
        const auto last = std::min(params.height, row + rows + (detail ? 1u : 0u));
        auto input = device.allocate(rowFloats * (last - first),
            reinterpret_cast<const float*>(image.pixels.data() + size_t(first) * image.width));
        auto output = device.allocate(rowFloats * rows);
        params.sourceRow = first; params.outputRow = row; params.count = rows * params.width;
        device.dispatch(params, *input, nullptr, *output);
        if (!finiteOutput(device, *output, rowFloats * rows,
            reinterpret_cast<float*>(result.pixels.data() + size_t(row) * image.width))) return false;
        row += rows;
    }
    image = std::move(result);
    return true;
}
} // namespace

bool computeWaveletFilter(FilterDevice& device, const float* input, int width, int height,
                          const WaveletFilterSettings& settings, float* output) {
    if (!input || !output || width <= 0 || height <= 0 || (settings.depth != 4 && settings.depth != 6) ||
        width % (1 << settings.depth) || height % (1 << settings.depth) ||
        uint64_t(width) * height > UINT32_MAX / 19) return false;
    for (int scale = 0; scale < settings.depth; ++scale) {
        if (!std::isfinite(settings.thresholdScale[scale]) || settings.thresholdScale[scale] < 0) return false;
        for (int direction = 0; direction < 3; ++direction)
            if (!std::isfinite(settings.sigma[scale * 3 + direction]) || settings.sigma[scale * 3 + direction] <= 0) return false;
    }
    const size_t count = size_t(width) * height;
    auto source = device.allocate(count, input), low = device.allocate(count), high = device.allocate(count);
    auto energy = device.allocate(count), spare = device.allocate(count);
    std::vector<FilterBufferPtr> bands;
    for (int i = 0; i < 1 + settings.depth * 3; ++i) bands.push_back(device.allocate(count));
    FilterParams p;
    p.width = width; p.height = height; p.count = static_cast<uint32_t>(count);
    for (int level = 1; level <= settings.depth; ++level) {
        p.level = level; p.step = 1u << (level - 1);
        dispatch(device, p, FilterStage::SwtRows, level == 1 ? *source : *bands[0], nullptr, *low, high.get());
        for (uint32_t direction = 0; direction < 4; ++direction) {
            p.direction = direction;
            const int band = direction == 0 ? 0 : 1 + (settings.depth - level) * 3 + direction - 1;
            dispatch(device, p, FilterStage::SwtColumns, direction < 2 ? *low : *high, nullptr, *bands[band]);
        }
    }
    for (int scale = 0; scale < settings.depth; ++scale) {
        p.level = settings.depth - scale;
        p.radius = (p.level > 4 ? (1u << (p.level - 1)) + 1 : 7) / 2;
        p.strength = settings.thresholdScale[scale];
        for (int direction = 0; direction < 3; ++direction) {
            auto& band = bands[1 + scale * 3 + direction];
            p.sigma = settings.sigma[scale * 3 + direction];
            dispatch(device, p, FilterStage::EnergyRows, *band, nullptr, *energy);
            dispatch(device, p, FilterStage::Threshold, *band, energy.get(), *spare);
            band.swap(spare);
        }
    }
    for (int level = settings.depth; level > 0; --level) {
        p.level = level; p.step = 1u << (level - 1);
        const int band = 1 + (settings.depth - level) * 3;
        dispatch(device, p, FilterStage::IswtColumns, *bands[0], bands[band].get(), *low);
        dispatch(device, p, FilterStage::IswtColumns, *bands[band + 1], bands[band + 2].get(), *high);
        dispatch(device, p, FilterStage::IswtRows, *low, high.get(), *bands[0]);
    }
    return finiteOutput(device, *bands[0], count, output);
}

bool computeGuidedFilter(FilterDevice& device, const float* guide, const float* input,
                         int width, int height, int radius, float epsilon, float* output) {
    if (!guide || !input || !output || width <= 0 || height <= 0 || radius < 1 || radius > 32 ||
        !std::isfinite(epsilon) || epsilon <= 0 || uint64_t(width) * height > UINT32_MAX / 17) return false;
    const size_t count = size_t(width) * height;
    auto guidance = device.allocate(count * 3, guide), source = device.allocate(count * 2, input);
    auto a = device.allocate(count * 17), b = device.allocate(count * 17), result = device.allocate(count * 2);
    FilterParams p;
    p.width = width; p.height = height; p.radius = radius; p.epsilon = epsilon; p.count = static_cast<uint32_t>(count);
    dispatch(device, p, FilterStage::GuideProducts, *guidance, source.get(), *a);
    p.channels = 17; p.count = static_cast<uint32_t>(count * 17);
    dispatch(device, p, FilterStage::MeanRows, *a, nullptr, *b);
    dispatch(device, p, FilterStage::MeanColumns, *b, nullptr, *a);
    p.count = static_cast<uint32_t>(count);
    dispatch(device, p, FilterStage::GuideCoefficients, *a, nullptr, *b);
    p.channels = 8; p.count = static_cast<uint32_t>(count * 8);
    dispatch(device, p, FilterStage::MeanRows, *b, nullptr, *a);
    dispatch(device, p, FilterStage::MeanColumns, *a, nullptr, *b);
    p.count = static_cast<uint32_t>(count);
    dispatch(device, p, FilterStage::GuideReconstruct, *guidance, b.get(), *result);
    return finiteOutput(device, *result, count * 2, output);
}

bool computePhotoEffects(FilterDevice& device, ImageData& image, const PhotoEffectsOptions& settings) {
    if (!settings.valid()) return false;
    if (!settings.active()) return true;
    FilterParams p;
    p.stage = static_cast<uint32_t>(FilterStage::PhotoEffects);
    p.vignette[0] = settings.vignetteAmount; p.vignette[1] = settings.vignetteMidpoint;
    p.vignette[2] = settings.vignetteRoundness; p.vignette[3] = settings.vignetteFeather;
    p.grain[0] = settings.vignetteHighlights; p.grain[1] = settings.grainAmount;
    p.grain[2] = settings.grainSize; p.grain[3] = settings.grainRoughness;
    return imageFilter(device, image, p);
}

bool computeDetailFilter(FilterDevice& device, ImageData& image, float noiseReduction, float sharpening) {
    if (!std::isfinite(noiseReduction) || !std::isfinite(sharpening)) return false;
    ImageData result = image;
    for (uint32_t direction = 0; direction < 2; ++direction) {
        const float amount = std::clamp(direction == 0 ? noiseReduction : sharpening, 0.f, direction == 0 ? 1.f : 2.f);
        if (amount == 0) continue;
        FilterParams p;
        p.stage = static_cast<uint32_t>(FilterStage::Detail); p.direction = direction; p.strength = amount;
        if (!imageFilter(device, result, p)) return false;
    }
    image = std::move(result);
    return true;
}
} // namespace sony2fuji
