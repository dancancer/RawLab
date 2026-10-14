#pragma once

#include "sony2fuji/common.h"

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

    bool valid() const;
    bool active() const;
};

// The input is already oriented. Rotate clockwise, flip in that canvas,
// straighten clockwise within a centered same-aspect canvas, then crop.
// Crop edges are floor(start * size) and ceil(end * size); ends up to 1e-6
// beyond one are accepted for Float UI rounding and clamped to the canvas.
// Output resizing belongs to the caller. Identity is an exact bypass;
// failures preserve input.
ErrorCode applyGeometry(ImageData& image, const GeometryOptions& options);

} // namespace sony2fuji
