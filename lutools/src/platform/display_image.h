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

} // namespace sony2fuji
