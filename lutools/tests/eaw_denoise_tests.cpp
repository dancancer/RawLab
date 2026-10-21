#include <stdexcept>
#include <iostream>
#include <cstring>
#include <random>
#include "../src/core/wavelet_denoise.cpp"
#include "eaw_reference.h"
#include "processing_reference_fixture.h"

using namespace sony2fuji;

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

static ImageData reference(ImageData image, const WaveletDenoiseOptions& options) {
    cv::Mat rgb(image.height,image.width,CV_32FC3,image.pixels.data());
    WaveletNoiseEstimateDiagnostics diagnostics;
    const auto samples=flatSamples(rgb,diagnostics);
    require(samples.size()>=8,"reference needs flat samples");
    const auto model=fitNoise(samples);
    cv::Mat transformed;
    cv::transform(normalize(rgb,model),transformed,opponent());
    c5_reference::EawStatistics statistics;
    constexpr float gain=3.5928893089294434f;
    auto result=c5_reference::filterEawGlobal(transformed,samples,options,{gain},statistics,
        c5_reference::EawShrinkage::Soft,0.2783275280746028f,{gain,1,1,1,gain,gain});
    restore(rgb,std::move(result.front()),model);
    return image;
}

static double difference(const ImageData& a, const ImageData& b) {
    return cv::norm(cv::Mat(a.height,a.width,CV_32FC3,const_cast<RGB*>(a.pixels.data())),
                    cv::Mat(b.height,b.width,CV_32FC3,const_cast<RGB*>(b.pixels.data())),cv::NORM_INF);
}

static void tiledChecks() {
    ImageData source(779,539);
    std::mt19937 random(20261021);
    std::normal_distribution<float> noise(0,1);
    for (int y=0;y<source.height;++y) for (int x=0;x<source.width;++x) {
        const float base=x<193 ? -.005f : x<513 ? .18f : 1.2f;
        const float sigma=std::sqrt(.002f*std::max(0.f,base)+.00002f);
        source.at(x,y)={base+sigma*noise(random),base+sigma*noise(random),base+sigma*noise(random)};
        if (y>251 && y<277 && x>480 && x<551) source.at(x,y).r+=.1f;
    }
    source.at(0,0)={4,-.2f,2}; source.at(778,538)={-.1f,3,2};
    const cv::Mat rgb(source.height,source.width,CV_32FC3,source.pixels.data());
    WaveletNoiseEstimateDiagnostics estimate;
    const auto samples=flatSamples(rgb,estimate);
    require(samples.size()>=8,"tiled fixture needs calibration");
    const auto model=fitNoise(samples);
    require(eaw::noiseScale(model)==1,"reference fixture must be outside low-noise guard");
    WaveletDenoiseAnalysisCache cache;
    for (const WaveletDenoiseOptions options : {WaveletDenoiseOptions{true,10,72,100},
            WaveletDenoiseOptions{true,40,46,50},WaveletDenoiseOptions{true,0,46,0},
            WaveletDenoiseOptions{true,.001f,.001f,100}}) {
        const auto expected=reference(source,options);
        auto cached=source;
        WaveletDenoiseDiagnostics diagnostics;
        require(applyWaveletDenoise(cached,options,&diagnostics,GpuMode::Auto,&cache,"odd-fixture")==ErrorCode::Success,
                "cached C5 filtering");
        require(diagnostics.applied && !diagnostics.gpuUsed,"Auto C5 uses CPU");
        require(difference(cached,expected)<2e-6,"odd dimensions and corners match full-frame C5");
        auto fresh=source;
        require(applyWaveletDenoise(fresh,options)==ErrorCode::Success,"fresh C5 filtering");
        require(difference(cached,fresh)==0,"changed strengths reuse only input statistics");
    }
    const WaveletDenoiseOptions options{true,10,72,100};
    const auto expected=reference(source,options);
    for (int tileSize:{193,384,1024}) {
        const auto analysis=eaw::analyze(rgb,model,samples,tileSize);
        const auto filtered=eaw::filter(rgb,model,analysis,options,1,tileSize);
        require(cv::norm(filtered,cv::Mat(expected.height,expected.width,CV_32FC3,
            const_cast<RGB*>(expected.pixels.data())),cv::NORM_INF)<2e-6,"tile size does not change C5 pixels");
    }
    auto forced=source;
    WaveletDenoiseDiagnostics diagnostics;
    require(applyWaveletDenoise(forced,options,&diagnostics,GpuMode::Force)==ErrorCode::ProcessingError,
            "C5 Force must reject unsupported GPU");
    require(difference(forced,source)==0 && diagnostics.outcome==WaveletDenoiseOutcome::GpuFailure,
            "Force failure is atomic");
    auto zero=source;
    require(applyWaveletDenoise(zero,{true,0,0,100})==ErrorCode::Success && difference(zero,source)==0,
            "zero strengths preserve exact input");
    auto clean=source;
    for (auto& pixel:clean.pixels) pixel={.18f+.0005f*noise(random),.18f+.0005f*noise(random),.18f+.0005f*noise(random)};
    const auto before=clean;
    require(applyWaveletDenoise(clean,options,&diagnostics)==ErrorCode::Success &&
            diagnostics.outcome==WaveletDenoiseOutcome::LowNoise && difference(clean,before)==0,"low noise exact bypass");
    for (float relative:{.019f,.02f,.025f,.03f,.035f,.04f,.05f}) {
        NoiseModel noiseModel{};
        noiseModel.b=cv::Vec3f::all(std::pow(relative*.18f,2));
        require(std::abs(eaw::noiseScale(noiseModel)-std::clamp((relative-.02f)/.02f,0.f,1.f))<1e-6,
                "low-noise strength ramp is continuous");
    }
}

int main() {
    try {
        cv::setNumThreads(4);
        const auto source=processingReferenceFixture();
        const WaveletDenoiseOptions options{true,10,72,100};
        const auto expected=reference(source,options);
        auto actual=source;
        WaveletDenoiseDiagnostics diagnostics;
        require(applyWaveletDenoise(actual,options,&diagnostics)==ErrorCode::Success,"C5 filtering failed");
        require(diagnostics.applied,"C5 must apply to noisy fixture");
        const auto error=difference(actual,expected);
        std::cout<<"C5 reference maximum error: "<<error<<'\n';
        require(error<2e-6,"v2 must reproduce the independent C5 reference");
        tiledChecks();
        return 0;
    } catch (const std::exception& error) {
        std::cerr<<error.what()<<'\n';
        return 1;
    }
}
