#pragma once

#include "denoise.h"
#include <cstddef>
#include <cstdint>
#include <memory>

namespace sony2fuji {

enum class FilterStage : uint32_t {
    SwtRows, SwtColumns, EnergyRows, Threshold, IswtColumns, IswtRows,
    GuideProducts, MeanRows, MeanColumns, GuideCoefficients, GuideReconstruct,
    PhotoEffects, Detail
};

struct FilterParams {
    uint32_t width = 0, height = 0, step = 0, level = 0;
    uint32_t channels = 0, radius = 0, stage = 0, count = 0;
    float sigma = 0, strength = 0, epsilon = 0;
    uint32_t direction = 0;
    uint32_t sourceRow = 0, outputRow = 0, baseIndex = 0, reserved = 0;
    float vignette[4]{}, grain[4]{};
};
static_assert(sizeof(FilterParams) == 96, "Native compute parameter layout");

struct FilterBuffer { virtual ~FilterBuffer() = default; };
struct FilterContext { virtual ~FilterContext() = default; };
using FilterBufferPtr = std::unique_ptr<FilterBuffer>;

// The graph owns bounded float planes; backend implementations own API resources.
class FilterDevice {
public:
    virtual ~FilterDevice() = default;
    virtual std::unique_ptr<FilterContext> activate() = 0;
    virtual FilterBufferPtr allocate(size_t count, const float* input = nullptr) = 0;
    virtual void dispatch(FilterParams params, FilterBuffer& source, FilterBuffer* other,
                          FilterBuffer& output, FilterBuffer* secondOutput = nullptr) = 0;
    virtual void read(FilterBuffer& buffer, size_t count, float* output) = 0;
};

std::unique_ptr<FilterDevice> createGlesFilterDevice();
std::unique_ptr<FilterDevice> createD3D11FilterDevice();
bool computeWaveletFilter(FilterDevice& device, const float* input, int width, int height,
                          const WaveletFilterSettings& settings, float* output);
bool computeGuidedFilter(FilterDevice& device, const float* guide, const float* input,
                         int width, int height, int radius, float epsilon, float* output);
bool computePhotoEffects(FilterDevice& device, ImageData& image, const PhotoEffectsOptions& settings);
bool computeDetailFilter(FilterDevice& device, ImageData& image, float noiseReduction, float sharpening);

} // namespace sony2fuji
