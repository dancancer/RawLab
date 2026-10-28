#include "core/photo_atmosphere.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core.hpp>
#endif

using namespace sony2fuji;
static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static float decode(float x) { return x <= .04045f ? x/12.92f : std::pow((x+.055f)/1.055f,2.4f); }
static float encode(float x) { return x <= .0031308f ? 12.92f*x : 1.055f*std::pow(x,1/2.4f)-.055f; }
static ImageData wave(int width, int period, float base, float amplitude) {
    ImageData image(width,128);
    for (int y=0;y<image.height;++y) for(int x=0;x<width;++x) {
        const float v=encode(base+amplitude*std::sin(6.28318530718f*x/period));
        image.at(x,y)=RGB(v,v,v);
    }
    return image;
}
static double amplitude(const ImageData& image, int period) {
    double sum=0;
    for (int x=32;x<image.width-32;++x)
        sum += decode(image.at(x,64).r)*std::sin(6.28318530718*x/period);
    return sum/(image.width-64);
}
static double mse(const ImageData& a, const ImageData& b) {
    double sum=0;
    for (size_t i=0;i<a.pixels.size();++i) {
        const float d=decode(a.pixels[i].r)-decode(b.pixels[i].r); sum+=d*d;
    }
    return sum/a.pixels.size();
}
static void identityAndRange() {
    require(AtmosphereOptions{}.valid() && !AtmosphereOptions{}.active(),"default identity");
    for(float bad : {-1.01f,1.01f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
        require(!AtmosphereOptions{bad,0}.valid() && !AtmosphereOptions{0,bad}.valid(),"finite inclusive range");
    }
    ImageData original(4,1); original.pixels={RGB(-0.f,0,0),RGB(-.2f,.4f,1.2f),RGB(.1f,.4f,.9f),RGB(1,1,1)};
    auto result=original; applyDehaze(result,0); applyClarity(result,0);
    require(std::memcmp(result.pixels.data(),original.pixels.data(),4*sizeof(RGB))==0,"zero is byte identity including extended values");
    std::mt19937 rng(7049); std::uniform_real_distribution<float> random(0,1);
    ImageData grid(257,129);
    for (auto& p:grid.pixels) p=RGB(random(rng),random(rng),random(rng));
    for (float a : {-1.f,-.5f,-.00001f,.00001f,.5f,1.f}) {
        result=grid; applyDehaze(result,a); applyClarity(result,a);
        for(const auto& p:result.pixels) for(float v : {p.r,p.g,p.b})
            require(std::isfinite(v) && v>=0 && v<=1,"finite bounded SDR extremes");
    }
}
static void clarityScaleAndProtection() {
    const auto source=wave(1024,64,.3f,.035f);
    auto positive=source, negative=source;
    applyClarity(positive,1); applyClarity(negative,-1);
    require(amplitude(positive,64)>1.03*amplitude(source,64),"positive clarity increases medium-scale contrast");
    require(amplitude(negative,64)<.97*amplitude(source,64),"negative clarity softens medium-scale contrast");
    ImageData edge(1024,128), uniform(1024,128), noise(1024,128);
    std::mt19937 rng(49); std::normal_distribution<float> normal(0,.003f);
    for(int y=0;y<128;++y) for(int x=0;x<1024;++x) {
        float v=encode(x<512?.04f:.85f); edge.at(x,y)=RGB(v,v,v);
        v=encode(.3f); uniform.at(x,y)=RGB(v,v,v);
        v=encode(.03f+normal(rng)); noise.at(x,y)=RGB(v,v,v);
    }
    auto beforeEdge=edge, beforeUniform=uniform, beforeNoise=noise;
    applyClarity(edge,1); applyClarity(uniform,1); applyClarity(noise,1);
    float maxEdge=0;
    for(size_t i=0;i<edge.pixels.size();++i) {
        maxEdge=std::max(maxEdge,std::abs(edge.pixels[i].r-beforeEdge.pixels[i].r));
        require(std::abs(uniform.pixels[i].r-beforeUniform.pixels[i].r)<1e-6,"flat field unchanged");
        require(edge.pixels[i].r==edge.pixels[i].g && edge.pixels[i].g==edge.pixels[i].b,"clarity preserves neutral gray");
    }
    std::cout << "clarity medium gain=" << amplitude(positive,64)/amplitude(source,64)
              << " edge max=" << maxEdge << " noise change MSE=" << mse(noise,beforeNoise) << '\n';
    require(maxEdge<.008f,"strong edge halo below two RGB8 codes");
    require(mse(noise,beforeNoise)<1e-7,"shadow noise is not sharpened");
}
static void hazeDirectionAndCache() {
    ImageData clear(1024,256), fog(1024,256);
    for(int y=0;y<256;++y) for(int x=0;x<1024;++x) {
        // 灰色纹理、暗目标和远处白色空气光区域提供已知 I=Jt+A(1-t)。
        const float j=y<32?.8f:((x%64)<10?.005f:.08f+.32f*(x%64)/63);
        const float t=y<32?1.f:.55f;
        const float c=encode(j), f=encode(j*t+.8f*(1-t));
        clear.at(x,y)=RGB(c,c,c); fog.at(x,y)=RGB(f,f,f);
    }
    auto recovered=fog, added=clear; DehazeAnalysis cache;
    applyDehaze(recovered,1,&cache); applyDehaze(added,-1);
    require(mse(recovered,clear)<.75*mse(fog,clear),"positive dehaze improves known synthetic haze");
    require(added.at(5,100).r>clear.at(5,100).r,"negative dehaze adds atmospheric light");
    for(const auto& p:recovered.pixels) require(p.r==p.g && p.g==p.b,"dehaze preserves gray");
    require(cache.builds==1,"first analysis built");
    auto again=fog; applyDehaze(again,.25,&cache);
    require(cache.builds==1,"strength does not invalidate source analysis");
    again=fog; again.at(2,2)=RGB(.1,.2,.3); applyDehaze(again,1,&cache);
    require(cache.builds==2,"changed source pixels invalidate analysis");
    std::cout << "synthetic haze MSE before=" << mse(fog,clear) << " after=" << mse(recovered,clear) << '\n';
}
static void smoothSkyNoise() {
    ImageData source(1024,128);
    std::mt19937 rng(972);std::normal_distribution<float> noise(0,.002f);
    for(int y=0;y<128;++y) for(int x=0;x<1024;++x) {
        if(y<20) source.at(x,y)=RGB(encode(.8f),encode(.8f),encode(.8f));
        else source.at(x,y)=RGB(encode(.25f+noise(rng)),encode(.4f+noise(rng)),encode(.6f+noise(rng)));
    }
    auto changed=source;applyDehaze(changed,1);
    auto spread=[](const ImageData& image) {
        double mean=0,square=0;int count=0;
        for(int y=64;y<120;++y) for(int x=32;x<992;++x) {
            const float v=image.at(x,y).g;mean+=v;square+=v*v;++count;
        }
        return std::sqrt(std::max(0.,square/count-mean*mean/count/count));
    };
    const double ratio=spread(changed)/spread(source);
    std::cout<<"smooth sky encoded noise ratio="<<ratio<<'\n';
    require(ratio<1.5,"smooth bright sky noise gain stays below 1.5");
}
static void extendedWorkingContinuity() {
    for(float amount : {-1.f,1.f}) for(int control=0;control<2;++control) {
        auto inside=wave(512,64,.3f,.04f),outside=inside;
        // 同一邻域跨过显示色域边界；旧 tone 和 LUT 允许有限扩展工作值。
        inside.at(175,64)=RGB(.999999f,.45f,.25f);outside.at(175,64)=RGB(1.000001f,.45f,.25f);
        inside.at(287,64)=RGB(.000001f,.45f,.25f);outside.at(287,64)=RGB(-.000001f,.45f,.25f);
        if(control==0) {applyClarity(inside,amount);applyClarity(outside,amount);}
        else {applyDehaze(inside,amount);applyDehaze(outside,amount);}
        for(int x:{175,287}) {
            const auto a=inside.at(x,64),b=outside.at(x,64);
            require(std::abs(a.r-b.r)+std::abs(a.g-b.g)+std::abs(a.b-b.b)<.0001,
                "active controls continuous across finite gamut boundary");
        }
    }
}
static void scaleCacheAndGradients() {
    const auto source=wave(1024,64,.3f,.035f);
    ImageData doubled(2048,256);
    for(int y=0;y<256;++y) for(int x=0;x<2048;++x) doubled.at(x,y)=source.at(x/2,y/2);
    for(float amount:{-1.f,1.f}) for(int control=0;control<2;++control) {
        auto small=source,large=doubled;
        if(control==0) {applyClarity(small,amount);applyClarity(large,amount);}
        else {applyDehaze(small,amount);applyDehaze(large,amount);}
        float difference=0;
        for(int x=32;x<992;++x)
            difference=std::max(difference,std::abs(small.at(x,64).r-(large.at(2*x,128).r+large.at(2*x+1,128).r)*.5f));
        require(difference<.002,"source-relative spatial scale remains stable at twice resolution");
    }
    // 缓存身份是算法的分析输入；分析桶内部重排仍必须与新 session 逐像素相同。
    doubled.at(200,128)=RGB(.2,.3,.4);doubled.at(201,128)=RGB(.7,.6,.5);
    DehazeAnalysis cache;auto previous=doubled;applyDehaze(previous,1,&cache);
    std::swap(doubled.at(200,128),doubled.at(201,128));
    auto cached=doubled,fresh=doubled;applyDehaze(cached,1,&cache);applyDehaze(fresh,1);
    require(std::memcmp(cached.pixels.data(),fresh.pixels.data(),cached.pixels.size()*sizeof(RGB))==0,
        "same analysis averages with changed full-resolution detail match fresh analysis");
    for(float amount:{-1.f,-.01f,.01f,1.f}) for(int control=0;control<2;++control) {
        ImageData ramp(2048,64);
        for(int y=0;y<64;++y) for(int x=0;x<2048;++x) {
            const float v=encode(x/2047.f);ramp.at(x,y)=RGB(v,v,v);
        }
        if(control==0) applyClarity(ramp,amount);else applyDehaze(ramp,amount);
        for(int x=1;x<2048;++x) {
            if(ramp.at(x,32).r<ramp.at(x-1,32).r-1e-6)
                std::cerr<<"ramp control="<<control<<" amount="<<amount<<" x="<<x<<" values="<<ramp.at(x-1,32).r<<','<<ramp.at(x,32).r<<'\n';
            require(ramp.at(x,32).r>=ramp.at(x-1,32).r-1e-6,"smooth grayscale ramp has no reversals");
        }
    }
}
static void coloredHighlightHeadroom() {
    ImageData source(1024,128);
    std::mt19937 rng(922);std::normal_distribution<float> noise(0,.002f);
    for(int y=0;y<128;++y) for(int x=0;x<1024;++x) {
        const float wave=std::sin(x*6.28318530718f/64);
        const RGB p=y<20?RGB(.8,.8,.8):RGB(.75f+.2f*wave+noise(rng),.4f+.12f*wave+noise(rng),.25f+.08f*wave+noise(rng));
        source.at(x,y)=RGB(encode(p.r),encode(p.g),encode(p.b));
    }
    auto changed=source;applyDehaze(changed,1);
    int newlyClipped=0;
    for(int y=48;y<128;++y) for(int x=0;x<1024;++x)
        if(source.at(x,y).r<.999f && changed.at(x,y).r>=.9999f) ++newlyClipped;
    std::cout<<"colored highlight newly clipped pixels="<<newlyClipped<<'\n';
    require(newlyClipped==0,"dehaze retains headroom in warm textured highlights");
}
static void referenceVectors() {
    std::ifstream stream(SONY2FUJI_ATMOSPHERE_REFERENCE);
    require(stream.good(),"reference fixture exists");nlohmann::json fixture;stream>>fixture;
    const float tolerance=fixture.at("float_absolute_tolerance");
    for(const auto& item:fixture.at("cases")) {
        ImageData image(1,1);const auto& p=item.at("input");image.pixels[0]=RGB(p[0],p[1],p[2]);
        applyDehaze(image,item.at("dehaze"));const auto& e=item.at("expected");const auto a=image.pixels[0];
        require(std::abs(a.r-e[0].get<float>())<tolerance && std::abs(a.g-e[1].get<float>())<tolerance &&
            std::abs(a.b-e[2].get<float>())<tolerance,"independent binary64 atmospheric reference");
    }
}
static void viewportScaleAndThreads() {
    const auto source=wave(2051,128,.3f,.035f);
    ImageData proxy(1025,64);
    for(int y=0;y<proxy.height;++y) for(int x=0;x<proxy.width;++x)
        proxy.at(x,y)=source.at(x*2,y*2);
    DehazeAnalysis cache;
    auto reduced=proxy;
    applyDehaze(reduced,.6f,&cache,source.width,source.height);
    const int gridHeight=std::max(1,int(std::lround(source.height*1024./source.width)));
    require(cache.width==1024 && cache.height==gridHeight,"viewport analysis grid uses full source dimensions");
    require(cache.workingWidth==proxy.width && cache.sourceWidth==source.width,"cache distinguishes working and source dimensions");
    auto full=source;applyDehaze(full,.6f,&cache);
    require(cache.builds==2,"full source cannot reuse reduced analysis");
    auto again=proxy;applyDehaze(again,.6f,&cache,source.width,source.height);
    require(cache.builds==3 && std::memcmp(again.pixels.data(),reduced.pixels.data(),again.pixels.size()*sizeof(RGB))==0,
        "small-full-small analysis matches fresh reduced pixels");
    DehazeAnalysis constantCache;
    uint64_t constantKey=0;
    for(const auto size:std::vector<std::pair<int,int>>{{1024,64},{512,64},{512,32}}) {
        ImageData constant(size.first,size.second);
        std::fill(constant.pixels.begin(),constant.pixels.end(),RGB(.5f,.5f,.5f));
        applyDehaze(constant,.6f,&constantCache,source.width,source.height);
        if(constantCache.builds==1) constantKey=constantCache.fingerprint;
        require(constantCache.fingerprint==constantKey,"constant grids deliberately have identical content fingerprints");
        require(constantCache.workingWidth==size.first && constantCache.workingHeight==size.second,
            "cache records both working dimensions");
    }
    require(constantCache.builds==3,"identical grid fingerprints cannot bypass working-width or height isolation");
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    struct RestoreThreads { int count=cv::getNumThreads(); ~RestoreThreads() { cv::setNumThreads(count); } } restore;
    for(const auto values:std::vector<std::vector<float>>{{1,0},{-1,0},{0,1},{0,-1},{.5f,-.5f}}) {
        for(bool viewport:{false,true}) {
            ImageData serial;
            for(int threads:{1,2,4}) {
                cv::setNumThreads(threads);
                auto current=viewport ? proxy : source;
                applyDehaze(current,values[1],nullptr,source.width,source.height);
                applyClarity(current,values[0],source.width,source.height);
                if(threads==1) serial=current;
                else require(std::memcmp(current.pixels.data(),serial.pixels.data(),current.pixels.size()*sizeof(RGB))==0,
                    "full and viewport float pixels are byte-identical at 1/2/4 threads");
            }
        }
    }
#endif
}
int main() {
    try { identityAndRange(); clarityScaleAndProtection(); hazeDirectionAndCache();smoothSkyNoise();extendedWorkingContinuity();scaleCacheAndGradients();coloredHighlightHeadroom();referenceVectors();viewportScaleAndThreads();
        std::cout << "Atmosphere controls tests passed\n"; return 0;
    } catch(const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
