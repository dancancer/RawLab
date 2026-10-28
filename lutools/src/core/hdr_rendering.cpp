#include "core/hdr_rendering.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace sony2fuji {
namespace {

constexpr uint64_t pixelLimit = 128000000;

float luminance(const RGB& p) { return .2126f * p.r + .7152f * p.g + .0722f * p.b; }
bool finite(const RGB& p) { return std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b); }
bool inRange(float value, float low, float high) {
    return std::isfinite(value) && value >= low && value <= high;
}

void validateImage(const ImageData& image) {
    if (image.width <= 0 || image.height <= 0 ||
        uint64_t(image.width) * uint64_t(image.height) > pixelLimit ||
        uint64_t(image.width) * uint64_t(image.height) != image.pixels.size())
        throw std::invalid_argument("HDR image dimensions or pixel storage are invalid");
    for (const auto& pixel : image.pixels)
        if (!finite(pixel)) throw std::invalid_argument("HDR pixels must be finite");
}

float smooth(float value, float low, float high) {
    const float t = std::clamp((value - low) / (high - low), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

RGB whiteBalance(const HDRRenderOptions& o) {
    if (o.temperature == 6500 && o.tint == 0) return {1, 1, 1};
    const float mired = 1 - 6500 / o.temperature;
    RGB gain{std::exp2(.5f * mired), std::exp2(-o.tint / 600), std::exp2(-.5f * mired)};
    const float y = luminance(gain);
    return {gain.r / y, gain.g / y, gain.b / y};
}

float encodeSRGB(float x) {
    return x <= .0031308f ? 12.92f * x : 1.055f * std::pow(x, 1 / 2.4f) - .055f;
}
float decodeSRGB(float x) {
    return x <= .04045f ? x / 12.92f : std::pow((x + .055f) / 1.055f, 2.4f);
}

RGB toneHDR(RGB p, const HDRRenderOptions& o) {
    const float y = luminance(p);
    if (y > 0 && (o.contrast != 0 || o.highlights != 0 || o.shadows != 0)) {
        float target = y;
        if (o.contrast != 0)
            target = .18f * std::exp2(std::log2(y / .18f) * std::exp2(o.contrast / 100));
        const float stops = std::log2(target);
        const float highlightWeight = smooth(stops, -2, 1);
        const float shadowWeight = 1 - smooth(stops, -5, -1);
        target *= std::exp2(.02f * (o.highlights * highlightWeight + o.shadows * shadowWeight));
        const float scale = target / y;
        p = {p.r * scale, p.g * scale, p.b * scale};
    }
    if (o.saturation != 0) {
        const float gray = luminance(p), factor = 1 + o.saturation / 100;
        p = {gray + (p.r - gray) * factor, gray + (p.g - gray) * factor, gray + (p.b - gray) * factor};
    }
    return p;
}

RGB toneSDR(RGB p, const HDRRenderOptions& o) {
    // 默认和仅 WB/曝光时不做 gamma 往返，保留底图的 float identity。
    if (o.contrast == 0 && o.highlights == 0 && o.shadows == 0 && o.saturation == 0) return p;
    p = {encodeSRGB(p.r), encodeSRGB(p.g), encodeSRGB(p.b)};
    const float y = luminance(p);
    if (y > 0 && (o.shadows != 0 || o.highlights != 0)) {
        float target = std::clamp(y, 0.0f, 1.0f);
        if (o.shadows != 0) target = std::pow(target, 1 - .005f * o.shadows);
        if (o.highlights != 0) target = 1 - std::pow(1 - target, 1 + .005f * o.highlights);
        const float scale = target / y;
        p = {p.r * scale, p.g * scale, p.b * scale};
    }
    if (o.contrast != 0) {
        const float factor = 1 + o.contrast / 100;
        p = {(p.r - .5f) * factor + .5f, (p.g - .5f) * factor + .5f, (p.b - .5f) * factor + .5f};
    }
    if (o.saturation != 0) {
        const float gray = luminance(p), factor = 1 + o.saturation / 100;
        p = {gray + (p.r - gray) * factor, gray + (p.g - gray) * factor, gray + (p.b - gray) * factor};
    }
    return {decodeSRGB(p.r), decodeSRGB(p.g), decodeSRGB(p.b)};
}

void edit(ImageData& image, const HDRRenderOptions& o, bool hdr) {
    const RGB gain = whiteBalance(o);
    const float exposure = std::exp2(o.exposureEV);
    const bool colorActive = o.exposureEV != 0 || o.temperature != 6500 || o.tint != 0;
    const bool toneActive = o.contrast != 0 || o.highlights != 0 || o.shadows != 0 || o.saturation != 0;
    if (!colorActive && !toneActive) return;
    for (auto& p : image.pixels) {
        if (colorActive) p = {p.r * gain.r * exposure, p.g * gain.g * exposure, p.b * gain.b * exposure};
        if (toneActive) p = hdr ? toneHDR(p, o) : toneSDR(p, o);
        if (!finite(p)) throw std::overflow_error("HDR adjustments exceeded finite float range");
    }
}

void resize(ImageData& image, uint32_t longEdge) {
    const int edge = std::max(image.width, image.height);
    if (longEdge == 0 || longEdge >= uint32_t(edge)) return;
    const double scale = double(longEdge) / edge;
    const int width = std::max(1, int(std::lround(image.width * scale)));
    const int height = std::max(1, int(std::lround(image.height * scale)));
    ImageData output(width, height);
    for (int y = 0; y < height; ++y) {
        const float sy = height > 1 ? float(y) * (image.height - 1) / (height - 1) : (image.height - 1) * .5f;
        const int y0 = int(sy), y1 = std::min(y0 + 1, image.height - 1);
        const float fy = sy - y0;
        for (int x = 0; x < width; ++x) {
            const float sx = width > 1 ? float(x) * (image.width - 1) / (width - 1) : (image.width - 1) * .5f;
            const int x0 = int(sx), x1 = std::min(x0 + 1, image.width - 1);
            const float fx = sx - x0;
            const auto& a = image.at(x0, y0); const auto& b = image.at(x1, y0);
            const auto& c = image.at(x0, y1); const auto& d = image.at(x1, y1);
            auto blend = [&](float av, float bv, float cv, float dv) {
                return (av + (bv - av) * fx) * (1 - fy) + (cv + (dv - cv) * fx) * fy;
            };
            output.at(x, y) = {blend(a.r, b.r, c.r, d.r), blend(a.g, b.g, c.g, d.g), blend(a.b, b.b, c.b, d.b)};
        }
    }
    image = std::move(output);
}

} // namespace

HDRImagePair renderHDRPair(const HDRImagePair& source, const HDRRenderOptions& o) {
    validateImage(source.hdr); validateImage(source.sdr);
    if (source.hdr.width != source.sdr.width || source.hdr.height != source.sdr.height ||
        o.processingVersion != 1 || !inRange(o.exposureEV, -4, 4) || !inRange(o.temperature, 2000, 50000) ||
        !inRange(o.tint, -150, 150) || !inRange(o.contrast, -100, 100) || !inRange(o.highlights, -100, 100) ||
        !inRange(o.shadows, -100, 100) || !inRange(o.saturation, -100, 100) ||
        !o.geometry.valid() || o.longEdge > 65535 ||
        (o.intent != HDRQuality::Preview && o.intent != HDRQuality::Final) ||
        (source.sourceQuality != HDRQuality::Preview && source.sourceQuality != HDRQuality::Final) ||
        (source.renderQuality != HDRQuality::Preview && source.renderQuality != HDRQuality::Final) ||
        !std::isfinite(source.sourceHeadroom) || (source.sourceHeadroom != 0 && source.sourceHeadroom < 1) ||
        (o.intent == HDRQuality::Final && (source.isProxy || source.sourceQuality != HDRQuality::Final ||
            source.renderQuality != HDRQuality::Final)))
        throw std::invalid_argument("Invalid HDR pair, settings, version or FINAL provenance");
    HDRImagePair result = source;
    const auto nativeSize=geometryOutputSize(int(source.nativeWidth),int(source.nativeHeight),o.geometry);
    result.outputNativeWidth=nativeSize.first; result.outputNativeHeight=nativeSize.second;
    edit(result.hdr, o, true); edit(result.sdr, o, false);
    for (auto* image : {&result.hdr, &result.sdr}) {
        const auto status = applyGeometry(*image, o.geometry);
        if (status == ErrorCode::OutOfMemory) throw std::bad_alloc();
        if (status != ErrorCode::Success) throw std::invalid_argument("Invalid HDR geometry");
        resize(*image, o.longEdge);
    }
    result.renderQuality = o.intent;
    result.isProxy = source.isProxy || o.intent == HDRQuality::Preview;
    result.editedHeadroom = 1;
    for (const auto& pixel : result.hdr.pixels) {
        if (!finite(pixel)) throw std::overflow_error("HDR geometry exceeded finite float range");
        result.editedHeadroom = std::max(result.editedHeadroom, luminance(pixel));
    }
    if (!std::isfinite(result.editedHeadroom)) throw std::overflow_error("HDR headroom exceeded finite float range");
    return result;
}

} // namespace sony2fuji
