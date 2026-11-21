#pragma once

#include "core/pixel_buffer.h"
#include <cstdint>

namespace sony2fuji {

RenderStatus loadDisplayImage(const char* path, OwnedPixelBuffer& output);
RenderStatus loadDisplayPreview(const char* path,
                                uint32_t edge,
                                OwnedPixelBuffer& output,
                                uint32_t* orientedSourceWidth = nullptr,
                                uint32_t* orientedSourceHeight = nullptr);

// Cumulative ImageIO decode calls in display_image (process-wide test counter).
uint64_t displayImageDecodeCount();
void resetDisplayImageDecodeCount();

} // namespace sony2fuji
