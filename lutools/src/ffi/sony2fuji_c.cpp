#include "ffi/session_internal.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include "core/hsl_probe.h"
#include "core/jpeg_mpf.h"
#include "core/render_params.h"

#include <algorithm>
#include <filesystem>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>

struct sony2fuji_session_slot {
    bool alive = true;
    bool in_use = false;
    std::unique_ptr<sony2fuji_session> session;
};

struct sony2fuji_hsl_probe {
    sony2fuji::HslProbeData data;
};

namespace {

struct SessionRegistry {
    std::mutex mutex;
    uint64_t next_token = 1;
    std::unordered_map<uintptr_t, std::shared_ptr<sony2fuji_session_slot>> slots;
};

SessionRegistry& sessionRegistry() {
    // 进程生命周期内常驻，避免与宿主线程析构顺序竞争。
    static auto* instance = new SessionRegistry();
    return *instance;
}

sony2fuji::ColorSpace toCoreColorSpace(sony2fuji_color_space space) noexcept {
    switch (space) {
        case SONY2FUJI_COLOR_SRGB: return sony2fuji::ColorSpace::sRGB;
        case SONY2FUJI_COLOR_FGAMUT: return sony2fuji::ColorSpace::FujiFilm_FGamut;
        case SONY2FUJI_COLOR_SONY_NATIVE: return sony2fuji::ColorSpace::SonyNative;
        case SONY2FUJI_COLOR_ACESCG: return sony2fuji::ColorSpace::ACEScg;
        case SONY2FUJI_COLOR_ADOBE_RGB: return sony2fuji::ColorSpace::AdobeRGB;
        default: return sony2fuji::ColorSpace::SonyNative;
    }
}

sony2fuji::GpuMode toCoreGpuMode(sony2fuji_gpu_mode mode) noexcept {
    switch (mode) {
        case SONY2FUJI_GPU_OFF: return sony2fuji::GpuMode::Off;
        case SONY2FUJI_GPU_AUTO: return sony2fuji::GpuMode::Auto;
        case SONY2FUJI_GPU_FORCE: return sony2fuji::GpuMode::Force;
        default: return sony2fuji::GpuMode::Auto;
    }
}

bool toCoreRenderParams(const sony2fuji_request* request, sony2fuji::RenderParams& out) {
    if (!request || request->version != SONY2FUJI_REQUEST_VERSION ||
        request->struct_size < sizeof(sony2fuji_request)) {
        return false;
    }
    out = {};
    out.inputType = static_cast<sony2fuji::RenderInputType>(request->input_type);
    out.inputPath = request->input_path ? request->input_path : "";
    out.inputPixels = request->input_pixels;
    out.inputWidth = request->input_width;
    out.inputHeight = request->input_height;
    out.inputPixelFormat = static_cast<sony2fuji::PixelBufferFormat>(request->input_pixel_format);
    out.inputColorSpace = toCoreColorSpace(request->input_color_space);
    out.inputIsLinear = request->input_is_linear != 0;
    out.wbMode = static_cast<sony2fuji::RenderWhiteBalanceMode>(request->wb_mode);
    out.temperature = request->temperature;
    out.tint = request->tint;
    std::copy(std::begin(request->wb_mul), std::end(request->wb_mul), out.wbMul.begin());
    out.exposureEV = request->exposure_ev;
    out.brightness = request->brightness;
    out.contrast = request->contrast;
    out.saturation = request->saturation;
    out.highlights = request->highlights;
    out.shadows = request->shadows;
    out.toneCurve = request->tone_curve;
    out.noiseReduction = request->noise_reduction;
    out.sharpening = request->sharpening;
    out.lutPath = request->lut_path ? request->lut_path : "";
    out.lutStrength = request->lut_strength;
    out.outputTarget = static_cast<sony2fuji::RenderOutputTarget>(request->output_target);
    out.outputFormat = static_cast<sony2fuji::RenderOutputFormat>(request->output_format);
    out.outputPath = request->output_path ? request->output_path : "";
    out.jpegQuality = request->jpeg_quality;
    out.sizeMode = static_cast<sony2fuji::RenderSizeMode>(request->size_mode);
    out.targetWidth = request->target_width;
    out.targetHeight = request->target_height;
    out.longEdge = request->long_edge;
    out.shortEdge = request->short_edge;
    out.previewLongEdge = request->preview_long_edge;
    out.intent = static_cast<sony2fuji::RenderIntent>(request->intent);
    return true;
}

bool toCoreToneCurveConfig(const sony2fuji_tone_curve_config& src, sony2fuji::ToneCurveConfig& out) noexcept {
    if (src.version != SONY2FUJI_TONE_CURVE_CONFIG_VERSION || src.struct_size != sizeof(src)) {
        return false;
    }
    static_assert(SONY2FUJI_TONE_CURVE_MAX_POINTS == sony2fuji::kToneCurveMaxPoints, "Tone curve capacity mismatch");
    out.mode = static_cast<sony2fuji::ToneCurveMode>(src.mode);
    out.count = src.count;
    for (uint32_t i = 0; i < sony2fuji::kToneCurveMaxPoints; ++i) {
        out.points[i] = {src.points[i].x, src.points[i].y};
    }
    return true;
}

} // namespace

// ============================================================================
// Internal Session Lease & HDR Bridge
// ============================================================================

bool SessionLease::acquire(const sony2fuji_session* handle, SessionLease& out, bool allowNull) {
    if (!handle) {
        out.session_ = nullptr;
        out.slot_.reset();
        return allowNull;
    }
    auto& registry = sessionRegistry();
    std::lock_guard<std::mutex> lock(registry.mutex);
    const auto it = registry.slots.find(reinterpret_cast<uintptr_t>(handle));
    if (it == registry.slots.end()) return false;
    const auto& slot = it->second;
    if (!slot || !slot->alive || slot->in_use || !slot->session) return false;
    slot->in_use = true;
    out.slot_ = slot;
    out.session_ = slot->session.get();
    return true;
}

SessionLease::~SessionLease() {
    if (slot_) {
        std::lock_guard<std::mutex> lock(sessionRegistry().mutex);
        slot_->in_use = false;
    }
}

bool hdrSessionForcesGPU(const SessionLease& session) {
    const auto* raw = session.constRaw();
    return raw && raw->pipeline.gpuMode() == sony2fuji::GpuMode::Force;
}

bool hdrSessionUsesLegacySonyCrop(const SessionLease& session) {
    const auto* raw = session.constRaw();
    return raw ? raw->pipeline.usesLegacySonyCrop() : true;
}

void hdrSessionDidRenderCPU(const SessionLease& session) {
    if (auto* raw = session.raw()) raw->pipeline.didRenderCpu();
}

sony2fuji::ProcessingCancellation hdrSessionCancellation(const SessionLease& session) {
    const auto* raw = session.constRaw();
    return raw ? raw->pipeline.getCancellation() : sony2fuji::ProcessingCancellation{};
}

sony2fuji::HdrProgress hdrSessionProgress(const SessionLease& session) {
    const auto* raw = session.constRaw();
    return raw ? raw->pipeline.getHdrProgress() : sony2fuji::HdrProgress{};
}

std::shared_ptr<const sony2fuji::LensCorrectionDatabase> hdrSessionLensDatabase(const SessionLease& lease) {
    auto* raw = lease.raw();
    return raw ? raw->pipeline.lensDatabaseShared() : sony2fuji::LensCorrectionDatabase::load();
}

void hdrSessionPrepareCameraAI(
    const SessionLease& lease, const char* path, uint64_t fileBytes,
    sony2fuji_ai_progress_callback progress, void* context
) {
    sony2fuji::Pipeline::AiProgressCallback cb;
    if (progress) {
        cb = [progress, context](int32_t phase, uint64_t done, uint64_t total) {
            return progress(context, phase, done, total) != 0;
        };
    }
    if (auto* raw = lease.raw()) {
        raw->pipeline.prepareHdrCameraAi(path, fileBytes, cb);
        return;
    }
    sony2fuji::Pipeline dummy;
    dummy.prepareHdrCameraAi(path, fileBytes, cb);
}

std::string hdrSessionCameraAIKey(const SessionLease& lease, const char* path) {
    if (auto* raw = lease.raw()) return raw->pipeline.hdrCameraAiKey(path);
    sony2fuji::Pipeline dummy;
    return dummy.hdrCameraAiKey(path);
}

sony2fuji::RAWBayerOverride hdrSessionLoadCameraAI(
    const SessionLease& lease, const std::string& key, const sony2fuji::RAWBayerSource& metadata
) {
    if (auto* raw = lease.raw()) return raw->pipeline.loadHdrCameraAi(key, metadata);
    sony2fuji::Pipeline dummy;
    return dummy.loadHdrCameraAi(key, metadata);
}

sony2fuji_hsl_probe* makeHDRHslProbe(
    sony2fuji::ImageData image, uint64_t sourceRevision, uint64_t requestRevision, bool preview
) {
    const auto quality = preview ? sony2fuji::HslProbeQuality::PreviewCpu
                                 : sony2fuji::HslProbeQuality::ExactCpu;
    return new sony2fuji_hsl_probe{{std::move(image), sourceRevision, requestRevision, quality, true}};
}

namespace sony2fuji {
WaveletCacheDiagnostics waveletCacheDiagnostics(const sony2fuji_session* handle) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return {};
    return lease.constRaw()->pipeline.waveletCacheDiagnostics();
}

PreviewExposureDiagnostics previewExposureDiagnostics(const sony2fuji_session* handle) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return {};
    return lease.constRaw()->pipeline.previewExposureDiagnostics();
}
} // namespace sony2fuji

// ============================================================================
// Session & Processing C API
// ============================================================================

int32_t sony2fuji_hdr_camera_ai_available(void) {
    return sony2fuji::Pipeline::hdrCameraAiAvailable() ? 1 : 0;
}

sony2fuji_status sony2fuji_session_create(sony2fuji_session** out_session) {
    if (!out_session) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        auto session = std::make_unique<sony2fuji_session>();
        auto slot = std::make_shared<sony2fuji_session_slot>();
        slot->session = std::move(session);

        auto& registry = sessionRegistry();
        std::lock_guard<std::mutex> lock(registry.mutex);
        uintptr_t handleValue = 0;
        do {
            handleValue = (static_cast<uintptr_t>(registry.next_token++) << 4) + 0x100000ULL;
        } while (handleValue == 0 || registry.slots.count(handleValue) != 0);
        registry.slots.emplace(handleValue, std::move(slot));
        *out_session = reinterpret_cast<sony2fuji_session*>(handleValue);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        *out_session = nullptr;
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        *out_session = nullptr;
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_session_destroy(sony2fuji_session* handle) {
    if (!handle) return SONY2FUJI_STATUS_OK;
    std::shared_ptr<sony2fuji_session_slot> removed;
    {
        auto& registry = sessionRegistry();
        std::lock_guard<std::mutex> lock(registry.mutex);
        const auto it = registry.slots.find(reinterpret_cast<uintptr_t>(handle));
        if (it == registry.slots.end()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        const auto& slot = it->second;
        if (!slot || !slot->alive || slot->in_use) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        slot->alive = false;
        removed = std::move(it->second);
        registry.slots.erase(it);
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_apply_params(sony2fuji_session* handle, const char* recipe_json) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !recipe_json || !*recipe_json) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.applyParams(recipe_json));
}

sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* handle, int32_t enabled) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || (enabled != 0 && enabled != 1)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    lease.raw()->pipeline.setInteractivePreview(enabled != 0);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_viewport_preview(sony2fuji_session* handle, int32_t enabled) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || (enabled != 0 && enabled != 1)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    lease.raw()->pipeline.setViewportPreview(enabled != 0);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_render_backend sony2fuji_session_get_last_backend(const sony2fuji_session* handle) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_BACKEND_CPU;
    return static_cast<sony2fuji_render_backend>(lease.constRaw()->pipeline.lastBackend());
}

sony2fuji_unsupported_reason sony2fuji_session_get_unsupported_reason(const sony2fuji_session* handle) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_UNSUPPORTED_NONE;
    return static_cast<sony2fuji_unsupported_reason>(lease.constRaw()->pipeline.unsupportedReason());
}

sony2fuji_gpu_fallback_reason sony2fuji_session_get_gpu_fallback_reason(const sony2fuji_session* handle) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_GPU_FALLBACK_NONE;
    return static_cast<sony2fuji_gpu_fallback_reason>(lease.constRaw()->pipeline.gpuFallbackReason());
}

const char* sony2fuji_session_get_gpu_error(const sony2fuji_session* handle) {
    thread_local std::string snapshot;
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return "";
    try {
        snapshot = lease.constRaw()->pipeline.gpuError();
        return snapshot.c_str();
    } catch (...) { return ""; }
}

uint64_t sony2fuji_session_get_raw_decode_count(const sony2fuji_session* handle) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return 0;
    return lease.constRaw()->pipeline.rawDecodeCount();
}

sony2fuji_status sony2fuji_session_set_gpu_config(sony2fuji_session* handle, const sony2fuji_gpu_config* config) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_GPU_CONFIG_VERSION || config->struct_size < sizeof(sony2fuji_gpu_config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        lease.raw()->pipeline.setGpuConfig(toCoreGpuMode(config->mode));
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_status sony2fuji_session_set_processing_version(sony2fuji_session* handle, sony2fuji_processing_version version) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.raw()->pipeline.setProcessingVersion(static_cast<sony2fuji::ProcessingVersion>(version)));
}

int32_t sony2fuji_x3f_available(void) {
    return sony2fuji::Pipeline::x3fAvailable() ? 1 : 0;
}

sony2fuji_status sony2fuji_x3f_default_mode(const char* input_path, sony2fuji_x3f_mode* mode) {
    if (!mode) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji::X3fMode coreMode = sony2fuji::X3fMode::Legacy;
    const auto status = sony2fuji::Pipeline::x3fDefaultMode(input_path, coreMode);
    if (status == sony2fuji::RenderStatus::Ok) *mode = static_cast<sony2fuji_x3f_mode>(coreMode);
    return toFfiStatus(status);
}

int32_t sony2fuji_is_normal_x3f(const char* input_path, sony2fuji_x3f_mode mode) {
    if (mode != SONY2FUJI_X3F_LEGACY && mode != SONY2FUJI_X3F_NORMAL) return 0;
    return sony2fuji::Pipeline::isNormalX3f(input_path, static_cast<sony2fuji::X3fMode>(mode)) ? 1 : 0;
}

int32_t sony2fuji_inspect_sdr_jpeg_mpf(const char* path) {
    if (!path || !*path) return -1;
    try {
        return sony2fuji::inspectSdrJpegMpf(std::filesystem::u8path(path));
    } catch (...) {
        return -1;
    }
}

sony2fuji_status sony2fuji_session_set_x3f_mode(sony2fuji_session* handle, sony2fuji_x3f_mode mode) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || (mode != SONY2FUJI_X3F_LEGACY && mode != SONY2FUJI_X3F_NORMAL)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setX3fMode(static_cast<sony2fuji::X3fMode>(mode)));
}

const char* sony2fuji_session_x3f_error(const sony2fuji_session* handle) {
    thread_local std::string snapshot;
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return "Invalid session";
    try {
        snapshot = lease.constRaw()->pipeline.x3fError();
        return snapshot.c_str();
    } catch (...) { return "Invalid session"; }
}

sony2fuji_status sony2fuji_session_set_raw_exposure_mode(sony2fuji_session* handle, sony2fuji_raw_exposure_mode mode) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || mode < SONY2FUJI_EXPOSURE_SCENE || mode > SONY2FUJI_EXPOSURE_SENSOR) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    lease.raw()->pipeline.setRawExposureMode(static_cast<sony2fuji::RawExposureMode>(mode));
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_raw_noise_reduction(sony2fuji_session* handle, int32_t level) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || level < 0 || level > 2) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    lease.raw()->pipeline.setRawNoiseReduction(level);
    return SONY2FUJI_STATUS_OK;
}

int32_t sony2fuji_ai_available(void) { return sony2fuji::Pipeline::aiAvailable() ? 1 : 0; }
int32_t sony2fuji_ai_hardware_available(void) { return sony2fuji::Pipeline::aiHardwareAvailable() ? 1 : 0; }

const char* sony2fuji_ai_get_devices(void) {
    thread_local std::string result;
    try {
        result = sony2fuji::Pipeline::aiDevicesJson();
        return result.c_str();
    } catch (...) {
        return "{\"version\":1,\"devices\":[],\"recommended_id\":\"\",\"error\":\"Device enumeration failed\"}";
    }
}

sony2fuji_status sony2fuji_session_set_ai_device(sony2fuji_session* handle, const char* device_id) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.raw()->pipeline.setAiDevice(device_id));
}

const char* sony2fuji_session_get_ai_diagnostics(const sony2fuji_session* handle) {
    thread_local std::string snapshot;
    SessionLease lease;
    try {
        if (SessionLease::acquire(handle, lease)) {
            snapshot = lease.constRaw()->pipeline.aiDiagnosticsJson();
            return snapshot.c_str();
        }
    } catch (...) { return "{\"version\":1,\"error\":\"Diagnostic snapshot unavailable\"}"; }
    return "{\"version\":1,\"logs\":[]}";
}

sony2fuji_status sony2fuji_session_set_ai_denoise(sony2fuji_session* handle, const sony2fuji_ai_denoise_config* config) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_AI_DENOISE_CONFIG_VERSION || config->struct_size < sizeof(*config) ||
        (config->enabled != 0 && config->enabled != 1) ||
        config->backend < SONY2FUJI_AI_CPU || config->backend > SONY2FUJI_AI_DIRECTML ||
        (config->enabled && (!config->model_directory || !*config->model_directory || !config->cache_directory || !*config->cache_directory))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::AiDenoiseConfig coreConfig{
            config->enabled != 0,
            static_cast<sony2fuji::AiBackendPreference>(config->backend),
            config->model_directory ? config->model_directory : "",
            config->cache_directory ? config->cache_directory : ""
        };
        return toFfiStatus(lease.raw()->pipeline.setAiDenoise(coreConfig));
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

const char* sony2fuji_session_get_ai_error(const sony2fuji_session* handle) {
    thread_local std::string snapshot;
    SessionLease lease;
    try {
        if (SessionLease::acquire(handle, lease)) {
            snapshot = lease.constRaw()->pipeline.aiError();
            return snapshot.c_str();
        }
    } catch (...) { return ""; }
    return "";
}

const char* sony2fuji_session_get_ai_backend(const sony2fuji_session* handle) {
    thread_local std::string snapshot;
    SessionLease lease;
    try {
        if (SessionLease::acquire(handle, lease)) {
            snapshot = lease.constRaw()->pipeline.aiBackend();
            return snapshot.c_str();
        }
    } catch (...) { return ""; }
    return "";
}

sony2fuji_status sony2fuji_session_prepare_ai(
    sony2fuji_session* handle, const sony2fuji_request* request,
    sony2fuji_ai_progress_callback progress, void* context
) {
    SessionLease lease;
    sony2fuji::RenderParams params;
    if (!SessionLease::acquire(handle, lease) || !toCoreRenderParams(request, params)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        sony2fuji::Pipeline::AiProgressCallback cb;
        if (progress) cb = [progress, context](int32_t phase, uint64_t done, uint64_t total) { return progress(context, phase, done, total) != 0; };
        return toFfiStatus(lease.raw()->pipeline.prepareAi(params, cb));
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_status sony2fuji_session_set_chroma_denoise(sony2fuji_session* handle, int32_t mode) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.raw()->pipeline.setChromaDenoise(mode));
}

sony2fuji_status sony2fuji_session_set_wavelet_denoise(sony2fuji_session* handle, const sony2fuji_wavelet_denoise_config* config) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION || config->struct_size < sizeof(*config) ||
        (config->enabled != 0 && config->enabled != 1)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setWaveletDenoise(config->enabled != 0, config->luma, config->chroma, config->coarse));
}

sony2fuji_status sony2fuji_session_get_raw_noise_reduction_support(const sony2fuji_session* handle, int32_t* supported) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !supported) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.constRaw()->pipeline.getRawNoiseReductionSupport(*supported));
}

sony2fuji_status sony2fuji_session_get_raw_exposure(const sony2fuji_session* handle, float* baseline_ev, float* metadata_ev) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !baseline_ev || !metadata_ev) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.constRaw()->pipeline.getRawExposure(*baseline_ev, *metadata_ev));
}

sony2fuji_status sony2fuji_session_get_raw_white_balance(const sony2fuji_session* handle, float* temperature, float* tint) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !temperature || !tint) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.constRaw()->pipeline.getRawWhiteBalance(*temperature, *tint));
}

sony2fuji_status sony2fuji_session_get_effective_raw_white_balance(
    const sony2fuji_session* handle, float* temperature, float* tint
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !temperature || !tint) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.constRaw()->pipeline.getEffectiveRawWhiteBalance(*temperature, *tint));
}

sony2fuji_status sony2fuji_session_resolve_recipe_wb(
    sony2fuji_session* handle,
    const sony2fuji_recipe_wb_request* request,
    sony2fuji_recipe_wb_result* result
) {
    if (result) {
        *result = {};
        result->version = SONY2FUJI_RECIPE_WB_RESULT_VERSION;
        result->struct_size = sizeof(*result);
    }
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !request || !result ||
        request->version != SONY2FUJI_RECIPE_WB_REQUEST_VERSION ||
        request->struct_size != sizeof(*request)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji::RecipeWbRequest coreRequest;
    coreRequest.inputPath = request->input_path ? request->input_path : "";
    coreRequest.processingVersion = static_cast<sony2fuji::ProcessingVersion>(request->processing_version);
    coreRequest.x3fMode = static_cast<sony2fuji::X3fMode>(request->x3f_mode);
    coreRequest.exposureMode = static_cast<sony2fuji::RawExposureMode>(request->exposure_mode);
    coreRequest.recipeActive = request->recipe_active != 0;
    coreRequest.recipeStrength = request->recipe_strength;
    coreRequest.customWb = request->custom_wb != 0;
    coreRequest.temperature = request->temperature;
    coreRequest.tint = request->tint;

    sony2fuji::RecipeWbResult coreResult;
    const auto status = lease.raw()->pipeline.resolveRecipeWhiteBalance(coreRequest, coreResult);
    result->version = SONY2FUJI_RECIPE_WB_RESULT_VERSION;
    result->struct_size = sizeof(*result);
    result->wb_mode = coreResult.wbMode == sony2fuji::RenderWhiteBalanceMode::Temperature
        ? SONY2FUJI_WB_TEMPERATURE
        : SONY2FUJI_WB_CAMERA;
    result->temperature = coreResult.temperature;
    result->tint = coreResult.tint;
    result->camera_temperature = coreResult.cameraTemperature;
    result->camera_tint = coreResult.cameraTint;
    result->camera_calibrated = coreResult.cameraCalibrated ? 1 : 0;
    return toFfiStatus(status);
}

sony2fuji_status sony2fuji_session_set_photo_effects(sony2fuji_session* handle, const sony2fuji_photo_effects_config* config) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION || config->struct_size != sizeof(*config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setPhotoEffects({
        config->vignette_amount, config->vignette_midpoint, config->vignette_roundness,
        config->vignette_feather, config->vignette_highlights,
        config->grain_amount, config->grain_size, config->grain_roughness
    }));
}

sony2fuji_status sony2fuji_session_set_hsl(sony2fuji_session* handle, const sony2fuji_hsl_config* config) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_HSL_CONFIG_VERSION || config->struct_size != sizeof(*config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji::HslOptions options;
    std::copy(std::begin(config->hue), std::end(config->hue), options.hue.begin());
    std::copy(std::begin(config->saturation), std::end(config->saturation), options.saturation.begin());
    std::copy(std::begin(config->lightness), std::end(config->lightness), options.lightness.begin());
    return toFfiStatus(lease.raw()->pipeline.setHsl(options));
}

sony2fuji_status sony2fuji_session_set_tone_controls(sony2fuji_session* handle, const sony2fuji_tone_controls_config* config) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION || config->struct_size != sizeof(*config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setToneControls({config->black_point, config->white_point, config->vibrance}));
}

sony2fuji_status sony2fuji_session_set_atmosphere(sony2fuji_session* handle, const sony2fuji_atmosphere_config* config) {
    static_assert(sizeof(sony2fuji_atmosphere_config) == 16, "Atmosphere C ABI layout");
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_ATMOSPHERE_CONFIG_VERSION || config->struct_size != sizeof(*config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setAtmosphere({config->clarity, config->dehaze}));
}

sony2fuji_status sony2fuji_session_set_color_grading(sony2fuji_session* handle, const sony2fuji_color_grading_config* config) {
    static_assert(sizeof(sony2fuji_color_grading_config) == 32, "Color grading C ABI layout");
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_COLOR_GRADING_CONFIG_VERSION || config->struct_size != sizeof(*config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji::ColorGradingOptions options;
    options.wheels = {
        sony2fuji::ColorGradingWheel{config->shadows_hue, config->shadows_saturation},
        sony2fuji::ColorGradingWheel{config->midtones_hue, config->midtones_saturation},
        sony2fuji::ColorGradingWheel{config->highlights_hue, config->highlights_saturation}
    };
    return toFfiStatus(lease.raw()->pipeline.setColorGrading(options));
}

sony2fuji_status sony2fuji_session_set_tone_curve(sony2fuji_session* handle, const sony2fuji_tone_curve_config* config) {
    static_assert(sizeof(sony2fuji_tone_curve_config) == 544, "Tone curve C ABI layout");
    SessionLease lease;
    sony2fuji::ToneCurveConfig coreConfig;
    if (!SessionLease::acquire(handle, lease) || !config || !toCoreToneCurveConfig(*config, coreConfig)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setToneCurve(coreConfig));
}

sony2fuji_status sony2fuji_session_set_tone_curves(sony2fuji_session* handle, const sony2fuji_tone_curve_set_config* config) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_TONE_CURVE_SET_CONFIG_VERSION || config->struct_size != sizeof(*config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji::ToneCurveConfig master;
    std::array<sony2fuji::ToneCurveConfig, 3> channels;
    if (!toCoreToneCurveConfig(config->curves[0], master) ||
        !toCoreToneCurveConfig(config->curves[1], channels[0]) ||
        !toCoreToneCurveConfig(config->curves[2], channels[1]) ||
        !toCoreToneCurveConfig(config->curves[3], channels[2])) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setToneCurves(master, channels));
}

sony2fuji_status sony2fuji_sample_tone_curve(const sony2fuji_tone_curve_config* config, const double* x, double* y, uint32_t count) {
    sony2fuji::ToneCurveConfig coreConfig;
    if (!config || !toCoreToneCurveConfig(*config, coreConfig)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(sony2fuji::Pipeline::sampleToneCurve(coreConfig, x, y, count));
}

sony2fuji_status sony2fuji_session_set_geometry(sony2fuji_session* handle, const sony2fuji_geometry_config* config) {
    static_assert(sizeof(sony2fuji_geometry_config) == 40, "Geometry C ABI layout");
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_GEOMETRY_CONFIG_VERSION || config->struct_size != sizeof(*config) ||
        config->flip_horizontal < 0 || config->flip_horizontal > 1 ||
        config->flip_vertical < 0 || config->flip_vertical > 1) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setGeometry({
        config->crop_x, config->crop_y, config->crop_width, config->crop_height,
        config->quarter_turns, config->flip_horizontal != 0, config->flip_vertical != 0,
        config->straighten_degrees, 0.0f, 0.0f
    }));
}

sony2fuji_status sony2fuji_session_set_perspective(sony2fuji_session* handle, const sony2fuji_perspective_config* config) {
    static_assert(sizeof(sony2fuji_perspective_config) == 16, "Perspective C ABI layout");
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_PERSPECTIVE_CONFIG_VERSION || config->struct_size != sizeof(*config)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setPerspective(config->horizontal, config->vertical));
}

sony2fuji_status sony2fuji_session_get_geometry_size(const sony2fuji_session* handle, uint32_t* width, uint32_t* height) {
    if (width) *width = 0;
    if (height) *height = 0;
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !width || !height) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.constRaw()->pipeline.getGeometrySize(*width, *height));
}

sony2fuji_status sony2fuji_session_estimate_auto_exposure(sony2fuji_session* handle, const sony2fuji_request* request, float* exposure_ev) {
    SessionLease lease;
    sony2fuji::RenderParams params;
    if (!SessionLease::acquire(handle, lease) || !exposure_ev || !toCoreRenderParams(request, params)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (request->input_type == SONY2FUJI_INPUT_BUFFER &&
        (request->input_color_space < SONY2FUJI_COLOR_SRGB || request->input_color_space > SONY2FUJI_COLOR_ADOBE_RGB)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.estimateAutoExposure(params, *exposure_ev));
}

sony2fuji_status sony2fuji_session_migrate_processing(
    const sony2fuji_session* handle, const sony2fuji_request* request, sony2fuji_processing_migration_result* result
) {
    if (result) *result = {};
    SessionLease lease;
    sony2fuji::RenderParams params;
    if (!SessionLease::acquire(handle, lease) || !result || !toCoreRenderParams(request, params)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::ProcessingMigrationResult coreResult;
        const auto status = lease.constRaw()->pipeline.migrateProcessing(params, coreResult);
        if (status != sony2fuji::RenderStatus::Ok) return toFfiStatus(status);
        *result = {
            SONY2FUJI_PROCESSING_MIGRATION_VERSION, sizeof(*result),
            coreResult.sourceVersion, coreResult.targetVersion,
            static_cast<int32_t>(coreResult.disposition), coreResult.evaluationCount,
            coreResult.fitted[0], coreResult.fitted[1], coreResult.fitted[2], coreResult.fitted[3], coreResult.fitted[4],
            coreResult.fitted[5], coreResult.fitted[6], coreResult.fitted[7], coreResult.fitted[8], coreResult.fitted[9],
            coreResult.quality.rgbRMSE, coreResult.quality.p99Error,
            coreResult.quality.worstTileRMSE, coreResult.quality.detailRMSE
        };
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_status sony2fuji_session_set_cancellation_callback(
    sony2fuji_session* handle, sony2fuji_cancel_callback callback, void* context
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    lease.raw()->pipeline.setCancellation(callback, context);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_hdr_progress_callback(
    sony2fuji_session* handle, sony2fuji_hdr_progress_callback callback, void* context
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    lease.raw()->pipeline.setHdrProgress(callback, context);
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_process(sony2fuji_session* handle, const sony2fuji_request* request, sony2fuji_buffer* buffer) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    lease.raw()->pipeline.clearGeometrySize();
    sony2fuji::RenderParams params;
    if (!toCoreRenderParams(request, params)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        sony2fuji::OwnedPixelBuffer owned;
        const auto status = lease.raw()->pipeline.process(params, buffer ? &owned : nullptr);
        if (status != sony2fuji::RenderStatus::Ok) return toFfiStatus(status);
        if (buffer && params.outputTarget == sony2fuji::RenderOutputTarget::Buffer) *buffer = toFfiBuffer(owned);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_status sony2fuji_preview_lut_compatibility(
    sony2fuji_session* handle, const sony2fuji_request* request, const char* configuration, sony2fuji_buffer* buffer
) {
    if (!buffer) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji_release_buffer(buffer);
    SessionLease lease;
    sony2fuji::RenderParams params;
    if (!SessionLease::acquire(handle, lease) || !toCoreRenderParams(request, params)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        sony2fuji::OwnedPixelBuffer owned;
        const auto status = lease.raw()->pipeline.previewLutCompatibility(params, configuration, owned);
        if (status != sony2fuji::RenderStatus::Ok) return toFfiStatus(status);
        *buffer = toFfiBuffer(owned);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_status sony2fuji_session_create_hsl_probe(
    sony2fuji_session* handle, const sony2fuji_request* request,
    uint64_t source_revision, uint64_t request_revision, sony2fuji_hsl_probe** out_probe
) {
    if (out_probe) *out_probe = nullptr;
    SessionLease lease;
    sony2fuji::RenderParams params;
    if (!SessionLease::acquire(handle, lease) || !out_probe || !toCoreRenderParams(request, params)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        auto probe = std::make_unique<sony2fuji_hsl_probe>();
        const auto status = lease.raw()->pipeline.createHslProbe(params, source_revision, request_revision, probe->data);
        if (status != sony2fuji::RenderStatus::Ok) return toFfiStatus(status);
        *out_probe = probe.release();
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (...) { return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_status sony2fuji_hsl_probe_sample(
    const sony2fuji_hsl_probe* probe, const sony2fuji_hsl_probe_query* query, sony2fuji_hsl_probe_result* result
) {
    if (result) *result = {};
    if (!probe || !query || !result || query->version != SONY2FUJI_HSL_PROBE_VERSION || query->struct_size != sizeof(*query)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const auto sampled = sony2fuji::sampleHslProbe(
        probe->data, query->source_revision, query->request_revision, query->x, query->y);
    result->version = SONY2FUJI_HSL_PROBE_VERSION;
    result->struct_size = sizeof(*result);
    result->source_revision = sampled.sourceRevision;
    result->request_revision = sampled.requestRevision;
    result->width = sampled.width;
    result->height = sampled.height;
    result->availability = static_cast<sony2fuji_hsl_probe_availability>(sampled.availability);
    result->quality = static_cast<sony2fuji_hsl_probe_quality>(sampled.quality);
    std::copy(sampled.rgb.begin(), sampled.rgb.end(), result->rgb);
    std::copy(sampled.hsl.begin(), sampled.hsl.end(), result->hsl);
    std::copy(sampled.weights.begin(), sampled.weights.end(), result->weights);
    return SONY2FUJI_STATUS_OK;
}

void sony2fuji_hsl_probe_destroy(sony2fuji_hsl_probe* probe) { delete probe; }
