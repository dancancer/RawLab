#include "wavelet_denoise.h"
#include "gpu/denoise.h"
#include <atomic>
#include <cmath>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <memory>
#include <vector>

#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <wavelib.h>

namespace {
struct WaveletGpuFailure {};
constexpr int levels = 4, halo = 96, tileSize = 512;
constexpr int chromaLevels = 6, coarseHalo = 256;
using Bands = std::array<std::array<float,3>,levels>;
struct Sample { int x, y; cv::Vec3f mean, variance; };
struct NoiseModel {
    cv::Vec3f a, b;
    std::array<Bands,3> sigma;
    std::array<std::array<std::array<float,3>,chromaLevels-levels>,2> coarseSigma{};
};

float quantile(std::vector<float> values, double fraction = .5) {
    if (values.empty()) return 0;
    const double position = (values.size()-1)*fraction;
    const size_t index = static_cast<size_t>(position);
    std::nth_element(values.begin(),values.begin()+index,values.end());
    const float lower = values[index];
    if (index+1 == values.size()) return lower;
    return lower + static_cast<float>(position-index)*(*std::min_element(values.begin()+index+1,values.end())-lower);
}

float mad(std::vector<float> values) {
    const float median = quantile(values);
    for (auto& value : values) value = std::abs(value-median);
    return quantile(std::move(values))/.67448975f;
}

cv::Matx33f opponent() {
    const float a=1/std::sqrt(3.f), b=1/std::sqrt(2.f), c=1/std::sqrt(6.f);
    return {a,a,a, b,0,-b, c,-2*c,c};
}

std::vector<int> positions(int length) {
    const int count = std::min(12,std::max(1,length/64));
    std::vector<int> result;
    for (int i=0;i<count;++i)
        result.push_back(count==1 ? 0 : static_cast<int>(double(i)*std::max(0,length-64)/(count-1)));
    return result;
}

bool periodic(const cv::Mat& residual) {
    const int height=residual.rows, width=residual.cols;
    std::vector<float> power(height*(width/2+1),0);
    for (int c=0;c<3;++c) {
        cv::Mat plane(height,width,CV_64F), spectrum;
        for (int y=0;y<height;++y) for (int x=0;x<width;++x) {
            const double window=(.5-.5*std::cos(2*CV_PI*y/(height-1)))*(.5-.5*std::cos(2*CV_PI*x/(width-1)));
            plane.at<double>(y,x)=residual.at<cv::Vec3f>(y,x)[c]*window;
        }
        cv::dft(plane,spectrum,cv::DFT_COMPLEX_OUTPUT);
        for (int y=0;y<height;++y) for (int x=0;x<=width/2;++x) {
            const auto value=spectrum.at<cv::Vec2d>(y,x);
            power[y*(width/2+1)+x]+=static_cast<float>(value.dot(value));
        }
    }
    double sum=0,peak=0;
    for (float value:power) sum+=value;
    const size_t count=std::max<size_t>(1,power.size()/100);
    std::nth_element(power.begin(),power.end()-count,power.end());
    for (auto it=power.end()-count;it!=power.end();++it) peak+=*it;
    return peak/std::max(sum,1e-20)>.35;
}

std::vector<Sample> flatSamples(const cv::Mat& rgb) {
    std::vector<Sample> samples;
    for (int y:positions(rgb.rows)) for (int x:positions(rgb.cols)) {
        const cv::Mat patch=rgb(cv::Rect(x,y,std::min(64,rgb.cols-x),std::min(64,rgb.rows-y))).clone();
        // Calibration uses full 64-pixel tiles, keeping SWT's size contract explicit.
        if (patch.rows<64 || patch.cols<64) continue;
        cv::Mat smooth;
        cv::GaussianBlur(patch,smooth,{},3);
        const cv::Mat residual=patch-smooth;
        Sample sample{x,y,{}, {}};
        bool flat=true, noisy=false;
        for (int c=0;c<3;++c) {
            std::vector<float> values,means,gradient;
            for (int py=0;py<64;++py) for (int px=0;px<64;++px) {
                values.push_back(residual.at<cv::Vec3f>(py,px)[c]);
                means.push_back(patch.at<cv::Vec3f>(py,px)[c]);
                if (py<63 && px<63) {
                    const float current=smooth.at<cv::Vec3f>(py,px)[c];
                    gradient.push_back(std::max(std::abs(current-smooth.at<cv::Vec3f>(py+1,px)[c]),
                        std::abs(current-smooth.at<cv::Vec3f>(py,px+1)[c])));
                }
            }
            const float sigma=mad(std::move(values));
            noisy |= sigma>=1e-7f;
            if (quantile(std::move(gradient),.9)>std::max(.00002f,.35f*sigma)) flat=false;
            sample.mean[c]=quantile(std::move(means));
            sample.variance[c]=sigma*sigma;
        }
        if (flat && noisy && !periodic(residual)) samples.push_back(sample);
    }
    return samples;
}

// 二变量凸回归用 soft-L1 的迭代加权最小二乘；边界解显式检查，避免负方差。
NoiseModel fitNoise(const std::vector<Sample>& samples) {
    NoiseModel model{};
    for (int c=0;c<3;++c) {
        std::vector<float> means,variances;
        for (const auto& sample:samples) {
            means.push_back(std::max(0.f,sample.mean[c]));
            variances.push_back(sample.variance[c]);
        }
        const double scale=std::max(double(quantile(variances)),1e-12);
        const auto range=std::minmax_element(means.begin(),means.end());
        if (*range.second-*range.first<.01f) { model.a[c]=0; model.b[c]=scale; continue; }
        double a=scale/std::max(double(quantile(means)),.01), b=scale*.1;
        for (int iteration=0;iteration<100;++iteration) {
            double sw=0,sx=0,sy=0,sxx=0,sxy=0;
            for (size_t i=0;i<means.size();++i) {
                const double x=means[i], y=variances[i];
                const double r=(a*x+b-y)/(scale*.3), weight=1/std::sqrt(1+r*r);
                sw+=weight; sx+=weight*x; sy+=weight*y; sxx+=weight*x*x; sxy+=weight*x*y;
            }
            const double determinant=sw*sxx-sx*sx;
            double nextA=0, nextB=sy/sw;
            if (determinant>1e-20) {
                nextA=(sw*sxy-sx*sy)/determinant;
                nextB=(sy-nextA*sx)/sw;
            }
            if (nextA<0 || nextB<1e-12) {
                const double boundaryA=std::max(0.,(sxy-1e-12*sx)/std::max(sxx,1e-20));
                const double boundaryB=std::max(1e-12,sy/sw);
                const double zeroSlope=sw*boundaryB*boundaryB-2*sy*boundaryB;
                const double zeroFloor=sxx*boundaryA*boundaryA+sw*1e-24+2*sx*boundaryA*1e-12-2*sxy*boundaryA-2*sy*1e-12;
                if (zeroSlope<=zeroFloor) { nextA=0; nextB=boundaryB; }
                else { nextA=boundaryA; nextB=1e-12; }
            }
            const double change=std::abs(nextA-a)+std::abs(nextB-b);
            a=nextA; b=nextB;
            if (change<1e-9*std::max(scale,std::abs(a)+std::abs(b))) break;
        }
        model.a[c]=static_cast<float>(a); model.b[c]=static_cast<float>(b);
    }
    return model;
}

cv::Mat normalize(const cv::Mat& rgb,const NoiseModel& model) {
    cv::Mat result(rgb.size(),CV_32FC3);
    cv::parallel_for_(cv::Range(0,rgb.rows),[&](const cv::Range& range) {
        for (int y=range.start;y<range.end;++y) {
            const auto* input=rgb.ptr<cv::Vec3f>(y);
            auto* output=result.ptr<cv::Vec3f>(y);
            for (int x=0;x<rgb.cols;++x) for (int c=0;c<3;++c) {
                const float a=std::max(model.a[c],1e-12f), b=std::max(model.b[c],1e-12f)+.375f*a*a;
                const float value=input[x][c], root=std::sqrt(b);
                output[x][c]=value>=0 ? 2*value/(std::sqrt(a*value+b)+root) : value/root;
            }
        }
    });
    return result;
}

class StationaryWavelet {
    std::unique_ptr<wave_set,decltype(&wave_free)> wave{wave_init("db2"),wave_free};
    std::unique_ptr<wt2_set,decltype(&wt2_free)> transform;
    std::unique_ptr<double,decltype(&std::free)> data{nullptr,std::free};
    size_t count;
    int depth;
public:
    explicit StationaryWavelet(const cv::Mat& plane,int levelCount=levels)
        : transform(wt2_init(wave.get(),"swt",plane.rows,plane.cols,levelCount),wt2_free),
          count(plane.total()),depth(levelCount) {
        std::vector<double> input(count);
        for (int y=0;y<plane.rows;++y) for (int x=0;x<plane.cols;++x) input[y*plane.cols+x]=plane.at<float>(y,x);
        data.reset(swt2(transform.get(),input.data()));
        if (!data) throw std::bad_alloc();
    }
    cv::Mat band(int scale,int direction) const {
        const int block=1+scale*3+direction;
        const float divisor=static_cast<float>(1<<(depth-scale));
        cv::Mat result(transform->rows,transform->cols,CV_32F);
        for (size_t i=0;i<count;++i) result.ptr<float>()[i]=static_cast<float>(data.get()[block*count+i]/divisor);
        return result;
    }
    void setBand(int scale,int direction,const cv::Mat& values) {
        const int block=1+scale*3+direction;
        const double multiplier=1<<(depth-scale);
        for (size_t i=0;i<count;++i) data.get()[block*count+i]=values.ptr<float>()[i]*multiplier;
    }
    cv::Mat reconstruct() {
        std::vector<double> output(count);
        iswt2(transform.get(),data.get(),output.data());
        cv::Mat result(transform->rows,transform->cols,CV_32F);
        for (size_t i=0;i<count;++i) result.ptr<float>()[i]=static_cast<float>(output[i]);
        return result;
    }
};

void calibrateBands(NoiseModel& model,const cv::Mat& transformed,const std::vector<Sample>& samples) {
    const int count=std::min(24,static_cast<int>(samples.size()));
    std::array<std::array<std::array<std::vector<float>,3>,levels>,3> measurements;
    for (auto& channel:measurements) for (auto& scale:channel) for (auto& direction:scale) direction.resize(count);
    cv::parallel_for_(cv::Range(0,count),[&](const cv::Range& range) {
        for (int i=range.start;i<range.end;++i) {
            const auto& sample=samples[static_cast<size_t>(double(i)*(samples.size()-1)/(count-1))];
            cv::Mat patch;
            cv::copyMakeBorder(transformed(cv::Rect(sample.x,sample.y,64,64)).clone(),patch,halo,halo,halo,halo,cv::BORDER_REFLECT_101);
            for (int c=0;c<3;++c) {
                cv::Mat plane;
                cv::extractChannel(patch,plane,c);
                StationaryWavelet transform(plane);
                for (int scale=0;scale<levels;++scale) for (int direction=0;direction<3;++direction) {
                    const auto band=transform.band(scale,direction);
                    std::vector<float> values;
                    for (int y=halo;y<halo+64;++y) for (int x=halo;x<halo+64;++x) values.push_back(band.at<float>(y,x));
                    measurements[c][scale][direction][i]=mad(std::move(values));
                }
            }
        }
    },4);
    for (int c=0;c<3;++c) for (int scale=0;scale<levels;++scale) for (int direction=0;direction<3;++direction)
        model.sigma[c][scale][direction]=std::max(1e-6f,quantile(std::move(measurements[c][scale][direction])));
}

void calibrateCoarseBands(NoiseModel& model,const cv::Mat& transformed,const std::vector<Sample>& samples) {
    constexpr int extraLevels=chromaLevels-levels;
    using CoarseCoefficients=std::array<std::array<std::array<std::vector<float>,3>,extraLevels>,2>;
    CoarseCoefficients measurements;
    std::array<std::array<std::vector<float>,3>,extraLevels> sharedNoise;
    const int count=std::min(16,static_cast<int>(samples.size()));
    for (auto& channel:measurements) for (auto& scale:channel) for (auto& direction:scale) direction.resize(count);
    for (auto& scale:sharedNoise) for (auto& direction:scale) direction.resize(count);
    const int width=std::min(128,transformed.cols/64*64),height=std::min(128,transformed.rows/64*64);
    cv::Mat padded;
    cv::copyMakeBorder(transformed,padded,coarseHalo,coarseHalo,coarseHalo,coarseHalo,cv::BORDER_REFLECT_101);
    cv::parallel_for_(cv::Range(0,count),[&](const cv::Range& range) {
        for (int i=range.start;i<range.end;++i) {
            const auto& sample=samples[static_cast<size_t>(double(i)*(samples.size()-1)/(count-1))];
            const int x=std::clamp(sample.x+32-width/2,0,transformed.cols-width);
            const int y=std::clamp(sample.y+32-height/2,0,transformed.rows-height);
            // 粗层读取真实邻域，不能靠重复反射 64 像素样块来估计更大色斑。
            const auto patch=padded(cv::Rect(x,y,width+2*coarseHalo,height+2*coarseHalo));
            CoarseCoefficients coefficients;
            for (int c=1;c<3;++c) {
                cv::Mat plane;
                cv::extractChannel(patch,plane,c);
                StationaryWavelet transform(plane,chromaLevels);
                for (int scale=0;scale<extraLevels;++scale) for (int direction=0;direction<3;++direction) {
                    const auto band=transform.band(scale,direction);
                    std::vector<float> values;
                    values.reserve(width*height);
                    for (int py=coarseHalo;py<coarseHalo+height;++py) for (int px=coarseHalo;px<coarseHalo+width;++px)
                        values.push_back(band.at<float>(py,px));
                    measurements[c-1][scale][direction][i]=mad(values);
                    coefficients[c-1][scale][direction]=std::move(values);
                }
            }
            for (int scale=0;scale<extraLevels;++scale) for (int direction=0;direction<3;++direction) {
                const auto& u=coefficients[0][scale][direction];
                const auto& v=coefficients[1][scale][direction];
                double su=0,sv=0,suu=0,svv=0,suv=0;
                for (size_t j=0;j<u.size();++j) {
                    su+=u[j]; sv+=v[j]; suu+=double(u[j])*u[j];
                    svv+=double(v[j])*v[j]; suv+=double(u[j])*v[j];
                }
                const double count=u.size();
                const double vu=(suu-su*su/count)/(count-1),vv=(svv-sv*sv/count)/(count-1);
                const double covariance=(suv-su*sv/count)/(count-1);
                // 单一色相渐变主要沿一个方向变化；较小特征值只补充两方向共有的波动。
                const double variance=.5*(vu+vv-std::hypot(vu-vv,2*covariance));
                sharedNoise[scale][direction][i]=static_cast<float>(std::sqrt(std::max(0.,variance)));
            }
        }
    },4);
    for (int c=1;c<3;++c) for (int scale=0;scale<extraLevels;++scale) for (int direction=0;direction<3;++direction) {
        const float anchor=model.sigma[c][0][direction];
        const float correlation=std::clamp(anchor/model.sigma[c][1][direction],1.f,2.f);
        // 用细层的相关噪声证据限制粗层估计，避免真实颜色渐变被当成噪声。
        const float limit=std::max(anchor*correlation/std::sqrt(static_cast<float>(1<<(extraLevels-scale))),
            quantile(sharedNoise[scale][direction]));
        model.coarseSigma[c-1][scale][direction]=std::max(1e-6f,
            std::min(limit,quantile(std::move(measurements[c-1][scale][direction]))));
    }
}

cv::Mat filterPlane(const cv::Mat& plane,const NoiseModel& model,const sony2fuji::WaveletDenoiseOptions& options,int channel,
                    sony2fuji::GpuMode gpuMode,std::atomic<bool>& gpuUsed) {
    const float strength=channel==0 ? options.luma*.02f : options.chroma*.025f;
    if (strength==0) return plane.clone();
    const int depth=channel!=0 && options.coarse>0 ? chromaLevels : levels;
    if (gpuMode != sony2fuji::GpuMode::Off) {
        sony2fuji::WaveletFilterSettings settings;
        settings.depth = depth;
        for (int scale = 0; scale < depth; ++scale) {
            const int sourceLevel = depth - scale;
            settings.thresholdScale[scale] = strength * (sourceLevel >= levels ?
                (channel == 0 ? .5f : options.coarse * .01f) : 1);
            for (int direction = 0; direction < 3; ++direction)
                settings.sigma[scale * 3 + direction] = sourceLevel > levels ?
                    model.coarseSigma[channel - 1][scale][direction] : model.sigma[channel][levels - sourceLevel][direction];
        }
        cv::Mat result(plane.size(), CV_32F);
        if (sony2fuji::gpuWaveletFilter(plane.ptr<float>(), plane.cols, plane.rows, settings, result.ptr<float>())) {
            gpuUsed.store(true, std::memory_order_relaxed);
            return result;
        }
        if (gpuMode == sony2fuji::GpuMode::Force) throw WaveletGpuFailure{};
    }
    StationaryWavelet transform(plane,depth);
    for (int scale=0;scale<depth;++scale) {
        const int sourceLevel=depth-scale;
        // 亮度粗层保持保守；第三个参数只改变粗尺度色度，不连带改变亮度参数。
        const float multiplier=sourceLevel>=levels ? (channel==0 ? .5f : options.coarse*.01f) : 1;
        for (int direction=0;direction<3;++direction) {
            cv::Mat band=transform.band(scale,direction),power;
            const int window=sourceLevel>levels ? (1<<(sourceLevel-1))+1 : 7;
            cv::boxFilter(band.mul(band),power,-1,{window,window});
            const float sigma=sourceLevel>levels ? model.coarseSigma[channel-1][scale][direction] :
                model.sigma[channel][levels-sourceLevel][direction];
            const float variance=sigma*sigma;
            for (int y=0;y<band.rows;++y) {
                auto* values=band.ptr<float>(y);
                const auto* energy=power.ptr<float>(y);
                for (int x=0;x<band.cols;++x) {
                    const float threshold=strength*multiplier*variance/std::sqrt(std::max(energy[x]-variance,.05f*variance));
                    values[x]=std::copysign(std::max(std::abs(values[x])-threshold,0.f),values[x]);
                }
            }
            transform.setBand(scale,direction,band);
        }
    }
    return transform.reconstruct();
}

cv::Mat filter(const cv::Mat& transformed,const NoiseModel& model,const sony2fuji::WaveletDenoiseOptions& options,
                sony2fuji::GpuMode gpuMode,std::atomic<bool>& gpuUsed) {
    const int height=transformed.rows,width=transformed.cols;
    const bool coarse=options.chroma>0 && options.coarse>0;
    const int centerSize=coarse ? 1024 : tileSize;
    const int border=coarse ? coarseHalo : halo, alignment=coarse ? 1<<chromaLevels : 1<<levels;
    cv::Mat padded,output(transformed.size(),CV_32FC3);
    cv::copyMakeBorder(transformed,padded,border,border+(alignment-height%alignment)%alignment,
        border,border+(alignment-width%alignment)%alignment,cv::BORDER_REFLECT_101);
    const int columns=(width+centerSize-1)/centerSize, rows=(height+centerSize-1)/centerSize;
    cv::parallel_for_(cv::Range(0,columns*rows),[&](const cv::Range& range) {
        for (int index=range.start;index<range.end;++index) {
            const int x=index%columns*centerSize,y=index/columns*centerSize;
            const int w=std::min(centerSize,width-x),h=std::min(centerSize,height-y);
            for (int c=0;c<3;++c) {
                const int radius=c!=0 && coarse ? coarseHalo : halo, divisor=c!=0 && coarse ? alignment : 16;
                const cv::Mat tile=padded(cv::Rect(x+border-radius,y+border-radius,
                    ((w+divisor-1)/divisor)*divisor+2*radius,((h+divisor-1)/divisor)*divisor+2*radius));
                cv::Mat plane;
                cv::extractChannel(tile,plane,c);
                const auto filtered=filterPlane(plane,model,options,c,gpuMode,gpuUsed);
                for (int py=0;py<h;++py) for (int px=0;px<w;++px)
                    output.at<cv::Vec3f>(y+py,x+px)[c]=filtered.at<float>(radius+py,radius+px);
            }
        }
    },coarse ? 4 : 8);
    return output;
}

void restore(cv::Mat& rgb,const cv::Mat& original,const cv::Mat& filtered,const NoiseModel& model) {
    cv::Mat normalized;
    cv::transform(filtered,normalized,opponent().t());
    cv::Mat difference=original-normalized,removed;
    cv::GaussianBlur(difference.mul(difference),removed,{},3);
    cv::parallel_for_(cv::Range(0,rgb.rows),[&](const cv::Range& range) {
        for (int y=range.start;y<range.end;++y) for (int x=0;x<rgb.cols;++x) for (int c=0;c<3;++c) {
            const float a=std::max(model.a[c],1e-12f), b=std::max(model.b[c],1e-12f)+.375f*a*a;
            const float value=normalized.at<cv::Vec3f>(y,x)[c], positive=std::max(value,0.f);
            rgb.at<cv::Vec3f>(y,x)[c]=std::sqrt(b)*value+.25f*a*positive*positive+
                (value>0 ? .25f*a*removed.at<cv::Vec3f>(y,x)[c] : 0.f);
        }
    });
}
} // namespace
#endif

namespace sony2fuji {
bool waveletDenoiseAvailable() {
#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    return true;
#else
    return false;
#endif
}
bool validWaveletDenoiseOptions(const WaveletDenoiseOptions& options) {
    for (float value : {options.luma, options.chroma, options.coarse})
        if (!std::isfinite(value) || value < 0 || value > 100) return false;
    return true;
}
ErrorCode applyWaveletDenoise(ImageData& image, const WaveletDenoiseOptions& options, WaveletDenoiseDiagnostics* diagnostics, GpuMode gpuMode) {
    if (diagnostics) *diagnostics = {};
    if (!validWaveletDenoiseOptions(options)) return ErrorCode::InvalidFormat;
    if (!options.active()) return ErrorCode::Success;
#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    if (image.width<=0 || image.height<=0 || image.pixels.size()!=static_cast<size_t>(image.width)*image.height)
        return ErrorCode::InvalidFormat;
    static_assert(sizeof(RGB)==sizeof(float)*3);
    cv::Mat rgb(image.height,image.width,CV_32FC3,image.pixels.data());
    if (!cv::checkRange(rgb)) return ErrorCode::InvalidFormat;
    const auto samples=flatSamples(rgb);
    if (diagnostics) diagnostics->flatTiles=static_cast<int>(samples.size());
    if (samples.size()<8) return ErrorCode::Success;
    auto model=fitNoise(samples);
    const cv::Mat normalized=normalize(rgb,model);
    cv::Mat transformed;
    cv::transform(normalized,transformed,opponent());
    calibrateBands(model,transformed,samples);
    if (options.chroma>0 && options.coarse>0) calibrateCoarseBands(model,transformed,samples);
    std::atomic<bool> gpuUsed{false};
    cv::Mat filtered;
    try { filtered = filter(transformed, model, options, gpuMode, gpuUsed); }
    catch (const WaveletGpuFailure&) { return ErrorCode::ProcessingError; }
    restore(rgb,normalized,filtered,model);
    if (diagnostics) {
        diagnostics->applied=true;
        diagnostics->gpuUsed=gpuUsed.load(std::memory_order_relaxed);
        for (int c=0;c<3;++c) { diagnostics->a[c]=model.a[c]; diagnostics->b[c]=model.b[c]; }
    }
    return ErrorCode::Success;
#else
    (void)image;
    (void)gpuMode;
    return ErrorCode::InvalidFormat;
#endif
}
}
