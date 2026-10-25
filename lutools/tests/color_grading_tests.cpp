#include "core/photo_color_grading.h"
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
static bool exact(const RGB& a, const RGB& b) { return std::memcmp(&a,&b,sizeof(RGB)) == 0; }
static float difference(const RGB& a, const RGB& b) {
    return std::max({std::abs(a.r-b.r),std::abs(a.g-b.g),std::abs(a.b-b.b)});
}
static double linear(double value) {
    return value <= .04045 ? value/12.92 : std::pow((value+.055)/1.055,2.4);
}
static float encoded(double value) {
    return static_cast<float>(value <= .0031308 ? 12.92*value : 1.055*std::pow(value,1/2.4)-.055);
}
static double luminance(const RGB& p) {
    return .2126*linear(p.r)+.7152*linear(p.g)+.0722*linear(p.b);
}
static ColorGradingOptions wheel(int zone, float hue, float saturation) {
    ColorGradingOptions options; options.wheels[zone]={hue,saturation}; return options;
}
static ColorGradingOptions split() {
    ColorGradingOptions options;
    options.wheels={ColorGradingWheel{220,100},ColorGradingWheel{110,100},ColorGradingWheel{35,100}};
    return options;
}

static void identityAndValidity() {
    ColorGradingOptions options;
    require(options.valid() && !options.active(),"default grading is valid and inactive");
    for (int zone=0;zone<3;++zone) options.wheels[zone].hue=67+zone*129;
    require(options.valid() && !options.active(),"pending hues with zero saturation remain render identity");
    for (const auto p : {RGB(-.1f,.4f,1.2f),RGB(-0.f,0,0),RGB(.8f,.6f,.4f)})
        require(exact(applyColorGrading(p,options),p),"identity is byte exact without transfer or clamp");
    ImageData image(3,1); image.pixels={RGB(-.1f,.4f,1.2f),RGB(-0.f,0,0),RGB(.8f,.6f,.4f)};
    const auto before=image.pixels;applyColorGrading(image,options);
    require(std::memcmp(before.data(),image.pixels.data(),3*sizeof(RGB))==0,"image identity preserves all bytes");
    for (int zone=0;zone<3;++zone) {
        for (float bad : {-1.f,360.f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()})
            require(!wheel(zone,bad,0).valid(),"invalid pending hue is not accepted");
        for (float bad : {-1.f,100.001f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()})
            require(!wheel(zone,0,bad).valid(),"invalid saturation is not accepted");
        require(wheel(zone,359.999f,100).valid() && wheel(zone,0,100).active(),"legal hue and saturation boundaries");
    }
}

static void weightsAndRegions() {
    auto previous=colorGradingWeights(0);
    for (int i=0;i<=10000;++i) {
        const auto w=colorGradingWeights(i/10000.f);
        require(std::abs(w[0]+w[1]+w[2]-1)<2e-7f,"weights sum to one");
        for (int z=0;z<3;++z) {
            require(std::isfinite(w[z]) && w[z]>=0 && w[z]<=1,"weights are nonnegative and finite");
            require(std::abs(w[z]-previous[z])<.001f,"weights change smoothly across the full ramp");
        }
        previous=w;
    }
    require(colorGradingWeights(.1f)==std::array<float,3>{1,0,0},"dark end selects only shadows");
    require(colorGradingWeights(.9f)==std::array<float,3>{0,0,1},"bright end selects only highlights");
    require(colorGradingWeights(.5f)[1]>.89f,"middle zone dominates its fixed center");
    const auto options=split();
    for (int zone=0;zone<3;++zone) {
        const auto coeff=colorGradingCoefficients(wheel(zone,31+zone*110,100));
        for (int other=0;other<3;++other) {
            const auto c=coeff[other];
            require(std::abs(c.g+.2126f*(c.r-c.g)+.0722f*(c.b-c.g))<1e-7f,"wheel direction has zero linear luminance");
            if (other!=zone) require(c.r==0 && c.g==0 && c.b==0,"coefficient construction keeps other zones untouched");
        }
    }
    const float dark=encoded(.1),bright=encoded(.9),middle=encoded(.5);
    const auto blue=applyColorGrading(RGB(dark,dark,dark),wheel(0,240,100));
    require(blue.b>blue.r && blue.b>blue.g,"shadow wheel tints its region");
    const auto red=applyColorGrading(RGB(bright,bright,bright),wheel(2,0,100));
    require(red.r>red.g && red.r>red.b,"highlight wheel tints its region");
    const auto green=applyColorGrading(RGB(middle,middle,middle),wheel(1,120,100));
    require(green.g>green.r && green.g>green.b,"middle wheel tints its region");
    require(exact(applyColorGrading(RGB(bright,bright,bright),wheel(0,240,100)),RGB(bright,bright,bright)),"shadow wheel leaves its zero-weight region exact");
    require(exact(applyColorGrading(RGB(dark,dark,dark),wheel(2,0,100)),RGB(dark,dark,dark)),"highlight wheel leaves its zero-weight region exact");
    for (const auto p : {RGB(0,0,0),RGB(1,1,1)}) require(exact(applyColorGrading(p,options),p),"black and white endpoints stay exact");
}

static void gamutAndContinuity() {
    double worstLuminance=0;
    for (const auto& options : {split(),wheel(0,0,100),wheel(1,120,100),wheel(2,240,100),wheel(1,359.999f,100)}) {
        for (int r=0;r<=20;++r) for(int g=0;g<=20;++g) for(int b=0;b<=20;++b) {
            const RGB input(r/20.f,g/20.f,b/20.f);const auto out=applyColorGrading(input,options);
            for (float v : {out.r,out.g,out.b}) require(std::isfinite(v) && v>=0 && v<=1,"21-cube SDR grid is finite and bounded");
            worstLuminance=std::max(worstLuminance,std::abs(luminance(out)-luminance(input)));
        }
    }
    require(worstLuminance<4e-6,"gamut mapping preserves display-linear luminance");
    std::cout<<"SDR luminance max="<<worstLuminance<<'\n';
    for (const auto& input : {RGB(.2f,.3f,.4f),RGB(1,.4f,.2f),RGB(-.15f,.6f,1.3f),RGB(.99f,.01f,.4f)}) {
        for (int zone=0;zone<3;++zone) {
            require(difference(applyColorGrading(input,wheel(zone,240,.0001f)),input)<2e-5f,"arbitrarily small saturation is continuous at identity, including old out-of-gamut values");
            require(difference(applyColorGrading(input,wheel(zone,359.999f,100)),applyColorGrading(input,wheel(zone,0,100)))<2e-5f,"hue wrap is continuous");
        }
        const auto out=applyColorGrading(input,split());
        const auto lo=std::min({0.f,input.r,input.g,input.b}),hi=std::max({1.f,input.r,input.g,input.b});
        for (float v : {out.r,out.g,out.b}) require(std::isfinite(v) && v>=lo-2e-6f && v<=hi+2e-6f,"old out-of-gamut extrema are not expanded");
    }
    for (float border : {0.f,1.f}) {
        const auto left=applyColorGrading(RGB(border-1e-6f,.4f,.2f),split());
        const auto right=applyColorGrading(RGB(border+1e-6f,.4f,.2f),split());
        require(difference(left,right)<2e-5f,"crossing the SDR input boundary has no branch jump");
    }
    auto previous=applyColorGrading(RGB(0,0,0),split());
    for (int i=1;i<=10000;++i) {
        const float value=encoded(i/10000.0);const auto out=applyColorGrading(RGB(value,value,value),split());
        require(difference(previous,out)<.005f,"three colored zones make a smooth full ramp");
        previous=out;
    }
}

static void referenceVectors() {
    std::ifstream stream(SONY2FUJI_GRADING_REFERENCE);require(stream.good(),"binary64 fixture exists");
    nlohmann::json fixture;stream>>fixture;
    const float tolerance=fixture.at("float_absolute_tolerance");
    float maximum=0;
    for (const auto& item : fixture.at("cases")) {
        ColorGradingOptions options;
        for (int z=0;z<3;++z) options.wheels[z]={item.at("wheels")[z][0],item.at("wheels")[z][1]};
        const auto& p=item.at("input");const auto& e=item.at("expected");
        const auto actual=applyColorGrading(RGB(p[0],p[1],p[2]),options);
        maximum=std::max(maximum,difference(actual,RGB(e[0],e[1],e[2])));
    }
    require(maximum<=tolerance,"fixed binary64 reference vectors");
    std::cout<<"Binary64 reference max="<<maximum<<'\n';
}

int main() {
    try {identityAndValidity();weightsAndRegions();gamutAndContinuity();referenceVectors();std::cout<<"PASS color grading CPU contract\n";return 0;}
    catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
}
