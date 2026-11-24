#include "sony2fuji/ffi/sony2fuji_c.h"

#include "core/inspection_overlay.h"
#include "core/photo_geometry.h"
#include "core/pixel_buffer.h"
#include "core/processing_cancellation.h"

#include <cmath>
#include <cstdint>
#include <limits>
#include <new>

namespace {

static_assert(sizeof(sony2fuji_inspection_sample) == 48, "Inspection sample C ABI size");

sony2fuji_status toFfiStatus(sony2fuji::RenderStatus status) noexcept {
    return static_cast<sony2fuji_status>(status);
}

bool toCoreGeometryOptions(
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    sony2fuji::GeometryOptions& out
) noexcept {
    out = sony2fuji::GeometryOptions{};
    if (geometry) {
        if (geometry->version != SONY2FUJI_GEOMETRY_CONFIG_VERSION ||
            geometry->struct_size != sizeof(*geometry) ||
            (geometry->flip_horizontal != 0 && geometry->flip_horizontal != 1) ||
            (geometry->flip_vertical != 0 && geometry->flip_vertical != 1)) {
            return false;
        }
        out.crop_x = geometry->crop_x;
        out.crop_y = geometry->crop_y;
        out.crop_width = geometry->crop_width;
        out.crop_height = geometry->crop_height;
        out.quarter_turns = geometry->quarter_turns;
        out.flip_horizontal = geometry->flip_horizontal != 0;
        out.flip_vertical = geometry->flip_vertical != 0;
        out.straighten_degrees = geometry->straighten_degrees;
    }
    if (perspective) {
        if (perspective->version != SONY2FUJI_PERSPECTIVE_CONFIG_VERSION ||
            perspective->struct_size != sizeof(*perspective)) {
            return false;
        }
        out.perspective_horizontal = perspective->horizontal;
        out.perspective_vertical = perspective->vertical;
    }
    return out.valid();
}

bool validOutSample(const sony2fuji_inspection_sample* out_sample) noexcept {
    return out_sample != nullptr &&
        out_sample->version == SONY2FUJI_INSPECTION_SAMPLE_VERSION &&
        out_sample->struct_size == sizeof(*out_sample) &&
        out_sample->reserved0 == 0 &&
        out_sample->reserved1 == 0;
}

bool validDim(uint32_t dim) noexcept {
    return dim > 0 && dim <= static_cast<uint32_t>(std::numeric_limits<int>::max());
}

} // namespace

extern "C" {

sony2fuji_status sony2fuji_geometry_output_size(
    uint32_t source_width,
    uint32_t source_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    uint32_t* out_width,
    uint32_t* out_height
) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    sony2fuji::GeometryOptions options;
    if (!out_width || !out_height || !validDim(source_width) || !validDim(source_height) ||
        !toCoreGeometryOptions(geometry, perspective, options)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const auto [w, h] = sony2fuji::geometryOutputSize(
        static_cast<int>(source_width), static_cast<int>(source_height), options);
    if (w <= 0 || h <= 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *out_width = static_cast<uint32_t>(w);
    *out_height = static_cast<uint32_t>(h);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_geometry_infer_source_size(
    uint32_t output_width,
    uint32_t output_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    uint32_t* out_source_width,
    uint32_t* out_source_height
) {
    if (out_source_width) *out_source_width = 0;
    if (out_source_height) *out_source_height = 0;
    sony2fuji::GeometryOptions options;
    if (!out_source_width || !out_source_height || !validDim(output_width) || !validDim(output_height) ||
        !toCoreGeometryOptions(geometry, perspective, options)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const auto [w, h] = sony2fuji::geometryInferSourceSize(
        static_cast<int>(output_width), static_cast<int>(output_height), options);
    if (w <= 0 || h <= 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *out_source_width = static_cast<uint32_t>(w);
    *out_source_height = static_cast<uint32_t>(h);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_geometry_output_norm_to_source_norm(
    uint32_t source_width,
    uint32_t source_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    double out_x,
    double out_y,
    double* out_source_x,
    double* out_source_y,
    int32_t* out_valid
) {
    if (out_source_x) *out_source_x = 0.0;
    if (out_source_y) *out_source_y = 0.0;
    if (out_valid) *out_valid = 0;
    sony2fuji::GeometryOptions options;
    if (!out_source_x || !out_source_y || !out_valid ||
        !validDim(source_width) || !validDim(source_height) ||
        !std::isfinite(out_x) || !std::isfinite(out_y) ||
        out_x < -1e-4 || out_x > 1.0 + 1e-4 || out_y < -1e-4 || out_y > 1.0 + 1e-4 ||
        !toCoreGeometryOptions(geometry, perspective, options)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    double sx = 0.0;
    double sy = 0.0;
    if (sony2fuji::geometryOutputNormToSourceNorm(
            static_cast<int>(source_width), static_cast<int>(source_height),
            options, out_x, out_y, sx, sy)) {
        *out_source_x = sx;
        *out_source_y = sy;
        *out_valid = 1;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_geometry_source_norm_to_output_norm(
    uint32_t source_width,
    uint32_t source_height,
    const sony2fuji_geometry_config* geometry,
    const sony2fuji_perspective_config* perspective,
    double source_x,
    double source_y,
    double* out_output_x,
    double* out_output_y,
    int32_t* out_valid
) {
    if (out_output_x) *out_output_x = 0.0;
    if (out_output_y) *out_output_y = 0.0;
    if (out_valid) *out_valid = 0;
    sony2fuji::GeometryOptions options;
    if (!out_output_x || !out_output_y || !out_valid ||
        !validDim(source_width) || !validDim(source_height) ||
        !std::isfinite(source_x) || !std::isfinite(source_y) ||
        source_x < -1e-4 || source_x > 1.0 + 1e-4 || source_y < -1e-4 || source_y > 1.0 + 1e-4 ||
        !toCoreGeometryOptions(geometry, perspective, options)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    double ox = 0.0;
    double oy = 0.0;
    if (sony2fuji::geometrySourceNormToOutputNorm(
            static_cast<int>(source_width), static_cast<int>(source_height),
            options, source_x, source_y, ox, oy)) {
        *out_output_x = ox;
        *out_output_y = oy;
        *out_valid = 1;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_inspection_color_from_rgb(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_sample* out_sample
) {
    if (!validOutSample(out_sample)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji::computeInspectionSampleFromRgb(r, g, b, *out_sample);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_inspection_sample_patch(
    const sony2fuji_buffer* image,
    double norm_x,
    double norm_y,
    uint32_t radius_px,
    sony2fuji_inspection_sample* out_sample
) {
    if (!image || !validOutSample(out_sample)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const sony2fuji::PixelBufferView view{
        image->data,
        image->size_bytes,
        image->width,
        image->height,
        image->stride_bytes,
        static_cast<sony2fuji::PixelBufferFormat>(image->pixel_format),
    };
    return toFfiStatus(sony2fuji::sampleInspectionPatch(view, norm_x, norm_y, radius_px, *out_sample));
}

sony2fuji_status sony2fuji_inspection_overlay_pixel(
    uint8_t r,
    uint8_t g,
    uint8_t b,
    sony2fuji_inspection_overlay_mode mode,
    uint8_t* out_r,
    uint8_t* out_g,
    uint8_t* out_b
) {
    if (!out_r || !out_g || !out_b ||
        mode < SONY2FUJI_INSPECTION_OVERLAY_NONE ||
        mode > SONY2FUJI_INSPECTION_OVERLAY_NEUTRAL_GRAY_50) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji::applyInspectionOverlayPixel(r, g, b, mode, *out_r, *out_g, *out_b);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_inspection_render_overlay(
    const sony2fuji_buffer* src,
    sony2fuji_inspection_overlay_mode mode,
    sony2fuji_buffer* dst
) {
    if (!src || !dst) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        const sony2fuji::PixelBufferView srcView{
            src->data,
            src->size_bytes,
            src->width,
            src->height,
            src->stride_bytes,
            static_cast<sony2fuji::PixelBufferFormat>(src->pixel_format),
        };
        const sony2fuji::MutablePixelBufferView dstView{
            dst->data,
            dst->size_bytes,
            dst->width,
            dst->height,
            dst->stride_bytes,
            static_cast<sony2fuji::PixelBufferFormat>(dst->pixel_format),
        };
        return toFfiStatus(sony2fuji::renderInspectionOverlay(srcView, mode, dstView));
    } catch (const sony2fuji::ProcessingCancelled&) {
        return SONY2FUJI_STATUS_CANCELLED;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

} // extern "C"
