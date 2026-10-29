#include "platform/hdr_heif_color.h"
#include "platform/hdr_image.h"
#include <libheif/heif.h>
#include <lcms2.h>
#include <algorithm>
#include <cmath>
#include <cstring>

namespace sony2fuji::hdr {
namespace {
[[noreturn]] void unsupported() { throw Error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,
    SONY2FUJI_HDR_FIELD_SOURCE,"HEIF requires supported RGB colorimetry"); }
[[noreturn]] void malformed() { throw Error(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_MALFORMED_AUX,
    SONY2FUJI_HDR_FIELD_SOURCE,"Invalid HEIF property association"); }
std::vector<uint8_t> nclx(uint16_t primaries,uint16_t transfer) {
    cmsCIExyYTRIPLE rgb;
    if(primaries==1)rgb={{.64,.33,1},{.3,.6,1},{.15,.06,1}};
    else if(primaries==12)rgb={{.68,.32,1},{.265,.69,1},{.15,.06,1}};
    else if(primaries==9)rgb={{.708,.292,1},{.17,.797,1},{.131,.046,1}};
    else unsupported();
    if(transfer!=13 && transfer!=1 && transfer!=8)unsupported();
    std::vector<cmsUInt16Number> table(4096);
    for(size_t i=0;i<table.size();++i) {
        const double x=double(i)/(table.size()-1);
        const double y=transfer==13 ? (x<=.04045 ? x/12.92 : std::pow((x+.055)/1.055,2.4)) :
            transfer==1 ? (x<.081 ? x/4.5 : std::pow((x+.099)/1.099,1/.45)) : x;
        table[i]=cmsUInt16Number(std::lround(y*65535));
    }
    auto* curve=cmsBuildTabulatedToneCurve16(nullptr,uint32_t(table.size()),table.data());
    cmsToneCurve* curves[]={curve,curve,curve};const cmsCIExyY white{.3127,.3290,1};
    auto profile=curve ? cmsCreateRGBProfile(&white,&rgb,curves) : nullptr;
    if(curve)cmsFreeToneCurve(curve);
    if(!profile)throw std::bad_alloc();
    cmsUInt32Number size=0;bool okay=cmsSaveProfileToMem(profile,nullptr,&size)!=0;
    std::vector<uint8_t> result(size);okay=okay && cmsSaveProfileToMem(profile,result.data(),&size)!=0;
    cmsCloseProfile(profile);if(!okay)unsupported();return result;
}
struct View {
    const uint8_t* data=nullptr;size_t size=0;
    uint64_t read(size_t offset,size_t count)const {
        if(count>8 || offset>size || count>size-offset)malformed();uint64_t value=0;
        for(size_t i=0;i<count;++i)value=value<<8|data[offset+i];return value;
    }
    View sub(size_t offset,size_t count)const { if(offset>size || count>size-offset)malformed();return {data+offset,count}; }
};
struct Box { uint32_t type;View payload; };
std::vector<Box> boxes(View view) {
    std::vector<Box> result;size_t at=0;
    while(at<view.size) {
        if(result.size()>=65536)malformed();
        auto length=view.read(at,4);const auto type=uint32_t(view.read(at+4,4));size_t header=8;
        if(length==1){length=view.read(at+8,8);header=16;}else if(!length)length=view.size-at;
        if(length<header || length>view.size-at)malformed();
        result.push_back({type,view.sub(at+header,size_t(length)-header)});at+=size_t(length);
    }
    return result;
}
constexpr uint32_t four(char a,char b,char c,char d){return uint32_t(a)<<24|uint32_t(b)<<16|uint32_t(c)<<8|uint32_t(d);}
std::vector<uint8_t> color(View profile) {
    const auto type=profile.read(0,4);
    if(type==four('n','c','l','x')) {
        if(profile.size!=11)malformed();return nclx(uint16_t(profile.read(4,2)),uint16_t(profile.read(6,2)));
    }
    if(type==four('r','I','C','C') || type==four('p','r','o','f')) {
        if(profile.size<132 || profile.size>1024*1024)malformed();return {profile.data+4,profile.data+profile.size};
    }
    unsupported();
}
}
std::vector<uint8_t> heifRGBProfile(const heif_image_handle* image) {
    const auto size=heif_image_handle_get_raw_color_profile_size(image);
    if(size) {
        if(size>1024*1024)malformed();std::vector<uint8_t> result(size);
        if(heif_image_handle_get_raw_color_profile(image,result.data()).code!=heif_error_Ok)malformed();return result;
    }
    heif_color_profile_nclx* description=nullptr;
    if(heif_image_handle_get_nclx_color_profile(image,&description).code!=heif_error_Ok || !description)unsupported();
    const auto primaries=description->color_primaries;
    const auto transfer=description->transfer_characteristics;
    heif_nclx_color_profile_free(description);return nclx(uint16_t(primaries),uint16_t(transfer));
}
std::vector<uint8_t> heifItemRGBProfile(const void* data,size_t size,uint32_t item) {
    // 稳定 libheif API 不暴露 tmap 的 colr 内容；只解析其有界 ipco/ipma 关联。
    std::vector<uint8_t> result;
    for(const auto& meta:boxes({static_cast<const uint8_t*>(data),size}))if(meta.type==four('m','e','t','a'))
    for(const auto& iprp:boxes(meta.payload.sub(4,meta.payload.size-4)))if(iprp.type==four('i','p','r','p')) {
        auto children=boxes(iprp.payload);std::vector<Box> properties;
        for(const auto& box:children)if(box.type==four('i','p','c','o')) { if(!properties.empty())malformed();properties=boxes(box.payload); }
        for(const auto& box:children)if(box.type==four('i','p','m','a')) {
            const auto& v=box.payload;const auto version=v.read(0,1),flags=v.read(1,3),count=v.read(4,4);
            if(version>1 || flags>1 || count>65536)malformed();size_t at=8;
            for(size_t i=0;i<count;++i) {
                const auto id=v.read(at,version ? 4 : 2);at+=version ? 4 : 2;
                const auto associations=v.read(at++,1);
                for(size_t a=0;a<associations;++a) {
                    const auto index=v.read(at,flags&1 ? 2 : 1)&(flags&1 ? 0x7fff : 0x7f);at+=flags&1 ? 2 : 1;
                    if(!index)continue;if(index>properties.size())malformed();
                    if(id==item && properties[index-1].type==four('c','o','l','r')) {
                        if(!result.empty())malformed();result=color(properties[index-1].payload);
                    }
                }
            }
            if(at!=v.size)malformed();
        }
    }
    if(result.empty())unsupported();return result;
}
}
