#pragma once

#include "sony2fuji/dcp_look.h"
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace sony2fuji {

// Cross-dialect GPU representation matching Adobe DNG SDK HSV + Tone DCP stages.
struct alignas(16) DcpGpuUniforms {
    float inputMatrix[3][4]{};
    float outputMatrix[3][4]{};
    float exposure[4]{1.0f, 0.0f, 0.0f, 0.0f};
    uint32_t calibration[4]{};
    uint32_t look[4]{};
    uint32_t offsets[4]{}; // [lookOffset, toneOffset, dataBaseOffset, active]
};
static_assert(sizeof(DcpGpuUniforms) == 160, "DCP GPU uniform layout");

inline bool packDcpLookGpuData(
    const DcpLook& dcp,
    DcpGpuUniforms& outUniforms,
    std::vector<float>& outData
) {
    outUniforms = {};
    outData.clear();

    const auto& s = dcp.stages();
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            outUniforms.inputMatrix[r][c] = static_cast<float>(s.input[r * 3 + c]);
            outUniforms.outputMatrix[r][c] = static_cast<float>(s.output[r * 3 + c]);
        }
    }
    outUniforms.exposure[0] = static_cast<float>(s.exposure);

    auto appendTable = [&](const DcpTable& table, uint32_t* dims) {
        dims[0] = table.hues;
        dims[1] = table.saturations;
        dims[2] = table.values;
        dims[3] = table.encoding;
        const uint32_t offset = static_cast<uint32_t>(outData.size());
        if (!table.entries.empty()) {
            outData.reserve(outData.size() + table.entries.size() * 3u);
            for (const auto& entry : table.entries) {
                outData.push_back(entry.r);
                outData.push_back(entry.g);
                outData.push_back(entry.b);
            }
        }
        return offset;
    };

    (void)appendTable(s.calibration, outUniforms.calibration);
    outUniforms.offsets[0] = appendTable(s.look, outUniforms.look);
    outUniforms.offsets[1] = static_cast<uint32_t>(outData.size());
    outData.reserve(outData.size() + s.tone.size());
    for (double v : s.tone) {
        outData.push_back(static_cast<float>(v));
    }
    outUniforms.offsets[2] = 0u;
    outUniforms.offsets[3] = 1u;
    return !outData.empty();
}

// Shared cross-dialect DCP shader helpers for Metal, GLSL ES 3.10, and HLSL cs_5_0.
// Embedding callers define dialect-specific helper macros around this string:
//   DCP_FN, DCP_V3, DCP_V3C(x,y,z), DCP_U3, DCP_U3C(x,y,z), DCP_U4,
//   DCP_CTX_DECL, DCP_CTX_ARG, DCP_SRGB_GAMMA(x), DCP_NEUTRAL(x),
//   DCP_LERP3(a,b,t), DCP_FINITE(v), DCP_DATA(idx), DCP_MARK_INVALID()
inline std::string dcpLookShaderBody() {
    return R"shader(
DCP_FN float dcpWrapHue(float hueVal) {
    float wrapped = hueVal - 6.0 * floor(hueVal / 6.0);
    return wrapped >= 6.0 ? 0.0 : wrapped;
}
DCP_FN DCP_V3 dcpApplyMat(DCP_V3 col, DCP_V3 row0, DCP_V3 row1, DCP_V3 row2) {
    return DCP_V3C(dot(row0, col), dot(row1, col), dot(row2, col));
}
DCP_FN float dcpSampleTone(float val, uint toneStart DCP_CTX_DECL) {
    float pos = clamp(val, 0.0, 1.0) * 4096.0;
    uint idx = min(uint(pos), 4095u);
    float frac = pos - float(idx);
    float t0 = DCP_DATA(toneStart + idx);
    float t1 = DCP_DATA(toneStart + idx + 1u);
    return t0 + (t1 - t0) * frac;
}
DCP_FN DCP_V3 dcpEvalHsv(DCP_V3 col, DCP_U4 dimsVec, uint tableOffset DCP_CTX_DECL) {
    if (dimsVec.x == 0u) return col;
    col = clamp(col, DCP_V3C(0.0, 0.0, 0.0), DCP_V3C(1.0, 1.0, 1.0));
    float hi = max(col.x, max(col.y, col.z));
    float lo = min(col.x, min(col.y, col.z));
    float delta = hi - lo;
    float divisor = delta > 0.0 ? delta : 1.0;
    float hue = hi == col.x ? (col.y - col.z) / divisor :
                (hi == col.y ? 2.0 + (col.z - col.x) / divisor : 4.0 + (col.x - col.y) / divisor);
    hue = dcpWrapHue(hue);
    float sat = hi > 0.0 ? delta / hi : 0.0;
    float encodedHi = dimsVec.w == 1u ? DCP_SRGB_GAMMA(hi) : hi;
    DCP_V3 pos = DCP_V3C(hue * float(dimsVec.x) / 6.0, sat * float(dimsVec.y - 1u), encodedHi * float(dimsVec.z - 1u));
    DCP_U3 low = DCP_U3C(
        min(uint(pos.x), dimsVec.x - 1u),
        min(uint(pos.y), dimsVec.y - 2u),
        dimsVec.z > 1u ? min(uint(pos.z), dimsVec.z - 2u) : 0u);
    DCP_V3 frac = pos - DCP_V3C(float(low.x), float(low.y), float(low.z));
    DCP_V3 adj = DCP_V3C(0.0, 0.0, 0.0);
    for (uint h = 0u; h < 2u; ++h) {
        for (uint s = 0u; s < 2u; ++s) {
            for (uint v = 0u; v < 2u; ++v) {
                float wt = (h != 0u ? frac.x : 1.0 - frac.x) *
                           (s != 0u ? frac.y : 1.0 - frac.y) *
                           (v != 0u ? frac.z : 1.0 - frac.z);
                uint vIdx = min(low.z + v, dimsVec.z - 1u);
                uint hIdx = (low.x + h) % dimsVec.x;
                uint idx = tableOffset + 3u * ((vIdx * dimsVec.x + hIdx) * dimsVec.y + low.y + s);
                adj += wt * DCP_V3C(DCP_DATA(idx), DCP_DATA(idx + 1u), DCP_DATA(idx + 2u));
            }
        }
    }
    if (!DCP_FINITE(adj)) {
        DCP_MARK_INVALID();
        return DCP_V3C(0.0, 0.0, 0.0);
    }
    hue = dcpWrapHue(hue + adj.x / 60.0);
    sat = clamp(sat * adj.y, 0.0, 1.0);
    float val = clamp(encodedHi * adj.z, 0.0, 1.0);
    if (dimsVec.w == 1u) {
        val = val <= 0.04045 ? val / 12.92 : pow((val + 0.055) / 1.055, 2.4);
    }
    float chroma = val * sat;
    float hueMod = hue - 2.0 * floor(hue / 2.0);
    float second = chroma * (1.0 - abs(hueMod - 1.0));
    uint sector = uint(hue);
    DCP_V3 outRgb = DCP_V3C(0.0, 0.0, 0.0);
    if (sector == 0u) outRgb = DCP_V3C(chroma, second, 0.0);
    else if (sector == 1u) outRgb = DCP_V3C(second, chroma, 0.0);
    else if (sector == 2u) outRgb = DCP_V3C(0.0, chroma, second);
    else if (sector == 3u) outRgb = DCP_V3C(0.0, second, chroma);
    else if (sector == 4u) outRgb = DCP_V3C(second, 0.0, chroma);
    else outRgb = DCP_V3C(chroma, 0.0, second);
    return clamp(outRgb + DCP_V3C(val - chroma, val - chroma, val - chroma),
                 DCP_V3C(0.0, 0.0, 0.0), DCP_V3C(1.0, 1.0, 1.0));
}
DCP_FN DCP_V3 dcpApplyLookPixel(
    DCP_V3 linearSrgb,
    DCP_V3 inRow0, DCP_V3 inRow1, DCP_V3 inRow2,
    DCP_V3 outRow0, DCP_V3 outRow1, DCP_V3 outRow2,
    float expScale,
    DCP_U4 calibDims, DCP_U4 lookDims,
    uint lookStart, uint toneStart,
    float blendStrength DCP_CTX_DECL
) {
    DCP_V3 baseDisplay = DCP_V3C(DCP_NEUTRAL(linearSrgb.x), DCP_NEUTRAL(linearSrgb.y), DCP_NEUTRAL(linearSrgb.z));
    DCP_V3 col = dcpApplyMat(linearSrgb, inRow0, inRow1, inRow2);
    if (!DCP_FINITE(col)) { DCP_MARK_INVALID(); return DCP_V3C(0.0, 0.0, 0.0); }
    col = dcpEvalHsv(col, calibDims, 0u DCP_CTX_ARG) * expScale;
    if (!DCP_FINITE(col)) { DCP_MARK_INVALID(); return DCP_V3C(0.0, 0.0, 0.0); }
    col = clamp(dcpEvalHsv(col, lookDims, lookStart DCP_CTX_ARG),
                DCP_V3C(0.0, 0.0, 0.0), DCP_V3C(1.0, 1.0, 1.0));
    float lo = min(col.x, min(col.y, col.z));
    float hi = max(col.x, max(col.y, col.z));
    float lower = dcpSampleTone(lo, toneStart DCP_CTX_ARG);
    float upper = dcpSampleTone(hi, toneStart DCP_CTX_ARG);
    DCP_V3 scaleVec = hi != lo ? (col - DCP_V3C(lo, lo, lo)) / (hi - lo) : DCP_V3C(0.0, 0.0, 0.0);
    col = DCP_V3C(lower, lower, lower) + (upper - lower) * scaleVec;
    col = dcpApplyMat(col, outRow0, outRow1, outRow2);
    if (!DCP_FINITE(col)) { DCP_MARK_INVALID(); return DCP_V3C(0.0, 0.0, 0.0); }
    DCP_V3 filmDisplay = clamp(DCP_V3C(DCP_SRGB_GAMMA(col.x), DCP_SRGB_GAMMA(col.y), DCP_SRGB_GAMMA(col.z)),
                               DCP_V3C(0.0, 0.0, 0.0), DCP_V3C(1.0, 1.0, 1.0));
    return DCP_LERP3(baseDisplay, filmDisplay, blendStrength);
}
)shader";
}

} // namespace sony2fuji
