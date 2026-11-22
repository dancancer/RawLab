#pragma once

#include "core/pixel_buffer.h"
#include "sony2fuji/common.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cstdint>
#include <string>
#include <vector>

namespace sony2fuji {

struct BshSampleQueryItem {
    float normX = 0.0f;
    float normY = 0.0f;
    std::string label;
};

struct BshSampleEntry {
    std::string label;
    float normX = 0.0f;
    float normY = 0.0f;
    sony2fuji_bsh_sample_result result{};
};

RenderStatus diagnosePixelBuffer(
    const PixelBufferView& view,
    uint32_t sampleStride,
    sony2fuji_bsh_diagnosis& out
);

RenderStatus sampleRegionBshBuffer(
    const PixelBufferView& view,
    float normX,
    float normY,
    float radiusNorm,
    sony2fuji_bsh_sample_result& out
);

OwnedPixelBuffer encodeRgba16BufferFromImageData(
    const ImageData& image,
    bool linearToSrgb = false
);

bool parseBshSampleArg(
    const std::string& rawArg,
    BshSampleQueryItem& out,
    std::string& error
);

const char* bshCastHintName(sony2fuji_bsh_cast_hint hint) noexcept;
const char* hslChannelName(sony2fuji_hsl_channel channel) noexcept;

std::string bshDiagnosisToJsonString(
    const sony2fuji_bsh_diagnosis& diag,
    const std::vector<BshSampleEntry>& samples
);

} // namespace sony2fuji
