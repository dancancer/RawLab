#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <functional>
#include <vector>

namespace sony2fuji {

// exposure, contrast, highlights, shadows, saturation, black, white, vibrance, clarity, dehaze.
using MigrationParameters = std::array<float, 10>;

struct MigrationQuality {
    float rgbRMSE = 0;
    float p99Error = 0;
    float worstTileRMSE = 0;
    float detailRMSE = 0;
    bool accepted() const;
};

struct MigrationFrame {
    int width = 0, height = 0;
    int sourceWidth = 0, sourceHeight = 0;
    std::vector<RGB> overview;
    // 拟合阶段采集网格中心及右、下邻居；最终验收另检查所有像素。
    std::vector<RGB> detail;
    bool retainNativePixels = false;
    // 最终验收保留量化到 16 bit 的完整显示像素，每通道误差不超过 1/65535。
    std::vector<uint16_t> nativePixels;
    const MigrationFrame* validationReference = nullptr;
    MigrationQuality nativeQuality;
};

bool validMigrationParameters(const MigrationParameters& values);
MigrationFrame captureMigrationFrame(const ImageData& image, bool retainNativePixels = false,
    const MigrationFrame* validationReference = nullptr);
MigrationQuality migrationQuality(const MigrationFrame& reference, const MigrationFrame& candidate);
MigrationParameters fitMigrationParameters(const MigrationParameters& initial, const MigrationFrame& reference,
    const std::function<MigrationFrame(const MigrationParameters&)>& render);

} // namespace sony2fuji
