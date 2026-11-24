#pragma once

#include "core/pixel_buffer.h"
#include "sony2fuji/common.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cstdint>

namespace sony2fuji {

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

OwnedPixelBuffer encodeRgba16BufferFromFloatRgb(
    const float* data,
    uint32_t width,
    uint32_t height,
    uint64_t strideBytes,
    bool linearToSrgb = false
);

OwnedPixelBuffer encodeRgba16BufferFromImageData(
    const ImageData& image,
    bool linearToSrgb = false
);

} // namespace sony2fuji
