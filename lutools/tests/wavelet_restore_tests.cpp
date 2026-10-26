#include "../src/core/wavelet_denoise.cpp"
#include <iostream>
#include <stdexcept>
#include <cstring>

namespace {
constexpr float shot = .005f;
constexpr float read = .00002f;

void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

double inverse(double value) {
    const double positive = std::max(value, 0.);
    return std::sqrt(double(read) + .375 * shot * shot) * value + .25 * shot * positive * positive;
}

float restored(float value, float variance, float residualSign = 1) {
    const float source = static_cast<float>(inverse(value + residualSign * std::sqrt(variance)));
    cv::Mat rgb(17, 17, CV_32FC3, cv::Scalar(source, source, source));
    cv::Mat normalized(17, 17, CV_32FC3, cv::Scalar(value, value, value)), filtered;
    cv::transform(normalized, filtered, opponent());
    NoiseModel model{};
    model.a = {shot, shot, shot};
    model.b = {read, read, read};
    restore(rgb, filtered, model);
    const auto result = rgb.at<cv::Vec3f>(8, 8);
    require(std::isfinite(result[0]) && std::isfinite(result[1]) && std::isfinite(result[2]),
        "restoration must remain finite");
    require(std::abs(result[0] - result[1]) < 1e-6 && std::abs(result[0] - result[2]) < 1e-6,
        "neutral restoration must not introduce a color cast");
    return result[0];
}

void checkLegacyOpponent() {
    cv::RNG random(12345);
    for (const auto size : {cv::Size(1, 1), cv::Size(257, 263), cv::Size(1031, 1043)}) {
        cv::Mat source(size, CV_32FC3); random.fill(source, cv::RNG::UNIFORM, -2.f, 4.f);
        for (const auto matrix : {opponent(), opponent().t()}) {
            cv::Mat expected, actual;
            cv::transform(source, expected, matrix);
            transformOpponent(source, actual, matrix);
            require(std::memcmp(expected.data, actual.data, actual.total() * actual.elemSize()) == 0,
                "Legacy opponent transform differs from v0.8.2 cv::transform");
#if defined(__aarch64__) || defined(_M_ARM64) || defined(_M_ARM64EC)
            // 分块依赖 ARM64 上 OpenCV 的舍入与调用边界无关；覆盖行带、尾块和非连续 ROI。
            for (const int extent : {64, 512, 1024}) {
                auto tiled = source.clone();
                for (int y = 0; y < source.rows; y += extent) {
                    for (int x = 0; x < source.cols; x += extent) {
                        const cv::Rect region(x, y, std::min(extent, source.cols - x),
                            std::min(extent, source.rows - y));
                        auto input = source(region);
                        auto output = tiled(region);
                        transformOpponent(input, output, matrix);
                    }
                }
                require(std::memcmp(expected.data, tiled.data, tiled.total() * tiled.elemSize()) == 0,
                    "ARM64 Legacy tile transform differs bitwise from the released full-frame transform");
            }
            auto bands = source.clone();
            for (int y = 0; y < source.rows; y += 64) {
                auto band = bands.rowRange(y, std::min(source.rows, y + 64));
                transformOpponent(band, band, matrix);
            }
            require(std::memcmp(expected.data, bands.data, bands.total() * bands.elemSize()) == 0,
                "ARM64 Legacy in-place row-band transform differs bitwise from full-frame transform");
#endif
        }
    }
}

void checkZeroContinuity() {
    const float below = restored(-1e-6f, .56f, -1);
    const float above = restored(1e-6f, .56f, -1);
    std::cout << "restore zero crossing: below=" << below << " above=" << above
        << " difference=" << above - below << '\n';
    require(std::abs(above - below) < 1e-6, "rounding around zero must not switch a finite variance correction");
}

void checkSymmetricVariance() {
    for (float variance : {0.f, 1e-8f, .01f, .56f, 4.f}) {
        const float radius = std::sqrt(variance);
        for (float value : {-40.f, -2.f, -radius, -.5f * radius, 0.f, .5f * radius, radius, 2.f, 40.f}) {
            const double expected = .5 * (inverse(double(value) + radius) + inverse(double(value) - radius));
            for (float residualSign : {-1.f, 1.f}) {
                const double actual = restored(value, variance, residualSign);
                require(std::abs(actual - expected) < 3e-6 * std::max(1., std::abs(expected)),
                    "restoration must match the independent symmetric two-point inverse");
            }
        }
    }
    require(restored(-2, .01f) < 0, "negative linear RGB must not be clipped");
    require(restored(40, .01f) > 1, "over-white linear RGB must not be clipped");
}

void checkBoundarySlopes() {
    constexpr float variance = .56f, step = .001f;
    const float radius = std::sqrt(variance);
    for (float boundary : {-radius, 0.f, radius}) {
        const float center = restored(boundary, variance);
        const float left = (center - restored(boundary - step, variance)) / step;
        const float right = (restored(boundary + step, variance) - center) / step;
        require(left >= 0 && right >= 0 && std::abs(left - right) < .0005f,
            "restoration must be monotone with continuous boundary slopes");
    }
}
}

int main() {
    try {
        checkLegacyOpponent();
        checkZeroContinuity();
        checkSymmetricVariance();
        checkBoundarySlopes();
        std::cout << "PASS continuous variance-aware restoration and extended range\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
