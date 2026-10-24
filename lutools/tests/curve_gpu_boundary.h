#pragma once
#include "gpu/photo_gpu.h"
#include "core/photo_rendering.h"
#include <algorithm>
#include <cmath>
#include <iostream>

namespace rawlabtest {
template<class Render>
bool curveGpuBoundary(Render render) {
    using namespace sony2fuji;
    ImageData input;
    for (int i=0;i<=4096;++i) {
        const float encoded=i/4096.f;
        const float linear=encoded<=.04045f ? encoded/12.92f : std::pow((encoded+.055f)/1.055f,2.4f);
        const float scene=i==0 ? 0 : i==4096 ? 1e8f :
            .1845f/std::pow((1/linear-1)*.1845f/(1-.1845f),1/1.5f);
        input.pixels.emplace_back(scene,scene,scene);
    }
    input.width=static_cast<int>(input.pixels.size());input.height=1;
    sony2fuji_request request{};
    request.brightness=request.contrast=request.saturation=1;request.temperature=6500;request.intent=SONY2FUJI_INTENT_FINAL;
    double maximum=0;
    for (int shape=0;shape<5;++shape) {
        sony2fuji_tone_curve_config config{1,sizeof(config),SONY2FUJI_CURVE_CUSTOM,4,{{0,0},{.25,.12},{.75,.88},{1,1}}};
        if (shape==0) { config.count=2;config.points[1]={1,1}; }
        if (shape==2) { config.points[1].y=0;config.points[2].y=1; }
        if (shape==3) { config.points[1]={.4,0};config.points[2]={.6,1}; }
        if (shape==4) { config.count=33;for(int i=0;i<33;++i)config.points[i]={i/32.0,std::pow(i/32.0,2)}; }
        const ToneCurve curve(config);
        if (!curve.gpuSupported()) return false;
        ImageData actual;
        if (!render(input,request,curve,actual) || actual.pixels.size()!=input.pixels.size()) return false;
        for (size_t i=0;i<actual.pixels.size();++i) {
            const double expected=curve.evaluate(neutralDisplay(input.pixels[i].r));
            const auto p=actual.pixels[i];
            if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b)) return false;
            maximum=std::max({maximum,std::abs(p.r-expected),std::abs(p.g-expected),std::abs(p.b-expected)});
        }
    }
    std::cout << "Tone curve CPU/GPU float max=" << maximum << '\n';
    return maximum<=5e-6;
}
} // namespace rawlabtest
