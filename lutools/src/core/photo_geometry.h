#pragma once

#include "sony2fuji/common.h"
#include <functional>
#include <utility>

namespace sony2fuji {

struct GeometryOptions {
    float crop_x = 0;
    float crop_y = 0;
    float crop_width = 1;
    float crop_height = 1;
    int quarter_turns = 0;
    bool flip_horizontal = false;
    bool flip_vertical = false;
    float straighten_degrees = 0;
    float perspective_horizontal = 0;
    float perspective_vertical = 0;

    bool valid() const;
    bool active() const;
};

// The input is already oriented. Rotate clockwise, flip in that canvas,
// apply centered perspective, straighten clockwise within an inscribed canvas,
// then crop. Perspective values are normalized -1..1.
// Crop edges are floor(start * size) and ceil(end * size); ends up to 1e-6
// beyond one are accepted for Float UI rounding and clamped to the canvas.
// Output resizing belongs to the caller. Identity is an exact bypass;
// failures preserve input.
ErrorCode applyGeometry(ImageData& image, const GeometryOptions& options);

// 分块存储按全局输出坐标取样；读取器提供已定向的原始画布像素。
// 整数旋转/翻转/裁切保留原始 float，透视/拉直沿用整图的单次双线性插值。
using GeometryPixelReader = std::function<RGB(int, int)>;
using GeometryPixelSampler = std::function<RGB(int, int, const GeometryPixelReader&)>;
GeometryPixelSampler makeGeometrySampler(int width, int height, const GeometryOptions& options);

/* 只计算画布，使用与像素变换相同的取整；无效参数返回零尺寸。 */
std::pair<int, int> geometryOutputSize(int width, int height, const GeometryOptions& options);
std::pair<int, int> geometryViewportSourceSize(int width, int height,
    const GeometryOptions& options, int target_width, int target_height);

} // namespace sony2fuji
