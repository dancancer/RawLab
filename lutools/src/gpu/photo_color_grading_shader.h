#pragma once

#include <string>

namespace sony2fuji {

// 色相系数由同一 CPU 函数生成；三后端只计算逐像素传递、权重和色域约束。
inline std::string colorGradingShader(const char* vectorType) {
    return std::string("\n#define CG_RGB ")+vectorType+R"shader(
float cgSmooth(float value) {
    float t=clamp(value,0.0,1.0);return t*t*(3.0-2.0*t);
}
float cgLinear(float value) {
    return value<=0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4);
}
float cgEncoded(float value) {
    return value<=0.0031308 ? 12.92*value : 1.055*pow(value,1.0/2.4)-0.055;
}
CG_RGB cgApply(CG_RGB pixel,CG_RGB shadows,CG_RGB middle,CG_RGB highlights) {
    CG_RGB magnitude=abs(shadows)+abs(middle)+abs(highlights);
    if (magnitude.r==0.0 && magnitude.g==0.0 && magnitude.b==0.0) return pixel;
    CG_RGB p=CG_RGB(cgLinear(pixel.r),cgLinear(pixel.g),cgLinear(pixel.b));
    float y=p.g+0.2126*(p.r-p.g)+0.0722*(p.b-p.g);
    float a=clamp(y,0.0,1.0),amplitude=a*(1.0-a);
    if (amplitude==0.0) return pixel;
    float ws=1.0-cgSmooth((y-0.20)/0.35);
    float wm=cgSmooth((y-0.20)/0.30)*(1.0-cgSmooth((y-0.50)/0.30));
    float wh=cgSmooth((y-0.45)/0.35),total=ws+wm+wh;
    CG_RGB delta=(ws/total)*shadows+(wm/total)*middle+(wh/total)*highlights;
    if (delta.r==0.0 && delta.g==0.0 && delta.b==0.0) return pixel;
    CG_RGB chroma=p-y+amplitude*delta;
    float low=min(0.0,min(p.r,min(p.g,p.b))),high=max(1.0,max(p.r,max(p.g,p.b)));
    float gain=1.0;
    for (int i=0;i<3;++i) {
        float c=chroma[i];
        if (c>0.0) gain=min(gain,(high-y)/c);
        else if (c<0.0) gain=min(gain,(low-y)/c);
    }
    CG_RGB result=clamp(y+gain*chroma,low,high);
    return CG_RGB(cgEncoded(result.r),cgEncoded(result.g),cgEncoded(result.b));
}
#undef CG_RGB
)shader";
}
} // namespace sony2fuji
