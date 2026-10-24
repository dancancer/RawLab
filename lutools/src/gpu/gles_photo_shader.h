#pragma once
#include "photo_tone_shader.h"
#include "photo_color_grading_shader.h"
#include "photo_tone_curve_shader.h"

namespace sony2fuji {
inline const std::string kPhotoComputeShader = std::string(R"glsl(#version 310 es
precision highp float;
precision highp int;
)glsl") + toneControlsShader("vec3") + colorGradingShader("vec3") + kToneCurveShader + R"glsl(
layout(local_size_x = 128) in;
layout(std430, binding = 0) readonly buffer Source { float src[]; };
layout(std430, binding = 1) writeonly buffer Destination { float dst[]; };
layout(binding = 0) uniform highp sampler3D film;
uniform uvec2 sourceSize;
uniform uvec2 destinationSize;
uniform uint sourceStartRow;
uniform uint destinationStartRow;
uniform uint pixelCount;
uniform uint outputOffset;
uniform int stage;
uniform bool useLut;
uniform bool inputIsFLog;
uniform bool outputIsLog;
uniform bool outputIsFLog;
uniform int lutSize;
uniform mat3 toSrgb;
uniform mat3 toFGamut;
uniform vec3 exposureWB;
uniform float strength;
uniform vec3 domainMin;
uniform vec3 domainMax;
uniform vec4 tone; // contrast, saturation, highlights, shadows
uniform float curve;
uniform int customCurveCount;
uniform vec4 curveRanges[32], curveTangents[32];
uniform bool hslActive;
uniform vec3 toneControls;
uniform vec3 colorGrading[3];
uniform vec4 hslHue[2];
uniform vec4 hslSaturation[2];
uniform vec4 hslLightness[2];

vec3 readPixel(uvec2 xy) {
    uint i = ((xy.y - sourceStartRow) * sourceSize.x + xy.x) * 3u;
    return vec3(src[i], src[i + 1u], src[i + 2u]);
}
float neutral(float x) {
    if (x <= 0.0) return 0.0;
    const float gray = 0.1845;
    float linear = 1.0 / (1.0 + (1.0 - gray) / gray * pow(gray / x, 1.5));
    return linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
}
float flog2(float x) {
    return clamp(x < 0.00088899597 ? 8.799461 * x + 0.092864 :
        log(x * 5.555556 + 0.064829) / log(10.0) * 0.245281 + 0.384316, 0.0, 1.0);
}
float encodeLog(float x) {
    if (!inputIsFLog) return flog2(x);
    return clamp(x < 0.00089 ? 8.735631 * x + 0.092864 :
        0.344676 * log(0.555556 * x + 0.009468) / log(10.0) + 0.790453, 0.0, 1.0);
}
float decodeLog(float x) {
    if (outputIsFLog) return x < 0.100537775223865 ? (x - 0.092864) / 8.735631 :
        (pow(10.0, (x - 0.790453) / 0.344676) - 0.009468) / 0.555556;
    return x < 0.100686685370811 ? (x - 0.092864) / 8.799461 :
        (pow(10.0, (x - 0.384316) / 0.245281) - 0.064829) / 5.555556;
}
vec3 lookup(vec3 x) {
    vec3 p = clamp((x - domainMin) / (domainMax - domainMin), 0.0, 1.0) * float(lutSize - 1);
    ivec3 low = ivec3(floor(p));
    ivec3 high = min(low + 1, ivec3(lutSize - 1));
    vec3 t = p - vec3(low);
    vec3 c00 = mix(texelFetch(film, low, 0).rgb,
        texelFetch(film, ivec3(low.xy, high.z), 0).rgb, t.z);
    vec3 c01 = mix(texelFetch(film, ivec3(low.x, high.y, low.z), 0).rgb,
        texelFetch(film, ivec3(low.x, high.yz), 0).rgb, t.z);
    vec3 c10 = mix(texelFetch(film, ivec3(high.x, low.yz), 0).rgb,
        texelFetch(film, ivec3(high.x, low.y, high.z), 0).rgb, t.z);
    vec3 c11 = mix(texelFetch(film, ivec3(high.xy, low.z), 0).rgb,
        texelFetch(film, high, 0).rgb, t.z);
    return mix(mix(c00, c01, t.y), mix(c10, c11, t.y), t.x);
}
float toneCurve(float x) {
    float s = sign(curve) * pow(abs(curve), 1.2);
    vec3 points = clamp(vec3(0.25 - s * 0.2, 0.5 + s * 0.05, 0.75 + s * 0.2), 0.0, 1.0);
    x = clamp(x, 0.0, 1.0);
    if (x <= 0.25) return x * 4.0 * points.x;
    if (x <= 0.5) return mix(points.x, points.y, (x - 0.25) * 4.0);
    if (x <= 0.75) return mix(points.y, points.z, (x - 0.5) * 4.0);
    return mix(points.z, 1.0, (x - 0.75) * 4.0);
}
float customToneCurve(float x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    int i = 0;
    while (i + 1 < customCurveCount && x > curveRanges[i].y) ++i;
    vec4 r = curveRanges[i];
    return pchipSegment(x, r.x, r.y, r.z, r.w, curveTangents[i].x, curveTangents[i].y);
}
vec3 applyHsl(vec3 pixel) {
    if (!hslActive) return pixel;
    float maximum = max(pixel.r, max(pixel.g, pixel.b));
    float minimum = min(pixel.r, min(pixel.g, pixel.b));
    float delta = maximum - minimum;
    if (delta <= 1e-6) return pixel;
    float hue = maximum == pixel.r ? 60.0 * (pixel.g - pixel.b) / delta :
        maximum == pixel.g ? 60.0 * ((pixel.b - pixel.r) / delta + 2.0) :
        60.0 * ((pixel.r - pixel.g) / delta + 4.0);
    if (hue < 0.0) hue += 360.0;
    const float centers[9] = float[9](0.0,30.0,60.0,120.0,180.0,240.0,270.0,300.0,360.0);
    int lower = 0;
    while (lower < 7 && hue >= centers[lower + 1]) ++lower;
    int upper = (lower + 1) % 8;
    float blend = (hue - centers[lower]) / (centers[lower + 1] - centers[lower]);
    blend = blend * blend * (3.0 - 2.0 * blend);
    float dh = hslHue[lower / 4][lower % 4] * (1.0 - blend) + hslHue[upper / 4][upper % 4] * blend;
    float ds = hslSaturation[lower / 4][lower % 4] * (1.0 - blend) + hslSaturation[upper / 4][upper % 4] * blend;
    float dl = hslLightness[lower / 4][lower % 4] * (1.0 - blend) + hslLightness[upper / 4][upper % 4] * blend;
    float colorWeight = clamp(delta * 255.0, 0.0, 1.0);
    dl *= colorWeight * colorWeight * (3.0 - 2.0 * colorWeight);
    if (dh == 0.0 && ds == 0.0 && dl == 0.0) return pixel;
    float lightness = clamp((maximum + minimum) * 0.5, 0.0, 1.0);
    float saturation = delta / max(1e-6, 1.0 - abs(2.0 * lightness - 1.0));
    vec3 residual = vec3(0.0);
    if (minimum < 0.0 || maximum > 1.0) {
        float baseChroma = (1.0 - abs(2.0 * lightness - 1.0)) * clamp(saturation, 0.0, 1.0);
        residual = pixel - ((pixel - minimum) * (baseChroma / delta) + (lightness - baseChroma * 0.5));
    }
    hue = mod(hue + dh * 0.3 + 360.0, 360.0);
    saturation = clamp(saturation * (1.0 + ds * 0.01), 0.0, 1.0);
    lightness = clamp(lightness + dl * 0.005, 0.0, 1.0);
    float chroma = (1.0 - abs(2.0 * lightness - 1.0)) * saturation;
    float x = chroma * (1.0 - abs(mod(hue / 60.0, 2.0) - 1.0));
    vec3 rgb = hue < 60.0 ? vec3(chroma,x,0) : hue < 120.0 ? vec3(x,chroma,0) :
        hue < 180.0 ? vec3(0,chroma,x) : hue < 240.0 ? vec3(0,x,chroma) :
        hue < 300.0 ? vec3(x,0,chroma) : vec3(chroma,0,x);
    return rgb + (lightness - chroma * 0.5) + residual;
}

vec3 evaluate(vec3 inputColor) {
    vec3 linear = (toSrgb * inputColor) * exposureWB;
    vec3 pixel = vec3(neutral(linear.r), neutral(linear.g), neutral(linear.b));
    if (useLut) {
        vec3 fgamut = toFGamut * linear;
        vec3 look = lookup(vec3(encodeLog(fgamut.r), encodeLog(fgamut.g), encodeLog(fgamut.b)));
        if (outputIsLog) look = vec3(neutral(decodeLog(look.r)), neutral(decodeLog(look.g)), neutral(decodeLog(look.b)));
        pixel = mix(pixel, look, strength);
    }
    pixel = tcBlackWhite(pixel, toneControls.x, toneControls.y);
    if (tone.z != 0.0 || tone.w != 0.0) {
        float luminance = dot(pixel, vec3(0.2126, 0.7152, 0.0722));
        float adjusted = luminance;
        if (tone.w != 0.0) adjusted = pow(clamp(adjusted, 0.0, 1.0), 1.0 - tone.w * 0.5);
        if (tone.z != 0.0) adjusted = 1.0 - pow(1.0 - clamp(adjusted, 0.0, 1.0), 1.0 - tone.z * 0.5);
        pixel = luminance > 0.0 ? pixel * (adjusted / luminance) : vec3(adjusted);
    }
    if (customCurveCount != 0) pixel = vec3(customToneCurve(pixel.r), customToneCurve(pixel.g), customToneCurve(pixel.b));
    else if (curve != 0.0) pixel = vec3(toneCurve(pixel.r), toneCurve(pixel.g), toneCurve(pixel.b));
    if (tone.x != 1.0 || tone.y != 1.0) {
        pixel = (pixel - 0.5) * tone.x + 0.5;
        float luminance = dot(pixel, vec3(0.2126, 0.7152, 0.0722));
        pixel = vec3(luminance) + (pixel - luminance) * tone.y;
    }
    return cgApply(applyHsl(tcVibrance(pixel, toneControls.z)),colorGrading[0],colorGrading[1],colorGrading[2]);
}
void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= pixelCount) return;
    uvec2 xy = uvec2(i % destinationSize.x, destinationStartRow + i / destinationSize.x);
    vec3 value;
    if (stage == 1 || (stage == 2 && all(equal(sourceSize, destinationSize)))) {
        value = evaluate(readPixel(xy));
    } else {
        vec2 scale = vec2(destinationSize.x == 1u ? 0.0 : float(sourceSize.x - 1u) / float(destinationSize.x - 1u),
            destinationSize.y == 1u ? 0.0 : float(sourceSize.y - 1u) / float(destinationSize.y - 1u));
        vec2 p = min(vec2(xy) * scale, vec2(sourceSize - 1u));
        uvec2 low = uvec2(floor(p));
        uvec2 high = min(low + 1u, sourceSize - 1u);
        vec2 t = p - vec2(low);
        vec3 a = readPixel(low), b = readPixel(uvec2(high.x, low.y));
        vec3 c = readPixel(uvec2(low.x, high.y)), d = readPixel(high);
        // FINAL resizes display output; PREVIEW resizes linear input first.
        if (stage == 2) { a = evaluate(a); b = evaluate(b); c = evaluate(c); d = evaluate(d); }
        value = mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
        if (stage == 3) value = evaluate(value);
    }
    uint outIndex = (outputOffset + i) * 3u;
    dst[outIndex] = value.r; dst[outIndex + 1u] = value.g; dst[outIndex + 2u] = value.b;
}
)glsl";
}
