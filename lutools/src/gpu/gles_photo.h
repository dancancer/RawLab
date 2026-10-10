#pragma once

#include "gpu/photo_gpu.h"
#include <memory>

namespace sony2fuji {

class GlesPhotoRenderer {
public:
    GlesPhotoRenderer();
    ~GlesPhotoRenderer();
    GlesPhotoRenderer(const GlesPhotoRenderer&) = delete;
    GlesPhotoRenderer& operator=(const GlesPhotoRenderer&) = delete;

    // decodeRevision is session-owned; zero disables reuse for mutable buffer inputs.
    bool render(const ImageData& input, ColorSpace inputSpace,
        const sony2fuji_request& request, const std::shared_ptr<LUT3D>& lut,
        const RGB& relativeWB, uint32_t width, uint32_t height,
        uint64_t decodeRevision, ImageData& output, const PhotoEffectsOptions& effects = {},
        int chromaDenoise = 0, bool preserveSourceResolution = false);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}
