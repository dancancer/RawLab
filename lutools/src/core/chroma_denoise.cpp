#include "chroma_denoise.h"
#include "gpu/denoise.h"

#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE)
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/ximgproc/edge_filter.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <limits>
#include <vector>

namespace {
struct ChromaGpuFailure {};

float quantile(std::vector<float> values, float fraction = .5f) {
    if (values.empty()) return 0;
    const double position = (values.size()-1) * static_cast<double>(fraction);
    const size_t lower = static_cast<size_t>(position);
    std::nth_element(values.begin(), values.begin()+lower, values.end());
    const float a = values[lower];
    if (lower+1 == values.size()) return a;
    const float b = *std::min_element(values.begin()+lower+1, values.end());
    return a + (b-a)*static_cast<float>(position-lower);
}

float mad(std::vector<float> values) {
    const float center = quantile(values);
    for (auto& value : values) value = std::abs(value-center);
    return quantile(std::move(values)) / .67448975f;
}

std::vector<int> positions(int length) {
    const int count = std::min(12, std::max(1, length/64));
    std::vector<int> result;
    for (int i = 0; i < count; ++i)
        result.push_back(count == 1 ? 0 : static_cast<int>(static_cast<double>(i)*std::max(0,length-64)/(count-1)));
    return result;
}

cv::Mat chroma(const cv::Mat& lab) {
    cv::Mat result(lab.size(), CV_32FC2);
    const int mapping[] = {1,0,2,1};
    cv::mixChannels(&lab,1,&result,1,mapping,2);
    return result;
}

struct TileNoise { cv::Vec3f sigma; float lightness; float powerSigma; };
struct NoiseProfile {
    int tiles = 0;
    float confidence = 0, sigma = 0;
    std::vector<std::pair<float,float>> levels;
};

bool periodic(const cv::Mat& residual) {
    std::vector<float> powers(residual.rows*(residual.cols/2+1),0);
    for (int channel = 0; channel < 2; ++channel) {
        cv::Mat plane(residual.size(),CV_32F);
        for (int y = 0; y < plane.rows; ++y) for (int x = 0; x < plane.cols; ++x) {
            const double window = (.5-.5*std::cos(2*CV_PI*y/(plane.rows-1))) *
                (.5-.5*std::cos(2*CV_PI*x/(plane.cols-1)));
            plane.at<float>(y,x) = static_cast<float>(window)*residual.at<cv::Vec2f>(y,x)[channel];
        }
        cv::Mat spectrum;
        cv::dft(plane,spectrum,cv::DFT_COMPLEX_OUTPUT);
        for (int y = 0; y < plane.rows; ++y) for (int x = 0; x <= plane.cols/2; ++x) {
            const auto value = spectrum.at<cv::Vec2f>(y,x);
            powers[y*(plane.cols/2+1)+x] += value.dot(value);
        }
    }
    double total = 0, peak = 0;
    for (float value : powers) total += value;
    const size_t count = std::max<size_t>(1,powers.size()/100);
    std::nth_element(powers.begin(),powers.end()-count,powers.end());
    for (auto it = powers.end()-count; it != powers.end(); ++it) peak += *it;
    return peak/std::max(total,1e-12) > .35;
}

NoiseProfile estimate(const cv::Mat& lab, bool rgbInput = false) {
    std::vector<TileNoise> tiles;
    int total = 0;
    for (int y : positions(lab.rows)) for (int x : positions(lab.cols)) {
        cv::Mat patch = lab(cv::Rect(x,y,std::min(64,lab.cols-x),std::min(64,lab.rows-y))).clone();
        if (rgbInput) cv::cvtColor(patch,patch,cv::COLOR_RGB2Lab);
        if (std::min(patch.rows,patch.cols) < 16) continue;
        ++total;
        cv::Vec3f sigma;
        const std::array<cv::Point,4> offsets = {{{1,0},{0,1},{1,1},{-1,1}}};
        for (int c = 0; c < 3; ++c) {
            sigma[c] = std::numeric_limits<float>::max();
            for (const auto& delta : offsets) {
                std::vector<float> values;
                for (int py = 1; py+1 < patch.rows; ++py) for (int px = 1; px+1 < patch.cols; ++px)
                    values.push_back((patch.at<cv::Vec3f>(py-delta.y,px-delta.x)[c] -
                        2*patch.at<cv::Vec3f>(py,px)[c] + patch.at<cv::Vec3f>(py+delta.y,px+delta.x)[c])/std::sqrt(6.f));
                sigma[c] = std::min(sigma[c],mad(std::move(values)));
            }
            std::vector<float> haar;
            for (int py = 0; py+1 < patch.rows; py += 2) for (int px = 0; px+1 < patch.cols; px += 2)
                haar.push_back((patch.at<cv::Vec3f>(py,px)[c]-patch.at<cv::Vec3f>(py+1,px)[c] -
                    patch.at<cv::Vec3f>(py,px+1)[c]+patch.at<cv::Vec3f>(py+1,px+1)[c])*.5f);
            sigma[c] = std::min(sigma[c],mad(std::move(haar)));
        }
        cv::Mat ab = chroma(patch), low, smooth;
        cv::boxFilter(ab,low,-1,{5,5});
        const cv::Mat residual = ab-low;
        if (periodic(residual)) continue;
        cv::GaussianBlur(patch,smooth,{},3);
        bool flat = true;
        for (int c = 0; c < 3; ++c) {
            std::vector<float> gradient;
            for (int py = 1; py < patch.rows; ++py) for (int px = 1; px < patch.cols; ++px) {
                const float value = smooth.at<cv::Vec3f>(py,px)[c];
                gradient.push_back(std::max(std::abs(value-smooth.at<cv::Vec3f>(py-1,px)[c]),
                    std::abs(value-smooth.at<cv::Vec3f>(py,px-1)[c])));
            }
            if (quantile(std::move(gradient),.9f) >= std::max(.3f,sigma[c]*.5f)) flat = false;
        }
        if (!flat) continue;
        float sum = 0;
        for (int c = 0; c < 2; ++c) {
            std::vector<float> values;
            for (int py = 0; py < patch.rows; ++py) for (int px = 0; px < patch.cols; ++px)
                values.push_back(residual.at<cv::Vec2f>(py,px)[c]);
            const float value = mad(std::move(values));
            sum += value*value;
        }
        tiles.push_back({sigma,static_cast<float>(cv::mean(patch)[0]),std::sqrt(sum/(2*.96f))});
    }
    NoiseProfile result;
    result.tiles = static_cast<int>(tiles.size());
    if (tiles.size() < 8 || tiles.size() < total*.05) return result;
    std::vector<float> powers, a, b;
    std::map<int,std::vector<TileNoise>> groups;
    for (const auto& tile : tiles) {
        powers.push_back(tile.powerSigma);
        a.push_back(tile.sigma[1]); b.push_back(tile.sigma[2]);
        groups[static_cast<int>(tile.lightness/20)].push_back(tile);
    }
    result.sigma = quantile(powers);
    const float medianA = quantile(a), medianB = quantile(b);
    if (std::sqrt((medianA*medianA+medianB*medianB)*.5f) <= .15f) return result;
    std::array<std::vector<float>,2> spreads;
    for (const auto& entry : groups) {
        const auto& group = entry.second;
        if (group.size() < 3) continue;
        std::vector<float> lights, levels;
        for (const auto& tile : group) { lights.push_back(tile.lightness); levels.push_back(tile.powerSigma); }
        result.levels.emplace_back(quantile(lights),quantile(levels));
        for (int c = 0; c < 2; ++c) {
            std::vector<float> values;
            for (const auto& tile : group) values.push_back(tile.sigma[c+1]);
            const float center = quantile(values);
            for (auto& value : values) value = std::abs(value-center);
            spreads[c].push_back(quantile(values)/std::max(center,.15f));
        }
    }
    if (spreads[0].empty()) {
        for (auto& value : a) value = std::abs(value-medianA);
        for (auto& value : b) value = std::abs(value-medianB);
        spreads[0].push_back(quantile(a)/std::max(medianA,.15f));
        spreads[1].push_back(quantile(b)/std::max(medianB,.15f));
    }
    result.confidence = std::clamp(1-std::max(quantile(spreads[0]),quantile(spreads[1])),0.f,1.f);
    if (result.confidence < .25f) result.confidence = 0;
    return result;
}

cv::Mat guided(const cv::Mat& lab, const cv::Mat& source, int radius, double epsilon,
               sony2fuji::GpuMode gpuMode, bool& gpuUsed) {
    cv::Mat result(source.size(),source.type());
    constexpr int tile = 768, halo = 32;
    for (int y = 0; y < source.rows; y += tile) for (int x = 0; x < source.cols; x += tile) {
        const cv::Rect center(x,y,std::min(tile,source.cols-x),std::min(tile,source.rows-y));
        const int left = std::max(0,x-halo), top = std::max(0,y-halo);
        const cv::Rect bounds(left,top,std::min(source.cols,x+tile+halo)-left,std::min(source.rows,y+tile+halo)-top);
        cv::Mat guide, filtered;
        cv::GaussianBlur(lab(bounds).clone(),guide,{},.7);
        const cv::Mat input = source(bounds).clone();
        bool accelerated = false;
        if (gpuMode != sony2fuji::GpuMode::Off) {
            filtered.create(input.size(), input.type());
            accelerated = sony2fuji::gpuGuidedFilter(guide.ptr<float>(), input.ptr<float>(),
                input.cols, input.rows, radius, static_cast<float>(epsilon), filtered.ptr<float>());
        }
        if (accelerated) gpuUsed = true;
        else {
            if (gpuMode == sony2fuji::GpuMode::Force) throw ChromaGpuFailure{};
            cv::ximgproc::guidedFilter(guide,input,filtered,radius,epsilon);
        }
        filtered(cv::Rect(x-left,y-top,center.width,center.height)).copyTo(result(center));
    }
    return result;
}

float localSigma(const NoiseProfile& profile, float lightness) {
    const auto& levels = profile.levels;
    if (levels.empty()) return profile.sigma;
    if (lightness <= levels.front().first) return levels.front().second;
    for (size_t i = 1; i < levels.size(); ++i) if (lightness < levels[i].first) {
        const float mix = (lightness-levels[i-1].first)/(levels[i].first-levels[i-1].first);
        return levels[i-1].second+(levels[i].second-levels[i-1].second)*mix;
    }
    return levels.back().second;
}

void filter(cv::Mat& lab, const NoiseProfile& noise, bool coarse, sony2fuji::GpuMode gpuMode, bool& gpuUsed) {
    cv::Mat ab = chroma(lab);
    cv::Mat delta = guided(lab,ab,8,std::max(.05f,16*noise.sigma*noise.sigma),gpuMode,gpuUsed)-ab;
    cv::Mat low;
    cv::GaussianBlur(delta,low,{},6);
    delta -= low;
    cv::boxFilter(ab,low,-1,{5,5});
    cv::Mat high = ab-low, power(lab.size(),CV_32F), lightness, smoothLightness;
    cv::extractChannel(lab,lightness,0);
    cv::GaussianBlur(lightness,smoothLightness,{},3);
    for (int y = 0; y < lab.rows; ++y) for (int x = 0; x < lab.cols; ++x) {
        const auto value = high.at<cv::Vec2f>(y,x);
        power.at<float>(y,x) = value.dot(value)*.5f;
    }
    cv::boxFilter(power,power,-1,{5,5});
    for (int y = 0; y < lab.rows; ++y) for (int x = 0; x < lab.cols; ++x) {
        const float sigma = localSigma(noise,smoothLightness.at<float>(y,x));
        const float variance = std::max(.0001f,sigma*sigma*.96f);
        const float protect = std::clamp((power.at<float>(y,x)-1.5f*variance)/(2*variance),0.f,1.f);
        ab.at<cv::Vec2f>(y,x) += delta.at<cv::Vec2f>(y,x)*(noise.confidence*(1-protect));
    }
    // 去噪优先只增加受限的粗尺度修正；不让粗尺度结构自行触发降噪。
    if (coarse) {
        cv::Mat candidate = ab.clone();
        for (int scale : {4,16}) {
            const cv::Size size(std::max(4,lab.cols/scale),std::max(4,lab.rows/scale));
            cv::Mat guide, source, correction;
            cv::resize(lab,guide,size,0,0,cv::INTER_AREA);
            cv::resize(candidate,source,size,0,0,cv::INTER_AREA);
            correction = guided(guide,source,4,std::max(.05f,4*noise.sigma*noise.sigma),gpuMode,gpuUsed)-source;
            cv::resize(correction,correction,lab.size(),0,0,cv::INTER_LINEAR);
            candidate += correction;
        }
        const float limit = .5f*noise.sigma*.35f*noise.confidence;
        for (int y = 0; y < lab.rows; ++y) for (int x = 0; x < lab.cols; ++x) {
            const auto correction = candidate.at<cv::Vec2f>(y,x)-ab.at<cv::Vec2f>(y,x);
            const float norm = std::sqrt(correction.dot(correction));
            ab.at<cv::Vec2f>(y,x) += correction*std::min(1.f,limit/std::max(norm,1e-8f));
        }
    }
    const int mapping[] = {0,1,1,2};
    cv::mixChannels(&ab,1,&lab,1,mapping,2);
}

// 使用全图坐标重建低分辨率修正，不为 INTER_LINEAR 放大分配完整 ab 图。
cv::Vec2f resizedChroma(const cv::Mat& image, cv::Size destination, int x, int y) {
    const auto coordinate = [](int p, int source, int target, int& first, int& second, float& fraction) {
        const float position = static_cast<float>((p + .5) * double(source) / target - .5);
        first = static_cast<int>(std::floor(position));
        fraction = position - first;
        if (first < 0) { first = 0; fraction = 0; }
        if (first >= source - 1) { first = source - 1; fraction = 0; }
        second = std::min(source - 1, first + 1);
    };
    int x0, x1, y0, y1; float tx, ty;
    coordinate(x, image.cols, destination.width, x0, x1, tx);
    coordinate(y, image.rows, destination.height, y0, y1, ty);
    const auto top = image.at<cv::Vec2f>(y0,x0) * (1 - tx) + image.at<cv::Vec2f>(y0,x1) * tx;
    const auto bottom = image.at<cv::Vec2f>(y1,x0) * (1 - tx) + image.at<cv::Vec2f>(y1,x1) * tx;
    return top * (1 - ty) + bottom * ty;
}

cv::Mat downsampleChroma(const cv::Mat& lab, cv::Size size, const cv::Mat* priorCorrection) {
    cv::Mat result(size, CV_32FC2);
    const double scaleX = double(lab.cols) / size.width, scaleY = double(lab.rows) / size.height;
    for (int y = 0; y < size.height; ++y) {
        const double top = y * scaleY, bottom = (y + 1) * scaleY;
        for (int x = 0; x < size.width; ++x) {
            const double left = x * scaleX, right = (x + 1) * scaleX;
            cv::Vec2f value(0,0);
            for (int sy = int(std::floor(top)); sy < std::min(lab.rows, int(std::ceil(bottom))); ++sy) {
                cv::Vec2f row(0,0);
                const float wy = float((std::min(bottom, double(sy + 1)) - std::max(top, double(sy))) / scaleY);
                for (int sx = int(std::floor(left)); sx < std::min(lab.cols, int(std::ceil(right))); ++sx) {
                    const float wx = float((std::min(right, double(sx + 1)) - std::max(left, double(sx))) / scaleX);
                    const auto pixel = lab.at<cv::Vec3f>(sy,sx);
                    cv::Vec2f sample(pixel[1], pixel[2]);
                    if (priorCorrection) sample += resizedChroma(*priorCorrection, lab.size(), sx, sy);
                    row += sample * wx;
                }
                value += row * wy;
            }
            result.at<cv::Vec2f>(y,x) = value;
        }
    }
    return result;
}


} // namespace
#endif

namespace sony2fuji {

bool chromaDenoiseAvailable() {
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    return true;
#else
    return false;
#endif
}

ErrorCode applyChromaDenoise(ImageData& image, int mode, ChromaDenoiseDiagnostics* diagnostics, GpuMode gpuMode) {
    if (diagnostics) *diagnostics = {};
    if (mode < 0 || mode > 2) return ErrorCode::InvalidFormat;
    if (mode == 0) return ErrorCode::Success;
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    if (image.width <= 0 || image.height <= 0 || image.pixels.size() != static_cast<size_t>(image.width)*image.height)
        return ErrorCode::InvalidFormat;
    static_assert(sizeof(RGB) == 3*sizeof(float));
    cv::Mat rgb(image.height,image.width,CV_32FC3,image.pixels.data()), lab;
    if (!cv::checkRange(rgb)) return ErrorCode::InvalidFormat;
    cv::cvtColor(rgb,lab,cv::COLOR_RGB2Lab);
    const auto noise = estimate(lab);
    if (diagnostics) { diagnostics->flatTiles = noise.tiles; diagnostics->confidence = noise.confidence; }
    if (noise.confidence == 0) return ErrorCode::Success;
    bool gpuUsed = false;
    try { filter(lab,noise,mode == 2,gpuMode,gpuUsed); }
    catch (const ChromaGpuFailure&) { return ErrorCode::ProcessingError; }
    cv::cvtColor(lab,rgb,cv::COLOR_Lab2RGB);
    if (diagnostics) { diagnostics->applied = true; diagnostics->gpuUsed = gpuUsed; }
    return ErrorCode::Success;
#else
    (void)image;
    (void)gpuMode;
    return ErrorCode::InvalidFormat;
#endif
}

// 只用于调用方拥有、失败后可丢弃的工作图；公开入口保留失败不修改输入的语义。
ErrorCode applyChromaDenoiseWorking(ImageData& image, int mode, ChromaDenoiseDiagnostics* diagnostics, GpuMode gpuMode) {
    if (diagnostics) *diagnostics = {};
    if (mode < 0 || mode > 2) return ErrorCode::InvalidFormat;
    if (mode == 0) return ErrorCode::Success;
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    if (image.width <= 0 || image.height <= 0 || image.pixels.size() != size_t(image.width) * image.height)
        return ErrorCode::InvalidFormat;
    cv::Mat pixels(image.height, image.width, CV_32FC3, image.pixels.data());
    if (!cv::checkRange(pixels)) return ErrorCode::InvalidFormat;
    const auto noise = estimate(pixels, true);
    if (diagnostics) { diagnostics->flatTiles = noise.tiles; diagnostics->confidence = noise.confidence; }
    if (noise.confidence == 0) return ErrorCode::Success;
    try {
        const auto convertRows = [&](int conversion) {
            for (int y = 0; y < pixels.rows; y += 64) {
                auto rows = pixels.rowRange(y, std::min(pixels.rows, y + 64));
                cv::Mat converted;
                cv::cvtColor(rows, converted, conversion);
                converted.copyTo(rows);
            }
        };
        convertRows(cv::COLOR_RGB2Lab);
        std::array<cv::Mat, 2> guides, corrections;
        if (mode == 2) {
            for (int i = 0; i < 2; ++i) {
                const int scale = i == 0 ? 4 : 16;
                cv::resize(pixels, guides[i], {std::max(4, pixels.cols / scale), std::max(4, pixels.rows / scale)},
                    0, 0, cv::INTER_AREA);
            }
        }
        // guided 的两次半径 8 滤波、sigma .7 预平滑及 sigma 6 高通总支持小于 64。
        // 先保存原 halo，再写回中心；后续分带永远不读取已降噪的邻域。
        constexpr int rowsPerBand = 128, halo = 64;
        cv::Mat previous;
        int previousFirst = 0, previousEnd = 0;
        bool gpuUsed = false;
        for (int y = 0; y < pixels.rows; y += rowsPerBand) {
            const int end = std::min(pixels.rows, y + rowsPerBand);
            const int top = std::max(0, y - halo), bottom = std::min(pixels.rows, end + halo);
            cv::Mat band = pixels.rowRange(top, bottom).clone();
            if (top < previousEnd)
                previous.rowRange(top - previousFirst, previousEnd - previousFirst).copyTo(band.rowRange(0, previousEnd - top));
            previousEnd = end; previousFirst = std::max(0, end - halo);
            previous = band.rowRange(previousFirst - top, previousEnd - top).clone();
            filter(band, noise, false, gpuMode, gpuUsed);
            band.rowRange(y - top, end - top).copyTo(pixels.rowRange(y, end));
        }
        if (mode == 2) {
            for (int i = 0; i < 2; ++i) {
                const auto source = downsampleChroma(pixels, guides[i].size(), i == 0 ? nullptr : &corrections[0]);
                corrections[i] = guided(guides[i], source, 4, std::max(.05f, 4 * noise.sigma * noise.sigma), gpuMode, gpuUsed) - source;
                guides[i].release();
            }
            const float limit = .5f * noise.sigma * .35f * noise.confidence;
            for (int y = 0; y < pixels.rows; ++y) for (int x = 0; x < pixels.cols; ++x) {
                auto& pixel = pixels.at<cv::Vec3f>(y,x);
                const cv::Vec2f base(pixel[1], pixel[2]);
                const auto candidate = base + resizedChroma(corrections[0], pixels.size(), x, y) +
                    resizedChroma(corrections[1], pixels.size(), x, y);
                const auto correction = candidate - base;
                const float norm = std::sqrt(correction.dot(correction));
                const auto corrected = base + correction * std::min(1.f, limit / std::max(norm, 1e-8f));
                pixel[1] = corrected[0]; pixel[2] = corrected[1];
            }
        }
        convertRows(cv::COLOR_Lab2RGB);
        if (diagnostics) { diagnostics->applied = true; diagnostics->gpuUsed = gpuUsed; }
        return ErrorCode::Success;
    } catch (const ChromaGpuFailure&) { return ErrorCode::ProcessingError; }
    catch (const std::bad_alloc&) { return ErrorCode::OutOfMemory; }
    catch (const cv::Exception& error) {
        return error.code == cv::Error::StsNoMem ? ErrorCode::OutOfMemory : ErrorCode::ProcessingError;
    }
#else
    (void)image; (void)gpuMode;
    return ErrorCode::InvalidFormat;
#endif
}

} // namespace sony2fuji
