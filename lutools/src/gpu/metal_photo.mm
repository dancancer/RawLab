#include "gpu/photo_gpu.h"
#include "gpu/metal_dcp_shader.h"
#include "core/photo_lut.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <vector>

#if defined(__APPLE__)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

namespace {

using sony2fuji::ColorConverter;
using sony2fuji::ColorSpace;
using sony2fuji::ImageData;
using sony2fuji::LUT3D;
using sony2fuji::RGB;
using sony2fuji::DcpLook;

static_assert(sizeof(RGB) == sizeof(float) * 3, "RGB must remain packed for Metal buffers");

// All values are scalar or scalar arrays so the Objective-C++ and Metal layouts
// are identical without relying on float3's 16-byte constant-buffer alignment.
struct PhotoParams {
    uint32_t srcWidth;
    uint32_t srcHeight;
    uint32_t dstWidth;
    uint32_t dstHeight;
    uint32_t lutSize;
    uint32_t useLut;
    uint32_t toneEnabled;
    float matrix[9];
    float lutMatrix[9];
    float exposureScale;
    float wbR;
    float wbG;
    float wbB;
    float lutStrength;
    float contrast;
    float saturation;
    float highlights;
    float shadows;
    float toneCurve;
    float noiseReduction;
    float sharpening;
    float domainMin[3];
    float domainMax[3];
    uint32_t inputIsFLog;
    uint32_t outputIsLog;
    uint32_t outputIsFLog;
};
static_assert(sizeof(PhotoParams) == 184, "Photo Metal parameter layout");

struct MetalContext {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLComputePipelineState> resizePipeline = nil;
    id<MTLComputePipelineState> matrixExposurePipeline = nil;
    id<MTLComputePipelineState> baseLutPipeline = nil;
    id<MTLComputePipelineState> baseDcpPipeline = nil;
    id<MTLComputePipelineState> tonePipeline = nil;
    id<MTLComputePipelineState> noisePipeline = nil;
    id<MTLComputePipelineState> sharpenPipeline = nil;
    bool ready = false;
};

struct CachedLUT {
    const LUT3D* key = nullptr;
    std::shared_ptr<LUT3D> owner;
    id<MTLTexture> texture = nil;
    uint64_t lastUsed = 0;
    int size = 0;
    RGB domainMin;
    RGB domainMax;
};

constexpr size_t kMaxCachedLUTs = 8;
std::mutex gLUTCacheMutex;
std::vector<CachedLUT> gLUTCache;
uint64_t gLUTClock = 0;

struct DcpParams {
    float input[9], output[9], exposure;
    uint32_t calibration[4], look[4], lookOffset, toneOffset;
};
static_assert(sizeof(DcpParams) == 116, "DCP Metal parameter layout");
struct CachedDcp {
    std::shared_ptr<const DcpLook> owner;
    id<MTLBuffer> params = nil, data = nil;
};
std::mutex gDcpCacheMutex;
CachedDcp gDcpCache;

static const char* kShaderSource = R"metal(
#include <metal_stdlib>
using namespace metal;

struct Params {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
    uint lutSize;
    uint useLut;
    uint toneEnabled;
    float matrix[9];
    float lutMatrix[9];
    float exposureScale;
    float wbR;
    float wbG;
    float wbB;
    float lutStrength;
    float contrast;
    float saturation;
    float highlights;
    float shadows;
    float toneCurve;
    float noiseReduction;
    float sharpening;
    float domainMin[3];
    float domainMax[3];
    uint inputIsFLog;
    uint outputIsLog;
    uint outputIsFLog;
};

inline float3 lerp3(float3 a, float3 b, float t) {
    return a + (b - a) * t;
}

inline float clamp01(float value) {
    return clamp(value, 0.0f, 1.0f);
}

inline float3 pixelAt(device const packed_float3* pixels, uint width, uint x, uint y) {
    return float3(pixels[y * width + x]);
}

inline float3 sampleBilinear(
    device const packed_float3* pixels,
    uint width,
    uint height,
    float x,
    float y
) {
    uint x0 = uint(floor(x));
    uint y0 = uint(floor(y));
    uint x1 = min(x0 + 1u, width - 1u);
    uint y1 = min(y0 + 1u, height - 1u);
    float tx = x - float(x0);
    float ty = y - float(y0);
    float3 c00 = pixelAt(pixels, width, x0, y0);
    float3 c10 = pixelAt(pixels, width, x1, y0);
    float3 c01 = pixelAt(pixels, width, x0, y1);
    float3 c11 = pixelAt(pixels, width, x1, y1);
    float3 cx0 = lerp3(c00, c10, tx);
    float3 cx1 = lerp3(c01, c11, tx);
    return lerp3(cx0, cx1, ty);
}

inline float3 matrixRGB(float3 value, constant Params& params) {
    return float3(
        params.matrix[0] * value.r + params.matrix[1] * value.g + params.matrix[2] * value.b,
        params.matrix[3] * value.r + params.matrix[4] * value.g + params.matrix[5] * value.b,
        params.matrix[6] * value.r + params.matrix[7] * value.g + params.matrix[8] * value.b
    );
}

inline float3 lutMatrixRGB(float3 value, constant Params& params) {
    return float3(
        params.lutMatrix[0] * value.r + params.lutMatrix[1] * value.g + params.lutMatrix[2] * value.b,
        params.lutMatrix[3] * value.r + params.lutMatrix[4] * value.g + params.lutMatrix[5] * value.b,
        params.lutMatrix[6] * value.r + params.lutMatrix[7] * value.g + params.lutMatrix[8] * value.b
    );
}

inline float srgbGamma(float linear) {
    if (linear <= 0.0031308f) {
        return 12.92f * linear;
    }
    return 1.055f * pow(linear, 1.0f / 2.4f) - 0.055f;
}

inline float neutralDisplay(float linear) {
    if (linear <= 0.0f) {
        return 0.0f;
    }
    constexpr float gray = 0.1845f;
    float shoulder = (1.0f - gray) / gray * pow(gray / linear, 1.5f);
    return srgbGamma(1.0f / (1.0f + shoulder));
}

inline float flog2(float linear) {
    constexpr float a = 5.555556f;
    constexpr float b = 0.064829f;
    constexpr float c = 0.245281f;
    constexpr float d = 0.384316f;
    constexpr float e = 8.799461f;
    constexpr float f = 0.092864f;
    constexpr float cut = 0.00088899597f;
    if (linear < cut) {
        return clamp(e * linear + f, 0.0f, 1.0f);
    }
    return clamp(log10(linear * a + b) * c + d, 0.0f, 1.0f);
}

inline float encodeLog(float linear, bool isFLog) {
    if (!isFLog) return flog2(linear);
    return clamp(linear < 0.00089f ? 8.735631f * linear + 0.092864f
        : 0.344676f * log10(0.555556f * linear + 0.009468f) + 0.790453f, 0.0f, 1.0f);
}

inline float decodeLog(float encoded, bool isFLog) {
    if (isFLog) return encoded < 0.100537775223865f ? (encoded - 0.092864f) / 8.735631f
        : (pow(10.0f, (encoded - 0.790453f) / 0.344676f) - 0.009468f) / 0.555556f;
    return encoded < 0.100686685370811f ? (encoded - 0.092864f) / 8.799461f
        : (pow(10.0f, (encoded - 0.384316f) / 0.245281f) - 0.064829f) / 5.555556f;
}

inline float3 readLUT(
    texture3d<float, access::read> lut,
    uint r,
    uint g,
    uint b
) {
    return lut.read(uint3(r, g, b)).xyz;
}

inline float3 applyLUT(
    texture3d<float, access::read> lut,
    float3 value,
    constant Params& params
) {
    float3 normalized = float3(
        clamp((value.r - params.domainMin[0]) /
            (params.domainMax[0] - params.domainMin[0]), 0.0f, 1.0f),
        clamp((value.g - params.domainMin[1]) /
            (params.domainMax[1] - params.domainMin[1]), 0.0f, 1.0f),
        clamp((value.b - params.domainMin[2]) /
            (params.domainMax[2] - params.domainMin[2]), 0.0f, 1.0f)
    );
    float3 coordinate = normalized * float(params.lutSize - 1u);
    uint r0 = min(uint(floor(coordinate.r)), params.lutSize - 1u);
    uint g0 = min(uint(floor(coordinate.g)), params.lutSize - 1u);
    uint b0 = min(uint(floor(coordinate.b)), params.lutSize - 1u);
    uint r1 = min(r0 + 1u, params.lutSize - 1u);
    uint g1 = min(g0 + 1u, params.lutSize - 1u);
    uint b1 = min(b0 + 1u, params.lutSize - 1u);
    float dr = coordinate.r - float(r0);
    float dg = coordinate.g - float(g0);
    float db = coordinate.b - float(b0);

    float3 c000 = readLUT(lut, r0, g0, b0);
    float3 c001 = readLUT(lut, r0, g0, b1);
    float3 c010 = readLUT(lut, r0, g1, b0);
    float3 c011 = readLUT(lut, r0, g1, b1);
    float3 c100 = readLUT(lut, r1, g0, b0);
    float3 c101 = readLUT(lut, r1, g0, b1);
    float3 c110 = readLUT(lut, r1, g1, b0);
    float3 c111 = readLUT(lut, r1, g1, b1);
    float3 c00 = lerp3(c000, c001, db);
    float3 c01 = lerp3(c010, c011, db);
    float3 c10 = lerp3(c100, c101, db);
    float3 c11 = lerp3(c110, c111, db);
    float3 c0 = lerp3(c00, c01, dg);
    float3 c1 = lerp3(c10, c11, dg);
    return lerp3(c0, c1, dr);
}

inline float signedPow(float value, float power) {
    return (value >= 0.0f ? 1.0f : -1.0f) * pow(abs(value), power);
}

inline float applyToneCurve(float value, float p1, float p2, float p3) {
    value = clamp01(value);
    if (value <= 0.25f) {
        return (value / 0.25f) * p1;
    }
    if (value <= 0.5f) {
        return p1 + (p2 - p1) * ((value - 0.25f) / 0.25f);
    }
    if (value <= 0.75f) {
        return p2 + (p3 - p2) * ((value - 0.5f) / 0.25f);
    }
    return p3 + (1.0f - p3) * ((value - 0.75f) / 0.25f);
}

inline float adjustShadows(float value, float shadows) {
    if (shadows == 0.0f) {
        return value;
    }
    float t = clamp(shadows, -1.0f, 1.0f);
    float gamma = t > 0.0f ? (1.0f - t * 0.5f) : (1.0f + (-t) * 0.5f);
    return pow(clamp01(value), gamma);
}

inline float adjustHighlights(float value, float highlights) {
    if (highlights == 0.0f) {
        return value;
    }
    float t = clamp(highlights, -1.0f, 1.0f);
    float inverse = 1.0f - clamp01(value);
    float gamma = t > 0.0f ? (1.0f - t * 0.5f) : (1.0f + (-t) * 0.5f);
    return 1.0f - pow(inverse, gamma);
}

inline float3 blur3x3(
    device const packed_float3* source,
    uint width,
    uint height,
    uint x,
    uint y
) {
    uint y0 = y > 0u ? y - 1u : 0u;
    uint y2 = min(height - 1u, y + 1u);
    uint x0 = x > 0u ? x - 1u : 0u;
    uint x2 = min(width - 1u, x + 1u);
    float3 row0 = pixelAt(source, width, x0, y0) +
        pixelAt(source, width, x, y0) + pixelAt(source, width, x2, y0);
    float3 row1 = pixelAt(source, width, x0, y) +
        pixelAt(source, width, x, y) + pixelAt(source, width, x2, y);
    float3 row2 = pixelAt(source, width, x0, y2) +
        pixelAt(source, width, x, y2) + pixelAt(source, width, x2, y2);
    float3 sum = row0;
    sum += row1 + row2;
    return sum / 9.0f;
}

kernel void resizeBilinear(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.dstWidth * params.dstHeight;
    if (gid >= count) {
        return;
    }
    uint x = gid % params.dstWidth;
    uint y = gid / params.dstWidth;
    float scaleX = params.dstWidth == 1u ? 0.0f :
        float(params.srcWidth - 1u) / float(params.dstWidth - 1u);
    float scaleY = params.dstHeight == 1u ? 0.0f :
        float(params.srcHeight - 1u) / float(params.dstHeight - 1u);
    float3 result = sampleBilinear(source, params.srcWidth, params.srcHeight,
        float(x) * scaleX, float(y) * scaleY);
    destination[gid] = packed_float3(result);
}

kernel void matrixExposure(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.srcWidth * params.srcHeight;
    if (gid >= count) {
        return;
    }
    float3 result = matrixRGB(float3(source[gid]), params);
    result.r *= params.exposureScale * params.wbR;
    result.g *= params.exposureScale * params.wbG;
    result.b *= params.exposureScale * params.wbB;
    destination[gid] = packed_float3(result);
}

kernel void baseAndLUT(
    constant Params& params [[buffer(0)]],
    texture3d<float, access::read> lut [[texture(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.srcWidth * params.srcHeight;
    if (gid >= count) {
        return;
    }
    float3 value = float3(source[gid]);
    float3 base = float3(neutralDisplay(value.r), neutralDisplay(value.g), neutralDisplay(value.b));
    if (params.useLut == 0u) {
        destination[gid] = packed_float3(base);
        return;
    }
    float3 gamut = lutMatrixRGB(value, params);
    float3 filmInput = float3(encodeLog(gamut.r, params.inputIsFLog != 0u),
        encodeLog(gamut.g, params.inputIsFLog != 0u), encodeLog(gamut.b, params.inputIsFLog != 0u));
    float3 film = applyLUT(lut, filmInput, params);
    if (params.outputIsLog != 0u) {
        film = float3(neutralDisplay(decodeLog(film.r, params.outputIsFLog != 0u)),
            neutralDisplay(decodeLog(film.g, params.outputIsFLog != 0u)),
            neutralDisplay(decodeLog(film.b, params.outputIsFLog != 0u)));
    }
    destination[gid] = packed_float3(lerp3(base, film, params.lutStrength));
}

kernel void toneAdjustments(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.srcWidth * params.srcHeight;
    if (gid >= count) {
        return;
    }
    float3 pixel = float3(source[gid]);
    if (params.toneEnabled == 0u) {
        destination[gid] = packed_float3(pixel);
        return;
    }
    float highlights = clamp(params.highlights, -1.0f, 1.0f);
    float shadows = clamp(params.shadows, -1.0f, 1.0f);
    if (highlights != 0.0f || shadows != 0.0f) {
        float luminance = 0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b;
        float shadowed = adjustShadows(luminance, shadows);
        float adjusted = adjustHighlights(shadowed, highlights);
        if (luminance > 0.0f) {
            float ratio = adjusted / luminance;
            pixel *= ratio;
        } else {
            pixel = float3(adjusted);
        }
    }
    if (params.toneCurve != 0.0f) {
        float curveStrength = signedPow(params.toneCurve, 1.2f);
        float p1 = clamp(0.25f - curveStrength * 0.2f, 0.0f, 1.0f);
        float p2 = clamp(0.5f + curveStrength * 0.05f, 0.0f, 1.0f);
        float p3 = clamp(0.75f + curveStrength * 0.2f, 0.0f, 1.0f);
        pixel.r = applyToneCurve(pixel.r, p1, p2, p3);
        pixel.g = applyToneCurve(pixel.g, p1, p2, p3);
        pixel.b = applyToneCurve(pixel.b, p1, p2, p3);
    }
    float contrast = clamp(params.contrast, 0.0f, 2.0f);
    float saturation = clamp(params.saturation, 0.0f, 2.0f);
    if (contrast != 1.0f || saturation != 1.0f) {
        pixel = (pixel - 0.5f) * contrast + 0.5f;
        float luminance = 0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b;
        pixel = float3(
            luminance + (pixel.r - luminance) * saturation,
            luminance + (pixel.g - luminance) * saturation,
            luminance + (pixel.b - luminance) * saturation
        );
    }
    destination[gid] = packed_float3(pixel);
}

kernel void noiseReduction(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.srcWidth * params.srcHeight;
    if (gid >= count) {
        return;
    }
    uint x = gid % params.srcWidth;
    uint y = gid / params.srcWidth;
    float strength = clamp(params.noiseReduction, 0.0f, 1.0f);
    float blend = strength * 0.4f;
    float3 current = float3(source[gid]);
    float3 blurred = blur3x3(source, params.srcWidth, params.srcHeight, x, y);
    destination[gid] = packed_float3(lerp3(current, blurred, blend));
}

kernel void sharpen(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.srcWidth * params.srcHeight;
    if (gid >= count) {
        return;
    }
    uint x = gid % params.srcWidth;
    uint y = gid / params.srcWidth;
    float strength = clamp(params.sharpening, 0.0f, 2.0f);
    float3 current = float3(source[gid]);
    float3 blurred = blur3x3(source, params.srcWidth, params.srcHeight, x, y);
    current = clamp(current + strength * (current - blurred), 0.0f, 1.0f);
    destination[gid] = packed_float3(current);
}
)metal";

id<MTLComputePipelineState> makePipeline(
    id<MTLDevice> device,
    id<MTLLibrary> library,
    NSString* name
) {
    id<MTLFunction> function = [library newFunctionWithName:name];
    if (!function) {
        return nil;
    }
    NSError* error = nil;
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:function error:&error];
    return error || !pipeline ? nil : pipeline;
}

MetalContext& metalContext() {
    static MetalContext context;
    static std::once_flag once;
    std::call_once(once, [] {
        @autoreleasepool {
            context.device = MTLCreateSystemDefaultDevice();
            if (!context.device) {
                return;
            }
            context.queue = [context.device newCommandQueue];
            if (!context.queue) {
                return;
            }
            NSString* source = [NSString stringWithUTF8String:kShaderSource];
            NSError* error = nil;
            id<MTLLibrary> library =
                [context.device newLibraryWithSource:source options:nil error:&error];
            if (error || !library) {
                return;
            }
            context.resizePipeline = makePipeline(context.device, library, @"resizeBilinear");
            context.matrixExposurePipeline = makePipeline(context.device, library, @"matrixExposure");
            context.baseLutPipeline = makePipeline(context.device, library, @"baseAndLUT");
            context.tonePipeline = makePipeline(context.device, library, @"toneAdjustments");
            context.noisePipeline = makePipeline(context.device, library, @"noiseReduction");
            context.sharpenPipeline = makePipeline(context.device, library, @"sharpen");
            context.ready = context.resizePipeline && context.matrixExposurePipeline &&
                context.baseLutPipeline && context.tonePipeline && context.noisePipeline &&
                context.sharpenPipeline;
            if (@available(macOS 15.0, iOS 18.0, *)) {
                MTLCompileOptions* options = [MTLCompileOptions new];
                options.mathMode = MTLMathModeSafe;
                NSString* dcpSource = [source stringByAppendingString:[NSString stringWithUTF8String:kDcpShaderSource]];
                error = nil;
                id<MTLLibrary> dcpLibrary = [context.device newLibraryWithSource:dcpSource options:options error:&error];
                if (dcpLibrary && !error) context.baseDcpPipeline = makePipeline(context.device, dcpLibrary, @"baseAndDcp");
                else NSLog(@"RawLab DCP Metal compilation failed: %@", error);
            }
        }
    });
    return context;
}

bool checkedCount(uint32_t width, uint32_t height, size_t* count) {
    if (!count || width == 0 || height == 0) {
        return false;
    }
    const uint64_t value = static_cast<uint64_t>(width) * height;
    if (value > std::numeric_limits<size_t>::max() || value > UINT32_MAX) {
        return false;
    }
    *count = static_cast<size_t>(value);
    return true;
}

id<MTLBuffer> makeBuffer(id<MTLDevice> device, size_t length) {
    if (length == 0 || length > std::numeric_limits<NSUInteger>::max()) {
        return nil;
    }
    return [device newBufferWithLength:length options:MTLResourceStorageModeShared];
}

id<MTLBuffer> makeParamsBuffer(id<MTLDevice> device, const PhotoParams& params) {
    id<MTLBuffer> buffer = makeBuffer(device, sizeof(params));
    if (buffer) {
        std::memcpy(buffer.contents, &params, sizeof(params));
    }
    return buffer;
}

bool getCachedDcp(MetalContext& context, const std::shared_ptr<const DcpLook>& look, CachedDcp& result) {
    std::lock_guard<std::mutex> lock(gDcpCacheMutex);
    if (gDcpCache.owner == look && gDcpCache.params && gDcpCache.data) { result = gDcpCache; return true; }
    const auto& stages = look->stages();
    DcpParams params{};
    for (size_t i = 0; i < 9; ++i) { params.input[i] = stages.input[i]; params.output[i] = stages.output[i]; }
    params.exposure = stages.exposure;
    std::vector<float> data;
    data.reserve((stages.calibration.entries.size() + stages.look.entries.size()) * 3 + stages.tone.size());
    auto append = [&](const sony2fuji::DcpTable& table, uint32_t* dimensions) {
        dimensions[0] = table.hues; dimensions[1] = table.saturations;
        dimensions[2] = table.values; dimensions[3] = table.encoding;
        for (const auto& entry : table.entries) { data.push_back(entry.r); data.push_back(entry.g); data.push_back(entry.b); }
    };
    append(stages.calibration, params.calibration);
    params.lookOffset = static_cast<uint32_t>(data.size());
    append(stages.look, params.look);
    params.toneOffset = static_cast<uint32_t>(data.size());
    for (double value : stages.tone) data.push_back(static_cast<float>(value));
    CachedDcp cached;
    cached.owner = look;
    cached.params = makeBuffer(context.device, sizeof(params));
    cached.data = makeBuffer(context.device, data.size() * sizeof(float));
    if (!cached.params || !cached.data) return false;
    std::memcpy(cached.params.contents, &params, sizeof(params));
    std::memcpy(cached.data.contents, data.data(), data.size() * sizeof(float));
    gDcpCache = cached;
    result = cached;
    return true;
}

id<MTLTexture> makeLUTTexture(id<MTLDevice> device, const LUT3D& lut) {
    const int size = lut.getSize();
    if (size < 2 || size > 256) {
        return nil;
    }
    const size_t voxelCount = static_cast<size_t>(size) * size * size;
    std::vector<float> values(voxelCount * 4);
    size_t offset = 0;
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                const RGB value = lut.getValue(r, g, b);
                values[offset++] = value.r;
                values[offset++] = value.g;
                values[offset++] = value.b;
                values[offset++] = 1.0f;
            }
        }
    }

    MTLTextureDescriptor* descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.textureType = MTLTextureType3D;
    descriptor.pixelFormat = MTLPixelFormatRGBA32Float;
    descriptor.width = size;
    descriptor.height = size;
    descriptor.depth = size;
    descriptor.mipmapLevelCount = 1;
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (!texture) {
        return nil;
    }
    MTLRegion region = MTLRegionMake3D(0, 0, 0, size, size, size);
    const NSUInteger bytesPerRow = static_cast<NSUInteger>(size) * 4 * sizeof(float);
    const NSUInteger bytesPerImage = bytesPerRow * static_cast<NSUInteger>(size);
    [texture replaceRegion:region
              mipmapLevel:0
                    slice:0
                withBytes:values.data()
              bytesPerRow:bytesPerRow
            bytesPerImage:bytesPerImage];
    return texture;
}

bool getCachedLUT(
    MetalContext& context,
    const std::shared_ptr<LUT3D>& lut,
    CachedLUT* result
) {
    if (!lut || !lut->isValid() || !result) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(gLUTCacheMutex);
        for (auto& cached : gLUTCache) {
            if (cached.key == lut.get()) {
                cached.lastUsed = ++gLUTClock;
                *result = cached;
                return true;
            }
        }
    }

    id<MTLTexture> texture = makeLUTTexture(context.device, *lut);
    if (!texture) {
        return false;
    }
    CachedLUT created;
    created.key = lut.get();
    created.owner = lut;
    created.texture = texture;
    created.lastUsed = 0;
    created.size = lut->getSize();
    created.domainMin = lut->domainMin();
    created.domainMax = lut->domainMax();

    std::lock_guard<std::mutex> lock(gLUTCacheMutex);
    for (auto& cached : gLUTCache) {
        if (cached.key == lut.get()) {
            cached.lastUsed = ++gLUTClock;
            *result = cached;
            return true;
        }
    }
    created.lastUsed = ++gLUTClock;
    if (gLUTCache.size() >= kMaxCachedLUTs) {
        const auto oldest = std::min_element(
            gLUTCache.begin(), gLUTCache.end(),
            [](const CachedLUT& a, const CachedLUT& b) { return a.lastUsed < b.lastUsed; }
        );
        gLUTCache.erase(oldest);
    }
    gLUTCache.push_back(created);
    *result = created;
    return true;
}

PhotoParams makeParams(
    uint32_t srcWidth,
    uint32_t srcHeight,
    uint32_t dstWidth,
    uint32_t dstHeight,
    ColorConverter::Matrix3x3 matrix,
    ColorConverter::Matrix3x3 lutMatrix,
    const sony2fuji_request& request,
    const RGB& relativeWB,
    const CachedLUT* cachedLUT,
    float lutStrength
) {
    PhotoParams params{};
    params.srcWidth = srcWidth;
    params.srcHeight = srcHeight;
    params.dstWidth = dstWidth;
    params.dstHeight = dstHeight;
    params.lutSize = cachedLUT ? static_cast<uint32_t>(cachedLUT->size) : 0;
    params.useLut = cachedLUT ? 1u : 0u;
    params.toneEnabled =
        request.exposure_ev != 0.0f || request.brightness != 1.0f ||
        request.contrast != 1.0f || request.saturation != 1.0f ||
        request.temperature != 6500.0f || request.tint != 0.0f ||
        request.wb_mode == SONY2FUJI_WB_CUSTOM ||
        request.highlights != 0.0f || request.shadows != 0.0f ||
        request.tone_curve != 0.0f;
    size_t matrixOffset = 0;
    for (const auto& row : matrix) {
        for (float value : row) {
            params.matrix[matrixOffset++] = value;
        }
    }
    matrixOffset = 0;
    for (const auto& row : lutMatrix) {
        for (float value : row) {
            params.lutMatrix[matrixOffset++] = value;
        }
    }
    params.exposureScale = std::exp2(request.exposure_ev) * request.brightness;
    params.wbR = relativeWB.r;
    params.wbG = relativeWB.g;
    params.wbB = relativeWB.b;
    params.lutStrength = lutStrength;
    params.contrast = request.contrast;
    params.saturation = request.saturation;
    params.highlights = request.highlights;
    params.shadows = request.shadows;
    params.toneCurve = request.tone_curve;
    params.noiseReduction = request.noise_reduction;
    params.sharpening = request.sharpening;
    if (cachedLUT) {
        params.inputIsFLog = cachedLUT->owner->inputTransfer() == sony2fuji::LUTTransfer::FLog;
        params.outputIsLog = cachedLUT->owner->outputTransfer() != sony2fuji::LUTTransfer::Display;
        params.outputIsFLog = cachedLUT->owner->outputTransfer() == sony2fuji::LUTTransfer::FLog;
        params.domainMin[0] = cachedLUT->domainMin.r;
        params.domainMin[1] = cachedLUT->domainMin.g;
        params.domainMin[2] = cachedLUT->domainMin.b;
        params.domainMax[0] = cachedLUT->domainMax.r;
        params.domainMax[1] = cachedLUT->domainMax.g;
        params.domainMax[2] = cachedLUT->domainMax.b;
    }
    return params;
}

id<MTLComputeCommandEncoder> beginKernel(
    id<MTLCommandBuffer> commandBuffer,
    id<MTLComputePipelineState> pipeline,
    id<MTLBuffer> params,
    id<MTLBuffer> source,
    id<MTLBuffer> destination,
    id<MTLTexture> lut,
    size_t count,
    const CachedDcp* dcp = nullptr,
    id<MTLBuffer> invalid = nil
) {
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder || !pipeline || !params || !source || !destination || count == 0) {
        return nil;
    }
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:params offset:0 atIndex:0];
    [encoder setBuffer:source offset:0 atIndex:1];
    [encoder setBuffer:destination offset:0 atIndex:2];
    [encoder setTexture:lut atIndex:0];
    if (dcp) {
        [encoder setBuffer:dcp->params offset:0 atIndex:3];
        [encoder setBuffer:dcp->data offset:0 atIndex:4];
        [encoder setBuffer:invalid offset:0 atIndex:5];
    }
    const NSUInteger maxThreads = pipeline.maxTotalThreadsPerThreadgroup;
    if (maxThreads == 0) {
        [encoder endEncoding];
        return nil;
    }
    const NSUInteger threadgroup = std::min<NSUInteger>(256, maxThreads);
    [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(count), 1, 1)
        threadsPerThreadgroup:MTLSizeMake(threadgroup, 1, 1)];
    return encoder;
}

bool finishKernel(id<MTLComputeCommandEncoder> encoder) {
    if (!encoder) {
        return false;
    }
    [encoder endEncoding];
    return true;
}

bool encodeKernel(
    id<MTLCommandBuffer> commandBuffer,
    id<MTLComputePipelineState> pipeline,
    id<MTLBuffer> params,
    id<MTLBuffer> source,
    id<MTLBuffer> destination,
    id<MTLTexture> lut,
    size_t count,
    const CachedDcp* dcp = nullptr,
    id<MTLBuffer> invalid = nil
) {
    return finishKernel(beginKernel(
        commandBuffer, pipeline, params, source, destination, lut, count, dcp, invalid
    ));
}

bool renderPhotoMetalImpl(
    const ImageData& input,
    ColorSpace inputSpace,
    const sony2fuji_request& request,
    const std::shared_ptr<LUT3D>& lut,
    const RGB& relativeWB,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output,
    const std::shared_ptr<const DcpLook>& dcp
) {
    if (input.width <= 0 || input.height <= 0 || targetWidth == 0 || targetHeight == 0 ||
        input.pixels.size() != static_cast<size_t>(input.width) * input.height ||
        !std::isfinite(request.exposure_ev) || !std::isfinite(request.brightness) ||
        !std::isfinite(request.contrast) || !std::isfinite(request.saturation) ||
        !std::isfinite(request.temperature) || !std::isfinite(request.tint) ||
        !std::isfinite(request.highlights) || !std::isfinite(request.shadows) ||
        !std::isfinite(request.tone_curve) || !std::isfinite(request.noise_reduction) ||
        !std::isfinite(request.sharpening) || !std::isfinite(request.lut_strength) ||
        !std::isfinite(relativeWB.r) || !std::isfinite(relativeWB.g) ||
        !std::isfinite(relativeWB.b)) {
        return false;
    }
    size_t inputCount = 0;
    size_t targetCount = 0;
    if (!checkedCount(static_cast<uint32_t>(input.width), static_cast<uint32_t>(input.height), &inputCount) ||
        !checkedCount(targetWidth, targetHeight, &targetCount)) {
        return false;
    }

    MetalContext& context = metalContext();
    if (!context.ready) {
        return false;
    }

    const float lutStrength = std::max(0.0f, std::min(2.0f, request.lut_strength));
    const bool useLUT = lut && lutStrength > 0.0f;
    const bool useDcp = dcp && lutStrength > 0.0f;
    if (useDcp && (useLUT || !context.baseDcpPipeline)) return false;
    CachedDcp cachedDcp;
    id<MTLBuffer> invalid = nil;
    if (useDcp) {
        if (!getCachedDcp(context, dcp, cachedDcp)) return false;
        invalid = makeBuffer(context.device, sizeof(uint32_t));
        if (!invalid) return false;
        *static_cast<uint32_t*>(invalid.contents) = 0;
    }
    CachedLUT cachedLUT;
    if (useLUT && !getCachedLUT(context, lut, &cachedLUT)) {
        return false;
    }

    ColorConverter::Matrix3x3 toSRGB;
    ColorConverter::Matrix3x3 toFGamut;
    try {
        if (inputSpace == ColorSpace::sRGB) {
            toSRGB = ColorConverter::Matrix3x3{{
                {1.0f, 0.0f, 0.0f},
                {0.0f, 1.0f, 0.0f},
                {0.0f, 0.0f, 1.0f}
            }};
        } else {
            toSRGB = ColorConverter::getConversionMatrix(inputSpace, ColorSpace::sRGB);
        }
        toFGamut = sony2fuji::photoLUTInputMatrix(useLUT ? lut->inputTransfer() : sony2fuji::LUTTransfer::FLog2);
    } catch (...) {
        return false;
    }

    const uint32_t inputWidth = static_cast<uint32_t>(input.width);
    const uint32_t inputHeight = static_cast<uint32_t>(input.height);
    const bool earlyResize = request.intent == SONY2FUJI_INTENT_PREVIEW &&
        request.sharpening <= 0.0f && (targetWidth != inputWidth || targetHeight != inputHeight);
    const uint32_t processingWidth = earlyResize ? targetWidth : inputWidth;
    const uint32_t processingHeight = earlyResize ? targetHeight : inputHeight;
    size_t processingCount = 0;
    if (!checkedCount(processingWidth, processingHeight, &processingCount)) {
        return false;
    }

    const size_t inputBytes = inputCount * sizeof(RGB);
    const size_t processingBytes = processingCount * sizeof(RGB);
    // Keep the input immutable and alternate every source-size stage through two buffers.
    id<MTLBuffer> inputBuffer = makeBuffer(context.device, inputBytes);
    id<MTLBuffer> processingA = makeBuffer(context.device, processingBytes);
    id<MTLBuffer> processingB = makeBuffer(context.device, processingBytes);
    if (!inputBuffer || !processingA || !processingB) {
        return false;
    }
    std::memcpy(inputBuffer.contents, input.pixels.data(), inputBytes);

    id<MTLCommandBuffer> commandBuffer = [context.queue commandBuffer];
    if (!commandBuffer) {
        return false;
    }

    id<MTLBuffer> currentBuffer = inputBuffer;
    id<MTLBuffer> nextBuffer = processingA;
    id<MTLBuffer> earlyResizeParams = nil;
    if (earlyResize) {
        const PhotoParams params = makeParams(
            inputWidth, inputHeight, targetWidth, targetHeight, toSRGB, toFGamut,
            request, relativeWB, useLUT ? &cachedLUT : nullptr, lutStrength
        );
        earlyResizeParams = makeParamsBuffer(context.device, params);
        if (!earlyResizeParams || !encodeKernel(
            commandBuffer, context.resizePipeline, earlyResizeParams, currentBuffer,
            processingA, nil, processingCount
        )) {
            return false;
        }
        currentBuffer = processingA;
        nextBuffer = processingB;
    }

    const PhotoParams params = makeParams(
        processingWidth, processingHeight, targetWidth, targetHeight, toSRGB, toFGamut,
        request, relativeWB, useLUT ? &cachedLUT : nullptr, lutStrength
    );
    id<MTLBuffer> paramsBuffer = makeParamsBuffer(context.device, params);
    if (!paramsBuffer) {
        return false;
    }

    auto runProcessingKernel = [&](id<MTLComputePipelineState> pipeline, id<MTLTexture> texture, const CachedDcp* stages = nullptr) {
        if (!encodeKernel(commandBuffer, pipeline, paramsBuffer, currentBuffer, nextBuffer,
            texture, processingCount, stages, stages ? invalid : nil)) {
            return false;
        }
        id<MTLBuffer> completed = currentBuffer;
        currentBuffer = nextBuffer;
        nextBuffer = completed;
        return true;
    };
    if (!runProcessingKernel(context.matrixExposurePipeline, nil) ||
        !runProcessingKernel(useDcp ? context.baseDcpPipeline : context.baseLutPipeline,
            useLUT ? cachedLUT.texture : nil, useDcp ? &cachedDcp : nullptr) ||
        !runProcessingKernel(context.tonePipeline, nil)) {
        return false;
    }

    if (request.noise_reduction > 0.0f) {
        if (!runProcessingKernel(context.noisePipeline, nil)) {
            return false;
        }
    }
    if (request.sharpening > 0.0f) {
        if (!runProcessingKernel(context.sharpenPipeline, nil)) {
            return false;
        }
    }

    id<MTLBuffer> finalBuffer = currentBuffer;
    if (processingWidth != targetWidth || processingHeight != targetHeight) {
        finalBuffer = makeBuffer(context.device, targetCount * sizeof(RGB));
        if (!finalBuffer || !encodeKernel(commandBuffer, context.resizePipeline, paramsBuffer,
            currentBuffer, finalBuffer, nil, targetCount)) {
            return false;
        }
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    if (commandBuffer.status != MTLCommandBufferStatusCompleted) {
        return false;
    }
    if (useDcp && *static_cast<const uint32_t*>(invalid.contents) != 0) return false;
    ImageData result(static_cast<int>(targetWidth), static_cast<int>(targetHeight));
    std::memcpy(result.pixels.data(), finalBuffer.contents, targetCount * sizeof(RGB));
    output = std::move(result);
    return true;
}

} // namespace

namespace sony2fuji {

bool renderPhotoMetal(
    const ImageData& input,
    ColorSpace inputSpace,
    const sony2fuji_request& request,
    const std::shared_ptr<LUT3D>& lut,
    const RGB& relativeWB,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output,
    const std::shared_ptr<const DcpLook>& dcp
) {
    bool result = false;
    @try {
        @autoreleasepool {
            try {
                result = renderPhotoMetalImpl(
                    input, inputSpace, request, lut, relativeWB,
                    targetWidth, targetHeight, output, dcp
                );
            } catch (...) {
                result = false;
            }
        }
    } @catch (NSException*) {
        result = false;
    }
    return result;
}

} // namespace sony2fuji

#else

namespace sony2fuji {

bool renderPhotoMetal(
    const ImageData&,
    ColorSpace,
    const sony2fuji_request&,
    const std::shared_ptr<LUT3D>&,
    const RGB&,
    uint32_t,
    uint32_t,
    ImageData&
) {
    return false;
}

} // namespace sony2fuji

#endif
