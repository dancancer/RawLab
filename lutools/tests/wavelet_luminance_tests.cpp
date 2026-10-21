// 验证残留噪声形态和物理尺度，不为测试增加公共渲染入口。
#include "../src/core/wavelet_denoise.cpp"
#include <iostream>
#include <random>
#include <stdexcept>

using namespace sony2fuji;

namespace {
void require(bool value,const char* message) {
    if (!value) throw std::runtime_error(message);
}

ImageData flatNoise(unsigned seed,double radius) {
    cv::Mat noise(512,512,CV_32F);
    std::mt19937 random(seed);
    std::normal_distribution<float> gaussian(0,1);
    for (int y=0;y<noise.rows;++y) for (int x=0;x<noise.cols;++x)
        noise.at<float>(y,x)=gaussian(random);
    if (radius>0) cv::GaussianBlur(noise,noise,{},radius);
    cv::Scalar mean,sd;
    cv::meanStdDev(noise,mean,sd);
    noise*=.014/sd[0];
    ImageData image(512,512);
    for (int y=0;y<512;++y) for (int x=0;x<512;++x) {
        const float value=.18f+noise.at<float>(y,x);
        image.at(x,y)={value,value,value};
    }
    return image;
}

struct NoiseShape {double rmse,mean,coarseFraction;};

NoiseShape noiseShape(const ImageData& image) {
    cv::Mat error(image.height,image.width,CV_32F);
    for (int y=0;y<image.height;++y) for (int x=0;x<image.width;++x) {
        const auto& pixel=image.at(x,y);
        require(std::isfinite(pixel.r) && std::isfinite(pixel.g) && std::isfinite(pixel.b),"finite luminance output");
        error.at<float>(y,x)=(pixel.r+pixel.g+pixel.b)/3-.18f;
    }
    const cv::Rect inside(32,32,image.width-64,image.height-64);
    const double rmse=std::sqrt(cv::mean(error(inside).mul(error(inside)))[0]);
    const double bias=cv::mean(error(inside))[0];
    cv::Mat trend,residual,smooth;
    cv::GaussianBlur(error,trend,{},16);
    residual=error-trend;
    cv::GaussianBlur(residual,smooth,{},2);
    cv::Scalar mean,sd,coarseMean,coarseSd;
    cv::meanStdDev(residual(inside),mean,sd);
    cv::meanStdDev(smooth(inside),coarseMean,coarseSd);
    return {rmse,bias,sd[0]>1e-8 ? coarseSd[0]/sd[0] : 0};
}

void checkPhysicalScaleMapping() {
    cv::Mat plane(256,256,CV_32F);
    for (int y=0;y<256;++y) for (int x=0;x<256;++x)
        plane.at<float>(y,x)=std::sin(.17f*x)+std::cos(.31f*y)+.1f*std::sin(.7f*x+.9f*y);
    StationaryWavelet four(plane,4),six(plane,6);
    for (int level=1;level<=4;++level) for (int direction=0;direction<3;++direction) {
        const auto a=four.band(4-level,direction),b=six.band(6-level,direction);
        require(cv::norm(a,b,cv::NORM_INF)<1e-7,"physical fine bands must retain their normalization at deeper SWT depth");
    }
}

void checkFlatNoiseDoesNotClump() {
    bool shapePassed=true;
    for (unsigned seed:{5317u,91823u,4517u,99227u}) for (double radius:{0.,.6}) {
        const auto source=flatNoise(seed,radius);
        auto output=source;
        WaveletDenoiseDiagnostics info;
        require(applyWaveletDenoise(output,{true,10,0,0},&info)==ErrorCode::Success && info.applied,
            "luminance control must actually be filtered");
        auto mild=source;
        require(applyWaveletDenoise(mild,{true,1,0,0})==ErrorCode::Success,"mild luminance filtering");
        const auto before=noiseShape(source),after=noiseShape(output),weaker=noiseShape(mild);
        require(after.rmse<weaker.rmse && weaker.rmse<before.rmse,"luminance slider controls noise removal");
        std::cout<<"seed="<<seed<<" radius="<<radius<<" RMS ratio="<<after.rmse/before.rmse
            <<" coarse fraction="<<before.coarseFraction<<" -> "<<after.coarseFraction<<'\n';
        require(after.rmse<before.rmse*.65,"grain preservation must not bypass luminance noise reduction");
        require(std::abs(after.mean)<.0005,"flat-field luminance must remain unbiased");
        // C5 的强度取舍允许残余频谱变化，但低频噪声的绝对量仍须降低。
        shapePassed&=after.rmse*after.coarseFraction<before.rmse*before.coarseFraction;
    }
    require(shapePassed,"luminance filtering must reduce absolute coarse noise");
}

void checkWeakStructures() {
    for (unsigned seed:{1841u,60973u}) for (const cv::Vec2f frequency : {
        cv::Vec2f{1.1f,.7f},cv::Vec2f{.45f,.29f},cv::Vec2f{.22f,.14f}}) {
        auto noisy=flatNoise(seed,.6),truth=noisy;
        cv::Mat fine(512,512,CV_32F,cv::Scalar(0)),coarse(512,512,CV_32F);
        for (int y=0;y<512;++y) for (int x=0;x<512;++x) {
            if (x>=128 && x<384 && y>=128 && y<384)
                fine.at<float>(y,x)=.012f*std::sin(frequency[0]*x)*std::cos(frequency[1]*y);
            coarse.at<float>(y,x)=.006f*std::sin(.055f*x)*std::cos(.04f*y);
            const float structure=.02f*(x-256)/512+fine.at<float>(y,x)+coarse.at<float>(y,x);
            truth.at(x,y)={.18f+structure,.18f+structure,.18f+structure};
            auto& pixel=noisy.at(x,y);
            pixel.r+=structure; pixel.g+=structure; pixel.b+=structure;
        }
        auto result=noisy;
        WaveletDenoiseDiagnostics info;
        require(applyWaveletDenoise(result,{true,1,0,0},&info)==ErrorCode::Success && info.applied,
            "weak structure fixture must be filtered");
        auto strong=noisy;
        require(applyWaveletDenoise(strong,{true,10,0,0})==ErrorCode::Success,"strong luminance filtering");
        double fineProjection=0,coarseProjection=0,strongFine=0,strongCoarse=0,finePower=0,coarsePower=0,before=0,after=0;
        for (int y=32;y<480;++y) for (int x=32;x<480;++x) {
            const double error=result.at(x,y).r-truth.at(x,y).r;
            const double inputError=noisy.at(x,y).r-truth.at(x,y).r;
            const double f=fine.at<float>(y,x),c=coarse.at<float>(y,x);
            fineProjection+=(error+f)*f; finePower+=f*f;
            coarseProjection+=(error+c)*c; coarsePower+=c*c;
            const double strongError=strong.at(x,y).r-truth.at(x,y).r;
            strongFine+=(strongError+f)*f; strongCoarse+=(strongError+c)*c;
            before+=inputError*inputError; after+=error*error;
        }
        std::cout<<"weak structure seed="<<seed<<" frequency="<<frequency[0]<<" fine="<<fineProjection/finePower
            <<" coarse="<<coarseProjection/coarsePower<<" RMS ratio="<<std::sqrt(after/before)<<'\n';
        require(after<before,"low strength must still reduce noise");
        require(fineProjection/finePower>.7 && fineProjection/finePower<1.1,"retain weak fine texture");
        require(fineProjection>strongFine && coarseProjection>strongCoarse,
            "lower luminance strength must retain more weak structure");
        require(coarseProjection/coarsePower<1.1,"weak coarse lightness must not be amplified");
    }
}

void checkCorrelatedMidScaleNoise() {
    bool reduced=true;
    for (unsigned seed:{14731u,8387u}) {
        constexpr double radius=1.2;
        const auto source=flatNoise(seed,radius);
        auto output=source;
        WaveletDenoiseDiagnostics info;
        require(applyWaveletDenoise(output,{true,10,0,0},&info)==ErrorCode::Success && info.applied,
            "mid-scale noise control must actually be filtered");
        const auto before=noiseShape(source),after=noiseShape(output);
        std::cout<<"mid-scale seed="<<seed<<" radius="<<radius<<" RMS ratio="<<after.rmse/before.rmse<<'\n';
        reduced&=after.rmse<before.rmse*.52;
        require(std::abs(after.mean)<.0005,"correlated flat-field luminance must remain unbiased");
    }
    require(reduced,"luminance must reduce correlated mid-scale clumps without increasing fine-scale strength");
}

void checkTiledLuminanceSupport() {
    cv::Mat transformed(321,1105,CV_32FC3);
    std::mt19937 random(6871);
    std::normal_distribution<float> noise(0,.7f);
    for (int y=0;y<transformed.rows;++y) for (int x=0;x<transformed.cols;++x)
        transformed.at<cv::Vec3f>(y,x)={noise(random)+.4f*std::sin(.03f*x)+(x>1024 ? .3f : 0),0,0};
    NoiseModel model{};
    for (int level=1;level<=6;++level) for (int direction=0;direction<3;++direction) {
        const float sigma=.7f/(1<<level);
        if (level<=4) model.sigma[0][4-level][direction]=sigma;
        else model.lumaCoarseSigma[6-level][direction]=sigma;
    }
    std::atomic<bool> gpuUsed{false};
    const WaveletDenoiseOptions options{true,10,0,0};
    const auto tiled=filter(transformed,model,options,GpuMode::Off,gpuUsed);
    // 整幅一次滤波作为参考；覆盖真实 1024 分块接缝、非整除尺寸和图像外沿。
    const auto plane=waveletTilePlane(transformed,{0,0,transformed.cols,transformed.rows},256,64,0);
    const auto whole=filterPlane(plane,model,options,0,GpuMode::Off,gpuUsed);
    double maximum=0;
    for (int y=0;y<transformed.rows;++y) for (int x=0;x<transformed.cols;++x)
        maximum=std::max(maximum,double(std::abs(tiled.at<cv::Vec3f>(y,x)[0]-whole.at<float>(y+256,x+256))));
    std::cout<<"tiled/full luminance maximum="<<maximum<<'\n';
    require(maximum<2e-6,"six-level luminance and energy window must fit inside each tile halo");
}
}

int main() {
    try {
        checkPhysicalScaleMapping();
        checkFlatNoiseDoesNotClump();
        checkWeakStructures();
        checkCorrelatedMidScaleNoise();
        checkTiledLuminanceSupport();
        std::cout<<"PASS luminance noise shape and physical band mapping\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr<<"FAIL "<<error.what()<<'\n';
        return 1;
    }
}
