#include "x3f_processor.h"
#include "sony2fuji/color_converter.h"
#include "processing_cancellation.h"
#include "parallel_pixels.h"
#include <algorithm>
#include <cmath>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <limits>
#include <atomic>
#include <chrono>
#include <thread>
#ifdef SONY2FUJI_ENABLE_X3F
#include "rawlab_x3f.h"
#endif

namespace sony2fuji {

#ifdef SONY2FUJI_ENABLE_X3F
namespace {
class X3fCancellation {
    std::unique_ptr<rawlab_x3f_cancel_token, decltype(&rawlab_x3f_cancel_free)> token_;
    std::atomic<bool> done_{false};
    std::thread monitor_;
public:
    X3fCancellation() : token_(rawlab_x3f_cancel_create(), rawlab_x3f_cancel_free) {
        if (!token_) throw std::bad_alloc();
        const auto cancellation = processingCancellation;
        if (cancellation.callback) monitor_ = std::thread([this, cancellation] {
            while (!done_.load(std::memory_order_relaxed)) {
                if (cancellation.cancelled()) { rawlab_x3f_cancel(token_.get()); break; }
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
        });
    }
    ~X3fCancellation() {
        done_.store(true, std::memory_order_relaxed);
        if (monitor_.joinable()) monitor_.join();
    }
    const rawlab_x3f_cancel_token* get() const { return token_.get(); }
};
}
#endif

bool hasX3fSignature(const std::string& path) {
    std::ifstream input(std::filesystem::u8path(path), std::ios::binary);
    char magic[4]{};
    return input.read(magic, sizeof(magic)) && std::string(magic, sizeof(magic)) == "FOVb";
}

bool hasX3fExtension(const std::string& path) {
    auto extension = std::filesystem::u8path(path).extension().u8string();
    std::transform(extension.begin(), extension.end(), extension.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return extension == ".x3f";
}

bool x3fRenderingAvailable() {
#ifdef SONY2FUJI_ENABLE_X3F
    return true;
#else
    return false;
#endif
}

X3fProcessor::X3fProcessor() {
#ifdef SONY2FUJI_ENABLE_X3F
    handle_ = rawlab_x3f_create();
#endif
}
X3fProcessor::~X3fProcessor() {
#ifdef SONY2FUJI_ENABLE_X3F
    rawlab_x3f_free(static_cast<rawlab_x3f_handle*>(handle_));
#endif
}

ErrorCode X3fProcessor::process(const std::string& path, const std::string& model, int flip,
                              const RAWProcessOptions& options, ImageData& output) {
    output = {};
    error_.clear();
#ifndef SONY2FUJI_ENABLE_X3F
    error_ = "This build does not include normal X3F rendering";
    return ErrorCode::InvalidFormat;
#else
    if (!handle_) return ErrorCode::OutOfMemory;
    if (options.useAutoWhiteBalance || options.useCustomWhiteBalance || options.useTemperatureWhiteBalance ||
        options.lensCorrection.active() || options.bayerOverride || options.rawNoiseReduction) {
        error_ = "Normal X3F rendering does not support automatic RAW white balance, FBDD, AI RAW replacement or additional lens correction";
        return ErrorCode::InvalidFormat;
    }
    if (base_.pixels.empty()) {
        uint32_t pipeline;
        if (model == "DP1S" || model == "SIGMA DP1S") pipeline = 0;
        else if (model.find("Merrill") != std::string::npos) pipeline = 2;
        else if (model.find("Quattro") != std::string::npos || model.find("quattro") != std::string::npos) pipeline = 1;
        else {
            error_ = "Normal X3F rendering has not been validated for this camera model";
            return ErrorCode::InvalidFormat;
        }
        // LibRaw 的 flip 与 EXIF orientation 使用不同编号。
        constexpr uint32_t orientations[] = {1, 2, 4, 3, 5, 8, 6, 7};
        if (flip < 0 || flip > 7) { error_ = "Invalid X3F orientation"; return ErrorCode::InvalidFormat; }
        rawlab_x3f_image decoded{};
        auto* handle = static_cast<rawlab_x3f_handle*>(handle_);
        checkProcessingCancellation();
        X3fCancellation cancellation;
        const auto result = rawlab_x3f_decode(handle, path.c_str(), pipeline, orientations[flip], cancellation.get(), &decoded);
        if (result == 4) throw ProcessingCancelled();
        checkProcessingCancellation();
        if (result != 0) { error_ = rawlab_x3f_error(handle); return ErrorCode::ProcessingError; }
        if (!decoded.pixels || decoded.encoding != 1 || decoded.width == 0 || decoded.height == 0 ||
            uint64_t(decoded.width) * decoded.height > 128000000 ||
            decoded.sample_count != uint64_t(decoded.width) * decoded.height * 3 ||
            decoded.orientation < 1 || decoded.orientation > 8) {
            error_ = "Invalid native X3F pixel contract";
            return ErrorCode::ProcessingError;
        }
        const int width = decoded.width, height = decoded.height;
        const bool transpose = decoded.orientation >= 5;
        ImageData image(transpose ? height : width, transpose ? width : height);
        parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
            for (size_t index = first; index < last; ++index) {
                const int y = static_cast<int>(index / image.width), x = static_cast<int>(index % image.width);
                int sx = x, sy = y;
                switch (decoded.orientation) {
                    case 2: sx = width - 1 - x; break;
                    case 3: sx = width - 1 - x; sy = height - 1 - y; break;
                    case 4: sy = height - 1 - y; break;
                    case 5: sx = y; sy = x; break;
                    case 6: sx = y; sy = height - 1 - x; break;
                    case 7: sx = width - 1 - y; sy = height - 1 - x; break;
                    case 8: sx = width - 1 - y; sy = x; break;
                }
                const auto* p = decoded.pixels + (size_t(sy) * width + sx) * 3;
                image.at(x, y) = RGB(GammaConverter::removeSRGBGamma(std::clamp(p[0], 0.0f, 1.0f)),
                    GammaConverter::removeSRGBGamma(std::clamp(p[1], 0.0f, 1.0f)),
                    GammaConverter::removeSRGBGamma(std::clamp(p[2], 0.0f, 1.0f)));
            }
        });
        base_ = std::move(image);
        // C++ 持有基准后释放 Rust 图像，避免缓存两份完整浮点图。
        rawlab_x3f_free(handle);
        handle_ = rawlab_x3f_create();
    }
    const auto target = options.outputAdobe ? ColorSpace::AdobeRGB :
        (options.outputAces ? ColorSpace::ACES2065_1 : ColorSpace::sRGB);
    const auto matrix = ColorConverter::getConversionMatrix(ColorSpace::sRGB, target);
    const float gain = std::exp2(options.exposure) * options.brightness;
    if (!std::isfinite(gain) || gain <= 0) return ErrorCode::InvalidFormat;
    output = base_;
    parallelPixelRanges(output.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            auto& pixel = output.pixels[i];
            pixel = RGB(pixel.r * gain, pixel.g * gain, pixel.b * gain);
            if (options.outputLinear) pixel = ColorConverter::applyMatrix(pixel, matrix);
            else {
                pixel = RGB(GammaConverter::applySRGBGamma(pixel.r), GammaConverter::applySRGBGamma(pixel.g),
                            GammaConverter::applySRGBGamma(pixel.b));
                if (options.outputBitsPerSample == 8) pixel = RGB(std::round(pixel.r * 255) / 255,
                    std::round(pixel.g * 255) / 255, std::round(pixel.b * 255) / 255);
            }
        }
    });
    return ErrorCode::Success;
#endif
}

}
