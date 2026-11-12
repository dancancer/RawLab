#import <Metal/Metal.h>
#import <objc/runtime.h>
#include "gpu/image_stats.h"
#include "gpu/photo_gpu.h"
#include "sony2fuji/gpu/lut_gpu.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <unistd.h>

namespace {
using BufferMethod = id<MTLBuffer> (*)(id, SEL, NSUInteger, MTLResourceOptions);
using BytesBufferMethod = id<MTLBuffer> (*)(id, SEL, const void*, NSUInteger, MTLResourceOptions);
using LimitMethod = NSUInteger (*)(id, SEL);
using StatusMethod = MTLCommandBufferStatus (*)(id, SEL);
BufferMethod originalBuffer;
BytesBufferMethod originalBytesBuffer;
LimitMethod originalLimit;
StatusMethod originalStatus;
size_t budget = std::numeric_limits<size_t>::max(), largest = 0, imageAllocations = 0;
int completions = 0, failCompletion = 0, bytesBufferThrows = 0;

id<MTLBuffer> boundedBuffer(id device, SEL selector, NSUInteger length, MTLResourceOptions options) {
    largest = std::max(largest, size_t(length));
    if (length > 4096) ++imageAllocations;
    return length > budget ? nil : originalBuffer(device, selector, length, options);
}
id<MTLBuffer> throwingBytesBuffer(id, SEL, const void*, NSUInteger, MTLResourceOptions) {
    ++bytesBufferThrows;
    [NSException raise:NSInternalInconsistencyException format:@"injected Metal exception"];
    return nil;
}
NSUInteger boundedLimit(id device, SEL selector) { return std::min<size_t>(originalLimit(device, selector), budget); }
MTLCommandBufferStatus completionStatus(id command, SEL selector) {
    const auto status = originalStatus(command, selector);
    if (status == MTLCommandBufferStatusCompleted && ++completions == failCompletion)
        return MTLCommandBufferStatusError;
    return status;
}

sony2fuji::ImageData image(int width, int height) {
    sony2fuji::ImageData result(width, height);
    for (size_t i = 0; i < result.pixels.size(); ++i) {
        const float a = float((i * 71 + i / 9) % 256) / 255;
        result.pixels[i] = sony2fuji::RGB(a, a * .7f, 1 - a);
    }
    return result;
}

bool sameImage(const sony2fuji::ImageData& actual, const sony2fuji::ImageData& expected) {
    if (actual.width != expected.width || actual.height != expected.height || actual.pixels.size() != expected.pixels.size()) return false;
    float maximum = 0;
    for (size_t i = 0; i < actual.pixels.size(); ++i) {
        const auto a = actual.pixels[i], b = expected.pixels[i];
        if (!std::isfinite(a.r) || !std::isfinite(a.g) || !std::isfinite(a.b)) return false;
        maximum = std::max({maximum, std::abs(a.r-b.r), std::abs(a.g-b.g), std::abs(a.b-b.b)});
    }
    std::cout << "DIFF Metal band sizes max=" << maximum << '\n';
    return maximum <= 5e-5f;
}
}

int main() {
    @autoreleasepool {
        using namespace sony2fuji;
        sony2fuji_request request{};
        request.brightness = request.contrast = request.saturation = 1;
        request.temperature = 6500; request.intent = SONY2FUJI_INTENT_FINAL;
        ImageData warm;
        if (!renderPhotoMetal(image(1,1), ColorSpace::sRGB, request, {}, RGB(1,1,1), 1, 1, warm)) return 1;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        Method bufferMethod = class_getInstanceMethod(object_getClass(device), @selector(newBufferWithLength:options:));
        Method limitMethod = class_getInstanceMethod(object_getClass(device), @selector(maxBufferLength));
        id<MTLCommandQueue> queue = [device newCommandQueue];
        Method statusMethod = class_getInstanceMethod(object_getClass([queue commandBuffer]), @selector(status));
        originalBuffer = reinterpret_cast<BufferMethod>(method_setImplementation(bufferMethod, reinterpret_cast<IMP>(boundedBuffer)));
        originalLimit = reinterpret_cast<LimitMethod>(method_setImplementation(limitMethod, reinterpret_cast<IMP>(boundedLimit)));
        originalStatus = reinterpret_cast<StatusMethod>(method_setImplementation(statusMethod, reinterpret_cast<IMP>(completionStatus)));
        bool passed = true;
        for (int scenario = 0; scenario < 6; ++scenario) {
            auto input = image(scenario == 4 ? 1 : scenario == 5 ? 17 : 2053, scenario == 5 ? 1 : scenario == 4 ? 33 : 1027);
            const uint32_t width = scenario == 2 || scenario == 3 ? 641 : input.width;
            const uint32_t height = scenario == 2 || scenario == 3 ? 317 : input.height;
            request.intent = scenario == 2 ? SONY2FUJI_INTENT_PREVIEW : SONY2FUJI_INTENT_FINAL;
            request.noise_reduction = scenario == 1 || scenario == 3 ? .4f : 0;
            request.sharpening = scenario == 1 || scenario == 3 ? .7f : 0;
            PhotoEffectsOptions effects;
            if (scenario == 1 || scenario == 3) { effects.vignetteAmount = -30; effects.grainAmount = 25; }
            HslOptions hsl; hsl.hue[4] = 12; hsl.saturation[0] = -20; hsl.lightness[5] = 10;
            ImageData expected, actual;
            budget = std::numeric_limits<size_t>::max();
            bool ok = renderPhotoMetal(input, ColorSpace::sRGB, request, {}, RGB(1,1,1), width, height, expected, {}, effects, 0, false, hsl);
            // 驱动限制比默认块小，强制跨行块及最后一个不足整块的边界。
            budget = 512 * 1024; largest = 0; completions = 0; imageAllocations = 0;
            ok = ok && renderPhotoMetal(input, ColorSpace::sRGB, request, {}, RGB(1,1,1), width, height, actual, {}, effects, 0, false, hsl);
            ok = ok && largest <= budget && imageAllocations <= 4 && sameImage(actual, expected);
            std::cout << (ok ? "PASS" : "FAIL") << " bounded Metal scenario=" << scenario
                << " largest=" << largest << " budget=" << budget << " allocations=" << imageAllocations << " commands=" << completions << '\n';
            passed &= ok;
        }
        auto input = image(2053, 1027);
        ImageData output(1,1); output.pixels[0] = RGB(-7,-8,-9);
        request.intent = SONY2FUJI_INTENT_FINAL; request.noise_reduction = request.sharpening = 0;
        completions = 0; failCompletion = 2;
        const bool rendered = renderPhotoMetal(input, ColorSpace::sRGB, request, {}, RGB(1,1,1), input.width, input.height, output);
        const bool atomic = !rendered && completions == 2 && output.width == 1 && output.height == 1 &&
            output.pixels[0].r == -7 && output.pixels[0].g == -8 && output.pixels[0].b == -9;
        std::cout << (atomic ? "PASS" : "FAIL") << " mid-band failure preserves output\n";
        passed &= atomic;
        method_setImplementation(bufferMethod, reinterpret_cast<IMP>(originalBuffer));
        method_setImplementation(limitMethod, reinterpret_cast<IMP>(originalLimit));
        method_setImplementation(statusMethod, reinterpret_cast<IMP>(originalStatus));
        const auto lutPath = std::filesystem::temp_directory_path() /
            ("rawlab-metal-lut-guard-" + std::to_string(::getpid()) + ".cube");
        {
            std::ofstream cubeFile(lutPath, std::ios::binary);
            cubeFile << "# Gamma: FLog2 to ETERNA\n# Gamut: FGamut to ITUR BT709\n"
                        "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
        }
        const std::string lutPathUtf8 = lutPath.u8string();
        const uint8_t lutInputPixels[12] = {32, 96, 192, 200, 80, 40, 16, 180, 120, 220, 210, 60};
        sony2fuji_request lutRequest{};
        lutRequest.version = SONY2FUJI_REQUEST_VERSION;
        lutRequest.struct_size = sizeof(lutRequest);
        lutRequest.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
        lutRequest.input_pixels = lutInputPixels;
        lutRequest.input_width = 2;
        lutRequest.input_height = 2;
        lutRequest.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
        lutRequest.input_color_space = SONY2FUJI_COLOR_SRGB;
        lutRequest.input_is_linear = 0;
        lutRequest.lut_path = lutPathUtf8.c_str();
        lutRequest.lut_strength = 1.0f;
        lutRequest.wb_mode = SONY2FUJI_WB_CAMERA;
        lutRequest.temperature = 6500;
        lutRequest.brightness = lutRequest.contrast = lutRequest.saturation = 1.0f;
        lutRequest.output_target = SONY2FUJI_TARGET_BUFFER;
        lutRequest.output_format = SONY2FUJI_OUTPUT_RGB8;
        lutRequest.intent = SONY2FUJI_INTENT_FINAL;
        lutRequest.size_mode = SONY2FUJI_SIZE_NATIVE;
        sony2fuji_session* lutSession = nullptr;
        sony2fuji_session_create(&lutSession);
        sony2fuji_gpu_config gpuOff{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpuOff), SONY2FUJI_GPU_OFF};
        sony2fuji_gpu_config gpuAuto{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpuAuto), SONY2FUJI_GPU_AUTO};
        sony2fuji_buffer cpuLutOut{};
        sony2fuji_session_set_gpu_config(lutSession, &gpuOff);
        const bool cpuRefOk = sony2fuji_process(lutSession, &lutRequest, &cpuLutOut) == SONY2FUJI_STATUS_OK && cpuLutOut.data != nullptr;

        Method bytesBufferMethod = class_getInstanceMethod(object_getClass(device), @selector(newBufferWithBytes:length:options:));
        originalBytesBuffer = reinterpret_cast<BytesBufferMethod>(
            method_setImplementation(bytesBufferMethod, reinterpret_cast<IMP>(throwingBytesBuffer)));
        {
            uint8_t statsPixels[16] = {};
            const sony2fuji_buffer statsInput{statsPixels, sizeof(statsPixels), 2, 2, 8, SONY2FUJI_PIXEL_RGBA8};
            ImageStats directStats{};
            directStats.shadows = 77;
            directStats.highlights = 88;
            bool statsEscaped = false;
            bool statsReturned = true;
            bytesBufferThrows = 0;
            @try {
                statsReturned = computeImageStatsMetal(statsInput, directStats);
            } @catch (NSException*) {
                statsEscaped = true;
            }
            const int directStatsThrows = bytesBufferThrows;
            uint32_t bins[768] = {};
            uint32_t shadows = 0, highlights = 0;
            sony2fuji_buffer mask{};
            const auto statsStatus = sony2fuji_analyze_image(&statsInput, SONY2FUJI_GPU_FORCE, bins, &shadows, &highlights, &mask);
            const bool statsGuarded = directStatsThrows == 1 && !statsEscaped && !statsReturned &&
                directStats.shadows == 77 && directStats.highlights == 88 &&
                statsStatus == SONY2FUJI_STATUS_PROCESSING_ERROR && mask.data == nullptr;
            std::cout << (statsGuarded ? "PASS" : "FAIL")
                      << " computeImageStatsMetal catches NSException internally (throws=" << directStatsThrows
                      << ", escaped=" << statsEscaped << ") and preserves C ABI Force error\n";
            passed &= statsGuarded;

            sony2fuji_buffer autoLutOut{};
            sony2fuji_session_set_gpu_config(lutSession, &gpuAuto);
            bytesBufferThrows = 0;
            const auto autoStatus = sony2fuji_process(lutSession, &lutRequest, &autoLutOut);
            const int cAbiLutThrows = bytesBufferThrows;
            const bool autoMatchesCpu = cpuRefOk && autoStatus == SONY2FUJI_STATUS_OK && autoLutOut.data != nullptr &&
                autoLutOut.size_bytes == cpuLutOut.size_bytes &&
                std::memcmp(autoLutOut.data, cpuLutOut.data, cpuLutOut.size_bytes) == 0;

            auto lut = std::make_shared<LUT3D>();
            const bool lutLoaded = lut->loadFromFile(lutPathUtf8) == ErrorCode::Success;
            ImageData lutImage = image(2, 2);
            const ImageData lutBefore = lutImage;
            bool lutForceEscaped = false;
            ErrorCode lutForceCode = ErrorCode::Success;
            @try {
                lutForceCode = applyLUTWithConfig(lut, lutImage, {GpuMode::Force});
            } @catch (NSException*) {
                lutForceEscaped = true;
            }
            const bool lutGuarded = cAbiLutThrows == 1 && autoMatchesCpu &&
                lutLoaded && !lutForceEscaped && lutForceCode == ErrorCode::ProcessingError &&
                lutImage.pixels[0].r == lutBefore.pixels[0].r;
            std::cout << (lutGuarded ? "PASS" : "FAIL")
                      << " applyLutMetal catches NSException internally across C ABI (throws=" << cAbiLutThrows
                      << ", AutoStatus=" << autoStatus << ", ForceEscaped=" << lutForceEscaped << ")\n";
            sony2fuji_release_buffer(&autoLutOut);
            passed &= lutGuarded;
        }
        method_setImplementation(bytesBufferMethod, reinterpret_cast<IMP>(originalBytesBuffer));
        sony2fuji_release_buffer(&cpuLutOut);
        sony2fuji_session_destroy(lutSession);
        std::error_code removeError;
        std::filesystem::remove(lutPath, removeError);
        [queue release]; [device release];
        return passed ? 0 : 1;
    }
}
