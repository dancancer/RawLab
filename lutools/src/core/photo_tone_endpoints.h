#pragma once

#include "sony2fuji/common.h"

namespace sony2fuji {

// 内部 CPU 参考；调用方先验证配置并提供有限的显示编码 RGB。
// 这不是 sensor black/white，也尚未接入 session 或客户端。
struct ToneEndpointOptions {
    float blackPoint = 0;
    float whitePoint = 0;
    bool valid() const;
    bool active() const;
};

RGB applyToneEndpoints(const RGB& pixel, const ToneEndpointOptions& options);
void applyToneEndpoints(ImageData& image, const ToneEndpointOptions& options);

} // namespace sony2fuji
