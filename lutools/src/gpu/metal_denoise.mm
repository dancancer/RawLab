#include "metal_denoise.h"
#include "metal_denoise_shader.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#include <mutex>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

namespace {
enum Kernel { SwtRows, SwtColumns, EnergyRows, Threshold, IswtColumns, IswtRows,
              Products, MeanRows, MeanColumns, Coefficients, Reconstruct, KernelCount };
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
                id<MTLLibrary> library = [value.device newLibraryWithSource:
                    [NSString stringWithUTF8String:kDenoiseShaderSource] options:options error:&error];
                if (!library || error) { NSLog(@"RawLab denoise Metal compilation failed: %@", error); return; }
                const char* names[] = {"swtRows", "swtColumns", "waveletEnergyRows", "waveletThreshold",
                    "iswtColumns", "iswtRows", "guideProducts", "guideMeanRows", "guideMeanColumns",
                    "guideCoefficients", "guideReconstruct"};
                for (int i = 0; i < KernelCount; ++i) {
                    id<MTLFunction> function = [library newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
                    value.pipelines[i] = [value.device newComputePipelineStateWithFunction:function error:&error];
                    if (error || !value.pipelines[i]) return;
                }
                value.ready = true;
            }
        }
    });
    return value;
}

struct Buffer { id<MTLBuffer> value; size_t offset = 0; };
struct WaveletParams { uint32_t width, height, step, depth, level, window; float sigma, strength; };
struct GuidedParams { uint32_t width, height, channels, radius; float epsilon; };
static_assert(sizeof(WaveletParams) == 32 && sizeof(GuidedParams) == 20, "Metal denoise parameter layout");

id<MTLBuffer> allocate(Context& context, size_t bytes, const void* source = nullptr) {
    if (!bytes || bytes > context.device.maxBufferLength) return nil;
    return source ? [context.device newBufferWithBytes:source length:bytes options:MTLResourceStorageModeShared] :
        [context.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
}

template<class Parameters>
bool encode(Context& context, id<MTLCommandBuffer> command, Kernel kernel, const Parameters& params,
            size_t count, std::initializer_list<Buffer> buffers) {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    const auto pipeline = context.pipelines[kernel];
    if (!encoder || !pipeline) return false;
    [encoder setComputePipelineState:pipeline];
    [encoder setBytes:&params length:sizeof(params) atIndex:0];
    NSUInteger index = 1;
    for (const auto& buffer : buffers) {
        if (!buffer.value) { [encoder endEncoding]; return false; }
        [encoder setBuffer:buffer.value offset:buffer.offset atIndex:index++];
    }
    [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(256, pipeline.maxTotalThreadsPerThreadgroup), 1, 1)];
    [encoder endEncoding];
    return true;
}

bool finish(id<MTLCommandBuffer> command, id<MTLBuffer> result, size_t count, float* output) {
    [command commit]; [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) return false;
    const auto* values = static_cast<const float*>(result.contents);
    for (size_t i = 0; i < count; ++i) if (!std::isfinite(values[i])) return false;
    std::memcpy(output, values, count * sizeof(float));
    return true;
}

bool wavelet(const float* input, int width, int height, const sony2fuji::WaveletFilterSettings& settings, float* output) {
    if (!input || !output || width <= 0 || height <= 0 || (settings.depth != 4 && settings.depth != 6) ||
        width % (1 << settings.depth) || height % (1 << settings.depth)) return false;
    for (int i = 0; i < settings.depth; ++i) {
        if (!std::isfinite(settings.thresholdScale[i]) || settings.thresholdScale[i] < 0) return false;
        for (int d = 0; d < 3; ++d)
            if (!std::isfinite(settings.sigma[i * 3 + d]) || settings.sigma[i * 3 + d] <= 0) return false;
    }
    auto& ctx = context();
    if (!ctx.ready) return false;
    // CPU tile workers share one bounded coefficient workspace at a time.
    std::lock_guard<std::mutex> lock(ctx.work);
    const size_t count = size_t(width) * height, bytes = count * sizeof(float);
    if (count > UINT32_MAX / 19) return false;
    auto source = allocate(ctx, bytes, input);
    auto low = allocate(ctx, bytes), high = allocate(ctx, bytes), energy = allocate(ctx, bytes);
    auto bands = allocate(ctx, bytes * (1 + 3 * settings.depth));
    if (!source || !low || !high || !energy || !bands) return false;
    id<MTLCommandBuffer> command = [ctx.queue commandBuffer];
    if (!command) return false;
    WaveletParams p{uint32_t(width), uint32_t(height), 0, uint32_t(settings.depth), 0, 0, 0, 0};
    for (int level = 1; level <= settings.depth; ++level) {
        p.level = level; p.step = 1u << (level - 1);
        if (!encode(ctx, command, SwtRows, p, count, {{level == 1 ? source : bands}, {low}, {high}}) ||
            !encode(ctx, command, SwtColumns, p, count, {{low}, {high}, {bands}})) return false;
    }
    for (int scale = 0; scale < settings.depth; ++scale) {
        p.level = settings.depth - scale;
        p.window = p.level > 4 ? (1u << (p.level - 1)) + 1 : 7;
        p.strength = settings.thresholdScale[scale];
        for (int direction = 0; direction < 3; ++direction) {
            p.sigma = settings.sigma[scale * 3 + direction];
            const Buffer band{bands, bytes * (1 + scale * 3 + direction)};
            if (!encode(ctx, command, EnergyRows, p, count, {band, {energy}}) ||
                !encode(ctx, command, Threshold, p, count, {band, {energy}})) return false;
        }
    }
    for (int level = settings.depth; level > 0; --level) {
        p.level = level; p.step = 1u << (level - 1);
        if (!encode(ctx, command, IswtColumns, p, count, {{bands}, {low}, {high}}) ||
            !encode(ctx, command, IswtRows, p, count, {{low}, {high}, {bands}})) return false;
    }
    return finish(command, bands, count, output);
}

bool guided(const float* guide, const float* input, int width, int height, int radius, float epsilon, float* output) {
    if (!guide || !input || !output || width <= 0 || height <= 0 || radius < 1 || radius > 32 ||
        !std::isfinite(epsilon) || epsilon <= 0) return false;
    auto& ctx = context();
    if (!ctx.ready) return false;
    std::lock_guard<std::mutex> lock(ctx.work);
    const size_t count = size_t(width) * height, bytes = count * sizeof(float);
    if (count > UINT32_MAX / 17) return false;
    auto guidance = allocate(ctx, bytes * 3, guide), source = allocate(ctx, bytes * 2, input);
    auto a = allocate(ctx, bytes * 17), b = allocate(ctx, bytes * 17), result = allocate(ctx, bytes * 2);
    if (!guidance || !source || !a || !b || !result) return false;
    id<MTLCommandBuffer> command = [ctx.queue commandBuffer];
    if (!command) return false;
    GuidedParams p{uint32_t(width), uint32_t(height), 17, uint32_t(radius), epsilon};
    if (!encode(ctx, command, Products, p, count, {{guidance}, {source}, {a}}) ||
        !encode(ctx, command, MeanRows, p, count * 17, {{a}, {b}}) ||
        !encode(ctx, command, MeanColumns, p, count * 17, {{b}, {a}}) ||
        !encode(ctx, command, Coefficients, p, count, {{a}, {b}})) return false;
    p.channels = 8;
    if (!encode(ctx, command, MeanRows, p, count * 8, {{b}, {a}}) ||
        !encode(ctx, command, MeanColumns, p, count * 8, {{a}, {b}}) ||
        !encode(ctx, command, Reconstruct, p, count, {{guidance}, {b}, {result}})) return false;
    return finish(command, result, count * 2, output);
}
} // namespace

namespace sony2fuji {
bool metalWaveletFilter(const float* input, int width, int height, const WaveletFilterSettings& settings, float* output) {
    @try { @autoreleasepool { return wavelet(input, width, height, settings, output); } }
    @catch (NSException*) { return false; }
}
bool metalGuidedFilter(const float* guide, const float* input, int width, int height, int radius, float epsilon, float* output) {
    @try { @autoreleasepool { return guided(guide, input, width, height, radius, epsilon, output); } }
    @catch (NSException*) { return false; }
}
}
