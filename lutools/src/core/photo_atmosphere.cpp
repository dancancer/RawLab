#include "photo_atmosphere.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <numeric>

namespace sony2fuji {
namespace {
constexpr int analysisLongEdge = 1024;
float smooth(float x) { x=std::clamp(x,0.f,1.f); return x*x*(3-2*x); }
float decode(float x) { return x<=.04045f ? x/12.92f : std::pow((x+.055f)/1.055f,2.4f); }
float encode(float x) { return x<=.0031308f ? 12.92f*x : 1.055f*std::pow(x,1/2.4f)-.055f; }
float luminance(const RGB& p) { return p.g+.2126f*(p.r-p.g)+.0722f*(p.b-p.g); }
bool inGamut(const RGB& p) {
    return p.r>=0 && p.r<=1 && p.g>=0 && p.g<=1 && p.b>=0 && p.b<=1;
}
bool finite(const RGB& p) { return std::isfinite(p.r) && std::isfinite(p.g) && std::isfinite(p.b); }
RGB linear(const RGB& p) { return RGB(decode(p.r),decode(p.g),decode(p.b)); }
RGB encodedExtended(const RGB& p) { return RGB(encode(p.r),encode(p.g),encode(p.b)); }
RGB encoded(const RGB& p) {
    return RGB(encode(std::clamp(p.r,0.f,1.f)),encode(std::clamp(p.g,0.f,1.f)),encode(std::clamp(p.b,0.f,1.f)));
}

// 面积平均先解 sRGB，避免高频纹理混叠进中尺度信号；完整源图只读一次。
ImageData analysisImage(const ImageData& source) {
    const double scale=std::min(1.,double(analysisLongEdge)/std::max(source.width,source.height));
    const int width=std::max(1,int(std::lround(source.width*scale)));
    const int height=std::max(1,int(std::lround(source.height*scale)));
    ImageData result(width,height);
    const double sx=double(source.width)/width, sy=double(source.height)/height;
    for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
        const double left=x*sx,right=(x+1)*sx,top=y*sy,bottom=(y+1)*sy;
        double r=0,g=0,b=0;
        for(int iy=int(top);iy<std::min(source.height,int(std::ceil(bottom)));++iy)
            for(int ix=int(left);ix<std::min(source.width,int(std::ceil(right)));++ix) {
                const double weight=(std::min(right,double(ix+1))-std::max(left,double(ix)))*
                    (std::min(bottom,double(iy+1))-std::max(top,double(iy)));
                const auto& p=source.at(ix,iy);
                // 扩展工作值仅在统计里限幅；应用阶段保留其连续的工作范围。
                r+=weight*decode(std::clamp(p.r,0.f,1.f));
                g+=weight*decode(std::clamp(p.g,0.f,1.f));
                b+=weight*decode(std::clamp(p.b,0.f,1.f));
            }
        result.at(x,y)=RGB(r/(sx*sy),g/(sx*sy),b/(sx*sy));
    }
    return result;
}
std::vector<float> lumaPlane(const ImageData& image) {
    std::vector<float> result(image.pixels.size());
    for(size_t i=0;i<result.size();++i) result[i]=luminance(image.pixels[i]);
    return result;
}
// 截断窗口按实际样本数归一化，double 累加避免大面积平场的浮点漂移。
std::vector<float> mean(const std::vector<float>& in,int width,int height,int radius) {
    std::vector<float> horizontal(in.size()),out(in.size());
    for(int y=0;y<height;++y) {
        double sum=0; int right=-1,left=0;
        for(int x=0;x<width;++x) {
            const int end=std::min(width-1,x+radius),start=std::max(0,x-radius);
            while(right<end) sum+=in[size_t(y)*width+(++right)];
            while(left<start) sum-=in[size_t(y)*width+left++];
            horizontal[size_t(y)*width+x]=sum/(end-start+1);
        }
    }
    for(int x=0;x<width;++x) {
        double sum=0; int bottom=-1,top=0;
        for(int y=0;y<height;++y) {
            const int end=std::min(height-1,y+radius),start=std::max(0,y-radius);
            while(bottom<end) sum+=horizontal[size_t(++bottom)*width+x];
            while(top<start) sum-=horizontal[size_t(top++)*width+x];
            out[size_t(y)*width+x]=sum/(end-start+1);
        }
    }
    return out;
}
std::vector<float> minimum(const std::vector<float>& in,int width,int height,int radius) {
    std::vector<float> horizontal(in.size()),out(in.size());
    auto line=[&](int count,int stride,int offset,const std::vector<float>& source,std::vector<float>& target) {
        std::deque<int> queue; int right=-1;
        for(int i=0;i<count;++i) {
            while(right<std::min(count-1,i+radius)) {
                ++right;
                while(!queue.empty() && source[offset+queue.back()*stride]>=source[offset+right*stride]) queue.pop_back();
                queue.push_back(right);
            }
            while(queue.front()<i-radius) queue.pop_front();
            target[offset+i*stride]=source[offset+queue.front()*stride];
        }
    };
    for(int y=0;y<height;++y) line(width,1,y*width,in,horizontal);
    for(int x=0;x<width;++x) line(height,width,x,horizontal,out);
    return out;
}
struct GuidedField { std::vector<float> slope,intercept,variance; };
GuidedField guided(const std::vector<float>& guide,const std::vector<float>& input,
                   int width,int height,int radius,float epsilon) {
    const auto mI=mean(guide,width,height,radius),mP=mean(input,width,height,radius);
    std::vector<float> ii(guide.size()),ip(guide.size());
    for(size_t i=0;i<guide.size();++i) { ii[i]=guide[i]*guide[i]; ip[i]=guide[i]*input[i]; }
    const auto mII=mean(ii,width,height,radius),mIP=mean(ip,width,height,radius);
    GuidedField result; result.variance.resize(guide.size());
    for(size_t i=0;i<guide.size();++i) {
        const float variance=std::max(0.f,mII[i]-mI[i]*mI[i]);
        result.variance[i]=variance;
        ii[i]=(mIP[i]-mI[i]*mP[i])/(variance+epsilon);
        ip[i]=mP[i]-ii[i]*mI[i];
    }
    result.slope=mean(ii,width,height,radius); result.intercept=mean(ip,width,height,radius);
    return result;
}
float sample(const std::vector<float>& field,int width,int height,float x,float y) {
    x=std::clamp(x,0.f,float(width-1)); y=std::clamp(y,0.f,float(height-1));
    const int x0=int(x),y0=int(y),x1=std::min(x0+1,width-1),y1=std::min(y0+1,height-1);
    const float dx=x-x0,dy=y-y0;
    return (1-dy)*((1-dx)*field[size_t(y0)*width+x0]+dx*field[size_t(y0)*width+x1])+
        dy*((1-dx)*field[size_t(y1)*width+x0]+dx*field[size_t(y1)*width+x1]);
}
uint64_t fingerprint(const ImageData& image) {
    uint64_t hash=14695981039346656037ull;
    for(const auto& p:image.pixels) for(float v:{p.r,p.g,p.b}) {
        uint32_t bits; std::memcpy(&bits,&v,sizeof(bits));
        for(int byte=0;byte<4;++byte) { hash^=(bits>>(byte*8))&255; hash*=1099511628211ull; }
    }
    return hash;
}
void analyzeDehaze(const ImageData& image,DehazeAnalysis& result) {
    const int width=image.width,height=image.height;
    const int radius=std::max(1,int(std::lround(std::max(width,height)*.0075)));
    std::vector<float> dark(image.pixels.size());
    for(size_t i=0;i<dark.size();++i) {
        const auto& p=image.pixels[i]; dark[i]=std::min({p.r,p.g,p.b});
    }
    dark=minimum(dark,width,height,radius);
    std::vector<size_t> order(dark.size()); std::iota(order.begin(),order.end(),0);
    const size_t count=std::max(size_t(1),dark.size()/500);
    // 相等时固定索引顺序，避免不同标准库在大平场选择不同空气光。
    auto better=[&](size_t a,size_t b) { return dark[a]!=dark[b] ? dark[a]>dark[b] : a<b; };
    std::partial_sort(order.begin(),order.begin()+count,order.end(),better);
    double r=0,g=0,b=0;
    for(size_t i=0;i<count;++i) {
        const auto& p=image.pixels[order[i]]; r+=p.r;g+=p.g;b+=p.b;
    }
    const RGB air(r/count,g/count,b/count);
    const float gray=luminance(air);
    // 中性占主导，限制偶然亮色物体引入的整体色偏。
    result.airlight=RGB(std::clamp(.85f*gray+.15f*air.r,.1f,.95f),
        std::clamp(.85f*gray+.15f*air.g,.1f,.95f),std::clamp(.85f*gray+.15f*air.b,.1f,.95f));
    for(size_t i=0;i<dark.size();++i) {
        const auto& p=image.pixels[i];
        dark[i]=std::min({p.r/result.airlight.r,p.g/result.airlight.g,p.b/result.airlight.b});
    }
    dark=minimum(dark,width,height,radius);
    for(auto& v:dark) v=std::clamp(1-.85f*v,.5f,1.f);
    const auto field=guided(lumaPlane(image),dark,width,height,2*radius,.001f);
    result.width=width; result.height=height; result.slope=field.slope; result.intercept=field.intercept;
    result.variance=field.variance;
    ++result.builds;
}
RGB boundedMove(const RGB& p,const RGB& delta) {
    float scale=1;
    const float values[]={p.r,p.g,p.b},deltas[]={delta.r,delta.g,delta.b};
    for(int c=0;c<3;++c) {
        if(deltas[c]>0) scale=std::min(scale,(1-values[c])/deltas[c]);
        if(deltas[c]<0) scale=std::min(scale,-values[c]/deltas[c]);
    }
    return RGB(p.r+scale*delta.r,p.g+scale*delta.g,p.b+scale*delta.b);
}
RGB softBoundedMove(const RGB& p,const RGB& delta) {
    float pressure=0;
    const float values[]={p.r,p.g,p.b},deltas[]={delta.r,delta.g,delta.b};
    for(int c=0;c<3;++c) {
        if(deltas[c]>0) pressure=std::max(pressure,deltas[c]/(1-values[c]));
        if(deltas[c]<0) pressure=std::max(pressure,-deltas[c]/values[c]);
    }
    // 在到达边界前连续压缩，避免有色高光被投到同一面而出现斑块。
    const float scale=1/(1+pressure);
    return RGB(p.r+scale*delta.r,p.g+scale*delta.g,p.b+scale*delta.b);
}
} // namespace

bool AtmosphereOptions::valid() const {
    return std::isfinite(clarity) && std::abs(clarity)<=1 && std::isfinite(dehaze) && std::abs(dehaze)<=1;
}
void applyClarity(ImageData& image,float amount) {
    if(amount==0 || image.width<=0 || image.height<=0) return;
    const auto analysis=analysisImage(image);
    const int width=analysis.width,height=analysis.height;
    const int radius=std::max(1,int(std::lround(std::max(width,height)*.01)));
    const auto guide=lumaPlane(analysis);
    const auto medium=mean(guide,width,height,std::max(1,radius/8));
    const auto base=guided(medium,medium,width,height,radius,.001f);
    std::vector<float> residual(guide.size());
    for(size_t i=0;i<guide.size();++i) {
        const float difference=medium[i]-(base.slope[i]*medium[i]+base.intercept[i]);
        const float edge=1/(1+base.variance[i]/.002f);
        residual[i]=std::clamp(difference,-.08f,.08f)*edge*edge*smooth(std::abs(difference)/.001f);
    }
    for(int y=0;y<image.height;++y) for(int x=0;x<image.width;++x) {
        auto& encodedPixel=image.at(x,y); if(!finite(encodedPixel)) continue;
        const bool bounded=inGamut(encodedPixel);
        const auto p=linear(encodedPixel); const float luma=luminance(p);
        const float ax=(x+.5f)*width/image.width-.5f,ay=(y+.5f)*height/image.height-.5f;
        const float coarse=sample(medium,width,height,ax,ay);
        const float fineGuard=1-smooth(std::abs(luma-coarse)/.08f);
        const float lightGuard=smooth((luma-.01f)/.12f)*(1-smooth((luma-.65f)/.3f));
        const float delta=1.5f*amount*sample(residual,width,height,ax,ay)*fineGuard*lightGuard;
        if(std::abs(delta)<1e-8f || luma<=0) continue;
        const float gain=std::max(-1.f,delta/luma);
        if (bounded) encodedPixel=encoded(boundedMove(p,RGB(p.r*gain,p.g*gain,p.b*gain)));
        // 收缩扩展工作值仍连续；向外扩张在色域边界停止，不能先截断旧 tone/LUT。
        else if (gain<0) encodedPixel=encodedExtended(RGB(p.r*(1+gain),p.g*(1+gain),p.b*(1+gain)));
    }
}
void applyDehaze(ImageData& image,float amount,DehazeAnalysis* cache) {
    if(amount==0 || image.width<=0 || image.height<=0) return;
    const auto analysis=analysisImage(image);
    DehazeAnalysis local; auto& state=cache ? *cache : local;
    const auto key=fingerprint(analysis);
    if(state.slope.empty() || state.fingerprint!=key || state.sourceWidth!=image.width || state.sourceHeight!=image.height) {
        analyzeDehaze(analysis,state); state.fingerprint=key;
        state.sourceWidth=image.width;state.sourceHeight=image.height;
    }
    const auto a=state.airlight;
    for(int y=0;y<image.height;++y) for(int x=0;x<image.width;++x) {
        auto& encodedPixel=image.at(x,y); if(!finite(encodedPixel)) continue;
        const bool bounded=inGamut(encodedPixel);
        if (amount>0 && !bounded) continue;
        const auto p=linear(encodedPixel); const float luma=luminance(p);
        const float ax=(x+.5f)*state.width/image.width-.5f,ay=(y+.5f)*state.height/image.height-.5f;
        const float t=std::clamp(sample(state.slope,state.width,state.height,ax,ay)*luma+
            sample(state.intercept,state.width,state.height,ax,ay),.5f,1.f);
        RGB delta;
        if(amount>0) {
            const float variance=sample(state.variance,state.width,state.height,ax,ay);
            const float flatBright=smooth((luma-.08f)/.22f)*(1-smooth(variance/.001f));
            // 有理暗部权重避免 smoothstep 的陡导数在灰阶渐变里造成反转。
            const float protect=(luma/(luma+.03f))*(1-.8f*smooth((luma-.5f)/.4f))*(1-.75f*flatBright);
            const float effective=std::max(.5f,1-amount*protect*(1-t));
            const float gain=1/effective-1;
            delta=RGB((p.r-a.r)*gain,(p.g-a.g)*gain,(p.b-a.b)*gain);
        } else {
            const float haze=-amount*.45f*(.25f+.75f*(1-t));
            delta=RGB((a.r-p.r)*haze,(a.g-p.g)*haze,(a.b-p.b)*haze);
        }
        if(std::max({std::abs(delta.r),std::abs(delta.g),std::abs(delta.b)})<1e-8f) continue;
        encodedPixel=bounded ? encoded(amount>0 ? softBoundedMove(p,delta) : boundedMove(p,delta)) :
            encodedExtended(RGB(p.r+delta.r,p.g+delta.g,p.b+delta.b));
    }
}
} // namespace sony2fuji
