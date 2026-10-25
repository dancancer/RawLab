#pragma once

#include <string>

namespace sony2fuji {

// 三种 shader 共用同一公式和常量；只替换语言的向量类型。
inline std::string toneControlsShader(const char* vectorType) {
    return std::string("\n#define TC_RGB ") + vectorType + R"shader(
float tcSmooth(float t) {
    t=clamp(t,0.0,1.0); return t*t*(3.0-2.0*t);
}
float tcLuminance(TC_RGB p) {
    return p.g+0.2126*(p.r-p.g)+0.0722*(p.b-p.g);
}
TC_RGB tcBlackWhite(TC_RGB pixel, float blackPoint, float whitePoint) {
    if (blackPoint==0.0 && whitePoint==0.0) return pixel;
    float y=tcLuminance(pixel);
    float offset=0.20*(blackPoint*(1.0-tcSmooth(y/0.35))+whitePoint*tcSmooth((y-0.65)/0.35));
    return clamp(pixel+offset,0.0,1.0);
}
float tcSkinMask(TC_RGB p, float maximum, float chroma, float y) {
    float hue;
    if (maximum==p.r) hue=(p.g-p.b)/chroma;
    else if (maximum==p.g) hue=(p.b-p.r)/chroma+2.0;
    else hue=(p.r-p.g)/chroma+4.0;
    hue*=60.0;
    if (hue<0.0) hue+=360.0;
    float distance=abs(hue-35.0); distance=min(distance,360.0-distance);
    float hueWeight=1.0-tcSmooth(distance/45.0);
    float lightWeight=tcSmooth((y-0.08)/0.12)*(1.0-tcSmooth((y-0.75)/0.20));
    float chromaWeight=tcSmooth((chroma-0.02)/0.08)*(1.0-tcSmooth((chroma-0.60)/0.25));
    return hueWeight*lightWeight*chromaWeight;
}
TC_RGB tcVibrance(TC_RGB p, float vibrance) {
    if (vibrance==0.0) return p;
    float maximum=max(max(p.r,p.g),p.b), minimum=min(min(p.r,p.g),p.b);
    float chroma=maximum-minimum;
    if (chroma==0.0) return p;
    bool inGamut=minimum>=0.0 && maximum<=1.0;
    if (vibrance>0.0 && !inGamut) return p;
    float y=tcLuminance(p), gain;
    if (vibrance<0.0) gain=1.0+vibrance;
    else {
        float saturation=chroma/maximum;
        float lowSaturation=(1.0-saturation)*(1.0-saturation);
        gain=1.0+vibrance*lowSaturation*(1.0-0.75*tcSkinMask(p,maximum,chroma,y));
        for (int channel=0;channel<3;++channel) {
            float difference=p[channel]-y;
            if (difference>0.0) gain=min(gain,(1.0-y)/difference);
            else if (difference<0.0) gain=min(gain,-y/difference);
        }
    }
    if (gain==1.0) return p;
    TC_RGB result=TC_RGB(y,y,y)+(p-TC_RGB(y,y,y))*gain;
    return inGamut ? clamp(result,0.0,1.0) : result;
}
#undef TC_RGB
)shader";
}
} // namespace sony2fuji
