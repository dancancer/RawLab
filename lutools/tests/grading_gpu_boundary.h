#pragma once

#include "gpu/photo_gpu.h"
#include "core/photo_color_grading.h"
#include "core/photo_rendering.h"
#include <algorithm>
#include <cmath>
#include <iostream>

namespace rawlabtest {
template<class Render>
bool gradingGpuBoundary(Render render) {
    using namespace sony2fuji;
    ImageData input;
    for (int i=0;i<=100;++i) {
        const float linear=i/100.f;
        const float scene=i==0 ? 0 : i==100 ? 1e6f :
            .1845f/std::pow((1/linear-1)*.1845f/(1-.1845f),1/1.5f);
        input.pixels.emplace_back(scene,scene,scene);
    }
    for (const RGB p : {RGB(.8f,.1f,.1f),RGB(.8f,.10001f,.1f),RGB(.8f,.1f,.10001f),
            RGB(.2f,.5f,.9f),RGB(.2f,.4f,.2f),RGB(.6f,.3f,.18f),RGB(.2f,.200001f,.2f),RGB(.8f,.7f,.5f)})
        input.pixels.push_back(p);
    input.width=static_cast<int>(input.pixels.size());input.height=1;
    ColorGradingOptions all,pending,shadows,middle,tiny;
    all.wheels={ColorGradingWheel{220,100},ColorGradingWheel{110,100},ColorGradingWheel{35,100}};
    pending.wheels={ColorGradingWheel{223,0},ColorGradingWheel{111,0},ColorGradingWheel{35,0}};
    shadows.wheels[0]={240,100};middle.wheels[1]={359.999f,100};tiny.wheels[0]={240,.0001f};
    sony2fuji_request request{};request.brightness=request.saturation=1;request.temperature=6500;request.intent=SONY2FUJI_INTENT_FINAL;
    float maximum=0;
    for (float contrast : {1.f,1.8f}) {
        request.contrast=contrast;
        for (const auto& options : {ColorGradingOptions{},pending,all,shadows,middle,tiny}) {
            ImageData actual;
            if (!render(input,request,options,actual) || actual.pixels.size()!=input.pixels.size())return false;
            for (size_t i=0;i<actual.pixels.size();++i) {
                const auto p=input.pixels[i];RGB expected(neutralDisplay(p.r),neutralDisplay(p.g),neutralDisplay(p.b));
                if (contrast!=1)expected=RGB((expected.r-.5f)*contrast+.5f,(expected.g-.5f)*contrast+.5f,(expected.b-.5f)*contrast+.5f);
                expected=applyColorGrading(expected,options);const auto out=actual.pixels[i];
                if (!std::isfinite(out.r) || !std::isfinite(out.g) || !std::isfinite(out.b))return false;
                maximum=std::max({maximum,std::abs(out.r-expected.r),std::abs(out.g-expected.g),std::abs(out.b-expected.b)});
            }
        }
    }
    std::cout<<"Color grading CPU/GPU float max="<<maximum<<'\n';
    return maximum<=5e-6f;
}
} // namespace rawlabtest
