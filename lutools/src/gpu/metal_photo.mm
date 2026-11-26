#include "gpu/photo_gpu.h"
#include "gpu/denoise.h"
#include "gpu/photo_log_shader.h"
#include "gpu/photo_tone_shader.h"
#include "gpu/photo_color_grading_shader.h"
#include "gpu/photo_tone_curve_shader.h"
#include "gpu/photo_color_science_shader.h"
#include "gpu/metal_dcp_shader.h"
#include "gpu/metal_effects_shader.h"
#include "gpu/photo_film_optics_shader.h"
#include "core/photo_film_optics.h"
#include "gpu/photo_spatial_shader.h"
#include "core/photo_atmosphere.h"
#include "core/photo_defringe.h"
#include "core/photo_lut.h"
#include "core/photo_sharpen_v2.h"
#include "core/chroma_denoise.h"
#include "core/processing_cancellation.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
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
    uint32_t inputIsSRGB;
    uint32_t hslEnabled;
    float hslHue[8], hslSaturation[8], hslLightness[8];
    uint32_t srcRowOffset, dstRowOffset, srcRows, dstRows;
    float blackPoint, whitePoint, vibrance;
    float colorGrading[12];
    float colorGradingLuminance[4];
    float colorGradingBlending;
    float colorGradingBalance;
    uint32_t customCurveCount;
    float curveRanges[32][4], curveTangents[32][2];
    uint32_t channelCurveCount[3];
    float channelCurveRanges[3][32][4], channelCurveTangents[3][32][2];
    uint32_t curveApplyToLuminosity;
    uint32_t parametricActive;
    float parametricAmps[4];
    float parametricSplits[4];
    uint32_t basicV3;
    uint32_t basicToneActive;
    uint32_t basicFieldWidth;
    uint32_t basicFieldHeight;
    uint32_t fullWorkHeight;
    float basicHighlights;
    float basicShadows;
};
static_assert(sizeof(PhotoParams) == 3544, "Photo Metal parameter layout");
static_assert(offsetof(PhotoParams, hslHue) == 192, "HSL Metal options offset");
static_assert(offsetof(PhotoParams, colorGrading) == 316, "Grading Metal options offset");
static_assert(offsetof(PhotoParams, customCurveCount) == 388, "Curve Metal options offset");
static_assert(offsetof(PhotoParams, channelCurveCount) == 1160, "Channel curve Metal options offset");
static_assert(offsetof(PhotoParams, curveApplyToLuminosity) == 3476, "Luminosity curve Metal options offset");
static_assert(offsetof(PhotoParams, parametricAmps) == 3484, "Parametric curve Metal options offset");

struct PhotoEffectsParams {
    uint32_t width, height;
    sony2fuji::PhotoEffectsOptions effects;
    uint32_t rowOffset, rows;
};
static_assert(sizeof(PhotoEffectsParams) == 56, "Photo effects Metal parameter layout");
static_assert(offsetof(PhotoEffectsParams, effects) == 8, "Photo effects Metal options offset");

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
    id<MTLComputePipelineState> effectsPipeline = nil;
    id<MTLComputePipelineState> filmOpticsDownsamplePipeline = nil;
    id<MTLComputePipelineState> filmOpticsBlurHPipeline = nil;
    id<MTLComputePipelineState> filmOpticsBlurVPipeline = nil;
    id<MTLComputePipelineState> filmOpticsCompositePipeline = nil;
    id<MTLBuffer> filmOpticsDummyBuffer = nil;
    id<MTLComputePipelineState> defringePipeline = nil;
    id<MTLComputePipelineState> dehazePipeline = nil;
    id<MTLComputePipelineState> clarityPipeline = nil;
    id<MTLComputePipelineState> textureBlurHPipeline = nil;
    id<MTLComputePipelineState> textureApplyVPipeline = nil;
    id<MTLComputePipelineState> sharpenPrepHPipeline = nil;
    id<MTLComputePipelineState> sharpenPrepVPipeline = nil;
    id<MTLComputePipelineState> sharpenMaskHPipeline = nil;
    id<MTLComputePipelineState> sharpenApplyPipeline = nil;
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

static const std::string kShaderSource = std::string(R"metal(
#include <metal_stdlib>
using namespace metal;
)metal") + sony2fuji::toneControlsShader("float3") + sony2fuji::colorGradingShader("float3") + sony2fuji::toneCurveShader("float3") + sony2fuji::photoLogShader(sony2fuji::ShaderDialect::Metal) + sony2fuji::colorScienceShader(sony2fuji::ShaderDialect::Metal) + R"metal(
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
    uint inputIsSRGB;
    uint hslEnabled;
    float hslHue[8], hslSaturation[8], hslLightness[8];
    uint srcRowOffset, dstRowOffset, srcRows, dstRows;
    float blackPoint, whitePoint, vibrance;
    float colorGrading[12];
    float colorGradingLuminance[4];
    float colorGradingBlending;
    float colorGradingBalance;
    uint customCurveCount;
    float curveRanges[32][4], curveTangents[32][2];
    uint channelCurveCount[3];
    float channelCurveRanges[3][32][4], channelCurveTangents[3][32][2];
    uint curveApplyToLuminosity;
    uint parametricActive;
    float parametricAmps[4];
    float parametricSplits[4];
    uint basicV3;
    uint basicToneActive;
    uint basicFieldWidth;
    uint basicFieldHeight;
    uint fullWorkHeight;
    float basicHighlights;
    float basicShadows;
};

inline float customToneCurve(float x, constant Params& p) {
    if (x <= p.curveRanges[0][0]) return p.curveRanges[0][2];
    if (x >= p.curveRanges[p.customCurveCount - 1u][1]) return p.curveRanges[p.customCurveCount - 1u][3];
    uint i = 0;
    while (i + 1u < p.customCurveCount && x > p.curveRanges[i][1]) ++i;
    return pchipSegment(x, p.curveRanges[i][0], p.curveRanges[i][1], p.curveRanges[i][2],
        p.curveRanges[i][3], p.curveTangents[i][0], p.curveTangents[i][1]);
}

inline float channelToneCurve(float x, uint ch, constant Params& p) {
    uint count = p.channelCurveCount[ch];
    if (count == 0u) return x;
    if (x <= p.channelCurveRanges[ch][0][0]) return p.channelCurveRanges[ch][0][2];
    if (x >= p.channelCurveRanges[ch][count - 1u][1]) return p.channelCurveRanges[ch][count - 1u][3];
    uint i = 0;
    while (i + 1u < count && x > p.channelCurveRanges[ch][i][1]) ++i;
    return pchipSegment(x, p.channelCurveRanges[ch][i][0], p.channelCurveRanges[ch][i][1],
        p.channelCurveRanges[ch][i][2], p.channelCurveRanges[ch][i][3],
        p.channelCurveTangents[ch][i][0], p.channelCurveTangents[ch][i][1]);
}

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
    float y,
    uint rowOffset
) {
    uint x0 = uint(floor(x));
    uint y0 = uint(floor(y));
    uint x1 = min(x0 + 1u, width - 1u);
    uint y1 = min(y0 + 1u, height - 1u);
    float tx = x - float(x0);
    float ty = y - float(y0);
    float3 c00 = pixelAt(pixels, width, x0, y0 - rowOffset);
    float3 c10 = pixelAt(pixels, width, x1, y0 - rowOffset);
    float3 c01 = pixelAt(pixels, width, x0, y1 - rowOffset);
    float3 c11 = pixelAt(pixels, width, x1, y1 - rowOffset);
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
    uint count = params.dstWidth * params.dstRows;
    if (gid >= count) {
        return;
    }
    uint x = gid % params.dstWidth;
    uint y = gid / params.dstWidth + params.dstRowOffset;
    float scaleX = params.dstWidth == 1u ? 0.0f :
        float(params.srcWidth - 1u) / float(params.dstWidth - 1u);
    float scaleY = params.dstHeight == 1u ? 0.0f :
        float(params.srcHeight - 1u) / float(params.dstHeight - 1u);
    float3 result = sampleBilinear(source, params.srcWidth, params.srcHeight,
        float(x) * scaleX, float(y) * scaleY, params.srcRowOffset);
    destination[gid] = packed_float3(result);
}

kernel void matrixExposure(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    device const float* basicField [[buffer(3)]],
    constant ColorScienceParams& colorScience [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.srcWidth * params.srcHeight;
    if (gid >= count) {
        return;
    }
    float3 result = matrixRGB(float3(source[gid]), params);
    result.r *= params.exposureScale * params.wbR;
    result.g *= params.exposureScale * params.wbG;
    result.b *= params.exposureScale * params.wbB;
    result = csApplyCalibration(result, colorScience);
    if (params.basicToneActive != 0u) {
        uint px = gid % params.srcWidth;
        uint py = gid / params.srcWidth + params.srcRowOffset;
        uint fw = params.basicFieldWidth;
        uint fh = params.basicFieldHeight;
        float fx = clamp((float(px) + 0.5f) * float(fw) / float(params.srcWidth) - 0.5f, 0.0f, float(fw - 1u));
        float fy = clamp((float(py) + 0.5f) * float(fh) / float(params.fullWorkHeight) - 0.5f, 0.0f, float(fh - 1u));
        uint x0 = uint(floor(fx));
        uint y0 = uint(floor(fy));
        uint x1 = min(x0 + 1u, fw - 1u);
        uint y1 = min(y0 + 1u, fh - 1u);
        float tx = fx - float(x0);
        float ty = fy - float(y0);
        uint i00 = (y0 * fw + x0) * 2u;
        uint i10 = (y0 * fw + x1) * 2u;
        uint i01 = (y1 * fw + x0) * 2u;
        uint i11 = (y1 * fw + x1) * 2u;
        float slope = mix(mix(basicField[i00], basicField[i10], tx),
                          mix(basicField[i01], basicField[i11], tx), ty);
        float intercept = mix(mix(basicField[i00 + 1u], basicField[i10 + 1u], tx),
                              mix(basicField[i01 + 1u], basicField[i11 + 1u], tx), ty);
        float gain = tcBasicToneV3Gain(tcLuminance(result), slope, intercept, params.basicHighlights, params.basicShadows);
        result *= gain;
    }
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
    float3 filmInput = base;
    if (params.inputIsSRGB == 0u) {
        float3 gamut = lutMatrixRGB(value, params);
        filmInput = float3(encodePhotoLog(gamut.r, params.inputIsFLog != 0u),
            encodePhotoLog(gamut.g, params.inputIsFLog != 0u), encodePhotoLog(gamut.b, params.inputIsFLog != 0u));
    }
    float3 film = applyLUT(lut, filmInput, params);
    if (params.outputIsLog != 0u) {
        film = float3(neutralDisplay(decodePhotoLog(film.r, params.outputIsFLog != 0u)),
            neutralDisplay(decodePhotoLog(film.g, params.outputIsFLog != 0u)),
            neutralDisplay(decodePhotoLog(film.b, params.outputIsFLog != 0u)));
    }
    destination[gid] = packed_float3(lerp3(base, film, params.lutStrength));
}

inline float3 applyHsl(float3 pixel, constant Params& params) {
    if (params.hslEnabled == 0u) return pixel;
    float maximum = max(pixel.r, max(pixel.g, pixel.b));
    float minimum = min(pixel.r, min(pixel.g, pixel.b));
    float delta = maximum - minimum;
    if (delta <= 1e-6f) return pixel;
    float hue = maximum == pixel.r ? 60.0f * (pixel.g - pixel.b) / delta :
        maximum == pixel.g ? 60.0f * ((pixel.b - pixel.r) / delta + 2.0f) :
        60.0f * ((pixel.r - pixel.g) / delta + 4.0f);
    if (hue < 0.0f) hue += 360.0f;
    const float centers[9] = {0,30,60,120,180,240,270,300,360};
    uint lower = 0u;
    while (lower < 7u && hue >= centers[lower + 1u]) ++lower;
    uint upper = (lower + 1u) % 8u;
    float blend = (hue - centers[lower]) / (centers[lower + 1u] - centers[lower]);
    blend = blend * blend * (3.0f - 2.0f * blend);
    float dh = params.hslHue[lower] * (1.0f - blend) + params.hslHue[upper] * blend;
    float ds = params.hslSaturation[lower] * (1.0f - blend) + params.hslSaturation[upper] * blend;
    float dl = params.hslLightness[lower] * (1.0f - blend) + params.hslLightness[upper] * blend;
    float colorWeight = clamp(delta * 255.0f, 0.0f, 1.0f);
    dl *= colorWeight * colorWeight * (3.0f - 2.0f * colorWeight);
    if (dh == 0.0f && ds == 0.0f && dl == 0.0f) return pixel;
    float lightness = clamp((maximum + minimum) * 0.5f, 0.0f, 1.0f);
    float saturation = delta / max(1e-6f, 1.0f - abs(2.0f * lightness - 1.0f));
    float3 residual = float3(0.0f);
    if (minimum < 0.0f || maximum > 1.0f) {
        float baseChroma = (1.0f - abs(2.0f * lightness - 1.0f)) * clamp(saturation, 0.0f, 1.0f);
        residual = pixel - ((pixel - minimum) * (baseChroma / delta) + (lightness - baseChroma * 0.5f));
    }
    hue = fmod(hue + dh * 0.3f + 360.0f, 360.0f);
    saturation = clamp(saturation * (1.0f + ds * 0.01f), 0.0f, 1.0f);
    lightness = clamp(lightness + dl * 0.005f, 0.0f, 1.0f);
    float chroma = (1.0f - abs(2.0f * lightness - 1.0f)) * saturation;
    float x = chroma * (1.0f - abs(fmod(hue / 60.0f, 2.0f) - 1.0f));
    float3 rgb = hue < 60.0f ? float3(chroma,x,0) : hue < 120.0f ? float3(x,chroma,0) :
        hue < 180.0f ? float3(0,chroma,x) : hue < 240.0f ? float3(0,x,chroma) :
        hue < 300.0f ? float3(x,0,chroma) : float3(chroma,0,x);
    return rgb + (lightness - chroma * 0.5f) + residual;
}

float3 applyGrading(float3 pixel, constant Params& params) {
    return cgApply(pixel,
        float3(params.colorGrading[0], params.colorGrading[1], params.colorGrading[2]), params.colorGradingLuminance[0],
        float3(params.colorGrading[3], params.colorGrading[4], params.colorGrading[5]), params.colorGradingLuminance[1],
        float3(params.colorGrading[6], params.colorGrading[7], params.colorGrading[8]), params.colorGradingLuminance[2],
        float3(params.colorGrading[9], params.colorGrading[10], params.colorGrading[11]), params.colorGradingLuminance[3],
        params.colorGradingBlending, params.colorGradingBalance);
}

inline float evalMasterTone(float x, constant Params& params) {
    if (params.parametricActive != 0u) {
        x = tcParametric(x, params.parametricAmps[0], params.parametricAmps[1],
            params.parametricAmps[2], params.parametricAmps[3],
            params.parametricSplits[0], params.parametricSplits[1], params.parametricSplits[2]);
    }
    if (params.customCurveCount != 0u) {
        return customToneCurve(x, params);
    }
    if (params.toneCurve != 0.0f) {
        float curveStrength = signedPow(params.toneCurve, 1.2f);
        float p1 = clamp(0.25f - curveStrength * 0.2f, 0.0f, 1.0f);
        float p2 = clamp(0.5f + curveStrength * 0.05f, 0.0f, 1.0f);
        float p3 = clamp(0.75f + curveStrength * 0.2f, 0.0f, 1.0f);
        return applyToneCurve(x, p1, p2, p3);
    }
    return x;
}

kernel void toneAdjustments(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    constant ColorScienceParams& colorScience [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = params.srcWidth * params.srcHeight;
    if (gid >= count) {
        return;
    }
    float3 raw = csApplyBwMixer(float3(source[gid]), colorScience);
    float3 pixel = params.basicV3 != 0u
        ? tcBasicBlackWhiteV3(raw, params.blackPoint, params.whitePoint)
        : tcBlackWhite(raw, params.blackPoint, params.whitePoint);
    if (params.toneEnabled == 0u) {
        float3 vibranced = params.basicV3 != 0u
            ? tcBasicVibranceV3(pixel, params.vibrance)
            : tcVibrance(pixel, params.vibrance);
        float3 colored = csApplySelectiveColor(
            csApplyPointColor(applyHsl(vibranced, params), colorScience),
            colorScience
        );
        destination[gid] = packed_float3(applyGrading(colored, params));
        return;
    }
    if (params.basicV3 == 0u) {
        pixel = hsApplyHighlightsShadows(pixel, params.highlights, params.shadows);
    }
    bool masterActive = params.parametricActive != 0u || params.customCurveCount != 0u || params.toneCurve != 0.0f;
    if (masterActive) {
        if (params.curveApplyToLuminosity != 0u) {
            float3 pL = float3(tcSrgbToLinear(pixel.r), tcSrgbToLinear(pixel.g), tcSrgbToLinear(pixel.b));
            float Y = tcLuminosityLinearY(pL);
            float u = tcLinearToSrgb(max(0.0f, Y));
            float uPrime = evalMasterTone(u, params);
            float Y0 = tcSrgbToLinear(evalMasterTone(0.0f, params));
            pixel = tcLuminosityFinish(pL, Y, uPrime, Y0);
        } else {
            pixel = float3(evalMasterTone(pixel.r, params), evalMasterTone(pixel.g, params), evalMasterTone(pixel.b, params));
        }
    }
    pixel.r = channelToneCurve(pixel.r, 0u, params);
    pixel.g = channelToneCurve(pixel.g, 1u, params);
    pixel.b = channelToneCurve(pixel.b, 2u, params);
    float contrast = clamp(params.contrast, 0.0f, 2.0f);
    float saturation = clamp(params.saturation, 0.0f, 2.0f);
    if (params.basicV3 != 0u && contrast != 1.0f) {
        float amount = contrast - 1.0f;
        pixel = float3(
            tcBasicContrastV3(pixel.r, amount),
            tcBasicContrastV3(pixel.g, amount),
            tcBasicContrastV3(pixel.b, amount)
        );
    }
    if ((params.basicV3 == 0u && contrast != 1.0f) || saturation != 1.0f) {
        if (params.basicV3 == 0u) {
            pixel = (pixel - 0.5f) * contrast + 0.5f;
        }
        float luminance = 0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b;
        pixel = float3(
            luminance + (pixel.r - luminance) * saturation,
            luminance + (pixel.g - luminance) * saturation,
            luminance + (pixel.b - luminance) * saturation
        );
    }
    float3 vibranced = params.basicV3 != 0u
        ? tcBasicVibranceV3(pixel, params.vibrance)
        : tcVibrance(pixel, params.vibrance);
    float3 colored = csApplySelectiveColor(
        csApplyPointColor(applyHsl(vibranced, params), colorScience),
        colorScience
    );
    destination[gid] = packed_float3(applyGrading(colored, params));
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

static const std::string kSpatialShaderSource = std::string(R"metal(
#include <metal_stdlib>
using namespace metal;

struct SpatialParams {
    uint width;
    uint height;
    uint rowOffset;
    uint rows;
    uint srcRowOffset;
    uint auxRowOffset;
    uint radius;
    uint stage;
    float strength;
    float sharpenCoring;
    float sharpenMaskLow;
    float sharpenMaskSpan;
    float defringePurpleNorm;
    float defringePurpleCenter;
    float defringeGreenNorm;
    float defringeGreenCenter;
    float4 airlight;
    uint4 flags;
    uint4 bandDims;
    float4 weights[7];
};

inline float3 spLoadBand(device const packed_float3* buf, int x, int y, uint w, uint rowOff, uint rowCount) {
    uint cx = uint(clamp(x, 0, int(w) - 1));
    int minY = int(rowOff);
    int maxY = minY + int(max(1u, rowCount)) - 1;
    uint cy = uint(clamp(y, minY, maxY));
    return float3(buf[(cy - rowOff) * w + cx]);
}

inline float spReadWeight(constant SpatialParams& p, uint idx) {
    float4 wv = p.weights[idx >> 2u];
    uint lane = idx & 3u;
    return lane == 0u ? wv.x : (lane == 1u ? wv.y : (lane == 2u ? wv.z : wv.w));
}

#define SP_FN inline
#define SP_V3 float3
#define SP_V3C(x, y, z) float3((x), (y), (z))
#define SP_CTX_DECL , constant SpatialParams& sp, device const packed_float3* spSrc, device const packed_float3* spAux, device const float* spField
#define SP_CTX_ARG , sp, spSrc, spAux, spField
#define SP_SRC(ix, iy) spLoadBand(spSrc, (ix), (iy), sp.width, sp.srcRowOffset, sp.bandDims.x)
#define SP_AUX(ix, iy) spLoadBand(spAux, (ix), (iy), sp.width, sp.auxRowOffset, sp.bandDims.y)
#define SP_FIELD(idx) spField[(idx)]
#define SP_FINITE(v) all(isfinite(v))
#define SP_WEIGHT(idx) spReadWeight(sp, (idx))
#define SP_WIDTH sp.width
#define SP_HEIGHT sp.height
#define SP_RADIUS sp.radius
#define SP_STRENGTH sp.strength
#define SP_SHARPEN_CORING sp.sharpenCoring
#define SP_SHARPEN_MASK_LOW sp.sharpenMaskLow
#define SP_SHARPEN_MASK_SPAN sp.sharpenMaskSpan
#define SP_PURPLE_NORM sp.defringePurpleNorm
#define SP_PURPLE_CENTER sp.defringePurpleCenter
#define SP_GREEN_NORM sp.defringeGreenNorm
#define SP_GREEN_CENTER sp.defringeGreenCenter
#define SP_AIRLIGHT sp.airlight
#define SP_FLAGS sp.flags
)metal") + sony2fuji::photoSpatialShaderBody() + R"metal(
#undef SP_FN
#undef SP_V3
#undef SP_V3C
#undef SP_CTX_DECL
#undef SP_CTX_ARG
#undef SP_SRC
#undef SP_AUX
#undef SP_FIELD
#undef SP_FINITE
#undef SP_WEIGHT
#undef SP_WIDTH
#undef SP_HEIGHT
#undef SP_RADIUS
#undef SP_STRENGTH
#undef SP_SHARPEN_CORING
#undef SP_SHARPEN_MASK_LOW
#undef SP_SHARPEN_MASK_SPAN
#undef SP_PURPLE_NORM
#undef SP_PURPLE_CENTER
#undef SP_GREEN_NORM
#undef SP_GREEN_CENTER
#undef SP_AIRLIGHT
#undef SP_FLAGS

#define DEFINE_SPATIAL_KERNEL(KERNEL_NAME, HELPER_FN) \
kernel void KERNEL_NAME( \
    constant SpatialParams& sp [[buffer(0)]], \
    device const packed_float3* spSrc [[buffer(1)]], \
    device packed_float3* spDst [[buffer(2)]], \
    device const packed_float3* spAux [[buffer(3)]], \
    device const float* spField [[buffer(4)]], \
    uint gid [[thread_position_in_grid]]) { \
    if (gid >= sp.width * sp.rows) return; \
    int x = int(gid % sp.width); \
    int y = int(gid / sp.width + sp.rowOffset); \
    spDst[gid] = packed_float3(HELPER_FN(x, y, sp, spSrc, spAux, spField)); \
}

DEFINE_SPATIAL_KERNEL(spatialDefringe, spDefringePixel)
DEFINE_SPATIAL_KERNEL(spatialDehaze, spDehazePixel)
DEFINE_SPATIAL_KERNEL(spatialClarity, spClarityPixel)
DEFINE_SPATIAL_KERNEL(spatialTextureBlurH, spTextureBlurHPixel)
DEFINE_SPATIAL_KERNEL(spatialTextureApplyV, spTextureApplyVPixel)
DEFINE_SPATIAL_KERNEL(spatialSharpenPrepH, spSharpenPrepHPixel)
DEFINE_SPATIAL_KERNEL(spatialSharpenPrepV, spSharpenPrepVPixel)
DEFINE_SPATIAL_KERNEL(spatialSharpenMaskH, spSharpenMaskHPixel)
DEFINE_SPATIAL_KERNEL(spatialSharpenApply, spSharpenApplyPixel)
#undef DEFINE_SPATIAL_KERNEL
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
            NSString* source = [NSString stringWithUTF8String:kShaderSource.c_str()];
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
            NSString* spatialSource = [NSString stringWithUTF8String:kSpatialShaderSource.c_str()];
            MTLCompileOptions* spatialOptions = [MTLCompileOptions new];
            if (@available(macOS 15.0, iOS 18.0, *)) {
                spatialOptions.mathMode = MTLMathModeSafe;
            } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                spatialOptions.fastMathEnabled = NO;
#pragma clang diagnostic pop
            }
            NSError* spatialError = nil;
            id<MTLLibrary> spatialLibrary =
                [context.device newLibraryWithSource:spatialSource options:spatialOptions error:&spatialError];
            if (spatialLibrary && !spatialError) {
                context.defringePipeline = makePipeline(context.device, spatialLibrary, @"spatialDefringe");
                context.dehazePipeline = makePipeline(context.device, spatialLibrary, @"spatialDehaze");
                context.clarityPipeline = makePipeline(context.device, spatialLibrary, @"spatialClarity");
                context.textureBlurHPipeline = makePipeline(context.device, spatialLibrary, @"spatialTextureBlurH");
                context.textureApplyVPipeline = makePipeline(context.device, spatialLibrary, @"spatialTextureApplyV");
                context.sharpenPrepHPipeline = makePipeline(context.device, spatialLibrary, @"spatialSharpenPrepH");
                context.sharpenPrepVPipeline = makePipeline(context.device, spatialLibrary, @"spatialSharpenPrepV");
                context.sharpenMaskHPipeline = makePipeline(context.device, spatialLibrary, @"spatialSharpenMaskH");
                context.sharpenApplyPipeline = makePipeline(context.device, spatialLibrary, @"spatialSharpenApply");
            } else {
                NSLog(@"RawLab spatial Metal compilation failed: %@", spatialError);
            }
            context.ready = context.resizePipeline && context.matrixExposurePipeline &&
                context.baseLutPipeline && context.tonePipeline && context.noisePipeline &&
                context.sharpenPipeline && context.defringePipeline && context.dehazePipeline &&
                context.clarityPipeline && context.textureBlurHPipeline &&
                context.textureApplyVPipeline && context.sharpenPrepHPipeline &&
                context.sharpenPrepVPipeline && context.sharpenMaskHPipeline &&
                context.sharpenApplyPipeline;
            if (@available(macOS 15.0, iOS 18.0, *)) {
                MTLCompileOptions* options = [MTLCompileOptions new];
                options.mathMode = MTLMathModeSafe;
                const std::string effectsStdSource = metalEffectsCombinedShaderSource();
                NSString* effectsSource = [NSString stringWithUTF8String:effectsStdSource.c_str()];
                error = nil;
                id<MTLLibrary> effectsLibrary = [context.device newLibraryWithSource:effectsSource options:options error:&error];
                if (effectsLibrary && !error) context.effectsPipeline = makePipeline(context.device, effectsLibrary, @"photoEffects");
                else NSLog(@"RawLab effects Metal compilation failed: %@", error);
                NSString* dcpSource = [source stringByAppendingString:[NSString stringWithUTF8String:sony2fuji::metalDcpShaderSource().c_str()]];
                error = nil;
                id<MTLLibrary> dcpLibrary = [context.device newLibraryWithSource:dcpSource options:options error:&error];
                if (dcpLibrary && !error) context.baseDcpPipeline = makePipeline(context.device, dcpLibrary, @"baseAndDcp");
                else NSLog(@"RawLab DCP Metal compilation failed: %@", error);
            }
            {
                MTLCompileOptions* foOptions = [MTLCompileOptions new];
                if (@available(macOS 15.0, iOS 18.0, *)) {
                    foOptions.mathMode = MTLMathModeSafe;
                }
                const std::string foStdSource = std::string(sony2fuji::kMetalFilmOpticsKernelSource) +
                    sony2fuji::kFilmOpticsSharedShaderBody + sony2fuji::kMetalFilmOpticsKernelsTail;
                NSString* foSource = [NSString stringWithUTF8String:foStdSource.c_str()];
                error = nil;
                id<MTLLibrary> foLibrary = [context.device newLibraryWithSource:foSource options:foOptions error:&error];
                if (foLibrary && !error) {
                    context.filmOpticsDownsamplePipeline = makePipeline(context.device, foLibrary, @"filmOpticsDownsample");
                    context.filmOpticsBlurHPipeline = makePipeline(context.device, foLibrary, @"filmOpticsBlurH");
                    context.filmOpticsBlurVPipeline = makePipeline(context.device, foLibrary, @"filmOpticsBlurV");
                    context.filmOpticsCompositePipeline = makePipeline(context.device, foLibrary, @"filmOpticsComposite");
                    context.filmOpticsDummyBuffer = [context.device newBufferWithLength:sizeof(float) * 4u
                                                                               options:MTLResourceStorageModeShared];
                } else {
                    NSLog(@"RawLab film optics Metal compilation failed: %@", error);
                }
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
    const sony2fuji::RenderParams& renderParams,
    const CachedLUT* cachedLUT,
    float lutStrength,
    bool includeOptionalCurves = true
) {
    PhotoParams params{};
    params.srcWidth = srcWidth;
    params.srcHeight = srcHeight;
    params.dstWidth = dstWidth;
    params.dstHeight = dstHeight;
    params.srcRows = srcHeight; params.dstRows = dstHeight;
    params.lutSize = cachedLUT ? static_cast<uint32_t>(cachedLUT->size) : 0;
    params.useLut = cachedLUT ? 1u : 0u;
    params.toneEnabled = renderParams.needsToneAdjustments();
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
    params.exposureScale = std::exp2(renderParams.exposureEV) * renderParams.brightness;
    params.wbR = renderParams.relativeWB.r;
    params.wbG = renderParams.relativeWB.g;
    params.wbB = renderParams.relativeWB.b;
    params.lutStrength = lutStrength;
    params.contrast = renderParams.contrast;
    params.saturation = renderParams.saturation;
    params.highlights = renderParams.highlights;
    params.shadows = renderParams.shadows;
    params.toneCurve = renderParams.toneCurve;
    if (includeOptionalCurves) {
        const auto custom = sony2fuji::toneCurveGpuParameters(renderParams.customCurve);
        params.customCurveCount = custom.count;
        if (custom.count) {
            std::memcpy(params.curveRanges, custom.ranges, sizeof(custom.ranges));
            for (uint32_t i = 0; i < custom.count; ++i) {
                params.curveTangents[i][0] = custom.tangents[i][0];
                params.curveTangents[i][1] = custom.tangents[i][1];
            }
        }
        for (size_t ch = 0; ch < 3; ++ch) {
            const auto chParams = sony2fuji::toneCurveGpuParameters(renderParams.channelCurves[ch]);
            params.channelCurveCount[ch] = chParams.count;
            if (chParams.count) {
                std::memcpy(params.channelCurveRanges[ch], chParams.ranges, sizeof(chParams.ranges));
                for (uint32_t i = 0; i < chParams.count; ++i) {
                    params.channelCurveTangents[ch][i][0] = chParams.tangents[i][0];
                    params.channelCurveTangents[ch][i][1] = chParams.tangents[i][1];
                }
            }
        }
        params.curveApplyToLuminosity = renderParams.curveApplyToLuminosity ? 1u : 0u;
        const auto parametric = sony2fuji::toneCurveParametricGpuParameters(renderParams.parametricCurve);
        params.parametricActive = parametric.active;
        std::memcpy(params.parametricAmps, parametric.amps, sizeof(parametric.amps));
        std::memcpy(params.parametricSplits, parametric.splits, sizeof(parametric.splits));
        params.hslEnabled = renderParams.hsl.active();
        params.blackPoint = renderParams.toneControls.blackPoint;
        params.whitePoint = renderParams.toneControls.whitePoint;
        params.vibrance = renderParams.toneControls.vibrance;
        const auto grading = sony2fuji::colorGradingParameters(renderParams.colorGrading);
        for (size_t zone = 0; zone < 4; ++zone) {
            params.colorGrading[zone * 3] = grading.coefficients[zone].r;
            params.colorGrading[zone * 3 + 1] = grading.coefficients[zone].g;
            params.colorGrading[zone * 3 + 2] = grading.coefficients[zone].b;
            params.colorGradingLuminance[zone] = grading.luminance[zone];
        }
        params.colorGradingBlending = grading.blending;
        params.colorGradingBalance = grading.balance;
        std::copy(renderParams.hsl.hue.begin(), renderParams.hsl.hue.end(), params.hslHue);
        std::copy(renderParams.hsl.saturation.begin(), renderParams.hsl.saturation.end(), params.hslSaturation);
        std::copy(renderParams.hsl.lightness.begin(), renderParams.hsl.lightness.end(), params.hslLightness);
        params.basicV3 = renderParams.basicV3 ? 1u : 0u;
        const bool bt = renderParams.basicV3 && renderParams.basicTone.active() &&
            renderParams.basicToneField && !renderParams.basicToneField->empty();
        params.basicToneActive = bt ? 1u : 0u;
        params.basicFieldWidth = bt ? static_cast<uint32_t>(renderParams.basicToneField->width) : 1u;
        params.basicFieldHeight = bt ? static_cast<uint32_t>(renderParams.basicToneField->height) : 1u;
        params.fullWorkHeight = srcHeight;
        params.basicHighlights = bt ? std::clamp(renderParams.basicTone.highlights, -1.0f, 1.0f) : 0.0f;
        params.basicShadows = bt ? std::clamp(renderParams.basicTone.shadows, -1.0f, 1.0f) : 0.0f;
    } else {
        const auto grading = sony2fuji::colorGradingParameters(sony2fuji::ColorGradingOptions{});
        for (size_t zone = 0; zone < 4; ++zone) {
            params.colorGrading[zone * 3] = grading.coefficients[zone].r;
            params.colorGrading[zone * 3 + 1] = grading.coefficients[zone].g;
            params.colorGrading[zone * 3 + 2] = grading.coefficients[zone].b;
            params.colorGradingLuminance[zone] = grading.luminance[zone];
        }
        params.colorGradingBlending = grading.blending;
        params.colorGradingBalance = grading.balance;
    }
    params.noiseReduction = renderParams.noiseReduction;
    params.sharpening = renderParams.sharpening;
    if (cachedLUT) {
        params.inputIsSRGB = cachedLUT->owner->inputTransfer() == sony2fuji::LUTTransfer::SRGB;
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
    id<MTLBuffer> invalid = nil,
    id<MTLBuffer> extraBuffer = nil,
    id<MTLBuffer> extraBuffer2 = nil
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
    } else if (extraBuffer != nil) {
        [encoder setBuffer:extraBuffer offset:0 atIndex:3];
        if (extraBuffer2 != nil) {
            [encoder setBuffer:extraBuffer2 offset:0 atIndex:4];
        }
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
    id<MTLBuffer> invalid = nil,
    id<MTLBuffer> extraBuffer = nil,
    id<MTLBuffer> extraBuffer2 = nil
) {
    return finishKernel(beginKernel(
        commandBuffer, pipeline, params, source, destination, lut, count, dcp, invalid, extraBuffer, extraBuffer2
    ));
}

bool encodeSpatialKernel(
    id<MTLCommandBuffer> commandBuffer,
    id<MTLComputePipelineState> pipeline,
    id<MTLDevice> device,
    const sony2fuji::SpatialGpuParams& sp,
    id<MTLBuffer> source,
    id<MTLBuffer> destination,
    id<MTLBuffer> auxBuffer,
    id<MTLBuffer> fieldBuffer
) {
    const size_t count = size_t(sp.width) * size_t(sp.rows);
    if (!pipeline || !source || !destination || !auxBuffer || !fieldBuffer || count == 0) {
        return false;
    }
    id<MTLBuffer> spBuf = makeBuffer(device, sizeof(sp));
    if (!spBuf) return false;
    std::memcpy(spBuf.contents, &sp, sizeof(sp));
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
    if (!encoder) return false;
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:spBuf offset:0 atIndex:0];
    [encoder setBuffer:source offset:0 atIndex:1];
    [encoder setBuffer:destination offset:0 atIndex:2];
    [encoder setBuffer:auxBuffer offset:0 atIndex:3];
    [encoder setBuffer:fieldBuffer offset:0 atIndex:4];
    const NSUInteger maxThreads = pipeline.maxTotalThreadsPerThreadgroup;
    if (maxThreads == 0) {
        [encoder endEncoding];
        return false;
    }
    const NSUInteger threadgroup = std::min<NSUInteger>(256, maxThreads);
    [encoder dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(count), 1, 1)
        threadsPerThreadgroup:MTLSizeMake(threadgroup, 1, 1)];
    [encoder endEncoding];
    return true;
}

id<MTLBuffer> makeFloatBuffer(id<MTLDevice> device, const std::vector<float>& data, size_t maxBytes) {
    const size_t bytes = std::max<size_t>(sizeof(float), data.size() * sizeof(float));
    if (bytes > maxBytes) return nil;
    id<MTLBuffer> buf = makeBuffer(device, bytes);
    if (buf && !data.empty()) {
        std::memcpy(buf.contents, data.data(), data.size() * sizeof(float));
    } else if (buf) {
        std::memset(buf.contents, 0, bytes);
    }
    return buf;
}

bool renderPhotoMetalImpl(
    const ImageData& input,
    ColorSpace inputSpace,
    const sony2fuji::RenderParams& renderParams,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output,
    sony2fuji::GpuRenderOutcome& outcome
) {
    outcome = {};
    auto failWith = [&](sony2fuji::GpuFailureKind failure, sony2fuji::GpuBackendFault fault, const char* message) {
        outcome = {failure, fault, message};
        return false;
    };
    if (input.width <= 0 || input.height <= 0 || targetWidth == 0 || targetHeight == 0 ||
        input.pixels.size() != static_cast<size_t>(input.width) * input.height ||
        !renderParams.validForGpu()) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "Image dimensions or parameters invalid for Metal");
    }
    size_t inputCount = 0;
    size_t targetCount = 0;
    if (!checkedCount(static_cast<uint32_t>(input.width), static_cast<uint32_t>(input.height), &inputCount) ||
        !checkedCount(targetWidth, targetHeight, &targetCount)) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "Image pixel count exceeds Metal 32-bit limit");
    }

    MetalContext& context = metalContext();
    if (!context.device) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::NoAdapter,
            "No Metal GPU device available");
    }
    if (!context.ready) {
        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
            sony2fuji::GpuBackendFault::DeviceError,
            "Metal shader or pipeline initialization failed");
    }
    if (renderParams.effects.active() && !context.effectsPipeline) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "Metal photo effects require macOS 15 or iOS 18");
    }
    const bool filmOpticsReady = context.filmOpticsDownsamplePipeline && context.filmOpticsBlurHPipeline &&
        context.filmOpticsBlurVPipeline && context.filmOpticsCompositePipeline && context.filmOpticsDummyBuffer;
    if (renderParams.filmOptics.active() && !filmOpticsReady) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "Metal film optics pipeline unavailable");
    }

    const float lutStrength = std::max(0.0f, std::min(2.0f, renderParams.lutStrength));
    const bool useLUT = renderParams.lut && lutStrength > 0.0f;
    if (useLUT && renderParams.lut->requiresCPU()) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "LUT requires CPU evaluation");
    }
    const bool useDcp = renderParams.dcp && lutStrength > 0.0f;
    if (useDcp && useLUT) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "Cannot combine DCP look and 3D LUT in Metal pass");
    }
    if (useDcp && !context.baseDcpPipeline) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "Metal DCP look requires macOS 15 or iOS 18");
    }
    CachedDcp cachedDcp;
    id<MTLBuffer> invalid = nil;
    if (useDcp) {
        if (!getCachedDcp(context, renderParams.dcp, cachedDcp)) {
            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                sony2fuji::GpuBackendFault::DeviceError,
                "Failed to upload DCP look buffers to Metal");
        }
        invalid = makeBuffer(context.device, sizeof(uint32_t));
        if (!invalid) {
            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                sony2fuji::GpuBackendFault::DeviceError,
                "Failed to allocate Metal DCP validation buffer");
        }
        *static_cast<uint32_t*>(invalid.contents) = 0;
    }
    CachedLUT cachedLUT;
    if (useLUT && !getCachedLUT(context, renderParams.lut, &cachedLUT)) {
        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
            sony2fuji::GpuBackendFault::DeviceError,
            "Failed to upload 3D LUT texture to Metal");
    }

    ColorConverter::Matrix3x3 toSRGB;
    ColorConverter::Matrix3x3 toFGamut;
    try {
        if (renderParams.hasCustomToSrgb) {
            toSRGB = renderParams.customToSrgb;
        } else if (inputSpace == ColorSpace::sRGB) {
            toSRGB = ColorConverter::Matrix3x3{{
                {1.0f, 0.0f, 0.0f},
                {0.0f, 1.0f, 0.0f},
                {0.0f, 0.0f, 1.0f}
            }};
        } else {
            toSRGB = ColorConverter::getConversionMatrix(inputSpace, ColorSpace::sRGB);
        }
        if (useLUT && renderParams.lut->inputTransfer() == sony2fuji::LUTTransfer::SRGB) {
            toFGamut = ColorConverter::Matrix3x3{{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}};
        } else {
            toFGamut = sony2fuji::photoLUTInputMatrix(useLUT ? renderParams.lut->inputTransfer() : sony2fuji::LUTTransfer::FLog2);
        }
    } catch (const std::exception& error) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            error.what());
    }

    id<MTLBuffer> basicFieldBuffer = nil;
    if (renderParams.basicV3 && renderParams.basicTone.active()) {
        const size_t fieldCount = renderParams.basicToneField->slope.size();
        basicFieldBuffer = makeBuffer(context.device, fieldCount * 2 * sizeof(float));
        if (!basicFieldBuffer) {
            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                sony2fuji::GpuBackendFault::DeviceError,
                "Failed to allocate Metal BasicToneV3 field buffer");
        }
        auto* dstField = static_cast<float*>(basicFieldBuffer.contents);
        for (size_t i = 0; i < fieldCount; ++i) {
            dstField[i * 2] = renderParams.basicToneField->slope[i];
            dstField[i * 2 + 1] = renderParams.basicToneField->intercept[i];
        }
    } else {
        basicFieldBuffer = makeBuffer(context.device, 2 * sizeof(float));
        if (!basicFieldBuffer) {
            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                sony2fuji::GpuBackendFault::DeviceError,
                "Failed to allocate Metal BasicToneV3 dummy field buffer");
        }
        std::memset(basicFieldBuffer.contents, 0, 2 * sizeof(float));
    }

    const sony2fuji::ColorScienceGpuParams csValues = sony2fuji::colorScienceGpuParameters(renderParams);
    id<MTLBuffer> colorScienceBuffer = makeBuffer(context.device, sizeof(csValues));
    if (!colorScienceBuffer) {
        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
            sony2fuji::GpuBackendFault::DeviceError,
            "Failed to allocate Metal ColorScience buffer");
    }
    std::memcpy(colorScienceBuffer.contents, &csValues, sizeof(csValues));

    const bool defringeActive = renderParams.defringe.active();
    const bool dehazeActive = renderParams.atmosphere.dehaze != 0.0f;
    const bool clarityActive = renderParams.atmosphere.clarity != 0.0f;
    const bool textureActive = renderParams.atmosphere.texture != 0.0f;
    const bool sharpenV2Active = renderParams.sharpening > 0.0f && renderParams.sharpenV2.luminanceV2;

    const uint32_t inputWidth = static_cast<uint32_t>(input.width);
    const uint32_t inputHeight = static_cast<uint32_t>(input.height);
    const bool earlyResize = renderParams.intent == sony2fuji::RenderIntent::Preview &&
        renderParams.sharpening <= 0.0f && renderParams.noiseReduction <= 0.0f &&
        !renderParams.effects.active() && renderParams.chromaDenoise == 0 &&
        !renderParams.atmosphere.active() && !defringeActive &&
        !renderParams.preserveSourceResolution &&
        (targetWidth != inputWidth || targetHeight != inputHeight);
    const uint32_t processingWidth = earlyResize ? targetWidth : inputWidth;
    const uint32_t processingHeight = earlyResize ? targetHeight : inputHeight;
    size_t processingCount = 0;
    if (!checkedCount(processingWidth, processingHeight, &processingCount)) {
        return failWith(sony2fuji::GpuFailureKind::Unsupported,
            sony2fuji::GpuBackendFault::UnsupportedCapability,
            "Processing pixel count exceeds Metal 32-bit limit");
    }

    const float texSigma = textureActive
        ? sony2fuji::textureBlurSigma(static_cast<int>(processingWidth), static_cast<int>(processingHeight))
        : 1.0f;
    const uint32_t texRadius = textureActive
        ? static_cast<uint32_t>(std::clamp(static_cast<int>(std::ceil(3.0f * texSigma)), 2, 12))
        : 0u;
    const float sharpSigma = std::clamp(renderParams.sharpenV2.radius, 0.5f, 3.0f);
    const uint32_t sharpRadius = sharpenV2Active
        ? static_cast<uint32_t>(std::clamp(static_cast<int>(std::ceil(3.0f * sharpSigma)), 1, 9))
        : 0u;
    const uint32_t sharpMaskRadius = (sharpenV2Active && renderParams.sharpenV2.masking > 0.0f)
        ? static_cast<uint32_t>(std::clamp(static_cast<int>(std::ceil(3.0f * 0.5f * sharpSigma)), 1, 5))
        : 0u;

    // 每个 GPU 缓冲区最多 16 MiB。主图只保留一份待提交结果；失败时调用方的
    // 原始 RAW 和输出均不改变，Auto 可从同一参数、同一源像素重新走 CPU。
    const size_t budget = std::min<size_t>(16u * 1024 * 1024, context.device.maxBufferLength);
    auto makeFilmOpticsParamsBuf = [&](const sony2fuji::FilmOpticsGpuParams& fp) -> id<MTLBuffer> {
        id<MTLBuffer> b = makeBuffer(context.device, sizeof(fp));
        if (b) std::memcpy(b.contents, &fp, sizeof(fp));
        return b;
    };
    auto buildMetalFilmOpticsGlow = [&](const ImageData& displaySrgb,
                                        const sony2fuji::FilmOpticsOptions& opt,
                                        __strong id<MTLBuffer>& outGlow,
                                        sony2fuji::FilmOpticsGpuParams& outComp) -> bool {
        outGlow = nil;
        outComp = {};
        if (!opt.active()) return true;
        const uint32_t srcW = static_cast<uint32_t>(displaySrgb.width);
        const uint32_t srcH = static_cast<uint32_t>(displaySrgb.height);
        const size_t srcRowBytes = static_cast<size_t>(srcW) * sizeof(RGB);
        const size_t maxSrcRows = budget / srcRowBytes;
        if (maxSrcRows == 0) {
            return failWith(sony2fuji::GpuFailureKind::Unsupported,
                sony2fuji::GpuBackendFault::UnsupportedCapability,
                "Image row exceeds Metal buffer limit");
        }
        auto runProxy = [&](bool isBloom, float thresh, float radiusParam,
                            uint32_t& outW, uint32_t& outH, __strong id<MTLBuffer>& outProxy) -> bool {
            const auto geom = sony2fuji::computeFilmOpticsProxyGeometry(
                displaySrgb.width, displaySrgb.height, radiusParam, isBloom, 1024);
            outW = static_cast<uint32_t>(geom.proxyWidth);
            outH = static_cast<uint32_t>(geom.proxyHeight);
            const uint32_t ch = isBloom ? 3u : 1u;
            const size_t totalPx = static_cast<size_t>(outW) * static_cast<size_t>(outH);
            const size_t totalBytes = totalPx * ch * sizeof(float);
            if (totalBytes > budget) {
                return failWith(sony2fuji::GpuFailureKind::Unsupported,
                    sony2fuji::GpuBackendFault::UnsupportedCapability,
                    "Film optics proxy buffer exceeds Metal buffer limit");
            }
            id<MTLBuffer> excess = makeBuffer(context.device, totalBytes);
            id<MTLBuffer> tmp = makeBuffer(context.device, totalBytes);
            id<MTLBuffer> core = makeBuffer(context.device, totalBytes);
            id<MTLBuffer> tail = makeBuffer(context.device, totalBytes);
            if (!excess || !tmp || !core || !tail) {
                return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                    sony2fuji::GpuBackendFault::DeviceError,
                    "Failed to allocate Metal film optics proxy buffers");
            }
            auto rowSpanForProxy = [&](uint32_t py) -> std::pair<uint32_t, uint32_t> {
                const uint32_t iy0 = static_cast<uint32_t>((uint64_t(py) * srcH) / outH);
                const uint32_t iy1 = std::min<uint32_t>(
                    srcH,
                    std::max<uint32_t>(iy0 + 1u, static_cast<uint32_t>((uint64_t(py + 1u) * srcH + outH - 1u) / outH)));
                return {iy0, iy1};
            };
            id<MTLBuffer> bandSrc = nil;
            size_t bandSrcCapacity = 0;
            for (uint32_t pyStart = 0; pyStart < outH;) {
                const auto firstSpan = rowSpanForProxy(pyStart);
                const uint32_t batchSrcY0 = firstSpan.first;
                uint32_t batchSrcY1 = firstSpan.second;
                if (batchSrcY1 - batchSrcY0 > maxSrcRows) {
                    return failWith(sony2fuji::GpuFailureKind::Unsupported,
                        sony2fuji::GpuBackendFault::UnsupportedCapability,
                        "Film optics proxy row span exceeds Metal band budget");
                }
                uint32_t pyEnd = pyStart + 1u;
                while (pyEnd < outH) {
                    const auto nextSpan = rowSpanForProxy(pyEnd);
                    if (nextSpan.second - batchSrcY0 > maxSrcRows) break;
                    batchSrcY1 = nextSpan.second;
                    ++pyEnd;
                }
                const uint32_t batchRows = pyEnd - pyStart;
                const size_t srcSpanBytes = static_cast<size_t>(batchSrcY1 - batchSrcY0) * srcRowBytes;
                if (!bandSrc || srcSpanBytes > bandSrcCapacity) {
                    bandSrc = makeBuffer(context.device, srcSpanBytes);
                    bandSrcCapacity = srcSpanBytes;
                    if (!bandSrc) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to allocate Metal film optics downsample band buffer");
                    }
                }
                std::memcpy(bandSrc.contents,
                    displaySrgb.pixels.data() + static_cast<size_t>(batchSrcY0) * srcW,
                    srcSpanBytes);
                sony2fuji::FilmOpticsGpuParams dp{};
                dp.width = srcW; dp.height = srcH;
                dp.proxyWidth = outW; dp.proxyHeight = outH;
                dp.rows = batchRows;
                dp.channelCount = ch;
                dp.srcRowOffset = batchSrcY0;
                dp.dstProxyRowOffset = pyStart;
                dp.halationThreshold = thresh;
                dp.bloomThreshold = thresh;
                id<MTLBuffer> dpBuf = makeFilmOpticsParamsBuf(dp);
                id<MTLCommandBuffer> cmd = [context.queue commandBuffer];
                if (!dpBuf || !cmd || !encodeKernel(cmd, context.filmOpticsDownsamplePipeline, dpBuf,
                    bandSrc, excess, nil, static_cast<size_t>(outW) * batchRows)) {
                    return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                        sony2fuji::GpuBackendFault::DeviceError,
                        "Failed to encode Metal film optics downsample pass");
                }
                [cmd commit];
                [cmd waitUntilCompleted];
                if (cmd.status != MTLCommandBufferStatusCompleted) {
                    return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                        sony2fuji::GpuBackendFault::DeviceError,
                        "Metal film optics downsample command failed");
                }
                pyStart = pyEnd;
            }
            auto makeBlurParams = [&](float sigma, int rad, uint32_t flags) {
                sony2fuji::FilmOpticsGpuParams bp{};
                bp.proxyWidth = outW; bp.proxyHeight = outH;
                bp.blurRadiusPx = static_cast<uint32_t>(rad);
                bp.channelCount = ch;
                bp.passFlags = flags;
                bp.proxySigma = sigma;
                bp.coreWeight = 0.40f;
                bp.tailWeight = 0.60f;
                return makeFilmOpticsParamsBuf(bp);
            };
            id<MTLBuffer> p1 = makeBlurParams(geom.coreSigma, geom.coreRadiusPx, 0u);
            id<MTLBuffer> p2 = makeBlurParams(geom.tailSigma, geom.tailRadiusPx, 1u);
            id<MTLCommandBuffer> cmd = [context.queue commandBuffer];
            if (!p1 || !p2 || !cmd ||
                !encodeKernel(cmd, context.filmOpticsBlurHPipeline, p1, excess, tmp, nil, totalPx) ||
                !encodeKernel(cmd, context.filmOpticsBlurVPipeline, p1, tmp, core, nil, totalPx, nullptr, nil, context.filmOpticsDummyBuffer) ||
                !encodeKernel(cmd, context.filmOpticsBlurHPipeline, p2, core, tmp, nil, totalPx) ||
                !encodeKernel(cmd, context.filmOpticsBlurVPipeline, p2, tmp, tail, nil, totalPx, nullptr, nil, core)) {
                return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                    sony2fuji::GpuBackendFault::DeviceError,
                    "Failed to encode Metal film optics blur passes");
            }
            [cmd commit];
            [cmd waitUntilCompleted];
            if (cmd.status != MTLCommandBufferStatusCompleted) {
                return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                    sony2fuji::GpuBackendFault::DeviceError,
                    "Metal film optics blur command failed");
            }
            outProxy = tail;
            return true;
        };

        const bool hasHal = opt.halationAmount > 0.0f;
        const bool hasBloom = opt.bloomAmount > 0.0f;
        uint32_t halW = 0, halH = 0, bloomW = 0, bloomH = 0;
        id<MTLBuffer> halBuf = nil, bloomBuf = nil;
        if (hasHal && !runProxy(false, opt.halationThreshold, opt.halationRadius, halW, halH, halBuf)) return false;
        if (hasBloom && !runProxy(true, opt.bloomThreshold, opt.bloomRadius, bloomW, bloomH, bloomBuf)) return false;

        if (hasHal && hasBloom) {
            const size_t halBytes = halBuf.length;
            const size_t bloomBytes = bloomBuf.length;
            if (halBytes + bloomBytes > budget) {
                return failWith(sony2fuji::GpuFailureKind::Unsupported,
                    sony2fuji::GpuBackendFault::UnsupportedCapability,
                    "Combined Metal film optics glow buffer exceeds limit");
            }
            outGlow = makeBuffer(context.device, halBytes + bloomBytes);
            if (!outGlow) {
                return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                    sony2fuji::GpuBackendFault::DeviceError,
                    "Failed to allocate Metal combined film optics glow buffer");
            }
            std::memcpy(outGlow.contents, halBuf.contents, halBytes);
            std::memcpy(static_cast<uint8_t*>(outGlow.contents) + halBytes, bloomBuf.contents, bloomBytes);
            outComp.bloomOffsetFloats = static_cast<uint32_t>(halBytes / sizeof(float));
        } else if (hasHal) {
            outGlow = halBuf;
            outComp.bloomOffsetFloats = 0u;
        } else if (hasBloom) {
            outGlow = bloomBuf;
            outComp.bloomOffsetFloats = 0u;
        }
        outComp.halProxyWidth = halW;
        outComp.halProxyHeight = halH;
        outComp.bloomProxyWidth = bloomW;
        outComp.bloomProxyHeight = bloomH;
        outComp.halationAmount = opt.halationAmount;
        outComp.halationHue = opt.halationHue;
        outComp.bloomAmount = opt.bloomAmount;
        return true;
    };
    id<MTLBuffer> dummyFieldBuffer = makeFloatBuffer(context.device, std::vector<float>{0.0f}, budget);
    if (!dummyFieldBuffer) {
        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
            sony2fuji::GpuBackendFault::DeviceError,
            "Failed to allocate Metal spatial dummy buffer");
    }
    id<MTLBuffer> dehazeFieldBuffer = dummyFieldBuffer;
    sony2fuji::SpatialGpuParams dehazeParamsTemplate{};
    id<MTLBuffer> clarityFieldBuffer = dummyFieldBuffer;
    sony2fuji::SpatialGpuParams clarityParamsTemplate{};

    enum MetalStageMask : uint32_t {
        kStagePreLook = 1u << 0,
        kStageDehaze = 1u << 1,
        kStageTone = 1u << 2,
        kStageNoise = 1u << 3,
        kStageClarity = 1u << 4,
        kStageTexture = 1u << 5,
        kStageFilmOptics = 1u << 6,
        kStagePostOptics = 1u << 7,
        kStagePostClarity = kStageTexture | kStageFilmOptics | kStagePostOptics,
    };

    auto runBands = [&](const ImageData& source, ImageData& destination, bool resizeFirst,
                        uint32_t stages, uint32_t resultWidth = 0, uint32_t resultHeight = 0,
                        id<MTLBuffer> filmOpticsGlow = nil, const sony2fuji::FilmOpticsGpuParams* filmOpticsComp = nullptr) -> bool {
        const uint32_t srcWidth = source.width, srcHeight = source.height;
        const uint32_t dstWidth = resultWidth ? resultWidth : destination.width;
        const uint32_t dstHeight = resultHeight ? resultHeight : destination.height;
        const uint32_t workWidth = resizeFirst ? dstWidth : srcWidth;
        const uint32_t workHeight = resizeFirst ? dstHeight : srcHeight;
        uint32_t halo = 0;
        if ((stages & kStagePreLook) && defringeActive) halo += 3u;
        if ((stages & kStageNoise) && renderParams.noiseReduction > 0.0f) halo += 1u;
        if ((stages & kStageTexture) && textureActive) halo += texRadius;
        if (stages & kStagePostOptics) {
            if (sharpenV2Active) halo += sharpMaskRadius + std::max(sharpRadius, 1u) + 1u;
            else if (renderParams.sharpening > 0.0f) halo += 1u;
        }
        const size_t srcRowBytes = size_t(srcWidth) * sizeof(RGB);
        const size_t workRowBytes = size_t(workWidth) * sizeof(RGB);
        const size_t dstRowBytes = size_t(dstWidth) * sizeof(RGB);
        if (srcRowBytes > budget || workRowBytes > budget || dstRowBytes > budget) {
            return failWith(sony2fuji::GpuFailureKind::Unsupported,
                sony2fuji::GpuBackendFault::UnsupportedCapability,
                "Image row exceeds Metal buffer limit");
        }
        const bool inplace = &source == &destination;
        if (inplace && (resizeFirst || srcWidth < dstWidth || srcHeight < dstHeight)) {
            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                sony2fuji::GpuBackendFault::DeviceError,
                "Invalid inplace Metal band configuration");
        }
        std::vector<RGB> previousRows;
        uint32_t previousFirst = 0, previousEnd = 0;
        const auto range = [](uint32_t row, uint32_t rows, uint32_t src, uint32_t dst, uint32_t padding) {
            // 双线性 kernel 即使权重为零也会读取下一行，同尺寸也必须包含它。
            if (src == dst) return std::pair<uint32_t, uint32_t>{row > padding ? row - padding : 0,
                std::min(src, row + rows + padding + 1)};
            const float scale = dst == 1 ? 0.f : float(src - 1) / float(dst - 1);
            const uint32_t first = uint32_t(float(row) * scale);
            const uint32_t last = uint32_t(float(row + rows - 1) * scale);
            // 多留一行覆盖 CPU 与 GPU 的坐标舍入边界，卷积另加自己的 halo。
            return std::pair<uint32_t, uint32_t>{first > padding + 1 ? first - padding - 1 : 0,
                std::min(src, last + padding + 3)};
        };
        const bool needAux1 = ((stages & kStageTexture) && textureActive) ||
            ((stages & kStagePostOptics) && sharpenV2Active);
        const bool needAux2 = (stages & kStagePostOptics) && sharpenV2Active;
        // 复用少量缓冲区，避免驱动缓存每一带已释放的分配而累积驻留内存。
        id<MTLBuffer> uploaded = makeBuffer(context.device, std::min(budget, size_t(srcHeight) * srcRowBytes));
        id<MTLBuffer> a = makeBuffer(context.device, std::min(budget, size_t(workHeight) * workRowBytes));
        id<MTLBuffer> b = resizeFirst ? makeBuffer(context.device, std::min(budget, size_t(workHeight) * workRowBytes)) : uploaded;
        id<MTLBuffer> aux1 = needAux1 ? makeBuffer(context.device, std::min(budget, size_t(workHeight) * workRowBytes)) : nil;
        id<MTLBuffer> aux2 = needAux2 ? makeBuffer(context.device, std::min(budget, size_t(workHeight) * workRowBytes)) : nil;
        id<MTLBuffer> final = makeBuffer(context.device, std::min(budget, size_t(dstHeight) * dstRowBytes));
        if (!uploaded || !a || !b || !final || (needAux1 && !aux1) || (needAux2 && !aux2)) {
            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                sony2fuji::GpuBackendFault::DeviceError,
                "Failed to allocate Metal working buffers");
        }
        for (uint32_t row = 0; row < dstHeight;) {
            // 每带在 waitUntilCompleted 后已同步写回 destination，带顶是安全边界：取消时后续带不再写入，
            // ProcessingCancelled 由 renderPhotoMetal 外层重抛（不吞成 false），调用方丢弃整个输出。
            sony2fuji::checkProcessingCancellation();
            @autoreleasepool {
                uint32_t rows = std::min<size_t>(dstHeight - row, budget / dstRowBytes);
                auto work = range(row, rows, workHeight, dstHeight, halo);
                auto upload = resizeFirst ? range(work.first, work.second - work.first, srcHeight, workHeight, 0) : work;
                while (rows > 1 && (size_t(work.second - work.first) * workRowBytes > budget ||
                       size_t(upload.second - upload.first) * srcRowBytes > budget)) {
                    rows = (rows + 1) / 2;
                    work = range(row, rows, workHeight, dstHeight, halo);
                    upload = resizeFirst ? range(work.first, work.second - work.first, srcHeight, workHeight, 0) : work;
                }
                const size_t uploadBytes = size_t(upload.second - upload.first) * srcRowBytes;
                const size_t workBytes = size_t(work.second - work.first) * workRowBytes;
                const size_t destinationBytes = size_t(rows) * dstRowBytes;
                if (uploadBytes > budget || workBytes > budget) {
                    return failWith(sony2fuji::GpuFailureKind::Unsupported,
                        sony2fuji::GpuBackendFault::UnsupportedCapability,
                        "Image band exceeds Metal buffer limit");
                }
                std::memcpy(uploaded.contents, source.pixels.data() + size_t(upload.first) * srcWidth, uploadBytes);
                if (inplace && upload.first < previousEnd) {
                    if (upload.first < previousFirst) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Invalid inplace Metal overlap");
                    }
                    const size_t count = size_t(previousEnd - upload.first) * srcWidth;
                    std::memcpy(uploaded.contents, previousRows.data() + size_t(upload.first - previousFirst) * srcWidth,
                        count * sizeof(RGB));
                }
                if (inplace) {
                    previousEnd = upload.second;
                    previousFirst = row + rows < dstHeight ?
                        range(row + rows, 1, srcHeight, dstHeight, halo).first : previousEnd;
                    previousFirst = std::min(previousFirst, previousEnd);
                    const auto* original = static_cast<const RGB*>(uploaded.contents);
                    previousRows.assign(original + size_t(previousFirst - upload.first) * srcWidth,
                        original + size_t(previousEnd - upload.first) * srcWidth);
                }
                id<MTLCommandBuffer> command = [context.queue commandBuffer];
                if (!command) {
                    return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                        sony2fuji::GpuBackendFault::DeviceError,
                        "Failed to create Metal command buffer");
                }
                if (useDcp) *static_cast<uint32_t*>(invalid.contents) = 0;
                id<MTLBuffer> current = uploaded, next = a;
                if (resizeFirst) {
                    auto params = makeParams(srcWidth, srcHeight, workWidth, workHeight,
                        toSRGB, toFGamut, renderParams, nullptr, lutStrength, false);
                    params.srcRowOffset = upload.first; params.dstRowOffset = work.first;
                    params.srcRows = upload.second - upload.first; params.dstRows = work.second - work.first;
                    auto constants = makeParamsBuffer(context.device, params);
                    if (!constants || !encodeKernel(command, context.resizePipeline, constants, current, a, nil,
                        size_t(workWidth) * params.dstRows)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal resize pass");
                    }
                    current = a; next = b;
                }
                const uint32_t bandRows = work.second - work.first;
                auto params = makeParams(workWidth, bandRows, dstWidth, dstHeight,
                    toSRGB, toFGamut, renderParams, useLUT ? &cachedLUT : nullptr, lutStrength, true);
                params.srcRowOffset = work.first;
                params.fullWorkHeight = workHeight;
                auto constants = makeParamsBuffer(context.device, params);
                if (!constants) {
                    return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                        sony2fuji::GpuBackendFault::DeviceError,
                        "Failed to allocate Metal parameter buffer");
                }
                auto run = [&](id<MTLComputePipelineState> pipeline, id<MTLTexture> texture,
                               const CachedDcp* stagesDcp = nullptr, id<MTLBuffer> extraBuffer = nil,
                               id<MTLBuffer> extraBuffer2 = nil) {
                    if (!encodeKernel(command, pipeline, constants, current, next, texture,
                        size_t(workWidth) * bandRows, stagesDcp, stagesDcp ? invalid : nil, extraBuffer, extraBuffer2)) return false;
                    std::swap(current, next);
                    return true;
                };
                auto makeBaseSp = [&]() {
                    sony2fuji::SpatialGpuParams sp{};
                    sp.width = workWidth;
                    sp.height = workHeight;
                    sp.rowOffset = work.first;
                    sp.rows = bandRows;
                    sp.srcRowOffset = work.first;
                    sp.auxRowOffset = work.first;
                    sp.bandDims[0] = bandRows;
                    sp.bandDims[1] = bandRows;
                    return sp;
                };
                if (stages & kStagePreLook) {
                    if (!run(context.matrixExposurePipeline, nil, nullptr, basicFieldBuffer, colorScienceBuffer)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal matrix/exposure pass");
                    }
                    if (defringeActive) {
                        auto sp = makeBaseSp();
                        sony2fuji::fillSpatialDefringeParams(renderParams.defringe, sp);
                        if (!encodeSpatialKernel(command, context.defringePipeline, context.device, sp,
                                                 current, next, current, dummyFieldBuffer)) {
                            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                                sony2fuji::GpuBackendFault::DeviceError,
                                "Failed to encode Metal defringe pass");
                        }
                        std::swap(current, next);
                    }
                    if (!run(useDcp ? context.baseDcpPipeline : context.baseLutPipeline,
                             useLUT ? cachedLUT.texture : nil, useDcp ? &cachedDcp : nullptr)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal look pass");
                    }
                }
                if ((stages & kStageDehaze) && dehazeActive) {
                    auto sp = dehazeParamsTemplate;
                    sp.width = workWidth;
                    sp.height = workHeight;
                    sp.rowOffset = work.first;
                    sp.rows = bandRows;
                    sp.srcRowOffset = work.first;
                    sp.auxRowOffset = work.first;
                    sp.bandDims[0] = bandRows;
                    sp.bandDims[1] = bandRows;
                    sp.strength = renderParams.atmosphere.dehaze;
                    if (!encodeSpatialKernel(command, context.dehazePipeline, context.device, sp,
                                             current, next, current, dehazeFieldBuffer)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal dehaze pass");
                    }
                    std::swap(current, next);
                }
                if (stages & kStageTone) {
                    if (!run(context.tonePipeline, nil, nullptr, colorScienceBuffer)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal tone pass");
                    }
                }
                if ((stages & kStageNoise) && renderParams.noiseReduction > 0.0f) {
                    if (!run(context.noisePipeline, nil)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal noise reduction pass");
                    }
                }
                if ((stages & kStageClarity) && clarityActive) {
                    auto sp = clarityParamsTemplate;
                    sp.width = workWidth;
                    sp.height = workHeight;
                    sp.rowOffset = work.first;
                    sp.rows = bandRows;
                    sp.srcRowOffset = work.first;
                    sp.auxRowOffset = work.first;
                    sp.bandDims[0] = bandRows;
                    sp.bandDims[1] = bandRows;
                    sp.strength = renderParams.atmosphere.clarity;
                    if (!encodeSpatialKernel(command, context.clarityPipeline, context.device, sp,
                                             current, next, current, clarityFieldBuffer)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal clarity pass");
                    }
                    std::swap(current, next);
                }
                if ((stages & kStageTexture) && textureActive) {
                    auto sp = makeBaseSp();
                    sp.strength = renderParams.atmosphere.texture;
                    sony2fuji::fillSpatialGaussianWeights(texSigma, 12, sp);
                    if (!encodeSpatialKernel(command, context.textureBlurHPipeline, context.device, sp,
                                             current, aux1, current, dummyFieldBuffer) ||
                        !encodeSpatialKernel(command, context.textureApplyVPipeline, context.device, sp,
                                             current, next, aux1, dummyFieldBuffer)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal texture pass");
                    }
                    std::swap(current, next);
                }
                if ((stages & kStageFilmOptics) && renderParams.filmOptics.active() &&
                    filmOpticsGlow != nil && filmOpticsComp != nullptr) {
                    auto comp = *filmOpticsComp;
                    comp.width = workWidth;
                    comp.height = workHeight;
                    comp.rowOffset = work.first;
                    comp.rows = bandRows;
                    id<MTLBuffer> foConstants = makeFilmOpticsParamsBuf(comp);
                    if (!foConstants || !encodeKernel(command, context.filmOpticsCompositePipeline, foConstants,
                        current, next, nil, size_t(workWidth) * bandRows, nullptr, nil, filmOpticsGlow)) {
                        return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                            sony2fuji::GpuBackendFault::DeviceError,
                            "Failed to encode Metal film optics composite pass");
                    }
                    std::swap(current, next);
                }
                if (stages & kStagePostOptics) {
                    if (sharpenV2Active) {
                        auto spSharp = makeBaseSp();
                        sony2fuji::fillSpatialSharpenV2Params(renderParams.sharpening, renderParams.sharpenV2, spSharp);
                        sony2fuji::fillSpatialGaussianWeights(sharpSigma, 9, spSharp);
                        if (!encodeSpatialKernel(command, context.sharpenPrepHPipeline, context.device, spSharp,
                                                 current, aux1, current, dummyFieldBuffer) ||
                            !encodeSpatialKernel(command, context.sharpenPrepVPipeline, context.device, spSharp,
                                                 aux1, aux2, aux1, dummyFieldBuffer)) {
                            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                                sony2fuji::GpuBackendFault::DeviceError,
                                "Failed to encode Metal sharpen v2 prep pass");
                        }
                        id<MTLBuffer> sharpenAux = aux2;
                        auto spApply = spSharp;
                        if (sharpMaskRadius > 0u) {
                            auto spMask = spSharp;
                            sony2fuji::fillSpatialGaussianWeights(0.5f * sharpSigma, 5, spMask);
                            if (!encodeSpatialKernel(command, context.sharpenMaskHPipeline, context.device, spMask,
                                                     aux2, aux1, aux2, dummyFieldBuffer)) {
                                return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                                    sony2fuji::GpuBackendFault::DeviceError,
                                    "Failed to encode Metal sharpen v2 mask pass");
                            }
                            sharpenAux = aux1;
                            spApply = spMask;
                        }
                        if (!encodeSpatialKernel(command, context.sharpenApplyPipeline, context.device, spApply,
                                                 current, next, sharpenAux, dummyFieldBuffer)) {
                            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                                sony2fuji::GpuBackendFault::DeviceError,
                                "Failed to encode Metal sharpen v2 apply pass");
                        }
                        std::swap(current, next);
                    } else if (renderParams.sharpening > 0.0f) {
                        if (!run(context.sharpenPipeline, nil)) {
                            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                                sony2fuji::GpuBackendFault::DeviceError,
                                "Failed to encode Metal sharpen pass");
                        }
                    }
                    if (renderParams.effects.active()) {
                        const PhotoEffectsParams values{workWidth, workHeight, renderParams.effects, work.first, bandRows};
                        id<MTLBuffer> effectConstants = [context.device newBufferWithBytes:&values
                            length:sizeof(values) options:MTLResourceStorageModeShared];
                        if (!effectConstants || !encodeKernel(command, context.effectsPipeline, effectConstants,
                            current, next, nil, size_t(workWidth) * bandRows)) {
                            return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                                sony2fuji::GpuBackendFault::DeviceError,
                                "Failed to encode Metal photo effects pass");
                        }
                        std::swap(current, next);
                    }
                }
                auto resize = makeParams(workWidth, workHeight, dstWidth, dstHeight,
                    toSRGB, toFGamut, renderParams, nullptr, lutStrength, false);
                resize.srcRowOffset = work.first; resize.dstRowOffset = row;
                resize.srcRows = bandRows; resize.dstRows = rows;
                auto resizeConstants = makeParamsBuffer(context.device, resize);
                if (!resizeConstants || !encodeKernel(command, context.resizePipeline, resizeConstants,
                    current, final, nil, size_t(dstWidth) * rows)) {
                    return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                        sony2fuji::GpuBackendFault::DeviceError,
                        "Failed to encode Metal output resize pass");
                }
                [command commit];
                [command waitUntilCompleted];
                if (command.status != MTLCommandBufferStatusCompleted ||
                    (useDcp && *static_cast<const uint32_t*>(invalid.contents) != 0)) {
                    const char* detail = command.error ? command.error.localizedDescription.UTF8String : nullptr;
                    return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                        sony2fuji::GpuBackendFault::DeviceError,
                        detail && *detail ? detail : "Metal command buffer execution failed");
                }
                std::memcpy(destination.pixels.data() + size_t(row) * dstWidth, final.contents, destinationBytes);
                row += rows;
            }
        }
        destination.width = dstWidth; destination.height = dstHeight;
        destination.pixels.resize(size_t(dstWidth) * dstHeight);
        return true;
    };

    const int diagSrcW = renderParams.atmosphereSourceWidth > 0 ? renderParams.atmosphereSourceWidth : static_cast<int>(processingWidth);
    const int diagSrcH = renderParams.atmosphereSourceHeight > 0 ? renderParams.atmosphereSourceHeight : static_cast<int>(processingHeight);
    const bool filmOpticsActive = renderParams.filmOptics.active();
    ImageData result;
    if (!dehazeActive && renderParams.chromaDenoise == 0 && !clarityActive && !filmOpticsActive) {
        result = ImageData(static_cast<int>(targetWidth), static_cast<int>(targetHeight));
        if (!runBands(input, result, earlyResize, kStagePreLook | kStageTone | kStageNoise | kStagePostClarity)) {
            return false;
        }
    } else {
        ImageData work(static_cast<int>(processingWidth), static_cast<int>(processingHeight));
        if (dehazeActive) {
            if (!runBands(input, work, earlyResize, kStagePreLook)) return false;
            const auto dehazeState = sony2fuji::buildDehazeAnalysis(work, diagSrcW, diagSrcH, renderParams.processingVersion);
            std::vector<float> dehazeData;
            sony2fuji::packDehazeAnalysisBuffer(dehazeState, dehazeData, dehazeParamsTemplate);
            dehazeFieldBuffer = makeFloatBuffer(context.device, dehazeData, budget);
            if (!dehazeFieldBuffer) {
                return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                    sony2fuji::GpuBackendFault::DeviceError,
                    "Failed to upload Metal dehaze field buffer");
            }
            if (renderParams.chromaDenoise == 0 && !clarityActive && !filmOpticsActive) {
                result = ImageData(static_cast<int>(targetWidth), static_cast<int>(targetHeight));
                if (!runBands(work, result, false, kStageDehaze | kStageTone | kStageNoise | kStagePostClarity)) return false;
                output = std::move(result);
                return true;
            }
            if (!runBands(work, work, false, kStageDehaze | kStageTone)) return false;
        } else {
            const uint32_t earlyStages = (renderParams.chromaDenoise == 0 && !clarityActive)
                ? (kStagePreLook | kStageTone | kStageNoise | kStageTexture)
                : (kStagePreLook | kStageTone);
            if (!runBands(input, work, earlyResize, earlyStages)) return false;
        }

        if (renderParams.chromaDenoise != 0) {
            // 全图噪声模型只估计一次，不能让分带改变颜色降噪的统计或边界。
            sony2fuji::lastGpuFilterOutcome() = {};
            const auto chromaErr = sony2fuji::applyChromaDenoiseWorking(work, renderParams.chromaDenoise, nullptr, sony2fuji::GpuMode::Force);
            if (chromaErr != sony2fuji::ErrorCode::Success) {
                const auto filterOutcome = sony2fuji::lastGpuFilterOutcome();
                if (chromaErr == sony2fuji::ErrorCode::OutOfMemory || filterOutcome.failure == sony2fuji::GpuFailureKind::OutOfMemory) {
                    outcome = {sony2fuji::GpuFailureKind::OutOfMemory, sony2fuji::GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? "Out of memory during Metal chroma denoise" : filterOutcome.message};
                } else if (chromaErr == sony2fuji::ErrorCode::Unsupported || filterOutcome.failure == sony2fuji::GpuFailureKind::Unsupported) {
                    outcome = {sony2fuji::GpuFailureKind::Unsupported,
                        filterOutcome.fault != sony2fuji::GpuBackendFault::None ? filterOutcome.fault : sony2fuji::GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? "Metal chroma denoise unavailable" : filterOutcome.message};
                } else {
                    outcome = {sony2fuji::GpuFailureKind::ProcessingError, sony2fuji::GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? "Metal chroma denoise failed" : filterOutcome.message};
                }
                return false;
            }
        }

        if (clarityActive) {
            if (renderParams.noiseReduction > 0.0f) {
                if (!runBands(work, work, false, kStageNoise)) return false;
            }
            const auto clarityState = sony2fuji::buildClarityField(work, diagSrcW, diagSrcH, renderParams.processingVersion);
            std::vector<float> clarityData;
            sony2fuji::packClarityFieldBuffer(clarityState, clarityData, clarityParamsTemplate);
            clarityFieldBuffer = makeFloatBuffer(context.device, clarityData, budget);
            if (!clarityFieldBuffer) {
                return failWith(sony2fuji::GpuFailureKind::ProcessingError,
                    sony2fuji::GpuBackendFault::DeviceError,
                    "Failed to upload Metal clarity field buffer");
            }
            if (!filmOpticsActive) {
                result = ImageData(static_cast<int>(targetWidth), static_cast<int>(targetHeight));
                if (!runBands(work, result, false, kStageClarity | kStagePostClarity)) return false;
                output = std::move(result);
                return true;
            }
            if (!runBands(work, work, false, kStageClarity | kStageTexture)) return false;
        } else if (!filmOpticsActive) {
            result = ImageData(static_cast<int>(targetWidth), static_cast<int>(targetHeight));
            if (!runBands(work, result, false, kStageNoise | kStagePostClarity)) return false;
            output = std::move(result);
            return true;
        } else if (dehazeActive || renderParams.chromaDenoise != 0) {
            if (renderParams.noiseReduction > 0.0f || textureActive) {
                if (!runBands(work, work, false, kStageNoise | kStageTexture)) return false;
            }
        }

        id<MTLBuffer> filmOpticsGlow = nil;
        sony2fuji::FilmOpticsGpuParams filmOpticsComp{};
        if (!buildMetalFilmOpticsGlow(work, renderParams.filmOptics, filmOpticsGlow, filmOpticsComp)) {
            return false;
        }
        result = ImageData(static_cast<int>(targetWidth), static_cast<int>(targetHeight));
        if (!runBands(work, result, false, kStageFilmOptics | kStagePostOptics, 0, 0, filmOpticsGlow, &filmOpticsComp)) {
            return false;
        }
    }
    output = std::move(result);
    return true;
}

} // namespace

namespace sony2fuji {

GpuRenderOutcome renderPhotoMetalWithOutcome(
    const ImageData& input,
    ColorSpace inputSpace,
    const RenderParams& params,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output
) {
    GpuRenderOutcome outcome;
    @try {
        @autoreleasepool {
            try {
                if (renderPhotoMetalImpl(input, inputSpace, params, targetWidth, targetHeight, output, outcome)) {
                    outcome = {};
                } else if (outcome.succeeded()) {
                    outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, "Metal photo render failed"};
                }
            } catch (const ProcessingCancelled&) {
                throw;
            } catch (const std::bad_alloc& error) {
                outcome = {GpuFailureKind::OutOfMemory, GpuBackendFault::DeviceError, error.what()};
            } catch (const std::exception& error) {
                outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, error.what()};
            } catch (...) {
                outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, "Metal photo render failed"};
            }
        }
    } @catch (NSException* exception) {
        const char* reason = exception.reason ? exception.reason.UTF8String : nullptr;
        outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError,
            reason && *reason ? reason : "Metal Objective-C exception"};
    }
    return outcome;
}

bool renderPhotoMetal(
    const ImageData& input,
    ColorSpace inputSpace,
    const RenderParams& params,
    uint32_t targetWidth,
    uint32_t targetHeight,
    ImageData& output
) {
    bool result = false;
    GpuRenderOutcome outcome;
    @try {
        @autoreleasepool {
            try {
                result = renderPhotoMetalImpl(
                    input, inputSpace, params, targetWidth, targetHeight, output, outcome
                );
            } catch (const ProcessingCancelled&) {
                // 取消不是渲染失败：在 catch(...) 之前原样重抛（对齐 gles_photo 的先例），
                // 否则 Auto 会把它当成 GPU 失败静默回退 CPU 重跑整张图。
                throw;
            } catch (const std::bad_alloc&) {
                throw;
            } catch (...) {
                result = false;
            }
        }
    } @catch (NSException*) {
        result = false;
    }
    return result;
}

PhotoGpuCapabilities queryMetalPhotoCapabilities(uint32_t width, uint32_t height) noexcept {
    PhotoGpuCapabilities caps{};
    caps.compiled = true;
    @autoreleasepool {
        MetalContext& context = metalContext();
        if (!context.device || !context.ready) {
            return caps;
        }
        caps.ready = true;
        caps.supportsEffects = context.effectsPipeline != nil;
        caps.supportsDcp = context.baseDcpPipeline != nil;
        caps.supportsFilmOptics = context.filmOpticsDownsamplePipeline != nil &&
            context.filmOpticsBlurHPipeline != nil &&
            context.filmOpticsBlurVPipeline != nil &&
            context.filmOpticsCompositePipeline != nil &&
            context.filmOpticsDummyBuffer != nil;
        size_t pixelCount = 0;
        if (!checkedCount(width, height, &pixelCount)) {
            caps.dimensionsSupported = false;
            return caps;
        }
        const size_t budget = std::min<size_t>(16u * 1024 * 1024, context.device.maxBufferLength);
        const size_t rowBytes = static_cast<size_t>(width) * sizeof(RGB);
        caps.dimensionsSupported = rowBytes > 0 && rowBytes <= budget;
        return caps;
    }
}

} // namespace sony2fuji

#else

namespace sony2fuji {

GpuRenderOutcome renderPhotoMetalWithOutcome(
    const ImageData&,
    ColorSpace,
    const RenderParams&,
    uint32_t,
    uint32_t,
    ImageData&
) {
    return {GpuFailureKind::Unsupported, GpuBackendFault::GpuDisabled, "Metal backend is not enabled in this build"};
}

bool renderPhotoMetal(
    const ImageData&,
    ColorSpace,
    const RenderParams&,
    uint32_t,
    uint32_t,
    ImageData&
) {
    return false;
}

PhotoGpuCapabilities queryMetalPhotoCapabilities(uint32_t, uint32_t) noexcept {
    return {};
}

} // namespace sony2fuji

#endif
