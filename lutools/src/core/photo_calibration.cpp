#include "photo_calibration.h"
#include "core/parallel_pixels.h"
#include <algorithm>
#include <array>
#include <cmath>

namespace sony2fuji {

namespace {

constexpr double kHueAngleScaleRad = 0.45; // +/-100 => +/-25.8 deg primary chroma rotation
constexpr double kPrimarySatScale = 0.45;  // +/-100 => +/-45% primary chroma amplitude
constexpr double kInvSqrt3 = 0.57735026918962576451;

struct Vec3d {
    double x;
    double y;
    double z;
};

Vec3d makeCalibratedPrimary(int channel, double hueNorm, double satNorm) {
    // Orthogonal chroma basis in the R+G+B=1 plane around neutral (1/3, 1/3, 1/3).
    static constexpr Vec3d kChromaBasis[3] = {
        { 2.0 / 3.0, -1.0 / 3.0, -1.0 / 3.0}, // R
        {-1.0 / 3.0,  2.0 / 3.0, -1.0 / 3.0}, // G
        {-1.0 / 3.0, -1.0 / 3.0,  2.0 / 3.0}, // B
    };
    static constexpr Vec3d kTangentBasis[3] = {
        { 0.0,        kInvSqrt3, -kInvSqrt3}, // R+: toward yellow (+G, -B)
        {-kInvSqrt3,  0.0,        kInvSqrt3}, // G+: toward aqua (+B, -R)
        { kInvSqrt3, -kInvSqrt3,  0.0      }, // B+: toward magenta (+R, -G)
    };
    const double angle = hueNorm * kHueAngleScaleRad;
    const double satScale = 1.0 + satNorm * kPrimarySatScale;
    const double c = std::cos(angle);
    const double s = std::sin(angle);
    const Vec3d& cb = kChromaBasis[channel];
    const Vec3d& tb = kTangentBasis[channel];
    constexpr double kNeutral = 1.0 / 3.0;
    return {
        kNeutral + satScale * (c * cb.x + s * tb.x),
        kNeutral + satScale * (c * cb.y + s * tb.y),
        kNeutral + satScale * (c * cb.z + s * tb.z),
    };
}

} // namespace

bool CameraCalibrationOptions::valid() const {
    for (float v : {shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation}) {
        if (!std::isfinite(v) || v < -100.0f || v > 100.0f) return false;
    }
    return true;
}

PreparedCameraCalibration prepareCameraCalibration(const CameraCalibrationOptions& options) {
    PreparedCameraCalibration prep;
    if (!options.valid() || !options.active()) return prep;

    prep.active = true;
    prep.shadowTint = std::clamp(options.shadowTint, -100.0f, 100.0f) / 100.0f;

    const bool hasPrimaries =
        options.redHue != 0.0f || options.redSaturation != 0.0f ||
        options.greenHue != 0.0f || options.greenSaturation != 0.0f ||
        options.blueHue != 0.0f || options.blueSaturation != 0.0f;
    if (!hasPrimaries) return prep;

    prep.hasMatrix = true;
    const Vec3d p0 = makeCalibratedPrimary(0, options.redHue / 100.0, options.redSaturation / 100.0);
    const Vec3d p1 = makeCalibratedPrimary(1, options.greenHue / 100.0, options.greenSaturation / 100.0);
    const Vec3d p2 = makeCalibratedPrimary(2, options.blueHue / 100.0, options.blueSaturation / 100.0);

    // Build column matrix P = [p0 | p1 | p2] and solve P * alpha = (1, 1, 1)^T so white preserves (1, 1, 1).
    double m[3][3] = {
        {p0.x, p1.x, p2.x},
        {p0.y, p1.y, p2.y},
        {p0.z, p1.z, p2.z},
    };
    const double det =
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);

    if (std::abs(det) > 1e-6) {
        const double invDet = 1.0 / det;
        double inv[3][3] = {
            {(m[1][1] * m[2][2] - m[1][2] * m[2][1]) * invDet,
             (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * invDet,
             (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * invDet},
            {(m[1][2] * m[2][0] - m[1][0] * m[2][2]) * invDet,
             (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * invDet,
             (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * invDet},
            {(m[1][0] * m[2][1] - m[1][1] * m[2][0]) * invDet,
             (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * invDet,
             (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * invDet},
        };
        const double alpha[3] = {
            inv[0][0] + inv[0][1] + inv[0][2],
            inv[1][0] + inv[1][1] + inv[1][2],
            inv[2][0] + inv[2][1] + inv[2][2],
        };
        for (int r = 0; r < 3; ++r) {
            for (int c = 0; c < 3; ++c) m[r][c] *= alpha[c];
        }
    }

    // Strictly enforce rowSum == 1.0 for every row so (v, v, v) maps to (v, v, v).
    for (int r = 0; r < 3; ++r) {
        const double rowSum = m[r][0] + m[r][1] + m[r][2];
        if (std::abs(rowSum) > 1e-6) {
            m[r][0] /= rowSum;
            m[r][1] /= rowSum;
            m[r][2] /= rowSum;
        }
        const float a = static_cast<float>(m[r][0]);
        const float b = static_cast<float>(m[r][1]);
        const float c = static_cast<float>(m[r][2]);
        // Absorb any float32 rounding residual into the diagonal entry? No — keeping normalized floats
        // and factoring p = gray + (p - gray) gives bit-exact neutral invariance AND smooth continuity.
        prep.matrix[r * 3 + 0] = a;
        prep.matrix[r * 3 + 1] = b;
        prep.matrix[r * 3 + 2] = c;
    }
    return prep;
}

RGB applyCameraCalibrationPixel(const RGB& linearSrgb, const PreparedCameraCalibration& prep) {
    if (!prep.active) return linearSrgb;

    RGB p = linearSrgb;
    if (prep.hasMatrix) {
        // Because every matrix row sums to 1.0, M * p == gray + M * (p - gray),
        // which evaluates to bit-exact (v, v, v) whenever R == G == B.
        const float gray = (p.r == p.g && p.g == p.b) ? p.r : (p.r + p.g + p.b) * (1.0f / 3.0f);
        const float dr = p.r - gray;
        const float dg = p.g - gray;
        const float db = p.b - gray;
        const auto& mat = prep.matrix;
        p.r = gray + mat[0] * dr + mat[1] * dg + mat[2] * db;
        p.g = gray + mat[3] * dr + mat[4] * dg + mat[5] * db;
        p.b = gray + mat[6] * dr + mat[7] * dg + mat[8] * db;
    }

    if (prep.shadowTint != 0.0f) {
        const float lum = std::max(0.0f, 0.2126f * p.r + 0.7152f * p.g + 0.0722f * p.b);
        const float t = std::clamp(1.0f - lum * 4.0f, 0.0f, 1.0f); // Smooth transition across Y in [0, 0.25]
        const float w = t * t * (3.0f - 2.0f * t);
        const float shift = prep.shadowTint * 0.25f * w;
        p.r *= (1.0f + 0.5f * shift);
        p.g *= (1.0f - shift);
        p.b *= (1.0f + 0.5f * shift);
    }
    return p;
}

void applyCameraCalibration(ImageData& image, const CameraCalibrationOptions& options) {
    const PreparedCameraCalibration prep = prepareCameraCalibration(options);
    if (!prep.active) return;

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            image.pixels[i] = applyCameraCalibrationPixel(image.pixels[i], prep);
        }
    });
}

} // namespace sony2fuji
