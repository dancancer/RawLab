#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_parser.h"
#include "sony2fuji/dcp_look.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cstdint>
#include <memory>

namespace sony2fuji {

bool renderPhotoMetal(
    const ImageData& input,
    ColorSpace inputSpace,
    const sony2fuji_request& request,
    const std::shared_ptr<LUT3D>& lut,
    const RGB& relativeWB,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output,
    const std::shared_ptr<const DcpLook>& dcp = {}
);

} // namespace sony2fuji
