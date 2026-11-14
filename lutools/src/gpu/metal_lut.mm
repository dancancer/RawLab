#include "sony2fuji/gpu/lut_gpu.h"
#include <cstring>

#include "gpu/lut_gpu_internal.h"

#import <Metal/Metal.h>

#include <algorithm>
#include <mutex>
#include <vector>

namespace {

struct MetalContext {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLComputePipelineState> pipeline = nil;
    bool ready = false;
};

static NSString* kShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct Params { uint pixel_count; uint lut_size; };\n"
     "kernel void apply_lut(texture3d<float, access::sample> lut [[texture(0)]],\n"
     "                      device packed_float3* pixels [[buffer(0)]],\n"
     "                      constant Params& params [[buffer(1)]],\n"
     "                      uint gid [[thread_position_in_grid]]) {\n"
     "    if (gid >= params.pixel_count) return;\n"
     "    packed_float3 input = pixels[gid];\n"
     "    float3 color = clamp(float3(input), 0.0f, 1.0f);\n"
     "    float size = float(params.lut_size);\n"
     "    float3 uvw = (color * (size - 1.0f) + 0.5f) / size;\n"
     "    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
     "    float3 out = lut.sample(s, uvw).xyz;\n"
     "    pixels[gid] = packed_float3(out);\n"
     "}\n";

bool initContext(MetalContext& context) {
    @autoreleasepool {
        context.device = MTLCreateSystemDefaultDevice();
        if (!context.device) {
            return false;
        }
        context.queue = [context.device newCommandQueue];
        if (!context.queue) {
            return false;
        }
        id<MTLLibrary> library = [context.device newLibraryWithSource:kShaderSource
                                                              options:nil
                                                                error:nil];
        if (!library) {
            return false;
        }
        id<MTLFunction> function = [library newFunctionWithName:@"apply_lut"];
        if (!function) {
            return false;
        }
        context.pipeline = [context.device newComputePipelineStateWithFunction:function error:nil];
        context.ready = context.pipeline != nil;
    }
    return context.ready;
}

MetalContext* getMetalContext() {
    static MetalContext context;
    static std::mutex mutex;
    std::lock_guard<std::mutex> lock(mutex);
    // 失败不缓存比 TTL 少一套计时状态；只发布完整上下文，失败的 ARC 资源随候选对象释放。
    if (!context.ready) {
        MetalContext candidate;
        if (!initContext(candidate)) {
            return nullptr;
        }
        context = candidate;
    }
    return &context;
}

id<MTLTexture> createLutTexture(MetalContext& context, const sony2fuji::LUT3D& lut) {
    const int size = lut.getSize();
    if (size <= 1) {
        return nil;
    }
    std::vector<float> data = sony2fuji::buildLutTextureDataRGBA(lut);
    MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.textureType = MTLTextureType3D;
    descriptor.pixelFormat = MTLPixelFormatRGBA32Float;
    descriptor.width = size;
    descriptor.height = size;
    descriptor.depth = size;
    descriptor.mipmapLevelCount = 1;
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [context.device newTextureWithDescriptor:descriptor];
    if (!texture) {
        return nil;
    }
    MTLRegion region = MTLRegionMake3D(0, 0, 0, size, size, size);
    NSUInteger bytes_per_row = static_cast<NSUInteger>(size) * 4 * sizeof(float);
    NSUInteger bytes_per_image = bytes_per_row * static_cast<NSUInteger>(size);
    [texture replaceRegion:region
               mipmapLevel:0
                     slice:0
                 withBytes:data.data()
               bytesPerRow:bytes_per_row
             bytesPerImage:bytes_per_image];
    return texture;
}

// 与 GLES 路径一致的瓦片大小：GPU 暂存缓冲上限固定，不随整幅尺寸膨胀。
constexpr size_t kLutTileBytes = 16ull * 1024 * 1024;

id<MTLBuffer> createParamsBuffer(MetalContext& context, uint32_t pixel_count, uint32_t lut_size) {
    struct Params {
        uint32_t pixel_count;
        uint32_t lut_size;
    };
    Params params{pixel_count, lut_size};
    return [context.device newBufferWithBytes:&params
                                       length:sizeof(params)
                                      options:MTLResourceStorageModeShared];
}

bool runCompute(
    MetalContext& context,
    id<MTLBuffer> pixel_buffer,
    id<MTLTexture> lut_texture,
    uint32_t pixel_count,
    uint32_t lut_size
) {
    id<MTLBuffer> params = createParamsBuffer(context, pixel_count, lut_size);
    if (!params) {
        return false;
    }
    id<MTLCommandBuffer> command_buffer = [context.queue commandBuffer];
    if (!command_buffer) {
        return false;
    }
    id<MTLComputeCommandEncoder> encoder = [command_buffer computeCommandEncoder];
    if (!encoder) {
        return false;
    }
    [encoder setComputePipelineState:context.pipeline];
    [encoder setBuffer:pixel_buffer offset:0 atIndex:0];
    [encoder setBuffer:params offset:0 atIndex:1];
    [encoder setTexture:lut_texture atIndex:0];

    NSUInteger max_threads = context.pipeline.maxTotalThreadsPerThreadgroup;
    NSUInteger threadgroup_size = std::min<NSUInteger>(256, max_threads);
    MTLSize threads_per_group = MTLSizeMake(threadgroup_size, 1, 1);
    MTLSize grid = MTLSizeMake(pixel_count, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:threads_per_group];
    [encoder endEncoding];

    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    return command_buffer.status == MTLCommandBufferStatusCompleted;
}

}

namespace sony2fuji {

bool applyLutMetal(const LUT3D& lut, ImageData& image, size_t* completedPixels) {
    if (completedPixels) {
        *completedPixels = 0;
    }
    size_t completed = 0;
    @autoreleasepool {
        @try {
            try {
                MetalContext* context = getMetalContext();
                if (!context) {
                    return false;
                }
                const size_t pixel_count = image.pixels.size();
                if (pixel_count == 0) {
                    return false;
                }
                id<MTLTexture> lut_texture = createLutTexture(*context, lut);
                if (!lut_texture) {
                    return false;
                }
                // 与 GLES 路径一致的瓦片大小（并受设备 maxBufferLength 约束）：上传/回写
                // 仍是两次整幅 memcpy，但 GPU 暂存峰值从整幅（可达数百 MiB）降到固定瓦片。
                // 每个瓦片只有在计算成功后才回写；completedPixels 报告已完整提交的像素数，
                // 供 Auto 回退只补未提交尾部，失败调用方也不会对未提交像素读到半截结果。
                const size_t tile_pixels = std::min({
                    pixel_count,
                    kLutTileBytes / sizeof(RGB),
                    static_cast<size_t>(context->device.maxBufferLength) / sizeof(RGB)});
                id<MTLBuffer> pixel_buffer = [context->device newBufferWithLength:tile_pixels * sizeof(RGB)
                                                                          options:MTLResourceStorageModeShared];
                if (!pixel_buffer || !pixel_buffer.contents) {
                    return false;
                }
                auto* staging = static_cast<float*>(pixel_buffer.contents);
                for (size_t offset = 0; offset < pixel_count; offset += tile_pixels) {
                    const size_t count = std::min(tile_pixels, pixel_count - offset);
                    const size_t bytes = count * sizeof(RGB);
                    std::memcpy(staging, image.pixels.data() + offset, bytes);
                    if (!runCompute(*context, pixel_buffer, lut_texture, static_cast<uint32_t>(count),
                                    static_cast<uint32_t>(lut.getSize()))) {
                        if (completedPixels) {
                            *completedPixels = completed;
                        }
                        return false;
                    }
                    std::memcpy(image.pixels.data() + offset, staging, bytes);
                    completed = offset + count;
                }
                if (completedPixels) {
                    *completedPixels = pixel_count;
                }
                return true;
            } catch (const std::exception&) {
                if (completedPixels) {
                    *completedPixels = completed;
                }
                return false;
            }
        } @catch (NSException*) {
            if (completedPixels) {
                *completedPixels = completed;
            }
            return false;
        }
    }
}

}
