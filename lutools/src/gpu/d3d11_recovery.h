#pragma once

#include "device_retry.h"
#include <d3d11.h>
#include <dxgi.h>
#include <stdexcept>
#include <string>
#if defined(RAWLAB_D3D11_TESTING)
#include "d3d11_test_hooks.h"
#endif

namespace sony2fuji {

class D3D11Failure : public std::runtime_error {
public:
    explicit D3D11Failure(HRESULT code)
        : std::runtime_error("Direct3D 11 operation failed: " + std::to_string(code)), code_(code) {}
    bool deviceLost() const {
        return code_ == DXGI_ERROR_DEVICE_REMOVED || code_ == DXGI_ERROR_DEVICE_RESET ||
            code_ == DXGI_ERROR_DEVICE_HUNG || code_ == DXGI_ERROR_DRIVER_INTERNAL_ERROR;
    }
private:
    HRESULT code_;
};

inline DeviceRetry::Clock::time_point d3d11RetryNow() {
#if defined(RAWLAB_D3D11_TESTING)
    return d3d11_test::now;
#else
    return DeviceRetry::Clock::now();
#endif
}

inline HRESULT d3d11DeviceStatus(ID3D11Device& device) {
#if defined(RAWLAB_D3D11_TESTING)
    if (FAILED(d3d11_test::deviceStatus)) return d3d11_test::deviceStatus;
#endif
    return device.GetDeviceRemovedReason();
}

inline bool d3d11LostDevice(const std::exception& error) {
    const auto* failure = dynamic_cast<const D3D11Failure*>(&error);
    return failure && failure->deviceLost();
}

} // namespace sony2fuji
