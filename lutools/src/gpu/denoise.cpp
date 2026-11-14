#include "denoise.h"
#include "compute_denoise.h"
#include "core/processing_cancellation.h"
#if defined(SONY2FUJI_ENABLE_METAL)
#include "metal_denoise.h"
#endif
#include <mutex>
#include <exception>
#if defined(SONY2FUJI_ENABLE_GLES)
#include <android/log.h>
#elif defined(SONY2FUJI_ENABLE_D3D11)
#include <windows.h>
#include "d3d11_recovery.h"
#endif

namespace sony2fuji {
namespace {
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
struct ComputeContext {
    std::mutex mutex;
    std::unique_ptr<FilterDevice> device;
#if defined(SONY2FUJI_ENABLE_D3D11)
    DeviceRetry retry;
#endif
    ComputeContext() {
        // Register our destructor after EGL's lazily initialized driver state.
#if defined(SONY2FUJI_ENABLE_GLES)
        device = createGlesFilterDevice();
#endif
    }
};
ComputeContext& computeContext() { static ComputeContext context; return context; }
#endif
template<class Operation>
bool compute(Operation operation) {
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    try {
        auto& context = computeContext();
        auto& device = context.device;
        std::lock_guard<std::mutex> lock(context.mutex);
#if defined(SONY2FUJI_ENABLE_D3D11)
        if (GetEnvironmentVariableW(L"RAWLAB_DISABLE_D3D11", nullptr, 0) > 0) return false;
        if (!device && !context.retry.ready(d3d11RetryNow())) return false;
        const bool initializing = !device;
#endif
        try {
#if defined(SONY2FUJI_ENABLE_GLES)
            if (!device) device = createGlesFilterDevice();
#else
            if (!device) device = createD3D11FilterDevice();
#endif
            auto scope = device->activate();
            const bool ok = operation(*device);
            device->trimPool();
#if defined(SONY2FUJI_ENABLE_D3D11)
            if (ok) context.retry.succeeded();
#endif
            return ok;
        } catch (const ProcessingCancelled&) {
            throw;
        } catch (const std::exception& error) {
#if defined(SONY2FUJI_ENABLE_D3D11)
            if (initializing || d3d11LostDevice(error)) {
                context.retry.failed(d3d11RetryNow());
                device.reset();
            }
#else
            device.reset();
#endif
            throw;
        }
    } catch (const ProcessingCancelled&) {
        throw;
    } catch (const std::exception& error) {
#if defined(SONY2FUJI_ENABLE_GLES)
        __android_log_print(ANDROID_LOG_WARN, "RawLabGPU", "%s", error.what());
#else
        OutputDebugStringA(error.what());
#endif
        return false;
    }
#else
    (void)operation;
    return false;
#endif
}
} // namespace
bool gpuWaveletFilter(const float* input, int width, int height, const WaveletFilterSettings& settings, float* output) {
    if (!validProcessingVersion(settings.processingVersion)) return false;
#if defined(SONY2FUJI_ENABLE_METAL)
    return metalWaveletFilter(input, width, height, settings, output);
#else
    return compute([&](FilterDevice& device) { return computeWaveletFilter(device, input, width, height, settings, output); });
#endif
}
bool gpuGuidedFilter(const float* guide, const float* input, int width, int height, int radius, float epsilon, float* output) {
#if defined(SONY2FUJI_ENABLE_METAL)
    return metalGuidedFilter(guide, input, width, height, radius, epsilon, output);
#else
    return compute([&](FilterDevice& device) { return computeGuidedFilter(device, guide, input, width, height, radius, epsilon, output); });
#endif
}
bool gpuPhotoEffects(ImageData& image, const PhotoEffectsOptions& settings) {
    return compute([&](FilterDevice& device) { return computePhotoEffects(device, image, settings); });
}
bool gpuDetailFilter(ImageData& image, float noiseReduction, float sharpening) {
    return compute([&](FilterDevice& device) { return computeDetailFilter(device, image, noiseReduction, sharpening); });
}
}
