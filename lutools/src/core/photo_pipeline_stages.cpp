#include "core/photo_pipeline_stages.h"

#include "core/parallel_pixels.h"
#include "core/photo_atmosphere.h"
#include "core/photo_basic_controls_v3.h"
#include "core/photo_lut.h"
#include "core/photo_lut_contract.h"
#include "core/photo_rendering.h"
#include "core/processing_cancellation.h"
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

void applyToneAdjustments(
    ImageData& image,
    const RenderParams& params,
    const std::array<ToneCurve, 3>& channels,
    bool basicV3
) {
    const auto& customCurve = params.customCurve;
    const bool channelsActive = std::any_of(channels.begin(), channels.end(),
        [](const auto& curve) { return curve.active(); });
    if (!params.needsToneAdjustments() && !customCurve.active() && !channelsActive) {
        return;
    }

    float exposureScale = 1.0f;
    float contrast = clampFloat(params.contrast, 0.0f, 2.0f);
    float saturation = clampFloat(params.saturation, 0.0f, 2.0f);
    float highlights = clampFloat(params.highlights, -1.0f, 1.0f);
    float shadows = clampFloat(params.shadows, -1.0f, 1.0f);
    bool useCurve = params.toneCurve != 0.0f;
    ToneCurvePoints curve = buildToneCurve(params.toneCurve);
    RGB wb(1, 1, 1);

    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        for (size_t index = first; index < last; ++index) {
            auto& pixel = image.pixels[index];
            applyExposureAndWhiteBalance(pixel, exposureScale, wb);
            if (highlights != 0.0f || shadows != 0.0f) {
                pixel = detail::hsApplyHighlightsShadows(pixel, highlights, shadows);
            }
            if (customCurve.active()) {
                pixel.r = static_cast<float>(customCurve.evaluate(pixel.r));
                pixel.g = static_cast<float>(customCurve.evaluate(pixel.g));
                pixel.b = static_cast<float>(customCurve.evaluate(pixel.b));
            } else if (useCurve) {
                pixel.r = applyToneCurve(pixel.r, curve);
                pixel.g = applyToneCurve(pixel.g, curve);
                pixel.b = applyToneCurve(pixel.b, curve);
            }
            if (channelsActive) {
                pixel.r = static_cast<float>(channels[0].evaluate(pixel.r));
                pixel.g = static_cast<float>(channels[1].evaluate(pixel.g));
                pixel.b = static_cast<float>(channels[2].evaluate(pixel.b));
            }
            if (basicV3 && contrast != 1.0f) {
                pixel.r = basicContrastV3(pixel.r, contrast - 1);
                pixel.g = basicContrastV3(pixel.g, contrast - 1);
                pixel.b = basicContrastV3(pixel.b, contrast - 1);
            }
            if ((!basicV3 && contrast != 1.0f) || saturation != 1.0f) {
                applyContrastSaturation(pixel, basicV3 ? 1.f : contrast, saturation);
            }
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
    ProcessingVersion version
) {
    if (noiseReduction > 0.0f) {
        applyNoiseReduction(image, noiseReduction);
    }
    applyClarity(image, clarity, sourceWidth, sourceHeight, version);
    if (sharpening > 0.0f) {
        applySharpening(image, sharpening);
    }
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
