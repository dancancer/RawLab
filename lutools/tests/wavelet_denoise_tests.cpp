#include "core/wavelet_denoise.h"
#include "core/wavelet_tile.h"
#include "sony2fuji/color_converter.h"
#include <cassert>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <random>
#include <wavelib.h>
#include <opencv2/imgproc.hpp>

using namespace sony2fuji;

void checkReflectedTilePlanes() {
    for (const auto size : {cv::Size(1800,1025),cv::Size(1025,1800),cv::Size(1025,1025),
                           cv::Size(513,513),cv::Size(1537,1025),cv::Size(65,513),
                           cv::Size(1,1),cv::Size(1,1024),cv::Size(63,1024),
                           cv::Size(64,1),cv::Size(32,24)}) {
        cv::Mat image(size,CV_32FC3);
        for (int y=0;y<image.rows;++y) for (int x=0;x<image.cols;++x)
            image.at<cv::Vec3f>(y,x)={float(x+3*y),float(2*x-y),float(x-7*y)};
        for (const bool coarse : {false,true}) {
            const int centerSize=coarse ? 1024 : 512;
            const int border=coarse ? 256 : 96,alignment=coarse ? 64 : 16;
            cv::Mat padded;
            cv::copyMakeBorder(image,padded,border,border+(alignment-image.rows%alignment)%alignment,
                border,border+(alignment-image.cols%alignment)%alignment,cv::BORDER_REFLECT_101);
            for (const int y : {0,(image.rows-1)/centerSize*centerSize})
                for (const int x : {0,(image.cols-1)/centerSize*centerSize}) {
                    const cv::Rect center(x,y,std::min(centerSize,image.cols-x),std::min(centerSize,image.rows-y));
                    for (int c=0;c<3;++c) {
                        const int radius=c!=0 && coarse ? 256 : 96,divisor=c!=0 && coarse ? 64 : 16;
                        const cv::Rect region(x+border-radius,y+border-radius,
                            (center.width+divisor-1)/divisor*divisor+2*radius,
                            (center.height+divisor-1)/divisor*divisor+2*radius);
                        cv::Mat expected;
                        cv::extractChannel(padded(region),expected,c);
                        const auto actual=waveletTilePlane(image,center,radius,divisor,c);
                        assert(actual.size()==expected.size());
                        assert(cv::norm(actual,expected,cv::NORM_INF)==0);
                    }
                }
        }
    }
    std::cout << "PASS: reflected tile planes match full padding, including thin edge tiles\n";
}

void checkParallelTiles() {
    ImageData source(1537,1025);
    std::mt19937 rng(7419);
    std::normal_distribution<float> noise(0,.014f);
    for (auto& p:source.pixels) p={.18f+noise(rng),.18f+noise(rng),.18f+noise(rng)};
    const int threads=cv::getNumThreads();
    for (const bool coarse : {false,true}) {
        const WaveletDenoiseOptions options{true,10,72,coarse ? 100.f : 0.f};
        auto serial=source,parallel=source;
        WaveletDenoiseDiagnostics first,second;
        cv::setNumThreads(1);
        assert(applyWaveletDenoise(serial,options,&first)==ErrorCode::Success && first.applied);
        cv::setNumThreads(2);
        assert(applyWaveletDenoise(parallel,options,&second)==ErrorCode::Success && second.applied);
        assert(std::memcmp(serial.pixels.data(),parallel.pixels.data(),serial.pixels.size()*sizeof(RGB))==0);
    }
    cv::setNumThreads(threads);
    std::cout << "PASS: multi-tile fine/coarse output is bitwise identical with one/two threads\n";
}

double error(const ImageData& image, float reference, bool chroma = false) {
    double sum = 0;
    for (const auto& p : image.pixels) {
        const double value = chroma ? p.r-p.b : (p.r+p.g+p.b)/3-reference;
        sum += value*value;
    }
    return std::sqrt(sum/image.pixels.size());
}

void checkInversePhases() {
    constexpr int rows=64,columns=48,count=rows*columns;
    auto wave=wave_init("db2");
    auto transform=wt2_init(wave,"swt",rows,columns,4);
    std::vector<double> input(count),output(count);
    for (int y=0;y<rows;++y) for (int x=0;x<columns;++x)
        input[y*columns+x]=.01*x+std::sin(.17*x)*std::cos(.23*y)+.2*std::cos(.11*x+.07*y);
    double* bands=swt2(transform,input.data());
    for (int block=0;block<13;++block) for (int i=0;i<count;++i) bands[block*count+i]*=(block+1)/13.;
    iswt2(transform,bands,output.data());
    // PyWavelets 1.8.0 SWT2/db2 golden values after independent band scaling.
    const struct { int y,x; double value; } expected[] = {
        {0,0,-.2738124900474262},{0,1,-.017185133942234438},{1,0,-.3584904456310259},
        {1,1,-.0998608450955982},{7,19,-.00019012365457268078},{12,31,.17842123406497076},
        {23,15,.06662310447766641},{39,42,-.10603350978044246},{63,47,-.40305160342967083}
    };
    for (const auto& p:expected) assert(std::abs(output[p.y*columns+p.x]-p.value)<1e-11);
    free(bands); wt2_free(transform); wave_free(wave);

    // Independent arbitrary coefficients, not just forward-consistent bands.
    constexpr int tall=256,wide=192,pixels=tall*wide,depth=6;
    wave=wave_init("db2");
    transform=wt2_init(wave,"swt",tall,wide,depth);
    input.assign(pixels,0);
    bands=swt2(transform,input.data());
    for (int block=0;block<3*depth+1;++block) for (int i=0;i<pixels;++i)
        bands[block*pixels+i]=std::sin(.013*i+.37*block)+.2*std::cos(.027*i-.19*block);
    output.resize(pixels);
    iswt2(transform,bands,output.data());
    const struct { int y,x; double value; } arbitrary[] = {
        {0,0,.21513618494114084},{0,191,-.18701069732933243},
        {255,0,-.20572221021538362},{255,191,.24541020657551266},
        {1,1,-.6495666300366107},{17,43,.2587731468533985},
        {127,98,.5216019723216702},{220,154,.4951079559690744}
    };
    for (const auto& p:arbitrary) assert(std::abs(output[p.y*wide+p.x]-p.value)<1e-11);
    free(bands); wt2_free(transform); wave_free(wave);
}

double colorError(const ImageData& image, const ImageData& reference) {
    double sum = 0;
    size_t count = 0;
    for (int y=32;y<image.height-32;++y) for (int x=32;x<image.width-32;++x) {
        const auto& p=image.pixels[y*image.width+x];
        const auto& q=reference.pixels[y*image.width+x];
        const double rg=(p.r-p.g)-(q.r-q.g), bg=(p.b-p.g)-(q.b-q.g);
        sum+=rg*rg+bg*bg;
        count+=2;
    }
    return std::sqrt(sum/count);
}

void checkFineLumaTexture() {
    ImageData truth(512,512);
    for (int y=0;y<512;++y) for (int x=0;x<512;++x) {
        const float texture=x>=128 && x<384 && y>=128 && y<384 ?
            .012f*std::sin(x*1.1f)*std::cos(y*.7f) : 0;
        truth.at(x,y)={.18f+texture,.18f+texture,.18f+texture};
    }
    std::mt19937 rng(85329);
    std::normal_distribution<float> noise(0,.014f);
    auto noisy=truth;
    for (auto& p:noisy.pixels) { p.r+=noise(rng); p.g+=noise(rng); p.b+=noise(rng); }
    auto strong=noisy,detail=noisy,clean=noisy;
    assert(applyWaveletDenoise(strong,{true,65,72,100})==ErrorCode::Success);
    assert(applyWaveletDenoise(detail,{true,0,46,50})==ErrorCode::Success);
    assert(applyWaveletDenoise(clean,{true,10,72,100})==ErrorCode::Success);
    auto retention=[&](const ImageData& image) {
        double projection=0,power=0;
        for (int y=144;y<368;++y) for (int x=144;x<368;++x) {
            const double t=truth.at(x,y).r-.18;
            const auto& p=image.at(x,y);
            projection+=t*((p.r+p.g+p.b)/3.-.18); power+=t*t;
        }
        return projection/power;
    };
    std::cout << "Fine luma texture strong/detail/clean " << retention(strong) << ' ' << retention(detail) << ' ' << retention(clean) << std::endl;
    assert(retention(detail)>.9);
    assert(retention(detail)>retention(clean) && retention(clean)>retention(strong));
    assert(colorError(clean,truth)<colorError(noisy,truth)*.4);
}

void checkCoarseColorNoise() {
    std::mt19937 rng(48103);
    std::normal_distribution<float> noise(0,1);
    ImageData truth(512,512);
    for (auto& pixel : truth.pixels) pixel={.18f,.18f,.18f};
    for (double radius : {7.,14.}) {
        ImageData noisy=truth;
        cv::Mat field(512,512,CV_32FC3);
        for (auto& pixel : noisy.pixels)
            pixel={.18f+.014f*noise(rng),.18f+.014f*noise(rng),.18f+.014f*noise(rng)};
        for (int y=0;y<512;++y) for (int x=0;x<512;++x)
            field.at<cv::Vec3f>(y,x)={noise(rng),noise(rng),noise(rng)};
        cv::GaussianBlur(field,field,{},radius);
        cv::Scalar mean,stddev;
        cv::meanStdDev(field,mean,stddev);
        for (int y=0;y<512;++y) for (int x=0;x<512;++x) {
            auto& p=noisy.pixels[y*512+x];
            const auto f=field.at<cv::Vec3f>(y,x);
            p.r+=.02f*(f[0]-mean[0])/stddev[0];
            p.g+=.02f*(f[1]-mean[1])/stddev[1];
            p.b+=.02f*(f[2]-mean[2])/stddev[2];
        }
        auto result=noisy;
        WaveletDenoiseDiagnostics info;
        assert(applyWaveletDenoise(result,{true,65,72,100},&info)==ErrorCode::Success && info.applied);
        const double ratio=colorError(result,truth)/colorError(noisy,truth);
        std::cout << "Coarse color radius " << radius << " remaining " << ratio << std::endl;
        auto fineOnly=noisy;
        assert(applyWaveletDenoise(fineOnly,{true,65,72,0})==ErrorCode::Success);
        assert(ratio<1 && colorError(result,truth)<colorError(fineOnly,truth) &&
            "Coarse control must reduce broad color noise beyond fine-only filtering");
    }
}

void checkColorStructure() {
    std::mt19937 rng(90317);
    std::normal_distribution<float> noise(0,.014f);
    ImageData truth(512,512);
    for (int y=0;y<512;++y) for (int x=0;x<512;++x) {
        const float color=.018f*std::sin(x/18.f)*std::sin(y/18.f);
        truth.at(x,y)={.18f+color,.18f,.18f-color};
    }
    auto noisy=truth;
    for (auto& p:noisy.pixels) { p.r+=noise(rng); p.g+=noise(rng); p.b+=noise(rng); }
    auto filtered=noisy;
    WaveletDenoiseDiagnostics info;
    assert(applyWaveletDenoise(filtered,{true,0,3,0},&info)==ErrorCode::Success && info.applied);
    double projection=0,power=0;
    for (int y=64;y<448;++y) for (int x=64;x<448;++x) {
        const auto& p=filtered.at(x,y);
        const auto& q=truth.at(x,y);
        projection+=(p.r-p.b)*(q.r-q.b);
        power+=(q.r-q.b)*(q.r-q.b);
    }
    std::cout << "Smooth color amplitude " << projection/power << std::endl;
    assert(projection/power>.9 && projection/power<1.1 && "Low chroma strength with coarse off preserves real color gradients");
    auto clean=truth;
    assert(applyWaveletDenoise(clean,{true,65,72,100},&info)==ErrorCode::Success && !info.applied);
    assert(colorError(clean,truth)==0);
    auto lumaOnly=noisy, coarseWithNoColor=noisy;
    assert(applyWaveletDenoise(lumaOnly,{true,65,0,0})==ErrorCode::Success);
    assert(applyWaveletDenoise(coarseWithNoColor,{true,65,0,100})==ErrorCode::Success);
    for (size_t i=0;i<noisy.pixels.size();++i) {
        const auto& a=lumaOnly.pixels[i];
        const auto& b=coarseWithNoColor.pixels[i];
        assert(a.r==b.r && a.g==b.g && a.b==b.b);
    }
}

void checkNeutralColorBands() {
    std::mt19937 rng(817);
    std::normal_distribution<float> noise(.18f,.014f);
    ImageData image(735,513);
    for (auto& p:image.pixels) { const auto value=noise(rng); p={value,value,value}; }
    auto coarseOff=image;
    assert(applyWaveletDenoise(coarseOff,{true,65,72,0})==ErrorCode::Success);
    assert(applyWaveletDenoise(image,{true,65,72,100})==ErrorCode::Success);
    for (size_t i=0;i<image.pixels.size();++i) {
        const auto& p=image.pixels[i]; const auto& q=coarseOff.pixels[i];
        assert(std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b));
        assert(std::abs(p.r-q.r)<1e-6 && std::abs(p.g-q.g)<1e-6 && std::abs(p.b-q.b)<1e-6);
        assert(std::abs(p.r-p.g)<1e-6 && std::abs(p.r-p.b)<1e-6);
    }
    for (auto& p:image.pixels) { const auto value=noise(rng); p={value,noise(rng),value}; }
    assert(applyWaveletDenoise(image,{true,65,72,100})==ErrorCode::Success);
    for (const auto& p:image.pixels) {
        assert(std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b));
        assert(std::abs(p.r-p.b)<1e-6);
    }
}

void checkColorEdgesAndRamp() {
    std::mt19937 rng(36719);
    std::normal_distribution<float> noise(0,.014f);
    ImageData truth(597,389);
    for (int y=0;y<truth.height;++y) for (int x=0;x<truth.width;++x) {
        const float ramp=.06f*(x/float(truth.width)-.5f), vertical=.04f*(y/float(truth.height)-.5f);
        const float edge=x>truth.width/2 ? .06f : -.06f;
        truth.at(x,y)={.18f+ramp+edge,.18f+vertical,.18f-ramp-edge};
    }
    auto result=truth;
    for (auto& p:result.pixels) { p.r+=noise(rng); p.g+=noise(rng); p.b+=noise(rng); }
    WaveletDenoiseDiagnostics info;
    assert(applyWaveletDenoise(result,{true,65,72,100},&info)==ErrorCode::Success && info.applied);
    double meanError[2]={},count[2]={};
    for (int y=64;y<truth.height-64;++y) for (int x=64;x<truth.width-64;++x) {
        const auto& p=result.at(x,y); const auto& q=truth.at(x,y);
        assert(std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b));
        const int side=x>truth.width/2;
        meanError[side]+=(p.r-p.b)-(q.r-q.b); ++count[side];
    }
    for (int side=0;side<2;++side) assert(std::abs(meanError[side]/count[side])<.006);
    for (int x : {truth.width/2-3,truth.width/2+3}) {
        double actual=0,expected=0;
        for (int y=64;y<truth.height-64;++y) {
            const auto& p=result.at(x,y); const auto& q=truth.at(x,y);
            actual+=p.r-p.b; expected+=q.r-q.b;
        }
        assert(actual/expected>.9 && actual/expected<1.1 && "Coarse filtering must not smear a color boundary");
    }
}

void checkAnalysisReuse() {
    ImageData source(256,256);
    std::mt19937 rng(1539);
    std::normal_distribution<float> noise(.18f,.014f);
    for (auto& p:source.pixels) p={noise(rng),noise(rng),noise(rng)};
    WaveletDenoiseAnalysisCache cache;
    int index=0;
    for (const auto& options : {WaveletDenoiseOptions{true,20,30,0}, {true,70,30,0},
                               {true,70,75,0}, {true,70,75,70}, {true,70,75,95}}) {
        auto cached=source, independent=source;
        WaveletDenoiseDiagnostics info;
        assert(applyWaveletDenoise(cached,options,&info,GpuMode::Off,&cache,"source-a")==ErrorCode::Success);
        assert(info.applied && info.analysisReused==(index>0));
        assert(info.coarseAnalysisReused==(index>0));
        assert(applyWaveletDenoise(independent,options)==ErrorCode::Success);
        for (size_t i=0;i<cached.pixels.size();++i) {
            const auto& a=cached.pixels[i]; const auto& b=independent.pixels[i];
            assert(a.r==b.r && a.g==b.g && a.b==b.b);
        }
        ++index;
    }
    WaveletDenoiseDiagnostics info;
    cache.clear();
    index=0;
    for (const auto& options : {WaveletDenoiseOptions{true,0,72,100}, {true,10,0,0}, {true,10,72,100}}) {
        auto cached=source,independent=source;
        assert(applyWaveletDenoise(cached,options,&info,GpuMode::Off,&cache,"chroma-then-luma")==ErrorCode::Success);
        assert(info.applied && info.analysisReused==(index>0) && info.coarseAnalysisReused==(index>0));
        assert(applyWaveletDenoise(independent,options)==ErrorCode::Success);
        assert(std::memcmp(cached.pixels.data(),independent.pixels.data(),cached.pixels.size()*sizeof(RGB))==0);
        ++index;
    }
    auto image=source;
    assert(applyWaveletDenoise(image,{true,70,75,95},&info,GpuMode::Off,&cache,"source-b")==ErrorCode::Success);
    assert(!info.analysisReused && !info.coarseAnalysisReused);
    cache.clear(); image=source;
    assert(applyWaveletDenoise(image,{true,70,75,95},&info,GpuMode::Off,&cache,"source-b")==ErrorCode::Success);
    assert(!info.analysisReused);
    image=ImageData(32,32);
    assert(applyWaveletDenoise(image,{true,40,46,50},&info,GpuMode::Off,&cache,"source-b")==ErrorCode::Success);
    assert(!info.applied && !info.analysisReused);
    assert(applyWaveletDenoise(image,{true,70,75,95},&info,GpuMode::Off,&cache,"source-b")==ErrorCode::Success);
    assert(!info.applied && info.analysisReused);
    assert(applyWaveletDenoise(image,{true,-1,75,95},&info,GpuMode::Off,&cache,"source-b")==ErrorCode::InvalidFormat);
    assert(!info.analysisReused);
    assert(applyWaveletDenoise(image,{false,40,46,50},&info,GpuMode::Off,&cache,"source-b")==ErrorCode::Success);
    assert(!info.analysisReused);
}

void checkImmutableSourceReload() {
    ImageData source(256,256);
    std::mt19937 rng(7381);
    std::normal_distribution<float> noise(.18f,.014f);
    for (auto& p:source.pixels) p={noise(rng),noise(rng),noise(rng)};
    const auto original=source;
    auto converted=source;
    assert(ColorConverter().convertImage(converted,ColorSpace::AdobeRGB,ColorSpace::sRGB)==ErrorCode::Success);
    WaveletDenoiseAnalysisCache cache;
    int index=0;
    for (const auto& options : {WaveletDenoiseOptions{true,10,72,0}, {true,10,72,100}, {true,25,60,80}}) {
        auto retained=converted,reloaded=converted;
        WaveletDenoiseDiagnostics info;
        assert(applyWaveletDenoise(retained,options)==ErrorCode::Success);
        assert(applyWaveletDenoise(reloaded,options,&info,GpuMode::Off,&cache,"immutable-a",&source,
            ColorSpace::AdobeRGB)==ErrorCode::Success);
        assert(info.applied && info.analysisReused==(index>0) && info.coarseAnalysisReused==(index>0));
        assert(reloaded.width==retained.width && reloaded.height==retained.height);
        assert(std::memcmp(retained.pixels.data(),reloaded.pixels.data(),retained.pixels.size()*sizeof(RGB))==0);
        assert(std::memcmp(source.pixels.data(),original.pixels.data(),source.pixels.size()*sizeof(RGB))==0);
        ++index;
    }
    auto invalid=source;
    invalid.pixels.push_back({0,0,0});
    auto image=converted;
    assert(applyWaveletDenoise(image,{true,10,72,100},nullptr,GpuMode::Off,nullptr,{},&invalid,
        ColorSpace::AdobeRGB)==ErrorCode::InvalidFormat);
    assert(std::memcmp(image.pixels.data(),converted.pixels.data(),converted.pixels.size()*sizeof(RGB))==0);
#if defined(TEST_WAVELET_GPU_DISABLED)
    // 无 GPU 构建可确定触发 Force 失败，覆盖 Auto 重新载入工作图的重试路径。
    const WaveletDenoiseOptions legacy{true,10,72,100,ProcessingVersion::Legacy};
    WaveletDenoiseAnalysisCache retryCache;
    WaveletDenoiseDiagnostics info;
    image=converted;
    assert(applyWaveletDenoise(image,legacy,&info,GpuMode::Force,&retryCache,"retry-a",&source,
        ColorSpace::AdobeRGB)==ErrorCode::ProcessingError);
    assert(image.pixels.empty());
    assert(applyWaveletDenoise(image,legacy,&info,GpuMode::Off,&retryCache,"retry-a",&source,
        ColorSpace::AdobeRGB)==ErrorCode::Success);
    assert(info.applied && info.analysisReused && info.coarseAnalysisReused && !info.gpuUsed);
    auto independent=converted;
    assert(applyWaveletDenoise(independent,legacy)==ErrorCode::Success);
    assert(image.pixels.size()==independent.pixels.size());
    assert(std::memcmp(image.pixels.data(),independent.pixels.data(),image.pixels.size()*sizeof(RGB))==0);
    assert(std::memcmp(source.pixels.data(),original.pixels.data(),source.pixels.size()*sizeof(RGB))==0);
    std::cout << "PASS: released working image is reloaded after Force GPU failure\n";
#endif
    std::cout << "PASS: immutable AdobeRGB reload preserves pixels and analysis reuse\n";
}

int main(int argc, char** argv) {
    if (argc == 6) {
        std::ifstream input(argv[1],std::ios::binary);
        uint32_t size[2];
        input.read(reinterpret_cast<char*>(size),sizeof(size));
        assert(input && size[0] && size[1]);
        ImageData image(size[0],size[1]);
        input.read(reinterpret_cast<char*>(image.pixels.data()),image.pixels.size()*sizeof(RGB));
        assert(input);
        WaveletDenoiseOptions options{true,std::stof(argv[3]),std::stof(argv[4]),std::stof(argv[5])};
        WaveletDenoiseDiagnostics info;
        assert(applyWaveletDenoise(image,options,&info) == ErrorCode::Success);
        std::ofstream output(argv[2],std::ios::binary);
        output.write(reinterpret_cast<const char*>(size),sizeof(size));
        output.write(reinterpret_cast<const char*>(image.pixels.data()),image.pixels.size()*sizeof(RGB));
        assert(output);
        std::cout << info.flatTiles << ' ' << info.applied;
        for (int c=0;c<3;++c) std::cout << ' ' << info.a[c] << ' ' << info.b[c];
        std::cout << '\n';
        return 0;
    }
    checkReflectedTilePlanes();
    checkParallelTiles();
    checkAnalysisReuse();
    checkImmutableSourceReload();
    checkInversePhases();
    checkFineLumaTexture();
    checkNeutralColorBands();
    checkCoarseColorNoise();
    checkColorStructure();
    checkColorEdgesAndRamp();
    ImageData source(256,256);
    std::mt19937 rng(219);
    std::normal_distribution<float> noise(0,.014f);
    for (auto& p : source.pixels) p = {.18f+noise(rng),.18f+noise(rng),.18f+noise(rng)};
    auto image = source;
    WaveletDenoiseOptions options;
    assert(applyWaveletDenoise(image,options) == ErrorCode::Success);
    for (size_t i=0;i<image.pixels.size();++i) assert(image.pixels[i].r==source.pixels[i].r);
    options.enabled = true;
    WaveletDenoiseDiagnostics info;
    assert(applyWaveletDenoise(image,options,&info) == ErrorCode::Success);
    assert(info.applied && info.flatTiles>=8);
    assert(error(image,.18f)<.5*error(source,.18f));
    assert(error(image,0,true)<.4*error(source,0,true));
    const auto detail = image;
    image = source; options.luma = 65; options.chroma = 72; options.coarse = 100;
    assert(applyWaveletDenoise(image,options) == ErrorCode::Success);
    assert(error(image,.18f)<error(detail,.18f));
    options.luma = options.chroma = 0;
    image = source;
    assert(applyWaveletDenoise(image,options) == ErrorCode::Success);
    for (size_t i=0;i<image.pixels.size();++i) assert(image.pixels[i].r==source.pixels[i].r);
    options.luma = -1;
    assert(applyWaveletDenoise(image,options)==ErrorCode::InvalidFormat);
    options.luma = std::numeric_limits<float>::quiet_NaN();
    assert(applyWaveletDenoise(image,options)==ErrorCode::InvalidFormat);
    image = ImageData(256,256);
    for (auto& p : image.pixels) p = {.18f,.18f,.18f};
    options = {true,40,46,50};
    assert(applyWaveletDenoise(image,options,&info)==ErrorCode::Success);
    assert(!info.applied && image.pixels[0].r==.18f);
    image=ImageData(384,256);
    std::normal_distribution<float> standard(0,1);
    for (int y=0;y<256;++y) for (int x=0;x<384;++x) {
        const float value=x<128 ? .03f : (x<256 ? .15f : .5f);
        image.pixels[y*384+x]={value+standard(rng)*std::sqrt(.2f*value),
            value+standard(rng)*std::sqrt(.07f*value+.003f),value+standard(rng)*std::sqrt(.13f*value)};
    }
    assert(applyWaveletDenoise(image,{true,100,100,100},&info)==ErrorCode::Success && info.applied);
    for (const auto& p:image.pixels) {
        assert(std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b));
        assert(std::max({std::abs(p.r),std::abs(p.g),std::abs(p.b)})<2);
    }
    std::cout << "PASS: wavelet off/zero identity, luma/chroma noise, strength, validation, flat fallback\n";
}
