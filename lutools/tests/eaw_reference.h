#pragma once

// Independent full-frame reference from the approved C5 experiment (2026-10-21).
// Original SHA-256: 9c5afe765fb5a778d47fe2538d590174dbd1ae219383df2893eb954c0691831d.
// Include after wavelet_denoise.cpp for the shared input model and inverse transform.
// Keep this separate from the production tiled implementation.
namespace c5_reference {
constexpr int depth = 6;
using BandStatistics = std::array<std::array<std::array<double, 3>, depth>, 3>;

struct Decomposition { cv::Mat coarse, detail; };

inline float globalThreshold(double energy, float variance, float strength) {
    return strength * variance / std::sqrt(std::max(energy-variance, .05*variance));
}

inline Decomposition decomposeEaw(const cv::Mat& input, int scale, const cv::Vec3f& inverseVariance,
                                  bool edgeAware = true) {
    if (input.type() != CV_32FC3 || input.empty() || scale < 0 || scale >= depth)
        throw std::runtime_error("invalid EAW input");
    Decomposition result{cv::Mat(input.size(), input.type()), cv::Mat(input.size(), input.type())};
    constexpr float taps[] = {1,4,6,4,1};
    const int step = 1 << scale;
    cv::parallel_for_(cv::Range(0, input.rows), [&](const cv::Range& range) {
        for (int y = range.start; y < range.end; ++y) {
            const auto* row = input.ptr<cv::Vec3f>(y);
            auto* coarse = result.coarse.ptr<cv::Vec3f>(y);
            auto* detail = result.detail.ptr<cv::Vec3f>(y);
            for (int x = 0; x < input.cols; ++x) {
                cv::Vec3f sum{};
                float weightSum = 0;
                for (int ky = 0; ky < 5; ++ky) {
                    const auto* neighborRow = input.ptr<cv::Vec3f>(std::clamp(y+(ky-2)*step, 0, input.rows-1));
                    for (int kx = 0; kx < 5; ++kx) {
                        const auto neighbor = neighborRow[std::clamp(x+(kx-2)*step, 0, input.cols-1)];
                        const auto delta = row[x]-neighbor;
                        const float distance = delta[0]*delta[0]*inverseVariance[0] +
                            delta[1]*delta[1]*inverseVariance[1] + delta[2]*delta[2]*inverseVariance[2];
                        const float edgeWeight = edgeAware ? std::exp2(-std::max(0.f, .02f*distance-9.f)) : 1;
                        const float weight = taps[ky]*taps[kx]*(1.f/256)*edgeWeight;
                        sum += neighbor*weight;
                        weightSum += weight;
                    }
                }
                coarse[x] = sum/weightSum;
                detail[x] = row[x]-coarse[x];
            }
        }
    });
    return result;
}

inline float strengthAt(const sony2fuji::WaveletDenoiseOptions& options, int channel, int level) {
    if (channel == 0) return options.luma*.02f*(level == 3 || level == 4 ? 2.f : 1.f);
    return options.chroma*.025f*(level >= 4 ? options.coarse*.01f : 1.f);
}

struct EawStatistics {
    cv::Vec3f guideSigma;
    std::array<cv::Vec3f, depth> sigma{}, threshold{};
};

enum class EawShrinkage { Soft, ChromaFirm, Firm };

inline float shrinkEawCoefficient(float value, float threshold, int channel, int level, EawShrinkage shrinkage,
                                  float gain = 1) {
    const float magnitude = std::abs(value);
    // 增益乘法留在减法表达式内，保留冻结 C0 的浮点运算顺序。
    const float soft = std::max(0.f,magnitude-threshold*gain);
    const bool firm = level >= 2 && level <= 4 &&
        (shrinkage == EawShrinkage::Firm || (shrinkage == EawShrinkage::ChromaFirm && channel > 0));
    return std::copysign(firm ? std::min(magnitude,2*soft) : soft,value);
}

inline cv::Vec3f sampleSigma(const cv::Mat& image, const std::vector<Sample>& samples, bool highPass) {
    if (samples.empty()) throw std::runtime_error("noise calibration requires source samples");
    std::array<std::vector<float>,3> estimates;
    const int count = std::min(24,static_cast<int>(samples.size()));
    for (int i = 0; i < count; ++i) {
        const auto& sample = samples[count == 1 ? 0 : static_cast<size_t>(double(i)*(samples.size()-1)/(count-1))];
        cv::Mat patch = image(cv::Rect(sample.x,sample.y,64,64)).clone();
        if (highPass) {
            cv::Mat smooth;
            cv::GaussianBlur(patch,smooth,{},3);
            patch -= smooth;
        }
        for (int c = 0; c < 3; ++c) {
            std::vector<float> values;
            values.reserve(patch.total());
            for (int y = 0; y < patch.rows; ++y) for (int x = 0; x < patch.cols; ++x)
                values.push_back(patch.at<cv::Vec3f>(y,x)[c]);
            estimates[c].push_back(mad(std::move(values)));
        }
    }
    return {std::max(1e-6f,quantile(std::move(estimates[0]))),
            std::max(1e-6f,quantile(std::move(estimates[1]))),
            std::max(1e-6f,quantile(std::move(estimates[2])))};
}

inline std::vector<cv::Mat> filterEawGlobal(const cv::Mat& input, const std::vector<Sample>& samples,
        const sony2fuji::WaveletDenoiseOptions& options, const std::vector<float>& gains,
        EawStatistics& statistics, EawShrinkage shrinkage = EawShrinkage::Soft, float chromaScale = 1,
        const std::array<float,depth>& chromaLevelScales = {1,1,1,1,1,1}) {
    statistics.guideSigma = sampleSigma(input,samples,true);
    std::vector<cv::Mat> output;
    for (float gain : gains) output.push_back(gain == 0 ? input.clone() : cv::Mat::zeros(input.size(),input.type()));
    cv::Mat coarse = input;
    const float decay = std::sqrt(70.f)/16;
    for (int scale = 0; scale < depth; ++scale) {
        cv::Vec3f inverseVariance;
        for (int c = 0; c < 3; ++c) {
            const float sigma = statistics.guideSigma[c]*std::pow(decay,scale);
            inverseVariance[c] = 1/(sigma*sigma);
        }
        const auto stage = decomposeEaw(coarse,scale,inverseVariance);
        const auto sumSquared = cv::sum(stage.detail.mul(stage.detail));
        const auto sigma = sampleSigma(stage.detail,samples,false);
        statistics.sigma[scale] = sigma;
        for (int c = 0; c < 3; ++c)
            statistics.threshold[scale][c] = globalThreshold(sumSquared[c]/input.total(),sigma[c]*sigma[c],
                                                            strengthAt(options,c,scale+1));
        cv::parallel_for_(cv::Range(0,input.rows),[&](const cv::Range& range) {
            for (int y = range.start; y < range.end; ++y) for (size_t k = 0; k < gains.size(); ++k) {
                if (gains[k] == 0) continue;
                const auto* detail = stage.detail.ptr<cv::Vec3f>(y);
                auto* target = output[k].ptr<cv::Vec3f>(y);
                for (int x = 0; x < input.cols; ++x) for (int c = 0; c < 3; ++c) {
                    const float gain = c == 0 ? gains[k] : gains[k]*chromaScale*chromaLevelScales[scale];
                    target[x][c] += shrinkEawCoefficient(detail[x][c],statistics.threshold[scale][c],
                                                       c,scale+1,shrinkage,gain);
                }
            }
        });
        coarse = stage.coarse;
    }
    for (size_t k = 0; k < gains.size(); ++k) if (gains[k] != 0) output[k] += coarse;
    return output;
}
} // namespace c5_reference
