#pragma once

#include "sony2fuji/common.h"

#include <array>
#include <cstdint>

namespace sony2fuji {

enum class HslProbeAvailability : int32_t {
    Available = 0,
    NearGray = 1,
    Outside = 2,
    Stale = 3,
    NonFinite = 4
};

enum class HslProbeQuality : int32_t {
    ExactCpu = 0,
    PreviewCpu = 1
};

struct HslProbeData {
    ImageData image;
    uint64_t sourceRevision = 0;
    uint64_t requestRevision = 0;
    HslProbeQuality quality = HslProbeQuality::ExactCpu;
    bool hdr = false;
};

struct HslProbeSampleResult {
    uint64_t sourceRevision = 0;
    uint64_t requestRevision = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    HslProbeAvailability availability = HslProbeAvailability::Outside;
    HslProbeQuality quality = HslProbeQuality::ExactCpu;
    std::array<float, 3> rgb{};
    std::array<float, 3> hsl{};
    std::array<float, 8> weights{};
};

HslProbeSampleResult sampleHslProbe(
    const HslProbeData& probe,
    uint64_t sourceRevision,
    uint64_t requestRevision,
    float x,
    float y
);

} // namespace sony2fuji
