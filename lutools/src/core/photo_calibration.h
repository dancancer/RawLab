#pragma once

#include "sony2fuji/common.h"
#include <array>

namespace sony2fuji {

struct CameraCalibrationOptions {
    float shadowTint = 0.0f;      // [-100, 100]
    float redHue = 0.0f;          // [-100, 100]
    float redSaturation = 0.0f;   // [-100, 100]
    float greenHue = 0.0f;        // [-100, 100]
    float greenSaturation = 0.0f; // [-100, 100]
    float blueHue = 0.0f;         // [-100, 100]
    float blueSaturation = 0.0f;  // [-100, 100]

    bool valid() const;
    bool active() const {
        return shadowTint != 0.0f || redHue != 0.0f || redSaturation != 0.0f ||
               greenHue != 0.0f || greenSaturation != 0.0f ||
               blueHue != 0.0f || blueSaturation != 0.0f;
    }

    bool operator==(const CameraCalibrationOptions& other) const {
        return shadowTint == other.shadowTint &&
               redHue == other.redHue && redSaturation == other.redSaturation &&
               greenHue == other.greenHue && greenSaturation == other.greenSaturation &&
               blueHue == other.blueHue && blueSaturation == other.blueSaturation;
    }
};

struct PreparedCameraCalibration {
    bool active = false;
    bool hasMatrix = false;
    // Row-major 3x3 linear sRGB calibration matrix normalized so each row sums to 1.0.
    std::array<float, 9> matrix{1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f};
    float shadowTint = 0.0f; // normalized [-1, 1]
};

PreparedCameraCalibration prepareCameraCalibration(const CameraCalibrationOptions& options);
RGB applyCameraCalibrationPixel(const RGB& linearSrgb, const PreparedCameraCalibration& prep);
void applyCameraCalibration(ImageData& image, const CameraCalibrationOptions& options);

} // namespace sony2fuji
