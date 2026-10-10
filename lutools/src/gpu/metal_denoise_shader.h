#pragma once

// The db2 phase convention matches the BSD-licensed wavelib implementation and
// the transpose inverse documented in cmake/wavelib-iswt2.c.inc.
static const char* kDenoiseShaderSource = R"metal(
#include <metal_stdlib>
using namespace metal;

int periodicIndex(int index, int length) {
    index %= length;
    return index < 0 ? index + length : index;
}

int reflectIndex(int index, int length, bool excludeEdge) {
    if (length == 1) return 0;
    const int period = 2 * (length - (excludeEdge ? 1 : 0));
    index = periodicIndex(index, period);
    return index < length ? index : period - index - (excludeEdge ? 0 : 1);
}

constant float db2Low[4] = {-.12940952255126037f, .22414386804201338f, .83651630373780791f, .48296291314453414f};
constant float db2High[4] = {-.48296291314453414f, .83651630373780791f, -.22414386804201338f, -.12940952255126037f};

struct WaveletParams {
    uint width, height, step, depth, level, window;
    float sigma, strength;
};

kernel void swtRows(constant WaveletParams& p [[buffer(0)]], device const float* input [[buffer(1)]],
                    device float* low [[buffer(2)]], device float* high [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    const int x = i % p.width, y = i / p.width;
    float a = 0, d = 0;
    for (int t = 0; t < 4; ++t) {
        const int sx = periodicIndex(x + int(p.step) * (2 - t), p.width);
        const float value = input[y * p.width + sx];
        a += db2Low[t] * value; d += db2High[t] * value;
    }
    low[i] = a; high[i] = d;
}

kernel void swtColumns(constant WaveletParams& p [[buffer(0)]], device const float* low [[buffer(1)]],
                       device const float* high [[buffer(2)]], device float* bands [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    const uint count = p.width * p.height;
    if (i >= count) return;
    const int x = i % p.width, y = i / p.width;
    float a = 0, h = 0, v = 0, d = 0;
    for (int t = 0; t < 4; ++t) {
        const int sy = periodicIndex(y + int(p.step) * (2 - t), p.height);
        const float lo = low[sy * p.width + x], hi = high[sy * p.width + x];
        a += db2Low[t] * lo; h += db2High[t] * lo;
        v += db2Low[t] * hi; d += db2High[t] * hi;
    }
    const uint block = 1 + (p.depth - p.level) * 3;
    const float divisor = float(1u << p.level);
    bands[i] = a;
    bands[block * count + i] = h / divisor;
    bands[(block + 1) * count + i] = v / divisor;
    bands[(block + 2) * count + i] = d / divisor;
}

kernel void waveletEnergyRows(constant WaveletParams& p [[buffer(0)]], device const float* band [[buffer(1)]],
                              device float* power [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    const int x = i % p.width, y = i / p.width, radius = p.window / 2;
    float sum = 0, correction = 0;
    for (int dx = -radius; dx <= radius; ++dx) {
        const float value = band[y * p.width + reflectIndex(x + dx, p.width, true)];
        const float delta = value * value - correction, next = sum + delta;
        correction = (next - sum) - delta; sum = next;
    }
    power[i] = sum / float(p.window);
}

kernel void waveletThreshold(constant WaveletParams& p [[buffer(0)]], device float* band [[buffer(1)]],
                             device const float* power [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    const int x = i % p.width, y = i / p.width, radius = p.window / 2;
    float sum = 0, correction = 0;
    for (int dy = -radius; dy <= radius; ++dy) {
        const float delta = power[reflectIndex(y + dy, p.height, true) * p.width + x] - correction;
        const float next = sum + delta; correction = (next - sum) - delta; sum = next;
    }
    const float variance = p.sigma * p.sigma;
    const float threshold = p.strength * variance / sqrt(max(sum / float(p.window) - variance, .05f * variance));
    band[i] = copysign(max(abs(band[i]) - threshold, 0.f), band[i]) * float(1u << p.level);
}

kernel void iswtColumns(constant WaveletParams& p [[buffer(0)]], device const float* bands [[buffer(1)]],
                        device float* low [[buffer(2)]], device float* high [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    const uint count = p.width * p.height;
    if (i >= count) return;
    const int x = i % p.width, y = i / p.width;
    const uint block = 1 + (p.depth - p.level) * 3;
    float a = 0, b = 0;
    for (int t = 0; t < 4; ++t) {
        const uint source = periodicIndex(y + int(p.step) * (t - 2), p.height) * p.width + x;
        a += .5f * db2Low[t] * bands[source] + .5f * db2High[t] * bands[block * count + source];
        b += .5f * db2Low[t] * bands[(block + 1) * count + source] + .5f * db2High[t] * bands[(block + 2) * count + source];
    }
    low[i] = a; high[i] = b;
}

kernel void iswtRows(constant WaveletParams& p [[buffer(0)]], device const float* low [[buffer(1)]],
                     device const float* high [[buffer(2)]], device float* output [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    const int x = i % p.width, y = i / p.width;
    float value = 0;
    for (int t = 0; t < 4; ++t) {
        const uint source = y * p.width + periodicIndex(x + int(p.step) * (t - 2), p.width);
        value += .5f * db2Low[t] * low[source] + .5f * db2High[t] * high[source];
    }
    output[i] = value;
}

struct GuidedParams { uint width, height, channels, radius; float epsilon; };

kernel void guideProducts(constant GuidedParams& p [[buffer(0)]], device const packed_float3* guide [[buffer(1)]],
                          device const packed_float2* input [[buffer(2)]], device float* moments [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    const float3 g = float3(guide[i]); const float2 s = float2(input[i]);
    device float* m = moments + i * 17;
    m[0] = g.x; m[1] = g.y; m[2] = g.z;
    m[3] = g.x * g.x; m[4] = g.x * g.y; m[5] = g.x * g.z;
    m[6] = g.y * g.y; m[7] = g.y * g.z; m[8] = g.z * g.z;
    m[9] = s.x; m[10] = s.y;
    for (int c = 0; c < 3; ++c) { m[11 + c] = g[c] * s.x; m[14 + c] = g[c] * s.y; }
}

kernel void guideMeanRows(constant GuidedParams& p [[buffer(0)]], device const float* input [[buffer(1)]],
                          device float* output [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height * p.channels) return;
    const uint pixel = i / p.channels, c = i % p.channels;
    const int x = pixel % p.width, y = pixel / p.width;
    float sum = 0, correction = 0;
    for (int dx = -int(p.radius); dx <= int(p.radius); ++dx) {
        const float delta = input[(y * p.width + reflectIndex(x + dx, p.width, false)) * p.channels + c] - correction;
        const float next = sum + delta; correction = (next - sum) - delta; sum = next;
    }
    output[i] = sum / float(2 * p.radius + 1);
}

kernel void guideMeanColumns(constant GuidedParams& p [[buffer(0)]], device const float* input [[buffer(1)]],
                             device float* output [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height * p.channels) return;
    const uint pixel = i / p.channels, c = i % p.channels;
    const int x = pixel % p.width, y = pixel / p.width;
    float sum = 0, correction = 0;
    for (int dy = -int(p.radius); dy <= int(p.radius); ++dy) {
        const float delta = input[(reflectIndex(y + dy, p.height, false) * p.width + x) * p.channels + c] - correction;
        const float next = sum + delta; correction = (next - sum) - delta; sum = next;
    }
    output[i] = sum / float(2 * p.radius + 1);
}

kernel void guideCoefficients(constant GuidedParams& p [[buffer(0)]], device const float* moments [[buffer(1)]],
                              device float* coefficients [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    device const float* m = moments + i * 17;
    device float* result = coefficients + i * 8;
    const float a = m[3] - m[0] * m[0] + p.epsilon, b = m[4] - m[0] * m[1];
    const float c = m[5] - m[0] * m[2], d = m[6] - m[1] * m[1] + p.epsilon;
    const float e = m[7] - m[1] * m[2], f = m[8] - m[2] * m[2] + p.epsilon;
    const float aa = d * f - e * e, ab = c * e - b * f, ac = b * e - c * d;
    const float dd = a * f - c * c, de = b * c - a * e, ff = a * d - b * b;
    const float determinant = a * aa + b * ab + c * ac;
    const float3 g = float3(m[0], m[1], m[2]);
    for (int channel = 0; channel < 2; ++channel) {
        const int offset = 11 + channel * 3;
        const float3 covariance = float3(m[offset], m[offset + 1], m[offset + 2]) - g * m[9 + channel];
        const float3 alpha = float3(aa * covariance.x + ab * covariance.y + ac * covariance.z,
            ab * covariance.x + dd * covariance.y + de * covariance.z,
            ac * covariance.x + de * covariance.y + ff * covariance.z) / determinant;
        for (int k = 0; k < 3; ++k) result[channel * 4 + k] = alpha[k];
        result[channel * 4 + 3] = m[9 + channel] - (alpha.x * g.x + alpha.y * g.y + alpha.z * g.z);
    }
}

kernel void guideReconstruct(constant GuidedParams& p [[buffer(0)]], device const packed_float3* guide [[buffer(1)]],
                             device const float* coefficients [[buffer(2)]], device packed_float2* output [[buffer(3)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    const float3 g = float3(guide[i]);
    device const float* a = coefficients + i * 8;
    output[i] = packed_float2(a[0] * g.x + a[1] * g.y + a[2] * g.z + a[3],
                              a[4] * g.x + a[5] * g.y + a[6] * g.z + a[7]);
}
)metal";
