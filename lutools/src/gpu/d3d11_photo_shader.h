#pragma once
namespace sony2fuji {
inline constexpr const char* kD3DPhotoShader = R"hlsl(
cbuffer Params : register(b0) {
    uint4 dimensions; // source width/height, destination width/height
    uint4 control; // stage, count, use LUT, LUT size
    float4 toSrgb[3];
    float4 toFilm[3];
    float4 exposureStrength;
    float4 tone; // contrast, saturation, highlights, shadows
    float4 detail; // curve, noise, sharpening, unused
    float4 domainLow;
    float4 domainHigh;
    uint4 logTransfer; // input is F-Log, output is Log, output is F-Log, unused
};
StructuredBuffer<float3> source : register(t0);
StructuredBuffer<float3> film : register(t1);
RWStructuredBuffer<float3> destination : register(u0);
float neutral(float x) {
    if (x <= 0) return 0;
    float gray=0.1845;
    float scene=1/(1+(1-gray)/gray*pow(gray/x,1.5));
    return scene<=0.0031308 ? scene*12.92 : 1.055*pow(scene,1/2.4)-0.055;
}
float flog2(float x) {
    return saturate(x<0.00088899597 ? 8.799461*x+0.092864 : log10(x*5.555556+0.064829)*0.245281+0.384316);
}
float encodeLog(float x) {
    if(logTransfer.x==0)return flog2(x);
    return saturate(x<0.00089 ? 8.735631*x+0.092864 : 0.344676*log10(0.555556*x+0.009468)+0.790453);
}
float decodeLog(float x) {
    if(logTransfer.z!=0)return x<0.100537775223865 ? (x-0.092864)/8.735631
        : (pow(10.0,(x-0.790453)/0.344676)-0.009468)/0.555556;
    return x<0.100686685370811 ? (x-0.092864)/8.799461
        : (pow(10.0,(x-0.384316)/0.245281)-0.064829)/5.555556;
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
float3 evaluate(float3 inputColor) {
    float3 scene=float3(dot(toSrgb[0].xyz,inputColor),dot(toSrgb[1].xyz,inputColor),dot(toSrgb[2].xyz,inputColor))*exposureStrength.xyz;
    float3 pixel=float3(neutral(scene.r),neutral(scene.g),neutral(scene.b));
    if(control.z!=0) {
        float3 fg=float3(dot(toFilm[0].xyz,scene),dot(toFilm[1].xyz,scene),dot(toFilm[2].xyz,scene));
        float3 look=lookup(float3(encodeLog(fg.r),encodeLog(fg.g),encodeLog(fg.b)));
        if(logTransfer.y!=0)look=float3(neutral(decodeLog(look.r)),neutral(decodeLog(look.g)),neutral(decodeLog(look.b)));
        pixel=lerp(pixel,look,exposureStrength.w);
    }
    if(tone.z!=0 || tone.w!=0) {
        float light=dot(pixel,float3(.2126,.7152,.0722)),adjusted=light;
        if(tone.w!=0)adjusted=pow(saturate(adjusted),1-tone.w*.5);
        if(tone.z!=0)adjusted=1-pow(1-saturate(adjusted),1-tone.z*.5);
        pixel=light>0 ? pixel*(adjusted/light) : adjusted.xxx;
    }
    if(detail.x!=0)pixel=float3(curve(pixel.r),curve(pixel.g),curve(pixel.b));
    if(tone.x!=1 || tone.y!=1) {
        pixel=(pixel-.5)*tone.x+.5;float light=dot(pixel,float3(.2126,.7152,.0722));
        pixel=light+(pixel-light)*tone.y;
    }
    return pixel;
}
float3 readPixel(uint2 p) { return source[p.y*dimensions.x+p.x]; }
float3 resize(uint2 xy) {
    float2 scale=float2(dimensions.z==1 ? 0 : float(dimensions.x-1)/float(dimensions.z-1),
        dimensions.w==1 ? 0 : float(dimensions.y-1)/float(dimensions.w-1));
    float2 p=min(xy*scale,float2(dimensions.xy-1));uint2 low=(uint2)floor(p),high=min(low+1,dimensions.xy-1);float2 t=p-low;
    return lerp(lerp(readPixel(low),readPixel(uint2(high.x,low.y)),t.x),lerp(readPixel(uint2(low.x,high.y)),readPixel(high),t.x),t.y);
}
[numthreads(16,16,1)]
void main(uint3 id : SV_DispatchThreadID) {
    if(id.x>=dimensions.z || id.y>=dimensions.w)return;
    float3 pixel;
    if(control.x==0)pixel=evaluate(all(dimensions.xy==dimensions.zw) ? readPixel(id.xy) : resize(id.xy));
    else if(control.x==1)pixel=resize(id.xy);
    else {
        float3 sum=0; float weight=0;
        [unroll] for(int y=-1;y<=1;y++) [unroll] for(int x=-1;x<=1;x++) {
            uint2 p=(uint2)clamp(int2(id.xy)+int2(x,y),int2(0,0),int2(dimensions.xy)-1);
            sum+=readPixel(p);weight+=1;
        }
        pixel=readPixel(id.xy);float3 blurred=sum/weight;
        pixel=control.x==2 ? lerp(pixel,blurred,saturate(detail.y)*.4) : saturate(pixel+clamp(detail.z,0,2)*(pixel-blurred));
    }
    destination[id.y*dimensions.z+id.x]=pixel;
}
)hlsl";
}
