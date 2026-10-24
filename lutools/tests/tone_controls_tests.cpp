#include "core/photo_tone_controls.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace sony2fuji;

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static float chroma(const RGB& p) { return std::max({p.r,p.g,p.b}) - std::min({p.r,p.g,p.b}); }
static float luma(const RGB& p) { return .2126f*p.r + .7152f*p.g + .0722f*p.b; }
static void bounded(const RGB& p) {
    for (const float v : {p.r,p.g,p.b}) require(std::isfinite(v) && v >= 0 && v <= 1, "finite SDR output");
}
static bool exact(const RGB& a, const RGB& b) { return std::memcmp(&a, &b, sizeof(RGB)) == 0; }

static void referenceVectors() {
    std::ifstream stream(SONY2FUJI_TONE_REFERENCE);
    require(stream.good(), "reference fixture exists");
    nlohmann::json reference; stream >> reference;
    const float tolerance=reference.at("float_absolute_tolerance").get<float>();
    for (const auto& item : reference.at("cases")) {
        const auto& p=item.at("input"); const auto& params=item.at("parameters");
        const ToneControlsOptions options{params.at("black_point"),params.at("white_point"),params.at("vibrance")};
        const auto actual=applyVibrance(applyBlackWhite(RGB(p[0],p[1],p[2]),options),options);
        const auto& expected=item.at("expected");
        require(std::abs(actual.r-expected[0].get<float>())<=tolerance &&
                std::abs(actual.g-expected[1].get<float>())<=tolerance &&
                std::abs(actual.b-expected[2].get<float>())<=tolerance,"fixed binary64 reference vectors");
    }
}

static void identityAndValidation() {
    ToneControlsOptions options;
    require(options.valid() && !options.active(), "default identity");
    for (const auto& p : {RGB(-.1f,.4f,1.2f), RGB(-0.f,0.f,0.f), RGB(.8f,.6f,.4f)}) {
        require(exact(applyBlackWhite(p, options), p), "black/white identity has no clamp or rounding");
        require(exact(applyVibrance(p, options), p), "vibrance identity has no clamp or rounding");
    }
    for (float bad : {-1.01f,1.01f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
        options = {}; options.blackPoint = bad; require(!options.valid(), "invalid black point");
        options = {}; options.whitePoint = bad; require(!options.valid(), "invalid white point");
        options = {}; options.vibrance = bad; require(!options.valid(), "invalid vibrance");
    }
    options = {1,-1,1}; require(options.valid() && options.active(), "inclusive parameter endpoints");
}

static void endpointDirectionAndMonotonicity() {
    // 独立推导的旧 .25 反例：正确 .20 输出不会反转 .15 和 .20。
    const ToneControlsOptions lift{1,0,0}, lowerWhite{0,-1,0};
    require(std::abs(applyBlackWhite(RGB(.15f,.15f,.15f),lift).r - .2712828f) < 1e-6f, "black reference .15");
    require(std::abs(applyBlackWhite(RGB(.20f,.20f,.20f),lift).r - .2787172f) < 1e-6f, "black reference .20");
    require(std::abs(applyBlackWhite(RGB(.85f,.85f,.85f),lowerWhite).r - .7287172f) < 1e-6f, "white symmetric reference");
    require(applyBlackWhite(RGB(0,0,0),lift).r == .2f, "black lift works at exact zero");
    require(std::abs(applyBlackWhite(RGB(1,1,1),lowerWhite).r - .8f) < 1e-7f, "white lowering works at exact one");
    for (int bi=-4; bi<=4; ++bi) for (int wi=-4; wi<=4; ++wi) {
        const ToneControlsOptions options{bi*.25f,wi*.25f,0};
        float previousRaw = -2, previousClamped = -2;
        for (int i=0; i<=10000; ++i) {
            const float y = i/10000.f;
            const float raw = y + blackWhiteOffset(y, options);
            const auto out = applyBlackWhite(RGB(y,y,y), options);
            require(raw >= previousRaw && out.r >= previousClamped, "81 by 10001 grayscale grid never reverses");
            require(out.r == out.g && out.g == out.b, "gray stays exactly gray");
            bounded(out);
            previousRaw = raw; previousClamped = out.r;
        }
        for (float y : {0.f,.175f,.35f,.5f,.65f,.825f,1.f}) {
            const auto out = applyBlackWhite(RGB(y,y,y), options);
            bounded(out);
            if (y >= .35f && y <= .65f) require(out.r == y, "black/white leaves middle interval intact");
        }
    }
    const auto colored = applyBlackWhite(RGB(.1f,.06f,.03f), lift);
    require(std::abs((colored.r-colored.g)-.04f) < 1e-7f &&
            std::abs((colored.g-colored.b)-.03f) < 1e-7f, "unclipped endpoint shift follows neutral axis");
}

static void vibranceQuality() {
    ToneControlsOptions options{0,0,1};
    for (float y : {0.f,.00001f,.2f,.5f,1.f}) {
        const RGB p(y,y,y);
        require(exact(applyVibrance(p, options),p), "positive vibrance cannot color gray");
    }
    const RGB low(.4f,.5f,.6f), high(.02f,.45f,.9f), skin(.7f,.5f,.35f), cool(.35f,.5f,.7f);
    const auto lowOut=applyVibrance(low,options), highOut=applyVibrance(high,options);
    require(chroma(lowOut) > chroma(low), "positive vibrance raises low chroma");
    require(chroma(lowOut)/chroma(low) > chroma(highOut)/chroma(high), "high saturation protected relative to low saturation");
    require(chroma(applyVibrance(skin,options))/chroma(skin) <
            chroma(applyVibrance(cool,options))/chroma(cool), "common skin colors receive smaller positive gain");
    require(std::abs(luma(lowOut)-luma(low)) < 2e-7f, "vibrance preserves display luma");
    require(exact(applyVibrance(RGB(1,0,0),options),RGB(1,0,0)), "fully saturated red remains unchanged");
    for (const RGB p : {low,high,skin,cool,RGB(.99f,.6f,.1f),RGB(.001f,.002f,.003f)}) {
        float previous=chroma(p);
        for (int i=1;i<=100;++i) {
            options.vibrance=-i*.01f;
            const auto out=applyVibrance(p,options);
            bounded(out);
            require(chroma(out) <= previous+1e-7f, "negative vibrance progressively removes chroma");
            require(std::abs(luma(out)-luma(p)) < 2e-7f, "negative vibrance preserves display luma");
            previous=chroma(out);
        }
        options.vibrance=-1;
        const auto gray=applyVibrance(p,options);
        require(gray.r == gray.g && gray.g == gray.b, "negative endpoint is exactly achromatic");
    }
    options.vibrance=1;
    for (int r=0;r<=20;++r) for (int g=0;g<=20;++g) for (int b=0;b<=20;++b) {
        const RGB p(r*.05f,g*.05f,b*.05f);
        const auto out=applyVibrance(p,options);
        bounded(out);
        require(chroma(out)+2e-7f >= chroma(p), "positive vibrance never decreases SDR chroma");
        require(std::abs(luma(out)-luma(p)) < 3e-7f, "gamut limiting preserves display luma");
        const auto nearby=applyVibrance(RGB(std::min(1.f,p.r+1e-6f),p.g,p.b),options);
        require(std::abs(out.r-nearby.r)+std::abs(out.g-nearby.g)+std::abs(out.b-nearby.b) < 1e-4f,
                "near gray and hue masks stay continuous");
    }
    for (const RGB p : {RGB(-.2f,.1f,1.2f), RGB(2,2,2)})
        require(exact(applyVibrance(p,options),p), "positive vibrance preserves already out-of-gamut working values");
    const RGB extended(-.2f,.5f,1.2f);
    options.vibrance=-1;
    const auto extendedGray=applyVibrance(extended,options);
    require(extendedGray.r==extendedGray.g && extendedGray.g==extendedGray.b &&
            std::abs(extendedGray.r-.40172f)<1e-6f,"negative vibrance reaches original luminance even outside SDR");
}

int main() {
    try {
        identityAndValidation(); endpointDirectionAndMonotonicity(); vibranceQuality(); referenceVectors();
        std::cout << "Tone controls: identity, 810081 monotonic samples and color quality checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
