#include "photo_basic_controls_v3.h"
#include "parallel_pixels.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace sony2fuji {
namespace {

float smooth(float value) {
    value = std::clamp(value, 0.f, 1.f);
    return value * value * (3 - 2 * value);
}

float luminance(const RGB& pixel) {
    return pixel.g + .2126f * (pixel.r - pixel.g) + .0722f * (pixel.b - pixel.g);
}

std::vector<float> boxMean(const std::vector<float>& input, int width, int height, int radius) {
    std::vector<float> horizontal(input.size()), output(input.size());
    for (int y = 0; y < height; ++y) {
        checkProcessingCancellation();
        double sum = 0;
        int left = 0, right = -1;
        for (int x = 0; x < width; ++x) {
            const int first = std::max(0, x - radius), last = std::min(width - 1, x + radius);
            while (right < last) sum += input[size_t(y) * width + ++right];
            while (left < first) sum -= input[size_t(y) * width + left++];
            horizontal[size_t(y) * width + x] = static_cast<float>(sum / (last - first + 1));
        }
    }
    for (int x = 0; x < width; ++x) {
        double sum = 0;
        int top = 0, bottom = -1;
        for (int y = 0; y < height; ++y) {
            const int first = std::max(0, y - radius), last = std::min(height - 1, y + radius);
            while (bottom < last) sum += horizontal[size_t(++bottom) * width + x];
            while (top < first) sum -= horizontal[size_t(top++) * width + x];
            output[size_t(y) * width + x] = static_cast<float>(sum / (last - first + 1));
        }
    }
    return output;
}

float sample(const std::vector<float>& values, int width, int height, float x, float y) {
    x = std::clamp(x, 0.f, float(width - 1));
    y = std::clamp(y, 0.f, float(height - 1));
    const int x0 = static_cast<int>(x), y0 = static_cast<int>(y);
    const int x1 = std::min(x0 + 1, width - 1), y1 = std::min(y0 + 1, height - 1);
    const float tx = x - x0, ty = y - y0;
    const float top = values[size_t(y0) * width + x0] * (1 - tx) + values[size_t(y0) * width + x1] * tx;
    const float bottom = values[size_t(y1) * width + x0] * (1 - tx) + values[size_t(y1) * width + x1] * tx;
    return top * (1 - ty) + bottom * ty;
}

} // namespace

void applyBasicToneV3(ImageData& image, const BasicToneV3& options, int sourceWidth, int sourceHeight) {
    if (!options.active() || image.width <= 0 || image.height <= 0) return;
    if (sourceWidth <= 0 || sourceHeight <= 0) {
        sourceWidth = image.width;
        sourceHeight = image.height;
    }
    const double scale = std::min(1., 768. / std::max(sourceWidth, sourceHeight));
    const int width = std::max(1, std::min(image.width, int(std::lround(sourceWidth * scale))));
    const int height = std::max(1, std::min(image.height, int(std::lround(sourceHeight * scale))));
    const double sx = double(image.width) / width, sy = double(image.height) / height;
    std::vector<float> guide(size_t(width) * height);
    parallelPixelRanges(guide.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const int x = int(i % width), y = int(i / width);
            const double left = x * sx, right = (x + 1) * sx, top = y * sy, bottom = (y + 1) * sy;
            double sum = 0;
            for (int iy = int(top); iy < std::min(image.height, int(std::ceil(bottom))); ++iy) {
                for (int ix = int(left); ix < std::min(image.width, int(std::ceil(right))); ++ix) {
                    const double weight = (std::min(right, double(ix + 1)) - std::max(left, double(ix))) *
                        (std::min(bottom, double(iy + 1)) - std::max(top, double(iy)));
                    const float light = luminance(image.at(ix, iy));
                    sum += weight * std::log2(std::max(std::isfinite(light) ? light : 0.f, 1e-7f) / .1845f);
                }
            }
            guide[i] = static_cast<float>(sum / (sx * sy));
        }
    });

    // 引导滤波仅决定区域权重；最终像素沿自身的线性 RGB 比例变化。
    const int radius = std::max(1, int(std::lround(std::max(width, height) * .025)));
    const auto mean = boxMean(guide, width, height, radius);
    std::vector<float> squared(guide.size()), slope(guide.size()), intercept(guide.size());
    for (size_t i = 0; i < guide.size(); ++i) squared[i] = guide[i] * guide[i];
    const auto meanSquared = boxMean(squared, width, height, radius);
    for (size_t i = 0; i < guide.size(); ++i) {
        const float variance = std::max(0.f, meanSquared[i] - mean[i] * mean[i]);
        slope[i] = variance / (variance + .25f);
        intercept[i] = mean[i] * (1 - slope[i]);
    }
    slope = boxMean(slope, width, height, radius);
    intercept = boxMean(intercept, width, height, radius);
    const float shadows = std::clamp(options.shadows, -1.f, 1.f);
    const float highlights = std::clamp(options.highlights, -1.f, 1.f);
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            auto& pixel = image.pixels[i];
            const float light = luminance(pixel);
            if (!std::isfinite(light) || light <= 0) continue;
            const float logLight = std::log2(std::max(light, 1e-7f) / .1845f);
            const float x = (float(i % image.width) + .5f) * width / image.width - .5f;
            const float y = (float(i / image.width) + .5f) * height / image.height - .5f;
            const float base = sample(slope, width, height, x, y) * logLight +
                sample(intercept, width, height, x, y);
            const float shadowWeight = 1 - smooth((base + 6) / 7);
            const float highlightWeight = smooth((base + 1) / 6);
            const float gain = std::exp2(3.5f * shadows * shadowWeight + 3.f * highlights * highlightWeight);
            pixel.r *= gain;
            pixel.g *= gain;
            pixel.b *= gain;
        }
    });
}

float basicContrastV3(float value, float amount) {
    if (amount == 0 || value <= 0 || value >= 1) return value;
    const float exponent = std::exp2(std::clamp(amount, -1.f, 1.f) * .75f);
    const float low = std::pow(value, exponent), high = std::pow(1 - value, exponent);
    return low / (low + high);
}

RGB basicBlackWhiteV3(const RGB& pixel, const ToneControlsOptions& options) {
    if (options.blackPoint == 0 && options.whitePoint == 0) return pixel;
    auto result = pixel;
    if (options.blackPoint < 0) {
        const float black = .24f * options.blackPoint * options.blackPoint;
        const float scale = 1 / (1 - black);
        result = RGB((result.r - black) * scale, (result.g - black) * scale, (result.b - black) * scale);
    } else if (options.blackPoint > 0) {
        const float y = std::clamp(luminance(result), 0.f, 1.f);
        const float black = std::pow(options.blackPoint, 1.4f) *
            (.15f * (1 - std::exp(-y / .06f)) + .01f * std::pow(1 - y, 7.f));
        result = RGB(result.r * (1 - black) + black, result.g * (1 - black) + black,
            result.b * (1 - black) + black);
    }
    if (options.whitePoint != 0) {
        const float y = std::max(0.f, luminance(result));
        const float scale = options.whitePoint < 0 ? 1 / (1 - .18f * options.whitePoint * y) :
            (y > 0 ? 1 + .18f * std::pow(options.whitePoint, 1.4f) * smooth(y / .8f) / y : 1);
        result.r *= scale;
        result.g *= scale;
        result.b *= scale;
    }
    return result;
}

RGB basicVibranceV3(const RGB& pixel, float amount) {
    if (amount == 0) return pixel;
    const float maximum = std::max({pixel.r, pixel.g, pixel.b});
    const float minimum = std::min({pixel.r, pixel.g, pixel.b});
    const float chroma = maximum - minimum;
    if (chroma <= 0 || maximum <= 0) return pixel;
    const float saturation = std::clamp(chroma / maximum, 0.f, 1.f);
    const float y = luminance(pixel);
    float gain;
    if (amount < 0) {
        // 鲜艳度的负端保留原本饱和的颜色；完全去色仍由饱和度负责。
        gain = 1 + amount * (.95f - .45f * saturation * saturation);
    } else {
        if (minimum < 0 || maximum > 1) return pixel;
        float hue;
        if (maximum == pixel.r) hue = 60 * std::fmod((pixel.g - pixel.b) / chroma, 6);
        else if (maximum == pixel.g) hue = 60 * ((pixel.b - pixel.r) / chroma + 2);
        else hue = 60 * ((pixel.r - pixel.g) / chroma + 4);
        if (hue < 0) hue += 360;
        const float distance = std::min(std::abs(hue - 35), 360 - std::abs(hue - 35));
        const float skin = (1 - smooth(distance / 45)) * smooth((y - .08f) / .12f) *
            (1 - smooth((y - .75f) / .2f)) * smooth((chroma - .02f) / .08f);
        gain = 1 + 2 * amount * (1 - saturation) * (1 - .6f * skin);
        for (float channel : {pixel.r, pixel.g, pixel.b}) {
            const float difference = channel - y;
            if (difference > 0) gain = std::min(gain, (1 - y) / difference);
            else if (difference < 0) gain = std::min(gain, -y / difference);
        }
    }
    return RGB(y + (pixel.r - y) * gain, y + (pixel.g - y) * gain, y + (pixel.b - y) * gain);
}

void applyBasicBlackWhiteV3(ImageData& image, const ToneControlsOptions& options) {
    if (options.blackPoint == 0 && options.whitePoint == 0) return;
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) image.pixels[i] = basicBlackWhiteV3(image.pixels[i], options);
    });
}

void applyBasicVibranceV3(ImageData& image, float amount) {
    if (amount == 0) return;
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) image.pixels[i] = basicVibranceV3(image.pixels[i], amount);
    });
}

} // namespace sony2fuji
