#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_parser.h"
#include "sony2fuji/dcp_look.h"
#include "core/render_params.h"

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>

namespace sony2fuji {

enum class GpuFailureKind : int32_t {
    None = 0,
    Unsupported = 1,
    OutOfMemory = 2,
    ProcessingError = 3
};

enum class GpuBackendFault : int32_t {
    None = 0,
    GpuDisabled = 1,
    NoAdapter = 2,
    Cooldown = 3,
    DeviceError = 4,
    FilterError = 5,
    UnsupportedCapability = 6
};

struct GpuRenderOutcome {
    GpuFailureKind failure = GpuFailureKind::None;
    GpuBackendFault fault = GpuBackendFault::None;
    std::string message;

    bool succeeded() const noexcept { return failure == GpuFailureKind::None; }
};

class GpuUnavailableError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class GpuCapabilityLimitError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct PhotoGpuCapabilities {
    bool compiled = false;
    bool ready = false;
    bool supportsEffects = false;
    bool supportsDcp = false;
    bool supportsFilmOptics = false;
    bool dimensionsSupported = false;
};

PhotoGpuCapabilities queryMetalPhotoCapabilities(uint32_t width, uint32_t height) noexcept;

// Wave 1 GPU parameter architecture contract:
// Existing `PhotoParams` (3544 bytes) remains byte-frozen and untouched so historical
// GPU kernels and static_asserts keep zero regression. v0.14.0 GPU stages bind
// separate secondary parameter buffers via dedicated shared shader headers:
//   - `photo_color_science_shader.h` (Camera Calibration, B&W mixer, Point Color 3D/swatches, Selective Color)
//   - `photo_spatial_shader.h`       (Texture pyramid, Luminance USM v2 & edge masking, Defringe)
//   - `dcp_look_shader.h`            (DCP look curve / neutral-preserving calibration compatibility)
//   - `photo_film_optics_shader.h`   (Halation, Bloom, asymmetric negative grain curves)

GpuRenderOutcome renderPhotoMetalWithOutcome(
    const ImageData& input,
    ColorSpace inputSpace,
    const RenderParams& params,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output
);

bool renderPhotoMetal(
    const ImageData& input,
    ColorSpace inputSpace,
    const RenderParams& params,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output
);

} // namespace sony2fuji
