#include "sony2fuji/raw_processor.h"
#include "sony2fuji/color_converter.h"
#include "sony2fuji/dcp_compiler.h"
#include "preview_exposure.h"
#include "photo_rendering.h"
#include "quantize_dither.h"
#include "white_balance.h"
#include "file_path.h"
#include "output_file_mode.h"
#include "parallel_pixels.h"
#include <libraw/libraw.h>
#include "x3f_processor.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <csetjmp>
#include <exception>
#include <iostream>
#include <memory>
#include <cstring>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <array>
#include <limits>
#include <new>
#include <system_error>
#include <spng.h>
#include <jpeglib.h>
#include <jerror.h>
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#else
#include <lcms2.h>
#endif
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOGDI
#define NOGDI
#endif
#include <windows.h>
#undef RGB
#undef near
#undef far
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#ifdef SONY2FUJI_ENABLE_DNGSDK
#include <dng_host.h>
#endif

#include "rendered_dng.h"

namespace sony2fuji {

namespace {
// Private LibRaw option used by the Sony DefaultCrop backport in patch-libraw.cmake.
constexpr unsigned kLegacySonyCrop = 1u << 31;

ErrorCode decodeError(int ret) {
    if (ret == LIBRAW_FILE_UNSUPPORTED) return ErrorCode::InvalidFormat;
    if (ret == LIBRAW_IO_ERROR) return ErrorCode::FileNotFound;
    if (ret == LIBRAW_UNSUFFICIENT_MEMORY || ret == LIBRAW_MEMPOOL_OVERFLOW) return ErrorCode::OutOfMemory;
    return ErrorCode::ProcessingError;
}

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
        const float blend = std::clamp(replacement->blend, 0.0f, 1.0f);
        if (blend <= 0.0f) return;
        original_ = raw.imgdata.rawdata.raw_image;
        pitch_ = raw.imgdata.sizes.raw_pitch / sizeof(uint16_t);
        left_ = raw.imgdata.sizes.left_margin; top_ = raw.imgdata.sizes.top_margin;
        width_ = source.width; height_ = source.height;
        backup_.resize(size_t(width_) * height_);
        for (int y = 0; y < height_; ++y)
            std::copy_n(original_ + (size_t(y) + top_) * pitch_ + left_, width_, backup_.data() + size_t(y) * width_);
        for (int y = 0; y < height_; ++y) for (int x = 0; x < width_; ++x) {
            const float black = source.black[source.pattern[(y % 2) * 2 + x % 2]];
            const float range = source.white - black;
            auto& pixel = original_[(size_t(y) + top_) * pitch_ + left_ + x];
            float value = std::clamp(replacement->normalizedMosaic[size_t(y) * width_ + x], 0.f, 1.f);
            if (blend < 1.0f) {
                const float signal = (pixel - black) / range;
                if (replacement->protectSensorHighlights) {
                    if (signal >= .9f) continue;
                    const float t = std::clamp((signal - .6f) / .3f, 0.f, 1.f);
                    value += t * t * (3.f - 2.f * t) * (signal - value);
                }
                value = signal + blend * (value - signal);
            } else if (replacement->protectSensorHighlights) {
                // 在白平衡和 LibRaw 高光混合前渐退，保留接近饱和的原始传感器值。
                const float signal = (pixel - black) / range;
                if (signal >= .9f) continue;
                const float t = std::clamp((signal - .6f) / .3f, 0.f, 1.f);
                value += t * t * (3.f - 2.f * t) * (signal - value);
            }
            pixel = uint16_t(std::lround(value * range + black));
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
    explicit Impl(bool legacySonyCrop) : rawProcessor_(std::make_unique<LibRaw>()) {
        if (legacySonyCrop) rawProcessor_->imgdata.rawparams.options |= kLegacySonyCrop;
    }

    ErrorCode loadFile(const std::string& filepath, X3fMode mode = X3fMode::Legacy, bool inspectOnly = false) {
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
        const bool metadataOnly = inspectOnly || (mode == X3fMode::Normal && hasX3fSignature(filepath));
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

    ErrorCode inspectFile(const std::string& filepath) {
        const auto status = loadFile(filepath, X3fMode::Legacy, true);
        if (status != ErrorCode::Success) return status;
        // Align getWidth/getHeight with unpacked active inset crop without decoding mosaic pixels.
        rawProcessor_->adjust_to_raw_inset_crop(3);
        snapshotCalibration();
        return ErrorCode::Success;
    }

    ErrorCode inspectCameraHDR(const std::string& filepath, int& width, int& height, uint64_t& sensorPixels) {
        const auto status = loadFile(filepath, X3fMode::Legacy, true);
        if (status != ErrorCode::Success) return status;
        auto& data = rawProcessor_->imgdata;
        const auto headerSizes = data.sizes;
        const auto rawSizes = data.rawdata.sizes;
        rawProcessor_->adjust_to_raw_inset_crop(3);
        const auto cropped = data.sizes;
        data.sizes = headerSizes;
        data.rawdata.sizes = rawSizes;
        const bool xTrans = data.idata.colors == 3 && data.idata.filters == 9;
        const auto* decoder = rawProcessor_->unpack_function_name();
        sensorPixels = uint64_t(data.sizes.raw_width) * data.sizes.raw_height;
        if ((!bayerSource_ && !xTrans) || !decoder ||
            std::strcmp(decoder, "jxl_dng_load_raw_placeholder()") == 0 ||
            fujiRotate_ || !std::isfinite(data.sizes.pixel_aspect) || std::abs(data.sizes.pixel_aspect - 1) > .005 ||
            cropped.width < 2 || cropped.height < 2 || !sensorPixels || sensorPixels > 128000000 ||
            uint64_t(cropped.width) * cropped.height > sensorPixels)
            return ErrorCode::InvalidFormat;
        const bool transpose = (data.sizes.flip & 4) != 0;
        width = transpose ? cropped.height : cropped.width;
        height = transpose ? cropped.width : cropped.height;
        cameraHDRInspected_ = true;
        return ErrorCode::Success;
    }

    bool supportsHDRCameraProfile(const HDRCameraProfile& profile) const {
        if (!cameraHDRInspected_) return false;
        const auto& data = rawProcessor_->imgdata;
        if (data.idata.dng_version) {
            // LibRaw exposes two individual calibrations. DNG 1.6 can carry a third.
            if (data.idata.dng_version >= 0x01060000) return false;
            const auto& levels = data.color.dng_levels;
            // LibRaw copies these values from the IFD without its parsedfields bits.
            if (!std::all_of(levels.analogbalance, levels.analogbalance + 3, [](float value) { return value == 1; }))
                return false;
            for (const auto& color : data.color.dng_color) {
                bool empty = true, identity = true;
                for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) {
                    const float coefficient = color.calibration[row][col];
                    empty &= coefficient == 0;
                    identity &= coefficient == (row == col ? 1 : 0);
                }
                if (!empty && !identity) return false;
            }
        }
        const std::string model = data.idata.dng_version ? data.color.UniqueCameraModel
            : std::string(data.idata.normalized_make) + ' ' + data.idata.normalized_model;
        const auto lower = [](char c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; };
        return std::equal(model.begin(), model.end(), profile.cameraModel.begin(), profile.cameraModel.end(),
                          [&](char a, char b) { return lower(a) == lower(b); });
    }

    ErrorCode unpackInspectedCameraHDR() {
        if (!cameraHDRInspected_ || sourceUnpacked_) return ErrorCode::InvalidFormat;
        RawCancellationScope cancellation(*rawProcessor_);
        const int result = unpackPixels();
        if (result != LIBRAW_SUCCESS) {
            invalidateState();
            if (result == LIBRAW_CANCELLED_BY_CALLBACK) throw ProcessingCancelled();
            return decodeError(result);
        }
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
        const auto* cameraProfile = options.hdrCameraProfile;
        if (cameraProfile && (!options.outputLinear || !supportsHDRCameraProfile(*cameraProfile)))
            return ErrorCode::InvalidFormat;
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
            lastAppliedWbValid_ = false;
            baselineExposureEV_ = previewExposureEV_ = 0;
            outputSpace_ = options.outputLinear && options.outputAdobe ? ColorSpace::AdobeRGB :
                (options.outputLinear && options.outputAces ? ColorSpace::ACES2065_1 : ColorSpace::sRGB);
            lensReport_ = {};
            return ErrorCode::Success;
        }
        const bool customWB = options.useCustomWhiteBalance || options.useTemperatureWhiteBalance;
        const bool cameraWB = options.useCameraWhiteBalance && !customWB && !options.useAutoWhiteBalance;
        const bool autoWB = options.useAutoWhiteBalance && !customWB;
        float multipliers[4];
        std::copy_n(options.customWhiteBalance, 4, multipliers);
        if (options.useTemperatureWhiteBalance &&
            (!whiteBalance_ || !whiteBalance_->multipliers(options.temperature, options.tint, multipliers,
                cameraProfile ? &cameraProfile->xyzToCamera : nullptr)))
            return ErrorCode::InvalidFormat;
        const auto* replacement = options.bayerOverride;
        if (replacement && (!bayerMetadataReady_ || options.halfSize || options.rawNoiseReduction != 0 || autoWB ||
            !std::isfinite(replacement->blend) || replacement->blend < 0.0f || replacement->blend > 1.0f ||
            replacement->width != bayerMetadata_.width || replacement->height != bayerMetadata_.height ||
            replacement->normalizedMosaic.size() != size_t(bayerMetadata_.width) * bayerMetadata_.height ||
            (!replacement->cameraCorrection.empty() && replacement->cameraCorrection.size() != replacement->normalizedMosaic.size()) ||
            !std::all_of(replacement->normalizedMosaic.begin(), replacement->normalizedMosaic.end(), [](float x) { return std::isfinite(x); }) ||
            !std::all_of(replacement->cameraCorrection.begin(), replacement->cameraCorrection.end(), [](const RGB& p) {
                return std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b);
            }))) return ErrorCode::InvalidFormat;

        int width = 0, height = 0, channels = 0;
        float green = 0.0f;
        const ErrorCode runResult = runDcrawProcess(options, cameraWB, autoWB, customWB, multipliers,
            options.halfSize, options.rawNoiseReduction, replacement, cameraProfile,
            width, height, channels, green);
        if (runResult != ErrorCode::Success) return runResult;

        struct ImageGuard {
            LibRaw* raw;
            ~ImageGuard() { raw->free_image(); }
        } imageGuard{rawProcessor_.get()};
        auto& data = rawProcessor_->imgdata;
        const float scale = 1.0f / (65535.0f * green);
        lastCalibrationValid_ = (channels == 3) && whiteBalance_ && whiteBalance_->available();
        if (lastCalibrationValid_) {
            for (int r = 0; r < 3; ++r) {
                for (int c = 0; c < 3; ++c) {
                    lastRgbCam_[r][c] = data.color.rgb_cam[r][c];
                }
                lastWbUsed_[r] = data.color.pre_mul[r] / green;
            }
        }

        float profileMatrix[3][4]{};
        const float (*cameraMatrix)[4] = data.color.rgb_cam;
        if (cameraProfile) {
            for (int row = 0; row < 3; ++row)
                std::copy(cameraProfile->balancedToSrgb[row].begin(), cameraProfile->balancedToSrgb[row].end(), profileMatrix[row]);
            cameraMatrix = profileMatrix;
        }
        snapshotLastAppliedColor(data, channels, green, cameraProfile != nullptr || replacement != nullptr);
        LensCorrectionTransform correction(options.lensDatabase, lensMetadata(*rawProcessor_, sdkStage3_),
            options.lensCorrection, width, height, channels);
        lensReport_ = correction.report();
        previewExposureEV_ = 0;
        baselineExposureEV_ = measureBaselineEV(width, height, channels, cameraMatrix, scale,
            correction, replacement, options, &previewExposureEV_);
        // User EV remains relative to a fixed per-file baseline, before the LUT.
        const float gain=std::exp2(baselineExposureEV_+options.exposure)*options.brightness;
        if (!std::isfinite(gain) || gain<=0) return ErrorCode::InvalidFormat;

        const int flip = data.sizes.flip;
        output.width = (flip & 4) ? height : width;
        output.height = (flip & 4) ? width : height;
        output.pixels.resize(static_cast<size_t>(output.width)*output.height);
        ColorSpace target = options.outputAdobe ? ColorSpace::AdobeRGB :
            (options.outputAces ? ColorSpace::ACES2065_1 : ColorSpace::sRGB);
        const auto matrix = ColorConverter::getConversionMatrix(ColorSpace::sRGB, target);
        outputSpace_ = options.outputLinear ? target : ColorSpace::sRGB;
        parallelRowRanges(output.height, output.width, [&](int firstRow, int lastRow) {
            std::vector<float> coordinates;
            if (correction.hasGeometry()) {
                coordinates.resize(static_cast<size_t>(output.width)*6);
            }
            for (int y = firstRow; y < lastRow; ++y) {
                if (correction.hasGeometry()) {
                    if (flip & 4) correction.map((flip & 1) ? width-1-y : y, 0, 1, height, coordinates.data());
                    else correction.map(0, (flip & 2) ? height-1-y : y, width, 1, coordinates.data());
                }
                for (int x=0;x<output.width;++x) {
                    int row=y, col=x;
                    if (flip & 4) std::swap(row,col);
                    if (flip & 2) row=height-1-row;
                    if (flip & 1) col=width-1-col;
                    const int mappedIndex = (flip & 4) ? row : col;
                    auto rgb=sampleProcessedRGB(data, width, height, channels, cameraMatrix, scale,
                        correction, replacement, row, col, coordinates.empty() ? nullptr : coordinates.data()+mappedIndex*6);
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
        });
        return ErrorCode::Success;
    }

    ErrorCode estimatePreviewExposure(const RAWProcessOptions& options, float& outBaselineEV) {
        RawCancellationScope cancellationScope(*rawProcessor_);
        outBaselineEV = 0.0f;
        if (filepath_.empty() || !sourceReady_) return ErrorCode::FileNotFound;
        if (options.bayerDemosaic != BayerDemosaicMethod::Legacy &&
            options.bayerDemosaic != BayerDemosaicMethod::VNG && options.bayerDemosaic != BayerDemosaicMethod::DHT)
            return ErrorCode::InvalidFormat;
        if (options.x3fMode != X3fMode::Legacy && options.x3fMode != X3fMode::Normal) return ErrorCode::InvalidFormat;
        const bool x3fSignature = options.x3fMode == X3fMode::Normal && hasX3fSignature(filepath_);
        if (options.x3fMode == X3fMode::Normal && !x3fSignature &&
            (rawProcessor_->imgdata.idata.is_foveon || hasX3fExtension(filepath_))) {
            lastError_ = "The X3F source does not contain a valid FOVb header";
            return ErrorCode::InvalidFormat;
        }
        if (x3fSignature) {
            outBaselineEV = 0.0f;
            return ErrorCode::Success;
        }

        int width = 0, height = 0, channels = 0;
        float green = 0.0f;
        const float unusedMul[4]{};
        const ErrorCode runResult = runDcrawProcess(options, /*cameraWB=*/true, /*autoWB=*/false, /*customWB=*/false,
            unusedMul, /*halfSize=*/bayerSource_ && options.rawNoiseReduction == 0, /*rawNoiseReduction=*/0,
            nullptr, nullptr, width, height, channels, green);
        if (runResult != ErrorCode::Success) return runResult;

        struct ImageGuard {
            LibRaw* raw;
            ~ImageGuard() { raw->free_image(); }
        } imageGuard{rawProcessor_.get()};
        const auto& data = rawProcessor_->imgdata;
        const float scale = 1.0f / (65535.0f * green);
        LensCorrectionTransform correction(options.lensDatabase, lensMetadata(*rawProcessor_, sdkStage3_),
            options.lensCorrection, width, height, channels);
        float previewEV = 0.0f;
        outBaselineEV = measureBaselineEV(width, height, channels, data.color.rgb_cam, scale,
            correction, nullptr, options, &previewEV);
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

    std::pair<int, int> getNativeOutputSize() const { return nativeOutputSize_; }

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

    bool getAsShotWhiteBalanceMultipliers(float multipliers[3]) const {
        if (displayReferred_ || !asShotWbValid_) return false;
        std::copy_n(asShotWbMul_.data(), 3, multipliers);
        return true;
    }

    bool computeTemperatureWhiteBalanceMultipliers(float temperature, float tint, float multipliers[3]) const {
        if (displayReferred_ || !whiteBalance_) return false;
        float mul[4]{};
        if (!whiteBalance_->multipliers(temperature, tint, mul)) return false;
        std::copy_n(mul, 3, multipliers);
        return true;
    }

    bool getLastAppliedWhiteBalanceMultipliers(float multipliers[3]) const {
        if (displayReferred_ || !lastAppliedWbValid_) return false;
        std::copy_n(lastAppliedWbMul_.data(), 3, multipliers);
        return true;
    }

    bool getCameraToSrgbMatrix(float matrix[3][3]) const {
        if (displayReferred_ || !cameraToSrgbValid_) return false;
        for (int row = 0; row < 3; ++row)
            for (int col = 0; col < 3; ++col)
                matrix[row][col] = cameraToSrgb_[row][col];
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

    bool getLastRgbCam(float matrix[3][3]) const {
        if (!lastCalibrationValid_) return false;
        for (int row = 0; row < 3; ++row) {
            for (int col = 0; col < 3; ++col) {
                matrix[row][col] = lastRgbCam_[row][col];
            }
        }
        return true;
    }

    bool getLastWbUsed(float multipliers[3]) const {
        if (!lastCalibrationValid_) return false;
        for (int c = 0; c < 3; ++c) {
            if (!std::isfinite(lastWbUsed_[c]) || lastWbUsed_[c] <= 0.0f) return false;
            multipliers[c] = lastWbUsed_[c];
        }
        return true;
    }

    bool getWhiteBalanceCalibration(
        double first[3][3],
        double second[3][3],
        double& firstTemperature,
        double& secondTemperature
    ) const {
        if (!whiteBalance_ || !whiteBalance_->available()) return false;
        std::array<std::array<double, 3>, 3> f{}, s{};
        whiteBalance_->calibrationData(f, s, firstTemperature, secondTemperature);
        for (int r = 0; r < 3; ++r) {
            for (int c = 0; c < 3; ++c) {
                first[r][c] = f[r][c];
                second[r][c] = s[r][c];
            }
        }
        return true;
    }

private:
    static bool validCameraToSrgb(const float matrix[3][3]) {
        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                if (!std::isfinite(matrix[r][c])) return false;
        const float det = matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1])
                        - matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0])
                        + matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
        return std::isfinite(det) && std::abs(det) >= 1e-10f;
    }

    static RGB sampleProcessedRGB(
        const libraw_data_t& data,
        int width,
        int height,
        int channels,
        const float (*cameraMatrix)[4],
        float scale,
        const LensCorrectionTransform& correction,
        const RAWBayerOverride* replacement,
        int row,
        int col,
        const float* coordinates
    ) {
        const auto& raw = data.image[static_cast<size_t>(row) * width + col];
        float rgb[3] = {};
        float camera[4];
        float lensGains[3] = {1, 1, 1};
        if (correction.report().appliedVignetting) {
            lensGains[0] = correction.gainAt(coordinates ? coordinates[0] : float(col), coordinates ? coordinates[1] : float(row));
            lensGains[1] = correction.report().appliedTCA ? correction.gainAt(coordinates[2], coordinates[3]) : lensGains[0];
            lensGains[2] = correction.report().appliedTCA ? correction.gainAt(coordinates[4], coordinates[5]) : lensGains[0];
        }
        for (int c = 0; c < channels; ++c) {
            const int mapped = c == 3 ? 1 : c;
            camera[c] = coordinates ? sampleCameraChannel(&data.image[0][0], width, height, c,
                coordinates[mapped * 2], coordinates[mapped * 2 + 1]) : raw[c];
            camera[c] *= lensGains[mapped];
        }
        for (int dst = 0; dst < 3; ++dst)
            for (int c = 0; c < channels; ++c)
                rgb[dst] += cameraMatrix[dst][c] * camera[c] * scale;
        const float bayerBlend = replacement ? std::clamp(replacement->blend, 0.0f, 1.0f) : 0.0f;
        if (replacement && !replacement->cameraCorrection.empty() && bayerBlend > 0.0f) {
            const auto& value = replacement->cameraCorrection[size_t(row) * width + col];
            for (int c = 0; c < 3; ++c) {
                float delta = coordinates ? sampleCameraCorrection(replacement->cameraCorrection, width, height, c,
                    coordinates[c * 2], coordinates[c * 2 + 1]) : c == 0 ? value.r : c == 1 ? value.g : value.b;
                if (bayerBlend < 1.0f) delta *= bayerBlend;
                if (delta != 0)
                    for (int dst = 0; dst < 3; ++dst)
                        rgb[dst] += cameraMatrix[dst][c] * delta * lensGains[c];
            }
        }
        return RGB(rgb[0], rgb[1], rgb[2]);
    }

    float measureBaselineEV(
        int width,
        int height,
        int channels,
        const float (*cameraMatrix)[4],
        float scale,
        const LensCorrectionTransform& correction,
        const RAWBayerOverride* replacement,
        const RAWProcessOptions& options,
        float* outPreviewEV
    ) {
        const auto& data = rawProcessor_->imgdata;
        float baseline = options.applyBaselineExposure ? sceneExposureEV(metadataExposureEV_) : 0;
        if (outPreviewEV) *outPreviewEV = 0;
        if (options.matchEmbeddedPreviewExposure) {
            auto* previewCache = currentPreviewExposureCache();
            auto preview = previewCache ? previewCache->getOrLoad(filepath_) : localPreviewCache_.getOrLoad(filepath_);
            if (!preview.empty()) {
                std::vector<float> luminance;
                luminance.reserve(128 * 128);
                alignas(16) float coordinates[6];
                for (int y = 0; y < 128; ++y) for (int x = 0; x < 128; ++x) {
                    const int row = (2 * y + 1) * height / 256;
                    const int col = (2 * x + 1) * width / 256;
                    if (correction.hasGeometry()) correction.map(col, row, 1, 1, coordinates);
                    const auto p = sampleProcessedRGB(data, width, height, channels, cameraMatrix, scale,
                        correction, replacement, row, col, correction.hasGeometry() ? coordinates : nullptr);
                    luminance.push_back(std::max(0.0f, .2126f * p.r + .7152f * p.g + .0722f * p.b));
                }
                bool matched = false;
                const float matchedEV = estimatePreviewExposureEV(std::move(luminance), std::move(preview), &matched);
                if (outPreviewEV) *outPreviewEV = matchedEV;
                if (matched) baseline = matchedEV;
            }
        }
        return baseline;
    }

    ErrorCode runDcrawProcess(
        const RAWProcessOptions& options,
        bool cameraWB,
        bool autoWB,
        bool customWB,
        const float multipliers[4],
        bool halfSize,
        int rawNoiseReduction,
        const RAWBayerOverride* replacement,
        const HDRCameraProfile* cameraProfile,
        int& outWidth,
        int& outHeight,
        int& outChannels,
        float& outGreen
    ) {
        auto& params = rawProcessor_->imgdata.params;
        // half_size skips the LibRaw interpolation stage that runs FBDD.
        params.half_size = halfSize && rawNoiseReduction == 0 ? 1 : 0;
        params.fbdd_noiserd = rawNoiseReduction;
        const ErrorCode identificationResult = ensureIdentificationMode(cameraWB, autoWB);
        if (identificationResult != ErrorCode::Success) return identificationResult;
        // 非 Bayer 必须重置，避免复用处理器时把 X-Trans 误送入 VNG。
        params.user_qual = bayerSource_ && options.bayerDemosaic != BayerDemosaicMethod::Legacy ?
            (options.bayerDemosaic == BayerDemosaicMethod::VNG ? 1 : 11) : -1;
        params.use_camera_matrix = 3;
        params.use_camera_wb = cameraWB ? 1 : 0;
        params.use_auto_wb = autoWB ? 1 : 0;
        for (int c = 0; c < 4; ++c) {
            const float value = c == 3 && multipliers[c] == 0 ? multipliers[1] : multipliers[c];
            if (customWB && (!std::isfinite(value) || value <= 0))
                return ErrorCode::InvalidFormat;
            params.user_mul[c] = customWB ? value : 0;
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
        BayerOverrideScope overrideScope(*rawProcessor_, bayerMetadata_, replacement);
        const int processed = rawProcessor_->dcraw_process();
        if (processed != LIBRAW_SUCCESS) {
            // Fatal LibRaw processing errors may recycle unpacked data internally.
            // Require a fresh load rather than advertising a reusable source.
            invalidateState();
            if (processed == LIBRAW_CANCELLED_BY_CALLBACK) throw ProcessingCancelled();
            if (processed == LIBRAW_UNSUFFICIENT_MEMORY || processed == LIBRAW_MEMPOOL_OVERFLOW)
                return ErrorCode::OutOfMemory;
            return ErrorCode::ProcessingError;
        }
        auto& data = rawProcessor_->imgdata;
        const int channels = data.idata.colors;
        if (channels != 3 && (channels != 4 || cameraProfile)) {
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
        const float green = data.color.pre_mul[1];
        if (!std::isfinite(green) || green <= 0) {
            rawProcessor_->free_image();
            return ErrorCode::ProcessingError;
        }
        outWidth = width;
        outHeight = height;
        outChannels = channels;
        outGreen = green;
        return ErrorCode::Success;
    }

    void snapshotLastAppliedColor(const libraw_data_t& data, int channels, float green, bool customOverride) {
        lastAppliedWbValid_ = false;
        cameraToSrgbValid_ = false;
        if (channels != 3 || customOverride || displayReferred_ || data.color.as_shot_wb_applied) return;
        float m[3][3]{};
        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                m[r][c] = data.color.rgb_cam[r][c];
        if (!validCameraToSrgb(m)) return;
        for (int c = 0; c < 3; ++c) {
            if (!std::isfinite(data.color.pre_mul[c]) || data.color.pre_mul[c] <= 0) return;
        }
        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                cameraToSrgb_[r][c] = m[r][c];
        cameraToSrgbValid_ = true;
        lastAppliedWbMul_ = {data.color.pre_mul[0] / green, 1.0f, data.color.pre_mul[2] / green};
        lastAppliedWbValid_ = true;
    }

    void invalidateState() {
        cameraHDRInspected_ = false;
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
        nativeOutputSize_ = {};
        cameraMake_.clear();
        cameraModel_.clear();
        whiteBalance_.reset();
        cameraColorMatrixValid_ = false;
        lastCalibrationValid_ = false;
        lastRgbCam_ = {};
        lastWbUsed_ = {1.0f, 1.0f, 1.0f};
        cameraToSrgbValid_ = false;
        cameraToSrgb_ = {};
        lastAppliedWbValid_ = false;
        lastAppliedWbMul_ = {1.0f, 1.0f, 1.0f};
        asShotWbValid_ = false;
        asShotWbMul_ = {1.0f, 1.0f, 1.0f};
        bayerSource_ = false;
        previewExposureEV_ = 0;
        baselineExposureEV_ = 0;
        metadataExposureEV_ = 0;
        fujiRotate_ = false;
        sdkStage3_ = false;
        jxlDng_ = false;
        lensReport_ = {};
        outputSpace_ = ColorSpace::sRGB;
        bayerMetadata_ = {}; bayerMetadataReady_ = false; bayerDaylightWB_ = {};
    }

    int openAndUnpack(bool cameraWB, bool autoWB, bool unpack = true) {
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
        jxlDng_ = false;
        if (!unpack) return LIBRAW_SUCCESS;
#ifdef SONY2FUJI_ENABLE_DNGSDK
        // 仅 JPEG XL 使用 SDK，其他 RAW 保留现有解码和白平衡路径。
        const char* decoder = rawProcessor_->unpack_function_name();
        if (decoder && std::strcmp(decoder, "jxl_dng_load_raw_placeholder()") == 0) {
            jxlDng_ = true;
            // LibRaw 在 open_file 内根据 Stage2 决定 WB 校正，必须带正确标志重新识别。
            rawProcessor_->recycle();
            rawProcessor_->imgdata.rawparams.options |= dngOptions;
            const int jxlOpenResult = openRawFile(*rawProcessor_, filepath_);
            if (jxlOpenResult != LIBRAW_SUCCESS) return jxlOpenResult;
            if (!dngHost_) dngHost_ = std::make_unique<dng_host>();
            rawProcessor_->set_dng_host(dngHost_.get());
        }
#endif
        return unpackPixels();
    }

    int unpackPixels() {
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
        // Save the oriented canvas while LibRaw still has the full-resolution source geometry.
        int channels = 0, bits = 0;
        rawProcessor_->get_mem_image_format(&nativeOutputSize_.first, &nativeOutputSize_.second, &channels, &bits);
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
        float camSrgb[3][3]{};
        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                camSrgb[r][c] = data.color.rgb_cam[r][c];
        cameraToSrgbValid_ = data.idata.colors == 3 && validCameraToSrgb(camSrgb);
        if (cameraToSrgbValid_) {
            for (int r = 0; r < 3; ++r)
                for (int c = 0; c < 3; ++c)
                    cameraToSrgb_[r][c] = camSrgb[r][c];
        }
        asShotWbValid_ = data.idata.colors == 3 && !data.color.as_shot_wb_applied &&
            std::isfinite(data.color.cam_mul[0]) && data.color.cam_mul[0] > 0 &&
            std::isfinite(data.color.cam_mul[1]) && data.color.cam_mul[1] > 0 &&
            std::isfinite(data.color.cam_mul[2]) && data.color.cam_mul[2] > 0;
        if (asShotWbValid_) {
            const float g = data.color.cam_mul[1];
            asShotWbMul_ = {data.color.cam_mul[0] / g, 1.0f, data.color.cam_mul[2] / g};
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
        // LibRaw only alters identification state on use_camera_wb for 4-color CatchLight metadata;
        // retain WB-mode re-identification for 4-color and JPEG XL SDK paths, while 3-color RAWs
        // reuse their unpacked mosaic directly across Camera/Auto/Custom/Temperature WB switches.
        const bool needsWbReidentify = (rawProcessor_->imgdata.idata.colors == 4 && cameraWB != identificationCameraWB_) ||
            (jxlDng_ && (cameraWB != identificationCameraWB_ || autoWB != identificationAutoWB_));
        if (sourceUnpacked_ && !needsWbReidentify)
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

#ifdef SONY2FUJI_ENABLE_DNGSDK
    // LibRaw 的 SDK 图像释放依赖 host，host 必须比 LibRaw 活得更久。
    std::unique_ptr<dng_host> dngHost_;
#endif
    std::unique_ptr<LibRaw> rawProcessor_;
    std::unique_ptr<X3fProcessor> x3fProcessor_;
    PreviewExposureCache localPreviewCache_;
    bool displayReferred_ = false;
    std::string lastError_;
    std::string filepath_;
    std::string cameraMake_;
    std::string cameraModel_;
    std::unique_ptr<CameraWhiteBalance> whiteBalance_;
    std::array<std::array<float,3>,3> cameraColorMatrix_{};
    bool cameraColorMatrixValid_ = false;
    std::array<std::array<float,3>,3> lastRgbCam_{};
    std::array<float,3> lastWbUsed_{1.0f, 1.0f, 1.0f};
    bool lastCalibrationValid_ = false;
    std::array<std::array<float,3>,3> cameraToSrgb_{};
    bool cameraToSrgbValid_ = false;
    std::array<float, 3> lastAppliedWbMul_{1.0f, 1.0f, 1.0f};
    bool lastAppliedWbValid_ = false;
    std::array<float, 3> asShotWbMul_{1.0f, 1.0f, 1.0f};
    bool asShotWbValid_ = false;
    bool bayerSource_ = false;
    bool sourceReady_ = false;
    bool cameraHDRInspected_ = false;
    bool sourceUnpacked_ = false;
    bool identificationCameraWB_ = false;
    bool identificationAutoWB_ = false;
    bool fujiRotate_ = false;
    bool sdkStage3_ = false;
    bool jxlDng_ = false;
    LensCorrectionReport lensReport_;
    int width_ = 0;
    int height_ = 0;
    std::pair<int, int> nativeOutputSize_{};
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

RAWProcessor::RAWProcessor() : RAWProcessor(false) {}
RAWProcessor::RAWProcessor(bool legacySonyCrop) : pImpl_(std::make_unique<Impl>(legacySonyCrop)) {}

RAWProcessor::~RAWProcessor() = default;

ErrorCode RAWProcessor::loadFile(const std::string& filepath) {
    return pImpl_->loadFile(filepath);
}
ErrorCode RAWProcessor::loadFile(const std::string& filepath, X3fMode mode) {
    return pImpl_->loadFile(filepath, mode);
}

ErrorCode RAWProcessor::inspectFile(const std::string& filepath) {
    return pImpl_->inspectFile(filepath);
}

ProbeSizeResult RAWProcessor::probeOutputSize(const std::string& filepath, bool legacySonyCrop,
                                              uint32_t& width, uint32_t& height, X3fMode x3fMode) {
    width = 0;
    height = 0;
    if (filepath.empty() || filepath.find('\0') != std::string::npos) return ProbeSizeResult::OpenFailed;
    auto canOpenInput = [&]() -> bool {
#ifdef _WIN32
        std::ifstream testStream(std::filesystem::u8path(filepath), std::ios::binary);
#else
        std::ifstream testStream(filepath, std::ios::binary);
#endif
        return static_cast<bool>(testStream);
    };
    if (!canOpenInput()) return ProbeSizeResult::OpenFailed;
    // Normal X3F uses x3f-bridge CAMF KeepImageArea, which differs from LibRaw foveon_data.
    if (x3fMode == X3fMode::Normal && hasX3fSignature(filepath)) {
        return ProbeSizeResult::DeferredPostDecode;
    }
    auto raw = std::make_unique<LibRaw>();
    if (legacySonyCrop) raw->imgdata.rawparams.options |= kLegacySonyCrop;
    RawCancellationScope cancellation(*raw);
    const int status = openRawFile(*raw, filepath);
    if (status == LIBRAW_CANCELLED_BY_CALLBACK) throw ProcessingCancelled();
    if (status != LIBRAW_SUCCESS) {
        return (status == LIBRAW_IO_ERROR && !canOpenInput())
            ? ProbeSizeResult::OpenFailed
            : ProbeSizeResult::Unsupported;
    }
    const char* decoder = raw->unpack_function_name();
    // JPEG XL DNG applies ActiveArea/DefaultUserCrop/Stage3 opcodes during DNG SDK unpack; verify post-decode.
    if (decoder && std::strcmp(decoder, "jxl_dng_load_raw_placeholder()") == 0) {
        return ProbeSizeResult::DeferredPostDecode;
    }
    raw->adjust_to_raw_inset_crop(3);
    int outWidth = 0, outHeight = 0, colors = 0, bps = 0;
    raw->get_mem_image_format(&outWidth, &outHeight, &colors, &bps);
    if (outWidth <= 0 || outHeight <= 0) return ProbeSizeResult::DeferredPostDecode;
    width = static_cast<uint32_t>(outWidth);
    height = static_cast<uint32_t>(outHeight);
    return ProbeSizeResult::Probed;
}

ErrorCode RAWProcessor::sonyFramingChanged(const std::string& filepath, bool& changed) {
    changed = false;
    auto raw = std::make_unique<LibRaw>();
    RawCancellationScope cancellation(*raw);
    auto open = [&] {
        const int status = openRawFile(*raw, filepath);
        if (status == LIBRAW_CANCELLED_BY_CALLBACK) throw ProcessingCancelled();
        return status;
    };
    auto status = open();
    if (status != LIBRAW_SUCCESS) return decodeError(status);
    if (raw->imgdata.idata.dng_version || raw->imgdata.idata.maker_index != LIBRAW_CAMERAMAKER_Sony)
        return ErrorCode::Success;
    auto inset = [&] {
        raw->adjust_to_raw_inset_crop(3);
        const auto& sizes = raw->imgdata.sizes;
        return std::array{sizes.left_margin, sizes.top_margin, sizes.width, sizes.height};
    };
    const auto full = inset();
    raw->recycle();
    raw->imgdata.rawparams.options |= kLegacySonyCrop;
    status = open();
    if (status != LIBRAW_SUCCESS) return decodeError(status);
    changed = full != inset();
    return ErrorCode::Success;
}

ErrorCode RAWProcessor::inspectCameraHDR(const std::string& filepath, int& width, int& height, uint64_t& sensorPixels) {
    return pImpl_->inspectCameraHDR(filepath, width, height, sensorPixels);
}

bool RAWProcessor::supportsHDRCameraProfile(const HDRCameraProfile& profile) const {
    return pImpl_->supportsHDRCameraProfile(profile);
}

ErrorCode RAWProcessor::unpackInspectedCameraHDR() {
    return pImpl_->unpackInspectedCameraHDR();
}

ErrorCode RAWProcessor::process(const RAWProcessOptions& options, ImageData& output) {
    return pImpl_->process(options, output);
}

ErrorCode RAWProcessor::estimatePreviewExposure(const RAWProcessOptions& options, float& outBaselineEV) {
    return pImpl_->estimatePreviewExposure(options, outBaselineEV);
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

std::pair<int, int> RAWProcessor::getNativeOutputSize() const { return pImpl_->getNativeOutputSize(); }

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

bool RAWProcessor::getAsShotWhiteBalanceMultipliers(float multipliers[3]) const {
    return pImpl_->getAsShotWhiteBalanceMultipliers(multipliers);
}

bool RAWProcessor::computeTemperatureWhiteBalanceMultipliers(float temperature, float tint, float multipliers[3]) const {
    return pImpl_->computeTemperatureWhiteBalanceMultipliers(temperature, tint, multipliers);
}

bool RAWProcessor::getLastAppliedWhiteBalanceMultipliers(float multipliers[3]) const {
    return pImpl_->getLastAppliedWhiteBalanceMultipliers(multipliers);
}

bool RAWProcessor::getCameraToSrgbMatrix(float matrix[3][3]) const {
    return pImpl_->getCameraToSrgbMatrix(matrix);
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

bool RAWProcessor::getLastRgbCam(float matrix[3][3]) const {
    return pImpl_->getLastRgbCam(matrix);
}

bool RAWProcessor::getLastWbUsed(float multipliers[3]) const {
    return pImpl_->getLastWbUsed(multipliers);
}

bool RAWProcessor::getWhiteBalanceCalibration(
    double first[3][3],
    double second[3][3],
    double& firstTemperature,
    double& secondTemperature
) const {
    return pImpl_->getWhiteBalanceCalibration(first, second, firstTemperature, secondTemperature);
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

namespace {

void removeStagingPathNoThrow(const std::filesystem::path& path) noexcept {
    if (path.empty()) return;
    std::error_code error;
    std::filesystem::remove(path, error);
}

// 编码结果先写入目标目录内的临时文件，最后一次原子替换发布。这样取消或失败都不会
// 破坏目标位置已有的文件，也不会留下半成品。
class EncodedStagingFile final {
public:
    enum class Kind { Jpeg, Png };

    explicit EncodedStagingFile(Kind kind) : kind_(kind) {}
    EncodedStagingFile(const EncodedStagingFile&) = delete;
    EncodedStagingFile& operator=(const EncodedStagingFile&) = delete;

    ~EncodedStagingFile() { cleanup(); }

    bool create(const std::filesystem::path& destination) {
#ifdef _WIN32
        // Mirror of the POSIX branch below: CREATE_NEW (_wopen O_EXCL) with a bounded
        // retry. A collided name is never opened or deleted by us (foreign-name
        // protection); GetTempFileNameW could return an already-existing name and
        // the CRT "wb" open would truncate it. NTFS permissions follow the target
        // directory's ACL inheritance, so this platform has no destination-mode copy.
        std::wstring temporaryName;
        int createdFd = -1;
        try {
            std::filesystem::path parent = destination.parent_path();
            if (parent.empty()) parent = L".";
            const std::wstring base = kind_ == Kind::Jpeg ? L".rawlab-jpeg" : L".rawlab-png";
            for (int attempt = 0; attempt < 64 && createdFd < 0; ++attempt) {
                const std::string suffix = stagingSuffix();
                temporaryName = (parent / (base + L"-" + std::wstring(suffix.begin(), suffix.end()) + L".tmp")).wstring();
                createdFd = ::_wopen(
                    temporaryName.c_str(),
                    _O_CREAT | _O_EXCL | _O_WRONLY | _O_BINARY | _O_NOINHERIT,
                    _S_IREAD | _S_IWRITE);
                if (createdFd < 0) {
                    if (errno != EEXIST) return false;
                    temporaryName.clear(); // the name belongs to someone else; never delete it
                }
            }
            if (createdFd < 0) return false;

            path_ = std::filesystem::path(temporaryName);
            file_ = ::_fdopen(createdFd, "wb");
            if (!file_) {
                (void)::_close(createdFd);
                createdFd = -1;
                cleanup();
                return false;
            }
            createdFd = -1; // file_ owns the descriptor after _fdopen succeeds.
            return true;
        } catch (...) {
            if (createdFd >= 0) (void)::_close(createdFd);
            cleanup();
            if (!temporaryName.empty()) DeleteFileW(temporaryName.c_str());
            throw;
        }
#else
        std::string temporaryName;
        int createdFd = -1;
        try {
            std::filesystem::path parent = destination.parent_path();
            if (parent.empty()) parent = ".";
            const std::string base = kind_ == Kind::Jpeg ? ".rawlab-jpeg" : ".rawlab-png";
            for (int attempt = 0; attempt < 64 && createdFd < 0; ++attempt) {
                temporaryName = (parent / (base + "-" + stagingSuffix() + ".tmp")).string();
                createdFd = ::open(temporaryName.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0666);
                if (createdFd < 0) {
                    if (errno != EEXIST) return false;
                    temporaryName.clear(); // the name belongs to someone else; never unlink it
                }
            }
            if (createdFd < 0) return false;
            preserveDestinationMode(createdFd, destination);

            path_ = std::filesystem::path(temporaryName);
            file_ = ::fdopen(createdFd, "wb");
            if (!file_) {
                (void)::close(createdFd);
                createdFd = -1;
                cleanup();
                return false;
            }
            createdFd = -1; // file_ owns the descriptor after fdopen succeeds.
            return true;
        } catch (...) {
            if (createdFd >= 0) (void)::close(createdFd);
            cleanup();
            if (!temporaryName.empty()) (void)::unlink(temporaryName.c_str());
            throw;
        }
#endif
    }

    std::FILE* file() const noexcept { return file_; }

    bool finishAndPublish(const std::filesystem::path& destination) {
        if (!file_) return false;
        const bool flushed = (std::fflush(file_) == 0) && (std::ferror(file_) == 0);
        const bool closed = (std::fclose(file_) == 0);
        file_ = nullptr;
        if (!flushed || !closed) {
            cleanup();
            return false;
        }
#ifdef _WIN32
        const std::wstring source = path_.wstring();
        const std::wstring target = destination.wstring();
        const bool published = MoveFileExW(
            source.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
        const bool published = (::rename(path_.c_str(), destination.c_str()) == 0);
#endif
        if (!published) {
            cleanup();
            return false;
        }
        published_ = true;
        path_.clear();
        return true;
    }

private:
    void cleanup() noexcept {
        if (file_) {
            (void)std::fclose(file_);
            file_ = nullptr;
        }
        if (!published_) {
            removeStagingPathNoThrow(path_);
        }
        path_.clear();
    }

    Kind kind_ = Kind::Jpeg;
    std::filesystem::path path_;
    std::FILE* file_ = nullptr;
    bool published_ = false;
};

const std::vector<uint8_t>& srgbIccProfileBytes() {
    static const std::vector<uint8_t> cached = []() -> std::vector<uint8_t> {
#if defined(__APPLE__)
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        if (!space) return {};
        CFDataRef data = CGColorSpaceCopyICCData(space);
        CGColorSpaceRelease(space);
        if (!data) return {};
        const CFIndex len = CFDataGetLength(data);
        const UInt8* ptr = CFDataGetBytePtr(data);
        std::vector<uint8_t> bytes;
        if (ptr && len > 0) {
            bytes.assign(ptr, ptr + len);
        }
        CFRelease(data);
        return bytes;
#else
        cmsHPROFILE profile = cmsCreate_sRGBProfile();
        if (!profile) return {};
        cmsUInt32Number size = 0;
        std::vector<uint8_t> bytes;
        if (cmsSaveProfileToMem(profile, nullptr, &size) && size > 0) {
            bytes.resize(size);
            if (!cmsSaveProfileToMem(profile, bytes.data(), &size)) {
                bytes.clear();
            }
        }
        cmsCloseProfile(profile);
        return bytes;
#endif
    }();
    return cached;
}

// libjpeg-turbo 扫描线编码器：写入 EncodedStagingFile 的暂存 FILE（stdio 目标管理器），
// 取消信号在扫描线边界即时中止（ProcessingCancelled 沿栈展开，析构删 .tmp），
// ERREXIT 经 setjmp 分类为 IO/内存/处理错误；流式写出，无整帧偏移量索引。
struct TurboJpegEncoder {
    jpeg_compress_struct codec{};
    jpeg_error_mgr manager{};
    std::jmp_buf jump{};
    std::FILE* file = nullptr;
    bool outOfMemory = false;

    explicit TurboJpegEncoder(std::FILE* destination) : file(destination) {}
    ~TurboJpegEncoder() { jpeg_destroy_compress(&codec); }

    static void fail(j_common_ptr codec) {
        auto* self = reinterpret_cast<TurboJpegEncoder*>(
            reinterpret_cast<char*>(codec->err) - offsetof(TurboJpegEncoder, manager));
        self->outOfMemory = codec->err->msg_code == JERR_OUT_OF_MEMORY;
        std::longjmp(self->jump, 1);
    }

    // 返回 false 表示 libjpeg 报错：按 outOfMemory 或 FILE 错误位分类。
    bool encode(int width, int height, const uint8_t* data, int quality) {
        const auto& icc = srgbIccProfileBytes();
        if (icc.empty()) return false;
        codec.err = jpeg_std_error(&manager);
        manager.error_exit = &TurboJpegEncoder::fail;
        if (setjmp(jump) != 0) return false;
        jpeg_create_compress(&codec);
        jpeg_stdio_dest(&codec, file);
        codec.image_width = static_cast<JDIMENSION>(width);
        codec.image_height = static_cast<JDIMENSION>(height);
        codec.input_components = 3;
        codec.in_color_space = JCS_RGB;
        jpeg_set_defaults(&codec);
        const int effectiveQuality = std::clamp(quality, 1, 100);
        // 基线表，与旧 stb 写出同语义。
        jpeg_set_quality(&codec, effectiveQuality, TRUE);
        // stb 参考语义：q<=90 用 4:2:0，q>90 用 4:4:4；对齐采样因子，
        // 避免高质量导出的色彩细节相对旧管线回退。
        const bool subsample = effectiveQuality <= 90;
        codec.comp_info[0].h_samp_factor = subsample ? 2 : 1;
        codec.comp_info[0].v_samp_factor = subsample ? 2 : 1;
        for (int component = 1; component < codec.num_components; ++component) {
            codec.comp_info[component].h_samp_factor = 1;
            codec.comp_info[component].v_samp_factor = 1;
        }
        jpeg_start_compress(&codec, TRUE);
        jpeg_write_icc_profile(&codec, icc.data(), static_cast<unsigned int>(icc.size()));
        // 行首指针用 size_t 步长：>2GiB 输入缓冲（约 715.8MP 上限 × 3B）无 int 溢出。
        const size_t rowBytes = static_cast<size_t>(width) * 3u;
        while (codec.next_scanline < static_cast<JDIMENSION>(height)) {
            checkProcessingCancellation();
            JSAMPROW row = const_cast<JSAMPLE*>(data) + static_cast<size_t>(codec.next_scanline) * rowBytes;
            jpeg_write_scanlines(&codec, &row, 1);
        }
        jpeg_finish_compress(&codec);
        return true;
    }
};

} // namespace
static_assert(JPEG_MAX_DIMENSION == 65500, "libjpeg-turbo dimension ceiling matches SDR JPEG contract");
ErrorCode ImageEncoder::saveJPEG(
    const ImageData& image,
    const std::string& filepath,
    int quality
) {
    if (filepath.empty() || filepath.find('\0') != std::string::npos ||
        image.width <= 0 || image.height <= 0 ||
        image.width > 65500 || image.height > 65500 ||
        image.pixels.empty() ||
        image.pixels.size() != static_cast<size_t>(image.width) * static_cast<size_t>(image.height)) {
        return ErrorCode::ProcessingError;
    }

    const uint64_t rgbBytes =
        static_cast<uint64_t>(image.width) * static_cast<uint64_t>(image.height) * 3u;
    if (rgbBytes > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
        return ErrorCode::ProcessingError;
    }

    std::filesystem::path destination;
    try {
#ifdef _WIN32
        destination = std::filesystem::u8path(filepath);
#else
        destination = std::filesystem::path(filepath);
#endif
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        return ErrorCode::IOError;
    }

    std::error_code directoryError;
    if (!destination.has_filename() || std::filesystem::is_directory(destination, directoryError)) {
        std::cerr << "保存 JPEG 失败: " << filepath << std::endl;
        return ErrorCode::IOError;
    }

    try {
        const size_t pixelCount =
            static_cast<size_t>(image.width) * static_cast<size_t>(image.height);
        std::vector<uint8_t> data(pixelCount * 3);

        parallelRowRanges(image.height, image.width, [&](int firstRow, int lastRow) {
            for (int y = firstRow; y < lastRow; ++y) {
                const size_t rowBase = static_cast<size_t>(y) * static_cast<size_t>(image.width);
                for (int x = 0; x < image.width; ++x) {
                    const size_t index = rowBase + static_cast<size_t>(x);
                    const auto& pixel = image.pixels[index];
                    data[index * 3 + 0] = quantizeFloatToUint8Dithered(pixel.r, static_cast<uint32_t>(x), static_cast<uint32_t>(y));
                    data[index * 3 + 1] = quantizeFloatToUint8Dithered(pixel.g, static_cast<uint32_t>(x), static_cast<uint32_t>(y));
                    data[index * 3 + 2] = quantizeFloatToUint8Dithered(pixel.b, static_cast<uint32_t>(x), static_cast<uint32_t>(y));
                }
            }
        });

        EncodedStagingFile staging(EncodedStagingFile::Kind::Jpeg);
        if (!staging.create(destination)) {
            std::cerr << "保存 JPEG 失败: " << filepath << std::endl;
            return ErrorCode::IOError;
        }

        TurboJpegEncoder encoder(staging.file());
        if (!encoder.encode(image.width, image.height, data.data(), quality)) {
            std::cerr << "保存 JPEG 失败: " << filepath << std::endl;
            if (encoder.outOfMemory) return ErrorCode::OutOfMemory;
            return std::ferror(staging.file()) != 0 ? ErrorCode::IOError : ErrorCode::ProcessingError;
        }
        // 提交点：编码完成后、替换目标文件之前再看一次取消。
        checkProcessingCancellation();
        if (!staging.finishAndPublish(destination)) {
            std::cerr << "保存 JPEG 失败: " << filepath << std::endl;
            return ErrorCode::IOError;
        }
    } catch (const ProcessingCancelled&) {
        throw;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        std::cerr << "保存 JPEG 失败: " << filepath << std::endl;
        return ErrorCode::IOError;
    }

    std::cout << "成功保存: " << filepath << std::endl;
    return ErrorCode::Success;
}

ErrorCode ImageEncoder::savePNG(
    const ImageData& image,
    const std::string& filepath,
    const PngMetadata* metadata
) {
    if (filepath.empty() || filepath.find('\0') != std::string::npos ||
        image.width <= 0 || image.height <= 0 ||
        image.pixels.size() != static_cast<size_t>(image.width) * static_cast<size_t>(image.height)) {
        return ErrorCode::ProcessingError;
    }

    const uint64_t rowBytes64 = static_cast<uint64_t>(image.width) * 3u * sizeof(uint16_t);
    if (rowBytes64 > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
        return ErrorCode::OutOfMemory;
    }

    std::filesystem::path destination;
    try {
#ifdef _WIN32
        destination = std::filesystem::u8path(filepath);
#else
        destination = std::filesystem::path(filepath);
#endif
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        return ErrorCode::IOError;
    }
    std::error_code directoryError;
    if (!destination.has_filename() || std::filesystem::is_directory(destination, directoryError)) {
        return ErrorCode::IOError;
    }

    try {
        EncodedStagingFile staging(EncodedStagingFile::Kind::Png);
        if (!staging.create(destination)) return ErrorCode::IOError;

        struct SpngEncoderGuard {
            spng_ctx* ctx = nullptr;
            explicit SpngEncoderGuard(spng_ctx* c) : ctx(c) {}
            ~SpngEncoderGuard() {
                if (ctx) spng_ctx_free(ctx);
            }
        };
        spng_ctx* ctx = spng_ctx_new(SPNG_CTX_ENCODER);
        if (!ctx) return ErrorCode::OutOfMemory;
        SpngEncoderGuard ctxGuard(ctx);

        auto mapSpngError = [&](int err) -> ErrorCode {
            if (std::ferror(staging.file()) != 0) return ErrorCode::IOError;
            if (err == SPNG_EMEM) return ErrorCode::OutOfMemory;
            return ErrorCode::ProcessingError;
        };

        if (int err = spng_set_png_file(ctx, staging.file()); err != 0) {
            return mapSpngError(err);
        }

        spng_ihdr ihdr{};
        ihdr.width = static_cast<uint32_t>(image.width);
        ihdr.height = static_cast<uint32_t>(image.height);
        ihdr.bit_depth = 16;
        ihdr.color_type = SPNG_COLOR_TYPE_TRUECOLOR;
        if (int err = spng_set_ihdr(ctx, &ihdr); err != 0) {
            return mapSpngError(err);
        }

        if (int err = spng_set_option(ctx, SPNG_FILTER_CHOICE, SPNG_FILTER_CHOICE_ALL); err != 0) {
            return mapSpngError(err);
        }

        if (metadata && !metadata->iccProfile.empty()) {
            spng_iccp iccp{};
            const std::string& profileName =
                metadata->iccProfileName.empty() ? std::string("ICC Profile") : metadata->iccProfileName;
            const size_t nameLen = std::min<size_t>(profileName.size(), sizeof(iccp.profile_name) - 1);
            std::memcpy(iccp.profile_name, profileName.data(), nameLen);
            iccp.profile_name[nameLen] = '\0';
            iccp.profile_len = metadata->iccProfile.size();
            iccp.profile = reinterpret_cast<char*>(const_cast<uint8_t*>(metadata->iccProfile.data()));
            if (int err = spng_set_iccp(ctx, &iccp); err != 0) {
                return mapSpngError(err);
            }
        } else {
            if (int err = spng_set_srgb(ctx, 0); err != 0) {
                return mapSpngError(err);
            }
        }

        if (metadata && !metadata->exif.empty()) {
            spng_exif exif{};
            exif.length = metadata->exif.size();
            exif.data = reinterpret_cast<char*>(const_cast<uint8_t*>(metadata->exif.data()));
            if (int err = spng_set_exif(ctx, &exif); err != 0) {
                return mapSpngError(err);
            }
        }

        if (int err = spng_encode_image(
                ctx, nullptr, 0, SPNG_FMT_PNG, SPNG_ENCODE_PROGRESSIVE | SPNG_ENCODE_FINALIZE);
            err != 0) {
            return mapSpngError(err);
        }

        std::vector<uint16_t> row(static_cast<size_t>(image.width) * 3u);
        const size_t rowBytes = static_cast<size_t>(rowBytes64);
        constexpr size_t kCancelCheckPixels = 65536;
        size_t pixelsSinceCheck = 0;
        for (int y = 0; y < image.height; ++y) {
            pixelsSinceCheck += static_cast<size_t>(image.width);
            if (pixelsSinceCheck >= kCancelCheckPixels) {
                pixelsSinceCheck = 0;
                checkProcessingCancellation();
            }
            for (int x = 0; x < image.width; ++x) {
                const auto& p = image.at(x, y);
                const size_t base = static_cast<size_t>(x) * 3u;
                row[base + 0] = floatToUint16(p.r);
                row[base + 1] = floatToUint16(p.g);
                row[base + 2] = floatToUint16(p.b);
            }
            const int err = spng_encode_row(ctx, row.data(), rowBytes);
            const bool lastRow = (y == image.height - 1);
            const bool rowOk = lastRow ? (err == SPNG_EOI || err == 0) : (err == 0);
            if (!rowOk) {
                return mapSpngError(err);
            }
        }

        if (std::fflush(staging.file()) != 0 || std::ferror(staging.file()) != 0) {
            return ErrorCode::IOError;
        }
        // 提交点：编码完成后、替换目标文件之前再看一次取消。
        checkProcessingCancellation();
        if (!staging.finishAndPublish(destination)) return ErrorCode::IOError;
    } catch (const ProcessingCancelled&) {
        throw;
    } catch (const std::bad_alloc&) {
        return ErrorCode::OutOfMemory;
    } catch (...) {
        return ErrorCode::IOError;
    }

    return ErrorCode::Success;
}

} // namespace sony2fuji
