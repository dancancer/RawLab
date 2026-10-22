#import <Metal/Metal.h>
#import <objc/runtime.h>
#include "gpu/photo_gpu.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>

namespace {
using BufferMethod = id<MTLBuffer> (*)(id, SEL, NSUInteger, MTLResourceOptions);
using LimitMethod = NSUInteger (*)(id, SEL);
using StatusMethod = MTLCommandBufferStatus (*)(id, SEL);
BufferMethod originalBuffer;
LimitMethod originalLimit;
StatusMethod originalStatus;
size_t budget = std::numeric_limits<size_t>::max(), largest = 0, imageAllocations = 0;
int completions = 0, failCompletion = 0;

id<MTLBuffer> boundedBuffer(id device, SEL selector, NSUInteger length, MTLResourceOptions options) {
    largest = std::max(largest, size_t(length));
    if (length > 4096) ++imageAllocations;
    return length > budget ? nil : originalBuffer(device, selector, length, options);
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
        [queue release]; [device release];
        return passed ? 0 : 1;
    }
}
