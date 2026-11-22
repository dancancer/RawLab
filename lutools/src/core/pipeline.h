#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/lens_correction.h"
#include "sony2fuji/processing_version.h"
#include "sony2fuji/raw_processor.h"
#include "core/hsl_probe.h"
#include "core/photo_atmosphere.h"
#include "core/photo_basic_controls_v3.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_effects.h"
#include "core/photo_geometry.h"
#include "core/photo_tone_controls.h"
#include "core/photo_tone_curve.h"
#include "core/pixel_buffer.h"
#include "core/preview_exposure.h"
#include "core/hdr_progress.h"
#include "core/processing_cancellation.h"
#include "core/processing_migration.h"
#include "core/render_params.h"
#include "core/wavelet_cache.h"
#include "core/wavelet_denoise.h"

#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace sony2fuji {

struct CanonicalSdrRecipe;
struct PipelineRuntimeState;

enum class RenderBackend : int32_t {
    Cpu = 0,
    Metal = 1,
    Gles = 2,
    D3d11 = 3
};

enum class UnsupportedReason : int32_t {
    None = 0,
    ForceGpu = 1
};

enum class GpuFallbackReason : int32_t {
    None = 0,
    BasicV3Controls = 1,
    Atmosphere = 2,
    Curves = 3,
    C5Wavelet = 4,
    DcpLook = 5,
    LutContract = 6,
    Geometry = 7,
    DisplayInput = 8,
    GpuDisabled = 9,
    NoAdapter = 10,
    Cooldown = 11,
    DeviceError = 12,
    FilterError = 13,
    UnsupportedCapability = 14
};

enum class RawExposureMode : int32_t {
    Scene = 0,
    Preview = 1,
    Sensor = 2
};

enum class LookFormat : int32_t {
    Unknown = 0,
    Cube = 1,
    Rlook = 2,
    Vlt = 3
};

enum class MigrationDisposition : int32_t {
    Unchanged = 0,
    Accepted = 1,
    Rejected = 2
};

enum class AiBackendPreference : int32_t {
    Cpu = 0,
    CoreML = 1,
    Auto = 2,
    DirectML = 3
};

struct AiDenoiseConfig {
    bool enabled = false;
    AiBackendPreference backend = AiBackendPreference::Auto;
    std::string modelDirectory;
    std::string cacheDirectory;
};

struct ProcessingMigrationResult {
    int32_t sourceVersion = 0;
    int32_t targetVersion = 3;
    MigrationDisposition disposition = MigrationDisposition::Unchanged;
    uint32_t evaluationCount = 0;
    MigrationParameters fitted{};
    MigrationQuality quality{};
};

struct RecipeWbRequest {
    std::string inputPath;
    ProcessingVersion processingVersion = ProcessingVersion::Legacy;
    X3fMode x3fMode = X3fMode::Legacy;
    RawExposureMode exposureMode = RawExposureMode::Scene;
    bool recipeActive = false;
    float recipeStrength = 1.0f;
    bool customWb = false;
    float temperature = 6500.0f;
    float tint = 0.0f;
};

struct RecipeWbResult {
    RenderWhiteBalanceMode wbMode = RenderWhiteBalanceMode::Camera;
    float temperature = 6500.0f;
    float tint = 0.0f;
    float cameraTemperature = 0.0f;
    float cameraTint = 0.0f;
    bool cameraCalibrated = false;
};

class Pipeline {
public:
    using AiProgressCallback = std::function<bool(int32_t phase, uint64_t completed, uint64_t total)>;

    Pipeline();
    ~Pipeline();
    Pipeline(const Pipeline&) = delete;
    Pipeline& operator=(const Pipeline&) = delete;

    // Look inspection (stateless)
    static RenderStatus validateLook(const char* path, LookFormat* format, uint32_t* formatVersion);
    static int32_t inspectLutColor(const char* path);

    // X3F availability & inspection (stateless)
    static bool x3fAvailable();
    static RenderStatus x3fDefaultMode(const char* inputPath, X3fMode& outMode);

    // AI availability & device discovery (stateless)
    static bool aiAvailable();
    static bool aiHardwareAvailable();
    static std::string aiDevicesJson();
    static bool hdrCameraAiAvailable();

    // Tone curve sampling (stateless)
    static RenderStatus sampleToneCurve(const ToneCurveConfig& config, const double* x, double* y, uint32_t count);

    // Atomic edit-state application (replaces all edit-state fields transactionally)
    RenderStatus applyParams(const char* recipeJson);
    RenderStatus applyParams(const CanonicalSdrRecipe& recipe);

    // Configuration setters & diagnostics
    void setCancellation(int32_t (*callback)(void*), void* context);
    ProcessingCancellation getCancellation() const noexcept { return cancellation_; }
    void setHdrProgress(void (*callback)(void*, uint32_t, uint32_t), void* context);
    HdrProgress getHdrProgress() const noexcept { return hdrProgress_; }

    void setGpuConfig(GpuMode mode);
    GpuMode gpuMode() const noexcept { return gpuConfig_.mode; }

    RenderStatus setProcessingVersion(ProcessingVersion version);
    ProcessingVersion processingVersion() const noexcept { return processingVersion_; }
    bool usesLegacySonyCrop() const noexcept { return sony2fuji::usesLegacySonyCrop(processingVersion_); }

    struct ViewportRoiConfig {
        bool enabled = false;
        double normX0 = 0.0;
        double normY0 = 0.0;
        double normX1 = 1.0;
        double normY1 = 1.0;
        uint32_t maxOutputLongEdge = 2048;
    };

    struct ViewportRoiResult {
        bool active = false;
        uint32_t nativeX0 = 0;
        uint32_t nativeY0 = 0;
        uint32_t nativeX1 = 0;
        uint32_t nativeY1 = 0;
        uint32_t fullNativeWidth = 0;
        uint32_t fullNativeHeight = 0;
    };

    void setInteractivePreview(bool enabled) noexcept { interactivePreview_ = enabled; }
    void setViewportPreview(bool enabled) noexcept { viewportPreview_ = enabled; }
    RenderStatus setViewportRoi(const ViewportRoiConfig& roi) noexcept;
    ViewportRoiResult viewportRoiResult() const noexcept { return viewportRoiResult_; }

    RenderBackend lastBackend() const noexcept { return lastBackend_; }
    void didRenderCpu() noexcept { lastBackend_ = RenderBackend::Cpu; }
    UnsupportedReason unsupportedReason() const noexcept { return unsupportedReason_; }
    GpuFallbackReason gpuFallbackReason() const noexcept { return gpuFallbackReason_; }
    const std::string& gpuError() const noexcept { return gpuErrorDetail_; }
    uint64_t rawDecodeCount() const noexcept { return rawDecodeCount_; }

    // Raw & processing controls
    void setRawExposureMode(RawExposureMode mode) noexcept { rawExposureMode_ = mode; }
    void setRawNoiseReduction(int32_t level) noexcept { rawNoiseReduction_ = level; }
    RenderStatus setChromaDenoise(int32_t mode);
    RenderStatus setWaveletDenoise(bool enabled, float luma, float chroma, float coarse);

    RenderStatus getRawNoiseReductionSupport(int32_t& supported) const;
    RenderStatus getRawExposure(float& baselineEv, float& metadataEv) const;
    RenderStatus getRawWhiteBalance(float& temperature, float& tint) const;
    RenderStatus getEffectiveRawWhiteBalance(float& temperature, float& tint) const;
    RenderStatus resolveRecipeWhiteBalance(const RecipeWbRequest& request, RecipeWbResult& result);

    RenderStatus setPhotoEffects(const PhotoEffectsOptions& options);
    RenderStatus setHsl(const HslOptions& options);
    RenderStatus setToneControls(const ToneControlsOptions& options);
    RenderStatus setAtmosphere(const AtmosphereOptions& options);
    RenderStatus setColorGrading(const ColorGradingOptions& options);
    RenderStatus setToneCurve(const ToneCurveConfig& config);
    RenderStatus setToneCurves(const ToneCurveConfig& master, const std::array<ToneCurveConfig, 3>& channels);

    // X3F per-pipeline state (pipeline_x3f.cpp)
    static bool isNormalX3f(const char* inputPath, X3fMode mode);
    RenderStatus setX3fMode(X3fMode mode);
    const std::string& x3fError() const noexcept { return x3fError_; }

    // Lens per-pipeline state & inspection (pipeline_lens.cpp)
    void ensureLensDatabase();
    std::shared_ptr<const LensCorrectionDatabase> lensDatabaseShared();
    RenderStatus setLensDatabase(const char* path);
    RenderStatus setLensCorrection(bool distortion, bool tca, bool autoCrop, bool vignetting, const char* profileId, size_t maxProfileIdBytes);
    const LensCorrectionReport& lensReport() const noexcept { return lensReport_; }
    RenderStatus inspectLensFile(const char* inputPath, LensCorrectionReport& report, std::vector<LensProfile>* outProfiles);
    RenderStatus inspectLensMetadata(const LensMetadata& metadata, LensCorrectionReport& report, std::vector<LensProfile>* outProfiles);
    void clearDisplayLensMetadata();
    void setDisplayLensMetadata(LensMetadata metadata, int orientation);

    // Geometry per-pipeline state (pipeline_geometry.cpp)
    RenderStatus setGeometry(const GeometryOptions& options);
    RenderStatus setPerspective(float horizontal, float vertical);
    RenderStatus getGeometrySize(uint32_t& width, uint32_t& height) const;
    void clearGeometrySize() noexcept { geometryWidth_ = geometryHeight_ = 0; }

    // AI per-pipeline state (pipeline_ai.cpp)
    bool aiEnabled() const noexcept;
    RenderStatus setAiDevice(const char* deviceId);
    std::string aiDiagnosticsJson() const;
    RenderStatus setAiDenoise(const AiDenoiseConfig& config);
    std::string aiError() const;
    std::string aiBackend() const;
    RenderStatus prepareAi(const RenderParams& params, const AiProgressCallback& progress);
    void prepareHdrCameraAi(const char* path, uint64_t fileBytes, const AiProgressCallback& progress);
    std::string hdrCameraAiKey(const char* path);
    RAWBayerOverride loadHdrCameraAi(const std::string& key, const RAWBayerSource& metadata);

    // Diagnostics for internal native benchmarks/tests
    WaveletCacheDiagnostics waveletCacheDiagnostics() const;
    PreviewExposureDiagnostics previewExposureDiagnostics() const;

    // Core processing entry points
    RenderStatus process(const RenderParams& params, OwnedPixelBuffer* outBuffer);
    RenderStatus previewLutCompatibility(const RenderParams& params, const char* configuration, OwnedPixelBuffer& outBuffer);
    RenderStatus createHslProbe(const RenderParams& params, uint64_t sourceRevision, uint64_t requestRevision, HslProbeData& outProbe);
    RenderStatus estimateAutoExposure(const RenderParams& params, float& outExposureEv);
    RenderStatus migrateProcessing(const RenderParams& params, ProcessingMigrationResult& outResult) const;

private:
    RenderStatus processImpl(
        const RenderParams& params,
        OwnedPixelBuffer* outBuffer,
        ImageData* preHsl = nullptr,
        std::shared_ptr<LUT3D> previewLut = nullptr,
        MigrationFrame* migrationFrame = nullptr
    );

    // pipeline_raw.cpp
    RAWProcessOptions rawWhiteBalanceOptions(const RenderParams& params) const;
    bool buildRawCacheWbKeys(
        const RenderParams& params,
        std::string& outBaseSourceKey,
        std::string& outFileKey,
        std::string& outWbBaseKey,
        std::string& outPreviewExposureKey
    );
    RenderStatus loadRawImage(
        const RenderParams& params,
        ImageData& image,
        ColorSpace* space,
        bool* isLinear,
        bool copyImage = true,
        bool applyAI = true,
        bool forceFullResolution = false
    );

    // pipeline_geometry.cpp
    RenderStatus finishGeometry(const RenderParams& params, ImageData& image, uint32_t nativeWidth, uint32_t nativeHeight);

    // pipeline_io.cpp
    static RenderStatus loadBufferImage(const RenderParams& params, ImageData& image, ColorSpace* space, bool* isLinear);
    static RenderStatus loadBufferImageROI(const RenderParams& params, const RoiSubRect& rect,
        ImageData& image, ColorSpace* space, bool* isLinear);
    static RenderStatus loadBufferImageDownsampled(const RenderParams& params, uint32_t maxLongEdge,
        ImageData& image, ColorSpace* space, bool* isLinear);
    static ImageData extractImageSubRect(const ImageData& source, const RoiSubRect& rect);
    RenderStatus processPreviewRoi(
        const RenderParams& params,
        OwnedPixelBuffer* outBuffer,
        std::shared_ptr<LUT3D> lut,
        std::shared_ptr<const DcpLook> dcp,
        bool displayInput,
        bool normalX3f,
        bool waveletActive,
        int chromaMode,
        bool basicV3,
        float exposure,
        const RGB& wb
    );
    static RenderStatus writeOutputFile(const RenderParams& params, const ImageData& image);
    static RenderStatus writeOutputBuffer(const RenderParams& params, const ImageData& image, OwnedPixelBuffer* outBuffer);
    RenderStatus finishOutput(
        const RenderParams& params,
        ImageData& image,
        OwnedPixelBuffer* outBuffer,
        uint32_t nativeWidth,
        uint32_t nativeHeight,
        MigrationFrame* migrationFrame = nullptr
    );

    // pipeline_ai.cpp
    RenderStatus recordAiError(RenderStatus status, const char* message) noexcept;
    void beginAiOperation(const char* name);

    void copyConfigurationFrom(const Pipeline& source);

    ProcessingCancellation cancellation_{};
    HdrProgress hdrProgress_{};
    GpuConfig gpuConfig_{};
    ImageData rawCache_{};
    std::pair<int, int> rawNativeSize_{};
    std::string rawKey_;
    std::string probedHeaderKey_;
    ProbeSizeResult probedHeaderResult_ = ProbeSizeResult::Unsupported;
    uint32_t probedHeaderWidth_ = 0;
    uint32_t probedHeaderHeight_ = 0;
    RawExposureMode rawExposureMode_ = RawExposureMode::Scene;
    int32_t rawNoiseReduction_ = 0;
    int32_t chromaDenoise_ = 0;
    ProcessingVersion processingVersion_ = ProcessingVersion::Legacy;
    X3fMode x3fMode_ = X3fMode::Legacy;
    bool rawDisplayReferred_ = false;
    std::string x3fError_;
    WaveletDenoiseOptions waveletDenoise_{false, 40, 46, 50, ProcessingVersion::Legacy};
    PhotoEffectsOptions photoEffects_{};
    HslOptions hsl_{};
    ToneControlsOptions toneControls_{};
    AtmosphereOptions atmosphere_{};
    DehazeAnalysis dehazeAnalysis_{};
    ColorGradingOptions colorGrading_{};
    ToneCurve toneCurve_{};
    std::array<ToneCurve, 3> channelCurves_{};
    GeometryOptions geometry_{};
    uint32_t geometryWidth_ = 0;
    uint32_t geometryHeight_ = 0;
    WaveletRenderCache waveletCache_{};
    LensCorrectionOptions lensCorrection_{};
    std::shared_ptr<LensCorrectionDatabase> lensDatabase_;
    bool lensDatabaseTried_ = false;
    uint64_t lensDatabaseRevision_ = 0;
    LensCorrectionReport lensReport_{};
    LensCorrectionReport rawLensReport_{};
    LensMetadata displayLensMetadata_{};
    bool hasDisplayLensMetadata_ = false;
    int displayLensOrientation_ = 1;
    bool rawNoiseReductionSupported_ = false;
    float baselineEv_ = 0.0f;
    float metadataEv_ = 0.0f;
    float asShotTemperature_ = 6500.0f;
    float asShotTint_ = 0.0f;
    bool calibratedWb_ = false;
    bool lastRenderRendered_ = false;
    bool lastRenderWasRaw_ = false;
    bool lastRenderWasNormalX3f_ = false;
    struct RecipeWbCacheEntry {
        bool valid = false;
        std::string fileKey;
        ProcessingVersion processingVersion = ProcessingVersion::Legacy;
        X3fMode x3fMode = X3fMode::Legacy;
        RawExposureMode exposureMode = RawExposureMode::Scene;
        bool calibrated = false;
        float temperature = 0.0f;
        float tint = 0.0f;
    };
    RecipeWbCacheEntry recipeWbCache_{};
    std::string previewExposureKey_;
    float previewCameraEv_ = 0.0f;
    PreviewExposureCache previewExposureCache_{};
    std::unique_ptr<RAWProcessor> rawProcessor_;
    std::string processorKey_;
    std::string rawCacheWbBaseKey_;
    bool rawCacheWbValid_ = false;
    std::array<float, 3> rawCacheAppliedWbMul_{1.0f, 1.0f, 1.0f};
    std::array<float, 3> rawCacheAsShotWbMul_{1.0f, 1.0f, 1.0f};
    float rawCacheCamToSrgb_[3][3]{};
    struct BasicToneFieldCacheEntry {
        std::string key;
        std::shared_ptr<const BasicToneV3Field> field;
    };
    BasicToneFieldCacheEntry basicToneFieldCache_{};
    bool interactivePreview_ = false;
    bool viewportPreview_ = false;
    ViewportRoiConfig viewportRoi_{};
    ViewportRoiResult viewportRoiResult_{};
    struct RoiGuideCache {
        std::string key;
        ImageData linearSrgb;
    };
    RoiGuideCache roiGuideCache_{};
    RenderBackend lastBackend_ = RenderBackend::Cpu;
    mutable UnsupportedReason unsupportedReason_ = UnsupportedReason::None;
    mutable GpuFallbackReason gpuFallbackReason_ = GpuFallbackReason::None;
    mutable std::string gpuErrorDetail_;
    uint64_t rawDecodeCount_ = 0;
    std::unique_ptr<PipelineRuntimeState> runtime_;
};

} // namespace sony2fuji
