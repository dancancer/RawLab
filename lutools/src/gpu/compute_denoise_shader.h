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
        float effSize = resolveGrainSize(grain.z, firmThreshold);
        float effRough = resolveGrainRoughness(grain.w, firmThreshold);
        float scale = .7 + effSize * .055, rough = effRough * .007;
        float u = (float(x) + .5) / scale, v = (float(y) + .5) / scale;
        float fine = grainNoise(u, v, 0x243f6a88u), coarse = grainNoise(u * .47 + 17.3, v * .47 + 31.7, 0x85a308d3u);
        float noise = ((1.0 - rough) * fine + rough * coarse) / sqrt((1.0 - rough) * (1.0 - rough) + rough * rough);
        float light = effectsLuminance(pixel);
        float weight = grainToneWeight(light, direction);
        float delta = noise * grain.y * .0012 * weight;
        pixel = clamp(pixel + delta, 0.0, 1.0);
    }
    return pixel;
}
V3 imagePixel(int x, int y) {
    uint index = (uint(clamp(y, 0, int(height) - 1)) - sourceRow) * width + uint(clamp(x, 0, int(width) - 1));
    return V3(readA(index * 3u), readA(index * 3u + 1u), readA(index * 3u + 2u));
}
float foFetchProxyB1(uint baseOff, uint pW, uint pH, float fx, float fy) {
    float cx = clamp(fx, 0.0, float(pW - 1u));
    float cy = clamp(fy, 0.0, float(pH - 1u));
    int x0 = int(floor(cx)), y0 = int(floor(cy));
    int x1 = min(int(pW) - 1, x0 + 1), y1 = min(int(pH) - 1, y0 + 1);
    float tx = cx - float(x0), ty = cy - float(y0);
    float v00 = readB(baseOff + uint(y0) * pW + uint(x0));
    float v10 = readB(baseOff + uint(y0) * pW + uint(x1));
    float v01 = readB(baseOff + uint(y1) * pW + uint(x0));
    float v11 = readB(baseOff + uint(y1) * pW + uint(x1));
    return (v00 * (1.0 - tx) + v10 * tx) * (1.0 - ty) + (v01 * (1.0 - tx) + v11 * tx) * ty;
}
V3 foFetchProxyB3(uint baseOff, uint pW, uint pH, float fx, float fy) {
    float cx = clamp(fx, 0.0, float(pW - 1u));
    float cy = clamp(fy, 0.0, float(pH - 1u));
    int x0 = int(floor(cx)), y0 = int(floor(cy));
    int x1 = min(int(pW) - 1, x0 + 1), y1 = min(int(pH) - 1, y0 + 1);
    float tx = cx - float(x0), ty = cy - float(y0);
    uint i00 = baseOff + (uint(y0) * pW + uint(x0)) * 3u;
    uint i10 = baseOff + (uint(y0) * pW + uint(x1)) * 3u;
    uint i01 = baseOff + (uint(y1) * pW + uint(x0)) * 3u;
    uint i11 = baseOff + (uint(y1) * pW + uint(x1)) * 3u;
    V3 c00 = V3(readB(i00), readB(i00 + 1u), readB(i00 + 2u));
    V3 c10 = V3(readB(i10), readB(i10 + 1u), readB(i10 + 2u));
    V3 c01 = V3(readB(i01), readB(i01 + 1u), readB(i01 + 2u));
    V3 c11 = V3(readB(i11), readB(i11 + 1u), readB(i11 + 2u));
    return (c00 * (1.0 - tx) + c10 * tx) * (1.0 - ty) + (c01 * (1.0 - tx) + c11 * tx) * ty;
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
            float magnitude = max(abs(value) - threshold, 0.0);
            if (firmThreshold != 0u) magnitude = min(abs(value), 2.0 * magnitude);
            writeA(i, (value < 0.0 ? -1.0 : 1.0) * magnitude * float(1u << level));
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
    } else if (stage == 11u || stage == 12u) {
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
    } else if (stage == 13u) {
        uint px = i % step, py = i / step + outputRow;
        float fx0 = float(px) * float(width) / float(step);
        float fx1 = float(px + 1u) * float(width) / float(step);
        float fy0 = float(py) * float(height) / float(level);
        float fy1 = float(py + 1u) * float(height) / float(level);
        int ix0 = int(floor(fx0));
        if (ix0 < 0) ix0 = 0;
        int cx1 = -int(floor(-fx1));
        int ix1 = cx1 > (ix0 + 1) ? cx1 : (ix0 + 1);
        if (ix1 > int(width)) ix1 = int(width);
        int iy0 = int(floor(fy0));
        if (iy0 < 0) iy0 = 0;
        int cy1 = -int(floor(-fy1));
        int iy1 = cy1 > (iy0 + 1) ? cy1 : (iy0 + 1);
        if (iy1 > int(height)) iy1 = int(height);
        int stepX = (ix1 - ix0 + 15) / 16;
        if (stepX < 1) stepX = 1;
        int stepY = (iy1 - iy0 + 15) / 16;
        if (stepY < 1) stepY = 1;
        V3 acc = V3(0.0, 0.0, 0.0);
        float samples = 0.0;
        for (int sy = iy0; sy < iy1; sy += stepY) {
            int bandY = clamp(sy - int(sourceRow), 0, int(radius) - 1);
            uint rowBase = uint(bandY) * width;
            for (int sx = ix0; sx < ix1; sx += stepX) {
                uint idx = (rowBase + uint(sx)) * 3u;
                V3 srgbPx = V3(readA(idx), readA(idx + 1u), readA(idx + 2u));
                V3 lin = foSrgbToLin3(srgbPx);
                float lum = foLuminance3(lin);
                if (channels == 1u) {
                    float ex = foHighlightExcess(lum, epsilon);
                    float ratio = lum > 1e-6 ? (ex / lum) : 0.0;
                    acc += lin * ratio;
                } else {
                    float maxCh = max(lin.x, max(lin.y, lin.z));
                    float sig = max(lum, maxCh * 0.55);
                    acc.x += foHighlightExcess(sig, epsilon);
                }
                samples += 1.0;
            }
        }
        float inv = samples > 0.0 ? (1.0 / samples) : 0.0;
        if (channels == 1u) {
            writeA(i * 3u, acc.x * inv);
            writeA(i * 3u + 1u, acc.y * inv);
            writeA(i * 3u + 2u, acc.z * inv);
        } else {
            writeA(i, acc.x * inv);
        }
    } else if (stage == 14u || stage == 15u) {
        int rad = int(radius);
        float invTwoSigSq = 0.5 / max(sigma * sigma, 0.01);
        if (channels == 3u) {
            V3 acc = V3(0.0, 0.0, 0.0);
            float wSum = 0.0;
            for (int d = -rad; d <= rad; ++d) {
                int sx = stage == 14u ? clamp(x + d, 0, int(width) - 1) : x;
                int sy = stage == 15u ? clamp(y + d, 0, int(height) - 1) : y;
                float w = exp(-float(d * d) * invTwoSigSq);
                uint idx = (uint(sy) * width + uint(sx)) * 3u;
                acc += V3(readA(idx), readA(idx + 1u), readA(idx + 2u)) * w;
                wSum += w;
            }
            V3 val = acc / max(wSum, 1e-6);
            uint outIdx = i * 3u;
            if (stage == 15u && direction != 0u) {
                V3 coreVal = V3(readB(outIdx), readB(outIdx + 1u), readB(outIdx + 2u));
                val = coreVal * strength + val * epsilon;
            }
            writeA(outIdx, val.x); writeA(outIdx + 1u, val.y); writeA(outIdx + 2u, val.z);
        } else {
            float acc = 0.0, wSum = 0.0;
            for (int d = -rad; d <= rad; ++d) {
                int sx = stage == 14u ? clamp(x + d, 0, int(width) - 1) : x;
                int sy = stage == 15u ? clamp(y + d, 0, int(height) - 1) : y;
                float w = exp(-float(d * d) * invTwoSigSq);
                acc += readA(uint(sy) * width + uint(sx)) * w;
                wSum += w;
            }
            float val = acc / max(wSum, 1e-6);
            if (stage == 15u && direction != 0u) {
                val = readB(i) * strength + val * epsilon;
            }
            writeA(i, val);
        }
    } else if (stage == 16u) {
        y += int(outputRow);
        V3 pixel = imagePixel(x, y);
        float halGlow = 0.0;
        if (vignette.y > 0.5 && step > 0u && level > 0u) {
            float hx = (float(x) + 0.5) * (float(step) / float(width)) - 0.5;
            float hy = (float(y) + 0.5) * (float(level) / float(height)) - 0.5;
            halGlow = foFetchProxyB1(0u, step, level, hx, hy);
        }
        V3 bloomGlow = V3(0.0, 0.0, 0.0);
        if (vignette.z > 0.5 && direction > 0u && firmThreshold > 0u) {
            float bx = (float(x) + 0.5) * (float(direction) / float(width)) - 0.5;
            float by = (float(y) + 0.5) * (float(firmThreshold) / float(height)) - 0.5;
            bloomGlow = foFetchProxyB3(channels, direction, firmThreshold, bx, by);
        }
        V3 blended = foApplyOpticsBlend(pixel, halGlow, bloomGlow, strength, epsilon, vignette.x);
        writeA(i * 3u, blended.x); writeA(i * 3u + 1u, blended.y); writeA(i * 3u + 2u, blended.z);
    }
}
)shader";
