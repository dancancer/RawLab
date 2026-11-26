#pragma once

#include "core/photo_atmosphere.h"
#include "core/photo_defringe.h"
#include "core/photo_sharpen_v2.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace sony2fuji {

enum class SpatialKernel : uint32_t {
    Defringe = 0,
    Dehaze = 1,
    Clarity = 2,
    TextureBlurH = 3,
    TextureApplyV = 4,
    SharpenPrepH = 5,
    SharpenPrepV = 6,
    SharpenMaskH = 7,
    SharpenApply = 8,
};

struct alignas(16) SpatialGpuParams {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t rowOffset = 0;
    uint32_t rows = 0;

    uint32_t srcRowOffset = 0;
    uint32_t auxRowOffset = 0;
    uint32_t radius = 0;
    uint32_t stage = 0;

    // 锐化 v2 各 pass 中 strength 装的是 detailGain；其余由宿主派生，着色器不再做“先缩放再夹紧”。
    float strength = 0.0f;
    float sharpenCoring = 0.0f;
    float sharpenMaskLow = 0.0f;
    float sharpenMaskSpan = 0.0f;

    float defringePurpleNorm = 0.0f;
    float defringePurpleCenter = 290.0f;
    float defringeGreenNorm = 0.0f;
    float defringeGreenCenter = 120.0f;

    float airlight[4]{};       // r, g, b, minTransmission
    uint32_t flags[4]{};       // [basicV3, fieldWidth, fieldHeight, fieldOffset]
    uint32_t bandDims[4]{};    // [srcRows, auxRows, dstWidth, dstHeight]
    float weights[7][4]{};     // up to 25 Gaussian weights (max radius 12)
};
static_assert(sizeof(SpatialGpuParams) == 224, "Spatial GPU parameter layout");

// 派生量只由 core 的 defringeWeights / sharpenV2Coefficients 计算一次，CPU 参考路径用的是同一函数。
inline void fillSpatialDefringeParams(const DefringeOptions& options, SpatialGpuParams& out) {
    const DefringeWeights weights = defringeWeights(options);
    out.defringePurpleNorm = weights.purpleNorm;
    out.defringePurpleCenter = weights.purpleCenter;
    out.defringeGreenNorm = weights.greenNorm;
    out.defringeGreenCenter = weights.greenCenter;
}

inline void fillSpatialSharpenV2Params(float amount, const SharpenV2Options& options, SpatialGpuParams& out) {
    const SharpenV2Coefficients coefficients = sharpenV2Coefficients(amount, options);
    out.strength = coefficients.detailGain;
    out.sharpenCoring = coefficients.coring;
    out.sharpenMaskLow = coefficients.maskLow;
    out.sharpenMaskSpan = coefficients.maskSpan;
}

inline void fillSpatialGaussianWeights(float sigma, int maxRadius, SpatialGpuParams& out) {
    const int r = std::clamp(static_cast<int>(std::ceil(3.0f * sigma)), 1, maxRadius);
    out.radius = static_cast<uint32_t>(r);
    const float invTwoSigmaSq = 0.5f / (sigma * sigma);
    float sum = 0.0f;
    float raw[25]{};
    const int count = 2 * r + 1;
    for (int k = -r; k <= r; ++k) {
        const float w = std::exp(-float(k * k) * invTwoSigmaSq);
        raw[k + r] = w;
        sum += w;
    }
    for (auto& vec : out.weights) {
        vec[0] = vec[1] = vec[2] = vec[3] = 0.0f;
    }
    for (int i = 0; i < count; ++i) {
        out.weights[i >> 2][i & 3] = raw[i] / sum;
    }
}

inline void packDehazeAnalysisBuffer(
    const DehazeAnalysis& analysis,
    std::vector<float>& outData,
    SpatialGpuParams& outParams
) {
    const size_t n = static_cast<size_t>(analysis.width) * static_cast<size_t>(analysis.height);
    outData.resize(n * 3u);
    std::copy(analysis.slope.begin(), analysis.slope.end(), outData.begin());
    std::copy(analysis.intercept.begin(), analysis.intercept.end(), outData.begin() + static_cast<ptrdiff_t>(n));
    std::copy(analysis.variance.begin(), analysis.variance.end(), outData.begin() + static_cast<ptrdiff_t>(n * 2u));
    outParams.airlight[0] = analysis.airlight.r;
    outParams.airlight[1] = analysis.airlight.g;
    outParams.airlight[2] = analysis.airlight.b;
    outParams.airlight[3] = analysis.processingVersion == ProcessingVersion::BasicV3 ? 0.2f : 0.5f;
    outParams.flags[0] = analysis.processingVersion == ProcessingVersion::BasicV3 ? 1u : 0u;
    outParams.flags[1] = static_cast<uint32_t>(analysis.width);
    outParams.flags[2] = static_cast<uint32_t>(analysis.height);
    outParams.flags[3] = 0u;
}

inline void packClarityFieldBuffer(
    const ClarityField& field,
    std::vector<float>& outData,
    SpatialGpuParams& outParams
) {
    const size_t n = static_cast<size_t>(field.width) * static_cast<size_t>(field.height);
    outData.resize(n * 2u);
    std::copy(field.medium.begin(), field.medium.end(), outData.begin());
    std::copy(field.residual.begin(), field.residual.end(), outData.begin() + static_cast<ptrdiff_t>(n));
    outParams.flags[0] = field.version == ProcessingVersion::BasicV3 ? 1u : 0u;
    outParams.flags[1] = static_cast<uint32_t>(field.width);
    outParams.flags[2] = static_cast<uint32_t>(field.height);
    outParams.flags[3] = 0u;
}

// Shared cross-dialect spatial filters for Metal, GLSL ES 3.10, and HLSL cs_5_0.
// Callers define dialect macros right before embedding photoSpatialShaderBody():
//   SP_FN, SP_V3, SP_V3C(x,y,z), SP_CTX_DECL, SP_CTX_ARG,
//   SP_SRC(ix, iy), SP_AUX(ix, iy), SP_FIELD(idx), SP_FINITE(v), SP_WEIGHT(idx),
//   SP_WIDTH, SP_HEIGHT, SP_RADIUS, SP_STRENGTH, SP_SHARPEN_CORING, SP_SHARPEN_MASK_LOW,
//   SP_SHARPEN_MASK_SPAN, SP_PURPLE_NORM, SP_PURPLE_CENTER, SP_GREEN_NORM, SP_GREEN_CENTER,
//   SP_AIRLIGHT, SP_FLAGS
inline std::string photoSpatialShaderBody() {
    return R"shader(
SP_FN float spSmooth(float val) {
    float t = clamp(val, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
SP_FN float spDecode(float val) {
    return val <= 0.04045 ? val / 12.92 : pow((val + 0.055) / 1.055, 2.4);
}
SP_FN float spEncode(float val) {
    return val <= 0.0031308 ? 12.92 * val : 1.055 * pow(val, 1.0 / 2.4) - 0.055;
}
SP_FN float spEncode01(float val) {
    return spEncode(clamp(val, 0.0, 1.0));
}
SP_FN float spLuma(SP_V3 p) {
    return p.y + 0.2126 * (p.x - p.y) + 0.0722 * (p.z - p.y);
}
SP_FN SP_V3 spDecodeV3(SP_V3 p) {
    return SP_V3C(spDecode(p.x), spDecode(p.y), spDecode(p.z));
}
SP_FN SP_V3 spEncodeV3(SP_V3 p) {
    return SP_V3C(spEncode(clamp(p.x, 0.0, 1.0)), spEncode(clamp(p.y, 0.0, 1.0)), spEncode(clamp(p.z, 0.0, 1.0)));
}
SP_FN SP_V3 spEncodeExtV3(SP_V3 p) {
    return SP_V3C(spEncode(p.x), spEncode(p.y), spEncode(p.z));
}
SP_FN bool spInGamut(SP_V3 p) {
    return p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0 && p.z >= 0.0 && p.z <= 1.0;
}
SP_FN SP_V3 spBoundedMove(SP_V3 p, SP_V3 delta) {
    float scale = 1.0;
    if (delta.x > 0.0) scale = min(scale, (1.0 - p.x) / delta.x);
    if (delta.x < 0.0) scale = min(scale, -p.x / delta.x);
    if (delta.y > 0.0) scale = min(scale, (1.0 - p.y) / delta.y);
    if (delta.y < 0.0) scale = min(scale, -p.y / delta.y);
    if (delta.z > 0.0) scale = min(scale, (1.0 - p.z) / delta.z);
    if (delta.z < 0.0) scale = min(scale, -p.z / delta.z);
    return p + delta * scale;
}
SP_FN SP_V3 spSoftBoundedMove(SP_V3 p, SP_V3 delta) {
    float pressure = 0.0;
    if (delta.x > 0.0) pressure = max(pressure, delta.x / (1.0 - p.x));
    if (delta.x < 0.0) pressure = max(pressure, -delta.x / p.x);
    if (delta.y > 0.0) pressure = max(pressure, delta.y / (1.0 - p.y));
    if (delta.y < 0.0) pressure = max(pressure, -delta.y / p.y);
    if (delta.z > 0.0) pressure = max(pressure, delta.z / (1.0 - p.z));
    if (delta.z < 0.0) pressure = max(pressure, -delta.z / p.z);
    return p + delta / (1.0 + pressure);
}
SP_FN float spSampleField(uint baseOffset, uint fw, uint fh, float xCoord, float yCoord SP_CTX_DECL) {
    float fx = clamp(xCoord, 0.0, float(fw - 1u));
    float fy = clamp(yCoord, 0.0, float(fh - 1u));
    uint x0 = uint(floor(fx));
    uint y0 = uint(floor(fy));
    uint x1 = min(x0 + 1u, fw - 1u);
    uint y1 = min(y0 + 1u, fh - 1u);
    float tx = fx - float(x0);
    float ty = fy - float(y0);
    float v00 = SP_FIELD(baseOffset + y0 * fw + x0);
    float v10 = SP_FIELD(baseOffset + y0 * fw + x1);
    float v01 = SP_FIELD(baseOffset + y1 * fw + x0);
    float v11 = SP_FIELD(baseOffset + y1 * fw + x1);
    float top = v00 + (v10 - v00) * tx;
    float bottom = v01 + (v11 - v01) * tx;
    return top + (bottom - top) * ty;
}
SP_FN float spHueDist(float a, float b) {
    float d = abs(a - b);
    return min(d, 360.0 - d);
}
SP_FN SP_V3 spDefringePixel(int x, int y SP_CTX_DECL) {
    SP_V3 col = SP_SRC(x, y);
    if (!SP_FINITE(col)) return col;
    float pMin = 2.0;
    float pMax = 0.0;
    for (int ky = -3; ky <= 3; ++ky) {
        for (int kx = -3; kx <= 3; ++kx) {
            SP_V3 n = SP_SRC(x + kx, y + ky);
            float pl = SP_FINITE(n) ? sqrt(clamp(spLuma(n), 0.0, 4.0)) : 0.0;
            pMin = min(pMin, pl);
            pMax = max(pMax, pl);
        }
    }
    float edgeWeight = spSmooth(((pMax - pMin) - 0.08) / 0.18);
    if (edgeWeight <= 0.0) return col;
    float sr = spEncode01(col.x);
    float sg = spEncode01(col.y);
    float sb = spEncode01(col.z);
    float hi = max(sr, max(sg, sb));
    float lo = min(sr, min(sg, sb));
    float delta = hi - lo;
    if (delta <= 1e-4 || hi <= 1e-4) return col;
    float hue = (hi == sr) ? 60.0 * (sg - sb) / delta :
                (hi == sg) ? 60.0 * ((sb - sr) / delta + 2.0) :
                             60.0 * ((sr - sg) / delta + 4.0);
    if (hue < 0.0) hue += 360.0;
    float sat = delta / hi;
    float satWeight = spSmooth((sat - 0.05) / 0.15);
    if (satWeight <= 0.0) return col;
    float pNorm = SP_PURPLE_NORM;
    float gNorm = SP_GREEN_NORM;
    float pCenter = SP_PURPLE_CENTER;
    float gCenter = SP_GREEN_CENTER;
    float wPurple = pNorm > 0.0 ? pNorm * (1.0 - spSmooth(spHueDist(hue, pCenter) / 45.0)) : 0.0;
    float wGreen = gNorm > 0.0 ? gNorm * (1.0 - spSmooth(spHueDist(hue, gCenter) / 45.0)) : 0.0;
    float suppress = clamp(edgeWeight * satWeight * max(wPurple, wGreen), 0.0, 1.0);
    if (suppress <= 0.0) return col;
    float yLum = spLuma(col);
    return col + (SP_V3C(yLum, yLum, yLum) - col) * suppress;
}
SP_FN SP_V3 spDehazePixel(int x, int y SP_CTX_DECL) {
    SP_V3 enc = SP_SRC(x, y);
    if (!SP_FINITE(enc) || SP_STRENGTH == 0.0) return enc;
    bool bounded = spInGamut(enc);
    if (SP_STRENGTH > 0.0 && !bounded) return enc;
    SP_V3 linP = spDecodeV3(enc);
    float luma = spLuma(linP);
    uint fw = SP_FLAGS.y;
    uint fh = SP_FLAGS.z;
    uint planeSize = fw * fh;
    uint baseOff = SP_FLAGS.w;
    float ax = (float(x) + 0.5) * float(fw) / float(SP_WIDTH) - 0.5;
    float ay = (float(y) + 0.5) * float(fh) / float(SP_HEIGHT) - 0.5;
    float slopeVal = spSampleField(baseOff, fw, fh, ax, ay SP_CTX_ARG);
    float interVal = spSampleField(baseOff + planeSize, fw, fh, ax, ay SP_CTX_ARG);
    float varVal = spSampleField(baseOff + planeSize * 2u, fw, fh, ax, ay SP_CTX_ARG);
    float minTrans = SP_AIRLIGHT.w;
    float tVal = clamp(slopeVal * luma + interVal, minTrans, 1.0);
    SP_V3 air = SP_V3C(SP_AIRLIGHT.x, SP_AIRLIGHT.y, SP_AIRLIGHT.z);
    SP_V3 delta = SP_V3C(0.0, 0.0, 0.0);
    bool basicV3 = SP_FLAGS.x != 0u;
    if (SP_STRENGTH > 0.0) {
        float flatBright = spSmooth((luma - 0.08) / 0.22) * (1.0 - spSmooth(varVal / 0.001));
        float protect = basicV3
            ? (luma / (luma + 0.015)) * (1.0 - 0.4 * spSmooth((luma - 0.6) / 0.35))
            : (luma / (luma + 0.03)) * (1.0 - 0.8 * spSmooth((luma - 0.5) / 0.4)) * (1.0 - 0.75 * flatBright);
        float eff = max(minTrans, 1.0 - SP_STRENGTH * protect * (1.0 - tVal));
        float gain = 1.0 / eff - 1.0;
        delta = (linP - air) * gain;
    } else {
        float haze = basicV3 ? -SP_STRENGTH * 0.6 * (0.5 + 0.5 * (1.0 - tVal))
                             : -SP_STRENGTH * 0.45 * (0.25 + 0.75 * (1.0 - tVal));
        delta = (air - linP) * haze;
    }
    if (max(abs(delta.x), max(abs(delta.y), abs(delta.z))) < 1e-8) return enc;
    return bounded ? spEncodeV3(SP_STRENGTH > 0.0 ? spSoftBoundedMove(linP, delta) : spBoundedMove(linP, delta))
                   : spEncodeExtV3(linP + delta);
}
SP_FN SP_V3 spClarityPixel(int x, int y SP_CTX_DECL) {
    SP_V3 enc = SP_SRC(x, y);
    if (!SP_FINITE(enc) || SP_STRENGTH == 0.0) return enc;
    bool bounded = spInGamut(enc);
    SP_V3 linP = spDecodeV3(enc);
    float luma = spLuma(linP);
    if (luma <= 0.0) return enc;
    uint fw = SP_FLAGS.y;
    uint fh = SP_FLAGS.z;
    uint planeSize = fw * fh;
    uint baseOff = SP_FLAGS.w;
    float ax = (float(x) + 0.5) * float(fw) / float(SP_WIDTH) - 0.5;
    float ay = (float(y) + 0.5) * float(fh) / float(SP_HEIGHT) - 0.5;
    float medVal = spSampleField(baseOff, fw, fh, ax, ay SP_CTX_ARG);
    float resVal = spSampleField(baseOff + planeSize, fw, fh, ax, ay SP_CTX_ARG);
    if (SP_FLAGS.x != 0u) {
        float root = sqrt(luma);
        float weight = spSmooth(root / 0.1) * (1.0 - 0.6 * spSmooth((root - 0.85) / 0.15));
        float effStrength = SP_STRENGTH > 0.0 ? 1.36 * SP_STRENGTH : -0.8 * pow(-SP_STRENGTH, 0.75);
        float adjusted = max(0.0, root + effStrength * weight * resVal);
        float gain = adjusted * adjusted / luma - 1.0;
        if (bounded) return spEncodeV3(spBoundedMove(linP, linP * gain));
        if (gain < 0.0) return spEncodeExtV3(linP * (1.0 + gain));
        return enc;
    }
    float fineGuard = 1.0 - spSmooth(abs(luma - medVal) / 0.08);
    float lightGuard = spSmooth((luma - 0.01) / 0.12) * (1.0 - spSmooth((luma - 0.65) / 0.3));
    float delta = 1.5 * SP_STRENGTH * resVal * fineGuard * lightGuard;
    if (abs(delta) < 1e-8) return enc;
    float gain = max(-1.0, delta / luma);
    if (bounded) return spEncodeV3(spBoundedMove(linP, linP * gain));
    if (gain < 0.0) return spEncodeExtV3(linP * (1.0 + gain));
    return enc;
}
SP_FN float spTextureRootAt(int x, int y SP_CTX_DECL) {
    SP_V3 enc = SP_SRC(x, y);
    if (!SP_FINITE(enc)) return 0.0;
    float lum = max(0.0, spLuma(spDecodeV3(enc)));
    return sqrt(lum);
}
SP_FN SP_V3 spTextureBlurHPixel(int x, int y SP_CTX_DECL) {
    SP_V3 enc = SP_SRC(x, y);
    float finiteFlag = SP_FINITE(enc) ? 1.0 : 0.0;
    float centerRoot = spTextureRootAt(x, y SP_CTX_ARG);
    int r = int(SP_RADIUS);
    float sum = 0.0;
    for (int k = -r; k <= r; ++k) {
        sum += spTextureRootAt(x + k, y SP_CTX_ARG) * SP_WEIGHT(uint(k + r));
    }
    return SP_V3C(centerRoot, sum, finiteFlag);
}
SP_FN SP_V3 spTextureApplyVPixel(int x, int y SP_CTX_DECL) {
    SP_V3 enc = SP_SRC(x, y);
    SP_V3 centerAux = SP_AUX(x, y);
    if (centerAux.z < 0.5 || !SP_FINITE(enc) || SP_STRENGTH == 0.0) return enc;
    SP_V3 linP = spDecodeV3(enc);
    float luma = spLuma(linP);
    if (luma <= 0.0) return enc;
    int r = int(SP_RADIUS);
    float blurV = 0.0;
    for (int k = -r; k <= r; ++k) {
        blurV += SP_AUX(x, y + k).y * SP_WEIGHT(uint(k + r));
    }
    float root = centerAux.x;
    float detailVal = root - blurV;
    float weight = spSmooth(root / 0.08) * (1.0 - 0.45 * spSmooth((root - 0.85) / 0.15));
    float delta = SP_STRENGTH > 0.0
        ? 0.85 * SP_STRENGTH * weight * (detailVal / (1.0 + (detailVal * detailVal) / 0.015))
        : 0.75 * SP_STRENGTH * weight * detailVal;
    if (abs(delta) < 1e-8) return enc;
    float adjusted = max(0.0, root + delta);
    float gain = adjusted * adjusted / luma - 1.0;
    if (spInGamut(enc)) return spEncodeV3(spBoundedMove(linP, linP * gain));
    if (gain < 0.0) return spEncodeExtV3(linP * (1.0 + gain));
    return enc;
}
SP_FN float spSharpenLumaAt(int x, int y SP_CTX_DECL) {
    SP_V3 p = SP_SRC(x, y);
    if (!SP_FINITE(p)) return 0.0;
    return spLuma(clamp(p, SP_V3C(0.0, 0.0, 0.0), SP_V3C(1.0, 1.0, 1.0)));
}
SP_FN float spSobelAt(int x, int y SP_CTX_DECL) {
    float l00 = spSharpenLumaAt(x - 1, y - 1 SP_CTX_ARG);
    float l10 = spSharpenLumaAt(x,     y - 1 SP_CTX_ARG);
    float l20 = spSharpenLumaAt(x + 1, y - 1 SP_CTX_ARG);
    float l01 = spSharpenLumaAt(x - 1, y     SP_CTX_ARG);
    float l21 = spSharpenLumaAt(x + 1, y     SP_CTX_ARG);
    float l02 = spSharpenLumaAt(x - 1, y + 1 SP_CTX_ARG);
    float l12 = spSharpenLumaAt(x,     y + 1 SP_CTX_ARG);
    float l22 = spSharpenLumaAt(x + 1, y + 1 SP_CTX_ARG);
    float gx = ((l20 + 2.0 * l21 + l22) - (l00 + 2.0 * l01 + l02)) * 0.125;
    float gy = ((l02 + 2.0 * l12 + l22) - (l00 + 2.0 * l10 + l20)) * 0.125;
    return sqrt(gx * gx + gy * gy);
}
SP_FN SP_V3 spSharpenPrepHPixel(int x, int y SP_CTX_DECL) {
    int r = int(SP_RADIUS);
    float sum = 0.0;
    for (int k = -r; k <= r; ++k) {
        sum += spSharpenLumaAt(x + k, y SP_CTX_ARG) * SP_WEIGHT(uint(k + r));
    }
    float gMaxH = max(spSobelAt(x - 1, y SP_CTX_ARG),
                  max(spSobelAt(x, y SP_CTX_ARG), spSobelAt(x + 1, y SP_CTX_ARG)));
    float centerL = spSharpenLumaAt(x, y SP_CTX_ARG);
    return SP_V3C(sum, gMaxH, centerL);
}
SP_FN SP_V3 spSharpenPrepVPixel(int x, int y SP_CTX_DECL) {
    int r = int(SP_RADIUS);
    float blurV = 0.0;
    for (int k = -r; k <= r; ++k) {
        blurV += SP_SRC(x, y + k).x * SP_WEIGHT(uint(k + r));
    }
    float gDilated = max(SP_SRC(x, y - 1).y, max(SP_SRC(x, y).y, SP_SRC(x, y + 1).y));
    float centerL = SP_SRC(x, y).z;
    return SP_V3C(centerL, blurV, gDilated);
}
SP_FN SP_V3 spSharpenMaskHPixel(int x, int y SP_CTX_DECL) {
    SP_V3 c = SP_SRC(x, y);
    int r = int(SP_RADIUS);
    float sum = 0.0;
    for (int k = -r; k <= r; ++k) {
        sum += SP_SRC(x + k, y).z * SP_WEIGHT(uint(k + r));
    }
    return SP_V3C(c.x, c.y, sum);
}
SP_FN SP_V3 spSharpenApplyPixel(int x, int y SP_CTX_DECL) {
    SP_V3 col = SP_SRC(x, y);
    if (!SP_FINITE(col) || SP_STRENGTH <= 0.0) return col;
    SP_V3 auxData = SP_AUX(x, y);
    float maskVal = 1.0;
    if (SP_SHARPEN_MASK_SPAN > 0.0) {
        int r = int(SP_RADIUS);
        float gField = 0.0;
        for (int k = -r; k <= r; ++k) {
            gField += SP_AUX(x, y + k).z * SP_WEIGHT(uint(k + r));
        }
        maskVal = spSmooth((gField - SP_SHARPEN_MASK_LOW) / SP_SHARPEN_MASK_SPAN);
    }
    if (maskVal <= 0.0) return col;
    float diff = auxData.x - auxData.y;
    float coring = SP_SHARPEN_CORING;
    float detailWeight = coring <= 1e-4 ? 1.0 : spSmooth(abs(diff) / coring);
    float detailGain = SP_STRENGTH;
    float delta = clamp(maskVal * detailWeight * detailGain * diff, -0.35, 0.35);
    if (delta == 0.0) return col;
    float minC = min(col.x, min(col.y, col.z));
    float maxC = max(col.x, max(col.y, col.z));
    if (minC >= 0.0 && maxC <= 1.0) {
        delta = clamp(delta, -minC, 1.0 - maxC);
    }
    return clamp(col + SP_V3C(delta, delta, delta), SP_V3C(0.0, 0.0, 0.0), SP_V3C(1.0, 1.0, 1.0));
}
)shader";
}

} // namespace sony2fuji
