#import <Metal/Metal.h>

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

static int gTextureCreations = 0;
static int gBufferCreations = 0;
static int gParamsBufferCreations = 0;
static int gDispatches = 0;
static NSUInteger gLastGridWidth = 0;
static bool gFailBufferAlloc = false;
static NSUInteger gMockMaxBufferLength = 64ull * 1024 * 1024;

static void resetCounters() {
    gTextureCreations = 0;
    gBufferCreations = 0;
    gParamsBufferCreations = 0;
    gDispatches = 0;
    gLastGridWidth = 0;
}

@interface BoundsTestBuffer : NSObject {
    std::vector<uint8_t> _storage;
}
- (instancetype)initWithLength:(NSUInteger)length;
- (instancetype)initWithBytes:(const void*)bytes length:(NSUInteger)length;
- (void*)contents;
@end

@implementation BoundsTestBuffer
- (instancetype)initWithLength:(NSUInteger)length {
    if ((self = [super init])) {
        _storage.assign(length, 0);
    }
    return self;
}
- (instancetype)initWithBytes:(const void*)bytes length:(NSUInteger)length {
    if ((self = [super init])) {
        const auto* src = static_cast<const uint8_t*>(bytes);
        _storage.assign(src, src + length);
    }
    return self;
}
- (void*)contents {
    return _storage.empty() ? nullptr : _storage.data();
}
@end

@interface BoundsTestTexture : NSObject
- (void)replaceRegion:(MTLRegion)region
          mipmapLevel:(NSUInteger)level
                slice:(NSUInteger)slice
            withBytes:(const void*)pixelBytes
          bytesPerRow:(NSUInteger)bytesPerRow
        bytesPerImage:(NSUInteger)bytesPerImage;
@end

@implementation BoundsTestTexture
- (void)replaceRegion:(MTLRegion)region
          mipmapLevel:(NSUInteger)level
                slice:(NSUInteger)slice
            withBytes:(const void*)pixelBytes
          bytesPerRow:(NSUInteger)bytesPerRow
        bytesPerImage:(NSUInteger)bytesPerImage {
    (void)region;
    (void)level;
    (void)slice;
    (void)pixelBytes;
    (void)bytesPerRow;
    (void)bytesPerImage;
}
@end

@interface BoundsTestEncoder : NSObject
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state;
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index;
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index;
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup;
- (void)endEncoding;
@end

@implementation BoundsTestEncoder
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state { (void)state; }
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    (void)buffer;
    (void)offset;
    (void)index;
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    (void)texture;
    (void)index;
}
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    (void)threadsPerThreadgroup;
    ++gDispatches;
    gLastGridWidth = threadsPerGrid.width;
}
- (void)endEncoding {}
@end

@interface BoundsTestCommandBuffer : NSObject
- (id<MTLComputeCommandEncoder>)computeCommandEncoder;
- (void)commit;
- (void)waitUntilCompleted;
- (MTLCommandBufferStatus)status;
@end

@implementation BoundsTestCommandBuffer
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    return (id<MTLComputeCommandEncoder>)[BoundsTestEncoder new];
}
- (void)commit {}
- (void)waitUntilCompleted {}
- (MTLCommandBufferStatus)status {
    return MTLCommandBufferStatusCompleted;
}
@end

@interface BoundsTestCommandQueue : NSObject
- (id<MTLCommandBuffer>)commandBuffer;
@end

@implementation BoundsTestCommandQueue
- (id<MTLCommandBuffer>)commandBuffer {
    return (id<MTLCommandBuffer>)[BoundsTestCommandBuffer new];
}
@end

@interface BoundsTestPipelineState : NSObject
- (NSUInteger)maxTotalThreadsPerThreadgroup;
@end

@implementation BoundsTestPipelineState
- (NSUInteger)maxTotalThreadsPerThreadgroup {
    return 256;
}
@end

@interface BoundsTestDevice : NSObject
- (NSUInteger)maxBufferLength;
- (id<MTLCommandQueue>)newCommandQueue;
- (id<MTLLibrary>)newLibraryWithSource:(NSString*)source options:(MTLCompileOptions*)options error:(NSError**)error;
- (id<MTLFunction>)newFunctionWithName:(NSString*)name;
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError**)error;
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor*)descriptor;
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options;
- (id<MTLBuffer>)newBufferWithBytes:(const void*)pointer length:(NSUInteger)length options:(MTLResourceOptions)options;
@end

@implementation BoundsTestDevice
- (NSUInteger)maxBufferLength {
    return gMockMaxBufferLength;
}
- (id<MTLCommandQueue>)newCommandQueue {
    return (id<MTLCommandQueue>)[BoundsTestCommandQueue new];
}
- (id<MTLLibrary>)newLibraryWithSource:(NSString*)source options:(MTLCompileOptions*)options error:(NSError**)error {
    (void)source;
    (void)options;
    (void)error;
    return (id<MTLLibrary>)[BoundsTestDevice new];
}
- (id<MTLFunction>)newFunctionWithName:(NSString*)name {
    (void)name;
    return (id<MTLFunction>)[NSObject new];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError**)error {
    (void)function;
    (void)error;
    return (id<MTLComputePipelineState>)[BoundsTestPipelineState new];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor*)descriptor {
    (void)descriptor;
    ++gTextureCreations;
    return (id<MTLTexture>)[BoundsTestTexture new];
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    (void)options;
    ++gBufferCreations;
    if (gFailBufferAlloc) {
        return nil;
    }
    return (id<MTLBuffer>)[[BoundsTestBuffer alloc] initWithLength:length];
}
- (id<MTLBuffer>)newBufferWithBytes:(const void*)pointer length:(NSUInteger)length options:(MTLResourceOptions)options {
    (void)options;
    ++gParamsBufferCreations;
    return (id<MTLBuffer>)[[BoundsTestBuffer alloc] initWithBytes:pointer length:length];
}
@end

static id<MTLDevice> createBoundsTestDevice() {
    return (id<MTLDevice>)[BoundsTestDevice new];
}

#define MTLCreateSystemDefaultDevice createBoundsTestDevice
#include "../src/gpu/metal_lut.mm"
#undef MTLCreateSystemDefaultDevice

static void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << std::endl;
        std::exit(1);
    }
}

int main() {
    sony2fuji::LUT3D lut;
    const auto loaded = lut.loadFromData(
        "LUT_3D_SIZE 2\n"
        "0 0 0\n1 0 0\n0 1 0\n1 1 0\n"
        "0 0 1\n1 0 1\n0 1 1\n1 1 1\n");
    require(loaded == sony2fuji::ErrorCode::Success, "2x2x2 LUT loads from memory");

    // 1. Baseline positive: single pixel succeeds via mock device.
    resetCounters();
    gFailBufferAlloc = false;
    sony2fuji::RGB pixel(0.25f, 0.5f, 0.75f);
    size_t completed = 999;
    require(sony2fuji::applyLutMetalPixels(lut, &pixel, 1, &completed),
            "baseline applyLutMetalPixels(1) succeeds");
    require(completed == 1, "baseline completed == 1");
    require(gTextureCreations == 1 && gBufferCreations == 1 && gDispatches == 1 && gLastGridWidth == 1,
            "baseline creates 1 texture, 1 buffer, and dispatches 1 grid thread");

    // 2. Entry guard > UINT32_MAX: rejects upfront before creating texture/buffer (and no OOB read).
    resetCounters();
    gFailBufferAlloc = true;
    completed = 999;
    const size_t overMax = static_cast<size_t>(std::numeric_limits<uint32_t>::max()) + 1ULL;
    require(!sony2fuji::applyLutMetalPixels(lut, &pixel, overMax, &completed),
            "applyLutMetalPixels rejects pixel_count > UINT32_MAX");
    require(completed == 0, "applyLutMetalPixels resets completedPixels to 0 on rejection");
    require(gTextureCreations == 0 && gBufferCreations == 0 && gDispatches == 0,
            "applyLutMetalPixels rejects > UINT32_MAX before creating Metal texture/buffer");

    // Zero pixel count and nullptr pixels must also be rejected cleanly.
    require(!sony2fuji::applyLutMetalPixels(lut, &pixel, 0, &completed),
            "applyLutMetalPixels rejects pixel_count == 0");
    require(!sony2fuji::applyLutMetalPixels(lut, nullptr, 1, &completed),
            "applyLutMetalPixels rejects null pixels");

    // 3. runCompute guard > UINT32_MAX (including UINT32_MAX + 2 which would truncate to 1 in uint32_t).
    resetCounters();
    gFailBufferAlloc = false;
    MetalContext* ctx = getMetalContext();
    require(ctx != nullptr, "getMetalContext returns initialized mock context");
    id<MTLBuffer> dummyBuf = (id<MTLBuffer>)[[BoundsTestBuffer alloc] initWithLength:sizeof(sony2fuji::RGB)];
    id<MTLTexture> dummyTex = (id<MTLTexture>)[BoundsTestTexture new];
    require(!runCompute(*ctx, dummyBuf, dummyTex, overMax, 2),
            "runCompute rejects UINT32_MAX + 1");
    require(!runCompute(*ctx, dummyBuf, dummyTex, overMax + 1ULL, 2),
            "runCompute rejects UINT32_MAX + 2 (no uint32 truncation to 1)");
    require(!runCompute(*ctx, dummyBuf, dummyTex, 0, 2),
            "runCompute rejects pixel_count == 0");
    require(gParamsBufferCreations == 0 && gDispatches == 0,
            "runCompute rejection allocates no params buffer and performs no dispatch");

    // 4. Degenerate maxBufferLength < sizeof(RGB) yields tile_pixels == 0 and returns false cleanly.
    resetCounters();
    gMockMaxBufferLength = 4;
    require(!sony2fuji::applyLutMetalPixels(lut, &pixel, 1, &completed),
            "applyLutMetalPixels rejects tile_pixels == 0 when maxBufferLength < sizeof(RGB)");
    gMockMaxBufferLength = 64ull * 1024 * 1024;

    return 0;
}
