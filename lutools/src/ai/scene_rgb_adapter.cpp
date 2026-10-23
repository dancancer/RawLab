#include "scene_rgb_adapter.h"
#include "core/photo_rendering.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji::ai {
namespace {
float inverseDisplay(float encoded) {
    if (encoded <= 0) return 0;
    constexpr float gray = .1845f;
    const float linear = GammaConverter::removeSRGBGamma(encoded);
    return gray * std::pow((1-gray)/gray * linear/(1-linear), 1.f/1.5f);
}
float smooth(float value) {
    const float t = std::clamp(value, 0.f, 1.f);
    return t*t*(3-2*t);
}
void validateImage(const ImageData& image, float gain) {
    if (image.width <= 0 || image.height <= 0 || uint64_t(image.width)*image.height > 128000000 ||
        image.pixels.size() != size_t(image.width)*image.height || !std::isfinite(gain) || gain <= 0)
        throw std::invalid_argument("invalid scene RGB canvas or exposure");
    for (const auto& p : image.pixels)
        if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
            throw ModelContractError("nonfinite scene RGB input");
}
}

Tensor sceneRGBCorrection(const ImageData& source, float gain, const PredictTile& predict,
                          const Progress& progress, TileGeometry geometry) {
    validateImage(source, gain);
    const int core = geometry.size - 2*geometry.halo;
    if (geometry.size < 1 || geometry.size > 2048 || geometry.halo < 0 || core < 1 || !predict)
        throw std::invalid_argument("invalid scene RGB tile geometry");
    const int columns = (source.width+core-1)/core, rows = (source.height+core-1)/core;
    const size_t total = size_t(columns)*rows, plane = size_t(source.width)*source.height;
    Tensor output{source.width, source.height, 3, std::vector<float>(plane*3)};
    size_t done = 0;
    if (progress && !progress(0,total)) throw Cancelled();
    for (int y = 0; y < source.height; y += core) for (int x = 0; x < source.width; x += core) {
        const size_t tilePlane = size_t(geometry.size)*geometry.size;
        Tensor tile{geometry.size,geometry.size,3,std::vector<float>(3*tilePlane)};
        for (int ty = 0; ty < geometry.size; ++ty) for (int tx = 0; tx < geometry.size; ++tx) {
            const auto& p = source.at(reflectIndex(x+tx-geometry.halo,source.width),
                                      reflectIndex(y+ty-geometry.halo,source.height));
            const size_t i = size_t(ty)*geometry.size+tx;
            tile.values[i] = neutralDisplay(gain*p.r);
            tile.values[tilePlane+i] = neutralDisplay(gain*p.g);
            tile.values[2*tilePlane+i] = neutralDisplay(gain*p.b);
        }
        const auto predicted = predict(tile);
        try { validateTensor(predicted); }
        catch (const std::invalid_argument& error) { throw ModelContractError(error.what()); }
        if (predicted.width != tile.width || predicted.height != tile.height || predicted.channels != 3)
            throw ModelContractError("scene RGB model output geometry mismatch");
        for (int cy = 0; cy < std::min(core,source.height-y); ++cy) for (int cx = 0; cx < std::min(core,source.width-x); ++cx) {
            const auto& p = source.at(x+cx,y+cy);
            const size_t i = size_t(cy+geometry.halo)*geometry.size+cx+geometry.halo;
            const size_t dst = size_t(y+cy)*source.width+x+cx;
            const float minimum = std::min({p.r,p.g,p.b}), maximum = std::max({p.r,p.g,p.b});
            float encodedPeak = 0;
            for (int c = 0; c < 3; ++c)
                encodedPeak = std::max({encodedPeak,tile.values[c*tilePlane+i],predicted.values[c*tilePlane+i]});
            // 三通道共用保护权重，避免单独裁切通道造成偏色；保留原片的 HDR 和负值。
            const float weight = smooth(minimum/.005f)*smooth((1-maximum)/.15f)*smooth((.99f-encodedPeak)/.05f);
            if (weight == 0) continue;
            for (int c = 0; c < 3; ++c) {
                const float before = tile.values[c*tilePlane+i], after = predicted.values[c*tilePlane+i];
                if (before != after)
                    output.values[c*plane+dst] = weight*(inverseDisplay(std::max(0.f,after))-inverseDisplay(before))/gain;
            }
        }
        if (progress && !progress(++done,total)) throw Cancelled();
    }
    validateTensor(output);
    return output;
}

void applySceneRGBCorrection(ImageData& image, const Tensor& correction, ColorSpace space, float gain) {
    validateImage(image,gain); validateTensor(correction);
    if (image.width != correction.width || image.height != correction.height || correction.channels != 3)
        throw std::invalid_argument("scene RGB cache does not match the decoded canvas");
    const auto matrix = ColorConverter::getConversionMatrix(ColorSpace::sRGB,space);
    const size_t plane = image.pixels.size();
    for (size_t i = 0; i < plane; ++i) {
        const auto delta = ColorConverter::applyMatrix(RGB(correction.values[i],correction.values[plane+i],correction.values[2*plane+i]),matrix);
        image.pixels[i].r += gain*delta.r;
        image.pixels[i].g += gain*delta.g;
        image.pixels[i].b += gain*delta.b;
    }
}
} // namespace sony2fuji::ai
