#include "sony2fuji/raw_processor.h"
#include "sony2fuji/color_converter.h"
#include "preview_exposure.h"
#include "photo_rendering.h"
#include "white_balance.h"
#include "file_path.h"
#include "processing_cancellation.h"
#include <libraw/libraw.h>
#include "x3f_processor.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <memory>
#include <cstring>
#include <fstream>
#include <array>
#include <zlib.h>
#ifdef SONY2FUJI_ENABLE_DNGSDK
#include <dng_host.h>
#endif

#define STB_IMAGE_WRITE_IMPLEMENTATION
#ifdef _WIN32
#define STBIW_WINDOWS_UTF8
#endif
#include "stb_image_write.h"
#include "rendered_dng.h"

#ifdef _OPENMP
namespace {
constexpr int kParallelThreshold = 1 << 16;
}
#endif

namespace sony2fuji {

namespace {
class RawCancellationScope {
    LibRaw& raw_;
    ProcessingCancellation cancellation_ = processingCancellation;
    static int progress(void* context, LibRaw_progress, int, int) {
        return static_cast<ProcessingCancellation*>(context)->cancelled() ? 1 : 0;
    }
public:
    explicit RawCancellationScope(LibRaw& raw) : raw_(raw) {
        cancellation_.check();
        raw_.set_progress_handler(progress, &cancellation_);
    }
    ~RawCancellationScope() { raw_.set_progress_handler(nullptr, nullptr); }
};

float sampleCameraCorrection(const std::vector<RGB>& pixels, int width, int height, int channel, float x, float y) {
    if (!std::isfinite(x) || !std::isfinite(y) || x < -1e-4f || y < -1e-4f ||
        x > width - 1 + 1e-4f || y > height - 1 + 1e-4f) return 0;
    x = std::clamp(x, 0.f, float(width - 1)); y = std::clamp(y, 0.f, float(height - 1));
    const int x0 = int(std::floor(x)), y0 = int(std::floor(y));
    const int x1 = std::min(x0 + 1, width - 1), y1 = std::min(y0 + 1, height - 1);
    auto at = [&](int col, int row) {
        const auto& value = pixels[size_t(row) * width + col];
        return channel == 0 ? value.r : channel == 1 ? value.g : value.b;
    };
    const float dx = x - x0, dy = y - y0;
    return ((1-dx)*at(x0,y0) + dx*at(x1,y0))*(1-dy) + ((1-dx)*at(x0,y1) + dx*at(x1,y1))*dy;
}

class BayerOverrideScope {
public:
    BayerOverrideScope(LibRaw& raw, const RAWBayerSource& source, const RAWBayerOverride* replacement)
        : raw_(raw) {
        if (!replacement) return;
        original_ = raw.imgdata.rawdata.raw_image;
        pitch_ = raw.imgdata.sizes.raw_pitch / sizeof(uint16_t);
        left_ = raw.imgdata.sizes.left_margin; top_ = raw.imgdata.sizes.top_margin;
        width_ = source.width; height_ = source.height;
        backup_.resize(size_t(width_) * height_);
        for (int y = 0; y < height_; ++y)
            std::copy_n(original_ + (size_t(y) + top_) * pitch_ + left_, width_, backup_.data() + size_t(y) * width_);
        for (int y = 0; y < height_; ++y) for (int x = 0; x < width_; ++x) {
            const float black = source.black[source.pattern[(y % 2) * 2 + x % 2]];
            const float value = std::clamp(replacement->normalizedMosaic[size_t(y) * width_ + x], 0.f, 1.f);
            original_[(size_t(y) + top_) * pitch_ + left_ + x] = uint16_t(std::lround(value * (source.white - black) + black));
        }
    }
    ~BayerOverrideScope() {
        // LibRaw 的致命错误可能自行 recycle，此时原地址已失效。
        if (!original_ || raw_.imgdata.rawdata.raw_image != original_) return;
        for (int y = 0; y < height_; ++y)
            std::copy_n(backup_.data() + size_t(y) * width_, width_, original_ + (size_t(y) + top_) * pitch_ + left_);
    }
private:
    LibRaw& raw_;
    uint16_t* original_ = nullptr;
    size_t pitch_ = 0;
    int left_ = 0, top_ = 0, width_ = 0, height_ = 0;
    std::vector<uint16_t> backup_;
};

LensMetadata lensMetadata(const LibRaw& processor, bool sdkStage3 = false) {
    const auto& data = processor.imgdata;
    LensMetadata metadata;
    metadata.cameraMake = data.idata.make;
    metadata.cameraModel = data.idata.model;
    metadata.lensMake = data.lens.LensMake;
    metadata.lensModel = data.lens.Lens[0] ? data.lens.Lens : data.lens.makernotes.Lens;
    metadata.focalLength = data.other.focal_len;
    metadata.aperture = data.other.aperture;
    if (metadata.focalLength > 0 && data.lens.FocalLengthIn35mmFormat > 0)
        metadata.cropFactor = data.lens.FocalLengthIn35mmFormat / metadata.focalLength;
    // SDK Stage3 may contain a spatial correction; conservatively avoid stacking a profile.
    metadata.embeddedGeometry = sdkStage3;
    return metadata;
}
}

// ============================================================================
// RAWProcessor::Impl - pImpl pattern
// ============================================================================

class RAWProcessor::Impl {
public:
    Impl() : rawProcessor_(std::make_unique<LibRaw>()) {}

    ErrorCode loadFile(const std::string& filepath, X3fMode mode = X3fMode::Legacy) {
        RawCancellationScope cancellation(*rawProcessor_);
        invalidateState();
        if (filepath.empty()) return ErrorCode::FileNotFound;
        if (mode != X3fMode::Legacy && mode != X3fMode::Normal) return ErrorCode::InvalidFormat;

        filepath_ = filepath;
        auto& params = rawProcessor_->imgdata.params;
        params.use_camera_matrix = 3;
        params.use_camera_wb = 1;
        params.use_auto_wb = 0;
        params.half_size = 0;
        const bool metadataOnly = mode == X3fMode::Normal && hasX3fSignature(filepath);
        const int ret = openAndUnpack(true, false, !metadataOnly);
        if (ret != LIBRAW_SUCCESS) {
            std::cerr << "无法打开 RAW 文件: " << libraw_strerror(ret) << std::endl;
            invalidateState();
            if (ret == LIBRAW_CANCELLED_BY_CALLBACK) throw ProcessingCancelled();
            return decodeError(ret);
        }

        sourceReady_ = true;
        identificationCameraWB_ = true;
        identificationAutoWB_ = false;
        snapshotCalibration();
        return ErrorCode::Success;
    }

    ErrorCode process(const RAWProcessOptions& options, ImageData& output) {
        RawCancellationScope cancellationScope(*rawProcessor_);
        output = {};
        if (filepath_.empty() || !sourceReady_) return ErrorCode::FileNotFound;
        if (options.rawNoiseReduction < 0 || options.rawNoiseReduction > 2 ||
            (options.rawNoiseReduction > 0 && !supportsNoiseReduction()))
            return ErrorCode::InvalidFormat;
        if (options.bayerDemosaic != BayerDemosaicMethod::Legacy &&
            options.bayerDemosaic != BayerDemosaicMethod::VNG && options.bayerDemosaic != BayerDemosaicMethod::DHT)
            return ErrorCode::InvalidFormat;
        if (options.outputBitsPerSample != 8 && options.outputBitsPerSample != 16)
            return ErrorCode::InvalidFormat;
        if (!std::isfinite(options.exposure) || !std::isfinite(options.brightness) ||
            options.brightness <= 0 || std::abs(options.exposure) > 20) return ErrorCode::InvalidFormat;
        if (options.x3fMode != X3fMode::Legacy && options.x3fMode != X3fMode::Normal) return ErrorCode::InvalidFormat;
        displayReferred_ = false;
        lastError_.clear();
        const bool x3fSignature = options.x3fMode == X3fMode::Normal && hasX3fSignature(filepath_);
        if (options.x3fMode == X3fMode::Normal && !x3fSignature &&
            (rawProcessor_->imgdata.idata.is_foveon || hasX3fExtension(filepath_))) {
            lastError_ = "The X3F source does not contain a valid FOVb header";
            return ErrorCode::InvalidFormat;
        }
        if (x3fSignature) {
            if (!x3fProcessor_) x3fProcessor_ = std::make_unique<X3fProcessor>();
            const auto result = x3fProcessor_->process(filepath_, cameraModel_, rawProcessor_->imgdata.sizes.flip, options, output);
            lastError_ = x3fProcessor_->error();
            if (result != ErrorCode::Success) return result;
            displayReferred_ = true;
            baselineExposureEV_ = previewExposureEV_ = 0;
            outputSpace_ = options.outputLinear && options.outputAdobe ? ColorSpace::AdobeRGB :
                (options.outputLinear && options.outputAces ? ColorSpace::ACES2065_1 : ColorSpace::sRGB);
            lensReport_ = {};
            return ErrorCode::Success;
        }
        const bool customWB = options.useCustomWhiteBalance || options.useTemperatureWhiteBalance;
        const bool cameraWB = options.useCameraWhiteBalance && !customWB && !options.useAutoWhiteBalance;
        const bool autoWB = options.useAutoWhiteBalance && !customWB;
        auto& params = rawProcessor_->imgdata.params;
        // half_size skips the LibRaw interpolation stage that runs FBDD.
        params.half_size = options.halfSize && options.rawNoiseReduction == 0 ? 1 : 0;
        params.fbdd_noiserd = options.rawNoiseReduction;
        const ErrorCode identificationResult = ensureIdentificationMode(cameraWB, autoWB);
        if (identificationResult != ErrorCode::Success) return identificationResult;
        float multipliers[4];
        std::copy_n(options.customWhiteBalance,4,multipliers);
        if (options.useTemperatureWhiteBalance &&
            (!whiteBalance_ || !whiteBalance_->multipliers(options.temperature, options.tint, multipliers)))
            return ErrorCode::InvalidFormat;
        // 非 Bayer 必须重置，避免复用处理器时把 X-Trans 误送入 VNG。
        params.user_qual = bayerSource_ && options.bayerDemosaic != BayerDemosaicMethod::Legacy ?
            (options.bayerDemosaic == BayerDemosaicMethod::VNG ? 1 : 11) : -1;
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
        const auto* replacement = options.bayerOverride;
        if (replacement && (!bayerMetadataReady_ || options.halfSize || options.rawNoiseReduction != 0 || autoWB ||
            replacement->width != bayerMetadata_.width || replacement->height != bayerMetadata_.height ||
            replacement->normalizedMosaic.size() != size_t(bayerMetadata_.width) * bayerMetadata_.height ||
            (!replacement->cameraCorrection.empty() && replacement->cameraCorrection.size() != replacement->normalizedMosaic.size()) ||
            !std::all_of(replacement->normalizedMosaic.begin(), replacement->normalizedMosaic.end(), [](float x) { return std::isfinite(x); }) ||
            !std::all_of(replacement->cameraCorrection.begin(), replacement->cameraCorrection.end(), [](const RGB& p) {
                return std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b);
            }))) return ErrorCode::InvalidFormat;
        BayerOverrideScope overrideScope(*rawProcessor_, bayerMetadata_, replacement);
        const int processed = rawProcessor_->dcraw_process();
        if (processed != LIBRAW_SUCCESS) {
            // Fatal LibRaw processing errors may recycle unpacked data internally.
            // Require a fresh load rather than advertising a reusable source.
            invalidateState();
            if (processed == LIBRAW_CANCELLED_BY_CALLBACK) throw ProcessingCancelled();
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
        if (replacement && (width != replacement->width || height != replacement->height)) {
            rawProcessor_->free_image();
            return ErrorCode::InvalidFormat;
        }
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

        LensCorrectionTransform correction(options.lensDatabase, lensMetadata(*rawProcessor_, sdkStage3_),
            options.lensCorrection, width, height, channels);
        lensReport_ = correction.report();
        auto sampledRGB=[&](int row,int col,const float* coordinates) {
            const auto& raw=data.image[static_cast<size_t>(row)*width+col];
            float rgb[3]={};
            float camera[4];
            for (int c=0;c<channels;++c) {
                const int mapped = c == 3 ? 1 : c;
                camera[c] = coordinates ? sampleCameraChannel(&data.image[0][0], width, height, c,
                    coordinates[mapped*2], coordinates[mapped*2+1]) : raw[c];
            }
            for (int dst=0;dst<3;++dst) for (int c=0;c<channels;++c)
                rgb[dst]+=data.color.rgb_cam[dst][c]*camera[c]*scale;
            if (replacement && !replacement->cameraCorrection.empty()) {
                const auto& value = replacement->cameraCorrection[size_t(row) * width + col];
                for (int c = 0; c < 3; ++c) {
                    const float delta = coordinates ? sampleCameraCorrection(replacement->cameraCorrection, width, height, c,
                        coordinates[c*2], coordinates[c*2+1]) : c == 0 ? value.r : c == 1 ? value.g : value.b;
                    if (delta != 0) for (int dst = 0; dst < 3; ++dst) rgb[dst] += data.color.rgb_cam[dst][c] * delta;
                }
            }
            return RGB(rgb[0],rgb[1],rgb[2]);
        };
        auto linearRGB=[&](int row,int col) {
            alignas(16) float coordinates[6];
            if (correction.active()) correction.map(col, row, 1, 1, coordinates);
            return sampledRGB(row, col, correction.active() ? coordinates : nullptr);
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
        const auto cancellation = processingCancellation;
#ifdef _OPENMP
#pragma omp parallel for if (static_cast<int64_t>(output.width)*output.height >= kParallelThreshold)
#endif
        for (int y=0;y<output.height;++y) {
            if (cancellation.cancelled()) continue;
            std::vector<float> coordinates;
            if (correction.active()) {
                coordinates.resize(static_cast<size_t>(output.width)*6);
                if (flip & 4) correction.map((flip & 1) ? width-1-y : y, 0, 1, height, coordinates.data());
                else correction.map(0, (flip & 2) ? height-1-y : y, width, 1, coordinates.data());
            }
            for (int x=0;x<output.width;++x) {
                int row=y, col=x;
                if (flip & 4) std::swap(row,col);
                if (flip & 2) row=height-1-row;
                if (flip & 1) col=width-1-col;
                const int mappedIndex = (flip & 4) ? row : col;
                auto rgb=sampledRGB(row,col,coordinates.empty() ? nullptr : coordinates.data()+mappedIndex*6);
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
        }
        rawProcessor_->free_image();
        cancellation.check();
        return ErrorCode::Success;
    }

    ErrorCode readBayerSource(const RAWProcessOptions& options, RAWBayerSource& output) {
        output = {};
        if (!sourceReady_ || !bayerMetadataReady_ || options.useAutoWhiteBalance ||
            !rawProcessor_->imgdata.rawdata.raw_image) return ErrorCode::InvalidFormat;
        output = bayerMetadata_;
        if (options.useTemperatureWhiteBalance) {
            if (!whiteBalance_ || !whiteBalance_->multipliers(options.temperature, options.tint, output.whiteBalance.data())) {
                output = {}; return ErrorCode::InvalidFormat;
            }
        } else if (options.useCustomWhiteBalance) {
            std::copy_n(options.customWhiteBalance, 4, output.whiteBalance.begin());
        } else if (!options.useCameraWhiteBalance) {
            output.whiteBalance = bayerDaylightWB_;
        }
        if (output.whiteBalance[3] == 0) output.whiteBalance[3] = output.whiteBalance[1];
        if (!std::all_of(output.whiteBalance.begin(), output.whiteBalance.end(), [](float x) { return std::isfinite(x) && x > 0; })) {
            output = {}; return ErrorCode::InvalidFormat;
        }
        output.pixels.resize(size_t(output.width) * output.height);
        const auto& data = rawProcessor_->imgdata;
        const size_t pitch = data.sizes.raw_pitch / sizeof(uint16_t);
        for (int y = 0; y < output.height; ++y)
            std::copy_n(data.rawdata.raw_image + (size_t(y) + data.sizes.top_margin) * pitch + data.sizes.left_margin,
                        output.width, output.pixels.data() + size_t(y) * output.width);
        return ErrorCode::Success;
    }

    bool getBayerMetadata(RAWBayerSource& output) const {
        output = sourceReady_ && bayerMetadataReady_ ? bayerMetadata_ : RAWBayerSource{};
        return sourceReady_ && bayerMetadataReady_;
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
        if (displayReferred_) return false;
        if (!whiteBalance_ || !whiteBalance_->available()) return false;
        temperature=whiteBalance_->asShot().temperature;
        tint=whiteBalance_->asShot().tint;
        return true;
    }

    bool supportsNoiseReduction() const { return sourceReady_ && bayerSource_; }
    bool isDisplayReferred() const { return displayReferred_; }
    const std::string& getLastError() const { return lastError_; }
    LensCorrectionReport getLensCorrectionReport() const { return lensReport_; }

    bool getCameraColorMatrix(float matrix[3][3]) const {
        if (!cameraColorMatrixValid_) return false;
        for (int row=0; row<3; ++row) for (int col=0; col<3; ++col)
            matrix[row][col] = cameraColorMatrix_[row][col];
        return true;
    }

private:
    void invalidateState() {
        x3fProcessor_.reset();
        displayReferred_ = false;
        lastError_.clear();
        rawProcessor_->recycle();
        filepath_.clear();
        sourceReady_ = false;
        sourceUnpacked_ = false;
        identificationCameraWB_ = false;
        identificationAutoWB_ = false;
        width_ = height_ = 0;
        cameraMake_.clear();
        cameraModel_.clear();
        whiteBalance_.reset();
        cameraColorMatrixValid_ = false;
        bayerSource_ = false;
        previewExposureEV_ = 0;
        baselineExposureEV_ = 0;
        metadataExposureEV_ = 0;
        fujiRotate_ = false;
        sdkStage3_ = false;
        lensReport_ = {};
        outputSpace_ = ColorSpace::sRGB;
        bayerMetadata_ = {}; bayerMetadataReady_ = false; bayerDaylightWB_ = {};
    }

    int openAndUnpack(bool cameraWB, bool autoWB, bool unpackPixels = true) {
        // open_file replaces LibRaw's datastream ownership flag before opening.
        // Explicitly close the previous stream first (Windows otherwise leaks a
        // file handle on camera/custom WB mode switches).
        rawProcessor_->recycle();
        sourceUnpacked_ = false;
        // recycle 不清警告位，Stage3 状态只能属于当前输入。
        rawProcessor_->imgdata.process_warnings &= ~LIBRAW_WARN_DNG_STAGE3_APPLIED;
#ifdef SONY2FUJI_ENABLE_DNGSDK
        constexpr unsigned dngOptions = LIBRAW_RAWOPTIONS_DNG_STAGE2 |
            LIBRAW_RAWOPTIONS_DNG_STAGE23_IFPRESENT_JPGJXL | LIBRAW_RAWOPTIONS_DNG_ALLOWSIZECHANGE;
        // recycle 不清 rawparams；普通 DNG 的识别不能继承上一张 JXL 的标志。
        rawProcessor_->imgdata.rawparams.options &= ~dngOptions;
        rawProcessor_->set_dng_host(nullptr);
#endif
        auto& params = rawProcessor_->imgdata.params;
        // 切换白平衡不能同时切换相机色矩阵，3 表示始终使用内嵌色彩数据。
        params.use_camera_matrix = 3;
        params.use_camera_wb = cameraWB ? 1 : 0;
        params.use_auto_wb = autoWB ? 1 : 0;
        const int openResult = openRawFile(*rawProcessor_, filepath_);
        if (openResult != LIBRAW_SUCCESS) return openResult;
        sdkStage3_ = false;
        if (!unpackPixels) return LIBRAW_SUCCESS;
#ifdef SONY2FUJI_ENABLE_DNGSDK
        // 仅 JPEG XL 使用 SDK，其他 RAW 保留现有解码和白平衡路径。
        const char* decoder = rawProcessor_->unpack_function_name();
        if (decoder && std::strcmp(decoder, "jxl_dng_load_raw_placeholder()") == 0) {
            // LibRaw 在 open_file 内根据 Stage2 决定 WB 校正，必须带正确标志重新识别。
            rawProcessor_->recycle();
            rawProcessor_->imgdata.rawparams.options |= dngOptions;
            const int jxlOpenResult = openRawFile(*rawProcessor_, filepath_);
            if (jxlOpenResult != LIBRAW_SUCCESS) return jxlOpenResult;
            if (!dngHost_) dngHost_ = std::make_unique<dng_host>();
            rawProcessor_->set_dng_host(dngHost_.get());
        }
#endif
        const int unpackResult = rawProcessor_->unpack();
        if (unpackResult != LIBRAW_SUCCESS) return unpackResult;
        sdkStage3_ = (rawProcessor_->imgdata.process_warnings & LIBRAW_WARN_DNG_STAGE3_APPLIED) != 0;
        // 部分解码器只记录损坏计数却返回成功，不能继续导出损坏的像素。
        if (rawProcessor_->error_count()!=0) return LIBRAW_DATA_ERROR;
        rawProcessor_->adjust_to_raw_inset_crop(3);
        sourceUnpacked_ = true;
        return LIBRAW_SUCCESS;
    }

    void snapshotCalibration() {
        const auto& data = rawProcessor_->imgdata;
        bayerSource_ = data.idata.colors == 3 && data.idata.filters > 1000 && !data.idata.is_foveon;
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
        snapshotBayerMetadata();
    }

    void snapshotBayerMetadata() {
        bayerMetadataReady_ = false; bayerMetadata_ = {};
        const auto& data = rawProcessor_->imgdata;
        if (!bayerSource_ || sdkStage3_ || fujiRotate_ || !data.rawdata.raw_image ||
            !std::isfinite(data.sizes.pixel_aspect) || std::abs(data.sizes.pixel_aspect - 1) > .005 ||
            width_ < 2 || height_ < 2 || uint64_t(width_) * height_ > 128000000 ||
            data.sizes.raw_pitch % sizeof(uint16_t) || data.sizes.raw_pitch / sizeof(uint16_t) < data.sizes.raw_width ||
            uint64_t(data.sizes.left_margin) + width_ > data.sizes.raw_width ||
            uint64_t(data.sizes.top_margin) + height_ > data.sizes.raw_height) return;
        double spatialBlack = 0;
        if (data.color.cblack[4] || data.color.cblack[5]) {
            const uint64_t count = uint64_t(data.color.cblack[4]) * data.color.cblack[5];
            if (!count || count > 4096 || !std::all_of(data.color.cblack + 6, data.color.cblack + 6 + count,
                    [&](unsigned value) { return value == data.color.cblack[6]; })) return;
            spatialBlack = data.color.cblack[6];
        }
        auto& source = bayerMetadata_;
        source.width = width_; source.height = height_; source.flip = data.sizes.flip;
        source.white = data.color.maximum; source.iso = data.other.iso_speed; source.shutterSeconds = data.other.shutter;
        source.cameraModel = data.idata.model; source.rawBits = data.color.raw_bps;
        source.sonyRawType = data.makernotes.sony.SonyRawFileType;
        for (int c = 0; c < 4; ++c) {
            source.pattern[c] = rawProcessor_->COLOR(c / 2, c % 2);
            source.black[c] = float(double(data.color.black) + data.color.cblack[c] + spatialBlack);
            if (!std::isfinite(source.black[c]) || source.black[c] < 0 || source.white <= source.black[c] || source.white > 65535) return;
            source.whiteBalance[c] = data.color.cam_mul[0] == 0 ? data.color.pre_mul[c] : data.color.cam_mul[c];
            bayerDaylightWB_[c] = data.color.pre_mul[c];
        }
        if (source.whiteBalance[3] == 0) source.whiteBalance[3] = source.whiteBalance[1];
        auto pattern = source.pattern; std::sort(pattern.begin(), pattern.end());
        if (pattern != std::array<int, 4>{0, 1, 2, 3}) return;
        for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) {
            source.cameraCalibration[row][col] = data.color.cam_xyz[row][col];
            source.cameraToSrgb[row][col] = data.color.rgb_cam[row][col];
        }
        bayerMetadataReady_ = true;
    }

    ErrorCode ensureIdentificationMode(bool cameraWB, bool autoWB) {
        if (sourceUnpacked_ && cameraWB == identificationCameraWB_ && autoWB == identificationAutoWB_)
            return ErrorCode::Success;
        const bool needsCalibration = !sourceUnpacked_;
        const int ret = openAndUnpack(cameraWB, autoWB);
        if (ret != LIBRAW_SUCCESS) {
            std::cerr << "无法重新加载 RAW 文件: " << libraw_strerror(ret) << std::endl;
            invalidateState();
            if (ret == LIBRAW_CANCELLED_BY_CALLBACK) throw ProcessingCancelled();
            return decodeError(ret);
        }
        identificationCameraWB_ = cameraWB;
        identificationAutoWB_ = autoWB;
        sourceReady_ = true;
        if (needsCalibration) snapshotCalibration();
        return ErrorCode::Success;
    }

    static ErrorCode decodeError(int ret) {
        if (ret == LIBRAW_FILE_UNSUPPORTED) return ErrorCode::InvalidFormat;
        if (ret == LIBRAW_IO_ERROR) return ErrorCode::FileNotFound;
        if (ret == LIBRAW_UNSUFFICIENT_MEMORY || ret == LIBRAW_MEMPOOL_OVERFLOW) return ErrorCode::OutOfMemory;
        return ErrorCode::ProcessingError;
    }

#ifdef SONY2FUJI_ENABLE_DNGSDK
    // LibRaw 的 SDK 图像释放依赖 host，host 必须比 LibRaw 活得更久。
    std::unique_ptr<dng_host> dngHost_;
#endif
    std::unique_ptr<LibRaw> rawProcessor_;
    std::unique_ptr<X3fProcessor> x3fProcessor_;
    bool displayReferred_ = false;
    std::string lastError_;
    std::string filepath_;
    std::string cameraMake_;
    std::string cameraModel_;
    std::unique_ptr<CameraWhiteBalance> whiteBalance_;
    std::array<std::array<float,3>,3> cameraColorMatrix_{};
    bool cameraColorMatrixValid_ = false;
    bool bayerSource_ = false;
    bool sourceReady_ = false;
    bool sourceUnpacked_ = false;
    bool identificationCameraWB_ = false;
    bool identificationAutoWB_ = false;
    bool fujiRotate_ = false;
    bool sdkStage3_ = false;
    LensCorrectionReport lensReport_;
    int width_ = 0;
    int height_ = 0;
    ColorSpace outputSpace_ = ColorSpace::sRGB;
    float previewExposureEV_ = 0;
    float baselineExposureEV_ = 0;
    float metadataExposureEV_ = 0;
    RAWBayerSource bayerMetadata_;
    std::array<float, 4> bayerDaylightWB_{};
    bool bayerMetadataReady_ = false;
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
ErrorCode RAWProcessor::loadFile(const std::string& filepath, X3fMode mode) {
    return pImpl_->loadFile(filepath, mode);
}

ErrorCode RAWProcessor::process(const RAWProcessOptions& options, ImageData& output) {
    return pImpl_->process(options, output);
}

bool RAWProcessor::isDisplayReferred() const { return pImpl_->isDisplayReferred(); }
const std::string& RAWProcessor::getLastError() const { return pImpl_->getLastError(); }

ErrorCode RAWProcessor::readBayerSource(const RAWProcessOptions& options, RAWBayerSource& output) {
    return pImpl_->readBayerSource(options, output);
}
bool RAWProcessor::getBayerMetadata(RAWBayerSource& output) const { return pImpl_->getBayerMetadata(output); }

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

ErrorCode RAWProcessor::readLensMetadata(const std::string& filepath, LensMetadata& metadata) {
    metadata = {};
    auto processor = std::make_unique<LibRaw>();
    const int result = openRawFile(*processor, filepath);
    if (result != LIBRAW_SUCCESS) return result == LIBRAW_IO_ERROR ? ErrorCode::FileNotFound : ErrorCode::InvalidFormat;
    metadata = lensMetadata(*processor);
    return ErrorCode::Success;
}

LensCorrectionReport RAWProcessor::getLensCorrectionReport() const { return pImpl_->getLensCorrectionReport(); }

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
        case OutputFormat::DNG:
            return saveRenderedDNG(image, filepath);
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
