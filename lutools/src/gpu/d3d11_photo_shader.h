#pragma once
#include "photo_log_shader.h"
#include "photo_tone_shader.h"
#include "photo_color_grading_shader.h"
#include "photo_tone_curve_shader.h"
namespace sony2fuji {
inline const std::string kD3DPhotoShader = toneControlsShader("float3") + colorGradingShader("float3") + kToneCurveShader + photoLogShader(ShaderDialect::Hlsl) + R"hlsl(
cbuffer Params : register(b0) {
    uint4 dimensions; // source width/height, destination width/height
    uint4 control; // stage, HSL active, use LUT, LUT size
    float4 toSrgb[3];
    float4 toFilm[3];
    float4 exposureStrength;
    float4 tone; // contrast, saturation, highlights, shadows
    float4 detail; // legacy curve, noise, sharpening, custom interval count
    float4 domainLow;
    float4 domainHigh;
    uint4 logTransfer; // input is F-Log, output is Log, output is F-Log, input is sRGB
    float4 hslHue[2], hslSaturation[2], hslLightness[2];
    float4 toneControls;
    float4 colorGrading[3];
    float4 curveRanges[32], curveTangents[32];
    uint4 band; // source row, destination row, output rows, reserved
    uint4 basicV3; // basicV3, basicToneActive, fieldWidth, fieldHeight
    float4 basicTone; // highlights, shadows, reserved, reserved
};
StructuredBuffer<float3> source : register(t0);
StructuredBuffer<float3> film : register(t1);
StructuredBuffer<float2> basicToneField : register(t2);
RWStructuredBuffer<float3> destination : register(u0);
float neutral(float x) {
    if (x <= 0) return 0;
    float gray=0.1845;
    float scene=1/(1+(1-gray)/gray*pow(gray/x,1.5));
    return scene<=0.0031308 ? scene*12.92 : 1.055*pow(scene,1/2.4)-0.055;
}
float3 sampleLut(uint3 p) { return film[(p.z*control.w+p.y)*control.w+p.x]; }
float3 lookup(float3 x) {
    float3 p=saturate((x-domainLow.xyz)/(domainHigh.xyz-domainLow.xyz))*(control.w-1);
    uint3 low=(uint3)floor(p),high=min(low+1,control.w-1); float3 t=p-low;
    float3 c00=lerp(sampleLut(low),sampleLut(uint3(low.xy,high.z)),t.z);
    float3 c01=lerp(sampleLut(uint3(low.x,high.y,low.z)),sampleLut(uint3(low.x,high.yz)),t.z);
    float3 c10=lerp(sampleLut(uint3(high.x,low.yz)),sampleLut(uint3(high.x,low.y,high.z)),t.z);
    float3 c11=lerp(sampleLut(uint3(high.xy,low.z)),sampleLut(high),t.z);
    return lerp(lerp(c00,c01,t.y),lerp(c10,c11,t.y),t.x);
}
float curve(float x) {
    float s=sign(detail.x)*pow(abs(detail.x),1.2);
    float3 p=saturate(float3(.25-s*.2,.5+s*.05,.75+s*.2));x=saturate(x);
    if(x<=.25)return x*4*p.x;
    if(x<=.5)return lerp(p.x,p.y,(x-.25)*4);
    if(x<=.75)return lerp(p.y,p.z,(x-.5)*4);
    return lerp(p.z,1,(x-.75)*4);
}
float customToneCurve(float x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    uint i = 0;
    while (i + 1 < uint(detail.w) && x > curveRanges[i].y) ++i;
    float4 r = curveRanges[i];
    return pchipSegment(x, r.x, r.y, r.z, r.w, curveTangents[i].x, curveTangents[i].y);
}
float3 applyHsl(float3 pixel) {
    if (control.y == 0) return pixel;
    float maximum = max(pixel.r, max(pixel.g, pixel.b));
    float minimum = min(pixel.r, min(pixel.g, pixel.b));
    float delta = maximum - minimum;
    if (delta <= 1e-6) return pixel;
    float hue = maximum == pixel.r ? 60.0 * (pixel.g - pixel.b) / delta :
        maximum == pixel.g ? 60.0 * ((pixel.b - pixel.r) / delta + 2.0) :
        60.0 * ((pixel.r - pixel.g) / delta + 4.0);
    if (hue < 0.0) hue += 360.0;
    const float centers[9] = {0,30,60,120,180,240,270,300,360};
    uint lower = 0;
    while (lower < 7 && hue >= centers[lower + 1]) ++lower;
    uint upper = (lower + 1) % 8;
    float blend = (hue - centers[lower]) / (centers[lower + 1] - centers[lower]);
    blend = blend * blend * (3.0 - 2.0 * blend);
    float dh = hslHue[lower / 4][lower % 4] * (1.0 - blend) + hslHue[upper / 4][upper % 4] * blend;
    float ds = hslSaturation[lower / 4][lower % 4] * (1.0 - blend) + hslSaturation[upper / 4][upper % 4] * blend;
    float dl = hslLightness[lower / 4][lower % 4] * (1.0 - blend) + hslLightness[upper / 4][upper % 4] * blend;
    float colorWeight = clamp(delta * 255.0, 0.0, 1.0);
    dl *= colorWeight * colorWeight * (3.0 - 2.0 * colorWeight);
    if (dh == 0.0 && ds == 0.0 && dl == 0.0) return pixel;
    float lightness = saturate((maximum + minimum) * 0.5);
    float saturation = delta / max(1e-6, 1.0 - abs(2.0 * lightness - 1.0));
    float3 residual = float3(0.0, 0.0, 0.0);
    if (minimum < 0.0 || maximum > 1.0) {
        float baseChroma = (1.0 - abs(2.0 * lightness - 1.0)) * clamp(saturation, 0.0, 1.0);
        residual = pixel - ((pixel - minimum) * (baseChroma / delta) + (lightness - baseChroma * 0.5));
    }
    hue = fmod(hue + dh * 0.3 + 360.0, 360.0);
    saturation = saturate(saturation * (1.0 + ds * 0.01));
    lightness = saturate(lightness + dl * 0.005);
    float chroma = (1.0 - abs(2.0 * lightness - 1.0)) * saturation;
    float x = chroma * (1.0 - abs(fmod(hue / 60.0, 2.0) - 1.0));
    float3 rgb = hue < 60.0 ? float3(chroma,x,0) : hue < 120.0 ? float3(x,chroma,0) :
        hue < 180.0 ? float3(0,chroma,x) : hue < 240.0 ? float3(0,x,chroma) :
        hue < 300.0 ? float3(x,0,chroma) : float3(chroma,0,x);
    return rgb + (lightness - chroma * 0.5) + residual;
}

float2 sampleBasicToneField(uint2 coord, uint2 coordSize) {
    uint fw = max(1u, basicV3.z);
    uint fh = max(1u, basicV3.w);
    float2 f = clamp((float2(coord) + 0.5) * float2(fw, fh) / float2(coordSize) - 0.5, float2(0.0, 0.0), float2(fw - 1u, fh - 1u));
    uint2 low = (uint2)floor(f);
    uint2 high = min(low + 1u, uint2(fw - 1u, fh - 1u));
    float2 t = f - float2(low);
    float2 v00 = basicToneField[low.y * fw + low.x];
    float2 v10 = basicToneField[low.y * fw + high.x];
    float2 v01 = basicToneField[high.y * fw + low.x];
    float2 v11 = basicToneField[high.y * fw + high.x];
    return lerp(lerp(v00, v10, t.x), lerp(v01, v11, t.x), t.y);
}
float3 evaluate(float3 inputColor, uint2 coord, uint2 coordSize) {
    float3 scene=float3(dot(toSrgb[0].xyz,inputColor),dot(toSrgb[1].xyz,inputColor),dot(toSrgb[2].xyz,inputColor))*exposureStrength.xyz;
    if(basicV3.y!=0) {
        float2 si=sampleBasicToneField(coord,coordSize);
        scene*=tcBasicToneV3Gain(tcLuminance(scene),si.x,si.y,basicTone.x,basicTone.y);
    }
    float3 pixel=float3(neutral(scene.r),neutral(scene.g),neutral(scene.b));
    if(control.z!=0) {
        float3 lutInput=pixel;
        if(logTransfer.w==0) {
            float3 fg=float3(dot(toFilm[0].xyz,scene),dot(toFilm[1].xyz,scene),dot(toFilm[2].xyz,scene));
            lutInput=float3(encodePhotoLog(fg.r,logTransfer.x!=0),encodePhotoLog(fg.g,logTransfer.x!=0),encodePhotoLog(fg.b,logTransfer.x!=0));
        }
        float3 look=lookup(lutInput);
        if(logTransfer.y!=0)look=float3(neutral(decodePhotoLog(look.r,logTransfer.z!=0)),neutral(decodePhotoLog(look.g,logTransfer.z!=0)),neutral(decodePhotoLog(look.b,logTransfer.z!=0)));
        pixel=lerp(pixel,look,exposureStrength.w);
    }
    pixel=basicV3.x!=0 ? tcBasicBlackWhiteV3(pixel,toneControls.x,toneControls.y)
        : tcBlackWhite(pixel,toneControls.x,toneControls.y);
    if(basicV3.x==0) {
        pixel=hsApplyHighlightsShadows(pixel,tone.z,tone.w);
    }
    if(detail.w!=0)pixel=float3(customToneCurve(pixel.r),customToneCurve(pixel.g),customToneCurve(pixel.b));
    else if(detail.x!=0)pixel=float3(curve(pixel.r),curve(pixel.g),curve(pixel.b));
    if(basicV3.x!=0 && tone.x!=1) {
        pixel=float3(tcBasicContrastV3(pixel.r,tone.x-1.0),tcBasicContrastV3(pixel.g,tone.x-1.0),tcBasicContrastV3(pixel.b,tone.x-1.0));
    }
    if((basicV3.x==0 && tone.x!=1) || tone.y!=1) {
        if(basicV3.x==0)pixel=(pixel-.5)*tone.x+.5;
        float light=dot(pixel,float3(.2126,.7152,.0722));
        pixel=light+(pixel-light)*tone.y;
    }
    float3 vibranced=basicV3.x!=0 ? tcBasicVibranceV3(pixel,toneControls.z) : tcVibrance(pixel,toneControls.z);
    return cgApply(applyHsl(vibranced),colorGrading[0].xyz,colorGrading[1].xyz,colorGrading[2].xyz);
}
float3 readPixel(uint2 p) { return source[(p.y-band.x)*dimensions.x+p.x]; }
float3 resize(uint2 xy) {
    float2 scale=float2(dimensions.z==1 ? 0 : float(dimensions.x-1)/float(dimensions.z-1),
        dimensions.w==1 ? 0 : float(dimensions.y-1)/float(dimensions.w-1));
    float2 p=min(xy*scale,float2(dimensions.xy-1));uint2 low=(uint2)floor(p),high=min(low+1,dimensions.xy-1);float2 t=p-low;
    float3 a=readPixel(low), b=readPixel(uint2(high.x,low.y)), c=readPixel(uint2(low.x,high.y)), d=readPixel(high);
    // FINAL 对显示输出缩放；PREVIEW 先缩放线性输入，保持既有处理顺序。
    if(control.x==4) { a=evaluate(a,low,dimensions.xy);b=evaluate(b,uint2(high.x,low.y),dimensions.xy);c=evaluate(c,uint2(low.x,high.y),dimensions.xy);d=evaluate(d,high,dimensions.xy); }
    return lerp(lerp(a,b,t.x),lerp(c,d,t.x),t.y);
}
[numthreads(16,16,1)]
void main(uint3 id : SV_DispatchThreadID) {
    if(id.x>=dimensions.z || id.y>=band.z)return;
    uint2 xy=uint2(id.x,id.y+band.y);
    float3 pixel;
    if(control.x==0)pixel=evaluate(all(dimensions.xy==dimensions.zw) ? readPixel(xy) : resize(xy), xy, dimensions.zw);
    else if(control.x==1)pixel=resize(xy);
    else if(control.x==4)pixel=all(dimensions.xy==dimensions.zw) ? evaluate(readPixel(xy), xy, dimensions.xy) : resize(xy);
    else {
        float3 sum=0; float weight=0;
        [unroll] for(int y=-1;y<=1;y++) [unroll] for(int x=-1;x<=1;x++) {
            uint2 p=(uint2)clamp(int2(xy)+int2(x,y),int2(0,0),int2(dimensions.xy)-1);
            sum+=readPixel(p);weight+=1;
        }
        pixel=readPixel(xy);float3 blurred=sum/weight;
        pixel=control.x==2 ? lerp(pixel,blurred,saturate(detail.y)*.4) : saturate(pixel+clamp(detail.z,0,2)*(pixel-blurred));
    }
    destination[id.y*dimensions.z+id.x]=pixel;
}
)hlsl";
}
