#pragma once

// One arithmetic body for GLSL and HLSL; adapters supply typed buffer access.
inline constexpr const char* kFilterShaderBody = R"shader(
int periodicIndex(int index, int length) {
    // GLSL ES does not define remainder for negative operands.
    return index < 0 ? length - 1 - ((-index - 1) % length) : index % length;
}
int reflectIndex(int index, int length, bool excludeEdge) {
    if (length == 1) return 0;
    int period = 2 * (length - (excludeEdge ? 1 : 0));
    index = periodicIndex(index, period);
    return index < length ? index : period - index - (excludeEdge ? 0 : 1);
}
float db2Low(int t) {
    return t == 0 ? -.12940952255126037 : t == 1 ? .22414386804201338 :
        t == 2 ? .83651630373780791 : .48296291314453414;
}
float db2High(int t) {
    return t == 0 ? -.48296291314453414 : t == 1 ? .83651630373780791 :
        t == 2 ? -.22414386804201338 : -.12940952255126037;
}
float effectSmooth(float value) {
    value = clamp(value, 0.0, 1.0);
    return value * value * (3.0 - 2.0 * value);
}
uint grainHash(uint value) {
    value ^= value >> 16; value *= 0x7feb352du;
    value ^= value >> 15; value *= 0x846ca68bu;
    return value ^ (value >> 16);
}
float grainNormal(int x, int y, uint seed) {
    uint a = grainHash(uint(x) ^ grainHash(uint(y) + seed)), b = grainHash(a ^ 0x9e3779b9u);
    return (float((a & 65535u) + (a >> 16) + (b & 65535u) + (b >> 16)) / 65535.0 - 2.0) * 1.7320508;
}
float grainNoise(float x, float y, uint seed) {
    int ix = int(floor(x)), iy = int(floor(y));
    float fx = effectSmooth(x - float(ix)), fy = effectSmooth(y - float(iy));
    float top = grainNormal(ix, iy, seed) * (1.0 - fx) + grainNormal(ix + 1, iy, seed) * fx;
    float bottom = grainNormal(ix, iy + 1, seed) * (1.0 - fx) + grainNormal(ix + 1, iy + 1, seed) * fx;
    float variance = ((1.0 - fx) * (1.0 - fx) + fx * fx) * ((1.0 - fy) * (1.0 - fy) + fy * fy);
    return (top * (1.0 - fy) + bottom * fy) / sqrt(variance);
}
float effectsLuminance(V3 pixel) { return clamp(dot(pixel, V3(.2126, .7152, .0722)), 0.0, 1.0); }
V3 photoEffects(V3 pixel, uint x, uint y) {
    if (vignette.x != 0.0) {
        float circle = max(0.0, vignette.z / 100.0), shortSide = float(min(width, height));
        float axisX = (float(width) * (1.0 - circle) + shortSide * circle) * .5;
        float axisY = (float(height) * (1.0 - circle) + shortSide * circle) * .5;
        float power = 2.0 + max(0.0, -vignette.z / 100.0) * 6.0;
        float radius = .35 + vignette.y * .01, feather = vignette.w / 100.0;
        float inner = radius * (1.0 - feather * .8), outer = radius + feather * .4;
        float nx = abs((float(x) + .5 - float(width) * .5) / axisX);
        float ny = abs((float(y) + .5 - float(height) * .5) / axisY);
        float distance = power == 2.0 ? sqrt(nx * nx + ny * ny) : pow(pow(nx, power) + pow(ny, power), 1.0 / power);
        float mask = effectSmooth((distance - inner) / max(outer - inner, 2.0 / shortSide));
        if (vignette.x < 0.0) mask *= 1.0 - grain.x / 100.0 * effectSmooth((effectsLuminance(pixel) - .5) * 2.0);
        float gain = exp2(-abs(vignette.x) * .03 * mask);
        pixel = vignette.x < 0.0 ? pixel * gain : 1.0 - (1.0 - pixel) * gain;
    }
    if (grain.y > 0.0) {
        float scale = .7 + grain.z * .055, rough = grain.w * .007;
        float u = (float(x) + .5) / scale, v = (float(y) + .5) / scale;
        float fine = grainNoise(u, v, 0x243f6a88u), coarse = grainNoise(u * .47 + 17.3, v * .47 + 31.7, 0x85a308d3u);
        float noise = ((1.0 - rough) * fine + rough * coarse) / sqrt((1.0 - rough) * (1.0 - rough) + rough * rough);
        float light = effectsLuminance(pixel);
        float delta = noise * grain.y * .0012 * sqrt(4.0 * light * (1.0 - light));
        pixel = clamp(pixel + delta, 0.0, 1.0);
    }
    return pixel;
}
V3 imagePixel(int x, int y) {
    uint index = (uint(clamp(y, 0, int(height) - 1)) - sourceRow) * width + uint(clamp(x, 0, int(width) - 1));
    return V3(readA(index * 3u), readA(index * 3u + 1u), readA(index * 3u + 2u));
}
void filterPixel(uint i) {
    if (i >= count) return;
    int x = int(i % width), y = int(i / width);
    if (stage == 0u) {
        float a = 0.0, d = 0.0;
        for (int t = 0; t < 4; ++t) {
            float value = readA(uint(y) * width + uint(periodicIndex(x + int(step) * (2 - t), int(width))));
            a += db2Low(t) * value; d += db2High(t) * value;
        }
        writeA(i, a); writeB(i, d);
    } else if (stage == 1u) {
        float value = 0.0;
        for (int t = 0; t < 4; ++t) {
            float coefficient = direction == 1u || direction == 3u ? db2High(t) : db2Low(t);
            value += coefficient * readA(uint(periodicIndex(y + int(step) * (2 - t), int(height))) * width + uint(x));
        }
        writeA(i, direction == 0u ? value : value / float(1u << level));
    } else if (stage == 2u || stage == 3u) {
        float sum = 0.0, correction = 0.0;
        for (int offset = -int(radius); offset <= int(radius); ++offset) {
            float value = stage == 2u ? readA(uint(y) * width + uint(reflectIndex(x + offset, int(width), true))) :
                readB(uint(reflectIndex(y + offset, int(height), true)) * width + uint(x));
            float delta = (stage == 2u ? value * value : value) - correction;
            float next = sum + delta; correction = (next - sum) - delta; sum = next;
        }
        float energy = sum / float(2u * radius + 1u);
        if (stage == 2u) writeA(i, energy);
        else {
            float variance = sigma * sigma, value = readA(i);
            float threshold = strength * variance / sqrt(max(energy - variance, .05 * variance));
            writeA(i, (value < 0.0 ? -1.0 : 1.0) * max(abs(value) - threshold, 0.0) * float(1u << level));
        }
    } else if (stage == 4u || stage == 5u) {
        float value = 0.0;
        for (int t = 0; t < 4; ++t) {
            uint index = stage == 4u ? uint(periodicIndex(y + int(step) * (t - 2), int(height))) * width + uint(x) :
                uint(y) * width + uint(periodicIndex(x + int(step) * (t - 2), int(width)));
            value += .5 * db2Low(t) * readA(index) + .5 * db2High(t) * readB(index);
        }
        writeA(i, value);
    } else if (stage == 6u) {
        V3 g = V3(readA(i * 3u), readA(i * 3u + 1u), readA(i * 3u + 2u));
        float a = readB(i * 2u), b = readB(i * 2u + 1u);
        uint m = i * 17u;
        writeA(m, g.x); writeA(m + 1u, g.y); writeA(m + 2u, g.z);
        writeA(m + 3u, g.x * g.x); writeA(m + 4u, g.x * g.y); writeA(m + 5u, g.x * g.z);
        writeA(m + 6u, g.y * g.y); writeA(m + 7u, g.y * g.z); writeA(m + 8u, g.z * g.z);
        writeA(m + 9u, a); writeA(m + 10u, b);
        for (uint c = 0u; c < 3u; ++c) { writeA(m + 11u + c, g[c] * a); writeA(m + 14u + c, g[c] * b); }
    } else if (stage == 7u || stage == 8u) {
        uint pixel = i / channels, channel = i % channels;
        x = int(pixel % width); y = int(pixel / width);
        float sum = 0.0, correction = 0.0;
        for (int offset = -int(radius); offset <= int(radius); ++offset) {
            uint index = stage == 7u ? uint(y) * width + uint(reflectIndex(x + offset, int(width), false)) :
                uint(reflectIndex(y + offset, int(height), false)) * width + uint(x);
            float delta = readA(index * channels + channel) - correction;
            float next = sum + delta; correction = (next - sum) - delta; sum = next;
        }
        writeA(i, sum / float(2u * radius + 1u));
    } else if (stage == 9u) {
        uint m = i * 17u;
        V3 g = V3(readA(m), readA(m + 1u), readA(m + 2u));
        float a = readA(m + 3u) - g.x * g.x + epsilon, b = readA(m + 4u) - g.x * g.y;
        float c = readA(m + 5u) - g.x * g.z, d = readA(m + 6u) - g.y * g.y + epsilon;
        float e = readA(m + 7u) - g.y * g.z, f = readA(m + 8u) - g.z * g.z + epsilon;
        float aa = d * f - e * e, ab = c * e - b * f, ac = b * e - c * d;
        float dd = a * f - c * c, de = b * c - a * e, ff = a * d - b * b;
        float determinant = a * aa + b * ab + c * ac;
        for (uint channel = 0u; channel < 2u; ++channel) {
            uint offset = m + 11u + channel * 3u;
            float mean = readA(m + 9u + channel);
            V3 covariance = V3(readA(offset), readA(offset + 1u), readA(offset + 2u)) - g * mean;
            V3 alpha = V3(aa * covariance.x + ab * covariance.y + ac * covariance.z,
                ab * covariance.x + dd * covariance.y + de * covariance.z,
                ac * covariance.x + de * covariance.y + ff * covariance.z) / determinant;
            uint outIndex = i * 8u + channel * 4u;
            for (uint k = 0u; k < 3u; ++k) writeA(outIndex + k, alpha[k]);
            writeA(outIndex + 3u, mean - (alpha.x * g.x + alpha.y * g.y + alpha.z * g.z));
        }
    } else if (stage == 10u) {
        V3 g = V3(readA(i * 3u), readA(i * 3u + 1u), readA(i * 3u + 2u));
        for (uint channel = 0u; channel < 2u; ++channel) {
            uint a = i * 8u + channel * 4u;
            writeA(i * 2u + channel, readB(a) * g.x + readB(a + 1u) * g.y + readB(a + 2u) * g.z + readB(a + 3u));
        }
    } else {
        y += int(outputRow);
        V3 pixel = imagePixel(x, y);
        if (stage == 11u) pixel = photoEffects(pixel, uint(x), uint(y));
        else {
            V3 sum = V3(0.0, 0.0, 0.0);
            for (int dy = -1; dy <= 1; ++dy) {
                V3 row = imagePixel(x - 1, y + dy) + imagePixel(x, y + dy) + imagePixel(x + 1, y + dy);
                sum += row;
            }
            V3 blurred = sum / 9.0;
            pixel = direction == 0u ? pixel + (blurred - pixel) * (strength * .4) :
                clamp(pixel + strength * (pixel - blurred), 0.0, 1.0);
        }
        writeA(i * 3u, pixel.x); writeA(i * 3u + 1u, pixel.y); writeA(i * 3u + 2u, pixel.z);
    }
}
)shader";
