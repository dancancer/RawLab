#include "core/pipeline.h"

#include "core/photo_pipeline_stages.h"
#include "core/processing_cancellation.h"

#include <algorithm>

namespace sony2fuji {

RenderStatus Pipeline::setGeometry(const GeometryOptions& options) {
    GeometryOptions normalized = geometry_;
    normalized.crop_x = options.crop_x;
    normalized.crop_y = options.crop_y;
    normalized.crop_width = options.crop_width;
    normalized.crop_height = options.crop_height;
    normalized.quarter_turns = options.quarter_turns;
    normalized.flip_horizontal = options.flip_horizontal;
    normalized.flip_vertical = options.flip_vertical;
    normalized.straighten_degrees = options.straighten_degrees;
    if (!normalized.valid()) return RenderStatus::InvalidArgument;
    normalized.crop_width = std::min(normalized.crop_width, 1.0f - normalized.crop_x);
    normalized.crop_height = std::min(normalized.crop_height, 1.0f - normalized.crop_y);
    geometry_ = normalized;
    geometryWidth_ = geometryHeight_ = 0;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::setPerspective(float horizontal, float vertical) {
    auto options = geometry_;
    options.perspective_horizontal = horizontal;
    options.perspective_vertical = vertical;
    if (!options.valid()) return RenderStatus::InvalidArgument;
    geometry_ = options;
    geometryWidth_ = geometryHeight_ = 0;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::getGeometrySize(uint32_t& width, uint32_t& height) const {
    width = 0;
    height = 0;
    if (geometryWidth_ == 0 || geometryHeight_ == 0) {
        return RenderStatus::Unsupported;
    }
    width = geometryWidth_;
    height = geometryHeight_;
    return RenderStatus::Ok;
}

RenderStatus Pipeline::finishGeometry(
    const RenderParams& params,
    ImageData& image,
    uint32_t nativeWidth,
    uint32_t nativeHeight
) {
    checkProcessingCancellation();
    uint32_t width = 0, height = 0;
    const auto status = computeTargetSize(params, nativeWidth, nativeHeight, &width, &height);
    if (status != RenderStatus::Ok) return status;
    const auto transformed = applyGeometry(image, geometry_);
    if (transformed != ErrorCode::Success) return mapErrorCode(transformed);
    if (width != static_cast<uint32_t>(image.width) || height != static_cast<uint32_t>(image.height)) {
        image = resizeBilinear(image, width, height);
    }
    return RenderStatus::Ok;
}

} // namespace sony2fuji
