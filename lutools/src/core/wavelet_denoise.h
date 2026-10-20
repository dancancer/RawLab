#pragma once
#include "sony2fuji/common.h"
#include "sony2fuji/gpu/lut_gpu.h"
#include "sony2fuji/processing_version.h"
#include <memory>
#include <string>

namespace sony2fuji {

struct WaveletDenoiseOptions {
    bool enabled = false;
    float luma = 40, chroma = 46, coarse = 50;
    ProcessingVersion processingVersion = ProcessingVersion::SwtV2;
    bool active() const { return enabled && (luma > 0 || chroma > 0); }
    bool operator==(const WaveletDenoiseOptions& other) const {
        return enabled == other.enabled && luma == other.luma && chroma == other.chroma && coarse == other.coarse &&
            processingVersion == other.processingVersion;
    }
};

enum class WaveletDenoiseOutcome {
    NotRun, Disabled, ZeroStrength, InvalidOptions, InvalidImage, UnsupportedBuild,
    SmallImage, LowNoise, InsufficientSamples, Applied, GpuFailure, ProcessingFailure
};

const char* waveletDenoiseOutcomeName(WaveletDenoiseOutcome outcome);

struct WaveletNoiseEstimateDiagnostics {
    int candidateTiles = 0;
    int rejectedSmall = 0, rejectedStructure = 0, rejectedLowNoise = 0, rejectedPeriodic = 0;
    bool fitAvailable = false;
    float sampleMeanMin[3] = {}, sampleMeanMax[3] = {};
    double relativeFitRmse[3] = {};
    double sampleVarianceMedian[3] = {}, fitRmse[3] = {};
    double relativeFitMedianAbsResidual[3] = {}, fitTopDecileErrorFraction[3] = {};
    bool constantVarianceFallback[3] = {};
};

struct WaveletDenoiseDiagnostics {
    WaveletDenoiseOutcome outcome = WaveletDenoiseOutcome::NotRun;
    WaveletNoiseEstimateDiagnostics estimate;
    int flatTiles = 0;
    bool applied = false;
    bool gpuUsed = false;
    bool analysisReused = false;
    bool coarseAnalysisReused = false;
    float a[3] = {}, b[3] = {};
};

class WaveletDenoiseAnalysisCache {
    struct Impl;
    std::unique_ptr<Impl> state;
    friend ErrorCode applyWaveletDenoise(ImageData&, const WaveletDenoiseOptions&,
        WaveletDenoiseDiagnostics*, GpuMode, WaveletDenoiseAnalysisCache*, const std::string&,
        const ImageData*, ColorSpace);
public:
    WaveletDenoiseAnalysisCache();
    ~WaveletDenoiseAnalysisCache();
    WaveletDenoiseAnalysisCache(WaveletDenoiseAnalysisCache&&) noexcept;
    WaveletDenoiseAnalysisCache& operator=(WaveletDenoiseAnalysisCache&&) noexcept;
    void clear();
};

bool waveletDenoiseAvailable();
bool validWaveletDenoiseOptions(const WaveletDenoiseOptions& options);
// immutableSource 必须是完整且不变的输入，image 为它按 sourceSpace 转换到 sRGB 的工作副本。
ErrorCode applyWaveletDenoise(ImageData& image, const WaveletDenoiseOptions& options,
                            WaveletDenoiseDiagnostics* diagnostics = nullptr, GpuMode gpuMode = GpuMode::Off,
                            WaveletDenoiseAnalysisCache* analysis = nullptr, const std::string& sourceKey = {},
                            const ImageData* immutableSource = nullptr, ColorSpace sourceSpace = ColorSpace::sRGB);

} // namespace sony2fuji
