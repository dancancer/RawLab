#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/lut_parser.h"
#include <memory>

namespace sony2fuji {

enum class GpuMode {
    Off = 0,
    Auto = 1,
    Force = 2
};

struct GpuConfig {
    GpuMode mode = GpuMode::Off;
};

GpuConfig defaultGpuConfig();

// 对 image 就地应用 LUT。GPU 失败语义：Auto 始终回退 CPU 且不会重复套 LUT
// （已提交的瓦片保留，仅补齐未提交尾部）；Force 返回 ProcessingError 时，
// 未提交任何瓦片则像素逐位原样，第 2 块起失败则此前已提交的整瓦片保留 LUT 结果。
ErrorCode applyLUTWithConfig(
    const std::shared_ptr<LUT3D>& lut,
    ImageData& image,
    const GpuConfig& config
);

}
