#pragma once

// HSV/tone stages follow Adobe DNG SDK reference algorithms.
// Copyright 2006-2023 Adobe Systems Incorporated. All Rights Reserved.
// See third_party/Adobe-DNG-SDK-LICENSE.txt.
static const char* kDcpShaderSource = R"metal(
struct DcpParams {
    float input[9];
    float output[9];
    float exposure;
    uint calibration[4];
    uint look[4];
    uint lookOffset;
    uint toneOffset;
};

inline bool dcpFinite(float3 value, device atomic_uint* invalid) {
    if (all(isfinite(value))) return true;
    atomic_store_explicit(invalid, 1u, memory_order_relaxed);
    return false;
}

inline float3 dcpMatrix(float3 rgb, constant float* m) {
    return float3(m[0]*rgb.r+m[1]*rgb.g+m[2]*rgb.b,
                  m[3]*rgb.r+m[4]*rgb.g+m[5]*rgb.b,
                  m[6]*rgb.r+m[7]*rgb.g+m[8]*rgb.b);
}

inline float dcpWrap(float hue) {
    hue = fmod(hue, 6.0f);
    if (hue < 0.0f) hue += 6.0f;
    return hue >= 6.0f ? 0.0f : hue;
}

inline float3 dcpHsv(float3 rgb, constant uint* dims, device const float* data,
                      uint offset, device atomic_uint* invalid) {
    if (dims[0] == 0u) return rgb;
    rgb = clamp(rgb, 0.0f, 1.0f);
    float hi = max(rgb.r, max(rgb.g, rgb.b)), lo = min(rgb.r, min(rgb.g, rgb.b));
    float delta = hi - lo, divisor = delta > 0.0f ? delta : 1.0f;
    float hue = hi == rgb.r ? (rgb.g-rgb.b)/divisor :
                hi == rgb.g ? 2.0f+(rgb.b-rgb.r)/divisor : 4.0f+(rgb.r-rgb.g)/divisor;
    hue = dcpWrap(hue);
    float sat = hi > 0.0f ? delta/hi : 0.0f;
    float encoded = dims[3] == 1u ? srgbGamma(hi) : hi;
    float3 position = float3(hue*float(dims[0])/6.0f, sat*float(dims[1]-1u), encoded*float(dims[2]-1u));
    uint3 low = uint3(min(uint(position.x), dims[0]-1u), min(uint(position.y), dims[1]-2u),
                     dims[2] > 1u ? min(uint(position.z), dims[2]-2u) : 0u);
    float3 fraction = position-float3(low), adjustment = 0.0f;
    for (uint h=0; h<2; ++h) for (uint s=0; s<2; ++s) for (uint v=0; v<2; ++v) {
        float weight = (h ? fraction.x : 1.0f-fraction.x) * (s ? fraction.y : 1.0f-fraction.y) *
                       (v ? fraction.z : 1.0f-fraction.z);
        uint index = offset+3u*((min(low.z+v,dims[2]-1u)*dims[0]+(low.x+h)%dims[0])*dims[1]+low.y+s);
        adjustment += weight*float3(data[index],data[index+1u],data[index+2u]);
    }
    if (!dcpFinite(adjustment, invalid)) return 0.0f;
    hue = dcpWrap(hue+adjustment.x/60.0f);
    sat = clamp(sat*adjustment.y,0.0f,1.0f);
    float value = clamp(encoded*adjustment.z,0.0f,1.0f);
    if (dims[3] == 1u) value = value <= .04045f ? value/12.92f : pow((value+.055f)/1.055f,2.4f);
    float chroma = value*sat, x = chroma*(1.0f-abs(fmod(hue,2.0f)-1.0f));
    switch (uint(hue)) {
        case 0u: rgb=float3(chroma,x,0); break;
        case 1u: rgb=float3(x,chroma,0); break;
        case 2u: rgb=float3(0,chroma,x); break;
        case 3u: rgb=float3(0,x,chroma); break;
        case 4u: rgb=float3(x,0,chroma); break;
        default: rgb=float3(chroma,0,x); break;
    }
    return clamp(rgb+value-chroma,0.0f,1.0f);
}

inline float dcpTone(float value, device const float* data, uint offset) {
    float position=clamp(value,0.0f,1.0f)*4096.0f;
    uint index=min(uint(position),4095u);
    return data[offset+index]+(data[offset+index+1u]-data[offset+index])*(position-float(index));
}

kernel void baseAndDcp(
    constant Params& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    constant DcpParams& dcp [[buffer(3)]],
    device const float* data [[buffer(4)]],
    device atomic_uint* invalid [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= params.srcWidth*params.srcHeight) return;
    float3 input=float3(source[gid]), rgb=dcpMatrix(input,dcp.input);
    if (!dcpFinite(rgb,invalid)) { destination[gid]=packed_float3(0.0f); return; }
    rgb=dcpHsv(rgb,dcp.calibration,data,0u,invalid)*dcp.exposure;
    if (!dcpFinite(rgb,invalid)) { destination[gid]=packed_float3(0.0f); return; }
    rgb=clamp(dcpHsv(rgb,dcp.look,data,dcp.lookOffset,invalid),0.0f,1.0f);
    float lo=min(rgb.r,min(rgb.g,rgb.b)), hi=max(rgb.r,max(rgb.g,rgb.b));
    float lower=dcpTone(lo,data,dcp.toneOffset), upper=dcpTone(hi,data,dcp.toneOffset);
    rgb=lower+(upper-lower)*(hi != lo ? (rgb-lo)/(hi-lo) : float3(0.0f));
    rgb=dcpMatrix(rgb,dcp.output);
    if (!dcpFinite(rgb,invalid)) { destination[gid]=packed_float3(0.0f); return; }
    float3 film=clamp(float3(srgbGamma(rgb.r),srgbGamma(rgb.g),srgbGamma(rgb.b)),0.0f,1.0f);
    float3 base=float3(neutralDisplay(input.r),neutralDisplay(input.g),neutralDisplay(input.b));
    destination[gid]=packed_float3(lerp3(base,film,params.lutStrength));
}
)metal";
