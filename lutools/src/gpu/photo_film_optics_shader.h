#pragma once

#include <cstdint>

namespace sony2fuji {

// Dedicated secondary constant/uniform parameter block for v0.14.0 Halation & Bloom,
// keeping the historical 3544-byte PhotoParams and 56-byte PhotoEffectsParams frozen.
struct FilmOpticsGpuParams {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t proxyWidth = 0;
    uint32_t proxyHeight = 0;
    uint32_t rowOffset = 0;
    uint32_t rows = 0;
    uint32_t halProxyWidth = 0;
    uint32_t halProxyHeight = 0;
    uint32_t bloomProxyWidth = 0;
    uint32_t bloomProxyHeight = 0;
    uint32_t blurRadiusPx = 0;
    uint32_t channelCount = 1;
    uint32_t passFlags = 0;
    uint32_t bloomOffsetFloats = 0;
    uint32_t srcRowOffset = 0;
    uint32_t dstProxyRowOffset = 0;
    float proxySigma = 1.0f;
    float halationAmount = 0.0f;
    // 阈值与色相由宿主经 filmOpticsThresholdNorm / filmOpticsHueNorm 换算后填入，着色器只读取。
    float halationThresholdNorm = 0.72f;
    float halationHueNorm = 0.0f;
    float bloomAmount = 0.0f;
    float bloomThresholdNorm = 0.672f;
    float coreWeight = 0.40f;
    float tailWeight = 0.60f;
};
static_assert(sizeof(FilmOpticsGpuParams) == 96, "FilmOptics GPU parameter layout");

// Shared cross-dialect arithmetic body consumed by Metal, GLSL ES 3.10, and HLSL cs_5_0.
// Dialect preamble defines `V3` (`float3` in Metal/HLSL, `vec3` in GLSL).
inline constexpr const char* kFilmOpticsSharedShaderBody = R"shader(
float foSmooth(float val) {
    val = clamp(val, 0.0, 1.0);
    return val * val * (3.0 - 2.0 * val);
}

float resolveGrainSize(float sz, uint preset) {
    return preset == 1u ? 18.0 : (preset == 2u ? 34.0 : sz);
}

float resolveGrainRoughness(float rgh, uint preset) {
    return preset == 1u ? 65.0 : (preset == 2u ? 22.0 : rgh);
}

float grainToneWeight(float luma, uint toneCurve) {
    luma = clamp(luma, 0.0, 1.0);
    if (toneCurve == 1u) {
        float shadowRise = foSmooth(luma / 0.06);
        float hiCut = 1.0 - foSmooth((luma - 0.22) / 0.75);
        return shadowRise * sqrt(max(hiCut, 0.0)) * (0.20 + 0.90 * hiCut);
    }
    return sqrt(max(4.0 * luma * (1.0 - luma), 0.0));
}

float foSrgbToLin1(float ch) {
    ch = max(ch, 0.0);
    return ch <= 0.04045 ? (ch / 12.92) : pow(max((ch + 0.055) / 1.055, 0.0), 2.4);
}

float foLinToSrgb1(float ch) {
    ch = clamp(ch, 0.0, 1.0);
    return ch <= 0.0031308 ? (12.92 * ch) : (1.055 * pow(max(ch, 0.0), 1.0 / 2.4) - 0.055);
}

V3 foSrgbToLin3(V3 px) {
    return V3(foSrgbToLin1(px.x), foSrgbToLin1(px.y), foSrgbToLin1(px.z));
}

V3 foLinToSrgb3(V3 px) {
    return V3(foLinToSrgb1(px.x), foLinToSrgb1(px.y), foLinToSrgb1(px.z));
}

float foLuminance3(V3 linPx) {
    return max(0.0, 0.2126 * linPx.x + 0.7152 * linPx.y + 0.0722 * linPx.z);
}

float foHighlightExcess(float sig, float tn) {
    float linThresh = foSrgbToLin1(tn);
    float knee = min(0.06, 0.5 * linThresh);
    if (sig <= linThresh - knee) return 0.0;
    if (sig >= linThresh + knee || knee <= 1e-6) return max(0.0, sig - linThresh);
    float rq = sig - (linThresh - knee);
    return (rq * rq) / (4.0 * knee);
}

V3 foHalationTint(float h) {
    float gW = h < 0.0 ? (0.24 + 0.16 * h) : (0.24 + 0.20 * h);
    float bW = 0.03 + 0.005 * (h + 1.0);
    return V3(1.0, gW, bW);
}

V3 foApplyOpticsBlend(V3 srgbPx, float halGlow, V3 bloomGlow, float halAmt, float halHue, float bloomAmt) {
    bool hasHal = halAmt > 0.0 && halGlow > 0.0;
    bool hasBloom = bloomAmt > 0.0 && (bloomGlow.x > 0.0 || bloomGlow.y > 0.0 || bloomGlow.z > 0.0);
    if (!hasHal && !hasBloom) {
        return srgbPx;
    }
    V3 baseLin = foSrgbToLin3(srgbPx);
    V3 accLin = baseLin;
    if (hasHal) {
        V3 halRgb = foHalationTint(halHue) * (halGlow * (halAmt / 100.0) * 1.15);
        accLin += halRgb / (V3(1.0, 1.0, 1.0) + 1.5 * max(baseLin, V3(0.0, 0.0, 0.0)));
    }
    if (hasBloom) {
        V3 bRgb = max(bloomGlow, V3(0.0, 0.0, 0.0)) * ((bloomAmt / 100.0) * 1.20);
        accLin += bRgb / (V3(1.0, 1.0, 1.0) + 1.2 * max(baseLin, V3(0.0, 0.0, 0.0)));
    }
    return foLinToSrgb3(accLin);
}
)shader";

inline constexpr const char* kMetalFilmOpticsKernelSource = R"metal(
#include <metal_stdlib>
using namespace metal;
#define V3 float3

struct FilmOpticsParams {
    uint width;
    uint height;
    uint proxyWidth;
    uint proxyHeight;
    uint rowOffset;
    uint rows;
    uint halProxyWidth;
    uint halProxyHeight;
    uint bloomProxyWidth;
    uint bloomProxyHeight;
    uint blurRadiusPx;
    uint channelCount;
    uint passFlags;
    uint bloomOffsetFloats;
    uint srcRowOffset;
    uint dstProxyRowOffset;
    float proxySigma;
    float halationAmount;
    float halationThresholdNorm;
    float halationHueNorm;
    float bloomAmount;
    float bloomThresholdNorm;
    float coreWeight;
    float tailWeight;
};
)metal";

inline constexpr const char* kMetalFilmOpticsKernelsTail = R"metal(
float foSampleProxy1(device const float* buf, uint baseOffset, uint pW, uint pH, float fx, float fy) {
    float cx = clamp(fx, 0.0f, float(pW - 1u));
    float cy = clamp(fy, 0.0f, float(pH - 1u));
    int x0 = int(floor(cx));
    int y0 = int(floor(cy));
    int x1 = min(int(pW) - 1, x0 + 1);
    int y1 = min(int(pH) - 1, y0 + 1);
    float tx = cx - float(x0);
    float ty = cy - float(y0);
    float v00 = buf[baseOffset + uint(y0) * pW + uint(x0)];
    float v10 = buf[baseOffset + uint(y0) * pW + uint(x1)];
    float v01 = buf[baseOffset + uint(y1) * pW + uint(x0)];
    float v11 = buf[baseOffset + uint(y1) * pW + uint(x1)];
    return (v00 * (1.0f - tx) + v10 * tx) * (1.0f - ty) + (v01 * (1.0f - tx) + v11 * tx) * ty;
}

float3 foSampleProxy3(device const float* buf, uint baseOffset, uint pW, uint pH, float fx, float fy) {
    float cx = clamp(fx, 0.0f, float(pW - 1u));
    float cy = clamp(fy, 0.0f, float(pH - 1u));
    int x0 = int(floor(cx));
    int y0 = int(floor(cy));
    int x1 = min(int(pW) - 1, x0 + 1);
    int y1 = min(int(pH) - 1, y0 + 1);
    float tx = cx - float(x0);
    float ty = cy - float(y0);
    uint i00 = baseOffset + (uint(y0) * pW + uint(x0)) * 3u;
    uint i10 = baseOffset + (uint(y0) * pW + uint(x1)) * 3u;
    uint i01 = baseOffset + (uint(y1) * pW + uint(x0)) * 3u;
    uint i11 = baseOffset + (uint(y1) * pW + uint(x1)) * 3u;
    float3 c00 = float3(buf[i00], buf[i00 + 1u], buf[i00 + 2u]);
    float3 c10 = float3(buf[i10], buf[i10 + 1u], buf[i10 + 2u]);
    float3 c01 = float3(buf[i01], buf[i01 + 1u], buf[i01 + 2u]);
    float3 c11 = float3(buf[i11], buf[i11 + 1u], buf[i11 + 2u]);
    return (c00 * (1.0f - tx) + c10 * tx) * (1.0f - ty) + (c01 * (1.0f - tx) + c11 * tx) * ty;
}

kernel void filmOpticsDownsample(
    constant FilmOpticsParams& p [[buffer(0)]],
    device const packed_float3* srcBand [[buffer(1)]],
    device float* dstProxy [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint total = p.proxyWidth * p.rows;
    if (gid >= total) return;
    uint px = gid % p.proxyWidth;
    uint pyLocal = gid / p.proxyWidth;
    uint py = pyLocal + p.dstProxyRowOffset;
    int ix0 = max(0, int((px * p.width) / p.proxyWidth));
    int ix1 = min(int(p.width), max(ix0 + 1, int(((px + 1u) * p.width + p.proxyWidth - 1u) / p.proxyWidth)));
    int iy0 = max(0, int((py * p.height) / p.proxyHeight));
    int iy1 = min(int(p.height), max(iy0 + 1, int(((py + 1u) * p.height + p.proxyHeight - 1u) / p.proxyHeight)));
    int stepX = max(1, (ix1 - ix0 + 15) / 16);
    int stepY = max(1, (iy1 - iy0 + 15) / 16);
    bool isBloom = p.channelCount == 3u;
    float thresh = isBloom ? p.bloomThresholdNorm : p.halationThresholdNorm;
    float3 sum = float3(0.0f);
    float count = 0.0f;
    for (int sy = iy0; sy < iy1; sy += stepY) {
        int bandY = sy - int(p.srcRowOffset);
        uint rowBase = uint(max(0, bandY)) * p.width;
        for (int sx = ix0; sx < ix1; sx += stepX) {
            float3 srgbPx = float3(srcBand[rowBase + uint(sx)]);
            float3 lin = foSrgbToLin3(srgbPx);
            float lum = foLuminance3(lin);
            if (isBloom) {
                float ex = foHighlightExcess(lum, thresh);
                float ratio = lum > 1e-6f ? (ex / lum) : 0.0f;
                sum += lin * ratio;
            } else {
                float maxCh = max(lin.x, max(lin.y, lin.z));
                float sig = max(lum, maxCh * 0.55f);
                sum.x += foHighlightExcess(sig, thresh);
            }
            count += 1.0f;
        }
    }
    float inv = count > 0.0f ? (1.0f / count) : 0.0f;
    uint outPx = py * p.proxyWidth + px;
    if (isBloom) {
        uint outIdx = outPx * 3u;
        dstProxy[outIdx] = sum.x * inv;
        dstProxy[outIdx + 1u] = sum.y * inv;
        dstProxy[outIdx + 2u] = sum.z * inv;
    } else {
        dstProxy[outPx] = sum.x * inv;
    }
}

kernel void filmOpticsBlurH(
    constant FilmOpticsParams& p [[buffer(0)]],
    device const float* srcBuf [[buffer(1)]],
    device float* dstBuf [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    uint total = p.proxyWidth * p.proxyHeight;
    if (gid >= total) return;
    int px = int(gid % p.proxyWidth);
    int py = int(gid / p.proxyWidth);
    int rad = int(p.blurRadiusPx);
    float invTwoSigSq = 0.5f / max(p.proxySigma * p.proxySigma, 0.01f);
    if (p.channelCount == 3u) {
        float3 acc = float3(0.0f);
        float wSum = 0.0f;
        for (int d = -rad; d <= rad; ++d) {
            int sx = clamp(px + d, 0, int(p.proxyWidth) - 1);
            float w = exp(-float(d * d) * invTwoSigSq);
            uint idx = (uint(py) * p.proxyWidth + uint(sx)) * 3u;
            acc += float3(srcBuf[idx], srcBuf[idx + 1u], srcBuf[idx + 2u]) * w;
            wSum += w;
        }
        float3 val = acc / max(wSum, 1e-6f);
        uint outIdx = gid * 3u;
        dstBuf[outIdx] = val.x;
        dstBuf[outIdx + 1u] = val.y;
        dstBuf[outIdx + 2u] = val.z;
    } else {
        float acc = 0.0f;
        float wSum = 0.0f;
        for (int d = -rad; d <= rad; ++d) {
            int sx = clamp(px + d, 0, int(p.proxyWidth) - 1);
            float w = exp(-float(d * d) * invTwoSigSq);
            acc += srcBuf[uint(py) * p.proxyWidth + uint(sx)] * w;
            wSum += w;
        }
        dstBuf[gid] = acc / max(wSum, 1e-6f);
    }
}

kernel void filmOpticsBlurV(
    constant FilmOpticsParams& p [[buffer(0)]],
    device const float* srcBuf [[buffer(1)]],
    device float* dstBuf [[buffer(2)]],
    device const float* coreBuf [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    uint total = p.proxyWidth * p.proxyHeight;
    if (gid >= total) return;
    int px = int(gid % p.proxyWidth);
    int py = int(gid / p.proxyWidth);
    int rad = int(p.blurRadiusPx);
    float invTwoSigSq = 0.5f / max(p.proxySigma * p.proxySigma, 0.01f);
    bool mixCore = (p.passFlags & 1u) != 0u;
    if (p.channelCount == 3u) {
        float3 acc = float3(0.0f);
        float wSum = 0.0f;
        for (int d = -rad; d <= rad; ++d) {
            int sy = clamp(py + d, 0, int(p.proxyHeight) - 1);
            float w = exp(-float(d * d) * invTwoSigSq);
            uint idx = (uint(sy) * p.proxyWidth + uint(px)) * 3u;
            acc += float3(srcBuf[idx], srcBuf[idx + 1u], srcBuf[idx + 2u]) * w;
            wSum += w;
        }
        float3 val = acc / max(wSum, 1e-6f);
        uint outIdx = gid * 3u;
        if (mixCore) {
            float3 c = float3(coreBuf[outIdx], coreBuf[outIdx + 1u], coreBuf[outIdx + 2u]);
            val = c * p.coreWeight + val * p.tailWeight;
        }
        dstBuf[outIdx] = val.x;
        dstBuf[outIdx + 1u] = val.y;
        dstBuf[outIdx + 2u] = val.z;
    } else {
        float acc = 0.0f;
        float wSum = 0.0f;
        for (int d = -rad; d <= rad; ++d) {
            int sy = clamp(py + d, 0, int(p.proxyHeight) - 1);
            float w = exp(-float(d * d) * invTwoSigSq);
            acc += srcBuf[uint(sy) * p.proxyWidth + uint(px)] * w;
            wSum += w;
        }
        float val = acc / max(wSum, 1e-6f);
        if (mixCore) {
            val = coreBuf[gid] * p.coreWeight + val * p.tailWeight;
        }
        dstBuf[gid] = val;
    }
}

kernel void filmOpticsComposite(
    constant FilmOpticsParams& p [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    device const float* glowBuffer [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    uint total = p.width * p.rows;
    if (gid >= total) return;
    uint x = gid % p.width;
    uint y = gid / p.width + p.rowOffset;
    float3 pixel = float3(source[gid]);
    float halGlow = 0.0f;
    if (p.halationAmount > 0.0f && p.halProxyWidth > 0u && p.halProxyHeight > 0u) {
        float hx = (float(x) + 0.5f) * (float(p.halProxyWidth) / float(p.width)) - 0.5f;
        float hy = (float(y) + 0.5f) * (float(p.halProxyHeight) / float(p.height)) - 0.5f;
        halGlow = foSampleProxy1(glowBuffer, 0u, p.halProxyWidth, p.halProxyHeight, hx, hy);
    }
    float3 bloomGlow = float3(0.0f);
    if (p.bloomAmount > 0.0f && p.bloomProxyWidth > 0u && p.bloomProxyHeight > 0u) {
        float bx = (float(x) + 0.5f) * (float(p.bloomProxyWidth) / float(p.width)) - 0.5f;
        float by = (float(y) + 0.5f) * (float(p.bloomProxyHeight) / float(p.height)) - 0.5f;
        bloomGlow = foSampleProxy3(glowBuffer, p.bloomOffsetFloats, p.bloomProxyWidth, p.bloomProxyHeight, bx, by);
    }
    destination[gid] = packed_float3(foApplyOpticsBlend(pixel, halGlow, bloomGlow, p.halationAmount, p.halationHueNorm, p.bloomAmount));
}
)metal";

} // namespace sony2fuji
