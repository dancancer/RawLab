#include "core/hdr_rendering.h"
#include "core/hdr_look.h"
#include "core/hdr_progress.h"
#include "core/hdr_resample.h"
#include "core/parallel_pixels.h"
#include "core/photo_tone_curve.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <mutex>
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
    if (image.pixels.size() >= 65536) {
        std::atomic<bool> nonfinite{false};
        parallelPixelRanges(image.pixels.size(), [&](size_t begin, size_t end) {
            for (size_t i = begin; i < end; ++i) {
                if (!finite(image.pixels[i])) {
                    nonfinite.store(true, std::memory_order_relaxed);
                    return;
                }
            }
        });
        if (nonfinite.load(std::memory_order_relaxed))
            throw std::invalid_argument("HDR pixels must be finite");
        return;
    }
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
    if (tone.curve.mode == ToneCurveMode::Custom) return ToneCurve(tone.curve);
    if (tone.curveStrength == 0) return {};
    auto config = tone.curve;
    const double offset = tone.curveStrength / 1600.0;
    config.mode = ToneCurveMode::Custom;
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

float editChannelCurve(float value, const ToneCurve& curve) {
    if (!curve.active() || value <= 0) return value;
    const double stops = std::log2(double(value));
    if (stops <= -8 || stops >= 8) return value;
    return static_cast<float>(std::exp2(curve.evaluate((stops + 8) / 16) * 16 - 8));
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

// contentMax 非空且本趟确实全量改写了像素时，回填写出像素的亮度峰值，供调用方融合掉后续独立的
// headroom 全图扫描；返回值表示该趟是否执行（全部滑杆关闭时提前返回，未覆盖像素）。
bool edit(ImageData& image, const HDRRenderOptions& o, bool hdr, float* contentMax = nullptr) {
    const RGB gain = hdrRelativeWhiteBalance(o.temperature, o.tint);
    const float exposure = std::exp2(o.exposureEV);
    const bool colorActive = o.exposureEV != 0 || o.temperature != 6500 || o.tint != 0;
    const bool toneActive = o.contrast != 0 || o.highlights != 0 || o.shadows != 0 || o.saturation != 0;
    const bool useToneV2 = o.processingVersion >= kHdrProcessingToneVersion;
    const auto curve = useToneV2 ? hdrCurve(o.tone) : ToneCurve();
    std::array<ToneCurve, 3> channels;
    if (o.processingVersion >= kHdrProcessingChannelCurvesVersion)
        for (size_t i = 0; i < channels.size(); ++i) channels[i] = ToneCurve(o.tone.channels[i]);
    const bool channelsActive = std::any_of(channels.begin(), channels.end(), [](const auto& value) { return value.active(); });
    const bool advancedToneActive = useToneV2 && (o.tone.blackPoint != 0 || o.tone.whitePoint != 0 || curve.active());
    const bool useColor = o.processingVersion >= kHdrProcessingColorVersion;
    const bool vibranceActive = useColor && o.color.vibrance != 0;
    const bool hslActive = useColor && o.color.hsl.active();
    const bool gradingActive = useColor && o.color.grading.active();
    const auto grading = gradingActive ? colorGradingCoefficients(o.color.grading) : std::array<RGB, 3>{};
    const bool lookActive = o.processingVersion >= kHdrProcessingLookVersion && o.look && o.lookStrength != 0;
    const bool useRendition = o.processingVersion >= kHdrProcessingRenditionVersion;
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
    if (!colorActive && !toneActive && !advancedToneActive && !channelsActive && !vibranceActive && !hslActive && !gradingActive &&
        !lookActive && !limitHDR && !adjustBase) return false;
    std::atomic<bool> overflow{false};
    float fusedMax = -std::numeric_limits<float>::infinity();
    std::mutex fusedMaxMutex;
    parallelPixelRanges(image.pixels.size(), [&](size_t begin, size_t end) {
        float localMax = -std::numeric_limits<float>::infinity();
        for (size_t i = begin; i < end; ++i) {
            auto& p = image.pixels[i];
            if (colorActive) p = {p.r * gain.r * exposure, p.g * gain.g * exposure, p.b * gain.b * exposure};
            if (toneActive) p = hdr ? toneHDR(p, o) : toneSDR(p, o);
            if (advancedToneActive) p = editToneV2(p, o.tone, curve);
            if (channelsActive) p = {editChannelCurve(p.r, channels[0]), editChannelCurve(p.g, channels[1]), editChannelCurve(p.b, channels[2])};
            if (vibranceActive) p = hdrVibrance(p, o.color.vibrance);
            if (hslActive) p = hdrHsl(p, o.color.hsl);
            if (gradingActive) p = hdrGrade(p, grading);
            if (lookActive) p = o.look->apply(p, o.lookStrength);
            if (limitHDR) p = limitHDRLuminance(p, knee, peak - knee);
            if (adjustBase) p = toneSDR({p.r * baseExposure, p.g * baseExposure, p.b * baseExposure}, baseTone);
            if (!finite(p)) overflow.store(true, std::memory_order_relaxed);
            if (contentMax) localMax = std::max(localMax, luminance(p));
        }
        if (contentMax) {
            // max 对有限 float 可交换可结合，归并顺序不改变结果位形；非有限像素由 overflow 抛出。
            std::lock_guard<std::mutex> lock(fusedMaxMutex);
            fusedMax = std::max(fusedMax, localMax);
        }
    });
    if (overflow.load(std::memory_order_relaxed))
        throw std::overflow_error("HDR adjustments exceeded finite float range");
    if (contentMax) *contentMax = fusedMax;
    return true;
}

void resize(ImageData& image, uint32_t longEdge) {
    const int edge = std::max(image.width, image.height);
    if (longEdge == 0 || longEdge >= uint32_t(edge)) return;
    const auto size = hdrResizeSize(image.width, image.height, longEdge);
    image = hdr::resample(image, static_cast<uint32_t>(size.first), static_cast<uint32_t>(size.second));
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
    // 尾段不改变像素值（几何恒等、resize 空操作、无细节/效果）时，headroom 由 edit 单趟顺带采集，
    // 省掉循环后对双平面的独立全图扫描；任一尾段活跃则回退原逐像素扫描，语义逐位不变。
    const uint32_t canvasEdge = uint32_t(std::max(result.hdr.width, result.hdr.height));
    const bool inertLater = !o.geometry.active() && !o.hasDetail() && !o.hasPhotoEffects() &&
        (o.longEdge == 0 || o.longEdge >= canvasEdge);
    float hdrContentMax = 0, sdrContentMax = 0;
    reportHdrProgress(50, 1000);
    const bool hdrRan = edit(result.hdr, o, true, inertLater ? &hdrContentMax : nullptr);
    reportHdrProgress(250, 1000);
    const bool sdrRan = edit(result.sdr, o, false, inertLater ? &sdrContentMax : nullptr);
    reportHdrProgress(450, 1000);
    finishGeometry(result.hdr, o); finishGeometry(result.sdr, o);
    reportHdrProgress(650, 1000);
    finishDetail(result.hdr, o, true);
    finishDetail(result.sdr, o, false);
    reportHdrProgress(850, 1000);
    finishEffects(result.hdr, o, true);
    finishEffects(result.sdr, o, false);
    reportHdrProgress(950, 1000);
    result.renderQuality = o.intent;
    result.isProxy = result.isProxy || o.intent == HDRQuality::Preview;
    if (inertLater && hdrRan) {
        // edit 已逐像素验证非有限并采集峰值；几何恒等保证这些像素就是最终像素。
        result.editedHeadroom = std::max(1.0f, hdrContentMax);
    } else {
        float peak = 1.0f;
        std::atomic<bool> overflow{false};
        std::mutex peakMutex;
        parallelPixelRanges(result.hdr.pixels.size(), [&](size_t begin, size_t end) {
            float localPeak = 1.0f;
            for (size_t i = begin; i < end; ++i) {
                const auto& pixel = result.hdr.pixels[i];
                if (!finite(pixel)) {
                    overflow.store(true, std::memory_order_relaxed);
                    return;
                }
                localPeak = std::max(localPeak, luminance(pixel));
            }
            std::lock_guard<std::mutex> lock(peakMutex);
            peak = std::max(peak, localPeak);
        });
        if (overflow.load(std::memory_order_relaxed)) throw std::overflow_error("HDR geometry exceeded finite float range");
        result.editedHeadroom = peak;
    }
    if (!std::isfinite(result.editedHeadroom)) throw std::overflow_error("HDR headroom exceeded finite float range");
    result.editedSdrHeadroom = inertLater && sdrRan ? std::max(1.0f, sdrContentMax) : 0;
    reportHdrProgress(1000, 1000);
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

namespace {

ImageData extractHDRSubRect(const ImageData& src, uint32_t fullWidth, uint32_t fullHeight,
    const RoiSubRect& rect, uint32_t offsetX, uint32_t offsetY, bool isPreCropped) {
    if (isPreCropped) {
        const int localX0 = rect.x0 - int(offsetX);
        const int localY0 = rect.y0 - int(offsetY);
        const int rw = rect.width();
        const int rh = rect.height();
        if (localX0 < 0 || localY0 < 0 || localX0 + rw > src.width || localY0 + rh > src.height) {
            throw std::invalid_argument("HDR pre-cropped ROI source does not cover required bounds");
        }
        ImageData out(rw, rh);
        parallelRowRanges(rh, rw, [&](int firstRow, int lastRow) {
            for (int y = firstRow; y < lastRow; ++y) {
                std::copy_n(src.pixels.data() + size_t(localY0 + y) * src.width + localX0, rw,
                    out.pixels.data() + size_t(y) * rw);
            }
        });
        return out;
    }

    if (src.width == int(fullWidth) && src.height == int(fullHeight)) {
        const int rw = rect.width();
        const int rh = rect.height();
        ImageData out(rw, rh);
        parallelRowRanges(rh, rw, [&](int firstRow, int lastRow) {
            for (int y = firstRow; y < lastRow; ++y) {
                std::copy_n(src.pixels.data() + size_t(rect.y0 + y) * src.width + rect.x0, rw,
                    out.pixels.data() + size_t(y) * rw);
            }
        });
        return out;
    }

    // Scaled proxy input: sample the exact [rect.x0..rect.x1) x [rect.y0..rect.y1) bounds bilinearly at proxy density.
    const double sxRatio = double(src.width) / double(fullWidth);
    const double syRatio = double(src.height) / double(fullHeight);
    const int targetW = std::max(1, std::min(rect.width(), int(std::lround(rect.width() * sxRatio))));
    const int targetH = std::max(1, std::min(rect.height(), int(std::lround(rect.height() * syRatio))));
    ImageData out(targetW, targetH);
    parallelRowRanges(targetH, targetW, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const double fullY = rect.y0 + (double(y) + 0.5) * rect.height() / double(targetH) - 0.5;
            const double py = std::clamp((fullY + 0.5) * syRatio - 0.5, 0.0, double(src.height - 1));
            const int y0 = int(std::floor(py));
            const int y1 = std::min(src.height - 1, y0 + 1);
            const float wy = float(py - y0);
            for (int x = 0; x < targetW; ++x) {
                const double fullX = rect.x0 + (double(x) + 0.5) * rect.width() / double(targetW) - 0.5;
                const double px = std::clamp((fullX + 0.5) * sxRatio - 0.5, 0.0, double(src.width - 1));
                const int x0 = int(std::floor(px));
                const int x1 = std::min(src.width - 1, x0 + 1);
                const float wx = float(px - x0);
                const RGB& p00 = src.at(x0, y0);
                const RGB& p10 = src.at(x1, y0);
                const RGB& p01 = src.at(x0, y1);
                const RGB& p11 = src.at(x1, y1);
                auto lerp = [](float a, float b, float t) { return a + (b - a) * t; };
                const RGB top{lerp(p00.r, p10.r, wx), lerp(p00.g, p10.g, wx), lerp(p00.b, p10.b, wx)};
                const RGB bot{lerp(p01.r, p11.r, wx), lerp(p01.g, p11.g, wx), lerp(p01.b, p11.b, wx)};
                out.at(x, y) = {lerp(top.r, bot.r, wy), lerp(top.g, bot.g, wy), lerp(top.b, bot.b, wy)};
            }
        }
    });
    return out;
}

double computeGlobalVeilROI(const ImageData& fullOrProxy, const ImageData& paddedPostEdit,
    const HDRRenderOptions& options, bool hdr, double peak, bool isPreCropped) {
    if (options.detail.dehaze == 0) return 0.0;
    if (isPreCropped || fullOrProxy.width <= 0 || fullOrProxy.height <= 0) {
        return planHDRDetail(paddedPostEdit.width, paddedPostEdit.height, options.detail, peak,
            [&](int x, int y) { return paddedPostEdit.at(x, y); }).veil;
    }
    const int step = std::max(1, (std::max(fullOrProxy.width, fullOrProxy.height) + 127) / 128);
    const int sw = std::max(1, (fullOrProxy.width + step - 1) / step);
    const int sh = std::max(1, (fullOrProxy.height + step - 1) / step);
    ImageData sample(sw, sh);
    for (int y = 0; y < sh; ++y) {
        for (int x = 0; x < sw; ++x) {
            sample.at(x, y) = fullOrProxy.at(std::min(x * step, fullOrProxy.width - 1),
                std::min(y * step, fullOrProxy.height - 1));
        }
    }
    edit(sample, options, hdr);
    if (options.geometry.active()) {
        ImageData cropped = sample;
        if (applyGeometry(cropped, options.geometry) == ErrorCode::Success &&
            cropped.width > 0 && cropped.height > 0) {
            sample = std::move(cropped);
        }
    }
    return planHDRDetail(sample.width, sample.height, options.detail, peak,
        [&](int x, int y) { return sample.at(x, y); }).veil;
}

void finishDetailROI(ImageData& padded, const ImageData& fullOrProxy, const HDRRenderOptions& options,
    const HDRRoiSourceBounds& bounds, bool hdr, bool isPreCropped) {
    const int outW = bounds.plan.outputWidth;
    const int outH = bounds.plan.outputHeight;
    if (options.hasDetail()) {
        const double peak = hdr && options.rendition.peakLimitEV > 0
            ? std::exp2(double(options.rendition.peakLimitEV)) : 0;
        const double veil = computeGlobalVeilROI(fullOrProxy, padded, options, hdr, peak, isPreCropped);
        const HDRDetailPlan detailPlan{options.detail, padded.width, padded.height,
            bounds.detailHalo, veil, peak};
        ImageData band(padded.width, outH);
        renderHDRDetailBand(detailPlan, padded.pixels.data(), 0, padded.height,
            band.pixels.data(), bounds.cropTop, outH);
        padded = ImageData(outW, outH);
        parallelRowRanges(outH, outW, [&](int firstRow, int lastRow) {
            for (int y = firstRow; y < lastRow; ++y) {
                std::copy_n(band.pixels.data() + size_t(y) * band.width + bounds.cropLeft, outW,
                    padded.pixels.data() + size_t(y) * outW);
            }
        });
    } else if (padded.width != outW || padded.height != outH || bounds.cropLeft != 0 || bounds.cropTop != 0) {
        ImageData cropped(outW, outH);
        parallelRowRanges(outH, outW, [&](int firstRow, int lastRow) {
            for (int y = firstRow; y < lastRow; ++y) {
                std::copy_n(padded.pixels.data() + size_t(bounds.cropTop + y) * padded.width + bounds.cropLeft,
                    outW, cropped.pixels.data() + size_t(y) * outW);
            }
        });
        padded = std::move(cropped);
    }
}

void finishEffectsROI(ImageData& image, const HDRRenderOptions& options,
    const HDRRoiSourceBounds& bounds, bool hdr) {
    if (!options.hasPhotoEffects()) return;
    const double scaleX = double(bounds.plan.outputWidth) / double(bounds.plan.nativeWidth());
    const double scaleY = double(bounds.plan.outputHeight) / double(bounds.plan.nativeHeight());
    const int offsetX = int(std::lround(bounds.plan.ox0 * scaleX));
    const int offsetY = int(std::lround(bounds.plan.oy0 * scaleY));
    const PhotoEffectSampler sampler(options.effects, bounds.fullScaledWidth, bounds.fullScaledHeight);
    const double peak = hdr && options.rendition.peakLimitEV > 0
        ? std::exp2(double(options.rendition.peakLimitEV)) : 0;
    std::atomic<bool> overflow{false};
    parallelRowRanges(image.height, image.width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const int gy = std::clamp(offsetY + y, 0, bounds.fullScaledHeight - 1);
            for (int x = 0; x < image.width; ++x) {
                const int gx = std::clamp(offsetX + x, 0, bounds.fullScaledWidth - 1);
                auto& pixel = image.at(x, y);
                pixel = sampler.applyExtendedLinear(pixel, gx, gy, peak);
                if (!finite(pixel)) overflow.store(true, std::memory_order_relaxed);
            }
        }
    });
    if (overflow.load(std::memory_order_relaxed)) {
        throw std::overflow_error("HDR effects exceeded finite float range");
    }
}

} // namespace

ImageData extractHDRPlaneForROI(const ImageData& src, uint32_t fullWidth, uint32_t fullHeight,
    const RoiSubRect& rect, uint32_t offsetX, uint32_t offsetY, bool isPreCropped) {
    return extractHDRSubRect(src, fullWidth, fullHeight, rect, offsetX, offsetY, isPreCropped);
}

HDRRoiSourceBounds computeHDRRoiSourceBounds(uint32_t fullSourceWidth, uint32_t fullSourceHeight,
    const HDRRenderOptions& options, const HDRRoiSpec& roi) {
    validateHDRRenderOptions(options);
    if (!fullSourceWidth || !fullSourceHeight ||
        uint64_t(fullSourceWidth) * fullSourceHeight > pixelLimit) {
        throw std::invalid_argument("Invalid HDR ROI source dimensions");
    }
    const auto nativeSize = geometryOutputSize(int(fullSourceWidth), int(fullSourceHeight), options.geometry);
    if (nativeSize.first <= 0 || nativeSize.second <= 0) {
        throw std::invalid_argument("Invalid HDR geometry");
    }
    HDRRoiSourceBounds out;
    out.plan = computeOutputRoiPlan(nativeSize.first, nativeSize.second,
        roi.normX0, roi.normY0, roi.normX1, roi.normY1, roi.maxOutputLongEdge);
    if (!out.plan.valid()) {
        throw std::invalid_argument("Invalid HDR ROI normalized bounds");
    }
    const double scaleX = double(out.plan.outputWidth) / double(out.plan.nativeWidth());
    const double scaleY = double(out.plan.outputHeight) / double(out.plan.nativeHeight());
    const double scale = std::min(1.0, std::min(scaleX, scaleY));
    out.fullScaledWidth = std::max(out.plan.outputWidth, int(std::lround(out.plan.fullNativeWidth * scaleX)));
    out.fullScaledHeight = std::max(out.plan.outputHeight, int(std::lround(out.plan.fullNativeHeight * scaleY)));
    out.detailHalo = options.hasDetail() ? options.detail.halo(out.fullScaledWidth, out.fullScaledHeight) : 0;
    const int nativeHalo = out.detailHalo > 0 ? int(std::ceil(double(out.detailHalo) / std::max(scale, 1e-4))) : 0;
    out.paddedOx0 = std::max(0, out.plan.ox0 - nativeHalo);
    out.paddedOy0 = std::max(0, out.plan.oy0 - nativeHalo);
    out.paddedOx1 = std::min(out.plan.fullNativeWidth, out.plan.ox1 + nativeHalo);
    out.paddedOy1 = std::min(out.plan.fullNativeHeight, out.plan.oy1 + nativeHalo);

    if (out.plan.outputWidth == out.plan.nativeWidth() && out.plan.outputHeight == out.plan.nativeHeight()) {
        out.cropLeft = out.plan.ox0 - out.paddedOx0;
        out.cropTop = out.plan.oy0 - out.paddedOy0;
        out.paddedOutWidth = out.paddedOx1 - out.paddedOx0;
        out.paddedOutHeight = out.paddedOy1 - out.paddedOy0;
    } else {
        const int padLeft = std::max(0, int(std::lround(double(out.plan.ox0 - out.paddedOx0) * scaleX)));
        const int padTop = std::max(0, int(std::lround(double(out.plan.oy0 - out.paddedOy0) * scaleY)));
        const int padRight = std::max(0, int(std::lround(double(out.paddedOx1 - out.plan.ox1) * scaleX)));
        const int padBottom = std::max(0, int(std::lround(double(out.paddedOy1 - out.plan.oy1) * scaleY)));
        out.cropLeft = padLeft;
        out.cropTop = padTop;
        out.paddedOutWidth = padLeft + out.plan.outputWidth + padRight;
        out.paddedOutHeight = padTop + out.plan.outputHeight + padBottom;
    }
    out.sourceRect = computeGeometrySourceBounds(int(fullSourceWidth), int(fullSourceHeight),
        options.geometry, out.paddedOx0, out.paddedOy0, out.paddedOx1, out.paddedOy1, 2);
    if (out.sourceRect.empty()) {
        throw std::invalid_argument("Invalid HDR ROI source bounds");
    }
    return out;
}

HDRImagePair renderHDRSubRectROI(ImageData subHdr, ImageData subSdr,
    uint32_t fullSourceWidth, uint32_t fullSourceHeight,
    float sourceHeadroom, uint64_t decodeRevision, HDRQuality sourceQuality,
    const HDRRenderOptions& o, const HDRRoiSpec& roi,
    const HDRRoiSourceBounds& bounds,
    const ImageData* veilSourceHdr, const ImageData* veilSourceSdr) {
    validateImage(subHdr);
    validateImage(subSdr);
    validateHDRRenderOptions(o);
    if ((roi.baseContentHeadroom != 0.0f &&
            (!std::isfinite(roi.baseContentHeadroom) || roi.baseContentHeadroom < 1.0f))) {
        throw std::invalid_argument("Invalid HDR ROI base headroom");
    }

    HDRImagePair result;
    result.nativeWidth = fullSourceWidth;
    result.nativeHeight = fullSourceHeight;
    result.outputNativeWidth = uint32_t(bounds.plan.fullNativeWidth);
    result.outputNativeHeight = uint32_t(bounds.plan.fullNativeHeight);
    result.sourceQuality = sourceQuality;
    result.renderQuality = HDRQuality::Preview;
    result.decodeRevision = decodeRevision;
    result.isProxy = true;
    result.sourceHeadroom = sourceHeadroom;

    edit(subHdr, o, true);
    edit(subSdr, o, false);

    const OutputRoiPlan paddedPlan{
        bounds.plan.fullNativeWidth, bounds.plan.fullNativeHeight,
        bounds.paddedOx0, bounds.paddedOy0, bounds.paddedOx1, bounds.paddedOy1,
        bounds.paddedOutWidth, bounds.paddedOutHeight
    };
    subHdr = applyGeometryROI(subHdr, bounds.sourceRect, int(fullSourceWidth), int(fullSourceHeight), o.geometry, paddedPlan);
    subSdr = applyGeometryROI(subSdr, bounds.sourceRect, int(fullSourceWidth), int(fullSourceHeight), o.geometry, paddedPlan);
    if (subHdr.width != bounds.paddedOutWidth || subHdr.height != bounds.paddedOutHeight ||
        subSdr.width != bounds.paddedOutWidth || subSdr.height != bounds.paddedOutHeight) {
        throw std::invalid_argument("Invalid HDR ROI geometry output");
    }

    const ImageData emptyVeil;
    finishDetailROI(subHdr, veilSourceHdr ? *veilSourceHdr : emptyVeil, o, bounds, true, veilSourceHdr == nullptr);
    finishDetailROI(subSdr, veilSourceSdr ? *veilSourceSdr : emptyVeil, o, bounds, false, veilSourceSdr == nullptr);
    finishEffectsROI(subHdr, o, bounds, true);
    finishEffectsROI(subSdr, o, bounds, false);

    float measuredPeak = 1.0f;
    for (const auto& pixel : subHdr.pixels) {
        if (!finite(pixel)) throw std::overflow_error("HDR ROI exceeded finite float range");
        measuredPeak = std::max(measuredPeak, luminance(pixel));
    }
    for (const auto& pixel : subSdr.pixels) {
        if (!finite(pixel)) throw std::overflow_error("SDR ROI exceeded finite float range");
    }
    if (!std::isfinite(measuredPeak)) throw std::overflow_error("HDR headroom exceeded finite float range");

    result.hdr = std::move(subHdr);
    result.sdr = std::move(subSdr);
    result.editedHeadroom = roi.baseContentHeadroom >= 1.0f ? roi.baseContentHeadroom : measuredPeak;
    result.editedSdrHeadroom = 0.0f;
    return result;
}

HDRImagePair renderHDRPairROI(const HDRImagePair& source, const HDRRenderOptions& o,
    const HDRRoiSpec& roi, HDRRoiSourceBounds* outBounds) {
    validateImage(source.hdr);
    validateImage(source.sdr);
    validateHDRRenderOptions(o);
    if (source.hdr.width != source.sdr.width || source.hdr.height != source.sdr.height ||
        !std::isfinite(source.sourceHeadroom) || (source.sourceHeadroom != 0 && source.sourceHeadroom < 1)) {
        throw std::invalid_argument("Invalid HDR ROI source pair or headroom");
    }
    const bool isPreCropped = roi.fullSourceWidth > 0 && roi.fullSourceHeight > 0;
    const uint32_t fullSourceWidth = isPreCropped
        ? roi.fullSourceWidth
        : (source.nativeWidth ? source.nativeWidth : uint32_t(source.hdr.width));
    const uint32_t fullSourceHeight = isPreCropped
        ? roi.fullSourceHeight
        : (source.nativeHeight ? source.nativeHeight : uint32_t(source.hdr.height));
    const auto bounds = computeHDRRoiSourceBounds(fullSourceWidth, fullSourceHeight, o, roi);

    ImageData subHdr = extractHDRSubRect(source.hdr, fullSourceWidth, fullSourceHeight,
        bounds.sourceRect, roi.sourceOffsetX, roi.sourceOffsetY, isPreCropped);
    ImageData subSdr = extractHDRSubRect(source.sdr, fullSourceWidth, fullSourceHeight,
        bounds.sourceRect, roi.sourceOffsetX, roi.sourceOffsetY, isPreCropped);

    auto result = renderHDRSubRectROI(std::move(subHdr), std::move(subSdr),
        fullSourceWidth, fullSourceHeight, source.sourceHeadroom,
        source.decodeRevision, source.sourceQuality, o, roi, bounds,
        isPreCropped ? nullptr : &source.hdr, isPreCropped ? nullptr : &source.sdr);
    if (outBounds) *outBounds = bounds;
    return result;
}

ImageData renderHDRHslProbe(ImageData image, const HDRRenderOptions& options) {
    validateHDRRenderOptions(options);
    validateImage(image);
    auto beforeColor = options;
    beforeColor.color.hsl = {};
    beforeColor.color.grading = {};
    beforeColor.rendition = {};
    beforeColor.look.reset();
    beforeColor.lookStrength = 0;
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
    const bool useToneV2 = o.processingVersion >= kHdrProcessingToneVersion;
    if (o.processingVersion < kHdrProcessingVersion || o.processingVersion > kHdrProcessingChannelCurvesVersion ||
        !inRange(o.exposureEV, -4, 4) || !inRange(o.temperature, 2000, 50000) ||
        !inRange(o.tint, -150, 150) || !inRange(o.contrast, -100, 100) || !inRange(o.highlights, -100, 100) ||
        !inRange(o.shadows, -100, 100) || !inRange(o.saturation, -100, 100) ||
        !o.geometry.valid() || o.longEdge > 65535 ||
        (o.intent != HDRQuality::Preview && o.intent != HDRQuality::Final))
        throw std::invalid_argument("Invalid HDR render settings");
    if (useToneV2 && (!inRange(o.tone.blackPoint, -100, 100) || !inRange(o.tone.whitePoint, -100, 100) ||
        !inRange(o.tone.curveStrength, -100, 100) || !validToneCurve(o.tone.curve)))
        throw std::invalid_argument("Invalid HDR tone settings");
    if (o.processingVersion >= kHdrProcessingChannelCurvesVersion &&
        !std::all_of(o.tone.channels.begin(), o.tone.channels.end(), validToneCurve))
        throw std::invalid_argument("Invalid HDR channel curves");
    if (o.processingVersion >= kHdrProcessingColorVersion &&
        (!inRange(o.color.vibrance, -100, 100) || !o.color.hsl.valid() || !o.color.grading.valid()))
        throw std::invalid_argument("Invalid HDR color settings");
    const auto& rendition = o.rendition;
    if (o.processingVersion >= kHdrProcessingRenditionVersion &&
        (!inRange(rendition.peakLimitEV, 0, 6) || !inRange(rendition.sdrExposureEV, -4, 4) ||
         !inRange(rendition.sdrContrast, -100, 100) || !inRange(rendition.sdrSaturation, -100, 100)))
        throw std::invalid_argument("Invalid HDR rendition settings");
    if (o.processingVersion >= kHdrProcessingEffectsVersion && !o.effects.valid())
        throw std::invalid_argument("Invalid HDR photo effects");
    if (o.processingVersion >= kHdrProcessingDetailVersion && !o.detail.valid())
        throw std::invalid_argument("Invalid HDR detail");
    if (o.processingVersion >= kHdrProcessingLookVersion &&
        (!inRange(o.lookStrength, 0, 2) || (!o.look && o.lookStrength != 0)))
        throw std::invalid_argument("Invalid HDR look strength or resource");
}

bool editHDRPixels(ImageData& image, const HDRRenderOptions& options, bool hdr, float* contentMax) {
    validateHDRRenderOptions(options);
    validateImage(image);
    const bool ran = edit(image, options, hdr, contentMax);
    if (!ran && contentMax) {
        float peak = 0.0f;
        std::mutex peakMutex;
        parallelPixelRanges(image.pixels.size(), [&](size_t begin, size_t end) {
            float localPeak = -std::numeric_limits<float>::infinity();
            for (size_t i = begin; i < end; ++i) {
                localPeak = std::max(localPeak, luminance(image.pixels[i]));
            }
            std::lock_guard<std::mutex> lock(peakMutex);
            peak = std::max(peak, localPeak);
        });
        *contentMax = peak;
    }
    return ran;
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
    return hdr::sampleResample(x, y, width, height, outputWidth, outputHeight, read);
}

} // namespace sony2fuji
