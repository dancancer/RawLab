#include "core/pipeline.h"
#include "core/pipeline_runtime.h"

#include "core/hdr_types.h"
#include "platform/hdr_image.h"

#ifdef SONY2FUJI_ENABLE_AI_DENOISE
#include "ai/ai_session.h"
#include "ai/directml_device.h"
#endif

#include <cstring>
#include <filesystem>

namespace sony2fuji {

bool Pipeline::aiAvailable() {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    return true;
#else
    return false;
#endif
}

bool Pipeline::aiHardwareAvailable() {
#if defined(SONY2FUJI_ENABLE_AI_DENOISE) && defined(_WIN32)
    try {
        ai::findDirectMLAdapter();
        return true;
    } catch (...) {
        return false;
    }
#elif defined(SONY2FUJI_ENABLE_AI_DENOISE) && defined(__APPLE__)
    try {
        return ai::CoreMLGraph::available();
    } catch (...) {
        return false;
    }
#else
    return false;
#endif
}

std::string Pipeline::aiDevicesJson() {
#if defined(SONY2FUJI_ENABLE_AI_DENOISE) && defined(_WIN32)
    try {
        return ai::directMLDevicesJSON();
    } catch (...) {
        return "{\"version\":1,\"devices\":[],\"recommended_id\":\"\",\"error\":\"Device enumeration failed\"}";
    }
#else
    return "{\"version\":1,\"devices\":[],\"recommended_id\":\"\",\"error\":\"DirectML is unavailable in this build\"}";
#endif
}

bool Pipeline::hdrCameraAiAvailable() {
#if defined(SONY2FUJI_ENABLE_AI_DENOISE) && defined(__APPLE__)
    try {
        return ai::CoreMLGraph::gpuPlanAvailable();
    } catch (...) {
        return false;
    }
#elif defined(SONY2FUJI_ENABLE_AI_DENOISE) && defined(_WIN32)
    return aiHardwareAvailable();
#else
    return false;
#endif
}

bool Pipeline::aiEnabled() const noexcept {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    return runtime_ && runtime_->ai && runtime_->ai->enabled;
#else
    return false;
#endif
}

RenderStatus Pipeline::recordAiError(RenderStatus status, const char* message) noexcept {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (aiEnabled()) {
        try {
            runtime_->ai->lastError = ai::nativeErrorText(message);
            runtime_->ai->recordFailure(static_cast<int>(status), runtime_->ai->lastError);
        } catch (...) {
        }
    }
#else
    (void)message;
#endif
    return status;
}

void Pipeline::beginAiOperation(const char* name) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (aiEnabled()) {
        runtime_->ai->beginOperation(name);
    }
#else
    (void)name;
#endif
}

RenderStatus Pipeline::setAiDevice(const char* deviceId) {
    const auto* id = deviceId ? deviceId : "";
    if (std::strlen(id) > 256) return RenderStatus::InvalidArgument;
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
#ifndef _WIN32
    if (*id) return RenderStatus::Unsupported;
#endif
    try {
        if (!runtime_->ai) runtime_->ai = std::make_unique<ai::AISession>();
        runtime_->ai->setDevice(id);
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::InvalidArgument;
    }
#else
    return *id ? RenderStatus::Unsupported : RenderStatus::Ok;
#endif
}

std::string Pipeline::aiDiagnosticsJson() const {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (runtime_ && runtime_->ai) {
        try {
            return runtime_->ai->diagnosticsJSON();
        } catch (...) {
            return "{\"version\":1,\"error\":\"Diagnostic snapshot unavailable\"}";
        }
    }
#endif
    return "{\"version\":1,\"logs\":[]}";
}

RenderStatus Pipeline::setAiDenoise(const AiDenoiseConfig& config) {
    if (config.enabled && (config.modelDirectory.empty() || config.cacheDirectory.empty())) {
        return RenderStatus::InvalidArgument;
    }
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (config.enabled && config.backend == AiBackendPreference::Cpu) {
        return RenderStatus::Unsupported;
    }
    const bool hadAI = runtime_->ai != nullptr;
    const bool previousEnabled = hadAI ? runtime_->ai->enabled : false;
    auto rollback = [&]() noexcept {
        if (!hadAI) {
            runtime_->ai.reset();
        } else if (runtime_->ai) {
            runtime_->ai->enabled = previousEnabled;
        }
    };
    try {
        if (!runtime_->ai) runtime_->ai = std::make_unique<ai::AISession>();
        const auto backend =
            config.backend == AiBackendPreference::Cpu ? ai::Backend::Cpu :
            config.backend == AiBackendPreference::CoreML ? ai::Backend::CoreML :
            config.backend == AiBackendPreference::DirectML ? ai::Backend::DirectML :
            ai::Backend::Auto;
        runtime_->ai->enabled = config.enabled;
        runtime_->ai->configure(config.modelDirectory, config.cacheDirectory, backend);
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        rollback();
        return RenderStatus::OutOfMemory;
    } catch (const std::exception&) {
        rollback();
        return RenderStatus::InvalidArgument;
    } catch (...) {
        rollback();
        return RenderStatus::ProcessingError;
    }
#else
    return config.enabled ? RenderStatus::Unsupported : RenderStatus::Ok;
#endif
}

std::string Pipeline::aiError() const {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (runtime_ && runtime_->ai) return runtime_->ai->lastError;
#endif
    return {};
}

std::string Pipeline::aiBackend() const {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (runtime_ && runtime_->ai) return runtime_->ai->lastBackend;
#endif
    return {};
}

RenderStatus Pipeline::prepareAi(const RenderParams& params, const AiProgressCallback& progress) {
    if (params.inputType != RenderInputType::Raw ||
        params.wbMode < RenderWhiteBalanceMode::Camera ||
        params.wbMode > RenderWhiteBalanceMode::Temperature) {
        return RenderStatus::InvalidArgument;
    }
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    if (!runtime_ || !runtime_->ai) return RenderStatus::InvalidArgument;
    // AI 降噪只在硬件后端运行、不回退 CPU，但取消语义走公共 ProcessingCancellationScope 链：
    // 会话级回调在此安装，tile/阶段边界经锁存短路（对齐 HDR 路径 hdrSessionPrepareCameraAI 的口径）。
    ProcessingCancellationScope cancellation(cancellation_);
    auto local = params;
    local.outputTarget = RenderOutputTarget::Buffer;
    local.outputFormat = RenderOutputFormat::RGB8;
    const auto valid = validateRenderParams(local, true);
    if (valid != RenderStatus::Ok) return valid;
    auto failure = [&](RenderStatus status, const std::string& message) {
        runtime_->ai->lastError = ai::nativeErrorText(message);
        runtime_->ai->recordFailure(static_cast<int>(status), runtime_->ai->lastError);
        return status;
    };
    try {
        // 入口预检（对齐 sony2fuji_hdr.cpp 安装 scope 后立即 check 的口径）：已取消则不再解析镜头库。
        processingCancellation.check();
        if (lensCorrection_.active()) ensureLensDatabase();
        runtime_->ai->prepare(local.inputPath.c_str(), rawWhiteBalanceOptions(local),
            [&](ai::Phase phase, size_t done, size_t total) {
                return !processingCancellation.cancelled() &&
                    (!progress || progress(static_cast<int32_t>(phase), done, total));
            });
        return RenderStatus::Ok;
    } catch (const ProcessingCancelled&) {
        // 取消不是处理失败：在通用 catch 之前放行，语义与 ai::Cancelled 相同。
        return RenderStatus::Cancelled;
    } catch (const ai::Cancelled& error) {
        runtime_->ai->lastError = error.what();
        return RenderStatus::Cancelled;
    } catch (const ai::DecodeError& error) {
        return failure(mapErrorCode(error.code), error.what());
    } catch (const std::bad_alloc&) {
        return failure(RenderStatus::OutOfMemory, "AI denoising ran out of memory");
    } catch (const std::invalid_argument& error) {
        return failure(RenderStatus::Unsupported, error.what());
    } catch (const std::filesystem::filesystem_error& error) {
        return failure(RenderStatus::IoError, error.what());
    } catch (const std::exception& error) {
        return failure(RenderStatus::ProcessingError, error.what());
    } catch (...) {
        return failure(RenderStatus::ProcessingError, "Unknown native AI failure");
    }
#else
    (void)params;
    (void)progress;
    return RenderStatus::Unsupported;
#endif
}

namespace {

[[noreturn]] void unavailableHdrCameraAi() {
    throw hdr::Error(RenderStatus::Unsupported, kHdrReasonCameraAi,
        kHdrFieldSession, "HDR camera AI requires a configured hardware GPU session");
}

#ifdef SONY2FUJI_ENABLE_AI_DENOISE
template <class Job>
decltype(auto) withHdrCameraAi(PipelineRuntimeState* runtime, Job job) {
    if (!runtime || !runtime->ai || !runtime->ai->enabled || !Pipeline::hdrCameraAiAvailable()) {
        unavailableHdrCameraAi();
    }
    auto& state = *runtime->ai;
    auto fail = [&](RenderStatus status, const char* message) -> void {
        state.lastBackend.clear();
        state.lastError = ai::nativeErrorText(message);
        state.recordFailure(static_cast<int>(status), state.lastError);
        throw hdr::Error(status, kHdrReasonCameraAi, kHdrFieldCameraDevelopment, message);
    };
    try {
        state.lastError.clear();
        return job(state);
    } catch (const ai::Cancelled&) {
        throw ProcessingCancelled();
    } catch (const ProcessingCancelled&) {
        throw;
    } catch (const hdr::Error&) {
        throw;
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const ai::NotReady& error) {
        fail(RenderStatus::AiNotReady, error.what());
    } catch (const ai::Unsupported& error) {
        fail(RenderStatus::Unsupported, error.what());
    } catch (const ai::DecodeError& error) {
        fail(mapErrorCode(error.code), error.what());
    } catch (const std::filesystem::filesystem_error& error) {
        fail(RenderStatus::IoError, error.what());
    } catch (const std::exception& error) {
        fail(RenderStatus::ProcessingError, error.what());
    } catch (...) {
        fail(RenderStatus::ProcessingError, "Unknown native AI failure");
    }
    std::terminate();
}
#endif

} // namespace

void Pipeline::prepareHdrCameraAi(const char* path, uint64_t fileBytes, const AiProgressCallback& progress) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    withHdrCameraAi(runtime_.get(), [&](ai::AISession& state) {
        const ai::JobProgress report = [&](ai::Phase phase, size_t done, size_t total) {
            return !processingCancellation.cancelled() &&
                (!progress || progress(static_cast<int32_t>(phase), done, total));
        };
        if (!report(ai::Phase::Loading, 0, 1)) throw ProcessingCancelled();
        const auto identity = ai::sourceIdentityKey(path, checkProcessingCancellation);
        const bool legacySonyCrop = usesLegacySonyCrop();
        RAWBayerSource source;
        {
            RAWProcessor processor(legacySonyCrop);
            int width = 0, height = 0;
            uint64_t sensorPixels = 0;
            auto status = processor.inspectCameraHDR(path, width, height, sensorPixels);
            if (status == ErrorCode::InvalidFormat) throw ai::Unsupported("Unsupported Bayer RAW for HDR AI");
            if (status != ErrorCode::Success) throw ai::DecodeError(status, "Cannot open Bayer RAW for HDR AI");
            // Sensor buffers, packed tensors and the largest model tile can overlap during preparation.
            hdr::admitMemory(fileBytes + sensorPixels * 24 + (256ull << 20));
            status = processor.unpackInspectedCameraHDR();
            if (status == ErrorCode::Success) status = processor.readBayerSource(RAWProcessOptions{}, source);
            if (status != ErrorCode::Success) throw ai::DecodeError(status, "Cannot unpack Bayer RAW for HDR AI");
        }
        if (!report(ai::Phase::Loading, 1, 1)) throw ProcessingCancelled();
        state.prepareHDRBayer(path, identity, source, legacySonyCrop, report);
    });
#else
    (void)path;
    (void)fileBytes;
    (void)progress;
    unavailableHdrCameraAi();
#endif
}

std::string Pipeline::hdrCameraAiKey(const char* path) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    return withHdrCameraAi(runtime_.get(), [&](ai::AISession& ai) {
        return ai.hdrBayerKey(path, usesLegacySonyCrop());
    });
#else
    (void)path;
    unavailableHdrCameraAi();
#endif
}

RAWBayerOverride Pipeline::loadHdrCameraAi(const std::string& key, const RAWBayerSource& metadata) {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    return withHdrCameraAi(runtime_.get(), [&](ai::AISession& ai) {
        return ai.loadHDRBayer(key, metadata);
    });
#else
    (void)key;
    (void)metadata;
    unavailableHdrCameraAi();
#endif
}

} // namespace sony2fuji
