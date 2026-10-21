#pragma once

// Included inside wavelet_denoise.cpp's private namespace, after the shared noise model and inverse.
namespace eaw {
constexpr int depth=6, support=126, restoreBorder=12, centerSize=512;
constexpr float gain=3.5928893089294434f;

struct Analysis {
    cv::Vec3f guideSigma{};
    std::array<cv::Vec3f,depth> sigma{};
    std::array<cv::Vec3d,depth> energy{};
};

cv::Rect expanded(cv::Rect rect, int border, cv::Size bounds) {
    const int x=std::max(0,rect.x-border), y=std::max(0,rect.y-border);
    return {x,y,std::min(bounds.width,rect.x+rect.width+border)-x,
                std::min(bounds.height,rect.y+rect.height+border)-y};
}

cv::Rect localRect(cv::Rect global, cv::Rect origin) {
    return {global.x-origin.x,global.y-origin.y,global.width,global.height};
}

std::vector<cv::Rect> centers(cv::Size size, int tileSize) {
    if (tileSize<=0) throw std::invalid_argument("invalid EAW tile size");
    std::vector<cv::Rect> result;
    for (int y=0;y<size.height;y+=tileSize) for (int x=0;x<size.width;x+=tileSize)
        result.emplace_back(x,y,std::min(tileSize,size.width-x),std::min(tileSize,size.height-y));
    return result;
}

cv::Vec3f patchSigma(const cv::Mat& patch) {
    cv::Vec3f result;
    for (int c=0;c<3;++c) {
        std::vector<float> values;
        values.reserve(patch.total());
        for (int y=0;y<patch.rows;++y) for (int x=0;x<patch.cols;++x)
            values.push_back(patch.at<cv::Vec3f>(y,x)[c]);
        result[c]=mad(std::move(values));
    }
    return result;
}

cv::Vec3f medianSigma(const std::vector<cv::Vec3f>& estimates) {
    cv::Vec3f result;
    for (int c=0;c<3;++c) {
        std::vector<float> values;
        for (const auto& estimate:estimates) values.push_back(estimate[c]);
        result[c]=std::max(1e-6f,quantile(std::move(values)));
    }
    return result;
}

// 每层只计算后续需要的真实邻域；只在整图边缘 clamp，不在分块接缝复制像素。
template<class Consume>
cv::Mat stages(const cv::Mat& rgb, const NoiseModel& model, const cv::Vec3f& guideSigma,
               cv::Rect wanted, Consume consume) {
    cv::Rect region=expanded(wanted,support,rgb.size());
    cv::Mat coarse;
    cv::transform(normalize(rgb(region),model),coarse,opponent());
    const float decay=std::sqrt(70.f)/16;
    int remaining=support;
    for (int scale=0;scale<depth;++scale) {
        const int step=1<<scale;
        remaining-=2*step;
        const auto nextRegion=expanded(wanted,remaining,rgb.size());
        const auto offset=localRect(nextRegion,region).tl();
        cv::Mat next(nextRegion.size(),CV_32FC3), detail(nextRegion.size(),CV_32FC3);
        cv::Vec3f inverseVariance;
        for (int c=0;c<3;++c) {
            const float sigma=guideSigma[c]*std::pow(decay,scale);
            inverseVariance[c]=1/(sigma*sigma);
        }
        cv::parallel_for_(cv::Range(0,next.rows),[&](const cv::Range& range) {
            constexpr float taps[]={1,4,6,4,1};
            for (int y=range.start;y<range.end;++y) {
                const int sy=y+offset.y;
                const auto* source=coarse.ptr<cv::Vec3f>(sy);
                auto* output=next.ptr<cv::Vec3f>(y);
                auto* coefficients=detail.ptr<cv::Vec3f>(y);
                for (int x=0;x<next.cols;++x) {
                    const int sx=x+offset.x;
                    const auto value=source[sx];
                    cv::Vec3f sum{};
                    float weightSum=0;
                    for (int ky=0;ky<5;++ky) {
                        const auto* row=coarse.ptr<cv::Vec3f>(std::clamp(sy+(ky-2)*step,0,coarse.rows-1));
                        for (int kx=0;kx<5;++kx) {
                            const auto neighbor=row[std::clamp(sx+(kx-2)*step,0,coarse.cols-1)];
                            const auto delta=value-neighbor;
                            const float distance=delta[0]*delta[0]*inverseVariance[0]+
                                delta[1]*delta[1]*inverseVariance[1]+delta[2]*delta[2]*inverseVariance[2];
                            const float weight=taps[ky]*taps[kx]*(1.f/256)*
                                std::exp2(-std::max(0.f,.02f*distance-9.f));
                            sum+=neighbor*weight;
                            weightSum+=weight;
                        }
                    }
                    output[x]=sum/weightSum;
                    coefficients[x]=value-output[x];
                }
            }
        });
        consume(scale,detail(localRect(wanted,nextRegion)));
        coarse=std::move(next);
        region=nextRegion;
    }
    return coarse;
}

Analysis analyze(const cv::Mat& rgb, const NoiseModel& model, const std::vector<Sample>& samples,
                 int tileSize=centerSize) {
    Analysis result;
    const int count=std::min(24,static_cast<int>(samples.size()));
    std::vector<cv::Rect> patches;
    std::vector<cv::Vec3f> guides;
    for (int i=0;i<count;++i) {
        const auto& sample=samples[count==1 ? 0 : static_cast<size_t>(double(i)*(samples.size()-1)/(count-1))];
        patches.emplace_back(sample.x,sample.y,64,64);
        cv::Mat patch,smooth;
        cv::transform(normalize(rgb(patches.back()),model),patch,opponent());
        cv::GaussianBlur(patch,smooth,{},3);
        guides.push_back(patchSigma(patch-smooth));
    }
    result.guideSigma=medianSigma(guides);
    std::array<std::vector<cv::Mat>,depth> measurements;
    for (auto& band:measurements) for (int i=0;i<count;++i) band.emplace_back(64,64,CV_32FC3);
    // 固定顺序累加全局能量；只保存校准样块，不保存整图系数。
    for (const auto& center:centers(rgb.size(),tileSize)) {
        stages(rgb,model,result.guideSigma,center,[&](int scale,const cv::Mat& detail) {
            const auto sum=cv::sum(detail.mul(detail));
            for (int c=0;c<3;++c) result.energy[scale][c]+=sum[c];
            for (int i=0;i<count;++i) {
                const auto intersection=center&patches[i];
                if (!intersection.empty())
                    detail(localRect(intersection,center)).copyTo(measurements[scale][i](localRect(intersection,patches[i])));
            }
        });
    }
    for (int scale=0;scale<depth;++scale) {
        std::vector<cv::Vec3f> estimates;
        for (const auto& patch:measurements[scale]) estimates.push_back(patchSigma(patch));
        result.sigma[scale]=medianSigma(estimates);
        result.energy[scale]/=static_cast<double>(rgb.total());
    }
    return result;
}

float noiseScale(const NoiseModel& model) {
    float relative=0;
    for (int c=0;c<3;++c) relative=std::max(relative,std::sqrt(model.a[c]*.18f+model.b[c])/.18f);
    return std::clamp((relative-.02f)/.02f,0.f,1.f);
}

cv::Mat filter(const cv::Mat& rgb, const NoiseModel& model, const Analysis& analysis,
               const sony2fuji::WaveletDenoiseOptions& options, float scaleStrength,
               int tileSize=centerSize) {
    std::array<cv::Vec3f,depth> thresholds;
    for (int scale=0;scale<depth;++scale) for (int c=0;c<3;++c) {
        const int level=scale+1;
        const float strength=c==0 ? options.luma*.02f*(level==3 || level==4 ? 2.f : 1.f) :
            options.chroma*.025f*(level>=4 ? options.coarse*.01f : 1.f);
        const float variance=analysis.sigma[scale][c]*analysis.sigma[scale][c];
        const float threshold=strength*scaleStrength*variance/
            std::sqrt(std::max(analysis.energy[scale][c]-variance,.05*variance));
        // 保留冻结 C5 的乘法顺序，细层与粗层色度使用相同的高增益。
        const float bandGain=c==0 ? gain : gain*0.2783275280746028f*(scale==0 || scale>=4 ? gain : 1.f);
        thresholds[scale][c]=threshold*bandGain;
    }
    cv::Mat output(rgb.size(),rgb.type());
    for (const auto& center:centers(rgb.size(),tileSize)) {
        const auto restoredRegion=expanded(center,restoreBorder,rgb.size());
        cv::Mat filtered=cv::Mat::zeros(restoredRegion.size(),CV_32FC3);
        const auto coarse=stages(rgb,model,analysis.guideSigma,restoredRegion,[&](int scale,const cv::Mat& detail) {
            cv::parallel_for_(cv::Range(0,detail.rows),[&](const cv::Range& range) {
                for (int y=range.start;y<range.end;++y) {
                    const auto* input=detail.ptr<cv::Vec3f>(y);
                    auto* target=filtered.ptr<cv::Vec3f>(y);
                    for (int x=0;x<detail.cols;++x) for (int c=0;c<3;++c)
                        target[x][c]+=std::copysign(std::max(0.f,std::abs(input[x][c])-thresholds[scale][c]),input[x][c]);
                }
            });
        });
        filtered+=coarse;
        cv::Mat restored=rgb(restoredRegion).clone();
        restore(restored,std::move(filtered),model,options.processingVersion);
        restored(localRect(center,restoredRegion)).copyTo(output(center));
    }
    return output;
}
} // namespace eaw
