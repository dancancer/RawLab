#import <Metal/Metal.h>

#include <cstdlib>
#include <iostream>

// 替身只实现初始化使用的消息，测试不要求宿主机有 Metal 硬件。
@interface LutInitDevice : NSObject
- (id<MTLCommandQueue>)newCommandQueue;
- (id<MTLLibrary>)newLibraryWithSource:(NSString*)source options:(MTLCompileOptions*)options error:(NSError**)error;
- (id<MTLFunction>)newFunctionWithName:(NSString*)name;
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError**)error;
@end

@implementation LutInitDevice
- (id<MTLCommandQueue>)newCommandQueue { return (id<MTLCommandQueue>)[NSObject new]; }
- (id<MTLLibrary>)newLibraryWithSource:(NSString*)source options:(MTLCompileOptions*)options error:(NSError**)error {
    return (id<MTLLibrary>)[LutInitDevice new];
}
- (id<MTLFunction>)newFunctionWithName:(NSString*)name { return (id<MTLFunction>)[NSObject new]; }
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)function error:(NSError**)error {
    return (id<MTLComputePipelineState>)[NSObject new];
}
@end

static int deviceAttempts = 0;
static id<MTLDevice> createTestDevice() {
    ++deviceAttempts;
    return deviceAttempts == 1 ? nil : (id<MTLDevice>)[LutInitDevice new];
}

// 仅此测试翻译单元替换设备工厂，直接执行真实私有初始化代码，不改变公共 ABI。
#define MTLCreateSystemDefaultDevice createTestDevice
#include "../src/gpu/metal_lut.mm"
#undef MTLCreateSystemDefaultDevice

static void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << std::endl;
        std::exit(1);
    }
}

int main() {
    require(getMetalContext() == nullptr, "first Metal device failure returns no context");
    auto* recovered = getMetalContext();
    require(recovered != nullptr, "second Metal call retries instead of caching initialization failure");
    require(recovered->queue != nil && recovered->pipeline != nil, "retry publishes a complete Metal context");
    require(deviceAttempts == 2, "failed Metal initialization is attempted again");
    require(getMetalContext() == recovered && deviceAttempts == 2, "successful Metal context remains cached");
    return 0;
}
