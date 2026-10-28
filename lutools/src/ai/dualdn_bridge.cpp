#include "dualdn_bridge.h"
#include <algorithm>
#include <cmath>
#include <deque>

namespace sony2fuji::ai {
namespace {
Matrix rowNormalized(Matrix matrix) {
    for (auto& row : matrix) {
        const float sum = row[0] + row[1] + row[2];
        if (!std::isfinite(sum) || std::abs(sum) < 1e-8f ||
            !std::all_of(row.begin(), row.end(), [](float x) { return std::isfinite(x); }))
            throw std::invalid_argument("invalid DualDn camera matrix");
        for (auto& value : row) value /= sum;
    }
    return matrix;
}

Matrix xyzToRgb() {
    return rowNormalized({{{3.2404542f,-1.5371385f,-.4985314f},
                           {-.969266f,1.8760108f,.041556f}, {.0556434f,-.2040259f,1.0572252f}}});
}

bool stableMatrix(const Matrix& input) {
    double m[3][3], norm = 0;
    for (int i = 0; i < 3; ++i) {
        double row = 0;
        for (int j = 0; j < 3; ++j) {
            if (!std::isfinite(input[i][j])) return false;
            m[i][j] = input[i][j]; row += std::abs(m[i][j]);
        }
        norm = std::max(norm,row);
    }
    const double det = m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1]) -
        m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0]) + m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);
    return std::abs(det) > 1e-6*norm*norm*norm;
}

void maximumLine(const std::vector<float>& input, std::vector<float>& output,
                 size_t offset, size_t stride, int count, int radius) {
    std::deque<int> indices;
    for (int right = 0; right < count + radius; ++right) {
        if (right < count) {
            while (!indices.empty() && input[offset + size_t(indices.back()) * stride] <= input[offset + size_t(right) * stride])
                indices.pop_back();
            indices.push_back(right);
        }
        while (!indices.empty() && indices.front() < right - 2 * radius) indices.pop_front();
        if (right >= radius) output[offset + size_t(right - radius) * stride] = input[offset + size_t(indices.front()) * stride];
    }
}
}

Matrix officialCameraToXYZ(const RAWBayerSource& source) {
    bool nonzero = true;
    for (const auto& row : source.cameraCalibration) for (float value : row)
        nonzero = nonzero && value != 0 && std::isfinite(value);
    // 与固定版本 utils/metadata.py 的两个分支一致；不替换为原生 rgb_cam。
    if (nonzero) return ColorConverter::invertMatrix(rowNormalized(source.cameraCalibration));
    return rowNormalized(ColorConverter::multiplyMatrices(ColorConverter::invertMatrix(xyzToRgb()), source.cameraToSrgb));
}

float inverseRec709(float value) {
    return value < .081f ? value / 4.5f : std::pow((value + .099f) / 1.099f, 1.f / .45f);
}

bool supportsDualDnBridge(const RAWBayerSource& source) {
    const auto& wb = source.whiteBalance;
    if (!std::all_of(wb.begin(),wb.end(),[](float x) { return std::isfinite(x) && x > 0; }) ||
        std::abs(wb[1]-wb[3]) > 1e-5f*std::max(wb[1],wb[3])) return false;
    bool calibrated = true;
    for (const auto& row : source.cameraCalibration) for (float x : row)
        calibrated = calibrated && x != 0 && std::isfinite(x);
    if (!stableMatrix(calibrated ? source.cameraCalibration : source.cameraToSrgb)) return false;
    try {
        const auto transform = ColorConverter::multiplyMatrices(xyzToRgb(),officialCameraToXYZ(source));
        if (!stableMatrix(transform)) return false;
        const auto matrix = ColorConverter::invertMatrix(transform);
        for (const auto& row : matrix) for (float x : row) if (!std::isfinite(x)) return false;
        return true;
    } catch (const std::invalid_argument&) { return false; }
    catch (const std::runtime_error&) { return false; }
}

Tensor rgbCameraCorrection(const Tensor& mosaic, const Tensor& noisy, const Tensor& skip, const Tensor& result,
                           const std::array<float, 4>& wb, const Matrix& cameraToXYZ) {
    validateTensor(mosaic); validateTensor(noisy); validateTensor(skip); validateTensor(result);
    if (mosaic.channels != 1 || skip.channels != 3 || result.channels != 3 ||
        noisy.channels != 1 || noisy.width != mosaic.width || noisy.height != mosaic.height ||
        skip.width != mosaic.width || skip.height != mosaic.height ||
        result.width != mosaic.width || result.height != mosaic.height ||
        !std::all_of(wb.begin(), wb.end(), [](float x) { return std::isfinite(x) && x > 0; }) ||
        std::abs(wb[1] - wb[3]) > 1e-5f * std::max(wb[1], wb[3]))
        throw std::invalid_argument("unsupported DualDn bridge geometry or white balance");
    const size_t pixels = size_t(mosaic.width) * mosaic.height;
    const float minimum = *std::min_element(wb.begin(), wb.end());
    const float nativeScale = minimum / wb[1];
    const auto transform = ColorConverter::invertMatrix(ColorConverter::multiplyMatrices(xyzToRgb(), cameraToXYZ));
    std::vector<float> peak(pixels), horizontal(pixels);
    constexpr int identities[] = {0, 1, 3, 2};
    for (int y = 0; y < mosaic.height; ++y) for (int x = 0; x < mosaic.width; ++x) {
        const size_t index = size_t(y) * mosaic.width + x;
        peak[index] = std::max(mosaic.values[index], noisy.values[index]) *
            (wb[identities[(y % 2) * 2 + x % 2]] / minimum);
    }
    // 保护整个邻域，避免 AHD/网络跨越已裁切像素向附近传播不可信的 RGB 修正。
    for (int y = 0; y < mosaic.height; ++y) maximumLine(peak, horizontal, size_t(y) * mosaic.width, 1, mosaic.width, 8);
    for (int x = 0; x < mosaic.width; ++x) maximumLine(horizontal, peak, x, mosaic.width, mosaic.height, 8);
    Tensor output{mosaic.width, mosaic.height, 3, std::vector<float>(pixels * 3)};
    for (size_t i = 0; i < pixels; ++i) {
        const float t = std::clamp((1 - peak[i]) / .15f, 0.f, 1.f);
        if (t == 0) continue;
        const float weight = t * t * (3 - 2 * t) * nativeScale;
        const RGB delta(inverseRec709(result.values[i]) - inverseRec709(skip.values[i]),
                        inverseRec709(result.values[pixels+i]) - inverseRec709(skip.values[pixels+i]),
                        inverseRec709(result.values[2*pixels+i]) - inverseRec709(skip.values[2*pixels+i]));
        const auto camera = ColorConverter::applyMatrix(delta, transform);
        output.values[i] = weight * camera.r;
        output.values[pixels+i] = weight * camera.g;
        output.values[2*pixels+i] = weight * camera.b;
    }
    validateTensor(output);
    return output;
}
} // namespace sony2fuji::ai
