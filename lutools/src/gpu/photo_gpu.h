#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_parser.h"
#include "sony2fuji/dcp_look.h"
#include "core/render_params.h"

#include <cstdint>
#include <memory>

namespace sony2fuji {

bool renderPhotoMetal(
    const ImageData& input,
    ColorSpace inputSpace,
    const RenderParams& params,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output
);

} // namespace sony2fuji
