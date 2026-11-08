#pragma once

#include "core/photo_geometry.h"

namespace sony2fuji {

struct HDRDetailOptions {
    float sharpening = 0;
    float clarity = 0;
    float dehaze = 0;
    float denoise = 0;

    bool active() const { return sharpening != 0 || clarity != 0 || dehaze != 0 || denoise != 0; }
    bool valid() const;
    int halo(int width, int height) const;
};

constexpr int hdrDetailBandHeight = 128;

struct HDRDetailPlan {
    HDRDetailOptions settings;
    int width, height, halo;
    double veil, peak;
};

HDRDetailPlan planHDRDetail(int width, int height, const HDRDetailOptions& settings,
    double peak, const GeometryPixelReader& read);

// The input covers the center rows and the required halo on the full canvas.
// Input and output are separate; the output receives only the center rows.
void renderHDRDetailBand(const HDRDetailPlan& plan, const RGB* input, int inputTop, int inputRows,
    RGB* output, int outputTop, int outputRows);

} // namespace sony2fuji
