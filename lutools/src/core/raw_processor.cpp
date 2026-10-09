#include "sony2fuji/raw_processor.h"
#include "sony2fuji/color_converter.h"
#include "preview_exposure.h"
#include "photo_rendering.h"
#include "white_balance.h"
#include "file_path.h"
#include <libraw/libraw.h>
#include <algorithm>
#include <cmath>
#include <iostream>
#include <memory>
#include <cstring>
#include <fstream>
#include <array>
#include <zlib.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#ifdef _WIN32
#define STBIW_WINDOWS_UTF8
#endif
#include "stb_image_write.h"

#ifdef _OPENMP
namespace {
constexpr int kParallelThreshold = 1 << 16;
}
#endif

namespace sony2fuji {

// ============================================================================
// RAWProcessor::Impl - pImpl pattern
// ============================================================================

class RAWProcessor::Impl {
public:
    Impl() : rawProcessor_(std::make_unique<LibRaw>()) {}

    ErrorCode loadFile(const std::string& filepath) {
        invalidateState();
        if (filepath.empty()) return ErrorCode::FileNotFound;

        filepath_ = filepath;
        auto& params = rawProcessor_->imgdata.params;
        params.use_camera_matrix = 3;
        params.use_camera_wb = 1;
        params.use_auto_wb = 0;
        params.half_size = 0;
        const int ret = openAndUnpack(true, false);
        if (ret != LIBRAW_SUCCESS) {
            std::cerr << "无法打开 RAW 文件: " << libraw_strerror(ret) << std::endl;
            invalidateState();
            return ErrorCode::FileNotFound;
        }

        sourceReady_ = true;
        identificationCameraWB_ = true;
        identificationAutoWB_ = false;
        snapshotCalibration();
        return ErrorCode::Success;
    }

    ErrorCode process(const RAWProcessOptions& options, ImageData& output) {
        output = {};
        if (filepath_.empty() || !sourceReady_) return ErrorCode::FileNotFound;
        if (options.rawNoiseReduction < 0 || options.rawNoiseReduction > 2 ||
            (options.rawNoiseReduction > 0 && !supportsNoiseReduction()))
            return ErrorCode::InvalidFormat;
        if (options.outputBitsPerSample != 8 && options.outputBitsPerSample != 16)
            return ErrorCode::InvalidFormat;
        if (!std::isfinite(options.exposure) || !std::isfinite(options.brightness) ||
            options.brightness <= 0 || std::abs(options.exposure) > 20) return ErrorCode::InvalidFormat;
        const bool customWB = options.useCustomWhiteBalance || options.useTemperatureWhiteBalance;
        float multipliers[4];
        std::copy_n(options.customWhiteBalance,4,multipliers);
        if (options.useTemperatureWhiteBalance &&
            (!whiteBalance_ || !whiteBalance_->multipliers(options.temperature, options.tint, multipliers)))
            return ErrorCode::InvalidFormat;
        const bool cameraWB = options.useCameraWhiteBalance && !customWB && !options.useAutoWhiteBalance;
        const bool autoWB = options.useAutoWhiteBalance && !customWB;
        auto& params = rawProcessor_->imgdata.params;
        // half_size skips the LibRaw interpolation stage that runs FBDD.
        params.half_size = options.halfSize && options.rawNoiseReduction == 0 ? 1 : 0;
        params.fbdd_noiserd = options.rawNoiseReduction;
        if (ensureIdentificationMode(cameraWB, autoWB) != ErrorCode::Success)
            return ErrorCode::ProcessingError;
        params.use_camera_matrix = 3;
        params.use_camera_wb = cameraWB ? 1 : 0;
        params.use_auto_wb = autoWB ? 1 : 0;
        for (int c=0;c<4;++c) {
            const float value=c==3 && multipliers[c]==0 ? multipliers[1] : multipliers[c];
            if (customWB && (!std::isfinite(value) || value<=0))
                return ErrorCode::InvalidFormat;
            params.user_mul[c]=customWB ? value : 0;
        }
        params.output_color = 0;
        params.output_bps = 16;
        params.no_auto_bright = 1;
        params.no_auto_scale = 0;
        params.adjust_maximum_thr = 0;
        // Blend clipped highlight chroma before the camera matrix and film LUT.
        params.highlight = 2;
        params.gamm[0] = params.gamm[1] = 1;
        params.bright = 1;
        params.exp_correc = 0;
        if (rawProcessor_->dcraw_process() != LIBRAW_SUCCESS) {
            // Fatal LibRaw processing errors may recycle unpacked data internally.
            // Require a fresh load rather than advertising a reusable source.
            invalidateState();
            return ErrorCode::ProcessingError;
        }
        auto& data = rawProcessor_->imgdata;
        const int channels = data.idata.colors;
        if (channels != 3 && channels != 4) {
            rawProcessor_->free_image();
            return ErrorCode::InvalidFormat;
        }
        if (!data.image || !data.color.maximum) {
            rawProcessor_->free_image();
            return ErrorCode::ProcessingError;
        }

        // Bayer half-size keeps the active crop in width/height while image is
        // allocated with iwidth/iheight. Fuji rotation and pixel-aspect stretch
        // instead replace width/height with the postprocess geometry.
        const bool postprocessGeometry = fujiRotate_ ||
            (std::isfinite(data.sizes.pixel_aspect) && data.sizes.pixel_aspect > 0 &&
             std::abs(data.sizes.pixel_aspect - 1.0) > .005);
        const int width = postprocessGeometry ? data.sizes.width : data.sizes.iwidth;
        const int height = postprocessGeometry ? data.sizes.height : data.sizes.iheight;
        if (width <= 0 || height <= 0) {
            rawProcessor_->free_image();
            return ErrorCode::ProcessingError;
        }
        const float green=data.color.pre_mul[1];
        if (!std::isfinite(green) || green<=0) {
            rawProcessor_->free_image();
            return ErrorCode::ProcessingError;
        }
        // LibRaw balances camera channels before demosaic, normalized by max WB
        // (highlight=2). Undo that common attenuation in float, not in uint16.
        const float scale=1.0f/(65535.0f*green);

        auto linearRGB=[&](int row,int col) {
            const auto& raw=data.image[static_cast<size_t>(row)*width+col];
            float rgb[3]={};
            for (int dst=0;dst<3;++dst) for (int c=0;c<channels;++c)
                rgb[dst]+=data.color.rgb_cam[dst][c]*raw[c]*scale;
            return RGB(rgb[0],rgb[1],rgb[2]);
        };
        baselineExposureEV_=options.applyBaselineExposure ? sceneExposureEV(metadataExposureEV_) : 0;
        previewExposureEV_=0;
        if (options.matchEmbeddedPreviewExposure) {
            auto preview=loadPreviewLuminance(filepath_);
            if (!preview.empty()) {
                std::vector<float> luminance;
                luminance.reserve(128*128);
                for (int y=0;y<128;++y) for (int x=0;x<128;++x) {
                    const auto p=linearRGB((2*y+1)*height/256,(2*x+1)*width/256);
                    luminance.push_back(std::max(0.0f,.2126f*p.r+.7152f*p.g+.0722f*p.b));
                }
                bool matched=false;
                previewExposureEV_=estimatePreviewExposureEV(std::move(luminance),std::move(preview),&matched);
                if (matched) baselineExposureEV_=previewExposureEV_;
            }
        }
        // User EV remains relative to a fixed per-file baseline, before the LUT.
        const float gain=std::exp2(baselineExposureEV_+options.exposure)*options.brightness;
        if (!std::isfinite(gain) || gain<=0) {
            rawProcessor_->free_image();
            return ErrorCode::InvalidFormat;
        }

        const int flip = data.sizes.flip;
        output.width = (flip & 4) ? height : width;
        output.height = (flip & 4) ? width : height;
        output.pixels.resize(static_cast<size_t>(output.width)*output.height);
        ColorSpace target = options.outputAdobe ? ColorSpace::AdobeRGB :
            (options.outputAces ? ColorSpace::ACES2065_1 : ColorSpace::sRGB);
        const auto matrix = ColorConverter::getConversionMatrix(ColorSpace::sRGB, target);
        outputSpace_ = options.outputLinear ? target : ColorSpace::sRGB;
#ifdef _OPENMP
#pragma omp parallel for if (static_cast<int64_t>(output.width)*output.height >= kParallelThreshold)
#endif
        for (int y=0;y<output.height;++y) for (int x=0;x<output.width;++x) {
            int row=y, col=x;
            if (flip & 4) std::swap(row,col);
            if (flip & 2) row=height-1-row;
            if (flip & 1) col=width-1-col;
            auto rgb=linearRGB(row,col);
            rgb=RGB(rgb.r*gain,rgb.g*gain,rgb.b*gain);
            RGB pixel = ColorConverter::applyMatrix(rgb,matrix);
            if (!options.outputLinear) {
                pixel = RGB(neutralDisplay(rgb.r),neutralDisplay(rgb.g),neutralDisplay(rgb.b));
                if (options.outputBitsPerSample == 8) {
                    pixel.r=std::round(pixel.r*255)/255;
                    pixel.g=std::round(pixel.g*255)/255;
                    pixel.b=std::round(pixel.b*255)/255;
                }
            }
            output.at(x,y)=pixel;
        }
        rawProcessor_->free_image();
        return ErrorCode::Success;
    }

    int getWidth() const {
        return sourceReady_ ? width_ : 0;
    }

    int getHeight() const {
        return sourceReady_ ? height_ : 0;
    }

    std::string getCameraMake() const {
        return sourceReady_ ? cameraMake_ : std::string();
    }

    std::string getCameraModel() const {
        return sourceReady_ ? cameraModel_ : std::string();
    }

    ColorSpace getNativeColorSpace() const {
        return outputSpace_;
    }

    float getPreviewExposureEV() const { return previewExposureEV_; }
    float getBaselineExposureEV() const { return baselineExposureEV_; }
    float getMetadataExposureEV() const { return metadataExposureEV_; }
    bool getAsShotWhiteBalance(float& temperature, float& tint) const {
        if (!whiteBalance_ || !whiteBalance_->available()) return false;
        temperature=whiteBalance_->asShot().temperature;
        tint=whiteBalance_->asShot().tint;
        return true;
    }

    bool supportsNoiseReduction() const { return sourceReady_ && noiseReductionSupported_; }

    bool getCameraColorMatrix(float matrix[3][3]) const {
        if (!cameraColorMatrixValid_) return false;
        for (int row=0; row<3; ++row) for (int col=0; col<3; ++col)
            matrix[row][col] = cameraColorMatrix_[row][col];
        return true;
    }

private:
    void invalidateState() {
        rawProcessor_->recycle();
        filepath_.clear();
        sourceReady_ = false;
        identificationCameraWB_ = false;
        identificationAutoWB_ = false;
        width_ = height_ = 0;
        cameraMake_.clear();
        cameraModel_.clear();
        whiteBalance_.reset();
        cameraColorMatrixValid_ = false;
        noiseReductionSupported_ = false;
        previewExposureEV_ = 0;
        baselineExposureEV_ = 0;
        metadataExposureEV_ = 0;
        fujiRotate_ = false;
        outputSpace_ = ColorSpace::sRGB;
    }

    int openAndUnpack(bool cameraWB, bool autoWB) {
        // open_file replaces LibRaw's datastream ownership flag before opening.
        // Explicitly close the previous stream first (Windows otherwise leaks a
        // file handle on camera/custom WB mode switches).
        rawProcessor_->recycle();
        auto& params = rawProcessor_->imgdata.params;
        // 切换白平衡不能同时切换相机色矩阵，3 表示始终使用内嵌色彩数据。
        params.use_camera_matrix = 3;
        params.use_camera_wb = cameraWB ? 1 : 0;
        params.use_auto_wb = autoWB ? 1 : 0;
        const int openResult = openRawFile(*rawProcessor_, filepath_);
        if (openResult != LIBRAW_SUCCESS) return openResult;
        const int unpackResult = rawProcessor_->unpack();
        if (unpackResult != LIBRAW_SUCCESS) return unpackResult;
        // 部分解码器只记录损坏计数却返回成功，不能继续导出损坏的像素。
        if (rawProcessor_->error_count()!=0) return LIBRAW_DATA_ERROR;
        rawProcessor_->adjust_to_raw_inset_crop(3);
        return LIBRAW_SUCCESS;
    }

    void snapshotCalibration() {
        const auto& data = rawProcessor_->imgdata;
        noiseReductionSupported_ = data.idata.colors == 3 && data.idata.filters > 1000 && !data.idata.is_foveon;
        width_ = data.sizes.width;
        height_ = data.sizes.height;
        cameraMake_ = data.idata.make;
        cameraModel_ = data.idata.model;
        const float dngExposure = data.color.dng_levels.baseline_exposure;
        metadataExposureEV_ = std::isfinite(dngExposure) && std::abs(dngExposure) <= 8 ? dngExposure : 0;
        fujiRotate_ = data.rawdata.ioparams.fuji_width != 0;
        whiteBalance_ = std::make_unique<CameraWhiteBalance>(data);
        cameraColorMatrixValid_ = data.idata.colors == 3;
        const float xyz[3][3] = {
            {.4124564f,.3575761f,.1804375f},
            {.2126729f,.7151522f,.0721750f},
            {.0193339f,.1191920f,.9503041f}
        };
        for (int row=0; row<3; ++row) for (int col=0; col<3; ++col) {
            cameraColorMatrix_[row][col] = 0;
            for (int k=0; k<3; ++k)
                cameraColorMatrix_[row][col] += xyz[row][k] * data.color.rgb_cam[k][col];
        }
    }

    ErrorCode ensureIdentificationMode(bool cameraWB, bool autoWB) {
        if (cameraWB == identificationCameraWB_ && autoWB == identificationAutoWB_)
            return ErrorCode::Success;
        const int ret = openAndUnpack(cameraWB, autoWB);
        if (ret != LIBRAW_SUCCESS) {
            std::cerr << "无法重新加载 RAW 文件: " << libraw_strerror(ret) << std::endl;
            invalidateState();
            return ErrorCode::ProcessingError;
        }
        identificationCameraWB_ = cameraWB;
        identificationAutoWB_ = autoWB;
        sourceReady_ = true;
        return ErrorCode::Success;
    }

    std::unique_ptr<LibRaw> rawProcessor_;
    std::string filepath_;
    std::string cameraMake_;
    std::string cameraModel_;
    std::unique_ptr<CameraWhiteBalance> whiteBalance_;
    std::array<std::array<float,3>,3> cameraColorMatrix_{};
    bool cameraColorMatrixValid_ = false;
    bool noiseReductionSupported_ = false;
    bool sourceReady_ = false;
    bool identificationCameraWB_ = false;
    bool identificationAutoWB_ = false;
    bool fujiRotate_ = false;
    int width_ = 0;
    int height_ = 0;
    ColorSpace outputSpace_ = ColorSpace::sRGB;
    float previewExposureEV_ = 0;
    float baselineExposureEV_ = 0;
    float metadataExposureEV_ = 0;
};

// ============================================================================
// RAWProcessor Implementation
// ============================================================================

RAWProcessor::RAWProcessor()
    : pImpl_(std::make_unique<Impl>()) {
}

RAWProcessor::~RAWProcessor() = default;

ErrorCode RAWProcessor::loadFile(const std::string& filepath) {
    return pImpl_->loadFile(filepath);
}

ErrorCode RAWProcessor::process(const RAWProcessOptions& options, ImageData& output) {
    return pImpl_->process(options, output);
}

int RAWProcessor::getWidth() const {
    return pImpl_->getWidth();
}

int RAWProcessor::getHeight() const {
    return pImpl_->getHeight();
}

std::string RAWProcessor::getCameraMake() const {
    return pImpl_->getCameraMake();
}

std::string RAWProcessor::getCameraModel() const {
    return pImpl_->getCameraModel();
}

ColorSpace RAWProcessor::getNativeColorSpace() const {
    return pImpl_->getNativeColorSpace();
}

float RAWProcessor::getPreviewExposureEV() const {
    return pImpl_->getPreviewExposureEV();
}

float RAWProcessor::getBaselineExposureEV() const { return pImpl_->getBaselineExposureEV(); }
float RAWProcessor::getMetadataExposureEV() const { return pImpl_->getMetadataExposureEV(); }
bool RAWProcessor::getAsShotWhiteBalance(float& temperature, float& tint) const {
    return pImpl_->getAsShotWhiteBalance(temperature,tint);
}

bool RAWProcessor::supportsNoiseReduction() const {
    return pImpl_->supportsNoiseReduction();
}

bool RAWProcessor::getCameraColorMatrix(float matrix[3][3]) const {
    return pImpl_->getCameraColorMatrix(matrix);
}

// ============================================================================
// ImageEncoder Implementation
// ============================================================================

uint8_t ImageEncoder::floatToUint8(float value) {
    value = std::max(0.0f, std::min(1.0f, value));
    return static_cast<uint8_t>(value * 255.0f + 0.5f);
}

uint16_t ImageEncoder::floatToUint16(float value) {
    value = std::max(0.0f, std::min(1.0f, value));
    return static_cast<uint16_t>(value * 65535.0f + 0.5f);
}

ErrorCode ImageEncoder::saveImage(
    const ImageData& image,
    const std::string& filepath,
    OutputFormat format,
    int quality
) {
    switch (format) {
        case OutputFormat::JPEG:
            return saveJPEG(image, filepath, quality);
        case OutputFormat::PNG:
            return savePNG(image, filepath);
        default:
            return ErrorCode::InvalidFormat;
    }
}

ErrorCode ImageEncoder::saveJPEG(
    const ImageData& image,
    const std::string& filepath,
    int quality
) {
    if (image.pixels.empty()) {
        return ErrorCode::ProcessingError;
    }

    // 转换为 uint8_t
    std::vector<uint8_t> data(image.width * image.height * 3);

    const int pixel_count = image.width * image.height;
#ifdef _OPENMP
#pragma omp parallel for if (pixel_count >= kParallelThreshold)
#endif
    for (int i = 0; i < pixel_count; ++i) {
        data[i * 3 + 0] = floatToUint8(image.pixels[i].r);
        data[i * 3 + 1] = floatToUint8(image.pixels[i].g);
        data[i * 3 + 2] = floatToUint8(image.pixels[i].b);
    }

    int result = stbi_write_jpg(
        filepath.c_str(),
        image.width,
        image.height,
        3,
        data.data(),
        quality
    );

    if (result == 0) {
        std::cerr << "保存 JPEG 失败: " << filepath << std::endl;
        return ErrorCode::ProcessingError;
    }

    std::cout << "成功保存: " << filepath << std::endl;
    return ErrorCode::Success;
}

ErrorCode ImageEncoder::savePNG(const ImageData& image, const std::string& filepath) {
    if (image.width <= 0 || image.height <= 0 ||
        image.pixels.size() != static_cast<size_t>(image.width) * image.height)
        return ErrorCode::ProcessingError;
    std::ofstream file(std::filesystem::u8path(filepath), std::ios::binary);
    if (!file) return ErrorCode::ProcessingError;
    auto write32 = [&](uint32_t value) {
        unsigned char bytes[] = {static_cast<unsigned char>(value>>24),
            static_cast<unsigned char>(value>>16), static_cast<unsigned char>(value>>8),
            static_cast<unsigned char>(value)};
        file.write(reinterpret_cast<char*>(bytes), 4);
    };
    auto chunk = [&](const char* type, const unsigned char* data, size_t length) {
        write32(static_cast<uint32_t>(length));
        file.write(type, 4);
        if (length) file.write(reinterpret_cast<const char*>(data), length);
        uLong crc = crc32(0, reinterpret_cast<const Bytef*>(type), 4);
        if (length) crc = crc32(crc, data, static_cast<uInt>(length));
        write32(static_cast<uint32_t>(crc));
    };
    const unsigned char signature[] = {137,80,78,71,13,10,26,10};
    file.write(reinterpret_cast<const char*>(signature), sizeof(signature));
    unsigned char header[13] = {};
    for (int i=0; i<4; ++i) {
        header[i] = static_cast<unsigned char>(image.width >> (24-8*i));
        header[4+i] = static_cast<unsigned char>(image.height >> (24-8*i));
    }
    header[8]=16; header[9]=2;
    chunk("IHDR", header, sizeof(header));
    const unsigned char intent = 0;
    chunk("sRGB", &intent, 1);
    z_stream stream{};
    if (deflateInit(&stream, Z_DEFAULT_COMPRESSION) != Z_OK) return ErrorCode::ProcessingError;
    std::vector<unsigned char> row(static_cast<size_t>(image.width)*6+1);
    std::array<unsigned char, 65536> compressed;
    bool ok = true;
    for (int y=0; y<image.height && ok; ++y) {
        row[0]=0;
        for (int x=0; x<image.width; ++x) {
            const auto& p = image.at(x,y);
            const uint16_t values[] = {floatToUint16(p.r),floatToUint16(p.g),floatToUint16(p.b)};
            for (int c=0;c<3;++c) {
                row[1+x*6+c*2] = static_cast<unsigned char>(values[c]>>8);
                row[2+x*6+c*2] = static_cast<unsigned char>(values[c]);
            }
        }
        stream.next_in = row.data();
        stream.avail_in = static_cast<uInt>(row.size());
        const int flush = y == image.height-1 ? Z_FINISH : Z_NO_FLUSH;
        int status;
        do {
            stream.next_out = compressed.data();
            stream.avail_out = compressed.size();
            status = deflate(&stream, flush);
            if (status != Z_OK && status != Z_STREAM_END) { ok=false; break; }
            const size_t size = compressed.size()-stream.avail_out;
            if (size) chunk("IDAT", compressed.data(), size);
        } while (stream.avail_in || stream.avail_out == 0 || (flush == Z_FINISH && status != Z_STREAM_END));
    }
    deflateEnd(&stream);
    chunk("IEND", nullptr, 0);
    file.flush();
    return ok && file.good() ? ErrorCode::Success : ErrorCode::ProcessingError;
}

} // namespace sony2fuji
