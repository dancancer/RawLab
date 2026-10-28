#include "noise_aware_sharpen.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <new>
#ifdef SONY2FUJI_ENABLE_METAL
#include "gpu/metal_sharpen.h"
#endif

#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>

namespace {
float median(std::vector<float>& values) {
    const size_t middle = values.size() / 2;
    std::nth_element(values.begin(), values.begin() + middle, values.end());
    if (values.size() % 2) return values[middle];
    return (values[middle] + *std::max_element(values.begin(), values.begin() + middle)) * .5f;
}

cv::Mat mean(const cv::Mat& source, int size) {
    cv::Mat result;
    cv::blur(source, result, {size, size}, {-1, -1}, cv::BORDER_REPLICATE);
    return result;
}

cv::Mat maximum(const cv::Mat& source, int size) {
    cv::Mat result;
    cv::dilate(source, result, cv::Mat::ones(size, size, CV_8U), {-1, -1}, 1, cv::BORDER_REPLICATE);
    return result;
}

float neighbor(const cv::Mat& plane, int x, int y, bool horizontal, int offset) {
    return plane.at<float>(std::clamp(y + (horizontal ? 0 : offset), 0, plane.rows - 1),
                           std::clamp(x + (horizontal ? offset : 0), 0, plane.cols - 1));
}

cv::Mat filterCpu(const cv::Mat& source, const cv::Mat& luma, const cv::Mat& residual,
                  const cv::Mat& noise, float amount) {
    const auto size = source.size();
    const cv::Mat power = mean(residual.mul(residual), 9);
    cv::Mat gx, gy, low, high, inGamut(size, CV_8U), interior;
    cv::Sobel(luma, gx, CV_32F, 1, 0, 3, .125, 0, cv::BORDER_REPLICATE);
    cv::Sobel(luma, gy, CV_32F, 0, 1, 3, .125, 0, cv::BORDER_REPLICATE);
    const auto kernel = cv::Mat::ones(3, 3, CV_8U);
    cv::erode(source, low, kernel, {-1, -1}, 1, cv::BORDER_REPLICATE);
    cv::dilate(source, high, kernel, {-1, -1}, 1, cv::BORDER_REPLICATE);
    cv::Mat magnitude(size, CV_32F);
    for (int y = 0; y < size.height; ++y) for (int x = 0; x < size.width; ++x) {
        magnitude.at<float>(y, x) = std::hypot(gx.at<float>(y, x), gy.at<float>(y, x));
        const auto rgb = source.at<cv::Vec3f>(y, x);
        inGamut.at<uint8_t>(y, x) = rgb[0] > 0 && rgb[0] < 1 && rgb[1] > 0 && rgb[1] < 1 && rgb[2] > 0 && rgb[2] < 1;
    }
    cv::erode(inGamut, interior, kernel, {-1, -1}, 1, cv::BORDER_REPLICATE);
    const cv::Mat averageX = mean(gx, 9), averageY = mean(gy, 9), averageMagnitude = mean(magnitude, 9);
    const cv::Mat peak = maximum(magnitude, 9);
    cv::Mat requested(size, CV_32F), addition(size, CV_32F), before(size, CV_32F), after(size, CV_32F);
    cv::Mat edge(size, CV_8U), coherent(size, CV_8U), horizontal(size, CV_8U), direction(size, CV_32F), step(size, CV_32F);
    for (int y = 0; y < size.height; ++y) for (int x = 0; x < size.width; ++x) {
        const float variance = noise.at<float>(y, x), energy = power.at<float>(y, x);
        const float weight = std::max(energy - 4 * variance, 0.f) / std::max(energy + variance, 1e-12f);
        const float coherence = std::hypot(averageX.at<float>(y, x), averageY.at<float>(y, x)) /
            std::max(averageMagnitude.at<float>(y, x), 1e-12f);
        float core = std::clamp((magnitude.at<float>(y, x) / std::max(peak.at<float>(y, x), 1e-12f) - .2f) / .2f, 0.f, 1.f);
        core = core * core * (3 - 2 * core) * (coherence > .75f) * interior.at<uint8_t>(y, x);
        const float wanted = 2 * weight * residual.at<float>(y, x) * core;
        const auto rgb = source.at<cv::Vec3f>(y, x), lo = low.at<cv::Vec3f>(y, x), hi = high.at<cv::Vec3f>(y, x);
        float floor = -1, ceiling = 1;
        for (int c = 0; c < 3; ++c) { floor = std::max(floor, lo[c] - rgb[c]); ceiling = std::min(ceiling, hi[c] - rgb[c]); }
        requested.at<float>(y, x) = wanted;
        addition.at<float>(y, x) = std::clamp(wanted, floor, ceiling);
        const bool axis = std::abs(gx.at<float>(y, x)) >= std::abs(gy.at<float>(y, x));
        const float gradient = axis ? gx.at<float>(y, x) : gy.at<float>(y, x), sign = gradient >= 0 ? 1.f : -1.f;
        horizontal.at<uint8_t>(y, x) = axis; direction.at<float>(y, x) = sign;
        const float b = sign * (luma.at<float>(y, x) - neighbor(luma, x, y, axis, -1));
        const float a = sign * (neighbor(luma, x, y, axis, 1) - luma.at<float>(y, x));
        before.at<float>(y, x) = b; after.at<float>(y, x) = a;
        step.at<float>(y, x) = std::max(std::abs(b), std::abs(a));
        const float sigma = std::sqrt(variance);
        edge.at<uint8_t>(y, x) = std::abs(gradient) > sigma && weight > 0 && core > 0;
        coherent.at<uint8_t>(y, x) = edge.at<uint8_t>(y, x) && b > 2 * sigma && a > 2 * sigma;
    }
    cv::Mat relaxed(size, CV_32F);
    for (int y = 0; y < size.height; ++y) for (int x = 0; x < size.width; ++x) {
        float delta = addition.at<float>(y, x);
        if (coherent.at<uint8_t>(y, x)) {
            const bool axis = horizontal.at<uint8_t>(y, x);
            const float sign = direction.at<float>(y, x);
            const float floor = std::min(sign * neighbor(addition, x, y, axis, -1) - before.at<float>(y, x), 0.f);
            const float ceiling = std::max(sign * neighbor(addition, x, y, axis, 1) + after.at<float>(y, x), 0.f);
            delta = sign * std::clamp(sign * requested.at<float>(y, x), floor, ceiling);
        }
        const auto rgb = source.at<cv::Vec3f>(y, x);
        delta = std::clamp(delta, -std::min({rgb[0], rgb[1], rgb[2]}), 1 - std::max({rgb[0], rgb[1], rgb[2]}));
        if (magnitude.at<float>(y, x) < .75f * peak.at<float>(y, x)) delta = std::clamp(delta, -1.f / 255, 1.f / 255);
        relaxed.at<float>(y, x) = delta;
    }
    addition = relaxed;
    const cv::Mat stepPeak = maximum(step, 9);
    for (int pass = 0; pass < 2; ++pass) {
        cv::Mat projected = addition.clone();
        for (int y = 0; y < size.height; ++y) for (int x = 0; x < size.width; ++x) if (edge.at<uint8_t>(y, x)) {
            const bool axis = horizontal.at<uint8_t>(y, x);
            const float sign = direction.at<float>(y, x), b = before.at<float>(y, x), a = after.at<float>(y, x);
            const float bFloor = b >= .9f * stepPeak.at<float>(y, x) ? 0 : std::max(b, 0.f);
            const float aFloor = a >= .9f * stepPeak.at<float>(y, x) ? 0 : std::max(a, 0.f);
            const float floor = std::min(sign * neighbor(addition, x, y, axis, -1) - bFloor, 0.f);
            const float ceiling = std::max(sign * neighbor(addition, x, y, axis, 1) + aFloor, 0.f);
            projected.at<float>(y, x) = sign * std::clamp(sign * addition.at<float>(y, x), floor, ceiling);
        }
        addition = projected;
    }
    cv::Mat result(size, CV_32FC3);
    for (int y = 0; y < size.height; ++y) for (int x = 0; x < size.width; ++x) {
        const auto rgb = source.at<cv::Vec3f>(y, x);
        for (int c = 0; c < 3; ++c) result.at<cv::Vec3f>(y, x)[c] = std::clamp(rgb[c] + (amount / 2) * addition.at<float>(y, x), 0.f, 1.f);
    }
    return result;
}
} // namespace
#endif

namespace sony2fuji {
bool noiseAwareSharpenAvailable() {
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    return true;
#else
    return false;
#endif
}

ErrorCode applyNoiseAwareSharpen(ImageData& image, float amount, NoiseAwareSharpenDiagnostics* diagnostics, GpuMode mode) {
    if (diagnostics) *diagnostics = {};
    if (!std::isfinite(amount) || amount < 0 || amount > 2 || image.width <= 0 || image.height <= 0 ||
        static_cast<size_t>(image.width) > std::numeric_limits<size_t>::max() / static_cast<size_t>(image.height) ||
        static_cast<size_t>(image.width) * image.height != image.pixels.size() ||
        (mode != GpuMode::Off && mode != GpuMode::Auto && mode != GpuMode::Force)) return ErrorCode::InvalidFormat;
    for (const auto& rgb : image.pixels)
        if (!std::isfinite(rgb.r) || !std::isfinite(rgb.g) || !std::isfinite(rgb.b)) return ErrorCode::InvalidFormat;
    if (amount == 0) return ErrorCode::Success;
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    try {
        static_assert(sizeof(RGB) == 3 * sizeof(float));
        ImageData output = image;
        cv::Mat source(image.height, image.width, CV_32FC3), luminance(image.height, image.width, CV_32F);
        for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x) {
            const auto& pixel = image.at(x, y);
            const cv::Vec3f rgb(std::clamp(pixel.r, 0.f, 1.f), std::clamp(pixel.g, 0.f, 1.f), std::clamp(pixel.b, 0.f, 1.f));
            source.at<cv::Vec3f>(y, x) = rgb;
            luminance.at<float>(y, x) = (rgb[0] * .2126f + rgb[1] * .7152f) + rgb[2] * .0722f;
        }
        const cv::Mat residual = luminance - mean(luminance, 3);
        cv::Mat sigma((image.height - 1) / 64 + 1, (image.width - 1) / 64 + 1, CV_32F);
        std::vector<float> sigmas;
        for (int y = 0; y < image.height; y += 64) for (int x = 0; x < image.width; x += 64) {
            std::vector<float> values;
            for (int py = y; py < std::min(y + 64, image.height); ++py)
                for (int px = x; px < std::min(x + 64, image.width); ++px) values.push_back(residual.at<float>(py, px));
            const float center = median(values);
            for (auto& value : values) value = std::abs(value - center);
            const float value = median(values) / .67448975f;
            sigma.at<float>(y / 64, x / 64) = value;
            sigmas.push_back(value);
        }
        NoiseAwareSharpenDiagnostics info;
        info.noiseSigmaMedian = median(sigmas);
        info.noiseSigmaMax = *std::max_element(sigmas.begin(), sigmas.end());
        cv::Mat noise;
        cv::resize(sigma.mul(sigma), noise, source.size(), 0, 0, cv::INTER_LINEAR);
        cv::Mat destination(image.height, image.width, CV_32FC3, output.pixels.data());
        // 空间依赖最多 8 像素；只分块滤波，MAD 及噪声插值始终按整幅图计算。
        constexpr int tile = 768, halo = 8;
        for (int y = 0; y < image.height; y += tile) for (int x = 0; x < image.width; x += tile) {
            const cv::Rect center(x, y, std::min(tile, image.width - x), std::min(tile, image.height - y));
            const int left = std::max(0, x - halo), top = std::max(0, y - halo);
            const cv::Rect bounds(left, top, std::min(image.width, x + tile + halo) - left, std::min(image.height, y + tile + halo) - top);
            const cv::Mat rgb = source(bounds).clone(), luma = luminance(bounds).clone();
            const cv::Mat high = residual(bounds).clone(), variance = noise(bounds).clone();
            cv::Mat result;
            bool accelerated = false;
#ifdef SONY2FUJI_ENABLE_METAL
            if (mode != GpuMode::Off) {
                result.create(rgb.size(), CV_32FC3);
                accelerated = metalNoiseAwareSharpen(rgb.ptr<float>(), luma.ptr<float>(), high.ptr<float>(),
                    variance.ptr<float>(), rgb.cols, rgb.rows, amount, result.ptr<float>());
            }
#endif
            if (!accelerated) {
                if (mode == GpuMode::Force) return ErrorCode::ProcessingError;
                result = filterCpu(rgb, luma, high, variance, amount);
            }
            info.gpuUsed |= accelerated;
            result(cv::Rect(x - left, y - top, center.width, center.height)).copyTo(destination(center));
        }
        info.applied = true;
        image.pixels.swap(output.pixels);
        if (diagnostics) *diagnostics = info;
        return ErrorCode::Success;
    } catch (const std::bad_alloc&) { return ErrorCode::OutOfMemory; }
    catch (const cv::Exception&) { return ErrorCode::ProcessingError; }
#else
    return ErrorCode::ProcessingError;
#endif
}
}
