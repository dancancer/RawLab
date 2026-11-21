#pragma once

#include "sony2fuji/lut_parser.h"
#include <cstddef>
#include <vector>

namespace sony2fuji {

std::vector<float> buildLutTextureDataRGBA(const LUT3D& lut);
ErrorCode applyLutGlesStatus(const LUT3D& lut, ImageData& image, size_t* completedPixels);

}
