#include "sony2fuji/gpu/lut_gpu.h"

#include "gpu/lut_gpu_internal.h"
#include "sony2fuji/lut_applicator.h"
#include <algorithm>

namespace sony2fuji {

std::vector<float> buildLutTextureDataRGBA(const LUT3D& lut) {
    const int size = lut.getSize();
    const size_t voxels = static_cast<size_t>(size) * size * size;
    std::vector<float> data;
    data.resize(voxels * 4);
    size_t index = 0;
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                RGB value = lut.getValue(r, g, b);
                data[index++] = value.r;
                data[index++] = value.g;
                data[index++] = value.b;
                data[index++] = 1.0f;
            }
        }
    }
    return data;
}

GpuConfig defaultGpuConfig() {
    GpuConfig config;
#if defined(SONY2FUJI_PLATFORM_IOS) || defined(SONY2FUJI_PLATFORM_ANDROID)
    config.mode = GpuMode::Auto;
#else
    config.mode = GpuMode::Off;
#endif
    return config;
}

#if defined(SONY2FUJI_ENABLE_METAL)
bool applyLutMetal(const LUT3D& lut, ImageData& image, size_t* completedPixels);
#endif

#if defined(SONY2FUJI_ENABLE_GLES)
bool applyLutGles(const LUT3D& lut, ImageData& image, size_t* completedPixels);
#endif

#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES)
namespace {
bool tryMetal(const LUT3D& lut, ImageData& image, size_t* completedPixels) {
#if defined(SONY2FUJI_ENABLE_METAL)
    return applyLutMetal(lut, image, completedPixels);
#else
    (void)lut;
    (void)image;
    (void)completedPixels;
    return false;
#endif
}

bool tryGles(const LUT3D& lut, ImageData& image, size_t* completedPixels) {
#if defined(SONY2FUJI_ENABLE_GLES)
    return applyLutGles(lut, image, completedPixels);
#else
    (void)lut;
    (void)image;
    (void)completedPixels;
    return false;
#endif
}
}
#endif

namespace {
ErrorCode applyLutCpu(const std::shared_ptr<LUT3D>& lut, ImageData& image, size_t begin = 0) {
    LUTApplicator applicator(lut);
    if (begin == 0) {
        return applicator.applyToImage(image);
    }
    if (begin >= image.pixels.size()) {
        return ErrorCode::Success;
    }
    for (size_t i = begin; i < image.pixels.size(); ++i) {
        image.pixels[i] = applicator.apply(image.pixels[i]);
    }
    return ErrorCode::Success;
}

}

ErrorCode applyLUTWithConfig(
    const std::shared_ptr<LUT3D>& lut,
    ImageData& image,
    const GpuConfig& config
) {
    if (!lut || !lut->isValid()) {
        return ErrorCode::InvalidFormat;
    }

    if (image.pixels.empty()) {
        return ErrorCode::ProcessingError;
    }
    if (lut->requiresCPU()) {
        if (config.mode == GpuMode::Force) return ErrorCode::Unsupported;
        return applyLutCpu(lut,image);
    }

    if (config.mode != GpuMode::Off) {
#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES)
        const auto low = lut->domainMin();
        const auto high = lut->domainMax();
        const bool unitDomain = low.r == 0.0f && low.g == 0.0f && low.b == 0.0f &&
            high.r == 1.0f && high.g == 1.0f && high.b == 1.0f;
        // 单位域输入原样交给后端：着色器自带 clamp(0,1)（与旧暂存路径的同值钳制逐位一致），
        // 失败回退时 CPU 第一步也做同值钳制；提交任何瓦片之前调用方像素保持原样。
        ImageData staged;
        ImageData* working = &image;
        if (!unitDomain) {
            // 自定义域归一化有损，CPU 回退必须看到原始像素，保持旧行为。
            staged = image;
            for (auto& p : staged.pixels) {
                p.r = std::clamp((p.r-low.r)/(high.r-low.r), 0.0f, 1.0f);
                p.g = std::clamp((p.g-low.g)/(high.g-low.g), 0.0f, 1.0f);
                p.b = std::clamp((p.b-low.b)/(high.b-low.b), 0.0f, 1.0f);
            }
            working = &staged;
        }
        size_t completedPixels = 0;
        if (tryMetal(*lut, *working, &completedPixels) ||
            tryGles(*lut, *working, unitDomain ? &completedPixels : nullptr)) {
            if (working != &image) image = std::move(staged);
            return ErrorCode::Success;
        }
        if (config.mode == GpuMode::Force) {
            return ErrorCode::ProcessingError;
        }
        // Auto：单位域下失败点之前已有整块瓦片提交进 image（后端仅在瓦片完整成功后回写），
        // 回退只补未提交的尾部 [completedPixels, end)，避免对已提交像素二次套 LUT；
        // 自定义域的暂存在失败时整体丢弃，image 未动，照旧全量 CPU。
        if (unitDomain) {
            return applyLutCpu(lut, image, completedPixels);
        }
#else
        if (config.mode == GpuMode::Force) {
            return ErrorCode::Unsupported;
        }
#endif
    }

    return applyLutCpu(lut, image);
}

}
