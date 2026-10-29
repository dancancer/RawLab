#pragma once
#include "sony2fuji/common.h"
#include <algorithm>

namespace sony2fuji::hdr {
inline ImageData resample(const ImageData& image,uint32_t width,uint32_t height) {
    ImageData output(width,height);
    for (uint32_t y=0;y<height;++y) for (uint32_t x=0;x<width;++x) {
        const double sx=width>1 ? double(x)*(image.width-1)/(width-1) : (image.width-1)*.5;
        const double sy=height>1 ? double(y)*(image.height-1)/(height-1) : (image.height-1)*.5;
        const int x0=int(sx),y0=int(sy),x1=std::min(x0+1,image.width-1),y1=std::min(y0+1,image.height-1);
        const float fx=float(sx-x0),fy=float(sy-y0);
        const auto a=image.at(x0,y0),b=image.at(x1,y0),c=image.at(x0,y1),d=image.at(x1,y1);
        auto mix=[&](float av,float bv,float cv,float dv) { return (av+(bv-av)*fx)*(1-fy)+(cv+(dv-cv)*fx)*fy; };
        output.at(x,y)={mix(a.r,b.r,c.r,d.r),mix(a.g,b.g,c.g,d.g),mix(a.b,b.b,c.b,d.b)};
    }
    return output;
}
}
