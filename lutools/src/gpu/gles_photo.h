#pragma once

#include "gpu/device_retry.h"
#include "gpu/photo_gpu.h"
#include <memory>
#include <string>

namespace sony2fuji {

class GlesPhotoRenderer {
public:
    GlesPhotoRenderer();
    ~GlesPhotoRenderer();
    GlesPhotoRenderer(const GlesPhotoRenderer&) = delete;
    GlesPhotoRenderer& operator=(const GlesPhotoRenderer&) = delete;

    // decodeRevision is session-owned; zero disables reuse for mutable buffer inputs.
    GpuRenderOutcome renderWithOutcome(const ImageData& input, ColorSpace inputSpace,
        const RenderParams& params, uint32_t width, uint32_t height,
        uint64_t decodeRevision, ImageData& output);
    bool render(const ImageData& input, ColorSpace inputSpace,
        const RenderParams& params, uint32_t width, uint32_t height,
        uint64_t decodeRevision, ImageData& output);
    bool isReadyForQuery() const noexcept;

private:
    bool renderImpl(const ImageData& input, ColorSpace inputSpace,
        const RenderParams& params, uint32_t width, uint32_t height,
        uint64_t decodeRevision, ImageData& output, GpuRenderOutcome& outcome);
    struct Impl;
    std::unique_ptr<Impl> impl_;
    DeviceRetry retry_;
    bool initUnavailable_ = false;
    std::string lastInitError_;
};

}
