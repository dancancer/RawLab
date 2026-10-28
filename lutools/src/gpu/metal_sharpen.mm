#include "metal_sharpen.h"
#include "metal_sharpen_shader.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <mutex>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#ifdef SONY2FUJI_TEST_P3_READBACK
namespace sony2fuji { void testNoiseAwareSharpenReadback(float* values, size_t count); }
#endif

namespace {
enum Kernel { Gradients, MeanRows, MeanColumns, Initial, Relax, Project, Output, KernelCount };
struct Context {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    std::array<id<MTLComputePipelineState>, KernelCount> pipelines{};
    std::mutex work;
    bool ready = false;
};
Context& context() {
    static Context value;
    static std::once_flag once;
    std::call_once(once, [&] {
        @autoreleasepool {
            if (@available(macOS 15.0, iOS 18.0, *)) {
                value.device = MTLCreateSystemDefaultDevice();
                value.queue = [value.device newCommandQueue];
                if (!value.device || !value.queue) return;
                MTLCompileOptions* options = [MTLCompileOptions new];
                options.mathMode = MTLMathModeSafe;
                NSError* error = nil;
                auto library = [value.device newLibraryWithSource:[NSString stringWithUTF8String:kNoiseAwareSharpenShader] options:options error:&error];
                if (!library || error) { NSLog(@"RawLab P3 Metal compilation failed: %@", error); return; }
                const char* names[] = {"sharpenGradients", "sharpenMeanRows", "sharpenMeanColumns", "sharpenInitial", "sharpenRelax", "sharpenProject", "sharpenOutput"};
                for (int i = 0; i < KernelCount; ++i) {
                    auto function = [library newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
                    value.pipelines[i] = [value.device newComputePipelineStateWithFunction:function error:&error];
                    if (!value.pipelines[i] || error) return;
                }
                value.ready = true;
            }
        }
    });
    return value;
}
struct Params { uint32_t width, height; float amount; };
static_assert(sizeof(Params) == 12, "P3 Metal parameter layout");

id<MTLBuffer> allocate(Context& ctx, size_t bytes, const void* source = nullptr) {
    if (!bytes || bytes > ctx.device.maxBufferLength) return nil;
    return source ? [ctx.device newBufferWithBytes:source length:bytes options:MTLResourceStorageModeShared] :
        [ctx.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
}
bool encode(Context& ctx, id<MTLCommandBuffer> command, Kernel kernel, const Params& params,
            std::initializer_list<id<MTLBuffer>> buffers) {
    auto encoder = [command computeCommandEncoder];
    const auto pipeline = ctx.pipelines[kernel];
    if (!encoder || !pipeline) return false;
    [encoder setComputePipelineState:pipeline];
    [encoder setBytes:&params length:sizeof(params) atIndex:0];
    NSUInteger index = 1;
    for (auto buffer : buffers) {
        if (!buffer) { [encoder endEncoding]; return false; }
        [encoder setBuffer:buffer offset:0 atIndex:index++];
    }
    [encoder dispatchThreads:MTLSizeMake(size_t(params.width)*params.height, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(256, pipeline.maxTotalThreadsPerThreadgroup), 1, 1)];
    [encoder endEncoding];
    return true;
}
bool filter(const float* rgb, const float* luma, const float* residual, const float* noise,
            int width, int height, float amount, float* output) {
    if (!rgb || !luma || !residual || !noise || !output || width < 1 || height < 1 ||
        !std::isfinite(amount) || amount <= 0 || amount > 2 || uint64_t(width)*height > UINT32_MAX/4) return false;
    auto& ctx = context();
    if (!ctx.ready) return false;
    std::lock_guard<std::mutex> lock(ctx.work);
    const size_t count = size_t(width)*height, bytes = count*sizeof(float);
    auto source = allocate(ctx, 3*bytes, rgb), y = allocate(ctx, bytes, luma);
    auto high = allocate(ctx, bytes, residual), variance = allocate(ctx, bytes, noise);
    auto stats = allocate(ctx, 4*bytes), rows = allocate(ctx, 8*bytes), means = allocate(ctx, 4*bytes);
    auto initial = allocate(ctx, 4*bytes), flags = allocate(ctx, count*sizeof(uint32_t));
    auto a = allocate(ctx, 4*bytes), b = allocate(ctx, 4*bytes), result = allocate(ctx, 3*bytes);
    if (!source || !y || !high || !variance || !stats || !rows || !means || !initial || !flags || !a || !b || !result) return false;
    auto command = [ctx.queue commandBuffer];
    if (!command) return false;
    const Params p{uint32_t(width), uint32_t(height), amount};
    if (!encode(ctx, command, Gradients, p, {y, high, stats}) ||
        !encode(ctx, command, MeanRows, p, {stats, rows}) ||
        !encode(ctx, command, MeanColumns, p, {rows, means}) ||
        !encode(ctx, command, Initial, p, {source, y, high, variance, stats, means, initial, flags}) ||
        !encode(ctx, command, Relax, p, {source, initial, flags, a}) ||
        !encode(ctx, command, Project, p, {a, flags, b}) ||
        !encode(ctx, command, Project, p, {b, flags, a}) ||
        !encode(ctx, command, Output, p, {source, a, result})) return false;
    [command commit]; [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) return false;
    const auto* values = static_cast<const float*>(result.contents);
#ifdef SONY2FUJI_TEST_P3_READBACK
    sony2fuji::testNoiseAwareSharpenReadback(static_cast<float*>(result.contents), 3*count);
#endif
    for (size_t i = 0; i < 3*count; ++i) if (!std::isfinite(values[i])) return false;
    std::memcpy(output, values, 3*bytes);
    return true;
}
}

namespace sony2fuji {
bool metalNoiseAwareSharpen(const float* rgb, const float* luma, const float* residual,
    const float* noise, int width, int height, float amount, float* output) {
    @try { @autoreleasepool { return filter(rgb, luma, residual, noise, width, height, amount, output); } }
    @catch (NSException*) { return false; }
}
}
