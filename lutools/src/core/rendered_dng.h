#pragma once

// This product includes DNG technology under license by Adobe Systems
// Incorporated. See third_party/Adobe-DNG-SDK-LICENSE.txt.

#include "sony2fuji/common.h"

#include <cstdint>
#include <functional>
#include <string>

namespace sony2fuji {

/**
 * Deterministic Classic TIFF capacity check shared with request/header preflight.
 *
 * Rendered DNG writes uncompressed 16-bit 3-channel LinearRaw strips (64 rows/strip),
 * 32-bit StripOffsets/StripByteCounts tables, a conservative 64 KiB TIFF/DNG directory
 * reservation, and the fixed neutral Adobe XMP packet within the 4,294,967,295-byte
 * Classic TIFF limit.
 */
bool exceedsRenderedDngCapacity(uint32_t width, uint32_t height,
                                uint64_t* remainingPreviewBytes = nullptr);

/**
 * Save a final display-sRGB image as an output-referred DNG 1.4.
 *
 * The input is already display encoded and oriented. Pixel values are clamped
 * to the same [0, 1] range used by the PNG encoder, inverse sRGB decoded, and
 * quantized to uncompressed 16-bit unsigned LinearRaw samples.
 * Embedded sRGB JPEG previews provide the rendered appearance to viewers.
 *
 * Cancellation semantics match ImageEncoder::saveImage (raw_processor.h): with a
 * cancellation scope installed, a cancelled save rethrows ProcessingCancelled and
 * never comes back as a generic ErrorCode.
 */
ErrorCode saveRenderedDNG(const ImageData& image, const std::string& filepath);

struct RenderedDNGRows {
    uint32_t width = 0, height = 0;
    // 显示编码 sRGB；允许缩略图、主图和 JPEG 预览重复读取。返回值有效到下一次读取。
    std::function<const RGB*(uint32_t)> read;
};
ErrorCode saveRenderedDNGRows(const RenderedDNGRows& image, const std::string& filepath,
    const std::function<void()>& beforePublish = {});

} // namespace sony2fuji
