#pragma once

#include "core/photo_bw_mixer.h"
#include "core/photo_calibration.h"
#include "core/photo_point_color.h"
#include "core/photo_selective_color.h"
#include "core/render_params.h"
#include "gpu/photo_log_shader.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>

namespace sony2fuji {

struct alignas(16) ColorScienceGpuParams {
    // x: calFlags (bit0=active, bit1=hasMatrix)
    // y: bwEnabled (0 or 1)
    // z: pointSwatchCount (0..8)
    // w: selectiveFlags (bit0=active, bit1=absolute)
    uint32_t csFlags[4]{};
    float csCalRow0[4]{1.0f, 0.0f, 0.0f, 0.0f}; // m00, m01, m02, shadowTint
    float csCalRow1[4]{0.0f, 1.0f, 0.0f, 0.0f}; // m10, m11, m12, 0
    float csCalRow2[4]{0.0f, 0.0f, 1.0f, 0.0f}; // m20, m21, m22, 0
    float csBwWeights[2][4]{};                  // [0]: R,O,Y,G  [1]: A,B,P,M
    float csPtSrc[8][4]{};                      // srcHue, srcSaturation, srcLuminance, enabled
    float csPtShift[8][4]{};                    // hueShift, saturationShift, luminanceShift, variance
    float csPtRange[8][4]{};                    // range, hueRange, satRange, lumRange
    float csSelBands[9][4]{};                   // cyan, magenta, yellow, black
};

static_assert(sizeof(ColorScienceGpuParams) == 624, "ColorScienceGpuParams must be 624 bytes");
static_assert(offsetof(ColorScienceGpuParams, csFlags) == 0);
static_assert(offsetof(ColorScienceGpuParams, csCalRow0) == 16);
static_assert(offsetof(ColorScienceGpuParams, csCalRow1) == 32);
static_assert(offsetof(ColorScienceGpuParams, csCalRow2) == 48);
static_assert(offsetof(ColorScienceGpuParams, csBwWeights) == 64);
static_assert(offsetof(ColorScienceGpuParams, csPtSrc) == 96);
static_assert(offsetof(ColorScienceGpuParams, csPtShift) == 224);
static_assert(offsetof(ColorScienceGpuParams, csPtRange) == 352);
static_assert(offsetof(ColorScienceGpuParams, csSelBands) == 480);

inline ColorScienceGpuParams colorScienceGpuParameters(const RenderParams& params) {
    ColorScienceGpuParams gpu{};
    if (params.calibration.valid() && params.calibration.active()) {
        const auto prep = prepareCameraCalibration(params.calibration);
        if (prep.active) {
            gpu.csFlags[0] = 1u | (prep.hasMatrix ? 2u : 0u);
            gpu.csCalRow0[0] = prep.matrix[0];
            gpu.csCalRow0[1] = prep.matrix[1];
            gpu.csCalRow0[2] = prep.matrix[2];
            gpu.csCalRow0[3] = prep.shadowTint;
            gpu.csCalRow1[0] = prep.matrix[3];
            gpu.csCalRow1[1] = prep.matrix[4];
            gpu.csCalRow1[2] = prep.matrix[5];
            gpu.csCalRow2[0] = prep.matrix[6];
            gpu.csCalRow2[1] = prep.matrix[7];
            gpu.csCalRow2[2] = prep.matrix[8];
        }
    }

    if (params.bw.valid() && params.bw.active()) {
        gpu.csFlags[1] = 1u;
        for (size_t i = 0; i < kBwMixerChannelCount; ++i) {
            gpu.csBwWeights[i / 4u][i % 4u] = params.bw.weights[i];
        }
    }

    if (params.pointColor.valid() && params.pointColor.active()) {
        const uint32_t count = std::min<uint32_t>(
            params.pointColor.swatchCount,
            static_cast<uint32_t>(kPointColorMaxSwatches)
        );
        gpu.csFlags[2] = count;
        for (uint32_t i = 0; i < count; ++i) {
            const auto& sw = params.pointColor.swatches[i];
            gpu.csPtSrc[i][0] = sw.srcHue;
            gpu.csPtSrc[i][1] = sw.srcSaturation;
            gpu.csPtSrc[i][2] = sw.srcLuminance;
            gpu.csPtSrc[i][3] = sw.active() ? 1.0f : 0.0f;
            gpu.csPtShift[i][0] = sw.hueShift;
            gpu.csPtShift[i][1] = sw.saturationShift;
            gpu.csPtShift[i][2] = sw.luminanceShift;
            gpu.csPtShift[i][3] = sw.variance;
            gpu.csPtRange[i][0] = sw.range;
            gpu.csPtRange[i][1] = sw.hueRange;
            gpu.csPtRange[i][2] = sw.satRange;
            gpu.csPtRange[i][3] = sw.lumRange;
        }
    }

    if (params.selectiveColor.valid() && params.selectiveColor.active()) {
        gpu.csFlags[3] = 1u | (params.selectiveColor.method == SelectiveColorMethod::Absolute ? 2u : 0u);
        for (size_t i = 0; i < kSelectiveColorBandCount; ++i) {
            const auto& b = params.selectiveColor.bands[i];
            gpu.csSelBands[i][0] = b.cyan;
            gpu.csSelBands[i][1] = b.magenta;
            gpu.csSelBands[i][2] = b.yellow;
            gpu.csSelBands[i][3] = b.black;
        }
    }
    return gpu;
}

inline std::string colorScienceShader(ShaderDialect dialect) {
    std::string header;
    std::string macros;
    if (dialect == ShaderDialect::Glsl) {
        header = R"glsl(
layout(std140, binding = 2) uniform ColorScienceParams {
    uvec4 csFlags;
    vec4 csCalRow0;
    vec4 csCalRow1;
    vec4 csCalRow2;
    vec4 csBwWeights[2];
    vec4 csPtSrc[8];
    vec4 csPtShift[8];
    vec4 csPtRange[8];
    vec4 csSelBands[9];
};
)glsl";
        macros = R"glsl(
#define CS_VEC3 vec3
#define CS_VEC4 vec4
#define CS_UVEC4 uvec4
#define CS_PARAM_DECL
#define CS_PARAM_ONLY
#define CS_CALL_ARG
#define CS_CALL_ONLY
#define CS_FIELD(name) name
)glsl";
    } else if (dialect == ShaderDialect::Hlsl) {
        header = R"hlsl(
cbuffer ColorScienceParams : register(b2) {
    uint4 csFlags;
    float4 csCalRow0;
    float4 csCalRow1;
    float4 csCalRow2;
    float4 csBwWeights[2];
    float4 csPtSrc[8];
    float4 csPtShift[8];
    float4 csPtRange[8];
    float4 csSelBands[9];
};
)hlsl";
        macros = R"hlsl(
#define CS_VEC3 float3
#define CS_VEC4 float4
#define CS_UVEC4 uint4
#define CS_PARAM_DECL
#define CS_PARAM_ONLY
#define CS_CALL_ARG
#define CS_CALL_ONLY
#define CS_FIELD(name) name
)hlsl";
    } else {
        header = R"metal(
struct ColorScienceParams {
    uint4 csFlags;
    float4 csCalRow0;
    float4 csCalRow1;
    float4 csCalRow2;
    float4 csBwWeights[2];
    float4 csPtSrc[8];
    float4 csPtShift[8];
    float4 csPtRange[8];
    float4 csSelBands[9];
};
)metal";
        macros = R"metal(
#define CS_VEC3 float3
#define CS_VEC4 float4
#define CS_UVEC4 uint4
#define CS_PARAM_DECL , constant ColorScienceParams& csP
#define CS_PARAM_ONLY constant ColorScienceParams& csP
#define CS_CALL_ARG , csP
#define CS_CALL_ONLY csP
#define CS_FIELD(name) csP.name
)metal";
    }

    const std::string body = R"shader(
float csWrapHue(float deg) {
    float w = deg - 360.0 * floor(deg * (1.0 / 360.0));
    if (w < 0.0) w += 360.0;
    if (w >= 360.0) w -= 360.0;
    return w;
}

float csWrappedHueDiff(float target, float curHue) {
    float diff = target - curHue;
    if (diff > 180.0) diff -= 360.0;
    if (diff < -180.0) diff += 360.0;
    return diff;
}

float csBwHueCenter(uint idx) {
    if (idx == 0u) return 0.0;
    if (idx == 1u) return 30.0;
    if (idx == 2u) return 60.0;
    if (idx == 3u) return 120.0;
    if (idx == 4u) return 180.0;
    if (idx == 5u) return 240.0;
    if (idx == 6u) return 270.0;
    if (idx == 7u) return 300.0;
    return 360.0;
}

float csBwWeightAt(uint idx CS_PARAM_DECL) {
    uint vIdx = idx / 4u;
    uint comp = idx - vIdx * 4u;
    CS_VEC4 wv = CS_FIELD(csBwWeights)[vIdx];
    if (comp == 0u) return wv.x;
    if (comp == 1u) return wv.y;
    if (comp == 2u) return wv.z;
    return wv.w;
}

CS_VEC3 csApplyCalibration(CS_VEC3 linPix CS_PARAM_DECL) {
    uint flags = CS_FIELD(csFlags).x;
    if ((flags & 1u) == 0u) return linPix;

    CS_VEC3 res = linPix;
    if ((flags & 2u) != 0u) {
        float gray = (res.x == res.y && res.y == res.z)
            ? res.x
            : (res.x + res.y + res.z) * (1.0 / 3.0);
        float dr = res.x - gray;
        float dg = res.y - gray;
        float db = res.z - gray;
        CS_VEC4 r0 = CS_FIELD(csCalRow0);
        CS_VEC4 r1 = CS_FIELD(csCalRow1);
        CS_VEC4 r2 = CS_FIELD(csCalRow2);
        res = CS_VEC3(
            gray + r0.x * dr + r0.y * dg + r0.z * db,
            gray + r1.x * dr + r1.y * dg + r1.z * db,
            gray + r2.x * dr + r2.y * dg + r2.z * db
        );
    }

    float st = CS_FIELD(csCalRow0).w;
    if (st != 0.0) {
        float lum = max(0.0, 0.2126 * res.x + 0.7152 * res.y + 0.0722 * res.z);
        float t = clamp(1.0 - lum * 4.0, 0.0, 1.0);
        float w = t * t * (3.0 - 2.0 * t);
        float shift = st * 0.25 * w;
        res = CS_VEC3(
            res.x * (1.0 + 0.5 * shift),
            res.y * (1.0 - shift),
            res.z * (1.0 + 0.5 * shift)
        );
    }
    return res;
}

CS_VEC3 csApplyBwMixer(CS_VEC3 pix CS_PARAM_DECL) {
    if (CS_FIELD(csFlags).y == 0u) return pix;

    float baseY = 0.2126 * pix.x + 0.7152 * pix.y + 0.0722 * pix.z;
    float maxC = max(pix.x, max(pix.y, pix.z));
    float minC = min(pix.x, min(pix.y, pix.z));
    float delta = maxC - minC;
    if (delta <= 1e-5) {
        float y = clamp(baseY, 0.0, 1.0);
        return CS_VEC3(y, y, y);
    }

    float hue = 0.0;
    if (maxC == pix.x) {
        hue = 60.0 * ((pix.y - pix.z) / delta + (pix.y < pix.z ? 6.0 : 0.0));
    } else if (maxC == pix.y) {
        hue = 60.0 * ((pix.z - pix.x) / delta + 2.0);
    } else {
        hue = 60.0 * ((pix.x - pix.y) / delta + 4.0);
    }
    hue = csWrapHue(hue);

    uint lower = 0u;
    for (uint stepIdx = 0u; stepIdx < 7u; ++stepIdx) {
        if (hue >= csBwHueCenter(stepIdx + 1u)) {
            lower = stepIdx + 1u;
        }
    }
    uint upper = lower + 1u;
    if (upper >= 8u) upper = 0u;

    float cLo = csBwHueCenter(lower);
    float cHi = csBwHueCenter(lower + 1u);
    float t = (hue - cLo) / (cHi - cLo);
    t = t * t * (3.0 - 2.0 * t);

    float wLo = csBwWeightAt(lower CS_CALL_ARG);
    float wHi = csBwWeightAt(upper CS_CALL_ARG);
    float channelWeight = wLo + (wHi - wLo) * t;
    float shiftedY = baseY + (channelWeight * 0.01) * min(1.0, delta) * 0.5;
    float resY = clamp(shiftedY, 0.0, 1.0);
    return CS_VEC3(resY, resY, resY);
}

CS_VEC3 csRgbToHsb(CS_VEC3 pix) {
    float rf = clamp(pix.x, 0.0, 1.0);
    float gf = clamp(pix.y, 0.0, 1.0);
    float bf = clamp(pix.z, 0.0, 1.0);
    float maxC = max(rf, max(gf, bf));
    float minC = min(rf, min(gf, bf));
    float delta = maxC - minC;
    float bright = maxC;
    float sat = maxC <= 0.0 ? 0.0 : (delta / maxC);
    float hue = 0.0;
    if (delta > 1e-6) {
        float seg = 0.0;
        if (maxC == rf) {
            seg = (gf - bf) / delta + (gf < bf ? 6.0 : 0.0);
        } else if (maxC == gf) {
            seg = (bf - rf) / delta + 2.0;
        } else {
            seg = (rf - gf) / delta + 4.0;
        }
        hue = csWrapHue(seg * 60.0);
    }
    return CS_VEC3(hue, sat, bright);
}

CS_VEC3 csHsbToRgb(float hueDeg, float satVal, float brightVal) {
    float h = csWrapHue(hueDeg);
    float s = clamp(satVal, 0.0, 1.0);
    float v = clamp(brightVal, 0.0, 1.0);
    float c = v * s;
    float hp = h * (1.0 / 60.0);
    float hpMod2 = hp - 2.0 * floor(hp * 0.5);
    float x = c * (1.0 - abs(hpMod2 - 1.0));
    float m = v - c;
    CS_VEC3 rgb = h < 60.0 ? CS_VEC3(c, x, 0.0)
        : h < 120.0 ? CS_VEC3(x, c, 0.0)
        : h < 180.0 ? CS_VEC3(0.0, c, x)
        : h < 240.0 ? CS_VEC3(0.0, x, c)
        : h < 300.0 ? CS_VEC3(x, 0.0, c)
        : CS_VEC3(c, 0.0, x);
    return CS_VEC3(
        clamp(rgb.x + m, 0.0, 1.0),
        clamp(rgb.y + m, 0.0, 1.0),
        clamp(rgb.z + m, 0.0, 1.0)
    );
}

CS_VEC3 csApplyPointColor(CS_VEC3 pix CS_PARAM_DECL) {
    uint count = CS_FIELD(csFlags).z;
    if (count == 0u) return pix;

    CS_VEC3 hsb = csRgbToHsb(pix);
    float h = hsb.x;
    float s = hsb.y;
    float l = hsb.z;
    uint modified = 0u;

    for (uint sw = 0u; sw < 8u; ++sw) {
        if (sw >= count) break;
        CS_VEC4 pSrc = CS_FIELD(csPtSrc)[sw];
        if (pSrc.w <= 0.0) continue;
        CS_VEC4 pShift = CS_FIELD(csPtShift)[sw];
        CS_VEC4 pRange = CS_FIELD(csPtRange)[sw];

        float rangeScale = 0.25 + 1.50 * (pRange.x * 0.01);
        float hueEdge = max(4.0, (5.0 + 0.55 * pRange.y) * rangeScale);
        float satEdge = max(0.05, (0.08 + 0.44 * (pRange.z * 0.01)) * rangeScale);
        float lumEdge = max(0.05, (0.08 + 0.44 * (pRange.w * 0.01)) * rangeScale);

        float dh = abs(h - pSrc.x);
        if (dh > 180.0) dh = 360.0 - dh;
        float nh = min(1.0, dh / hueEdge);
        float ns = min(1.0, abs(s - pSrc.y) / satEdge);
        float nl = min(1.0, abs(l - pSrc.z) / lumEdge);
        float d = min(1.0, sqrt(nh * nh + ns * ns + nl * nl));
        float mask = 1.0 - d * d * (3.0 - 2.0 * d);
        if (mask <= 0.0) continue;

        modified = 1u;
        float varianceVal = pShift.w;
        if (varianceVal < 0.0) {
            float pull = clamp((-varianceVal * 0.01) * mask, 0.0, 1.0);
            h = csWrapHue(h + pull * csWrappedHueDiff(pSrc.x, h));
            s = clamp(s + pull * (pSrc.y - s), 0.0, 1.0);
            l = clamp(l + pull * (pSrc.z - l), 0.0, 1.0);
        } else if (varianceVal > 0.0) {
            float push = (varianceVal * 0.01) * mask * 0.75;
            h = csWrapHue(h - push * csWrappedHueDiff(pSrc.x, h));
            s = clamp(s - push * (pSrc.y - s), 0.0, 1.0);
            l = clamp(l - push * (pSrc.z - l), 0.0, 1.0);
        }

        h = csWrapHue(h + pShift.x * 0.6 * mask);
        float satShift = pShift.y;
        if (satShift >= 0.0) {
            float ks = (satShift * 0.01) * 0.75 * mask;
            s = clamp(s + (1.0 - s) * ks, 0.0, 1.0);
        } else {
            float ks = (satShift * 0.01) * mask;
            s = clamp(s * (1.0 + ks), 0.0, 1.0);
        }
        l = clamp(l + (pShift.z * 0.01) * 0.40 * mask, 0.0, 1.0);
    }

    if (modified == 0u) return pix;
    return csHsbToRgb(h, s, l);
}

CS_VEC3 csApplySelectiveColor(CS_VEC3 pix CS_PARAM_DECL) {
    uint flags = CS_FIELD(csFlags).w;
    if ((flags & 1u) == 0u) return pix;

    float r = clamp(pix.x, 0.0, 1.0);
    float g = clamp(pix.y, 0.0, 1.0);
    float b = clamp(pix.z, 0.0, 1.0);
    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float midC = r + g + b - maxC - minC;

    float dC = 0.0;
    float dM = 0.0;
    float dY = 0.0;
    for (uint bandIdx = 0u; bandIdx < 9u; ++bandIdx) {
        float w = 0.0;
        if (bandIdx == 0u) w = (r >= g && r >= b) ? (r - midC) : 0.0;
        else if (bandIdx == 1u) w = (b <= r && b <= g) ? (midC - b) : 0.0;
        else if (bandIdx == 2u) w = (g >= r && g >= b) ? (g - midC) : 0.0;
        else if (bandIdx == 3u) w = (r <= g && r <= b) ? (midC - r) : 0.0;
        else if (bandIdx == 4u) w = (b >= r && b >= g) ? (b - midC) : 0.0;
        else if (bandIdx == 5u) w = (g <= r && g <= b) ? (midC - g) : 0.0;
        else if (bandIdx == 6u) w = minC > 0.5 ? (minC - 0.5) * 2.0 : 0.0;
        else if (bandIdx == 7u) w = max(0.0, 1.0 - abs(maxC - 0.5) - abs(minC - 0.5));
        else w = maxC < 0.5 ? (0.5 - maxC) * 2.0 : 0.0;

        if (w <= 0.0) continue;
        CS_VEC4 bv = CS_FIELD(csSelBands)[bandIdx];
        if (bv.x == 0.0 && bv.y == 0.0 && bv.z == 0.0 && bv.w == 0.0) continue;
        float kc = bv.x * 0.01;
        float km = bv.y * 0.01;
        float ky = bv.z * 0.01;
        float kk = bv.w * 0.01;
        dC -= w * (kc + kk);
        dM -= w * (km + kk);
        dY -= w * (ky + kk);
    }

    if ((flags & 2u) == 0u) {
        dC *= min(r, 1.0 - r);
        dM *= min(g, 1.0 - g);
        dY *= min(b, 1.0 - b);
    }

    return CS_VEC3(
        clamp(r + dC, 0.0, 1.0),
        clamp(g + dM, 0.0, 1.0),
        clamp(b + dY, 0.0, 1.0)
    );
}
)shader";

    const std::string undefs = R"shader(
#undef CS_VEC3
#undef CS_VEC4
#undef CS_UVEC4
#undef CS_PARAM_DECL
#undef CS_PARAM_ONLY
#undef CS_CALL_ARG
#undef CS_CALL_ONLY
#undef CS_FIELD
)shader";

    return header + macros + body + undefs;
}

} // namespace sony2fuji
