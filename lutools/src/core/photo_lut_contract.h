#pragma once
#include "sony2fuji/lut_applicator.h"
#include "photo_rendering.h"

namespace sony2fuji {
// 曲线和原色来自 Panasonic V-Log/V-Gamut Rev.1.0、Sony S-Log3 technical summary。
inline double contractEncode(double x, LUTColorSpace space) {
    switch (space) {
    case LUTColorSpace::SRGB: return x <= .0031308 ? 12.92*x : 1.055*std::pow(x,1/2.4)-.055;
    case LUTColorSpace::Rec709Gamma24: return std::copysign(std::pow(std::abs(x),1/2.4),x);
    case LUTColorSpace::VLogVGamut: return x < .01 ? 5.6*x+.125 : .241514*std::log10(x+.00873)+.598206;
    case LUTColorSpace::SLog3SGamut3:
    case LUTColorSpace::SLog3SGamut3Cine:
        return x < .01125 ? (x*(171.2102946929-95)/.01125+95)/1023 : (420+std::log10((x+.01)/.19)*261.5)/1023;
    case LUTColorSpace::LinearSRGB: return x;
    }
    return NAN;
}
inline double contractDecode(double x, LUTColorSpace space) {
    switch (space) {
    case LUTColorSpace::SRGB: return x <= .04045 ? x/12.92 : std::pow((x+.055)/1.055,2.4);
    case LUTColorSpace::Rec709Gamma24: return std::copysign(std::pow(std::abs(x),2.4),x);
    case LUTColorSpace::VLogVGamut: return x < .181 ? (x-.125)/5.6 : std::pow(10.,(x-.598206)/.241514)-.00873;
    case LUTColorSpace::SLog3SGamut3:
    case LUTColorSpace::SLog3SGamut3Cine:
        return x < 171.2102946929/1023 ? (x*1023-95)*.01125/(171.2102946929-95) : std::pow(10.,(x*1023-420)/261.5)*.19-.01;
    case LUTColorSpace::LinearSRGB: return x;
    }
    return NAN;
}
inline ColorConverter::Matrix3x3 contractToLinearSRGB(LUTColorSpace space) {
    ColorConverter::Matrix3x3 xyz;
    switch (space) {
    case LUTColorSpace::VLogVGamut:
        xyz = {{{.67964447f,.15221141f,.11860004f},{.26068555f,.77489446f,-.03558001f},{-.00931020f,-.00461247f,1.10298042f}}}; break;
    case LUTColorSpace::SLog3SGamut3:
        xyz = {{{.70648271f,.12880105f,.11517216f},{.27097967f,.78660641f,-.05758608f},{-.00967785f,.00460004f,1.09413556f}}}; break;
    case LUTColorSpace::SLog3SGamut3Cine:
        xyz = {{{.59908392f,.24892552f,.10244649f},{.21507582f,.88506850f,-.10014432f},{-.03206585f,-.02765839f,1.14878199f}}}; break;
    default: return {{{1,0,0},{0,1,0},{0,0,1}}};
    }
    return ColorConverter::getConversionMatrix(xyz, ColorSpace::sRGB, ColorSpace::sRGB);
}

class ContractLUTEvaluator {
public:
    explicit ContractLUTEvaluator(std::shared_ptr<LUT3D> lut)
        : contract_(lut->colorContract()), table_(std::move(lut)),
          input_(ColorConverter::invertMatrix(contractToLinearSRGB(contract_.input.space))),
          output_(contractToLinearSRGB(contract_.output.space)) {}

    bool supportsInput(bool displayInput) const {
        if (displayInput) return contract_.input.reference == LUTReference::Display && contract_.base == LUTBaseRendering::SourceDisplay;
        return contract_.base != LUTBaseRendering::SourceDisplay;
    }
    RGB apply(RGB linear) const {
        if (contract_.base == LUTBaseRendering::RawLabNeutral) {
            linear = RGB(GammaConverter::removeSRGBGamma(neutralDisplay(linear.r)),
                GammaConverter::removeSRGBGamma(neutralDisplay(linear.g)),
                GammaConverter::removeSRGBGamma(neutralDisplay(linear.b)));
        }
        const auto input = ColorConverter::applyMatrix(linear,input_);
        auto encode = [&](double x) {
            x = contractEncode(x,contract_.input.space);
            return static_cast<float>(contract_.input.range == LUTRange::Legal10 ? (64+876*x)/1023 : x);
        };
        const auto result = table_.apply(RGB(encode(input.r),encode(input.g),encode(input.b)));
        auto decode = [&](double x) {
            if (contract_.output.range == LUTRange::Legal10) x = (1023*x-64)/876;
            return static_cast<float>(contractDecode(x,contract_.output.space));
        };
        const auto output = ColorConverter::applyMatrix(RGB(decode(result.r),decode(result.g),decode(result.b)),output_);
        if (!std::isfinite(output.r) || !std::isfinite(output.g) || !std::isfinite(output.b)) return RGB(NAN,NAN,NAN);
        auto display = [&](float x) {
            return std::clamp(contract_.output.reference == LUTReference::Scene ? neutralDisplay(x) :
                GammaConverter::applySRGBGamma(x),0.f,1.f);
        };
        return RGB(display(output.r),display(output.g),display(output.b));
    }
private:
    LUTColorContract contract_;
    LUTApplicator table_;
    ColorConverter::Matrix3x3 input_, output_;
};
}
