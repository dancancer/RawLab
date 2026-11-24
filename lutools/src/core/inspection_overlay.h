#pragma once

#include "core/pixel_buffer.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cstddef>
#include <cstdint>

namespace sony2fuji {

struct MutablePixelBufferView {
    void* data = nullptr;
    size_t sizeBytes = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t strideBytes = 0;
    PixelBufferFormat format = PixelBufferFormat::RGBA8;
};

void computeInspectionSampleFromRgb(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_sample& out
) noexcept;

RenderStatus sampleInspectionPatch(
    const PixelBufferView& view,
    double normX,
    double normY,
    uint32_t radiusPx,
    sony2fuji_inspection_sample& out
) noexcept;

void applyInspectionOverlayPixel(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_overlay_mode mode,
    uint8_t& outR,
    uint8_t& outG,
    uint8_t& outB
) noexcept;

RenderStatus renderInspectionOverlay(
    const PixelBufferView& src,
    sony2fuji_inspection_overlay_mode mode,
    const MutablePixelBufferView& dst
);

} // namespace sony2fuji
