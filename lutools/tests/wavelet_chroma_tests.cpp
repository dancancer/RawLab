// 用已知真值同时约束色斑、彩色纹理和色边，不能靠去饱和或全局模糊通过。
#include "../src/core/wavelet_denoise.cpp"
#include <iostream>
#include <random>
#include <stdexcept>

using namespace sony2fuji;

namespace {
constexpr float inverseRoot2=.7071067811865475f,inverseRoot6=.4082482904638630f;

void require(bool value,const char* message) {
    if (!value) throw std::runtime_error(message);
}

cv::Vec3f colorVector(float u,float v) {
    return {u*inverseRoot2+v*inverseRoot6,-2*v*inverseRoot6,-u*inverseRoot2+v*inverseRoot6};
}

cv::Vec2d colorError(const RGB& value,const RGB& truth) {
    const double r=value.r-truth.r,g=value.g-truth.g,b=value.b-truth.b;
    return {(r-b)*inverseRoot2,(r-2*g+b)*inverseRoot6};
}

struct Fixture {
    ImageData truth{512,512},noisy{512,512};
    cv::Mat fine=cv::Mat(512,512,CV_32F),coarse=cv::Mat(512,512,CV_32F),luma=cv::Mat(512,512,CV_32F);
};

Fixture makeFixture(unsigned seed,double radius,int scene,float fineAmplitude=.025f) {
    Fixture fixture;
    std::mt19937 random(seed);
    std::normal_distribution<float> gaussian(0,1);
    cv::Mat u(512,512,CV_32F),v(512,512,CV_32F);
    for (int y=0;y<512;++y) for (int x=0;x<512;++x) {
        u.at<float>(y,x)=gaussian(random); v.at<float>(y,x)=gaussian(random);
    }
    cv::GaussianBlur(u,u,{},radius); cv::GaussianBlur(v,v,{},radius);
    cv::Scalar um,us,vm,vs;
    cv::meanStdDev(u,um,us); cv::meanStdDev(v,vm,vs);
    u=(u-um[0])/us[0]; v=(v-vm[0])/vs[0];
    for (int y=0;y<512;++y) for (int x=0;x<512;++x) {
        const bool middle=x>=128 && x<384 && y>=128 && y<384;
        const float fine=scene==1 && middle ? fineAmplitude*std::sin(.35f*x)*std::cos(.21f*y) : 0;
        const float coarse=scene==1 ? .018f*std::sin(.055f*x)*std::cos(.04f*y) : 0;
        const float luma=scene>0 && middle ? .012f*std::sin(1.1f*x)*std::cos(.7f*y) : 0;
        fixture.fine.at<float>(y,x)=fine; fixture.coarse.at<float>(y,x)=coarse; fixture.luma.at<float>(y,x)=luma;
        float cu=.6f*fine-.8f*coarse,cv=.8f*fine+.6f*coarse;
        if (scene==2) {
            cu=(x>=256 ? .055f : -.035f)+.02f*(x-256)/512;
            cv=(x>=256 ? -.03f : .04f)+.018f*(y-256)/512;
        }
        const auto color=colorVector(cu,cv);
        const auto noise=colorVector(.018f*u.at<float>(y,x),.009f*u.at<float>(y,x)+.013f*v.at<float>(y,x));
        auto& truth=fixture.truth.at(x,y); auto& noisy=fixture.noisy.at(x,y);
        truth={.18f+luma+color[0],.18f+luma+color[1],.18f+luma+color[2]};
        noisy={truth.r+noise[0]+.008f*gaussian(random),truth.g+noise[1]+.008f*gaussian(random),
            truth.b+noise[2]+.008f*gaussian(random)};
    }
    return fixture;
}

ImageData filtered(const Fixture& fixture, WaveletDenoiseOptions options = {true,10,72,100}) {
    auto output=fixture.noisy;
    WaveletDenoiseDiagnostics info;
    require(applyWaveletDenoise(output,options,&info)==ErrorCode::Success && info.applied,
        "chroma fixture must actually be filtered");
    return output;
}

ImageData previousChromaReference(const Fixture& fixture) {
    auto output=fixture.noisy;
    cv::Mat rgb(output.height,output.width,CV_32FC3,output.pixels.data());
    WaveletNoiseEstimateDiagnostics info;
    const auto samples=flatSamples(rgb,info);
    require(samples.size()>=8,"reference fixture must have enough flat samples");
    auto model=fitNoise(samples);
    cv::Mat transformed;
    cv::transform(normalize(rgb,model),transformed,opponent());
    calibrateBands(model,transformed,samples);
    calibrateLumaCoarseBands(model,transformed,samples);
    calibrateCoarseBands(model,transformed,samples);
    cv::Mat result=transformed.clone();
    std::atomic<bool> used{false};
    const cv::Rect region(0,0,rgb.cols,rgb.rows),inside(256,256,rgb.cols,rgb.rows);
    const std::array<int,6> windows{7,7,7,7,17,33};
    for (int c=0;c<3;++c) {
        const auto plane=waveletTilePlane(transformed,region,256,64,c);
        if (c==0) {
            const auto luma=filterPlane(plane,model,{true,10,72,100},0,GpuMode::Off,used);
            cv::insertChannel(luma(inside),result,0);
            continue;
        }
        // 旧版色度参考写死窗口与软阈值，不调用待测的窗口或阈值选择器。
        StationaryWavelet wavelet(plane,6);
        for (int scale=0;scale<6;++scale) for (int direction=0;direction<3;++direction) {
            const int level=6-scale;
            const float sigma=bandSigma(model,c,level,direction),variance=sigma*sigma;
            auto band=wavelet.band(scale,direction);
            cv::Mat energy;
            cv::boxFilter(band.mul(band),energy,-1,{windows[level-1],windows[level-1]});
            for (int y=0;y<band.rows;++y) for (int x=0;x<band.cols;++x) {
                const float threshold=(72*.025f)*variance/
                    std::sqrt(std::max(energy.at<float>(y,x)-variance,.05f*variance));
                auto& value=band.at<float>(y,x);
                value=std::copysign(std::max(std::abs(value)-threshold,0.f),value);
            }
            wavelet.setBand(scale,direction,band);
        }
        const auto chroma=wavelet.reconstruct();
        cv::insertChannel(chroma(inside),result,c);
    }
    restore(rgb,result,model);
    return output;
}

struct Error { double rmse; cv::Vec2d bias; };

Error measure(const ImageData& output,const ImageData& truth) {
    double square=0;
    cv::Vec2d bias{};
    size_t count=0;
    for (int y=32;y<480;++y) for (int x=32;x<480;++x) {
        const auto& value=output.at(x,y);
        require(std::isfinite(value.r) && std::isfinite(value.g) && std::isfinite(value.b),"finite chroma output");
        const auto error=colorError(value,truth.at(x,y));
        square+=error.dot(error); bias+=error; ++count;
    }
    return {std::sqrt(square/(2*count)),bias/double(count)};
}

void checkCorrelatedColorNoise() {
    bool reduced=true;
    for (unsigned seed:{7919u,20021u,44621u,92891u}) for (double radius:{1.2,3.}) {
        const auto fixture=makeFixture(seed,radius,0);
        const auto output=filtered(fixture);
        const auto before=measure(fixture.noisy,fixture.truth),after=measure(output,fixture.truth);
        const auto mild=measure(filtered(fixture,{true,0,3,5}),fixture.truth);
        require(after.rmse<mild.rmse && mild.rmse<before.rmse,"chroma sliders control noise/detail tradeoff");
        // normal_distribution 的序列跨标准库不同，必须在同一输入上现算旧版参考。
        const auto previous=measure(previousChromaReference(fixture),fixture.truth);
        const double ratio=after.rmse/before.rmse;
        std::cout<<"color noise seed="<<seed<<" radius="<<radius<<" RMS ratio="<<ratio
            <<" previous="<<previous.rmse/before.rmse<<'\n';
        reduced&=ratio<(radius<2 ? .13 : .25) && after.rmse<previous.rmse*.9;
        require(cv::norm(after.bias)<.001,"flat color noise must not leave a color cast");
    }
    require(reduced,"correlated middle-scale color noise must not protect its own high-energy patches");
}

void checkColorTexture() {
    for (unsigned seed:{7919u,20021u}) for (double radius:{1.2,3.}) for (float amplitude:{.025f,.08f}) {
        const auto fixture=makeFixture(seed,radius,1,amplitude);
        // 低强度验证细节保留；强降噪预设的取舍另由已冻结 C5 参照和噪声测试约束。
        const auto output=filtered(fixture,{true,0,3,5});
        const auto strong=filtered(fixture);
        double strongFine=0;
        double fine=0,cross=0,finePower=0,coarse=0,coarsePower=0,luma=0,lumaPower=0;
        for (int y=32;y<480;++y) for (int x=32;x<480;++x) {
            const auto error=colorError(output.at(x,y),fixture.truth.at(x,y));
            const double f=fixture.fine.at<float>(y,x),c=fixture.coarse.at<float>(y,x),l=fixture.luma.at<float>(y,x);
            fine+=(.6*error[0]+.8*error[1]+f)*f; finePower+=f*f;
            const auto strongError=colorError(strong.at(x,y),fixture.truth.at(x,y));
            strongFine+=(.6*strongError[0]+.8*strongError[1]+f)*f;
            cross+=(-.8*error[0]+.6*error[1])*f;
            coarse+=(-.8*error[0]+.6*error[1]+c)*c; coarsePower+=c*c;
            const auto& p=output.at(x,y); const auto& q=fixture.truth.at(x,y);
            luma+=((p.r-q.r+p.g-q.g+p.b-q.b)/3.+l)*l; lumaPower+=l*l;
        }
        const double fineGain=fine/finePower,coarseGain=coarse/coarsePower,lumaGain=luma/lumaPower;
        require(fineGain>strongFine/finePower,"lower strength retains more of the same colored fine texture");
        const double hueError=std::atan2(std::abs(cross),fine);
        std::cout<<"color texture seed="<<seed<<" radius="<<radius<<" amplitude="<<amplitude
            <<" fine="<<fineGain<<" coarse="<<coarseGain<<" luma="<<lumaGain<<" hue radians="<<hueError<<'\n';
        require(fineGain>(amplitude<.04f ? .32 : .85) && fineGain<1.1,"retain real colored fine texture");
        require(coarseGain>(radius<2 ? .6 : .39) && coarseGain<1.1,"retain slow color structure");
        require(lumaGain>.9 && lumaGain<1.1,"color denoise must preserve fine luminance texture");
        require(hueError<(amplitude<.04f ? .32 : .08),"retain the hue of colored texture");
        require(measure(output,fixture.truth).rmse<measure(fixture.noisy,fixture.truth).rmse,
            "color detail preservation must not bypass noise reduction");
    }
}

void checkHueEdges() {
    for (unsigned seed:{7919u,20021u}) {
        const auto fixture=makeFixture(seed,3,2);
        const auto output=filtered(fixture);
        for (int x:{252,260}) {
            cv::Vec2d bias{};
            for (int y=64;y<448;++y) bias+=colorError(output.at(x,y),fixture.truth.at(x,y));
            bias/=384;
            std::cout<<"color edge seed="<<seed<<" x="<<x<<" bias="<<cv::norm(bias)<<'\n';
            require(cv::norm(bias)<.009,"color boundaries must remain localized");
        }
    }
}

void checkTileSupport() {
    cv::Mat source(321,1105,CV_32FC3);
    std::mt19937 random(7211);
    std::normal_distribution<float> noise(0,.014f);
    for (int y=0;y<source.rows;++y) for (int x=0;x<source.cols;++x) {
        const float detail=.01f*std::sin(.3f*x)*std::cos(.2f*y);
        source.at<cv::Vec3f>(y,x)={.18f+detail+noise(random),.18f+noise(random),.18f-detail+noise(random)};
    }
    NoiseModel model{};
    for (auto& channel:model.sigma) for (auto& scale:channel) for (auto& sigma:scale) sigma=.01f;
    for (auto& channel:model.coarseSigma) for (auto& scale:channel) for (auto& sigma:scale) sigma=.003f;
    std::atomic<bool> used{false};
    const WaveletDenoiseOptions options{true,0,72,100};
    const auto tiled=filter(source,model,options,GpuMode::Off,used);
    cv::Mat expected=source.clone();
    for (int c=1;c<3;++c) {
        const auto plane=waveletTilePlane(source,{0,0,source.cols,source.rows},256,64,c);
        const auto whole=filterPlane(plane,model,options,c,GpuMode::Off,used);
        cv::insertChannel(whole(cv::Rect(256,256,source.cols,source.rows)),expected,c);
    }
    const double maximum=cv::norm(tiled,expected,cv::NORM_INF);
    std::cout<<"tiled/full chroma maximum="<<maximum<<'\n';
    require(maximum<2e-6,"chroma energy windows must remain inside the tile halo");
}
}

int main() {
    bool passed=true;
    for (const auto check:{checkCorrelatedColorNoise,checkColorTexture,checkHueEdges,checkTileSupport}) {
        try {
            check();
        } catch (const std::exception& error) {
            std::cerr<<"FAIL "<<error.what()<<'\n';
            passed=false;
        }
    }
    if (passed) std::cout<<"PASS correlated chroma noise, colored detail and tile boundaries\n";
    return passed ? 0 : 1;
}
