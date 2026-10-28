#pragma once

#include "gpu/photo_gpu.h"
#include "core/photo_rendering.h"
#include <algorithm>
#include <cmath>
#include <iostream>

namespace rawlabtest {
template<class Render>
bool toneGpuBoundary(Render render) {
    using namespace sony2fuji;
    ImageData input;
    for (int i=0;i<=100;++i) {
        const float value=i/100.f;
        const float linear=value<=.04045f ? value/12.92f : std::pow((value+.055f)/1.055f,2.4f);
        const float scene=i==0 ? 0 : i==100 ? 1e6f :
            .1845f/std::pow((1/linear-1)*.1845f/(1-.1845f),1/1.5f);
        input.pixels.emplace_back(scene,scene,scene);
    }
    for (const RGB p : {RGB(.8f,.1f,.1f),RGB(.8f,.10001f,.1f),RGB(.8f,.1f,.10001f),
            RGB(.2f,.5f,.9f),RGB(.2f,.4f,.2f),RGB(.6f,.3f,.18f),RGB(.2f,.200001f,.2f),RGB(.8f,.7f,.5f)})
        input.pixels.push_back(p);
    input.width=static_cast<int>(input.pixels.size());input.height=1;
    sony2fuji_request request{};
    request.brightness=request.saturation=1;request.temperature=6500;request.intent=SONY2FUJI_INTENT_FINAL;
    float maximum=0;
    for (float contrast : {1.f,1.8f}) {
        request.contrast=contrast;
        for (const ToneControlsOptions options : {ToneControlsOptions{},ToneControlsOptions{1,-1,1},
                ToneControlsOptions{-1,1,-1},ToneControlsOptions{.3f,-.4f,.65f},
                ToneControlsOptions{0,0,-1e-6f},ToneControlsOptions{0,0,1e-6f}}) {
            ImageData actual;
            if (!render(input,request,options,actual) || actual.pixels.size()!=input.pixels.size()) return false;
            for (size_t i=0;i<actual.pixels.size();++i) {
                const auto p=input.pixels[i];
                auto expected=applyBlackWhite(RGB(neutralDisplay(p.r),neutralDisplay(p.g),neutralDisplay(p.b)),options);
                if (contrast!=1) expected=RGB((expected.r-.5f)*contrast+.5f,(expected.g-.5f)*contrast+.5f,(expected.b-.5f)*contrast+.5f);
                expected=applyVibrance(expected,options);
                const auto out=actual.pixels[i];
                if (!std::isfinite(out.r) || !std::isfinite(out.g) || !std::isfinite(out.b)) return false;
                maximum=std::max({maximum,std::abs(out.r-expected.r),std::abs(out.g-expected.g),std::abs(out.b-expected.b)});
            }
        }
    }
    std::cout<<"Tone endpoint/vibrance CPU/GPU float max="<<maximum<<'\n';
    return maximum<=5e-5f;
}
} // namespace rawlabtest
