#include "core/photo_pipeline_stages.h"

#include "core/chroma_denoise.h"
#include "core/lut_compatibility.h"
#include "core/lut_interpolation.h"
#include "core/parallel_pixels.h"
#include "core/photo_atmosphere.h"
#include "core/photo_basic_controls_v3.h"
#include "core/photo_bw_mixer.h"
#include "core/photo_calibration.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_defringe.h"
#include "core/photo_effects.h"
#include "core/photo_film_optics.h"
#include "core/photo_lut.h"
#include "core/photo_lut_contract.h"
#include "core/photo_point_color.h"
#include "core/photo_rendering.h"
#include "core/photo_selective_color.h"
#include "core/processing_cancellation.h"
#include "gpu/photo_tone_curve_shader.h"
#include "gpu/photo_tone_shader.h"
#include "sony2fuji/sony2fuji.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <vector>

namespace sony2fuji {
namespace {

#define TCV_FN inline
#define TCV_RGB sony2fuji::RGB
#define TCV_RGB3(r, g, b) sony2fuji::RGB(static_cast<float>(r), static_cast<float>(g), static_cast<float>(b))
#define TCV_MAX(a, b) std::max<float>(static_cast<float>(a), static_cast<float>(b))
#define TCV_MIN(a, b) std::min<float>(static_cast<float>(a), static_cast<float>(b))
#define TCV_CLAMP01(x) std::max<float>(0.0f, std::min<float>(1.0f, static_cast<float>(x)))
#define TCV_SRGB_TO_LINEAR(x) sony2fuji::GammaConverter::removeSRGBGamma(static_cast<float>(x))
#define TCV_LINEAR_TO_SRGB(x) sony2fuji::GammaConverter::applySRGBGamma(static_cast<float>(x))
RAWLAB_TONE_CURVE_LUMINOSITY_BODY
#undef TCV_FN
#undef TCV_RGB
#undef TCV_RGB3
#undef TCV_MAX
#undef TCV_MIN
#undef TCV_CLAMP01
#undef TCV_SRGB_TO_LINEAR
#undef TCV_LINEAR_TO_SRGB

float signedPow(float value, float power) {
    float sign = value >= 0.0f ? 1.0f : -1.0f;
    return sign * std::pow(std::abs(value), power);
}

float lerpFloat(float a, float b, float t) {
    return a + (b - a) * t;
}

RGB lerpRGB(const RGB& a, const RGB& b, float t) {
    return RGB(
        lerpFloat(a.r, b.r, t),
        lerpFloat(a.g, b.g, t),
        lerpFloat(a.b, b.b, t)
    );
}

struct ToneCurvePoints {
    float p1;
    float p2;
    float p3;
};

ToneCurvePoints buildToneCurve(float toneCurve) {
    float curveStrength = signedPow(toneCurve, 1.2f);
    float lift = curveStrength * 0.2f;
    float mid = curveStrength * 0.05f;

    ToneCurvePoints points;
    points.p1 = clamp01(0.25f - lift);
    points.p2 = clamp01(0.5f + mid);
    points.p3 = clamp01(0.75f + lift);
    return points;
}

float applyToneCurve(float x, const ToneCurvePoints& curve) {
    float value = clamp01(x);
    if (value <= 0.25f) {
        return lerpFloat(0.0f, curve.p1, value / 0.25f);
    }
    if (value <= 0.5f) {
        return lerpFloat(curve.p1, curve.p2, (value - 0.25f) / 0.25f);
    }
    if (value <= 0.75f) {
        return lerpFloat(curve.p2, curve.p3, (value - 0.5f) / 0.25f);
    }
    return lerpFloat(curve.p3, 1.0f, (value - 0.75f) / 0.25f);
}

RGB normalizeWhiteBalance(float r, float g, float b) {
    float maxValue = std::max(r, std::max(g, b));
    if (maxValue <= 0.0f) {
        return RGB(1.0f, 1.0f, 1.0f);
    }
    return RGB(r / maxValue, g / maxValue, b / maxValue);
}

RGB temperatureToRGB(float temperature) {
    float temp = clampFloat(temperature, 1000.0f, 40000.0f) / 100.0f;
    float r;
    float g;
    float b;

    if (temp <= 66.0f) {
        r = 1.0f;
        g = clamp01(0.3900816f * std::log(temp) - 0.6318414f);
        if (temp <= 19.0f) {
            b = 0.0f;
        } else {
            b = clamp01(0.5432068f * std::log(temp - 10.0f) - 1.1962541f);
        }
    } else {
        r = clamp01(1.2929362f * std::pow(temp - 60.0f, -0.1332048f));
        g = clamp01(1.1298909f * std::pow(temp - 60.0f, -0.0755148f));
        b = 1.0f;
    }

    return normalizeWhiteBalance(r, g, b);
}

RGB applyTint(const RGB& base, float tint) {
    float t = clampFloat(tint / 100.0f, -1.0f, 1.0f);
    float g = base.g * (1.0f + t * 0.1f);
    return normalizeWhiteBalance(base.r, g, base.b);
}

void applyContrastSaturation(RGB& pixel, float contrast, float saturation) {
    pixel.r = (pixel.r - 0.5f) * contrast + 0.5f;
    pixel.g = (pixel.g - 0.5f) * contrast + 0.5f;
    pixel.b = (pixel.b - 0.5f) * contrast + 0.5f;

    float l = detail::hsLuminance(pixel);
    pixel.r = l + (pixel.r - l) * saturation;
    pixel.g = l + (pixel.g - l) * saturation;
    pixel.b = l + (pixel.b - l) * saturation;
}

// 保存两行原像素，避免已写回的行进入下一行的 3x3 邻域。
template <typename Apply>
void applyBlurredDetail(ImageData& image, Apply apply) {
    const int width = image.width, height = image.height;
    if (width <= 0 || height <= 0) return;
    std::vector<RGB> previous(width), current(width);
    std::copy_n(image.pixels.data(), width, previous.data());
    const auto sumRow = [](const RGB* row, int a, int b, int c) {
        return RGB(row[a].r + row[b].r + row[c].r,
            row[a].g + row[b].g + row[c].g, row[a].b + row[b].b + row[c].b);
    };
    for (int y = 0; y < height; ++y) {
        checkProcessingCancellation();
        auto* destination = image.pixels.data() + size_t(y) * width;
        std::copy_n(destination, width, current.data());
        const auto* next = y + 1 < height ? destination + width : current.data();
        for (int x = 0; x < width; ++x) {
            const int a = std::max(0, x - 1), c = std::min(width - 1, x + 1);
            auto sum = sumRow(previous.data(), a, x, c);
            const auto middle = sumRow(current.data(), a, x, c);
            const auto bottom = sumRow(next, a, x, c);
            sum.r += middle.r + bottom.r;
            sum.g += middle.g + bottom.g;
            sum.b += middle.b + bottom.b;
            destination[x] = apply(current[x], RGB(sum.r / 9.0f, sum.g / 9.0f, sum.b / 9.0f));
        }
        previous.swap(current);
    }
}

void applyNoiseReduction(ImageData& image, float amount) {
    const float strength = clampFloat(amount, 0.0f, 1.0f);
    if (strength <= 0.0f) return;
    applyBlurredDetail(image, [strength](const auto& current, const auto& blur) {
        return lerpRGB(current, blur, strength * 0.4f);
    });
}

void applySharpening(ImageData& image, float amount) {
    const float strength = clampFloat(amount, 0.0f, 2.0f);
    if (strength <= 0.0f) return;
    applyBlurredDetail(image, [strength](const auto& current, const auto& blur) {
        return RGB(clamp01(current.r + strength * (current.r - blur.r)),
            clamp01(current.g + strength * (current.g - blur.g)),
            clamp01(current.b + strength * (current.b - blur.b)));
    });
}

bool isLutDiagnosticsEnabled() {
    const char* value = std::getenv("SONY2FUJI_LUT_DIAG");
    return value != nullptr && value[0] != '\0';
}

void logFLog2Diagnostics(const GammaConverter::FLog2Diagnostics& diagnostics) {
    std::fprintf(stderr,
        "F-Log2 diagnostics: min=%f max=%f scale=%f offset=%f neg=%zu over=%zu\n",
        diagnostics.min_linear, diagnostics.max_linear, diagnostics.scale, diagnostics.offset,
        diagnostics.negative_pixels, diagnostics.over_pixels);
}

void applyFLog2Encoding(ImageData& image, bool clampOnly,
    GammaConverter::FLog2Diagnostics* total = nullptr) {
    GammaConverter::FLog2Options options;
    options.normalizeToRange = !clampOnly;
    options.clampOnly = clampOnly;
    options.enableDiagnostics = isLutDiagnosticsEnabled();

    GammaConverter::FLog2Diagnostics diagnostics =
        GammaConverter::applyFLog2ToImage(image, options);
    if (options.enableDiagnostics) {
        if (total) {
            total->min_linear = std::min(total->min_linear, diagnostics.min_linear);
            total->max_linear = std::max(total->max_linear, diagnostics.max_linear);
            total->negative_pixels += diagnostics.negative_pixels;
            total->over_pixels += diagnostics.over_pixels;
        } else logFLog2Diagnostics(diagnostics);
    }
}

} // namespace

RGB whiteBalanceForTempTint(float temperature, float tint) {
    if (temperature <= 0.0f) {
        return RGB(1.0f, 1.0f, 1.0f);
    }
    return applyTint(temperatureToRGB(temperature), tint);
}

void applyExposureAndWhiteBalance(RGB& pixel, float exposureScale, const RGB& wb) {
    pixel.r *= exposureScale * wb.r;
    pixel.g *= exposureScale * wb.g;
    pixel.b *= exposureScale * wb.b;
}

RGB sampleBilinear(const ImageData& image, double x, double y) {
    const double clampedX = std::clamp(x, 0.0, static_cast<double>(image.width - 1));
    const double clampedY = std::clamp(y, 0.0, static_cast<double>(image.height - 1));
    const int x0 = std::clamp(static_cast<int>(std::floor(clampedX)), 0, image.width - 1);
    const int y0 = std::clamp(static_cast<int>(std::floor(clampedY)), 0, image.height - 1);
    const int x1 = x0 < image.width - 1 ? x0 + 1 : image.width - 1;
    const int y1 = y0 < image.height - 1 ? y0 + 1 : image.height - 1;

    const float tx = static_cast<float>(clampedX - static_cast<double>(x0));
    const float ty = static_cast<float>(clampedY - static_cast<double>(y0));

    const RGB& c00 = image.at(x0, y0);
    const RGB& c10 = image.at(x1, y0);
    const RGB& c01 = image.at(x0, y1);
    const RGB& c11 = image.at(x1, y1);

    RGB cx0 = lerpRGB(c00, c10, tx);
    RGB cx1 = lerpRGB(c01, c11, tx);

    return lerpRGB(cx0, cx1, ty);
}

ImageData resizeBilinear(
    const ImageData& source,
    uint32_t targetWidth,
    uint32_t targetHeight
) {
    ImageData output(static_cast<int>(targetWidth), static_cast<int>(targetHeight));

    if (source.width <= 0 || source.height <= 0 || output.width <= 0 || output.height <= 0) {
        return output;
    }

    const double scaleX = (targetWidth == 1)
        ? 0.0
        : static_cast<double>(source.width - 1) / static_cast<double>(targetWidth - 1);
    const double scaleY = (targetHeight == 1)
        ? 0.0
        : static_cast<double>(source.height - 1) / static_cast<double>(targetHeight - 1);

    parallelRowRanges(static_cast<int>(targetHeight), static_cast<int>(targetWidth),
        [&](int firstRow, int lastRow) {
            for (int y = firstRow; y < lastRow; ++y) {
                const double srcY = static_cast<double>(y) * scaleY;
                for (uint32_t x = 0; x < targetWidth; ++x) {
                    const double srcX = static_cast<double>(x) * scaleX;
                    output.pixels[static_cast<size_t>(y) * targetWidth + x] = sampleBilinear(source, srcX, srcY);
                }
            }
        });

    return output;
}

void applyPostLookStages(
    ImageData& image,
    const RenderParams& params,
    const ToneControlsOptions& toneControls,
    const HslOptions& hsl,
    const ColorGradingOptions& colorGrading,
    const std::array<ToneCurve, 3>& channels,
    bool basicV3,
    bool applyHslAndGrading,
    const BwMixerOptions* repeatBwAfterBlackWhite
) {
    const auto& customCurve = params.customCurve;
    const ToneCurveParametric parametric(params.parametricCurve);
    const bool useCurve = params.toneCurve != 0.0f;
    const bool masterActive = parametric.active() || customCurve.active() || useCurve;
    const bool channelsActive = std::any_of(channels.begin(), channels.end(),
        [](const auto& curve) { return curve.active(); });
    const bool toneActive = params.needsToneAdjustments() || masterActive || channelsActive;
    const BasicBlackWhiteV3Prepared bwV3(basicV3 ? toneControls : ToneControlsOptions{});
    const bool bwLegacyActive = !basicV3 && (toneControls.blackPoint != 0.0f || toneControls.whitePoint != 0.0f);
    const bool bwMixerActive = params.bw.active();
    const bool repeatBwActive = repeatBwAfterBlackWhite && repeatBwAfterBlackWhite->active();
    const bool vibranceActive = toneControls.vibrance != 0.0f;
    const bool hslActive = applyHslAndGrading && hsl.active();
    const bool pointColorActive = applyHslAndGrading && params.pointColor.active();
    const bool selectiveColorActive = applyHslAndGrading && params.selectiveColor.active();
    const bool gradingActive = applyHslAndGrading && colorGrading.active();
    if (!bwMixerActive && !bwV3.active && !bwLegacyActive && !repeatBwActive && !toneActive && !vibranceActive &&
        !hslActive && !pointColorActive && !selectiveColorActive && !gradingActive) {
        return;
    }

    const float contrast = clampFloat(params.contrast, 0.0f, 2.0f);
    const float saturation = clampFloat(params.saturation, 0.0f, 2.0f);
    const float highlights = clampFloat(params.highlights, -1.0f, 1.0f);
    const float shadows = clampFloat(params.shadows, -1.0f, 1.0f);
    const ToneCurvePoints curve = buildToneCurve(params.toneCurve);
    const BasicContrastV3Lut contrastLut((toneActive && basicV3) ? (contrast - 1.0f) : 0.0f);
    const ColorGradingShaderParams gradingParams = gradingActive ? colorGradingParameters(colorGrading) : ColorGradingShaderParams{};

    auto evalMaster = [&](float v) -> float {
        if (parametric.active()) {
            v = static_cast<float>(parametric.evaluate(v));
        }
        if (customCurve.active()) {
            return static_cast<float>(customCurve.evaluate(v));
        }
        if (useCurve) {
            return applyToneCurve(v, curve);
        }
        return v;
    };
    const float y0Linear = (masterActive && params.curveApplyToLuminosity)
        ? GammaConverter::removeSRGBGamma(evalMaster(0.0f))
        : 0.0f;

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t index = first; index < last; ++index) {
            RGB pixel = image.pixels[index];
            if (bwMixerActive) {
                pixel = applyBwMixerPixel(pixel, params.bw);
            }
            if (basicV3) {
                if (bwV3.active) pixel = bwV3.apply(pixel);
            } else if (bwLegacyActive) {
                pixel = applyBlackWhite(pixel, toneControls);
            }
            if (repeatBwActive) {
                pixel = applyBwMixerPixel(pixel, *repeatBwAfterBlackWhite);
            }
            if (toneActive) {
                if (highlights != 0.0f || shadows != 0.0f) {
                    pixel = detail::hsApplyHighlightsShadows(pixel, highlights, shadows);
                }
                if (masterActive) {
                    if (params.curveApplyToLuminosity) {
                        const RGB pL(
                            GammaConverter::removeSRGBGamma(pixel.r),
                            GammaConverter::removeSRGBGamma(pixel.g),
                            GammaConverter::removeSRGBGamma(pixel.b)
                        );
                        const float Y = tcLuminosityLinearY(pL);
                        const float u = GammaConverter::applySRGBGamma(std::max(0.0f, Y));
                        const float uPrime = evalMaster(u);
                        pixel = tcLuminosityFinish(pL, Y, uPrime, y0Linear);
                    } else {
                        pixel.r = evalMaster(pixel.r);
                        pixel.g = evalMaster(pixel.g);
                        pixel.b = evalMaster(pixel.b);
                    }
                }
                if (channelsActive) {
                    if (channels[0].active()) pixel.r = static_cast<float>(channels[0].evaluate(pixel.r));
                    if (channels[1].active()) pixel.g = static_cast<float>(channels[1].evaluate(pixel.g));
                    if (channels[2].active()) pixel.b = static_cast<float>(channels[2].evaluate(pixel.b));
                }
                if (basicV3 && contrastLut.active) {
                    pixel.r = contrastLut.apply(pixel.r);
                    pixel.g = contrastLut.apply(pixel.g);
                    pixel.b = contrastLut.apply(pixel.b);
                }
                if ((!basicV3 && contrast != 1.0f) || saturation != 1.0f) {
                    applyContrastSaturation(pixel, basicV3 ? 1.f : contrast, saturation);
                }
            }
            if (vibranceActive) {
                pixel = basicV3 ? basicVibranceV3(pixel, toneControls.vibrance) : applyVibrance(pixel, toneControls);
            }
            if (hslActive) {
                pixel = applyHsl(pixel, hsl);
            }
            if (pointColorActive) {
                pixel = applyPointColorPixel(pixel, params.pointColor);
            }
            if (selectiveColorActive) {
                pixel = applySelectiveColorPixel(pixel, params.selectiveColor);
            }
            if (gradingActive) {
                pixel = applyColorGradingParameters(pixel, gradingParams);
            }
            image.pixels[index] = pixel;
        }
    });
}

void applyDetailAdjustments(
    ImageData& image,
    float noiseReduction,
    float sharpening,
    float clarity,
    int sourceWidth,
    int sourceHeight,
    ProcessingVersion version,
    const ClarityField* clarityField,
    const SubRectMap& roiMap,
    float texture,
    const SharpenV2Options& sharpenV2,
    int textureSourceWidth,
    int textureSourceHeight,
    const FilmOpticsOptions& filmOptics,
    const FilmOpticsField* filmOpticsField,
    const DetailGuideFields* guideFields
) {
    // 引导图只为 ROI 瓦片构建分析场，不做降噪和锐化。
    if (noiseReduction > 0.0f && !guideFields) {
        applyNoiseReduction(image, noiseReduction);
    }
    if (guideFields) {
        if (clarity != 0.0f) {
            *guideFields->clarity = buildClarityField(image, sourceWidth, sourceHeight, version);
        }
        if (!filmOptics.active()) return;
        if (clarity != 0.0f) {
            applyClarityWithField(image, clarity, *guideFields->clarity);
        }
    } else if (clarityField && !clarityField->empty() && roiMap.active()) {
        applyClarityWithField(image, clarity, *clarityField, roiMap);
    } else {
        applyClarity(image, clarity, sourceWidth, sourceHeight, version);
    }
    if (texture != 0.0f) {
        applyTexture(image, texture, textureSourceWidth, textureSourceHeight);
    }
    if (filmOptics.active()) {
        if (guideFields) {
            *guideFields->filmOptics = buildFilmOpticsField(image, sourceWidth, sourceHeight, filmOptics);
            return;
        }
        if (filmOpticsField && !filmOpticsField->empty() && roiMap.active()) {
            applyFilmOpticsWithField(image, *filmOpticsField, filmOptics, roiMap);
        } else {
            applyFilmOptics(image, filmOptics);
        }
    }
    if (sharpening > 0.0f) {
        if (sharpenV2.luminanceV2) {
            applySharpenV2(image, sharpening, sharpenV2);
        } else {
            applySharpening(image, sharpening);
        }
    }
}

RenderStatus runCpuStageChain(ImageData& image, RenderParams& params, const CpuStagePass& pass) {
    using Kind = CpuStagePass::Kind;
    const bool guide = pass.kind == Kind::RoiGuide;
    const bool tile = pass.kind == Kind::RoiTile;
    const float dehaze = params.atmosphere.dehaze;
    const float clarity = params.atmosphere.clarity;
    const bool filmOptics = params.filmOptics.active();
    // 引导图依次产出 Basic、去雾、清晰度和胶片光学场；最后一个所需场之后的阶段不必运行。
    const bool guideNeedsLook = dehaze != 0.0f || clarity != 0.0f || filmOptics;
    const bool guideNeedsPostLook = clarity != 0.0f || filmOptics;

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            RGB p = pass.applyMatrix ? ColorConverter::applyMatrix(image.pixels[i], pass.toSrgb) : image.pixels[i];
            p.r *= pass.exposureWB.r;
            p.g *= pass.exposureWB.g;
            p.b *= pass.exposureWB.b;
            image.pixels[i] = p;
        }
    });
    applyCameraCalibration(image, params.calibration);
    if (pass.basicV3 && pass.basicTone.active()) {
        if (guide) {
            *pass.basicFieldOut = buildBasicToneV3Field(image, pass.analysisWidth, pass.analysisHeight);
            if (guideNeedsLook) applyBasicToneV3WithField(image, pass.basicTone, *pass.basicFieldOut, {});
        } else if (pass.basicField) {
            applyBasicToneV3WithField(image, pass.basicTone, *pass.basicField, pass.roiMap);
        } else {
            applyBasicToneV3(image, pass.basicTone, pass.analysisWidth, pass.analysisHeight);
        }
        params.highlights = params.shadows = 0.0f;
    }
    if (guide && !guideNeedsLook) return RenderStatus::Ok;
    if (params.defringe.active()) {
        applyDefringe(image, params.defringe);
    }

    const RenderStatus status = applyPhotoLook(image, params.lut, params.dcp, params.lutStrength,
        pass.displayInput, pass.lookConfig);
    if (status != RenderStatus::Ok) return status;
    checkProcessingCancellation();
    if (dehaze != 0.0f) {
        if (guide) {
            *pass.dehaze = buildDehazeAnalysis(image, pass.analysisWidth, pass.analysisHeight, params.processingVersion);
            if (guideNeedsPostLook) applyDehazeWithAnalysis(image, dehaze, *pass.dehaze, {});
        } else if (tile) {
            applyDehazeWithAnalysis(image, dehaze, *pass.dehaze, pass.roiMap);
        } else {
            applyDehaze(image, dehaze, pass.dehaze, pass.analysisWidth, pass.analysisHeight, params.processingVersion);
        }
    }
    if (guide && !guideNeedsPostLook) return RenderStatus::Ok;
    applyPostLookStages(image, params, params.toneControls, params.hsl, params.colorGrading,
        params.channelCurves, pass.basicV3, !pass.stopBeforeHsl, pass.repeatBwAfterBlackWhite);
    if (pass.stopBeforeHsl) return RenderStatus::Ok;

    if (!guide) {
        const auto chromaResult = applyChromaDenoiseWorking(image, params.chromaDenoise);
        checkProcessingCancellation();
        if (chromaResult != ErrorCode::Success) return mapErrorCode(chromaResult);
    }
    // 纹理半径按整图对角线换算：整图用当前尺寸，瓦片按 roiMap 折算到整图，引导图用画布尺寸。
    int textureWidth = image.width;
    int textureHeight = image.height;
    if (tile) {
        textureWidth = std::max(1, static_cast<int>(std::lround(
            pass.roiMap.fullWidth * double(image.width) / std::max(1.0, pass.roiMap.sourceSpanX))));
        textureHeight = std::max(1, static_cast<int>(std::lround(
            pass.roiMap.fullHeight * double(image.height) / std::max(1.0, pass.roiMap.sourceSpanY))));
    } else if (guide) {
        textureWidth = pass.analysisWidth;
        textureHeight = pass.analysisHeight;
    }
    const DetailGuideFields guideFields{pass.clarity, pass.filmOptics};
    applyDetailAdjustments(image, params.noiseReduction, params.sharpening, clarity,
        pass.analysisWidth, pass.analysisHeight, params.processingVersion,
        tile && clarity != 0.0f ? pass.clarity : nullptr, pass.roiMap,
        params.atmosphere.texture, params.sharpenV2, textureWidth, textureHeight,
        params.filmOptics, tile && filmOptics ? pass.filmOptics : nullptr,
        guide ? &guideFields : nullptr);
    if (guide) return RenderStatus::Ok;
    checkProcessingCancellation();
    applyPhotoEffectsROI(image, params.effects, pass.roiMap);
    return RenderStatus::Ok;
}

void applyOutputSharpening(ImageData& image, OutputSharpening level) {
    if (level == OutputSharpening::Off || image.width <= 1 || image.height <= 1 || image.pixels.empty()) {
        return;
    }
    float strength = 0.0f;
    switch (level) {
        case OutputSharpening::Low: strength = 0.20f; break;
        case OutputSharpening::Standard: strength = 0.40f; break;
        case OutputSharpening::High: strength = 0.70f; break;
        case OutputSharpening::Off: return;
    }
    const int width = image.width;
    const int height = image.height;
    const size_t pixelCount = static_cast<size_t>(width) * static_cast<size_t>(height);
    if (image.pixels.size() != pixelCount) {
        return;
    }

    std::vector<float> luma(pixelCount);
    parallelPixelRanges(pixelCount, [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const auto& p = image.pixels[i];
            luma[i] = 0.2126f * p.r + 0.7152f * p.g + 0.0722f * p.b;
        }
    });

    auto rowHoriz = [&](int row, int x) noexcept -> float {
        const int x0 = std::max(0, x - 1);
        const int x2 = std::min(width - 1, x + 1);
        const float* rowPtr = luma.data() + static_cast<size_t>(row) * static_cast<size_t>(width);
        return (rowPtr[x0] + 2.0f * rowPtr[x] + rowPtr[x2]) * 0.25f;
    };

    parallelRowRanges(height, width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            checkProcessingCancellation();
            const int y0 = std::max(0, y - 1);
            const int y2 = std::min(height - 1, y + 1);
            const size_t rowOffset = static_cast<size_t>(y) * static_cast<size_t>(width);
            for (int x = 0; x < width; ++x) {
                const size_t idx = rowOffset + static_cast<size_t>(x);
                const float blur = (rowHoriz(y0, x) + 2.0f * rowHoriz(y, x) + rowHoriz(y2, x)) * 0.25f;
                const float detail = luma[idx] - blur;
                const float weight = clamp01((std::abs(detail) - 0.008f) / 0.032f);
                const float delta = clampFloat(detail * weight * strength, -0.15f, 0.15f);
                auto& pixel = image.pixels[idx];
                pixel.r = clamp01(pixel.r + delta);
                pixel.g = clamp01(pixel.g + delta);
                pixel.b = clamp01(pixel.b + delta);
            }
        }
    });
}

RenderStatus applyPhotoLook(
    ImageData& image,
    const std::shared_ptr<LUT3D>& lut,
    const std::shared_ptr<const DcpLook>& dcp,
    float strength,
    bool displayInput,
    const GpuConfig& config
) {
    const auto encode = displayInput ? GammaConverter::applySRGBGamma : neutralDisplay;
    if (!lut && !dcp) {
        parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
            for (size_t i = first; i < last; ++i) {
                auto& p = image.pixels[i];
                p = RGB(encode(p.r), encode(p.g), encode(p.b));
            }
        });
        return RenderStatus::Ok;
    }
    GammaConverter::FLog2Diagnostics diagnostics;
    diagnostics.min_linear = std::numeric_limits<float>::max();
    diagnostics.max_linear = std::numeric_limits<float>::lowest();
    // 只有 LUT 确实可能进独立 LUT GPU 时才按整图事务处理；DCP、contract、VLT 是纯 CPU 阶段，
    // 没有独立 LUT GPU 后端的构建也不该因 GPU 未关闭而按整幅分配工作区。
    bool gpuLookTransaction = false;
#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES)
    gpuLookTransaction = config.mode != GpuMode::Off && lut && !dcp && !lut->requiresCPU();
#endif
    const bool diagnosticBlocks = !gpuLookTransaction && lut &&
        lut->inputTransfer() == LUTTransfer::FLog2 && isLutDiagnosticsEnabled();
    std::unique_ptr<ContractLUTEvaluator> contract;
    if (lut && lut->hasColorContract()) {
        contract = std::make_unique<ContractLUTEvaluator>(lut);
        if (!contract->supportsInput(displayInput)) return RenderStatus::Unsupported;
    }
    const bool srgbLookInput = lut && !dcp && !contract &&
        lut->inputTransfer() == LUTTransfer::SRGB;
    if (srgbLookInput && !gpuLookTransaction && lut->isValid() && !lut->requiresCPU() &&
        lut->outputTransfer() == LUTTransfer::Display) {
        checkProcessingCancellation();
        const auto low = lut->domainMin();
        const auto high = lut->domainMax();
        const float spanR = high.r - low.r;
        const float spanG = high.g - low.g;
        const float spanB = high.b - low.b;
        const bool unitDomain = low.r == 0.0f && low.g == 0.0f && low.b == 0.0f &&
            high.r == 1.0f && high.g == 1.0f && high.b == 1.0f;
        const int size = lut->getSize();
        const RGB* table = lutTableData(*lut);
        const bool exactOne = strength == 1.0f;
        parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
            for (size_t i = first; i < last; ++i) {
                const RGB& src = image.pixels[i];
                const RGB enc(encode(src.r), encode(src.g), encode(src.b));
                const float r = std::clamp(unitDomain ? enc.r : (enc.r - low.r) / spanR, 0.0f, 1.0f);
                const float g = std::clamp(unitDomain ? enc.g : (enc.g - low.g) / spanG, 0.0f, 1.0f);
                const float b = std::clamp(unitDomain ? enc.b : (enc.b - low.b) / spanB, 0.0f, 1.0f);
                const RGB look = detail::interpolateLUT(table, size, r, g, b);
                image.pixels[i] = exactOne ? look : lerpRGB(enc, look, strength);
            }
        });
        return RenderStatus::Ok;
    }
    auto render = [&](ImageData& working) {
        checkProcessingCancellation();
        auto encodeInPlace = [&](std::vector<RGB>& pixels) {
            parallelPixelRanges(pixels.size(), [&](size_t first, size_t last) {
                for (size_t i = first; i < last; ++i) {
                    auto& p = pixels[i];
                    p = RGB(encode(p.r), encode(p.g), encode(p.b));
                }
            });
        };
        ImageData base;
        if (srgbLookInput) {
            // sRGB 输入 LUT 直接编码工作像素，编码后再取混合基准，省一次整幅回拷。
            encodeInPlace(working.pixels);
            base = working;
        } else {
            base = working;
            encodeInPlace(base.pixels);
        }
        if (dcp) {
            parallelPixelRanges(working.pixels.size(), [&](size_t first, size_t last) {
                for (size_t i = first; i < last; ++i) {
                    working.pixels[i] = dcp->apply(working.pixels[i]);
                }
            });
        } else if (contract) {
            std::atomic<bool> nonFinite{false};
            parallelPixelRanges(working.pixels.size(), [&](size_t first, size_t last) {
                if (nonFinite.load(std::memory_order_acquire)) return;
                for (size_t i = first; i < last; ++i) {
                    auto& pixel = working.pixels[i];
                    pixel = contract->apply(pixel);
                    if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b)) {
                        nonFinite.store(true, std::memory_order_release);
                        return;
                    }
                }
            });
            if (nonFinite.load(std::memory_order_acquire)) return RenderStatus::ProcessingError;
        } else {
            if (!srgbLookInput) {
                if (lut->inputTransfer() == LUTTransfer::FLog2) {
                    ColorConverter().convertImage(working, ColorSpace::sRGB, ColorSpace::FujiFilm_FGamut);
                    applyFLog2Encoding(working, false, diagnosticBlocks ? &diagnostics : nullptr);
                } else {
                    encodePhotoLUTInput(working, lut->inputTransfer());
                }
            }
            const auto result = applyLUTWithConfig(lut, working, config);
            checkProcessingCancellation();
            if (result != ErrorCode::Success) return mapErrorCode(result);
            renderPhotoLUTOutput(working, lut->outputTransfer());
        }
        parallelPixelRanges(working.pixels.size(), [&](size_t first, size_t last) {
            for (size_t i = first; i < last; ++i) {
                working.pixels[i] = lerpRGB(base.pixels[i], working.pixels[i], strength);
            }
        });
        return RenderStatus::Ok;
    };
    // 独立 LUT GPU 仍以整次调用为事务；CPU 混合只保留两块各 3 MiB 的工作区。
    if (gpuLookTransaction) return render(image);
    constexpr size_t blockPixels = 1u << 18;
    ImageData block;
    block.height = 1;
    for (size_t first = 0; first < image.pixels.size(); first += blockPixels) {
        checkProcessingCancellation();
        const size_t count = std::min(blockPixels, image.pixels.size() - first);
        block.width = static_cast<int>(count);
        block.pixels.assign(image.pixels.begin() + first, image.pixels.begin() + first + count);
        const auto status = render(block);
        if (status != RenderStatus::Ok) return status;
        std::copy(block.pixels.begin(), block.pixels.end(), image.pixels.begin() + first);
    }
    if (diagnosticBlocks) logFLog2Diagnostics(diagnostics);
    return RenderStatus::Ok;
}

RenderStatus ensureLinear(
    ImageData& image,
    ColorSpace space,
    bool* isLinear
) {
    if (!isLinear || *isLinear) {
        return RenderStatus::Ok;
    }

    if (space != ColorSpace::sRGB) {
        return RenderStatus::Unsupported;
    }

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            auto& pixel = image.pixels[i];
            pixel.r = GammaConverter::removeSRGBGamma(pixel.r);
            pixel.g = GammaConverter::removeSRGBGamma(pixel.g);
            pixel.b = GammaConverter::removeSRGBGamma(pixel.b);
        }
    });

    *isLinear = true;
    return RenderStatus::Ok;
}

RenderStatus loadLUT(
    const char* lutPath,
    std::shared_ptr<LUT3D>* outLut
) {
    if (!outLut || lutPath == nullptr || lutPath[0] == '\0') {
        return RenderStatus::InvalidArgument;
    }

    auto lut = LUTParser::loadLUTCached(lutPath);
    if (!lut) {
        return RenderStatus::Unsupported;
    }

    *outLut = lut;
    return RenderStatus::Ok;
}

} // namespace sony2fuji
