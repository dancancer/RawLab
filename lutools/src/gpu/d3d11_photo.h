#pragma once
#include "gpu/photo_gpu.h"
#include "gpu/device_retry.h"

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
        const RenderParams& params, uint32_t width, uint32_t height,
        uint64_t decodeRevision, ImageData& output);
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    DeviceRetry retry_;
};
}
