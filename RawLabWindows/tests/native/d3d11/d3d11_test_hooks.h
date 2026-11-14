#pragma once

#include <d3d11.h>
#include <wrl/client.h>
#include <chrono>
#include <cstddef>
#include <stdexcept>

namespace sony2fuji::d3d11_test {
inline int photoInitializations = 0;
inline int filterInitializations = 0;
inline int initializationFailures = 0;
inline HRESULT deviceStatus = S_OK;
inline size_t largestPhotoBuffer = 0;
inline size_t filterAllocations = 0;
inline size_t idleFilterFloats = 0;
inline std::chrono::steady_clock::time_point now{};

inline void createDevice(Microsoft::WRL::ComPtr<ID3D11Device>& device,
                         Microsoft::WRL::ComPtr<ID3D11DeviceContext>& context, bool filter) {
    ++(filter ? filterInitializations : photoInitializations);
    if (initializationFailures > 0) {
        --initializationFailures;
        throw std::runtime_error("Injected D3D11 initialization failure");
    }
    const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, &level, 1,
        D3D11_SDK_VERSION, &device, nullptr, &context)))
        throw std::runtime_error("WARP device creation failed");
}
} // namespace sony2fuji::d3d11_test
