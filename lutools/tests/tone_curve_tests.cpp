#include "core/photo_tone_curve.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <fstream>
#include <limits>
#include <random>
#include <stdexcept>

using namespace sony2fuji;
static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static sony2fuji_tone_curve_config config(std::initializer_list<sony2fuji_curve_point> points) {
    sony2fuji_tone_curve_config result{SONY2FUJI_TONE_CURVE_CONFIG_VERSION, sizeof(result),
        SONY2FUJI_CURVE_CUSTOM, static_cast<uint32_t>(points.size()), {}};
    std::copy(points.begin(), points.end(), result.points);
    return result;
}
int main() {
    try {
        std::ifstream fixture(SONY2FUJI_CURVE_REFERENCE);
        nlohmann::json reference;fixture >> reference;
        for (const auto& example : reference.at("cases")) {
            auto points=config({{0,0},{1,1}});
            points.count=static_cast<uint32_t>(example.at("points").size());
            for (uint32_t i=0;i<points.count;++i)
                points.points[i]={example["points"][i][0].get<double>(),example["points"][i][1].get<double>()};
            const ToneCurve curve(points);
            for (const auto& sample : example.at("samples"))
                require(std::abs(curve.evaluate(sample[0].get<double>())-sample[1].get<double>())<2e-14,
                    "independent SciPy reference matches");
        }
        const auto identity=config({{0,0},{.1,.1},{.8,.8},{1,1}});
        require(validToneCurve(identity), "identity config valid");
        ToneCurve curve(identity);
        require(!curve.active() && curve.custom(), "custom identity retains mode and bypasses");
        for (double value : {-1.0,0.0,.123456789,1.0,2.0})
            require(curve.evaluate(value)==value, "identity preserves working residual exactly");
        auto source=config({{0,0},{.25,.125},{.75,.875},{1,1}});
        curve=ToneCurve(source);
        require(curve.active() && curve.gpuSupported(), "ordinary curve enabled on GPU");
        // Independent PCHIP: internal slope 27/38, endpoint slope 1/6.
        require(std::abs(curve.evaluate(.125)-(.0625+.03125*(1.0/6-27.0/38)))<1e-14,
            "PCHIP weighted harmonic and one-sided slopes");
        for (uint32_t i=0;i<source.count;++i)
            require(curve.evaluate(source.points[i].x)==source.points[i].y, "passes every control point");
        for (double x : {.25,.75}) {
            const double e=1e-6;
            const double left=(curve.evaluate(x)-curve.evaluate(x-e))/e;
            const double right=(curve.evaluate(x+e)-curve.evaluate(x))/e;
            require(std::abs(left-right)<3e-5, "first derivative continuous");
        }
        for (int invalid=0;invalid<12;++invalid) {
            auto bad=source;
            if (invalid==0) ++bad.version;
            if (invalid==1) --bad.struct_size;
            if (invalid==2) ++bad.struct_size;
            if (invalid==3) bad.mode=static_cast<sony2fuji_curve_mode>(9);
            if (invalid==4) bad.count=1;
            if (invalid==5) bad.count=34;
            if (invalid==6) bad.points[0].y=.01;
            if (invalid==7) bad.points[3].x=.99;
            if (invalid==8) bad.points[2].x=.25;
            if (invalid==9) bad.points[2].y=.1;
            if (invalid==10) bad.points[1].x=std::numeric_limits<double>::quiet_NaN();
            if (invalid==11) bad.points[1].y=std::numeric_limits<double>::infinity();
            require(!validToneCurve(bad), "invalid curve rejected");
        }
        std::mt19937 random(1909);
        std::uniform_real_distribution<double> unit(0,1);
        for (int sample=0;sample<120;++sample) {
            auto points=config({{0,0},{1,1}});
            points.count=sample%32+2;
            double xs[33]{},ys[33]{};
            xs[points.count-1]=ys[points.count-1]=1;
            for (uint32_t i=1;i+1<points.count;++i) { xs[i]=unit(random);ys[i]=unit(random); }
            std::sort(xs,xs+points.count);std::sort(ys,ys+points.count);
            for (uint32_t i=0;i<points.count;++i) points.points[i]={xs[i],ys[i]};
            require(validToneCurve(points), "2 through 33 ordered points valid");
            curve=ToneCurve(points);
            double previous=-1;
            for (int step=0;step<=10000;++step) {
                const double y=curve.evaluate(step/10000.0);
                require(std::isfinite(y) && y>=0 && y<=1 && y>=previous-1e-14,
                    "dense random curves remain monotone and bounded");
                previous=y;
            }
        }
        for (auto points : {config({{0,0},{.2,0},{.8,1},{1,1}}),
                            config({{0,0},{.5,.1},{std::nextafter(.5,1.0),.9},{1,1}}),
                            config({{0,0},{std::numeric_limits<double>::denorm_min(),.7},{1,1}})}) {
            require(validToneCurve(points), "plateau and arbitrarily close valid points accepted");
            curve=ToneCurve(points);
            for (uint32_t i=0;i+1<points.count;++i) {
                double previous=points.points[i].y;
                for (int step=0;step<=1000;++step) {
                    const double x=points.points[i].x+(points.points[i+1].x-points.points[i].x)*step/1000;
                    const double y=curve.evaluate(x);
                    require(std::isfinite(y) && y>=previous-1e-14 && y<=points.points[i+1].y+1e-14,
                        "narrow intervals and plateaus never overshoot");
                    previous=y;
                }
            }
        }
        require(!curve.gpuSupported(), "precision-limited curve requires CPU");
        require(ToneCurve(config({{0,0},{.5,.25},{.59375,.75},{1,1}})).gpuSupported(),
            "GPU derivative bound includes exact threshold");
        require(!ToneCurve(config({{0,0},{.5,.25},{std::nextafter(.59375,0.0),.75},{1,1}})).gpuSupported(),
            "GPU derivative bound rejects next value above threshold");
        require(!ToneCurve(config({{0,0},{1e-44,2e-44},{1,1}})).gpuSupported(),
            "GPU flush-to-zero interval falls back to CPU");
        const double tiny=2e-320;
        curve=ToneCurve(config({{0,0},{tiny,2*tiny},{1,1}}));
        require(std::abs(curve.segment(0).tangent1-1.5*tiny)<=4*std::numeric_limits<double>::denorm_min(),
            "subnormal interval retains nonzero PCHIP harmonic tangent");
        require(std::abs(curve.evaluate(tiny/2)-1.0625*tiny)<=4*std::numeric_limits<double>::denorm_min(),
            "subnormal PCHIP reference remains accurate");
        std::cout << "Tone curve checks passed\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n';return 1; }
}
