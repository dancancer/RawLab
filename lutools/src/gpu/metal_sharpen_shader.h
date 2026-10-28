#pragma once

static const char* kNoiseAwareSharpenShader = R"METAL(
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

struct Params { uint width, height; float amount; };
uint indexAt(int x, int y, constant Params& p) {
    return uint(clamp(y, 0, int(p.height) - 1)) * p.width + uint(clamp(x, 0, int(p.width) - 1));
}
uint adjacent(uint i, bool horizontal, int offset, constant Params& p) {
    return indexAt(int(i % p.width) + (horizontal ? offset : 0), int(i / p.width) + (horizontal ? 0 : offset), p);
}

kernel void sharpenGradients(constant Params& p [[buffer(0)]], device const float* luma [[buffer(1)]],
    device const float* residual [[buffer(2)]], device float4* stats [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    int x = int(i % p.width), y = int(i / p.width);
    float tl = luma[indexAt(x-1, y-1, p)], t = luma[indexAt(x, y-1, p)], tr = luma[indexAt(x+1, y-1, p)];
    float l = luma[indexAt(x-1, y, p)], r = luma[indexAt(x+1, y, p)];
    float bl = luma[indexAt(x-1, y+1, p)], b = luma[indexAt(x, y+1, p)], br = luma[indexAt(x+1, y+1, p)];
    float gx = (r-l)*.25f + ((tr-tl)+(br-bl))*.125f;
    float gy = (b*.25f + (bl+br)*.125f) - (t*.25f + (tl+tr)*.125f);
    stats[i] = float4(gx, gy, length(float2(gx, gy)), residual[i]*residual[i]);
}

// OpenCV 对 float 输入使用 double 累加；保留舍入残差，避免均值误差翻转硬阈值。
struct Sum { float4 high, low; };
void add(thread Sum& sum, float4 value) {
    float4 next = sum.high + value, part = next - sum.high;
    sum.low += (sum.high - (next - part)) + (value - part);
    sum.high = next;
}
kernel void sharpenMeanRows(constant Params& p [[buffer(0)]], device const float4* input [[buffer(1)]],
    device Sum* output [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    Sum sum{0, 0};
    for (int offset = -4; offset <= 4; ++offset) add(sum, input[adjacent(i, true, offset, p)]);
    output[i] = sum;
}
kernel void sharpenMeanColumns(constant Params& p [[buffer(0)]], device const Sum* input [[buffer(1)]],
    device float4* output [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    Sum sum{0, 0};
    for (int offset = -4; offset <= 4; ++offset) {
        Sum row = input[adjacent(i, false, offset, p)];
        add(sum, row.high); add(sum, row.low);
    }
    float4 quotient = sum.high / 81.f;
    output[i] = quotient + (fma(-quotient, 81.f, sum.high) + sum.low) / 81.f;
}

kernel void sharpenInitial(constant Params& p [[buffer(0)]], device const packed_float3* rgb [[buffer(1)]],
    device const float* luma [[buffer(2)]], device const float* residual [[buffer(3)]],
    device const float* noise [[buffer(4)]], device const float4* stats [[buffer(5)]],
    device const float4* means [[buffer(6)]], device float4* initial [[buffer(7)]],
    device uint* flags [[buffer(8)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    int x = int(i % p.width), y = int(i / p.width);
    float peak = 0;
    for (int dy = -4; dy <= 4; ++dy) for (int dx = -4; dx <= 4; ++dx)
        peak = max(peak, stats[indexAt(x+dx, y+dy, p)].z);
    float3 low = 1, high = 0;
    bool interior = true;
    for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
        float3 v = rgb[indexAt(x+dx, y+dy, p)];
        low = min(low, v); high = max(high, v);
        interior = interior && all(v > 0) && all(v < 1);
    }
    float weight = max(means[i].w - 4*noise[i], 0.f) / max(means[i].w + noise[i], 1e-12f);
    float coherence = length(means[i].xy) / max(means[i].z, 1e-12f);
    float core = clamp((stats[i].z / max(peak, 1e-12f) - .2f) / .2f, 0.f, 1.f);
    core = core*core*(3-2*core) * float(coherence > .75f && interior);
    float wanted = 2*weight*residual[i]*core;
    float3 v = rgb[i], lo = low-v, hi = high-v;
    float delta = clamp(wanted, max(lo.x, max(lo.y, lo.z)), min(hi.x, min(hi.y, hi.z)));
    bool horizontal = abs(stats[i].x) >= abs(stats[i].y);
    float gradient = horizontal ? stats[i].x : stats[i].y, sign = gradient >= 0 ? 1.f : -1.f;
    float before = sign*(luma[i] - luma[adjacent(i, horizontal, -1, p)]);
    float after = sign*(luma[adjacent(i, horizontal, 1, p)] - luma[i]);
    float sigma = sqrt(noise[i]);
    bool edge = abs(gradient) > sigma && weight > 0 && core > 0;
    bool relaxable = edge && before > 2*sigma && after > 2*sigma;
    flags[i] = uint(horizontal) | (uint(sign > 0) << 1) | (uint(edge) << 2) | (uint(relaxable) << 3) |
        (uint(stats[i].z < .75f*peak) << 4);
    initial[i] = float4(wanted, delta, before, after);
}

kernel void sharpenRelax(constant Params& p [[buffer(0)]], device const packed_float3* rgb [[buffer(1)]],
    device const float4* initial [[buffer(2)]], device const uint* flags [[buffer(3)]],
    device float4* output [[buffer(4)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    bool horizontal = flags[i] & 1;
    float sign = (flags[i] & 2) ? 1.f : -1.f, delta = initial[i].y;
    if (flags[i] & 8) {
        float floor = min(sign*initial[adjacent(i, horizontal, -1, p)].y - initial[i].z, 0.f);
        float ceiling = max(sign*initial[adjacent(i, horizontal, 1, p)].y + initial[i].w, 0.f);
        delta = sign*clamp(sign*initial[i].x, floor, ceiling);
    }
    float3 v = rgb[i];
    delta = clamp(delta, -min(v.x, min(v.y, v.z)), 1-max(v.x, max(v.y, v.z)));
    if (flags[i] & 16) delta = clamp(delta, -1.f/255, 1.f/255);
    float peak = 0;
    int x = int(i % p.width), y = int(i / p.width);
    for (int dy = -4; dy <= 4; ++dy) for (int dx = -4; dx <= 4; ++dx) {
        float2 steps = abs(initial[indexAt(x+dx, y+dy, p)].zw);
        peak = max(peak, max(steps.x, steps.y));
    }
    float before = initial[i].z >= .9f*peak ? 0 : max(initial[i].z, 0.f);
    float after = initial[i].w >= .9f*peak ? 0 : max(initial[i].w, 0.f);
    output[i] = float4(delta, before, after, 0);
}

kernel void sharpenProject(constant Params& p [[buffer(0)]], device const float4* input [[buffer(1)]],
    device const uint* flags [[buffer(2)]], device float4* output [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    float4 v = input[i];
    if (flags[i] & 4) {
        bool horizontal = flags[i] & 1;
        float sign = (flags[i] & 2) ? 1.f : -1.f;
        float floor = min(sign*input[adjacent(i, horizontal, -1, p)].x - v.y, 0.f);
        float ceiling = max(sign*input[adjacent(i, horizontal, 1, p)].x + v.z, 0.f);
        v.x = sign*clamp(sign*v.x, floor, ceiling);
    }
    output[i] = v;
}
kernel void sharpenOutput(constant Params& p [[buffer(0)]], device const packed_float3* rgb [[buffer(1)]],
    device const float4* delta [[buffer(2)]], device packed_float3* output [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    output[i] = packed_float3(clamp(float3(rgb[i]) + (p.amount/2)*delta[i].x, 0.f, 1.f));
}
)METAL";
