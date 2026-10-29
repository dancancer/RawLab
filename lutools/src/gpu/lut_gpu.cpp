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
bool applyLutMetal(const LUT3D& lut, ImageData& image);
#endif

#if defined(SONY2FUJI_ENABLE_GLES)
bool applyLutGles(const LUT3D& lut, ImageData& image);
#endif

namespace {
bool tryMetal(const LUT3D& lut, ImageData& image) {
#if defined(SONY2FUJI_ENABLE_METAL)
    return applyLutMetal(lut, image);
#else
    (void)lut;
    (void)image;
    return false;
#endif
}

bool tryGles(const LUT3D& lut, ImageData& image) {
#if defined(SONY2FUJI_ENABLE_GLES)
    return applyLutGles(lut, image);
#else
    (void)lut;
    (void)image;
    return false;
#endif
}

ErrorCode applyLutCpu(const std::shared_ptr<LUT3D>& lut, ImageData& image) {
    LUTApplicator applicator(lut);
    return applicator.applyToImage(image);
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
        if (config.mode == GpuMode::Force) return ErrorCode::ProcessingError;
        return applyLutCpu(lut,image);
    }

    if (config.mode != GpuMode::Off) {
        ImageData staged = image;
        const auto low = lut->domainMin();
        const auto high = lut->domainMax();
        for (auto& p : staged.pixels) {
            p.r = std::clamp((p.r-low.r)/(high.r-low.r), 0.0f, 1.0f);
            p.g = std::clamp((p.g-low.g)/(high.g-low.g), 0.0f, 1.0f);
            p.b = std::clamp((p.b-low.b)/(high.b-low.b), 0.0f, 1.0f);
        }
        if (tryMetal(*lut, staged) || tryGles(*lut, staged)) {
            image = std::move(staged);
            return ErrorCode::Success;
        }
        if (config.mode == GpuMode::Force) {
            return ErrorCode::ProcessingError;
        }
    }

    return applyLutCpu(lut, image);
}

}
