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
CG_RGB cgApply(CG_RGB pixel,
    CG_RGB shadows,float shadowsLum,
    CG_RGB middle,float middleLum,
    CG_RGB highlights,float highlightsLum,
    CG_RGB globalCoeff,float globalLum,
    float blending,float balance) {
    CG_RGB magnitude=abs(shadows)+abs(middle)+abs(highlights)+abs(globalCoeff);
    float lumMag=abs(shadowsLum)+abs(middleLum)+abs(highlightsLum)+abs(globalLum);
    if (magnitude.r==0.0 && magnitude.g==0.0 && magnitude.b==0.0 && lumMag==0.0) return pixel;
    CG_RGB p=CG_RGB(cgLinear(pixel.r),cgLinear(pixel.g),cgLinear(pixel.b));
    float y=p.g+0.2126*(p.r-p.g)+0.0722*(p.b-p.g);
    if (y<=0.0 || y>=1.0) return pixel;
    float ws=0.0,wm=0.0,wh=0.0;
    if (blending==50.0 && balance==0.0) {
        ws=1.0-cgSmooth((y-0.20)/0.35);
        wm=cgSmooth((y-0.20)/0.30)*(1.0-cgSmooth((y-0.50)/0.30));
        wh=cgSmooth((y-0.45)/0.35);
    } else {
        float sy=y+0.20*(balance/100.0);
        float scale=0.05+1.90*(blending/100.0);
        float sW=0.35*scale,mW=0.30*scale,hW=0.35*scale;
        ws=1.0-cgSmooth((sy-(0.375-0.5*sW))/sW);
        wm=cgSmooth((sy-(0.35-0.5*mW))/mW)*(1.0-cgSmooth((sy-(0.65-0.5*mW))/mW));
        wh=cgSmooth((sy-(0.625-0.5*hW))/hW);
    }
    float total=ws+wm+wh;
    ws/=total;wm/=total;wh/=total;
    CG_RGB delta=ws*shadows+wm*middle+wh*highlights+globalCoeff;
    float lumDelta=ws*shadowsLum+wm*middleLum+wh*highlightsLum+globalLum;
    if (delta.r==0.0 && delta.g==0.0 && delta.b==0.0 && lumDelta==0.0) return pixel;
    float targetY=y;
    float yScale=1.0;
    if (lumDelta!=0.0) {
        float u=cgEncoded(y);
        float c=clamp(0.75*lumDelta,-0.95,0.95);
        targetY=cgLinear(u+c*u*(1.0-u));
        yScale=targetY/y;
    }
    float a=clamp(targetY,0.0,1.0),amplitude=a*(1.0-a);
    if (lumDelta==0.0 && amplitude==0.0) return pixel;
    CG_RGB chroma=(p-y)*yScale+amplitude*delta;
    float low=min(0.0,min(p.r,min(p.g,p.b))),high=max(1.0,max(p.r,max(p.g,p.b)));
    float gain=1.0;
    for (int i=0;i<3;++i) {
        float c=chroma[i];
        if (c>0.0) gain=min(gain,(high-targetY)/c);
        else if (c<0.0) gain=min(gain,(low-targetY)/c);
    }
    CG_RGB result=clamp(targetY+gain*chroma,low,high);
    return CG_RGB(cgEncoded(result.r),cgEncoded(result.g),cgEncoded(result.b));
}
#undef CG_RGB
)shader";
}
} // namespace sony2fuji
