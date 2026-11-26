#pragma once

#include "gpu/dcp_look_shader.h"
#include <string>

// HSV/tone stages follow Adobe DNG SDK reference algorithms.
// Copyright 2006-2023 Adobe Systems Incorporated. All Rights Reserved.
// See third_party/Adobe-DNG-SDK-LICENSE.txt.
namespace sony2fuji {

inline std::string metalDcpShaderSource() {
    return std::string(R"metal(
struct DcpParams {
    float input[9];
    float output[9];
    float exposure;
    uint calibration[4];
    uint look[4];
    uint lookOffset;
    uint toneOffset;
};

#define DCP_FN inline
#define DCP_V3 float3
#define DCP_V3C(x, y, z) float3((x), (y), (z))
#define DCP_U3 uint3
#define DCP_U3C(x, y, z) uint3((x), (y), (z))
#define DCP_U4 uint4
#define DCP_CTX_DECL , device const float* dcpData, device atomic_uint* dcpInvalid
#define DCP_CTX_ARG , dcpData, dcpInvalid
#define DCP_SRGB_GAMMA(x) srgbGamma(x)
#define DCP_NEUTRAL(x) neutralDisplay(x)
#define DCP_LERP3(a, b, t) lerp3((a), (b), (t))
#define DCP_FINITE(v) all(isfinite(v))
#define DCP_DATA(idx) dcpData[(idx)]
#define DCP_MARK_INVALID() atomic_store_explicit(dcpInvalid, 1u, memory_order_relaxed)
)metal") + dcpLookShaderBody() + R"metal(
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

kernel void baseAndDcp(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    constant DcpParams& dcp [[buffer(3)]],
    device const float* data [[buffer(4)]],
    device atomic_uint* invalid [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= params.srcWidth * params.srcHeight) return;
    float3 inCol = float3(source[gid]);
    float3 inR0 = float3(dcp.input[0], dcp.input[1], dcp.input[2]);
    float3 inR1 = float3(dcp.input[3], dcp.input[4], dcp.input[5]);
    float3 inR2 = float3(dcp.input[6], dcp.input[7], dcp.input[8]);
    float3 outR0 = float3(dcp.output[0], dcp.output[1], dcp.output[2]);
    float3 outR1 = float3(dcp.output[3], dcp.output[4], dcp.output[5]);
    float3 outR2 = float3(dcp.output[6], dcp.output[7], dcp.output[8]);
    uint4 cal = uint4(dcp.calibration[0], dcp.calibration[1], dcp.calibration[2], dcp.calibration[3]);
    uint4 lk = uint4(dcp.look[0], dcp.look[1], dcp.look[2], dcp.look[3]);
    destination[gid] = packed_float3(dcpApplyLookPixel(
        inCol, inR0, inR1, inR2, outR0, outR1, outR2,
        dcp.exposure, cal, lk, dcp.lookOffset, dcp.toneOffset,
        params.lutStrength, data, invalid));
}
)metal";
}

} // namespace sony2fuji
