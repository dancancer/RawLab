#pragma once

static const char* kPhotoEffectsShaderSource = R"metal(
#include <metal_stdlib>
using namespace metal;

struct EffectsParams {
    uint width, height;
    float vignetteAmount, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights;
    float grainAmount, grainSize, grainRoughness;
};

float effectsSmooth(float value) {
    value = clamp(value, 0.f, 1.f);
    return value * value * (3 - 2 * value);
}

uint grainHash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

float grainNormal(int x, int y, uint seed) {
    const uint a = grainHash(uint(x) ^ grainHash(uint(y) + seed));
    const uint b = grainHash(a ^ 0x9e3779b9u);
    return (float((a & 65535u) + (a >> 16) + (b & 65535u) + (b >> 16)) /
        65535.f - 2.f) * 1.7320508f;
}

float grainNoise(float x, float y, uint seed) {
    const int ix = int(floor(x)), iy = int(floor(y));
    const float fx = effectsSmooth(x - ix), fy = effectsSmooth(y - iy);
    const float top = grainNormal(ix, iy, seed) * (1 - fx) + grainNormal(ix + 1, iy, seed) * fx;
    const float bottom = grainNormal(ix, iy + 1, seed) * (1 - fx) + grainNormal(ix + 1, iy + 1, seed) * fx;
    const float variance = ((1 - fx) * (1 - fx) + fx * fx) * ((1 - fy) * (1 - fy) + fy * fy);
    return (top * (1 - fy) + bottom * fy) / sqrt(variance);
}

float effectsLuminance(float3 pixel) {
    return clamp(0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b, 0.f, 1.f);
}

kernel void photoEffects(
    constant EffectsParams& params [[buffer(0)]],
    device const packed_float3* source [[buffer(1)]],
    device packed_float3* destination [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= params.width * params.height) return;
    const uint x = gid % params.width, y = gid / params.width;
    float3 pixel = float3(source[gid]);
    if (params.vignetteAmount != 0) {
        const float circle = max(0.f, params.vignetteRoundness / 100);
        const float shortSide = float(min(params.width, params.height));
        const float axisX = (params.width * (1 - circle) + shortSide * circle) * 0.5f;
        const float axisY = (params.height * (1 - circle) + shortSide * circle) * 0.5f;
        const float power = 2 + max(0.f, -params.vignetteRoundness / 100) * 6;
        const float radius = 0.35f + params.vignetteMidpoint * 0.01f;
        const float feather = params.vignetteFeather / 100;
        const float inner = radius * (1 - feather * 0.8f);
        const float outer = radius + feather * 0.4f;
        const float transition = max(outer - inner, 2.f / shortSide);
        const float nx = abs((x + 0.5f - params.width * 0.5f) / axisX);
        const float ny = abs((y + 0.5f - params.height * 0.5f) / axisY);
        const float distance = power == 2 ? sqrt(nx * nx + ny * ny) :
            pow(pow(nx, power) + pow(ny, power), 1 / power);
        float mask = effectsSmooth((distance - inner) / transition);
        if (params.vignetteAmount < 0)
            mask *= 1 - params.vignetteHighlights / 100 * effectsSmooth((effectsLuminance(pixel) - 0.5f) * 2);
        const float gain = exp2(-abs(params.vignetteAmount) * 0.03f * mask);
        pixel = params.vignetteAmount < 0 ? pixel * gain : 1 - (1 - pixel) * gain;
    }
    if (params.grainAmount > 0) {
        const float grainScale = 0.7f + params.grainSize * 0.055f;
        const float rough = params.grainRoughness * 0.007f;
        const float normalization = 1 / sqrt((1 - rough) * (1 - rough) + rough * rough);
        const float u = (x + 0.5f) / grainScale, v = (y + 0.5f) / grainScale;
        const float fine = grainNoise(u, v, 0x243f6a88u);
        const float coarse = grainNoise(u * 0.47f + 17.3f, v * 0.47f + 31.7f, 0x85a308d3u);
        const float noise = ((1 - rough) * fine + rough * coarse) * normalization;
        const float luma = effectsLuminance(pixel);
        const float delta = noise * params.grainAmount * 0.0012f * sqrt(4 * luma * (1 - luma));
        pixel = clamp(pixel + delta, 0.f, 1.f);
    }
    destination[gid] = packed_float3(pixel);
}
)metal";
