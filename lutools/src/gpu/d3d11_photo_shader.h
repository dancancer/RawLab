#pragma once
#include "dcp_look_shader.h"
#include "photo_log_shader.h"
#include "photo_spatial_shader.h"
#include "photo_tone_shader.h"
#include "photo_color_grading_shader.h"
#include "photo_tone_curve_shader.h"
#include "photo_color_science_shader.h"
namespace sony2fuji {
inline const std::string kD3DPhotoShader = toneControlsShader("float3") + colorGradingShader("float3") + toneCurveShader("float3") + photoLogShader(ShaderDialect::Hlsl) + colorScienceShader(ShaderDialect::Hlsl) + R"hlsl(
cbuffer Params : register(b0) {
    uint4 dimensions; // source width/height, destination width/height
    uint4 control; // stage, HSL active, use LUT/DCP (0=none, 1=LUT, 2=DCP), LUT size
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
    float4 curveRanges[128], curveTangents[128];
    uint4 curveCounts; // master, R, G, B
    uint4 curveFlags;  // applyToLuminosity, parametricActive, 0, 0
    float4 parametricAmps;
    float4 parametricSplits;
    float4 colorGradingGlobal;
    float4 colorGradingMix;
    uint4 band; // source row, destination row, output rows, evalPhase
    uint4 basicV3; // basicV3, basicToneActive, fieldWidth, fieldHeight
    float4 basicTone; // highlights, shadows, reserved, reserved
};
cbuffer DcpParamsBuffer : register(b1) {
    float4 dcpInput[3];
    float4 dcpOutput[3];
    float4 dcpExposure;
    uint4 dcpCalib;
    uint4 dcpLook;
    uint4 dcpOffsets;
};
StructuredBuffer<float3> source : register(t0);
StructuredBuffer<float3> film : register(t1);
StructuredBuffer<float2> basicToneField : register(t2);
StructuredBuffer<float> dcpData : register(t3);
RWStructuredBuffer<float3> destination : register(u0);
RWStructuredBuffer<uint> dcpInvalid : register(u1);
float neutral(float x) {
    if (x <= 0) return 0;
    float gray=0.1845;
    float scene=1/(1+(1-gray)/gray*pow(gray/x,1.5));
    return scene<=0.0031308 ? scene*12.92 : 1.055*pow(scene,1/2.4)-0.055;
}
float dcpSrgbGamma(float x) {
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
}
#define DCP_FN
#define DCP_V3 float3
#define DCP_V3C(x, y, z) float3((x), (y), (z))
#define DCP_U3 uint3
#define DCP_U3C(x, y, z) uint3((x), (y), (z))
#define DCP_U4 uint4
#define DCP_CTX_DECL
#define DCP_CTX_ARG
#define DCP_SRGB_GAMMA(x) dcpSrgbGamma(x)
#define DCP_NEUTRAL(x) neutral(x)
#define DCP_LERP3(a, b, t) lerp((a), (b), (t))
#define DCP_FINITE(v) all(isfinite(v))
#define DCP_DATA(idx) dcpData[(idx)]
#define DCP_MARK_INVALID InterlockedOr(dcpInvalid[0], 1u)
)hlsl" + dcpLookShaderBody() + R"hlsl(
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
float customToneCurve(float x, uint count, uint base) {
    if (count == 0u) return x;
    if (x <= curveRanges[base].x) return curveRanges[base].z;
    if (x >= curveRanges[base + count - 1u].y) return curveRanges[base + count - 1u].w;
    uint i = 0u;
    while (i + 1u < count && x > curveRanges[base + i].y) ++i;
    float4 r = curveRanges[base + i];
    float4 t = curveTangents[base + i];
    return pchipSegment(x, r.x, r.y, r.z, r.w, t.x, t.y);
}
float evalMasterTone(float x) {
    if (curveFlags.y != 0u) {
        x = tcParametric(x, parametricAmps.x, parametricAmps.y, parametricAmps.z, parametricAmps.w,
            parametricSplits.x, parametricSplits.y, parametricSplits.z);
    }
    if (curveCounts.x != 0u) return customToneCurve(x, curveCounts.x, 0u);
    if (detail.x != 0.0) return curve(x);
    return x;
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
    uint evalPhase = band.w;
    float3 pixel = inputColor;
    if (evalPhase != 2u && evalPhase != 3u) {
        float3 scene=csApplyCalibration(float3(dot(toSrgb[0].xyz,inputColor),dot(toSrgb[1].xyz,inputColor),dot(toSrgb[2].xyz,inputColor))*exposureStrength.xyz);
        if(basicV3.y!=0) {
            float2 si=sampleBasicToneField(coord,coordSize);
            scene*=tcBasicToneV3Gain(tcLuminance(scene),si.x,si.y,basicTone.x,basicTone.y);
        }
        if (evalPhase == 1u) return scene;
        inputColor = scene;
    }
    if (evalPhase != 3u) {
        float3 scene = inputColor;
        if (control.z == 2u) {
            pixel = dcpApplyLookPixel(
                scene,
                dcpInput[0].xyz, dcpInput[1].xyz, dcpInput[2].xyz,
                dcpOutput[0].xyz, dcpOutput[1].xyz, dcpOutput[2].xyz,
                dcpExposure.x,
                dcpCalib, dcpLook, dcpOffsets.x, dcpOffsets.y, exposureStrength.w);
        } else {
            pixel=float3(neutral(scene.r),neutral(scene.g),neutral(scene.b));
            if(control.z == 1u) {
                float3 lutInput=pixel;
                if(logTransfer.w==0) {
                    float3 fg=float3(dot(toFilm[0].xyz,scene),dot(toFilm[1].xyz,scene),dot(toFilm[2].xyz,scene));
                    lutInput=float3(encodePhotoLog(fg.r,logTransfer.x!=0),encodePhotoLog(fg.g,logTransfer.x!=0),encodePhotoLog(fg.b,logTransfer.x!=0));
                }
                float3 look=lookup(lutInput);
                if(logTransfer.y!=0)look=float3(neutral(decodePhotoLog(look.r,logTransfer.z!=0)),neutral(decodePhotoLog(look.g,logTransfer.z!=0)),neutral(decodePhotoLog(look.b,logTransfer.z!=0)));
                pixel=lerp(pixel,look,exposureStrength.w);
            }
        }
        if (evalPhase == 2u || evalPhase == 4u) return pixel;
    }
    pixel=csApplyBwMixer(pixel);
    pixel=basicV3.x!=0 ? tcBasicBlackWhiteV3(pixel,toneControls.x,toneControls.y)
        : tcBlackWhite(pixel,toneControls.x,toneControls.y);
    if(basicV3.x==0) {
        pixel=hsApplyHighlightsShadows(pixel,tone.z,tone.w);
    }
    bool masterActive=curveFlags.y!=0u || curveCounts.x!=0u || detail.x!=0.0;
    if(masterActive) {
        if(curveFlags.x!=0u) {
            float3 pL=float3(tcSrgbToLinear(pixel.r),tcSrgbToLinear(pixel.g),tcSrgbToLinear(pixel.b));
            float Y=tcLuminosityLinearY(pL);
            float u=tcLinearToSrgb(max(0.0,Y));
            float uPrime=evalMasterTone(u);
            float Y0=tcSrgbToLinear(evalMasterTone(0.0));
            pixel=tcLuminosityFinish(pL,Y,uPrime,Y0);
        } else {
            pixel=float3(evalMasterTone(pixel.r),evalMasterTone(pixel.g),evalMasterTone(pixel.b));
        }
    }
    pixel.r=customToneCurve(pixel.r,curveCounts.y,32u);
    pixel.g=customToneCurve(pixel.g,curveCounts.z,64u);
    pixel.b=customToneCurve(pixel.b,curveCounts.w,96u);
    if(basicV3.x!=0 && tone.x!=1) {
        pixel=float3(tcBasicContrastV3(pixel.r,tone.x-1.0),tcBasicContrastV3(pixel.g,tone.x-1.0),tcBasicContrastV3(pixel.b,tone.x-1.0));
    }
    if((basicV3.x==0 && tone.x!=1) || tone.y!=1) {
        if(basicV3.x==0)pixel=(pixel-.5)*tone.x+.5;
        float light=dot(pixel,float3(.2126,.7152,.0722));
        pixel=light+(pixel-light)*tone.y;
    }
    float3 vibranced=basicV3.x!=0 ? tcBasicVibranceV3(pixel,toneControls.z) : tcVibrance(pixel,toneControls.z);
    float3 colored=csApplySelectiveColor(csApplyPointColor(applyHsl(vibranced)));
    return cgApply(colored,
        colorGrading[0].xyz,colorGrading[0].w,
        colorGrading[1].xyz,colorGrading[1].w,
        colorGrading[2].xyz,colorGrading[2].w,
        colorGradingGlobal.xyz,colorGradingGlobal.w,
        colorGradingMix.x,colorGradingMix.y);
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

inline const std::string kD3DSpatialShader = std::string(R"hlsl(
cbuffer SpatialParamsBuffer : register(b0) {
    uint4 spDims;        // width, height, rowOffset, rows
    uint4 spBandInfo;    // srcRowOffset, auxRowOffset, radius, stage
    float4 spSharpenCfg; // strength (detailGain for sharpen v2), coring, maskLow, maskSpan
    float4 spDefringeCfg;// purpleNorm, purpleCenter, greenNorm, greenCenter
    float4 spAirlight;
    uint4 spFlags;
    uint4 spBandDims;    // srcRows, auxRows, dstWidth, dstHeight
    float4 spWeights[7];
};
StructuredBuffer<float3> spSrc : register(t0);
StructuredBuffer<float3> spAux : register(t1);
StructuredBuffer<float> spField : register(t2);
RWStructuredBuffer<float3> spDst : register(u0);

float3 spLoadSrc(int x, int y) {
    uint cx = (uint)clamp(x, 0, (int)spDims.x - 1);
    int minY = (int)spBandInfo.x;
    int maxY = minY + (int)max(1u, spBandDims.x) - 1;
    uint cy = (uint)clamp(y, minY, maxY);
    return spSrc[(cy - spBandInfo.x) * spDims.x + cx];
}
float3 spLoadAux(int x, int y) {
    uint cx = (uint)clamp(x, 0, (int)spDims.x - 1);
    int minY = (int)spBandInfo.y;
    int maxY = minY + (int)max(1u, spBandDims.y) - 1;
    uint cy = (uint)clamp(y, minY, maxY);
    return spAux[(cy - spBandInfo.y) * spDims.x + cx];
}
float spReadWeight(uint idx) {
    float4 wv = spWeights[idx >> 2u];
    uint lane = idx & 3u;
    return lane == 0u ? wv.x : (lane == 1u ? wv.y : (lane == 2u ? wv.z : wv.w));
}

#define SP_FN
#define SP_V3 float3
#define SP_V3C(x, y, z) float3((x), (y), (z))
#define SP_CTX_DECL
#define SP_CTX_ARG
#define SP_SRC(ix, iy) spLoadSrc((ix), (iy))
#define SP_AUX(ix, iy) spLoadAux((ix), (iy))
#define SP_FIELD(idx) spField[(idx)]
#define SP_FINITE(v) all(isfinite(v))
#define SP_WEIGHT(idx) spReadWeight(idx)
#define SP_WIDTH spDims.x
#define SP_HEIGHT spDims.y
#define SP_RADIUS spBandInfo.z
#define SP_STRENGTH spSharpenCfg.x
#define SP_SHARPEN_CORING spSharpenCfg.y
#define SP_SHARPEN_MASK_LOW spSharpenCfg.z
#define SP_SHARPEN_MASK_SPAN spSharpenCfg.w
#define SP_PURPLE_NORM spDefringeCfg.x
#define SP_PURPLE_CENTER spDefringeCfg.y
#define SP_GREEN_NORM spDefringeCfg.z
#define SP_GREEN_CENTER spDefringeCfg.w
#define SP_AIRLIGHT spAirlight
#define SP_FLAGS spFlags
)hlsl") + photoSpatialShaderBody() + R"hlsl(
#undef SP_FN
#undef SP_V3
#undef SP_V3C
#undef SP_CTX_DECL
#undef SP_CTX_ARG
#undef SP_SRC
#undef SP_AUX
#undef SP_FIELD
#undef SP_FINITE
#undef SP_WEIGHT
#undef SP_WIDTH
#undef SP_HEIGHT
#undef SP_RADIUS
#undef SP_STRENGTH
#undef SP_SHARPEN_CORING
#undef SP_SHARPEN_MASK_LOW
#undef SP_SHARPEN_MASK_SPAN
#undef SP_PURPLE_NORM
#undef SP_PURPLE_CENTER
#undef SP_GREEN_NORM
#undef SP_GREEN_CENTER
#undef SP_AIRLIGHT
#undef SP_FLAGS

[numthreads(16, 16, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    if (id.x >= spDims.x || id.y >= spDims.w) return;
    int x = (int)id.x;
    int y = (int)(id.y + spDims.z);
    float3 outCol;
    uint st = spBandInfo.w;
    if (st == 0u) outCol = spDefringePixel(x, y);
    else if (st == 1u) outCol = spDehazePixel(x, y);
    else if (st == 2u) outCol = spClarityPixel(x, y);
    else if (st == 3u) outCol = spTextureBlurHPixel(x, y);
    else if (st == 4u) outCol = spTextureApplyVPixel(x, y);
    else if (st == 5u) outCol = spSharpenPrepHPixel(x, y);
    else if (st == 6u) outCol = spSharpenPrepVPixel(x, y);
    else if (st == 7u) outCol = spSharpenMaskHPixel(x, y);
    else outCol = spSharpenApplyPixel(x, y);
    spDst[id.y * spDims.x + id.x] = outCol;
}
)hlsl";
}
