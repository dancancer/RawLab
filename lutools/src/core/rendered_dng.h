#pragma once

// This product includes DNG technology under license by Adobe Systems
// Incorporated. See third_party/Adobe-DNG-SDK-LICENSE.txt.

#include "sony2fuji/common.h"

#include <string>

namespace sony2fuji {

/**
 * Save a final display-sRGB image as an output-referred DNG 1.4.
 *
 * The input is already display encoded and oriented. Pixel values are clamped
 * to the same [0, 1] range used by the PNG encoder, inverse sRGB decoded, and
 * quantized to uncompressed 16-bit unsigned LinearRaw samples.
 * Embedded sRGB JPEG previews provide the rendered appearance to viewers.
 */
ErrorCode saveRenderedDNG(const ImageData& image, const std::string& filepath);

} // namespace sony2fuji
