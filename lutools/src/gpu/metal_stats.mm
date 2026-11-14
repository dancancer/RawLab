#include "gpu/image_stats.h"
#include "core/processing_cancellation.h"

#import <Metal/Metal.h>

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <limits>
#include <mutex>
#include <utility>

namespace {

constexpr size_t kHistogramBins = 768;
constexpr size_t kCounterCount = kHistogramBins + 2;

struct ImageLayout {
    const uint8_t* data = nullptr;
    size_t requiredBytes = 0;
    size_t pixelCount = 0;
    size_t maskBytes = 0;
    uint32_t channels = 0;
};

bool checkedMultiply(size_t left, size_t right, size_t& result) {
    if (left != 0 && right > std::numeric_limits<size_t>::max() / left) {
        return false;
    }
    result = left * right;
    return true;
}

bool checkedAdd(size_t left, size_t right, size_t& result) {
    if (right > std::numeric_limits<size_t>::max() - left) {
        return false;
    }
    result = left + right;
    return true;
}

bool validateBuffer(const sony2fuji_buffer& buffer, ImageLayout& layout) {
    if (!buffer.data || buffer.width == 0 || buffer.height == 0) {
        return false;
    }

    if (buffer.pixel_format == SONY2FUJI_PIXEL_RGB8) {
        layout.channels = 3;
    } else if (buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8) {
        layout.channels = 4;
    } else {
        return false;
    }

    size_t rowBytes = 0;
    if (!checkedMultiply(static_cast<size_t>(buffer.width), layout.channels, rowBytes) ||
        buffer.stride_bytes < rowBytes) {
        return false;
    }

    size_t lastRowOffset = 0;
    if (!checkedMultiply(static_cast<size_t>(buffer.height - 1),
                         static_cast<size_t>(buffer.stride_bytes), lastRowOffset) ||
        !checkedAdd(lastRowOffset, rowBytes, layout.requiredBytes) ||
        layout.requiredBytes > buffer.size_bytes) {
        return false;
    }

    if (!checkedMultiply(static_cast<size_t>(buffer.width),
                         static_cast<size_t>(buffer.height), layout.pixelCount) ||
        layout.pixelCount > std::numeric_limits<uint32_t>::max() ||
        !checkedMultiply(layout.pixelCount, 4, layout.maskBytes)) {
        return false;
    }

    layout.data = static_cast<const uint8_t*>(buffer.data);
    return true;
}

struct MetalContext {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLComputePipelineState> pipeline = nil;
    bool ready = false;
};

static NSString* kShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "constant uint kHistogramBins = 768;\n"
     "constant uint kCounterCount = 770;\n"
     "struct StatsParams { uint width; uint height; uint stride_bytes; uint channels; uint pixel_count; };\n"
     "kernel void image_stats(device const uchar* pixels [[buffer(0)]],\n"
     "                        device atomic_uint* totals [[buffer(1)]],\n"
     "                        device uchar* clipping [[buffer(2)]],\n"
     "                        constant StatsParams& params [[buffer(3)]],\n"
     "                        uint gid [[thread_position_in_grid]],\n"
     "                        uint tid [[thread_position_in_threadgroup]],\n"
     "                        uint threads [[threads_per_threadgroup]]) {\n"
     "    threadgroup atomic_uint local_totals[kCounterCount];\n"
     "    for (uint index = tid; index < kCounterCount; index += threads) {\n"
     "        atomic_store_explicit(&local_totals[index], 0u, memory_order_relaxed);\n"
     "    }\n"
     "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
     "    if (gid < params.pixel_count) {\n"
     "        uint y = gid / params.width;\n"
     "        uint x = gid - y * params.width;\n"
     "        device const uchar* pixel = pixels + y * params.stride_bytes + x * params.channels;\n"
     "        uchar r = pixel[0];\n"
     "        uchar g = pixel[1];\n"
     "        uchar b = pixel[2];\n"
     "        atomic_fetch_add_explicit(&local_totals[r], 1u, memory_order_relaxed);\n"
     "        atomic_fetch_add_explicit(&local_totals[256u + g], 1u, memory_order_relaxed);\n"
     "        atomic_fetch_add_explicit(&local_totals[512u + b], 1u, memory_order_relaxed);\n"
     "        device uchar* mask = clipping + gid * 4u;\n"
     "        mask[0] = 0; mask[1] = 0; mask[2] = 0; mask[3] = 0;\n"
     "        if (r == 255 || g == 255 || b == 255) {\n"
     "            atomic_fetch_add_explicit(&local_totals[769], 1u, memory_order_relaxed);\n"
     "            mask[0] = 255; mask[3] = 160;\n"
     "        } else if (r == 0 && g == 0 && b == 0) {\n"
     "            atomic_fetch_add_explicit(&local_totals[768], 1u, memory_order_relaxed);\n"
     "            mask[1] = 130; mask[2] = 255; mask[3] = 160;\n"
     "        }\n"
     "    }\n"
     "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
     "    for (uint index = tid; index < kCounterCount; index += threads) {\n"
     "        uint value = atomic_load_explicit(&local_totals[index], memory_order_relaxed);\n"
     "        if (value != 0u) {\n"
     "            atomic_fetch_add_explicit(&totals[index], value, memory_order_relaxed);\n"
     "        }\n"
     "    }\n"
     "}\n";

MetalContext* getMetalContext() {
    static MetalContext context;
    static std::once_flag once;
    std::call_once(once, []() {
        @autoreleasepool {
            context.device = MTLCreateSystemDefaultDevice();
            if (!context.device) {
                return;
            }
            context.queue = [context.device newCommandQueue];
            if (!context.queue) {
                return;
            }
            NSError* error = nil;
            id<MTLLibrary> library = [context.device newLibraryWithSource:kShaderSource
                                                                    options:nil
                                                                      error:&error];
            if (!library) {
                return;
            }
            id<MTLFunction> function = [library newFunctionWithName:@"image_stats"];
            if (!function) {
                return;
            }
            context.pipeline = [context.device newComputePipelineStateWithFunction:function
                                                                                 error:&error];
            context.ready = context.pipeline != nil;
        }
    });
    return context.ready ? &context : nullptr;
}

struct StatsParams {
    uint32_t width;
    uint32_t height;
    uint32_t strideBytes;
    uint32_t channels;
    uint32_t pixelCount;
};

bool runKernel(MetalContext& context, const ImageLayout& layout,
               const sony2fuji_buffer& buffer, sony2fuji::ImageStats& result) {
    id<MTLBuffer> pixels = [context.device newBufferWithBytes:layout.data
                                                         length:layout.requiredBytes
                                                        options:MTLResourceStorageModeShared];
    id<MTLBuffer> totals = [context.device newBufferWithLength:kCounterCount * sizeof(uint32_t)
                                                        options:MTLResourceStorageModeShared];
    id<MTLBuffer> clipping = [context.device newBufferWithLength:layout.maskBytes
                                                           options:MTLResourceStorageModeShared];
    if (!pixels || !totals || !clipping || !totals.contents || !clipping.contents) {
        return false;
    }
    std::memset(totals.contents, 0, kCounterCount * sizeof(uint32_t));
    std::memset(clipping.contents, 0, layout.maskBytes);

    const StatsParams params{
        buffer.width,
        buffer.height,
        buffer.stride_bytes,
        layout.channels,
        static_cast<uint32_t>(layout.pixelCount)
    };
    id<MTLBuffer> paramsBuffer = [context.device newBufferWithBytes:&params
                                                               length:sizeof(params)
                                                              options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> commandBuffer = [context.queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!paramsBuffer || !commandBuffer || !encoder) {
        return false;
    }

    [encoder setComputePipelineState:context.pipeline];
    [encoder setBuffer:pixels offset:0 atIndex:0];
    [encoder setBuffer:totals offset:0 atIndex:1];
    [encoder setBuffer:clipping offset:0 atIndex:2];
    [encoder setBuffer:paramsBuffer offset:0 atIndex:3];

    NSUInteger threadgroupSize = std::min<NSUInteger>(256, context.pipeline.maxTotalThreadsPerThreadgroup);
    const NSUInteger executionWidth = context.pipeline.threadExecutionWidth;
    if (executionWidth > 1) {
        threadgroupSize = (threadgroupSize / executionWidth) * executionWidth;
    }
    if (threadgroupSize == 0) {
        [encoder endEncoding];
        return false;
    }
    const NSUInteger groupCount =
        (static_cast<NSUInteger>(layout.pixelCount) - 1) / threadgroupSize + 1;
    [encoder dispatchThreadgroups:MTLSizeMake(groupCount, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(threadgroupSize, 1, 1)];
    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        return false;
    }

    try {
        sony2fuji::ImageStats candidate;
        const auto* values = static_cast<const uint32_t*>(totals.contents);
        std::copy_n(values, kHistogramBins, candidate.histogram.begin());
        candidate.shadows = values[kHistogramBins];
        candidate.highlights = values[kHistogramBins + 1];
        candidate.clipping.resize(layout.maskBytes);
        std::memcpy(candidate.clipping.data(), clipping.contents, layout.maskBytes);
        result = std::move(candidate);
        return true;
    } catch (const sony2fuji::ProcessingCancelled&) {
        // Cancellation is not a stats failure: rethrow it unchanged (the #329
        // semantics). Forward-looking defence: the only FFI caller today,
        // sony2fuji_analyze_image, is FORCE-only and installs no cancellation
        // scope, so a stray cancellation maps to PROCESSING_ERROR there; what the
        // rethrow prevents is this fallback turning a cancelled run into a plain
        // `false` and inviting an AUTO caller to redo the whole image on CPU.
        throw;
    } catch (const std::exception&) {
        return false;
    } catch (...) {
        // Restore the catch-all fallback: computeImageStatsMetal has a no-throw
        // promise, and a throw object that does not derive from std::exception
        // escaped it toward direct C++ callers and the internal-API tests (G-N5).
        // The sony2fuji_analyze_image boundary happens to map such a throw to
        // PROCESSING_ERROR anyway; the promise belongs to this function.
        return false;
    }
}

} // namespace

namespace sony2fuji {

bool computeImageStatsMetal(const sony2fuji_buffer& buffer, ImageStats& output) {
    ImageLayout layout;
    if (!validateBuffer(buffer, layout)) {
        return false;
    }
    @autoreleasepool {
        @try {
            MetalContext* context = getMetalContext();
            if (!context) {
                return false;
            }
            return runKernel(*context, layout, buffer, output);
        } @catch (NSException*) {
            return false;
        }
    }
}

} // namespace sony2fuji
