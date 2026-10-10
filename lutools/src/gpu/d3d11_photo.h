#pragma once
#include "gpu/photo_gpu.h"

namespace sony2fuji {
// Session-owned device/context and immutable linear RAW upload cache.
// Calls must be serial, as with the owning C ABI session.
class D3D11PhotoRenderer {
public:
    D3D11PhotoRenderer();
    ~D3D11PhotoRenderer();
    D3D11PhotoRenderer(const D3D11PhotoRenderer&) = delete;
    D3D11PhotoRenderer& operator=(const D3D11PhotoRenderer&) = delete;
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
