#pragma once
#include "dcp_look_shader.h"
#include "photo_log_shader.h"
#include "photo_spatial_shader.h"
#include "photo_tone_shader.h"
#include "photo_color_grading_shader.h"
#include "photo_tone_curve_shader.h"
#include "photo_color_science_shader.h"

namespace sony2fuji {
inline const std::string kPhotoComputeShader = std::string(R"glsl(#version 310 es
precision highp float;
precision highp int;
)glsl") + toneControlsShader("vec3") + colorGradingShader("vec3") + toneCurveShader("vec3") + photoLogShader(ShaderDialect::Glsl) + colorScienceShader(ShaderDialect::Glsl) + R"glsl(
layout(local_size_x = 128) in;
layout(std430, binding = 0) readonly buffer Source { float src[]; };
layout(std430, binding = 1) writeonly buffer Destination { float dst[]; };
layout(std430, binding = 2) readonly buffer AuxField { float auxField[]; };
layout(std430, binding = 3) writeonly buffer DcpInvalid { uint dcpInvalid[]; };
layout(binding = 0) uniform highp sampler3D film;
uniform uvec2 sourceSize;
uniform uvec2 destinationSize;
uniform uint sourceStartRow;
uniform uint destinationStartRow;
uniform uint pixelCount;
uniform uint outputOffset;
uniform int stage;
uniform int evalPhase;
uniform bool useLut;
uniform bool inputIsSRGB;
uniform bool inputIsFLog;
uniform bool outputIsLog;
uniform bool outputIsFLog;
uniform int lutSize;
uniform mat3 toSrgb;
uniform mat3 toFGamut;
uniform vec3 exposureWB;
uniform float strength;
uniform vec3 domainMin;
uniform vec3 domainMax;
uniform vec4 tone; // contrast, saturation, highlights, shadows
uniform float curve;
layout(std140, binding = 0) uniform CurveParams {
    uvec4 curveCounts;
    uvec4 curveFlags;
    vec4 parametricAmps;
    vec4 parametricSplits;
    vec4 curveRanges[128];
    vec4 curveTangents[128];
};
layout(std140, binding = 1) uniform DcpParams {
    vec4 dcpInput[3];
    vec4 dcpOutput[3];
    vec4 dcpExposure;
    uvec4 dcpCalib;
    uvec4 dcpLook;
    uvec4 dcpOffsets; // lookOffset, toneOffset, dataBaseOffset, active
};
uniform bool hslActive;
uniform vec3 toneControls;
uniform vec4 colorGrading[4];
uniform vec4 colorGradingMix;
uniform vec4 hslHue[2];
uniform vec4 hslSaturation[2];
uniform vec4 hslLightness[2];
uniform int basicV3;
uniform int basicToneActive;
uniform uvec2 basicFieldSize;
uniform vec4 basicTone;

vec3 readPixel(uvec2 xy) {
    uint i = ((xy.y - sourceStartRow) * sourceSize.x + xy.x) * 3u;
    return vec3(src[i], src[i + 1u], src[i + 2u]);
}
float neutral(float x) {
    if (x <= 0.0) return 0.0;
    const float gray = 0.1845;
    float linear = 1.0 / (1.0 + (1.0 - gray) / gray * pow(gray / x, 1.5));
    return linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
}
float dcpSrgbGamma(float x) {
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}
#define DCP_FN
#define DCP_V3 vec3
#define DCP_V3C(x, y, z) vec3((x), (y), (z))
#define DCP_U3 uvec3
#define DCP_U3C(x, y, z) uvec3((x), (y), (z))
#define DCP_U4 uvec4
#define DCP_CTX_DECL
#define DCP_CTX_ARG
#define DCP_SRGB_GAMMA(x) dcpSrgbGamma(x)
#define DCP_NEUTRAL(x) neutral(x)
#define DCP_LERP3(a, b, t) mix((a), (b), (t))
#define DCP_FINITE(v) (abs((v).x) <= 3.4e38 && abs((v).y) <= 3.4e38 && abs((v).z) <= 3.4e38)
#define DCP_DATA(idx) auxField[dcpOffsets.z + (idx)]
#define DCP_MARK_INVALID (dcpInvalid[0] = 1u)
)glsl" + dcpLookShaderBody() + R"glsl(
#undef DCP_FN
#undef DCP_V3
#undef DCP_V3C
#undef DCP_U3
#undef DCP_U3C
#undef DCP_U4
#undef DCP_CTX_DECL
#undef DCP_CTX_ARG
#undef DCP_SRGB_GAMMA
#undef DCP_NEUTRAL
#undef DCP_LERP3
#undef DCP_FINITE
#undef DCP_DATA
#undef DCP_MARK_INVALID
vec3 lookup(vec3 x) {
    vec3 p = clamp((x - domainMin) / (domainMax - domainMin), 0.0, 1.0) * float(lutSize - 1);
    ivec3 low = ivec3(floor(p));
    ivec3 high = min(low + 1, ivec3(lutSize - 1));
    vec3 t = p - vec3(low);
    vec3 c00 = mix(texelFetch(film, low, 0).rgb,
        texelFetch(film, ivec3(low.xy, high.z), 0).rgb, t.z);
    vec3 c01 = mix(texelFetch(film, ivec3(low.x, high.y, low.z), 0).rgb,
        texelFetch(film, ivec3(low.x, high.yz), 0).rgb, t.z);
    vec3 c10 = mix(texelFetch(film, ivec3(high.x, low.yz), 0).rgb,
        texelFetch(film, ivec3(high.x, low.y, high.z), 0).rgb, t.z);
    vec3 c11 = mix(texelFetch(film, ivec3(high.xy, low.z), 0).rgb,
        texelFetch(film, high, 0).rgb, t.z);
    return mix(mix(c00, c01, t.y), mix(c10, c11, t.y), t.x);
}
float toneCurve(float x) {
    float s = sign(curve) * pow(abs(curve), 1.2);
    vec3 points = clamp(vec3(0.25 - s * 0.2, 0.5 + s * 0.05, 0.75 + s * 0.2), 0.0, 1.0);
    x = clamp(x, 0.0, 1.0);
    if (x <= 0.25) return x * 4.0 * points.x;
    if (x <= 0.5) return mix(points.x, points.y, (x - 0.25) * 4.0);
    if (x <= 0.75) return mix(points.y, points.z, (x - 0.5) * 4.0);
    return mix(points.z, 1.0, (x - 0.75) * 4.0);
}
float customToneCurve(float x, int count, int base) {
    if (count == 0) return x;
    if (x <= curveRanges[base].x) return curveRanges[base].z;
    if (x >= curveRanges[base + count - 1].y) return curveRanges[base + count - 1].w;
    int i = 0;
    while (i + 1 < count && x > curveRanges[base + i].y) ++i;
    vec4 r = curveRanges[base + i];
    vec4 t = curveTangents[base + i];
    return pchipSegment(x, r.x, r.y, r.z, r.w, t.x, t.y);
}
float evalMasterTone(float x) {
    if (curveFlags.y != 0u) {
        x = tcParametric(x, parametricAmps.x, parametricAmps.y, parametricAmps.z, parametricAmps.w,
            parametricSplits.x, parametricSplits.y, parametricSplits.z);
    }
    if (curveCounts.x != 0u) return customToneCurve(x, int(curveCounts.x), 0);
    if (curve != 0.0) return toneCurve(x);
    return x;
}
vec3 applyHsl(vec3 pixel) {
    if (!hslActive) return pixel;
    float maximum = max(pixel.r, max(pixel.g, pixel.b));
    float minimum = min(pixel.r, min(pixel.g, pixel.b));
    float delta = maximum - minimum;
    if (delta <= 1e-6) return pixel;
    float hue = maximum == pixel.r ? 60.0 * (pixel.g - pixel.b) / delta :
        maximum == pixel.g ? 60.0 * ((pixel.b - pixel.r) / delta + 2.0) :
        60.0 * ((pixel.r - pixel.g) / delta + 4.0);
    if (hue < 0.0) hue += 360.0;
    const float centers[9] = float[9](0.0,30.0,60.0,120.0,180.0,240.0,270.0,300.0,360.0);
    int lower = 0;
    while (lower < 7 && hue >= centers[lower + 1]) ++lower;
    int upper = (lower + 1) % 8;
    float blend = (hue - centers[lower]) / (centers[lower + 1] - centers[lower]);
    blend = blend * blend * (3.0 - 2.0 * blend);
    float dh = hslHue[lower / 4][lower % 4] * (1.0 - blend) + hslHue[upper / 4][upper % 4] * blend;
    float ds = hslSaturation[lower / 4][lower % 4] * (1.0 - blend) + hslSaturation[upper / 4][upper % 4] * blend;
    float dl = hslLightness[lower / 4][lower % 4] * (1.0 - blend) + hslLightness[upper / 4][upper % 4] * blend;
    float colorWeight = clamp(delta * 255.0, 0.0, 1.0);
    dl *= colorWeight * colorWeight * (3.0 - 2.0 * colorWeight);
    if (dh == 0.0 && ds == 0.0 && dl == 0.0) return pixel;
    float lightness = clamp((maximum + minimum) * 0.5, 0.0, 1.0);
    float saturation = delta / max(1e-6, 1.0 - abs(2.0 * lightness - 1.0));
    vec3 residual = vec3(0.0);
    if (minimum < 0.0 || maximum > 1.0) {
        float baseChroma = (1.0 - abs(2.0 * lightness - 1.0)) * clamp(saturation, 0.0, 1.0);
        residual = pixel - ((pixel - minimum) * (baseChroma / delta) + (lightness - baseChroma * 0.5));
    }
    hue = mod(hue + dh * 0.3 + 360.0, 360.0);
    saturation = clamp(saturation * (1.0 + ds * 0.01), 0.0, 1.0);
    lightness = clamp(lightness + dl * 0.005, 0.0, 1.0);
    float chroma = (1.0 - abs(2.0 * lightness - 1.0)) * saturation;
    float x = chroma * (1.0 - abs(mod(hue / 60.0, 2.0) - 1.0));
    vec3 rgb = hue < 60.0 ? vec3(chroma,x,0) : hue < 120.0 ? vec3(x,chroma,0) :
        hue < 180.0 ? vec3(0,chroma,x) : hue < 240.0 ? vec3(0,x,chroma) :
        hue < 300.0 ? vec3(x,0,chroma) : vec3(chroma,0,x);
    return rgb + (lightness - chroma * 0.5) + residual;
}

vec2 sampleBasicToneField(uvec2 coord, uvec2 coordSize) {
    uint fw = max(1u, basicFieldSize.x);
    uint fh = max(1u, basicFieldSize.y);
    vec2 maxIdx = vec2(float(fw - 1u), float(fh - 1u));
    vec2 f = clamp((vec2(coord) + 0.5) * vec2(float(fw), float(fh)) / vec2(coordSize) - 0.5, vec2(0.0), maxIdx);
    uvec2 low = uvec2(floor(f));
    uvec2 high = min(low + 1u, uvec2(fw - 1u, fh - 1u));
    vec2 t = f - vec2(low);
    uint i00 = (low.y * fw + low.x) * 2u;
    uint i10 = (low.y * fw + high.x) * 2u;
    uint i01 = (high.y * fw + low.x) * 2u;
    uint i11 = (high.y * fw + high.x) * 2u;
    vec2 v00 = vec2(auxField[i00], auxField[i00 + 1u]);
    vec2 v10 = vec2(auxField[i10], auxField[i10 + 1u]);
    vec2 v01 = vec2(auxField[i01], auxField[i01 + 1u]);
    vec2 v11 = vec2(auxField[i11], auxField[i11 + 1u]);
    return mix(mix(v00, v10, t.x), mix(v01, v11, t.x), t.y);
}

vec3 evaluate(vec3 inputColor, uvec2 coord, uvec2 coordSize) {
    vec3 pixel = inputColor;
    if (evalPhase != 2 && evalPhase != 3) {
        vec3 linear = csApplyCalibration((toSrgb * inputColor) * exposureWB);
        if (basicToneActive != 0) {
            vec2 si = sampleBasicToneField(coord, coordSize);
            linear *= tcBasicToneV3Gain(tcLuminance(linear), si.x, si.y, basicTone.x, basicTone.y);
        }
        if (evalPhase == 1) return linear;
        inputColor = linear;
    }
    if (evalPhase != 3) {
        vec3 linear = inputColor;
        if (dcpOffsets.w != 0u) {
            pixel = dcpApplyLookPixel(
                linear,
                dcpInput[0].xyz, dcpInput[1].xyz, dcpInput[2].xyz,
                dcpOutput[0].xyz, dcpOutput[1].xyz, dcpOutput[2].xyz,
                dcpExposure.x,
                dcpCalib, dcpLook, dcpOffsets.x, dcpOffsets.y, strength);
        } else {
            pixel = vec3(neutral(linear.r), neutral(linear.g), neutral(linear.b));
            if (useLut) {
                vec3 lookInput = pixel;
                if (!inputIsSRGB) {
                    vec3 fgamut = toFGamut * linear;
                    lookInput = vec3(encodePhotoLog(fgamut.r, inputIsFLog), encodePhotoLog(fgamut.g, inputIsFLog), encodePhotoLog(fgamut.b, inputIsFLog));
                }
                vec3 look = lookup(lookInput);
                if (outputIsLog) look = vec3(neutral(decodePhotoLog(look.r, outputIsFLog)), neutral(decodePhotoLog(look.g, outputIsFLog)), neutral(decodePhotoLog(look.b, outputIsFLog)));
                pixel = mix(pixel, look, strength);
            }
        }
        if (evalPhase == 2 || evalPhase == 4) return pixel;
    }
    pixel = csApplyBwMixer(pixel);
    pixel = basicV3 != 0 ? tcBasicBlackWhiteV3(pixel, toneControls.x, toneControls.y)
        : tcBlackWhite(pixel, toneControls.x, toneControls.y);
    if (basicV3 == 0) {
        pixel = hsApplyHighlightsShadows(pixel, tone.z, tone.w);
    }
    bool masterActive = curveFlags.y != 0u || curveCounts.x != 0u || curve != 0.0;
    if (masterActive) {
        if (curveFlags.x != 0u) {
            vec3 pL = vec3(tcSrgbToLinear(pixel.r), tcSrgbToLinear(pixel.g), tcSrgbToLinear(pixel.b));
            float Y = tcLuminosityLinearY(pL);
            float u = tcLinearToSrgb(max(0.0, Y));
            float uPrime = evalMasterTone(u);
            float Y0 = tcSrgbToLinear(evalMasterTone(0.0));
            pixel = tcLuminosityFinish(pL, Y, uPrime, Y0);
        } else {
            pixel = vec3(evalMasterTone(pixel.r), evalMasterTone(pixel.g), evalMasterTone(pixel.b));
        }
    }
    pixel.r = customToneCurve(pixel.r, int(curveCounts.y), 32);
    pixel.g = customToneCurve(pixel.g, int(curveCounts.z), 64);
    pixel.b = customToneCurve(pixel.b, int(curveCounts.w), 96);
    if (basicV3 != 0 && tone.x != 1.0) {
        pixel = vec3(tcBasicContrastV3(pixel.r, tone.x - 1.0), tcBasicContrastV3(pixel.g, tone.x - 1.0), tcBasicContrastV3(pixel.b, tone.x - 1.0));
    }
    if ((basicV3 == 0 && tone.x != 1.0) || tone.y != 1.0) {
        if (basicV3 == 0) pixel = (pixel - 0.5) * tone.x + 0.5;
        float luminance = dot(pixel, vec3(0.2126, 0.7152, 0.0722));
        pixel = vec3(luminance) + (pixel - luminance) * tone.y;
    }
    vec3 vibranced = basicV3 != 0 ? tcBasicVibranceV3(pixel, toneControls.z) : tcVibrance(pixel, toneControls.z);
    vec3 colored = csApplySelectiveColor(csApplyPointColor(applyHsl(vibranced)));
    return cgApply(colored,
        colorGrading[0].xyz, colorGrading[0].w,
        colorGrading[1].xyz, colorGrading[1].w,
        colorGrading[2].xyz, colorGrading[2].w,
        colorGrading[3].xyz, colorGrading[3].w,
        colorGradingMix.x, colorGradingMix.y);
}
void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pixelCount) return;
    uvec2 xy = uvec2(i % destinationSize.x, destinationStartRow + i / destinationSize.x);
    vec3 value;
    if (stage == 1 || (stage == 2 && all(equal(sourceSize, destinationSize)))) {
        value = evaluate(readPixel(xy), xy, stage == 1 ? destinationSize : sourceSize);
    } else {
        vec2 scale = vec2(destinationSize.x == 1u ? 0.0 : float(sourceSize.x - 1u) / float(destinationSize.x - 1u),
            destinationSize.y == 1u ? 0.0 : float(sourceSize.y - 1u) / float(destinationSize.y - 1u));
        vec2 p = min(vec2(xy) * scale, vec2(sourceSize - 1u));
        uvec2 low = uvec2(floor(p));
        uvec2 high = min(low + 1u, sourceSize - 1u);
        vec2 t = p - vec2(low);
        vec3 a = readPixel(low), b = readPixel(uvec2(high.x, low.y));
        vec3 c = readPixel(uvec2(low.x, high.y)), d = readPixel(high);
        // FINAL resizes display output; PREVIEW resizes linear input first.
        if (stage == 2) {
            a = evaluate(a, low, sourceSize);
            b = evaluate(b, uvec2(high.x, low.y), sourceSize);
            c = evaluate(c, uvec2(low.x, high.y), sourceSize);
            d = evaluate(d, high, sourceSize);
        }
        value = mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
        if (stage == 3) value = evaluate(value, xy, destinationSize);
    }
    uint outIndex = (outputOffset + i) * 3u;
    dst[outIndex] = value.r; dst[outIndex + 1u] = value.g; dst[outIndex + 2u] = value.b;
}
)glsl";

inline const std::string kPhotoSpatialShader = std::string(R"glsl(#version 310 es
precision highp float;
precision highp int;
layout(local_size_x = 128) in;
layout(std430, binding = 0) readonly buffer SpatialSrc { float spSrc[]; };
layout(std430, binding = 1) writeonly buffer SpatialDst { float spDst[]; };
layout(std430, binding = 2) readonly buffer SpatialAux { float spAux[]; };
layout(std430, binding = 3) readonly buffer SpatialField { float spField[]; };
layout(std140, binding = 0) uniform SpatialParams {
    uvec4 dims;       // width, height, rowOffset, rows
    uvec4 bandInfo;   // srcRowOffset, auxRowOffset, radius, stage
    vec4 sharpenCfg;  // strength, sharpenDetail, sharpenMasking, sharpenRadius
    vec4 defringeCfg; // purpleAmount, purpleHue, greenAmount, greenHue
    vec4 spAirlight;  // r, g, b, minTransmission
    uvec4 spFlags;    // basicV3, fieldWidth, fieldHeight, fieldOffset
    uvec4 spBandDims; // srcRows, auxRows, dstWidth, dstHeight
    vec4 spWeights[7];
};

vec3 spLoadSrc(int x, int y) {
    uint cx = uint(clamp(x, 0, int(dims.x) - 1));
    int minY = int(bandInfo.x);
    int maxY = minY + int(max(1u, spBandDims.x)) - 1;
    uint cy = uint(clamp(y, minY, maxY));
    uint idx = ((cy - bandInfo.x) * dims.x + cx) * 3u;
    return vec3(spSrc[idx], spSrc[idx + 1u], spSrc[idx + 2u]);
}
vec3 spLoadAux(int x, int y) {
    uint cx = uint(clamp(x, 0, int(dims.x) - 1));
    int minY = int(bandInfo.y);
    int maxY = minY + int(max(1u, spBandDims.y)) - 1;
    uint cy = uint(clamp(y, minY, maxY));
    uint idx = ((cy - bandInfo.y) * dims.x + cx) * 3u;
    return vec3(spAux[idx], spAux[idx + 1u], spAux[idx + 2u]);
}
float spReadWeight(uint idx) {
    vec4 wv = spWeights[idx >> 2u];
    uint lane = idx & 3u;
    return lane == 0u ? wv.x : (lane == 1u ? wv.y : (lane == 2u ? wv.z : wv.w));
}

#define SP_FN
#define SP_V3 vec3
#define SP_V3C(x, y, z) vec3((x), (y), (z))
#define SP_CTX_DECL
#define SP_CTX_ARG
#define SP_SRC(ix, iy) spLoadSrc((ix), (iy))
#define SP_AUX(ix, iy) spLoadAux((ix), (iy))
#define SP_FIELD(idx) spField[(idx)]
#define SP_FINITE(v) (abs((v).x) <= 3.4e38 && abs((v).y) <= 3.4e38 && abs((v).z) <= 3.4e38)
#define SP_WEIGHT(idx) spReadWeight(idx)
#define SP_WIDTH dims.x
#define SP_HEIGHT dims.y
#define SP_RADIUS bandInfo.z
#define SP_STRENGTH sharpenCfg.x
#define SP_SHARPEN_DETAIL sharpenCfg.y
#define SP_SHARPEN_MASKING sharpenCfg.z
#define SP_PURPLE_AMT defringeCfg.x
#define SP_PURPLE_HUE defringeCfg.y
#define SP_GREEN_AMT defringeCfg.z
#define SP_GREEN_HUE defringeCfg.w
#define SP_AIRLIGHT spAirlight
#define SP_FLAGS spFlags
)glsl") + photoSpatialShaderBody() + R"glsl(
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
#undef SP_SHARPEN_DETAIL
#undef SP_SHARPEN_MASKING
#undef SP_PURPLE_AMT
#undef SP_PURPLE_HUE
#undef SP_GREEN_AMT
#undef SP_GREEN_HUE
#undef SP_AIRLIGHT
#undef SP_FLAGS

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint count = dims.x * dims.w;
    if (i >= count) return;
    int x = int(i % dims.x);
    int y = int(i / dims.x + dims.z);
    vec3 outCol;
    uint st = bandInfo.w;
    if (st == 0u) outCol = spDefringePixel(x, y);
    else if (st == 1u) outCol = spDehazePixel(x, y);
    else if (st == 2u) outCol = spClarityPixel(x, y);
    else if (st == 3u) outCol = spTextureBlurHPixel(x, y);
    else if (st == 4u) outCol = spTextureApplyVPixel(x, y);
    else if (st == 5u) outCol = spSharpenPrepHPixel(x, y);
    else if (st == 6u) outCol = spSharpenPrepVPixel(x, y);
    else if (st == 7u) outCol = spSharpenMaskHPixel(x, y);
    else outCol = spSharpenApplyPixel(x, y);
    uint outIdx = i * 3u;
    spDst[outIdx] = outCol.x;
    spDst[outIdx + 1u] = outCol.y;
    spDst[outIdx + 2u] = outCol.z;
}
)glsl";
}
