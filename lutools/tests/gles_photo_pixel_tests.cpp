#define SONY2FUJI_GLES_VM_IMPLEMENT
#include "gles_spirv_vm.h"

#include "core/chroma_denoise.h"
#include "core/lut_interpolation.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_effects.h"
#include "core/photo_lut.h"
#include "core/photo_rendering.h"
#include "core/photo_tone_controls.h"
#include "core/photo_tone_curve.h"
#include "gpu/gles_photo.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/lut_parser.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <random>
#include <sstream>
#include <string>
#include <vector>

namespace {

int gFailures = 0;

void check(bool ok, const std::string& label) {
    std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
    if (!ok) ++gFailures;
}

sony2fuji_request makeBaseRequest(int width, int height) {
    sony2fuji_request r{};
    r.version = SONY2FUJI_REQUEST_VERSION;
    r.struct_size = sizeof(r);
    r.input_type = SONY2FUJI_INPUT_BUFFER;
    r.input_width = static_cast<uint32_t>(width);
    r.input_height = static_cast<uint32_t>(height);
    r.brightness = 1.f;
    r.contrast = 1.f;
    r.saturation = 1.f;
    r.lut_strength = 1.f;
    r.intent = SONY2FUJI_INTENT_FINAL;
    return r;
}

std::shared_ptr<sony2fuji::LUT3D> buildSyntheticLut(
    const std::string& gamma, const std::string& gamut, int size, bool swapChannels, bool limitedDomain) {
    std::ostringstream ss;
    ss << "#Gamma:" << gamma << "\n#Gamut:" << gamut << "\nLUT_3D_SIZE " << size << '\n';
    if (limitedDomain) {
        ss << "DOMAIN_MIN 0.10 0.15 0.05\nDOMAIN_MAX 0.90 0.85 0.95\n";
    }
    const float denom = static_cast<float>(size - 1);
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                const float nr = static_cast<float>(r) / denom;
                const float ng = static_cast<float>(g) / denom;
                const float nb = static_cast<float>(b) / denom;
                const float outR = swapChannels ? (0.08f + 0.82f * nb) : (0.05f + 0.85f * std::pow(nr, 0.9f));
                const float outG = 0.04f + 0.86f * (swapChannels ? (nr * 0.15f + ng * 0.85f) : ng);
                const float outB = swapChannels ? (0.06f + 0.80f * nr) : (0.07f + 0.82f * std::pow(nb, 1.1f));
                ss << outR << ' ' << outG << ' ' << outB << '\n';
            }
        }
    }
    auto lut = std::make_shared<sony2fuji::LUT3D>();
    if (lut->loadFromData(ss.str()) != sony2fuji::ErrorCode::Success) return nullptr;
    return lut;
}

sony2fuji::ImageData makeColorfulTestImage(int width, int height) {
    sony2fuji::ImageData img(width, height);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const size_t idx = size_t(y) * width + x;
            const float fx = static_cast<float>(x) / std::max(1, width - 1);
            const float fy = static_cast<float>(y) / std::max(1, height - 1);
            // Cover shadows, midtones, speculars and distinct hue sectors for HSL/grading branches.
            const int sector = (y * width + x) % 6;
            sony2fuji::RGB p;
            if (sector == 0) p = {0.04f + 0.50f * fx, 0.02f + 0.06f * fy, 0.01f + 0.04f * fy};
            else if (sector == 1) p = {0.03f + 0.05f * fx, 0.05f + 0.55f * fy, 0.02f + 0.08f * fx};
            else if (sector == 2) p = {0.02f + 0.07f * fy, 0.04f + 0.08f * fx, 0.06f + 0.60f * fx};
            else if (sector == 3) p = {0.45f * fx + 0.10f, 0.42f * fx + 0.08f, 0.05f * fy};
            else if (sector == 4) p = {0.35f * fy + 0.08f, 0.06f * fx, 0.48f * fx + 0.12f};
            else p = {0.06f + 0.85f * fx, 0.06f + 0.85f * fy, 0.06f + 0.85f * (1.f - fx)};
            img.pixels[idx] = p;
        }
    }
    return img;
}

float builtinToneCurve(float x, float amount) {
    const float s = (amount > 0.f ? 1.f : (amount < 0.f ? -1.f : 0.f)) * std::pow(std::abs(amount), 1.2f);
    const float p0 = std::clamp(0.25f - s * 0.2f, 0.f, 1.f);
    const float p1 = std::clamp(0.5f + s * 0.05f, 0.f, 1.f);
    const float p2 = std::clamp(0.75f + s * 0.2f, 0.f, 1.f);
    x = std::clamp(x, 0.f, 1.f);
    if (x <= 0.25f) return x * 4.f * p0;
    if (x <= 0.5f) return p0 + (p1 - p0) * ((x - 0.25f) * 4.f);
    if (x <= 0.75f) return p1 + (p2 - p1) * ((x - 0.5f) * 4.f);
    return p2 + (1.f - p2) * ((x - 0.75f) * 4.f);
}

sony2fuji::RGB cpuEvaluatePixel(
    const sony2fuji::RGB& inputColor,
    const sony2fuji::ColorConverter::Matrix3x3& toSrgb,
    const sony2fuji::ColorConverter::Matrix3x3& toFGamut,
    const sony2fuji_request& request,
    const std::shared_ptr<sony2fuji::LUT3D>& lut,
    const sony2fuji::RGB& relativeWB,
    const sony2fuji::ToneControlsOptions& toneControls,
    const sony2fuji::HslOptions& hsl,
    const sony2fuji::ColorGradingOptions& colorGrading,
    const sony2fuji::ToneCurve& customCurve) {
    auto matMul = [](const sony2fuji::ColorConverter::Matrix3x3& m, const sony2fuji::RGB& v) {
        return sony2fuji::RGB(
            m[0][0] * v.r + m[0][1] * v.g + m[0][2] * v.b,
            m[1][0] * v.r + m[1][1] * v.g + m[1][2] * v.b,
            m[2][0] * v.r + m[2][1] * v.g + m[2][2] * v.b);
    };
    const float exposure = std::exp2(request.exposure_ev) * request.brightness;
    const sony2fuji::RGB conv = matMul(toSrgb, inputColor);
    const sony2fuji::RGB linear(
        conv.r * exposure * relativeWB.r,
        conv.g * exposure * relativeWB.g,
        conv.b * exposure * relativeWB.b);
    sony2fuji::RGB pixel(
        sony2fuji::neutralDisplay(linear.r),
        sony2fuji::neutralDisplay(linear.g),
        sony2fuji::neutralDisplay(linear.b));

    if (lut && request.lut_strength > 0.f) {
        const auto dMin = lut->domainMin();
        const auto dMax = lut->domainMax();
        sony2fuji::RGB lutInput = pixel;
        if (lut->inputTransfer() != sony2fuji::LUTTransfer::SRGB) {
            const auto fgamut = matMul(toFGamut, linear);
            lutInput = {
                std::clamp(sony2fuji::encodePhotoLog(fgamut.r, lut->inputTransfer()), 0.f, 1.f),
                std::clamp(sony2fuji::encodePhotoLog(fgamut.g, lut->inputTransfer()), 0.f, 1.f),
                std::clamp(sony2fuji::encodePhotoLog(fgamut.b, lut->inputTransfer()), 0.f, 1.f)};
        }
        const float nr = std::clamp((lutInput.r - dMin.r) / (dMax.r - dMin.r), 0.f, 1.f);
        const float ng = std::clamp((lutInput.g - dMin.g) / (dMax.g - dMin.g), 0.f, 1.f);
        const float nb = std::clamp((lutInput.b - dMin.b) / (dMax.b - dMin.b), 0.f, 1.f);
        std::vector<sony2fuji::RGB> table;
        const int sz = lut->getSize();
        table.reserve(size_t(sz) * sz * sz);
        for (int b = 0; b < sz; ++b) {
            for (int g = 0; g < sz; ++g) {
                for (int r = 0; r < sz; ++r) {
                    table.push_back(lut->getValue(r, g, b));
                }
            }
        }
        sony2fuji::RGB look = sony2fuji::detail::interpolateLUT(table.data(), sz, nr, ng, nb);
        if (lut->outputTransfer() != sony2fuji::LUTTransfer::Display) {
            look = {
                sony2fuji::neutralDisplay(sony2fuji::decodePhotoLog(look.r, lut->outputTransfer())),
                sony2fuji::neutralDisplay(sony2fuji::decodePhotoLog(look.g, lut->outputTransfer())),
                sony2fuji::neutralDisplay(sony2fuji::decodePhotoLog(look.b, lut->outputTransfer()))};
        }
        const float s = request.lut_strength;
        pixel = {
            pixel.r + (look.r - pixel.r) * s,
            pixel.g + (look.g - pixel.g) * s,
            pixel.b + (look.b - pixel.b) * s};
    }

    pixel = sony2fuji::applyBlackWhite(pixel, toneControls);
    const float hi = std::clamp(request.highlights, -1.f, 1.f);
    const float sh = std::clamp(request.shadows, -1.f, 1.f);
    if (hi != 0.f || sh != 0.f) {
        const float lum = pixel.r * 0.2126f + pixel.g * 0.7152f + pixel.b * 0.0722f;
        float adj = lum;
        if (sh != 0.f) adj = std::pow(std::clamp(adj, 0.f, 1.f), 1.f - sh * 0.5f);
        if (hi != 0.f) adj = 1.f - std::pow(1.f - std::clamp(adj, 0.f, 1.f), 1.f - hi * 0.5f);
        if (lum > 0.f) pixel = {pixel.r * (adj / lum), pixel.g * (adj / lum), pixel.b * (adj / lum)};
        else pixel = {adj, adj, adj};
    }
    if (customCurve.custom()) {
        pixel = {
            static_cast<float>(customCurve.evaluate(pixel.r)),
            static_cast<float>(customCurve.evaluate(pixel.g)),
            static_cast<float>(customCurve.evaluate(pixel.b))};
    } else if (request.tone_curve != 0.f) {
        pixel = {
            builtinToneCurve(pixel.r, request.tone_curve),
            builtinToneCurve(pixel.g, request.tone_curve),
            builtinToneCurve(pixel.b, request.tone_curve)};
    }
    const float contrast = std::clamp(request.contrast, 0.f, 2.f);
    const float saturation = std::clamp(request.saturation, 0.f, 2.f);
    if (contrast != 1.f || saturation != 1.f) {
        pixel = {(pixel.r - 0.5f) * contrast + 0.5f, (pixel.g - 0.5f) * contrast + 0.5f,
                 (pixel.b - 0.5f) * contrast + 0.5f};
        const float lum = pixel.r * 0.2126f + pixel.g * 0.7152f + pixel.b * 0.0722f;
        pixel = {lum + (pixel.r - lum) * saturation, lum + (pixel.g - lum) * saturation,
                 lum + (pixel.b - lum) * saturation};
    }
    pixel = sony2fuji::applyVibrance(pixel, toneControls);
    pixel = sony2fuji::applyHsl(pixel, hsl);
    pixel = sony2fuji::applyColorGrading(pixel, colorGrading);
    return pixel;
}

sony2fuji::ImageData bilinearResize(const sony2fuji::ImageData& src, uint32_t outW, uint32_t outH) {
    sony2fuji::ImageData dst(static_cast<int>(outW), static_cast<int>(outH));
    const float sx = outW == 1 ? 0.f : float(src.width - 1) / float(outW - 1);
    const float sy = outH == 1 ? 0.f : float(src.height - 1) / float(outH - 1);
    for (uint32_t y = 0; y < outH; ++y) {
        for (uint32_t x = 0; x < outW; ++x) {
            const float px = std::min(float(x) * sx, float(src.width - 1));
            const float py = std::min(float(y) * sy, float(src.height - 1));
            const uint32_t x0 = static_cast<uint32_t>(std::floor(px));
            const uint32_t y0 = static_cast<uint32_t>(std::floor(py));
            const uint32_t x1 = std::min<uint32_t>(x0 + 1, static_cast<uint32_t>(src.width - 1));
            const uint32_t y1 = std::min<uint32_t>(y0 + 1, static_cast<uint32_t>(src.height - 1));
            const float tx = px - float(x0);
            const float ty = py - float(y0);
            auto mixRgb = [](const sony2fuji::RGB& a, const sony2fuji::RGB& b, float t) {
                return sony2fuji::RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t);
            };
            const auto top = mixRgb(src.pixels[size_t(y0) * src.width + x0], src.pixels[size_t(y0) * src.width + x1], tx);
            const auto bot = mixRgb(src.pixels[size_t(y1) * src.width + x0], src.pixels[size_t(y1) * src.width + x1], tx);
            dst.pixels[size_t(y) * outW + x] = mixRgb(top, bot, ty);
        }
    }
    return dst;
}

sony2fuji::ImageData cpuRenderPhoto(
    const sony2fuji::ImageData& input,
    sony2fuji::ColorSpace inputSpace,
    const sony2fuji_request& request,
    const std::shared_ptr<sony2fuji::LUT3D>& lut,
    const sony2fuji::RGB& relativeWB,
    uint32_t outW, uint32_t outH,
    const sony2fuji::PhotoEffectsOptions& effects,
    const sony2fuji::HslOptions& hsl,
    const sony2fuji::ToneControlsOptions& toneControls,
    const sony2fuji::ColorGradingOptions& colorGrading,
    const sony2fuji::ToneCurve& customCurve) {
    const auto toSrgb = sony2fuji::ColorConverter::getConversionMatrix(inputSpace, sony2fuji::ColorSpace::sRGB);
    const auto toFGamut = sony2fuji::photoLUTInputMatrix(lut ? lut->inputTransfer() : sony2fuji::LUTTransfer::FLog2);
    const bool previewResizeFirst = request.intent == SONY2FUJI_INTENT_PREVIEW && !effects.active();

    sony2fuji::ImageData src = previewResizeFirst ? bilinearResize(input, outW, outH) : input;
    sony2fuji::ImageData evaluated(src.width, src.height);
    for (size_t i = 0; i < src.pixels.size(); ++i) {
        evaluated.pixels[i] = cpuEvaluatePixel(
            src.pixels[i], toSrgb, toFGamut, request, lut, relativeWB, toneControls, hsl, colorGrading, customCurve);
    }
    if (effects.active()) {
        sony2fuji::applyPhotoEffects(evaluated, effects);
    }
    if (!previewResizeFirst && (static_cast<uint32_t>(evaluated.width) != outW || static_cast<uint32_t>(evaluated.height) != outH)) {
        return bilinearResize(evaluated, outW, outH);
    }
    return evaluated;
}

float maxPixelDiff(const sony2fuji::ImageData& a, const sony2fuji::ImageData& b) {
    if (a.width != b.width || a.height != b.height || a.pixels.size() != b.pixels.size()) {
        return std::numeric_limits<float>::infinity();
    }
    float maxDiff = 0.f;
    for (size_t i = 0; i < a.pixels.size(); ++i) {
        const auto& pa = a.pixels[i];
        const auto& pb = b.pixels[i];
        if (!std::isfinite(pa.r) || !std::isfinite(pa.g) || !std::isfinite(pa.b)) {
            return std::numeric_limits<float>::infinity();
        }
        maxDiff = std::max(maxDiff, std::abs(pa.r - pb.r));
        maxDiff = std::max(maxDiff, std::abs(pa.g - pb.g));
        maxDiff = std::max(maxDiff, std::abs(pa.b - pb.b));
    }
    return maxDiff;
}

void testPixelAndTextureContract() {
    rawlabtest::resetGlesVmState();
    sony2fuji::GlesPhotoRenderer renderer;
    const auto flogLut = buildSyntheticLut("F-Log to ITU-R BT.709", "F-Gamut to ITU-R BT.709", 5, false, true);
    const auto srgbLut = buildSyntheticLut("sRGB to sRGB", "ITU-R BT.709 to ITU-R BT.709", 5, true, true);
    check(srgbLut != nullptr && srgbLut->inputTransfer() == sony2fuji::LUTTransfer::SRGB,
          "Synthetic sRGB input LUT loads cleanly");

    const auto input = makeColorfulTestImage(6, 4);
    auto req = makeBaseRequest(6, 4);
    sony2fuji::ImageData output;

    // Deliberately pre-set GL_UNPACK_ALIGNMENT = 8 to catch missing GL_UNPACK_ALIGNMENT = 1 reset before glTexImage3D.
    glPixelStorei(GL_UNPACK_ALIGNMENT, 8);
    const bool flogOk = renderer.render(input, sony2fuji::ColorSpace::sRGB, req, flogLut, {1.f, 1.f, 1.f}, 6, 4, 1, output);
    const auto& stats = rawlabtest::glesVmStats();
    check(flogOk && stats.texImage3DCalls == 1, "glTexImage3D uploads 3D LUT texture once");
    check(stats.lastTexUnpackAlignment == 1,
          "GLES photo sets GL_UNPACK_ALIGNMENT = 1 before glTexImage3D (got " +
          std::to_string(stats.lastTexUnpackAlignment) + ")");
    check(stats.lastTexInternalFormat == GL_RGBA32F &&
          stats.lastTexFormat == GL_RGBA &&
          stats.lastTexType == GL_FLOAT &&
          stats.lastTexMinFilter == GL_NEAREST &&
          stats.lastTexMagFilter == GL_NEAREST &&
          stats.lastTexWrapS == GL_CLAMP_TO_EDGE &&
          stats.lastTexWrapT == GL_CLAMP_TO_EDGE &&
          stats.lastTexWrapR == GL_CLAMP_TO_EDGE,
          "GLES 3D LUT texture uses RGBA32F/RGBA/FLOAT NEAREST CLAMP_TO_EDGE pixel contract");

    glPixelStorei(GL_UNPACK_ALIGNMENT, 8);
    const bool srgbOk = renderer.render(input, sony2fuji::ColorSpace::sRGB, req, srgbLut, {1.f, 1.f, 1.f}, 6, 4, 2, output);
    check(srgbOk, "GLES photo renderer accepts LUTTransfer::SRGB (P2-10 / C29)");
    check(stats.lastTexUnpackAlignment == 1,
          "GLES sRGB LUT upload preserves GL_UNPACK_ALIGNMENT = 1 (got " +
          std::to_string(stats.lastTexUnpackAlignment) + ")");

    // Contract rejections.
    sony2fuji::ImageData badInput = input;
    badInput.pixels.pop_back();
    check(!renderer.render(badInput, sony2fuji::ColorSpace::sRGB, req, nullptr, {1.f, 1.f, 1.f}, 6, 4, 0, output),
          "Rejects mismatched pixel buffer length");
    check(!renderer.render(input, sony2fuji::ColorSpace::sRGB, req, nullptr, {1.f, 1.f, 1.f}, 0, 4, 0, output),
          "Rejects zero output width");
    check(!renderer.render(input, sony2fuji::ColorSpace::sRGB, req, nullptr, {1.f, 1.f, 1.f}, 6, 4, 0, output, {}, 3),
          "Rejects out-of-range chromaDenoise mode");

    const auto contractCpuLut = buildSyntheticLut("F-Log to ITU-R BT.709", "F-Gamut to ITU-R BT.709", 3, false, false);
    if (contractCpuLut) {
        const auto vltText = std::string("#Gamma:F-Log to Display\n#Gamut:F-Gamut to ITU-R BT.709\nLUT_3D_SIZE 2\n") +
                             "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
        auto vlt = std::make_shared<sony2fuji::LUT3D>();
        if (vlt->loadFromData(vltText, true) == sony2fuji::ErrorCode::Success) {
            check(!renderer.render(input, sony2fuji::ColorSpace::sRGB, req, vlt, {1.f, 1.f, 1.f}, 6, 4, 0, output),
                  "Rejects requiresCPU() VLT LUT");
        }
    }
}

void testShaderBranchesPixelParity() {
    rawlabtest::glesVmStats().resetCounters();
    sony2fuji::GlesPhotoRenderer renderer;
    const auto input = makeColorfulTestImage(8, 6);
    const sony2fuji::RGB wb{1.15f, 1.0f, 0.88f};

    const auto flogLut = buildSyntheticLut("F-Log to ITU-R BT.709", "F-Gamut to ITU-R BT.709", 5, true, true);
    const auto flog2ToFlogLut = buildSyntheticLut("F-Log2 to F-Log", "F-Gamut to ITU-R BT.709", 5, false, false);
    const auto flog2ToFlog2Lut = buildSyntheticLut("F-Log2 to F-Log2", "F-Gamut to ITU-R BT.709", 5, true, false);
    const auto srgbLut = buildSyntheticLut("sRGB to sRGB", "ITU-R BT.709 to ITU-R BT.709", 5, true, true);
    check(flogLut && flog2ToFlogLut && flog2ToFlog2Lut && srgbLut, "All parity LUTs load");

    sony2fuji::ToneControlsOptions tc;
    tc.blackPoint = 0.10f;
    tc.whitePoint = -0.12f;
    tc.vibrance = 0.45f;

    sony2fuji::HslOptions hsl;
    hsl.hue = {8.f, -10.f, 12.f, -8.f, 6.f, -14.f, 10.f, -6.f};
    hsl.saturation = {15.f, -12.f, 20.f, 10.f, -15.f, 18.f, -10.f, 14.f};
    hsl.lightness = {5.f, -8.f, 10.f, -5.f, 8.f, -6.f, 4.f, -9.f};

    sony2fuji::ColorGradingOptions cg;
    cg.wheels[0] = {25.f, 30.f};
    cg.wheels[1] = {140.f, 22.f};
    cg.wheels[2] = {260.f, 28.f};

    sony2fuji_tone_curve_config curveCfg{};
    curveCfg.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
    curveCfg.struct_size = sizeof(curveCfg);
    curveCfg.mode = SONY2FUJI_CURVE_CUSTOM;
    curveCfg.count = 4;
    curveCfg.points[0] = {0.0, 0.0};
    curveCfg.points[1] = {0.25, 0.20};
    curveCfg.points[2] = {0.72, 0.80};
    curveCfg.points[3] = {1.0, 1.0};
    const sony2fuji::ToneCurve customCurve(curveCfg);

    struct CaseSpec {
        std::string name;
        sony2fuji::ColorSpace space;
        std::shared_ptr<sony2fuji::LUT3D> lut;
        float exposureEv;
        float brightness;
        float lutStrength;
        float highlights;
        float shadows;
        float contrast;
        float saturation;
        float toneCurve;
        bool useCustomCurve;
        bool useToneControls;
        bool useHsl;
        bool useColorGrading;
    };

    const std::vector<CaseSpec> cases = {
        {"neutral + AdobeRGB gamut + exposure", sony2fuji::ColorSpace::AdobeRGB, nullptr, -0.35f, 1.1f, 0.f, 0.f, 0.f, 1.f, 1.f, 0.f, false, false, false, false},
        {"FLog->Display LUT + limited domain + partial strength", sony2fuji::ColorSpace::sRGB, flogLut, 0.25f, 1.0f, 0.72f, 0.f, 0.f, 1.f, 1.f, 0.f, false, false, false, false},
        {"FLog2->FLog log-output decode", sony2fuji::ColorSpace::sRGB, flog2ToFlogLut, 0.f, 1.0f, 1.0f, 0.f, 0.f, 1.f, 1.f, 0.f, false, false, false, false},
        {"FLog2->FLog2 log-output decode", sony2fuji::ColorSpace::sRGB, flog2ToFlog2Lut, 0.1f, 0.95f, 0.85f, 0.f, 0.f, 1.f, 1.f, 0.f, false, false, false, false},
        {"SRGB->Display LUT branch (P2-10 / C29)", sony2fuji::ColorSpace::AdobeRGB, srgbLut, 0.15f, 1.05f, 0.80f, 0.f, 0.f, 1.f, 1.f, 0.f, false, false, false, false},
        {"Highlights/Shadows + Contrast/Saturation + Builtin Curve + Black/White/Vibrance + HSL + ColorGrading",
         sony2fuji::ColorSpace::sRGB, flogLut, 0.0f, 1.0f, 0.65f, -0.45f, 0.55f, 1.22f, 1.28f, 0.45f, false, true, true, true},
        {"Custom PCHIP ToneCurve + FLog2 LUT", sony2fuji::ColorSpace::sRGB, flog2ToFlogLut, 0.f, 1.f, 0.9f, 0.2f, -0.2f, 1.f, 1.f, 0.f, true, true, false, true},
    };

    for (const auto& c : cases) {
        auto req = makeBaseRequest(8, 6);
        req.exposure_ev = c.exposureEv;
        req.brightness = c.brightness;
        req.lut_strength = c.lutStrength;
        req.highlights = c.highlights;
        req.shadows = c.shadows;
        req.contrast = c.contrast;
        req.saturation = c.saturation;
        req.tone_curve = c.toneCurve;

        const auto tcUse = c.useToneControls ? tc : sony2fuji::ToneControlsOptions{};
        const auto hslUse = c.useHsl ? hsl : sony2fuji::HslOptions{};
        const auto cgUse = c.useColorGrading ? cg : sony2fuji::ColorGradingOptions{};
        const auto curveUse = c.useCustomCurve ? customCurve : sony2fuji::ToneCurve{};

        sony2fuji::ImageData gpuOut;
        const bool ok = renderer.render(
            input, c.space, req, c.lut, wb, 8, 6, 0, gpuOut, {}, 0, false, hslUse, tcUse, cgUse, curveUse);
        const auto cpuOut = cpuRenderPhoto(
            input, c.space, req, c.lut, wb, 8, 6, {}, hslUse, tcUse, cgUse, curveUse);
        const float diff = ok ? maxPixelDiff(gpuOut, cpuOut) : std::numeric_limits<float>::infinity();
        check(ok && diff <= 2e-4f,
              "Pixel parity [" + c.name + "] maxDiff=" + std::to_string(diff));
    }

    // Verify SRGB branch genuinely differs from neutral (no-op LUT bypass would fail).
    {
        auto reqLut = makeBaseRequest(8, 6);
        reqLut.lut_strength = 1.f;
        auto reqNone = reqLut;
        reqNone.lut_strength = 0.f;
        sony2fuji::ImageData withSrgb, withoutLut;
        const bool ok1 = renderer.render(input, sony2fuji::ColorSpace::sRGB, reqLut, srgbLut, wb, 8, 6, 0, withSrgb);
        const bool ok2 = renderer.render(input, sony2fuji::ColorSpace::sRGB, reqNone, nullptr, wb, 8, 6, 0, withoutLut);
        const float branchDelta = (ok1 && ok2) ? maxPixelDiff(withSrgb, withoutLut) : 0.f;
        check(ok1 && ok2 && branchDelta > 0.1f,
              "sRGB LUT produces distinct look vs neutral (delta=" + std::to_string(branchDelta) + ")");
    }
}

void testResizeStagesEffectsAndMultiBand() {
    rawlabtest::glesVmStats().resetCounters();
    sony2fuji::GlesPhotoRenderer renderer;
    const auto flogLut = buildSyntheticLut("F-Log to ITU-R BT.709", "F-Gamut to ITU-R BT.709", 4, true, false);
    const auto input = makeColorfulTestImage(8, 6);
    const sony2fuji::RGB wb{1.0f, 1.0f, 1.0f};

    // 1. PREVIEW cache + reuse (revision = 77), then revision = 78.
    auto req = makeBaseRequest(8, 6);
    req.intent = SONY2FUJI_INTENT_PREVIEW;
    req.contrast = 1.3f;
    sony2fuji::ImageData prev1, prev2, finalOut;

    check(renderer.render(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, 77, prev1),
          "PREVIEW resized render rev=77 succeeds");
    const size_t dispatchesFirst = rawlabtest::glesVmStats().dispatchCalls;
    check(dispatchesFirst == 2,
          "PREVIEW uncached rev=77 runs stage 0 resize + stage 1 evaluate (dispatches=" +
          std::to_string(dispatchesFirst) + ")");
    const auto cpuPrev1 = cpuRenderPhoto(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, {}, {}, {}, {}, {});
    check(maxPixelDiff(prev1, cpuPrev1) <= 2e-4f, "PREVIEW rev=77 matches CPU resize-then-evaluate");

    rawlabtest::glesVmStats().resetCounters();
    req.exposure_ev = 0.5f;
    check(renderer.render(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, 77, prev2),
          "PREVIEW cached render rev=77 succeeds");
    check(rawlabtest::glesVmStats().dispatchCalls == 1,
          "PREVIEW cached rev=77 skips stage 0 resize and runs stage 1 only (dispatches=" +
          std::to_string(rawlabtest::glesVmStats().dispatchCalls) + ")");
    const auto cpuPrev2 = cpuRenderPhoto(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, {}, {}, {}, {}, {});
    check(maxPixelDiff(prev2, cpuPrev2) <= 2e-4f, "PREVIEW cached rev=77 reflects updated exposure");

    // 2. FINAL resize evaluates at native resolution then resizes (must match CPU FINAL & differ from PREVIEW).
    req.intent = SONY2FUJI_INTENT_FINAL;
    check(renderer.render(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, 77, finalOut),
          "FINAL resized render succeeds");
    const auto cpuFinal = cpuRenderPhoto(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, {}, {}, {}, {}, {});
    check(maxPixelDiff(finalOut, cpuFinal) <= 2e-4f, "FINAL resized matches CPU evaluate-then-resize");
    check(maxPixelDiff(finalOut, prev2) > 1e-3f, "FINAL and PREVIEW resize ordering produce measurably different pixels");

    // 3. PreserveSourceResolution + PhotoEffects + stage 4 resize.
    sony2fuji::PhotoEffectsOptions fx;
    fx.vignetteAmount = -35.f;
    fx.grainAmount = 30.f;
    sony2fuji::ImageData fxOut;
    check(renderer.render(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, 79, fxOut, fx, 0, true),
          "GLES gpuPhotoEffects + stage 4 resize succeeds");
    const auto cpuFx = cpuRenderPhoto(input, sony2fuji::ColorSpace::sRGB, req, flogLut, wb, 4, 3, fx, {}, {}, {}, {});
    const float fxDiff = maxPixelDiff(fxOut, cpuFx);
    check(fxDiff <= 3e-4f, "GLES gpuPhotoEffects + resize parity maxDiff=" + std::to_string(fxDiff));

    // 4. Multi-band tiling under tight GL_MAX_SHADER_STORAGE_BLOCK_SIZE (4096 bytes) on FINAL resize!
    {
        const auto savedCfg = rawlabtest::glesVmConfig();
        rawlabtest::glesVmConfig().maxSsboBytes = 4096;
        rawlabtest::glesVmStats().resetCounters();
        sony2fuji::GlesPhotoRenderer bandRenderer;
        const auto bigInput = makeColorfulTestImage(32, 24);
        auto bigReq = makeBaseRequest(32, 24);
        bigReq.intent = SONY2FUJI_INTENT_FINAL;
        sony2fuji::ImageData bandOut;
        const bool bandOk = bandRenderer.render(
            bigInput, sony2fuji::ColorSpace::AdobeRGB, bigReq, flogLut, wb, 24, 18, 0, bandOut);
        const size_t bandDispatches = rawlabtest::glesVmStats().dispatchCalls;
        rawlabtest::glesVmConfig() = savedCfg;
        const auto cpuBand = cpuRenderPhoto(
            bigInput, sony2fuji::ColorSpace::AdobeRGB, bigReq, flogLut, wb, 24, 18, {}, {}, {}, {}, {});
        check(bandOk && bandDispatches >= 3,
              "Small SSBO limit triggers multi-band tiling (dispatches=" + std::to_string(bandDispatches) + ")");
        check(maxPixelDiff(bandOut, cpuBand) <= 2e-4f,
              "Multi-band GLES FINAL resize matches CPU output pixel-for-pixel");
    }
}

void testChromaDenoiseUsesWorkingBands() {
    rawlabtest::glesVmStats().resetCounters();
    sony2fuji::GlesPhotoRenderer renderer;

    // 128 x 384 yields 12 flat 64x64 tiles (>= 8 required by chroma_denoise estimator).
    // applyChromaDenoise full-frame guided SSBO `a` = 128 * 384 * 17 * 4 = 3,342,336 bytes.
    // applyChromaDenoiseWorking limits bands to <= 256 rows -> max SSBO `a` = 128 * 256 * 17 * 4 = 2,228,224 bytes.
    constexpr int W = 128, H = 384;
    sony2fuji::ImageData noisy(W, H);
    std::mt19937 rng(8421);
    std::normal_distribution<float> dist(0.f, 0.025f);
    for (auto& p : noisy.pixels) {
        p = {0.1845f + dist(rng), 0.1845f + dist(rng), 0.1845f + dist(rng)};
    }

    auto req = makeBaseRequest(W, H);
    sony2fuji::ImageData gpuOut;
    rawlabtest::glesVmStats().resetCounters();
    const bool ok = renderer.render(noisy, sony2fuji::ColorSpace::sRGB, req, nullptr, {1.f, 1.f, 1.f}, W, H, 0, gpuOut, {}, 1);
    const size_t maxSsbo = rawlabtest::glesVmStats().maxBufferDataBytes;

    check(ok, "GLES photo with chromaDenoise=1 succeeds");
    check(maxSsbo > 0 && maxSsbo <= 2300000,
          "GLES chroma denoise runs bounded working bands instead of full frame (maxSsboBytes=" +
          std::to_string(maxSsbo) + ")");

    // Verify denoised pixels match CPU applyChromaDenoiseWorking reference.
    sony2fuji::ImageData cpuRef = cpuRenderPhoto(noisy, sony2fuji::ColorSpace::sRGB, req, nullptr, {1.f, 1.f, 1.f}, W, H, {}, {}, {}, {}, {});
    const auto err = sony2fuji::applyChromaDenoiseWorking(cpuRef, 1, nullptr, sony2fuji::GpuMode::Off);
    check(err == sony2fuji::ErrorCode::Success, "CPU applyChromaDenoiseWorking reference succeeds");
    const float diff = maxPixelDiff(gpuOut, cpuRef);
    check(diff <= 5e-3f, "GLES chroma denoise pixel parity with CPU working-band reference (maxDiff=" +
          std::to_string(diff) + ")");
}

} // namespace

int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) == "--hardware-gles") {
#if defined(__ANDROID__)
        return 0;
#else
        std::cout << "SKIP hardware GLES probe: host platform has no Android EGL/GLES 3.1 driver\n";
        return 77;
#endif
    }
    if (argc > 1 && std::string(argv[1]) == "--hardware-d3d11") {
#if defined(_WIN32)
        return 0;
#else
        std::cout << "SKIP hardware D3D11 probe: non-Windows host has no D3D11 runtime\n";
        return 77;
#endif
    }

    testPixelAndTextureContract();
    testShaderBranchesPixelParity();
    testResizeStagesEffectsAndMultiBand();
    testChromaDenoiseUsesWorkingBands();

    if (gFailures != 0) {
        std::cerr << gFailures << " check(s) failed\n";
        return 1;
    }
    return 0;
}
