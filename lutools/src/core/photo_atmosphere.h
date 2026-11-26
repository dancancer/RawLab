#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/processing_version.h"
#include "photo_geometry.h"
#include <cstdint>

namespace sony2fuji {

struct AtmosphereOptions {
    float clarity = 0;
    float dehaze = 0;
    float texture = 0;
    bool valid() const;
    bool active() const { return clarity != 0 || dehaze != 0 || texture != 0; }
};

// 完整源尺寸固定分析尺度；内容签名和工作尺寸区分视口近似与完整源分析。
struct DehazeAnalysis {
    ProcessingVersion processingVersion = ProcessingVersion::Legacy;
    uint64_t fingerprint = 0;
    uint64_t builds = 0;
    int sourceWidth = 0, sourceHeight = 0;
    int workingWidth = 0, workingHeight = 0;
    int width = 0, height = 0;
    RGB airlight;
    std::vector<float> slope, intercept, variance;
};

struct ClarityField {
    ProcessingVersion version = ProcessingVersion::Legacy;
    int width = 0, height = 0;
    std::vector<float> medium, residual;
    bool empty() const { return width <= 0 || height <= 0 || residual.empty(); }
};

DehazeAnalysis buildDehazeAnalysis(const ImageData& image, int sourceWidth = 0, int sourceHeight = 0,
    ProcessingVersion version = ProcessingVersion::Legacy);
void applyDehazeWithAnalysis(ImageData& image, float amount, const DehazeAnalysis& state,
    const SubRectMap& roiMap = {});
ClarityField buildClarityField(const ImageData& image, int sourceWidth = 0, int sourceHeight = 0,
    ProcessingVersion version = ProcessingVersion::Legacy);
void applyClarityWithField(ImageData& image, float amount, const ClarityField& field,
    const SubRectMap& roiMap = {});

void applyDehaze(ImageData& image, float amount, DehazeAnalysis* cache = nullptr,
    int sourceWidth = 0, int sourceHeight = 0, ProcessingVersion version = ProcessingVersion::Legacy);
void applyClarity(ImageData& image, float amount, int sourceWidth = 0, int sourceHeight = 0,
    ProcessingVersion version = ProcessingVersion::Legacy);

} // namespace sony2fuji
