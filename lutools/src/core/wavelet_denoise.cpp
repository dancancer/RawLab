#include "wavelet_denoise.h"
#include "sony2fuji/color_converter.h"
#include "gpu/denoise.h"
#include <atomic>
#include <cmath>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <memory>
#include <vector>
#include <stdexcept>

#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include "wavelet_tile.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <wavelib.h>

namespace {
struct WaveletGpuFailure {};
constexpr int levels = 4, halo = 96, tileSize = 512;
constexpr int coarseLevels = 6, coarseHalo = 256;
using Bands = std::array<std::array<float,3>,levels>;
struct Sample { int x, y; cv::Vec3f mean, variance, gradient{}; };
struct NoiseModel {
    cv::Vec3f a, b;
    std::array<Bands,3> sigma;
    std::array<std::array<std::array<float,3>,coarseLevels-levels>,2> coarseSigma{};
    std::array<std::array<float,3>,coarseLevels-levels> lumaCoarseSigma{};
};

NoiseModel fitNoise(const std::vector<Sample>& samples);

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

void transformOpponent(const cv::Mat& source,cv::Mat& output,const cv::Matx33f& matrix) {
    // Legacy 沿用 v0.8.2 的 OpenCV 整图调度，保留 AVX2/FMA 的舍入顺序。
    // 标量重写或把整图拆成行带/tile 都会改变主段与尾部的边界。
    cv::transform(source,output,matrix);
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

std::vector<Sample> flatSamples(const cv::Mat& rgb, sony2fuji::WaveletNoiseEstimateDiagnostics& diagnostics,
                              sony2fuji::ProcessingVersion version = sony2fuji::ProcessingVersion::C5V2) {
    std::vector<Sample> samples;
    for (int y:positions(rgb.rows)) for (int x:positions(rgb.cols)) {
        ++diagnostics.candidateTiles;
        const cv::Mat patch=rgb(cv::Rect(x,y,std::min(64,rgb.cols-x),std::min(64,rgb.rows-y))).clone();
        // Calibration uses full 64-pixel tiles, keeping SWT's size contract explicit.
        if (patch.rows<64 || patch.cols<64) { ++diagnostics.rejectedSmall; continue; }
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
            sample.gradient[c]=quantile(std::move(gradient),.9);
            if (sample.gradient[c]>std::max(.00002f,.35f*sigma)) flat=false;
            sample.mean[c]=quantile(std::move(means));
            sample.variance[c]=sigma*sigma;
        }
        if (!flat) ++diagnostics.rejectedStructure;
        else if (!noisy) ++diagnostics.rejectedLowNoise;
        else if (periodic(residual)) ++diagnostics.rejectedPeriodic;
        else samples.push_back(sample);
    }
    if (version != sony2fuji::ProcessingVersion::Legacy && samples.size()>=8) {
        const auto model=fitNoise(samples);
        // 图案不能用自身抬高的 MAD 无限放宽结构门；固定首轮模型，只筛选一次。
        samples.erase(std::remove_if(samples.begin(),samples.end(),[&](const Sample& sample) {
            for (int c=0;c<3;++c) {
                // 约束下限不是测得的噪声底，不用它收紧该通道的门限。
                if (model.b[c]<=1e-12f) continue;
                const float expected=model.a[c]*std::max(0.f,sample.mean[c])+model.b[c];
                const float sigmaLimit=4*std::sqrt(expected);
                if (std::isfinite(expected) && expected>0 &&
                    sample.gradient[c]>std::max(.00002f,.35f*sigmaLimit)) {
                    ++diagnostics.rejectedStructure;
                    return true;
                }
            }
            return false;
        }),samples.end());
    }
    if (!samples.empty()) for (int c=0;c<3;++c) {
        diagnostics.sampleMeanMin[c]=diagnostics.sampleMeanMax[c]=samples.front().mean[c];
        for (const auto& sample:samples) {
            diagnostics.sampleMeanMin[c]=std::min(diagnostics.sampleMeanMin[c],sample.mean[c]);
            diagnostics.sampleMeanMax[c]=std::max(diagnostics.sampleMeanMax[c],sample.mean[c]);
        }
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

// 仅描述已有样本和拟合，不参与阈值、样本选择或模型求解；残差不是置信概率。
void describeFit(const std::vector<Sample>& samples, const NoiseModel& model,
                 sony2fuji::WaveletNoiseEstimateDiagnostics& diagnostics) {
    diagnostics.fitAvailable = true;
    for (int c=0;c<3;++c) {
        double squared=0;
        std::vector<float> variances;
        std::vector<double> squaredErrors;
        for (const auto& sample:samples) {
            variances.push_back(sample.variance[c]);
            const double residual=double(model.a[c])*std::max(0.f,sample.mean[c])+model.b[c]-sample.variance[c];
            squared+=residual*residual;
            squaredErrors.push_back(residual*residual);
        }
        diagnostics.sampleVarianceMedian[c]=quantile(variances);
        const double scale=std::max(diagnostics.sampleVarianceMedian[c],1e-12);
        diagnostics.fitRmse[c]=std::sqrt(squared/samples.size());
        diagnostics.relativeFitRmse[c]=diagnostics.fitRmse[c]/scale;
        std::sort(squaredErrors.begin(),squaredErrors.end());
        const size_t count=squaredErrors.size();
        diagnostics.relativeFitMedianAbsResidual[c]=
            .5*(std::sqrt(squaredErrors[(count-1)/2])+std::sqrt(squaredErrors[count/2]))/scale;
        double dominant=0;
        for (size_t i=count-(count+9)/10;i<count;++i) dominant+=squaredErrors[i];
        diagnostics.fitTopDecileErrorFraction[c]=squared>0 ? dominant/squared : 0;
        diagnostics.constantVarianceFallback[c]=std::max(0.f,diagnostics.sampleMeanMax[c])-
            std::max(0.f,diagnostics.sampleMeanMin[c])<.01f;
    }
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
    constexpr int extraLevels=coarseLevels-levels;
    using CoarseCoefficients=std::array<std::array<std::array<std::vector<float>,3>,extraLevels>,2>;
    CoarseCoefficients measurements;
    std::array<std::array<std::vector<float>,3>,extraLevels> sharedNoise;
    const int count=std::min(16,static_cast<int>(samples.size()));
    for (auto& channel:measurements) for (auto& scale:channel) for (auto& direction:scale) direction.resize(count);
    for (auto& scale:sharedNoise) for (auto& direction:scale) direction.resize(count);
    const int width=std::min(128,transformed.cols/64*64),height=std::min(128,transformed.rows/64*64);
    cv::parallel_for_(cv::Range(0,count),[&](const cv::Range& range) {
        for (int i=range.start;i<range.end;++i) {
            const auto& sample=samples[static_cast<size_t>(double(i)*(samples.size()-1)/(count-1))];
            const int x=std::clamp(sample.x+32-width/2,0,transformed.cols-width);
            const int y=std::clamp(sample.y+32-height/2,0,transformed.rows-height);
            // 粗层读取真实邻域，不能靠重复反射 64 像素样块来估计更大色斑。
            CoarseCoefficients coefficients;
            for (int c=1;c<3;++c) {
                const auto plane=sony2fuji::waveletTilePlane(transformed,{x,y,width,height},coarseHalo,1,c);
                StationaryWavelet transform(plane,coarseLevels);
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

void calibrateLumaCoarseBands(NoiseModel& model,const cv::Mat& transformed,const std::vector<Sample>& samples) {
    constexpr int extraLevels=coarseLevels-levels;
    std::array<std::array<std::vector<float>,3>,extraLevels> measurements;
    const int count=std::min(16,static_cast<int>(samples.size()));
    for (auto& scale:measurements) for (auto& direction:scale) direction.resize(count);
    const int width=std::min(128,transformed.cols/64*64),height=std::min(128,transformed.rows/64*64);
    cv::parallel_for_(cv::Range(0,count),[&](const cv::Range& range) {
        for (int i=range.start;i<range.end;++i) {
            const auto& sample=samples[static_cast<size_t>(double(i)*(samples.size()-1)/(count-1))];
            const int x=std::clamp(sample.x+32-width/2,0,transformed.cols-width);
            const int y=std::clamp(sample.y+32-height/2,0,transformed.rows-height);
            const auto plane=sony2fuji::waveletTilePlane(transformed,{x,y,width,height},coarseHalo,1,0);
            StationaryWavelet transform(plane,coarseLevels);
            for (int scale=0;scale<extraLevels;++scale) for (int direction=0;direction<3;++direction) {
                const auto band=transform.band(scale,direction);
                std::vector<float> values;
                values.reserve(width*height);
                for (int py=coarseHalo;py<coarseHalo+height;++py) for (int px=coarseHalo;px<coarseHalo+width;++px)
                    values.push_back(band.at<float>(py,px));
                measurements[scale][direction][i]=mad(std::move(values));
            }
        }
    },4);
    for (int scale=0;scale<extraLevels;++scale) for (int direction=0;direction<3;++direction) {
        const float anchor=model.sigma[0][0][direction];
        const float decay=std::clamp(anchor/model.sigma[0][1][direction],.5f,1.f);
        // 归一化白噪声每层约减半；沿细层实测衰减外推上界，避免真实缓变明暗抬高粗层 MAD。
        const float limit=anchor*std::pow(decay,static_cast<float>(extraLevels-scale));
        model.lumaCoarseSigma[scale][direction]=std::max(1e-6f,
            std::min(limit,quantile(std::move(measurements[scale][direction]))));
    }
}

float bandSigma(const NoiseModel& model,int channel,int level,int direction) {
    if (level<=levels) return model.sigma[channel][levels-level][direction];
    return channel==0 ? model.lumaCoarseSigma[coarseLevels-level][direction] :
        model.coarseSigma[channel-1][coarseLevels-level][direction];
}

cv::Mat filterPlane(const cv::Mat& plane,const NoiseModel& model,const sony2fuji::WaveletDenoiseOptions& options,int channel,
                    sony2fuji::GpuMode gpuMode,std::atomic<bool>& gpuUsed) {
    const float strength=channel==0 ? options.luma*.02f : options.chroma*.025f;
    if (strength==0) return plane.clone();
    const bool legacy=options.processingVersion==sony2fuji::ProcessingVersion::Legacy;
    const int depth=(channel==0 ? !legacy : options.coarse>0) ? coarseLevels : levels;
    auto thresholdScale=[&](int level) {
        if (legacy) return strength*(level>=levels ? (channel==0 ? .5f : options.coarse*.01f) : 1.f);
        // 只加强中间尺度，避免靠压低最细颗粒或缓变明暗来掩盖结块。
        if (channel==0) return strength*(level==3 || level==4 ? 2.f : 1.f);
        return strength*(level>=levels ? options.coarse*.01f : 1.f);
    };
    if (gpuMode != sony2fuji::GpuMode::Off) {
        sony2fuji::WaveletFilterSettings settings;
        settings.depth = depth;
        settings.luminance = channel == 0;
        settings.processingVersion = options.processingVersion;
        for (int scale = 0; scale < depth; ++scale) {
            const int sourceLevel = depth - scale;
            settings.thresholdScale[scale] = thresholdScale(sourceLevel);
            for (int direction = 0; direction < 3; ++direction)
                settings.sigma[scale * 3 + direction] = bandSigma(model, channel, sourceLevel, direction);
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
        const float scaleStrength=thresholdScale(sourceLevel);
        const bool firm=sony2fuji::waveletUsesFirmThreshold(sourceLevel,channel==0,options.processingVersion);
        for (int direction=0;direction<3;++direction) {
            cv::Mat band=transform.band(scale,direction),power;
            const int window=sony2fuji::waveletEnergyWindow(sourceLevel,channel==0,options.processingVersion);
            cv::boxFilter(band.mul(band),power,-1,{window,window});
            const float sigma=bandSigma(model,channel,sourceLevel,direction);
            const float variance=sigma*sigma;
            for (int y=0;y<band.rows;++y) {
                auto* values=band.ptr<float>(y);
                const auto* energy=power.ptr<float>(y);
                for (int x=0;x<band.cols;++x) {
                    const float threshold=scaleStrength*variance/std::sqrt(std::max(energy[x]-variance,.05f*variance));
                    const float magnitude=std::abs(values[x]);
                    const float soft=std::max(magnitude-threshold,0.f);
                    // 中尺度色度采用 T 到 2T 的连续过渡，强颜色系数不再持续被软阈值削弱。
                    values[x]=std::copysign(firm ? std::min(magnitude,2*soft) : soft,values[x]);
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
    const bool coarseChroma=options.chroma>0 && options.coarse>0;
    const bool coarseLuma=options.processingVersion!=sony2fuji::ProcessingVersion::Legacy && options.luma>0;
    const bool coarse=coarseLuma || coarseChroma;
    const int centerSize=coarse ? 1024 : tileSize;
    cv::Mat output(transformed.size(),CV_32FC3);
    const int columns=(width+centerSize-1)/centerSize, rows=(height+centerSize-1)/centerSize;
    int stripes=coarse ? 4 : 8;
#if defined(SONY2FUJI_PLATFORM_ANDROID)
    // 大图的六层 SWT 每个 tile 需要约 400 MiB；移动端避免并发叠加。
    if (coarse && transformed.total()>4*1024*1024) stripes=1;
#endif
    cv::parallel_for_(cv::Range(0,columns*rows),[&](const cv::Range& range) {
        for (int index=range.start;index<range.end;++index) {
            const int x=index%columns*centerSize,y=index/columns*centerSize;
            const int w=std::min(centerSize,width-x),h=std::min(centerSize,height-y);
            for (int c=0;c<3;++c) {
                const bool extended=c==0 ? coarseLuma : coarseChroma;
                const int radius=extended ? coarseHalo : halo, divisor=extended ? 1<<coarseLevels : 1<<levels;
                const auto plane=sony2fuji::waveletTilePlane(transformed,{x,y,w,h},radius,divisor,c);
                const auto filtered=filterPlane(plane,model,options,c,gpuMode,gpuUsed);
                for (int py=0;py<h;++py) for (int px=0;px<w;++px)
                    output.at<cv::Vec3f>(y+py,x+px)[c]=filtered.at<float>(radius+py,radius+px);
            }
        }
    },stripes);
    return output;
}

void restore(cv::Mat& rgb,cv::Mat filtered,const NoiseModel& model,
             sony2fuji::ProcessingVersion version = sony2fuji::ProcessingVersion::C5V2) {
    cv::Mat normalized;
    if (version==sony2fuji::ProcessingVersion::Legacy)
        transformOpponent(filtered,normalized,opponent().t());
    else
        cv::transform(filtered,normalized,opponent().t());
    filtered.release();
    cv::Mat difference=normalize(rgb,model);
    cv::subtract(difference,normalized,difference);
    cv::multiply(difference,difference,difference);
    cv::GaussianBlur(difference,difference,{},3);
    cv::parallel_for_(cv::Range(0,rgb.rows),[&](const cv::Range& range) {
        for (int y=range.start;y<range.end;++y) for (int x=0;x<rgb.cols;++x) for (int c=0;c<3;++c) {
            const float a=std::max(model.a[c],1e-12f), b=std::max(model.b[c],1e-12f)+.375f*a*a;
            const float value=normalized.at<cv::Vec3f>(y,x)[c];
            if (version==sony2fuji::ProcessingVersion::Legacy) {
                const float positive=std::max(value,0.f);
                rgb.at<cv::Vec3f>(y,x)[c]=std::sqrt(b)*value+.25f*a*positive*positive+
                    (value>0 ? .25f*a*difference.at<cv::Vec3f>(y,x)[c] : 0.f);
                continue;
            }
            const float variance=std::max(difference.at<cv::Vec3f>(y,x)[c],0.f), radius=std::sqrt(variance);
            const float linear=std::sqrt(b)*value;
            auto& restored=rgb.at<cv::Vec3f>(y,x)[c];
            // 对称扰动的逆变换均值在零点附近连续，避免舍入误差触发整项方差补偿。
            if (value>=radius) restored=linear+.25f*a*value*value+.25f*a*variance;
            else if (value<=-radius) restored=linear;
            else {
                const float positive=value+radius;
                restored=linear+.125f*a*positive*positive;
            }
        }
    });
}

#include "eaw_denoise_impl.h"
} // namespace
#endif

namespace sony2fuji {
struct WaveletDenoiseAnalysisCache::Impl {
    std::string key;
    ProcessingVersion processingVersion = ProcessingVersion::C5V2;
    int width = 0, height = 0;
    bool ready = false, coarseReady = false, lumaCoarseReady = false;
    WaveletNoiseEstimateDiagnostics estimate;
#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    NoiseModel model{};
    eaw::Analysis eawAnalysis{};
    bool eawReady = false;
    std::vector<Sample> samples;
#endif
};

WaveletDenoiseAnalysisCache::WaveletDenoiseAnalysisCache() = default;
WaveletDenoiseAnalysisCache::~WaveletDenoiseAnalysisCache() = default;
WaveletDenoiseAnalysisCache::WaveletDenoiseAnalysisCache(WaveletDenoiseAnalysisCache&&) noexcept = default;
WaveletDenoiseAnalysisCache& WaveletDenoiseAnalysisCache::operator=(WaveletDenoiseAnalysisCache&&) noexcept = default;
void WaveletDenoiseAnalysisCache::clear() { state.reset(); }

const char* waveletDenoiseOutcomeName(WaveletDenoiseOutcome outcome) {
    switch (outcome) {
    case WaveletDenoiseOutcome::NotRun: return "not_run";
    case WaveletDenoiseOutcome::Disabled: return "disabled";
    case WaveletDenoiseOutcome::ZeroStrength: return "zero_strength";
    case WaveletDenoiseOutcome::InvalidOptions: return "invalid_options";
    case WaveletDenoiseOutcome::InvalidImage: return "invalid_image";
    case WaveletDenoiseOutcome::UnsupportedBuild: return "unsupported_build";
    case WaveletDenoiseOutcome::SmallImage: return "small_image";
    case WaveletDenoiseOutcome::LowNoise: return "low_noise";
    case WaveletDenoiseOutcome::InsufficientSamples: return "insufficient_samples";
    case WaveletDenoiseOutcome::Applied: return "applied";
    case WaveletDenoiseOutcome::GpuFailure: return "gpu_failure";
    case WaveletDenoiseOutcome::ProcessingFailure: return "processing_failure";
    }
    return "unknown";
}

bool waveletDenoiseAvailable() {
#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    return true;
#else
    return false;
#endif
}
bool validWaveletDenoiseOptions(const WaveletDenoiseOptions& options) {
    if (!validProcessingVersion(options.processingVersion)) return false;
    for (float value : {options.luma, options.chroma, options.coarse})
        if (!std::isfinite(value) || value < 0 || value > 100) return false;
    return true;
}
ErrorCode applyWaveletDenoise(ImageData& image, const WaveletDenoiseOptions& options, WaveletDenoiseDiagnostics* diagnostics,
    GpuMode gpuMode, WaveletDenoiseAnalysisCache* analysis, const std::string& sourceKey,
    const ImageData* immutableSource, ColorSpace sourceSpace) {
    if (diagnostics) *diagnostics = {};
    auto finish = [&](WaveletDenoiseOutcome outcome, ErrorCode code) {
        if (diagnostics) diagnostics->outcome=outcome;
        return code;
    };
    if (!validWaveletDenoiseOptions(options)) return finish(WaveletDenoiseOutcome::InvalidOptions, ErrorCode::InvalidFormat);
    if (!options.active()) return finish(options.enabled ? WaveletDenoiseOutcome::ZeroStrength :
        WaveletDenoiseOutcome::Disabled, ErrorCode::Success);
#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    try {
        const bool reloadable = immutableSource && immutableSource != &image;
        if (reloadable && (immutableSource->width <= 0 || immutableSource->height <= 0 ||
            immutableSource->pixels.size() != static_cast<size_t>(immutableSource->width) * immutableSource->height))
            return finish(WaveletDenoiseOutcome::InvalidImage, ErrorCode::InvalidFormat);
        auto reload = [&]() {
            image = *immutableSource;
            return ColorConverter().convertImage(image, sourceSpace, ColorSpace::sRGB);
        };
        // Auto 在 GPU 失败后重试时，工作副本可能已释放；原始输入仍由 session 持有。
        if (reloadable && image.pixels.empty()) {
            const auto result = reload();
            if (result != ErrorCode::Success) return finish(WaveletDenoiseOutcome::ProcessingFailure, result);
        }
        if (image.width<=0 || image.height<=0 || image.pixels.size()!=static_cast<size_t>(image.width)*image.height)
            return finish(WaveletDenoiseOutcome::InvalidImage, ErrorCode::InvalidFormat);
        if (reloadable && (immutableSource->width != image.width || immutableSource->height != image.height))
            return finish(WaveletDenoiseOutcome::InvalidImage, ErrorCode::InvalidFormat);
        static_assert(sizeof(RGB)==sizeof(float)*3);
        cv::Mat rgb(image.height,image.width,CV_32FC3,image.pixels.data());
        if (!cv::checkRange(rgb)) return finish(WaveletDenoiseOutcome::InvalidImage, ErrorCode::InvalidFormat);
        WaveletDenoiseAnalysisCache::Impl local;
        auto* state = &local;
        bool reused = false;
        // sourceKey 由调用方标识不可变输入；只保留小型分析模型，不缓存整图系数。
        if (analysis && !sourceKey.empty()) {
            reused = analysis->state && analysis->state->ready && analysis->state->key == sourceKey &&
                analysis->state->processingVersion == options.processingVersion &&
                analysis->state->width == image.width && analysis->state->height == image.height;
            if (!reused) {
                analysis->state = std::make_unique<WaveletDenoiseAnalysisCache::Impl>();
                analysis->state->key = sourceKey;
                analysis->state->processingVersion = options.processingVersion;
                analysis->state->width = image.width; analysis->state->height = image.height;
            }
            state = analysis->state.get();
        }
        if (!reused) state->samples=flatSamples(rgb,state->estimate,options.processingVersion);
        const auto& samples = state->samples;
        if (diagnostics) {
            diagnostics->flatTiles=static_cast<int>(samples.size());
            diagnostics->analysisReused=reused;
            diagnostics->estimate=state->estimate;
        }
        if (samples.size()<8) {
            state->ready=true;
            const auto& estimate=state->estimate;
            const auto outcome=estimate.rejectedSmall==estimate.candidateTiles ? WaveletDenoiseOutcome::SmallImage :
                estimate.rejectedLowNoise==estimate.candidateTiles ? WaveletDenoiseOutcome::LowNoise :
                WaveletDenoiseOutcome::InsufficientSamples;
            return finish(outcome, ErrorCode::Success);
        }
        if (!reused) {
            state->model=fitNoise(samples);
            describeFit(samples,state->model,state->estimate);
        }
        auto& model = state->model;
        if (diagnostics) {
            diagnostics->estimate=state->estimate;
            for (int c=0;c<3;++c) { diagnostics->a[c]=model.a[c]; diagnostics->b[c]=model.b[c]; }
        }
        if (options.processingVersion == ProcessingVersion::C5V2) {
            // C5 暂无 GPU 滤波后端，Force 不能把 CPU 结果当作 GPU 成功。
            if (gpuMode == GpuMode::Force)
                return finish(WaveletDenoiseOutcome::GpuFailure, ErrorCode::ProcessingError);
            const float strengthScale=eaw::noiseScale(model);
            if (strengthScale==0) {
                state->ready=true;
                return finish(WaveletDenoiseOutcome::LowNoise, ErrorCode::Success);
            }
            if (!state->eawReady) {
                state->eawAnalysis=eaw::analyze(rgb,model,samples);
                state->eawReady=true;
            }
            if (diagnostics) diagnostics->coarseAnalysisReused=reused;
            state->ready=true;
            const auto filtered=eaw::filter(rgb,model,state->eawAnalysis,options,strengthScale);
            // 输出完整生成后才替换输入，失败不留下部分接缝或丢失工作副本。
            filtered.copyTo(rgb);
            if (diagnostics) diagnostics->applied=true;
            return finish(WaveletDenoiseOutcome::Applied, ErrorCode::Success);
        }
        cv::Mat transformed;
        {
            const cv::Mat normalized=normalize(rgb,model);
            transformOpponent(normalized,transformed,opponent());
        }
        if (!reused) calibrateBands(model,transformed,samples);
        state->ready=true;
        const bool needLumaCoarse=options.processingVersion!=ProcessingVersion::Legacy && options.luma>0;
        const bool needChromaCoarse=options.chroma>0 && options.coarse>0;
        if (diagnostics && (needLumaCoarse || needChromaCoarse))
            diagnostics->coarseAnalysisReused=(!needLumaCoarse || state->lumaCoarseReady) &&
                (!needChromaCoarse || state->coarseReady);
        if (needLumaCoarse && !state->lumaCoarseReady) {
            calibrateLumaCoarseBands(model,transformed,samples);
            state->lumaCoarseReady=true;
        }
        if (needChromaCoarse) {
            if (!state->coarseReady) {
                calibrateCoarseBands(model,transformed,samples);
                state->coarseReady=true;
            }
        }
        std::atomic<bool> gpuUsed{false};
        cv::Mat filtered;
        try { filtered = filter(transformed, model, options, gpuMode, gpuUsed); }
        catch (const WaveletGpuFailure&) {
            if (reloadable) { transformed.release(); rgb.release(); image={}; }
            return finish(WaveletDenoiseOutcome::GpuFailure, ErrorCode::ProcessingError);
        }
        transformed.release();
        restore(rgb,std::move(filtered),model,options.processingVersion);
        if (diagnostics) {
            diagnostics->applied=true;
            diagnostics->gpuUsed=gpuUsed.load(std::memory_order_relaxed);
        }
        return finish(WaveletDenoiseOutcome::Applied, ErrorCode::Success);
    } catch (const std::bad_alloc&) {
        if (options.processingVersion==ProcessingVersion::Legacy) throw;
        return finish(WaveletDenoiseOutcome::ProcessingFailure, ErrorCode::OutOfMemory);
    } catch (const cv::Exception& error) {
        if (options.processingVersion==ProcessingVersion::Legacy) throw;
        return finish(WaveletDenoiseOutcome::ProcessingFailure,
            error.code==cv::Error::StsNoMem ? ErrorCode::OutOfMemory : ErrorCode::ProcessingError);
    } catch (const std::exception&) {
        if (options.processingVersion==ProcessingVersion::Legacy) throw;
        return finish(WaveletDenoiseOutcome::ProcessingFailure, ErrorCode::ProcessingError);
    }
#else
    (void)image;
    (void)gpuMode;
    (void)analysis;
    (void)sourceKey;
    (void)immutableSource;
    (void)sourceSpace;
    return finish(WaveletDenoiseOutcome::UnsupportedBuild, ErrorCode::InvalidFormat);
#endif
}
}
