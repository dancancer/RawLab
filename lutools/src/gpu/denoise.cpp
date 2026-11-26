#include "denoise.h"
#include "compute_denoise.h"
#include "core/processing_cancellation.h"
#if defined(SONY2FUJI_ENABLE_METAL)
#include "metal_denoise.h"
#endif
#include <mutex>
#include <exception>
#include <new>
#include <string>
#if defined(SONY2FUJI_ENABLE_GLES)
#include <android/log.h>
#include "gles_recovery.h"
#elif defined(SONY2FUJI_ENABLE_D3D11)
#include <windows.h>
#include "d3d11_recovery.h"
#endif

namespace sony2fuji {
namespace {
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
inline DeviceRetry::Clock::time_point filterRetryNow() {
#if defined(SONY2FUJI_ENABLE_GLES)
    return glesRetryNow();
#else
    return d3d11RetryNow();
#endif
}
struct ComputeContext {
    std::mutex mutex;
    std::unique_ptr<FilterDevice> device;
    DeviceRetry retry;
    bool initUnavailable = false;
    std::string lastInitError;
    ComputeContext() {
        // Register our destructor after EGL's lazily initialized driver state.
#if defined(SONY2FUJI_ENABLE_GLES)
        try {
            device = createGlesFilterDevice();
        } catch (const GpuUnavailableError& error) {
            initUnavailable = true;
            lastInitError = error.what();
            retry.failed(glesRetryNow());
        } catch (const std::exception& error) {
            initUnavailable = false;
            lastInitError = error.what();
            retry.failed(glesRetryNow());
        }
#endif
    }
};
ComputeContext& computeContext() { static ComputeContext context; return context; }
#endif
template<class Operation>
bool compute(Operation operation) {
    lastGpuFilterOutcome() = {};
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    auto logError = [](const char* message) {
#if defined(SONY2FUJI_ENABLE_GLES)
        __android_log_print(ANDROID_LOG_WARN, "RawLabGPU", "%s", message);
#else
        OutputDebugStringA(message);
#endif
    };
    auto& context = computeContext();
    auto& device = context.device;
    std::lock_guard<std::mutex> lock(context.mutex);
#if defined(SONY2FUJI_ENABLE_D3D11)
    if (GetEnvironmentVariableW(L"RAWLAB_DISABLE_D3D11", nullptr, 0) > 0) {
        lastGpuFilterOutcome() = {
            GpuFailureKind::Unsupported,
            GpuBackendFault::GpuDisabled,
            "Direct3D 11 filters disabled by RAWLAB_DISABLE_D3D11"
        };
        return false;
    }
#endif
    if (!device && !context.retry.ready(filterRetryNow())) {
        if (context.initUnavailable) {
            lastGpuFilterOutcome() = {
                GpuFailureKind::Unsupported,
                GpuBackendFault::Cooldown,
                context.lastInitError.empty() ? "GPU filter device unavailable (retry cooldown)" : context.lastInitError
            };
        } else {
            lastGpuFilterOutcome() = {
                GpuFailureKind::ProcessingError,
                GpuBackendFault::Cooldown,
                context.lastInitError.empty() ? "GPU filter device recovery cooldown" : context.lastInitError
            };
        }
        return false;
    }
    bool initializing = !device;
    try {
#if defined(SONY2FUJI_ENABLE_GLES)
        if (!device) device = createGlesFilterDevice();
#else
        if (!device) device = createD3D11FilterDevice();
#endif
        initializing = false;
        auto scope = device->activate();
        const bool ok = operation(*device);
        device->trimPool();
        if (ok) {
            context.retry.succeeded();
            context.initUnavailable = false;
            context.lastInitError.clear();
            lastGpuFilterOutcome() = {};
        } else if (lastGpuFilterOutcome().failure == GpuFailureKind::None) {
            lastGpuFilterOutcome() = {
                GpuFailureKind::ProcessingError,
                GpuBackendFault::FilterError,
                "GPU filter rejected input or produced invalid output"
            };
        }
        return ok;
    } catch (const ProcessingCancelled&) {
        if (device) device->clearErrors();
        throw;
    } catch (const std::bad_alloc&) {
        if (device) device->clearErrors();
        throw;
    } catch (const GpuUnavailableError& error) {
        context.initUnavailable = true;
        context.lastInitError = error.what();
        context.retry.failed(filterRetryNow());
        device.reset();
        lastGpuFilterOutcome() = {
            GpuFailureKind::Unsupported,
            GpuBackendFault::NoAdapter,
            error.what()
        };
        logError(error.what());
        return false;
    } catch (const GpuCapabilityLimitError& error) {
        if (device) device->clearErrors();
        lastGpuFilterOutcome() = {
            GpuFailureKind::Unsupported,
            GpuBackendFault::UnsupportedCapability,
            error.what()
        };
        logError(error.what());
        return false;
    } catch (const std::exception& error) {
#if defined(SONY2FUJI_ENABLE_D3D11)
        const bool lost = initializing || d3d11LostDevice(error) || (device && device->deviceLost());
#else
        const bool lost = initializing || glesLostDevice(error);
#endif
        if (lost) {
            context.initUnavailable = false;
            context.lastInitError = error.what();
            context.retry.failed(filterRetryNow());
            device.reset();
        } else if (device) {
            device->clearErrors();
        }
        lastGpuFilterOutcome() = {
            GpuFailureKind::ProcessingError,
            GpuBackendFault::FilterError,
            error.what()
        };
        logError(error.what());
        return false;
    }
#else
    (void)operation;
    lastGpuFilterOutcome() = {
        GpuFailureKind::Unsupported,
        GpuBackendFault::GpuDisabled,
        "GPU compute filter backend is not enabled"
    };
    return false;
#endif
}
} // namespace
bool gpuWaveletFilter(const float* input, int width, int height, const WaveletFilterSettings& settings, float* output) {
    lastGpuFilterOutcome() = {};
    if (!validProcessingVersion(settings.processingVersion)) return false;
#if defined(SONY2FUJI_ENABLE_METAL)
    return metalWaveletFilter(input, width, height, settings, output);
#else
    return compute([&](FilterDevice& device) { return computeWaveletFilter(device, input, width, height, settings, output); });
#endif
}
bool gpuGuidedFilter(const float* guide, const float* input, int width, int height, int radius, float epsilon, float* output) {
    lastGpuFilterOutcome() = {};
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
bool gpuFilmOptics(ImageData& image, const FilmOpticsOptions& options) {
    return compute([&](FilterDevice& device) { return computeFilmOptics(device, image, options); });
}
}
