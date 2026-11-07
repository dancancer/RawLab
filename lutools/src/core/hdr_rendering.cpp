#include "core/hdr_rendering.h"
#include "core/hdr_look.h"
#include "core/parallel_pixels.h"
#include "core/photo_tone_curve.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

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

ToneCurve hdrCurve(const HDRToneOptions& tone) {
    if (tone.curve.mode == SONY2FUJI_CURVE_CUSTOM) return ToneCurve(tone.curve);
    if (tone.curveStrength == 0) return {};
    auto config = tone.curve;
    const double offset = tone.curveStrength / 1600.0;
    config.mode = SONY2FUJI_CURVE_CUSTOM;
    config.count = 5;
    config.points[0] = {0, 0};
    config.points[1] = {.25, .25 - offset};
    config.points[2] = {.5, .5};
    config.points[3] = {.75, .75 + offset};
    config.points[4] = {1, 1};
    return ToneCurve(config);
}

RGB editToneV2(RGB pixel, const HDRToneOptions& tone, const ToneCurve& curve) {
    const float y = luminance(pixel);
    if (y <= 0) return pixel;
    const float stops = std::log2(y);
    float target = stops + (tone.blackPoint * (1 - smooth(stops, -7, -3)) +
        tone.whitePoint * smooth(stops, -1, 3)) / 50;
    if (curve.active() && target > -8 && target < 8)
        target = float(curve.evaluate((double(target) + 8) / 16) * 16 - 8);
    if (target == stops) return pixel;
    const float gain = std::exp2(target - stops);
    return {pixel.r * gain, pixel.g * gain, pixel.b * gain};
}

RGB scaleChroma(const RGB& pixel, float y, double factor, double lightness = 1) {
    const auto channel = [=](float value) { return float((y + (double(value) - y) * factor) * lightness); };
    return {channel(pixel.r), channel(pixel.g), channel(pixel.b)};
}

RGB hdrVibrance(const RGB& pixel, float strength) {
    const auto color = analyzeHDRColor(pixel);
    if (!color.valid) return pixel;
    const float unsaturated = 1 - color.saturation;
    const float skin = smooth(color.hue, 5, 20) * (1 - smooth(color.hue, 45, 70));
    const float weight = strength > 0 ? unsaturated * unsaturated * (1 - .5f * skin) : 1;
    const double factor = 1 + double(strength) * weight / 100;
    return factor == 1 ? pixel : scaleChroma(pixel, luminance(pixel), factor);
}

RGB hdrHsl(const RGB& pixel, const HslOptions& settings) {
    const auto color = analyzeHDRColor(pixel);
    if (!color.valid) return pixel;
    const float hue = color.value(settings.hue);
    const float saturation = color.value(settings.saturation);
    const float lightness = color.value(settings.lightness) * smooth(color.saturation, .0005f, .02f);
    if (hue == 0 && saturation == 0 && lightness == 0) return pixel;
    const float y = luminance(pixel);
    const double chromaScale = 1 + double(saturation) / 100;
    const double lightnessScale = std::exp2(double(lightness) / 100);
    if (hue == 0) return scaleChroma(pixel, y, chromaScale, lightnessScale);

    const auto direction = hueUnitRGB(std::fmod(color.hue + .3f * hue + 360, 360));
    const float directionY = luminance(direction);
    const double spread = double(std::max({pixel.r, pixel.g, pixel.b})) - std::min({pixel.r, pixel.g, pixel.b});
    const double chroma = spread * chromaScale;
    const auto channel = [=](float value) { return float((y + chroma * (value - directionY)) * lightnessScale); };
    return {channel(direction.r), channel(direction.g), channel(direction.b)};
}

RGB hdrGrade(const RGB& pixel, const std::array<RGB, 3>& coefficients) {
    const float y = luminance(pixel);
    if (y <= 0) return pixel;
    const float stops = std::log2(y);
    const float shadows = 1 - smooth(stops, -5, -2.5f);
    const float highlights = smooth(stops, -1, 1);
    const float middle = 1 - shadows - highlights;
    const auto channel = [=](float value, float shadow, float midtone, float highlight) {
        return float(value + .25 * y * (shadows * shadow + middle * midtone + highlights * highlight));
    };
    return {channel(pixel.r, coefficients[0].r, coefficients[1].r, coefficients[2].r),
        channel(pixel.g, coefficients[0].g, coefficients[1].g, coefficients[2].g),
        channel(pixel.b, coefficients[0].b, coefficients[1].b, coefficients[2].b)};
}

RGB limitHDRLuminance(const RGB& pixel, double knee, double span) {
    const double y = .2126 * pixel.r + .7152 * pixel.g + .0722 * pixel.b;
    if (y <= knee) return pixel;
    const double above = y - knee;
    const double scale = (knee + span * above / (span + above)) / y;
    return {float(pixel.r * scale), float(pixel.g * scale), float(pixel.b * scale)};
}

void edit(ImageData& image, const HDRRenderOptions& o, bool hdr) {
    const RGB gain = hdrRelativeWhiteBalance(o.temperature, o.tint);
    const float exposure = std::exp2(o.exposureEV);
    const bool colorActive = o.exposureEV != 0 || o.temperature != 6500 || o.tint != 0;
    const bool toneActive = o.contrast != 0 || o.highlights != 0 || o.shadows != 0 || o.saturation != 0;
    const bool useToneV2 = o.processingVersion >= SONY2FUJI_HDR_PROCESSING_TONE_VERSION;
    const auto curve = useToneV2 ? hdrCurve(o.tone) : ToneCurve();
    const bool advancedToneActive = useToneV2 && (o.tone.blackPoint != 0 || o.tone.whitePoint != 0 || curve.active());
    const bool useColor = o.processingVersion >= SONY2FUJI_HDR_PROCESSING_COLOR_VERSION;
    const bool vibranceActive = useColor && o.color.vibrance != 0;
    const bool hslActive = useColor && o.color.hsl.active();
    const bool gradingActive = useColor && o.color.grading.active();
    const auto grading = gradingActive ? colorGradingCoefficients(o.color.grading) : std::array<RGB, 3>{};
    const bool lookActive = o.processingVersion >= SONY2FUJI_HDR_PROCESSING_LOOK_VERSION && o.look && o.lookStrength != 0;
    const bool useRendition = o.processingVersion >= SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION;
    const auto& rendition = o.rendition;
    const bool limitHDR = hdr && useRendition && rendition.peakLimitEV != 0;
    const double peak = limitHDR ? std::exp2(double(rendition.peakLimitEV)) : 1;
    const double knee = std::max(1.0, peak * .5);
    const bool adjustBase = !hdr && useRendition &&
        (rendition.sdrExposureEV != 0 || rendition.sdrContrast != 0 || rendition.sdrSaturation != 0);
    const float baseExposure = adjustBase ? std::exp2(rendition.sdrExposureEV) : 1;
    HDRRenderOptions baseTone;
    baseTone.contrast = rendition.sdrContrast;
    baseTone.saturation = rendition.sdrSaturation;
    if (!colorActive && !toneActive && !advancedToneActive && !vibranceActive && !hslActive && !gradingActive &&
        !lookActive && !limitHDR && !adjustBase) return;
    std::atomic<bool> overflow{false};
    parallelPixelRanges(image.pixels.size(), [&](size_t begin, size_t end) {
        for (size_t i = begin; i < end; ++i) {
            auto& p = image.pixels[i];
            if (colorActive) p = {p.r * gain.r * exposure, p.g * gain.g * exposure, p.b * gain.b * exposure};
            if (toneActive) p = hdr ? toneHDR(p, o) : toneSDR(p, o);
            if (advancedToneActive) p = editToneV2(p, o.tone, curve);
            if (vibranceActive) p = hdrVibrance(p, o.color.vibrance);
            if (hslActive) p = hdrHsl(p, o.color.hsl);
            if (gradingActive) p = hdrGrade(p, grading);
            if (lookActive) p = o.look->apply(p, o.lookStrength);
            if (limitHDR) p = limitHDRLuminance(p, knee, peak - knee);
            if (adjustBase) p = toneSDR({p.r * baseExposure, p.g * baseExposure, p.b * baseExposure}, baseTone);
            if (!finite(p)) overflow.store(true, std::memory_order_relaxed);
        }
    });
    if (overflow.load(std::memory_order_relaxed))
        throw std::overflow_error("HDR adjustments exceeded finite float range");
}

template<class Reader> RGB sampleResize(int x, int y, int width, int height, int outputWidth, int outputHeight,
    const Reader& read) {
    if (width == outputWidth && height == outputHeight) return read(x, y);
    const float sy = outputHeight > 1 ? float(y) * (height - 1) / (outputHeight - 1) : (height - 1) * .5f;
    const int y0 = int(sy), y1 = std::min(y0 + 1, height - 1);
    const float fy = sy - y0;
    const float sx = outputWidth > 1 ? float(x) * (width - 1) / (outputWidth - 1) : (width - 1) * .5f;
    const int x0 = int(sx), x1 = std::min(x0 + 1, width - 1);
    const float fx = sx - x0;
    const auto a = read(x0, y0), b = read(x1, y0), c = read(x0, y1), d = read(x1, y1);
    auto blend = [&](float av, float bv, float cv, float dv) {
        return (av + (bv - av) * fx) * (1 - fy) + (cv + (dv - cv) * fx) * fy;
    };
    return {blend(a.r, b.r, c.r, d.r), blend(a.g, b.g, c.g, d.g), blend(a.b, b.b, c.b, d.b)};
}

void resize(ImageData& image, uint32_t longEdge) {
    const int edge = std::max(image.width, image.height);
    if (longEdge == 0 || longEdge >= uint32_t(edge)) return;
    const auto size = hdrResizeSize(image.width, image.height, longEdge);
    const int width = size.first, height = size.second;
    ImageData output(width, height);
    parallelPixelRanges(output.pixels.size(), [&](size_t begin, size_t end) {
        for (size_t i = begin; i < end; ++i) {
            const int y = int(i / width), x = int(i % width);
            output.at(x, y) = sampleResize(x, y, image.width, image.height, width, height,
                [&](int sx, int sy) { return image.at(sx, sy); });
        }
    });
    image = std::move(output);
}

} // namespace

namespace {

void finishGeometry(ImageData& image, const HDRRenderOptions& options) {
    const auto status = applyGeometry(image, options.geometry);
    if (status == ErrorCode::OutOfMemory) throw std::bad_alloc();
    if (status != ErrorCode::Success) throw std::invalid_argument("Invalid HDR geometry");
    resize(image, options.longEdge);
}

void finishEffects(ImageData& image, const HDRRenderOptions& options, bool hdr) {
    if (!options.hasPhotoEffects()) return;
    const PhotoEffectSampler sampler(options.effects, image.width, image.height);
    const double peak = hdr && options.rendition.peakLimitEV > 0 ? std::exp2(double(options.rendition.peakLimitEV)) : 0;
    std::atomic<bool> overflow{false};
    parallelPixelRanges(image.pixels.size(), [&](size_t begin, size_t end) {
        for (size_t i = begin; i < end; ++i) {
            auto& pixel = image.pixels[i];
            pixel = sampler.applyExtendedLinear(pixel, int(i % image.width), int(i / image.width), peak);
            if (!finite(pixel)) overflow.store(true, std::memory_order_relaxed);
        }
    });
    if (overflow.load(std::memory_order_relaxed)) throw std::overflow_error("HDR effects exceeded finite float range");
}

void finishDetail(ImageData& image, const HDRRenderOptions& options, bool hdr) {
    if (!options.hasDetail()) return;
    const double peak = hdr && options.rendition.peakLimitEV > 0 ? std::exp2(double(options.rendition.peakLimitEV)) : 0;
    const auto plan = planHDRDetail(image.width, image.height, options.detail, peak,
        [&](int x, int y) { return image.at(x, y); });
    ImageData output(image.width, image.height);
    for (int first = 0; first < image.height; first += hdrDetailBandHeight) {
        const int end = std::min(first + hdrDetailBandHeight, image.height);
        const int top = std::max(0, first - plan.halo);
        const int bottom = std::min(image.height, end + plan.halo);
        renderHDRDetailBand(plan, image.pixels.data() + size_t(top) * image.width, top, bottom - top,
            output.pixels.data() + size_t(first) * image.width, first, end - first);
    }
    image = std::move(output);
}

void validateRenderInput(const HDRImagePair& source, const HDRRenderOptions& o) {
    validateImage(source.hdr); validateImage(source.sdr);
    validateHDRRenderOptions(o);
    if (source.hdr.width != source.sdr.width || source.hdr.height != source.sdr.height ||
        (source.sourceQuality != HDRQuality::Preview && source.sourceQuality != HDRQuality::Final) ||
        (source.renderQuality != HDRQuality::Preview && source.renderQuality != HDRQuality::Final) ||
        !std::isfinite(source.sourceHeadroom) || (source.sourceHeadroom != 0 && source.sourceHeadroom < 1) ||
        (o.intent == HDRQuality::Final && (source.isProxy || source.sourceQuality != HDRQuality::Final ||
            source.renderQuality != HDRQuality::Final)))
        throw std::invalid_argument("Invalid HDR pair, settings, version or FINAL provenance");
}

HDRImagePair renderHDRPairOwned(HDRImagePair source, const HDRRenderOptions& o) {
    HDRImagePair result = std::move(source);
    const auto nativeSize=geometryOutputSize(int(result.nativeWidth),int(result.nativeHeight),o.geometry);
    result.outputNativeWidth=nativeSize.first; result.outputNativeHeight=nativeSize.second;
    edit(result.hdr, o, true); edit(result.sdr, o, false);
    finishGeometry(result.hdr, o);
    finishGeometry(result.sdr, o);
    finishDetail(result.hdr, o, true);
    finishDetail(result.sdr, o, false);
    finishEffects(result.hdr, o, true);
    finishEffects(result.sdr, o, false);
    result.renderQuality = o.intent;
    result.isProxy = result.isProxy || o.intent == HDRQuality::Preview;
    result.editedHeadroom = 1;
    for (const auto& pixel : result.hdr.pixels) {
        if (!finite(pixel)) throw std::overflow_error("HDR geometry exceeded finite float range");
        result.editedHeadroom = std::max(result.editedHeadroom, luminance(pixel));
    }
    if (!std::isfinite(result.editedHeadroom)) throw std::overflow_error("HDR headroom exceeded finite float range");
    return result;
}

} // namespace

HDRImagePair renderHDRPair(const HDRImagePair& source, const HDRRenderOptions& o) {
    validateRenderInput(source, o);
    return renderHDRPairOwned(HDRImagePair(source), o);
}

HDRImagePair renderHDRPair(HDRImagePair&& source, const HDRRenderOptions& o) {
    validateRenderInput(source, o);
    return renderHDRPairOwned(std::move(source), o);
}

ImageData renderHDRHslProbe(ImageData image, const HDRRenderOptions& options) {
    validateHDRRenderOptions(options);
    validateImage(image);
    auto beforeColor = options;
    beforeColor.color.hsl = {};
    beforeColor.color.grading = {};
    beforeColor.rendition = {};
    edit(image, beforeColor, true);
    finishGeometry(image, beforeColor);
    return image;
}

HslColor analyzeHDRColor(const RGB& pixel) {
    // Normalize for hue analysis so the eight hue ranges do not depend on exposure.
    const float scale = std::max({std::abs(pixel.r), std::abs(pixel.g), std::abs(pixel.b)});
    if (scale == 0 || !finite(pixel)) return {};
    const RGB normalized(pixel.r / scale, pixel.g / scale, pixel.b / scale);
    const float y = luminance(normalized);
    if (y <= 0) return {};
    auto color = analyzeHslColor(normalized);
    if (color.valid) {
        color.saturation = color.spread / (color.spread + y);
        const double linearLuminance = double(y) * scale;
        color.lightness = float(linearLuminance / (1 + linearLuminance));
    }
    return color;
}

RGB hdrRelativeWhiteBalance(float temperature, float tint) {
    if (temperature == 6500 && tint == 0) return {1, 1, 1};
    const float mired = 1 - 6500 / temperature;
    RGB gain{std::exp2(.5f * mired), std::exp2(-tint / 600), std::exp2(-.5f * mired)};
    const float y = luminance(gain);
    return {gain.r / y, gain.g / y, gain.b / y};
}

void validateHDRRenderOptions(const HDRRenderOptions& o) {
    const bool useToneV2 = o.processingVersion >= SONY2FUJI_HDR_PROCESSING_TONE_VERSION;
    if (o.processingVersion < SONY2FUJI_HDR_PROCESSING_VERSION || o.processingVersion > SONY2FUJI_HDR_PROCESSING_LOOK_VERSION ||
        !inRange(o.exposureEV, -4, 4) || !inRange(o.temperature, 2000, 50000) ||
        !inRange(o.tint, -150, 150) || !inRange(o.contrast, -100, 100) || !inRange(o.highlights, -100, 100) ||
        !inRange(o.shadows, -100, 100) || !inRange(o.saturation, -100, 100) ||
        !o.geometry.valid() || o.longEdge > 65535 ||
        (o.intent != HDRQuality::Preview && o.intent != HDRQuality::Final))
        throw std::invalid_argument("Invalid HDR render settings");
    if (useToneV2 && (!inRange(o.tone.blackPoint, -100, 100) || !inRange(o.tone.whitePoint, -100, 100) ||
        !inRange(o.tone.curveStrength, -100, 100) || !validToneCurve(o.tone.curve)))
        throw std::invalid_argument("Invalid HDR tone settings");
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_COLOR_VERSION &&
        (!inRange(o.color.vibrance, -100, 100) || !o.color.hsl.valid() || !o.color.grading.valid()))
        throw std::invalid_argument("Invalid HDR color settings");
    const auto& rendition = o.rendition;
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION &&
        (!inRange(rendition.peakLimitEV, 0, 6) || !inRange(rendition.sdrExposureEV, -4, 4) ||
         !inRange(rendition.sdrContrast, -100, 100) || !inRange(rendition.sdrSaturation, -100, 100)))
        throw std::invalid_argument("Invalid HDR rendition settings");
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION && !o.effects.valid())
        throw std::invalid_argument("Invalid HDR photo effects");
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION && !o.detail.valid())
        throw std::invalid_argument("Invalid HDR detail");
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_LOOK_VERSION &&
        (!inRange(o.lookStrength, 0, 2) || (!o.look && o.lookStrength != 0)))
        throw std::invalid_argument("Invalid HDR look strength or resource");
}

void editHDRPixels(ImageData& image, const HDRRenderOptions& options, bool hdr) {
    validateHDRRenderOptions(options);
    validateImage(image);
    edit(image, options, hdr);
}

std::pair<int, int> hdrResizeSize(int width, int height, uint32_t longEdge) {
    if (width <= 0 || height <= 0 || longEdge > 65535) throw std::invalid_argument("Invalid HDR resize size");
    const int edge = std::max(width, height);
    if (!longEdge || longEdge >= uint32_t(edge)) return {width, height};
    const double scale = double(longEdge) / edge;
    return {std::max(1, int(std::lround(width * scale))), std::max(1, int(std::lround(height * scale)))};
}

RGB sampleHDRResize(int x, int y, int width, int height, int outputWidth, int outputHeight,
    const GeometryPixelReader& read) {
    return sampleResize(x, y, width, height, outputWidth, outputHeight, read);
}

} // namespace sony2fuji
