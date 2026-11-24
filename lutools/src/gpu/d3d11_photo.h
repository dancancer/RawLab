#pragma once
#include "gpu/photo_gpu.h"
#include "gpu/device_retry.h"
#include <string>

namespace sony2fuji {
// Session-owned device/context and immutable linear RAW upload cache.
// Calls must be serial, as with the owning C ABI session.
class D3D11PhotoRenderer {
public:
    D3D11PhotoRenderer();
    ~D3D11PhotoRenderer();
    D3D11PhotoRenderer(const D3D11PhotoRenderer&) = delete;
    D3D11PhotoRenderer& operator=(const D3D11PhotoRenderer&) = delete;
    GpuRenderOutcome renderWithOutcome(const ImageData& input, ColorSpace inputSpace,
        const RenderParams& params, uint32_t width, uint32_t height,
        uint64_t decodeRevision, ImageData& output);
    bool render(const ImageData& input, ColorSpace inputSpace,
        const RenderParams& params, uint32_t width, uint32_t height,
        uint64_t decodeRevision, ImageData& output);
    bool isReadyForQuery() const noexcept;
    static bool disabledByEnvironment() noexcept;
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
