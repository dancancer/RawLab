#include "platform/hdr_heif.h"
#include "platform/hdr_metadata.h"
#include "platform/hdr_heif_color.h"
#include <libheif/heif.h>
#include <libheif/heif_properties.h>
#include <libheif/heif_items.h>
#include <lcms2.h>
#include <ultrahdr/gainmapmetadata.h>
#include <ultrahdr/gainmapmath.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <thread>

namespace sony2fuji::hdr {
namespace {
void checked(heif_error error) {
    if (error.code!=heif_error_Ok)
        throw Error(error.code==heif_error_Memory_allocation_error ? SONY2FUJI_STATUS_OUT_OF_MEMORY : SONY2FUJI_STATUS_PROCESSING_ERROR,
            error.code==heif_error_Memory_allocation_error ? SONY2FUJI_HDR_REASON_OUT_OF_MEMORY : SONY2FUJI_HDR_REASON_MALFORMED_AUX,
            SONY2FUJI_HDR_FIELD_SOURCE,error.message ? error.message : "HEIF decoding failed");
}
[[noreturn]] void invalid(const char* message) {
    throw Error(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_MALFORMED_AUX,SONY2FUJI_HDR_FIELD_SOURCE,message);
}
[[noreturn]] void unsupported(uint32_t reason,const char* message) {
    throw Error(SONY2FUJI_STATUS_UNSUPPORTED,reason,SONY2FUJI_HDR_FIELD_SOURCE,message);
}
using Context=std::unique_ptr<heif_context,decltype(&heif_context_free)>;
using Handle=std::unique_ptr<heif_image_handle,decltype(&heif_image_handle_release)>;
using Image=std::unique_ptr<heif_image,decltype(&heif_image_release)>;
struct File {
    Context context{nullptr,heif_context_free}; Handle primary{nullptr,heif_image_handle_release},gain{nullptr,heif_image_handle_release};
    std::vector<uint8_t> exif,icc;
    std::unique_ptr<ultrahdr::uhdr_gainmap_metadata_ext_t> iso;
    uint32_t gainColor=0;
    uint32_t toneMapItem=0;
    sony2fuji_hdr_source_info_v1 info{};
};
float appleMetadata(const heif_image_handle* handle) {
    const int count=heif_image_handle_get_number_of_metadata_blocks(handle,"mime");
    if (count<1 || count>32) invalid("Missing Apple gain-map metadata");
    std::array<heif_item_id,32> ids{}; heif_image_handle_get_list_of_metadata_block_IDs(handle,"mime",ids.data(),count);
    bool found=false; float headroom=0;
    for (int i=0;i<count;++i) {
        const auto* type=heif_image_handle_get_metadata_content_type(handle,ids[i]);
        if (!type || std::strcmp(type,"application/rdf+xml")) continue;
        const size_t size=heif_image_handle_get_metadata_size(handle,ids[i]);
        if (!size || size>1024*1024) invalid("Invalid Apple gain-map XMP size");
        std::vector<uint8_t> bytes(size); checked(heif_image_handle_get_metadata(handle,ids[i],bytes.data()));
        const char* name="http://ns.apple.com/HDRGainMap/1.0/";
        if (std::search(bytes.begin(),bytes.end(),name,name+std::strlen(name))==bytes.end()) continue;
        if (found) invalid("Ambiguous Apple gain-map XMP");
        headroom=appleXMPHeadroom(bytes.data(),bytes.size()); found=true;
    }
    if (!found) invalid("Missing Apple gain-map XMP description"); return headroom;
}
bool findISO(File& file) {
    const auto* context=file.context.get(); const auto primary=heif_image_handle_get_item_id(file.primary.get());
    const int count=heif_context_get_number_of_items(context);
    if (count<1 || count>65536) invalid("Invalid HEIF item table");
    std::vector<heif_item_id> ids(count); heif_context_get_list_of_item_IDs(context,ids.data(),count);
    bool found=false;
    for (auto id:ids) if (heif_item_get_item_type(context,id)==heif_fourcc('t','m','a','p')) {
        bool associated=false; heif_item_id gainID=0;int dimgCount=0;
        for (int index=0;index<32;++index) {
            uint32_t type=0; heif_item_id* references=nullptr;
            const size_t length=heif_context_get_item_references(context,id,index,&type,&references);
            if (!length) break;
            if(type==heif_fourcc('d','i','m','g'))dimgCount++;
            if (type==heif_fourcc('d','i','m','g') && length==2 && references[0]==primary && references[1]!=primary) {
                if (associated) { heif_release_item_references(context,&references); invalid("Ambiguous ISO gain-map association"); }
                associated=true; gainID=references[1];
            }
            heif_release_item_references(context,&references);
        }
        if (!associated) continue;
        if(dimgCount!=1)invalid("Ambiguous ISO derived image inputs");
        if (found) invalid("Multiple ISO gain-map descriptions");
        size_t size=0; checked(heif_item_get_item_data(context,id,nullptr,nullptr,&size));
        if (size<2 || size>4096) invalid("Invalid ISO gain-map description size");
        uint8_t* bytes=nullptr; checked(heif_item_get_item_data(context,id,nullptr,&bytes,&size));
        std::vector<uint8_t> payload(bytes,bytes+size); heif_release_item_data(context,&bytes);
        if (payload[0]!=0) unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION,"Unsupported HEIF tone-map version");
        payload.erase(payload.begin()); ultrahdr::uhdr_gainmap_metadata_frac fractions;
        auto result=ultrahdr::uhdr_gainmap_metadata_frac::decodeGainmapMetadata(payload,&fractions);
        if (result.error_code!=UHDR_CODEC_OK) invalid("Invalid ISO gain-map description");
        file.iso=std::make_unique<ultrahdr::uhdr_gainmap_metadata_ext_t>("1.0");
        result=ultrahdr::uhdr_gainmap_metadata_frac::gainmapMetadataFractionToFloat(&fractions,file.iso.get());
        if (result.error_code!=UHDR_CODEC_OK) invalid("Invalid ISO gain-map fractions");
        auto& m=*file.iso;
        if (!std::isfinite(m.hdr_capacity_min) || !std::isfinite(m.hdr_capacity_max) || m.hdr_capacity_min<1 || m.hdr_capacity_max<=m.hdr_capacity_min)
            invalid("Invalid ISO gain-map capacity");
        for (int c=0;c<3;++c) if (!std::isfinite(m.min_content_boost[c]) || !std::isfinite(m.max_content_boost[c]) ||
            !std::isfinite(m.gamma[c]) || !std::isfinite(m.offset_sdr[c]) || !std::isfinite(m.offset_hdr[c]) ||
            m.min_content_boost[c]<=0 || m.max_content_boost[c]<m.min_content_boost[c] || m.gamma[c]<=0)
            invalid("Invalid ISO gain-map channel parameters");
        heif_image_handle* gain=nullptr; checked(heif_context_get_image_handle(file.context.get(),gainID,&gain)); file.gain.reset(gain);
        file.toneMapItem=id;
        file.info.protocol=SONY2FUJI_HDR_PROTOCOL_ISO;
        file.info.content_headroom=std::max({1.0f,m.max_content_boost[0],m.max_content_boost[1],m.max_content_boost[2]});
        found=true;
    }
    return found;
}
std::vector<uint8_t> exif(const heif_image_handle* handle) {
    const int count=heif_image_handle_get_number_of_metadata_blocks(handle,"Exif");
    if (!count) return {};
    if (count!=1) invalid("HEIF contains ambiguous EXIF blocks");
    heif_item_id id{};
    if (heif_image_handle_get_list_of_metadata_block_IDs(handle,"Exif",&id,1)!=1) invalid("Missing HEIF EXIF item");
    const size_t size=heif_image_handle_get_metadata_size(handle,id);
    if (size<4 || size>1024*1024) invalid("Invalid HEIF EXIF item size");
    std::vector<uint8_t> bytes(size); checked(heif_image_handle_get_metadata(handle,id,bytes.data()));
    const size_t offset=size_t(bytes[0])<<24|size_t(bytes[1])<<16|size_t(bytes[2])<<8|bytes[3];
    if (offset>size-4) invalid("Invalid HEIF TIFF offset");
    size_t at=4+offset;
    if (size-at>=6 && std::memcmp(bytes.data()+at,"Exif\0\0",6)==0) at+=6;
    std::vector<uint8_t> result(bytes.begin()+at,bytes.end());
    exifOrientation(result.data(),result.size()); return result;
}
uint32_t orientation(const heif_context* context,const heif_image_handle* handle) {
    const auto id=heif_image_handle_get_item_id(handle);
    const int count=heif_item_get_transformation_properties(context,id,nullptr,0);
    if (count<0 || count>16) invalid("Invalid HEIF transformations");
    std::array<heif_property_id,16> properties{};
    heif_item_get_transformation_properties(context,id,properties.data(),count);
    // 归一化方形的三个角，按容器声明顺序组合，再识别为 EXIF 八种方向之一。
    std::array<std::array<int,2>,3> points={{{0,0},{1,0},{0,1}}};
    for (int i=0;i<count;++i) {
        const auto property=properties[i]; const auto type=heif_item_get_property_type(context,id,property);
        if (type==heif_item_property_type_transform_rotation) {
            const int rotation=heif_item_get_property_transform_rotation_ccw(context,id,property);
            if (rotation<0 || rotation%90) invalid("Invalid HEIF rotation");
            for (int step=0;step<rotation/90;++step) for (auto& p:points) p={p[1],1-p[0]};
        } else if (type==heif_item_property_type_transform_mirror) {
            const auto direction=heif_item_get_property_transform_mirror(context,id,property);
            if (direction==heif_transform_mirror_direction_invalid) invalid("Invalid HEIF mirror");
            for (auto& p:points) if (direction==heif_transform_mirror_direction_horizontal) p[0]=1-p[0]; else p[1]=1-p[1];
        }
    }
    static const std::array<std::array<std::array<int,2>,3>,8> expected={{{{{0,0},{1,0},{0,1}}},{{{1,0},{0,0},{1,1}}},
        {{{1,1},{0,1},{1,0}}},{{{0,1},{1,1},{0,0}}},{{{0,0},{0,1},{1,0}}},{{{1,0},{1,1},{0,0}}},
        {{{1,1},{1,0},{0,1}}},{{{0,1},{0,0},{1,1}}}}};
    for (uint32_t i=0;i<8;++i) if (points==expected[i]) return i+1;
    invalid("HEIF orientation is not representable");
}
File open(const void* data,size_t size) {
    File file; file.context.reset(heif_context_alloc()); if (!file.context) throw std::bad_alloc();
    auto* limits=heif_context_get_security_limits(file.context.get());
    limits->max_image_size_pixels=128000000;
    heif_context_set_max_decoding_threads(file.context.get(),int(std::min(6u,std::max(1u,std::thread::hardware_concurrency()))));
    checked(heif_context_read_from_memory_without_copy(file.context.get(),data,size,nullptr));
    if (heif_context_get_number_of_top_level_images(file.context.get())!=1) unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,"HEIF requires one primary image");
    heif_image_handle* primary=nullptr; checked(heif_context_get_primary_image_handle(file.context.get(),&primary)); file.primary.reset(primary);
    const int width=heif_image_handle_get_ispe_width(primary),height=heif_image_handle_get_ispe_height(primary);
    if (width<=0 || height<=0 || uint64_t(width)*height>128000000) invalid("HEIF exceeds source pixel budget");
    if (heif_image_handle_has_alpha_channel(primary)) unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,"HDR source must be opaque");
    file.info.version=1; file.info.struct_size=sizeof(file.info); file.info.width=width; file.info.height=height;
    file.info.container=SONY2FUJI_HDR_CONTAINER_HEIF; file.info.orientation=orientation(file.context.get(),primary);
    const bool iso=findISO(file);
    const int count=heif_image_handle_get_number_of_auxiliary_images(primary,LIBHEIF_AUX_IMAGE_FILTER_OMIT_ALPHA|LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH);
    if (count<0 || count>32) invalid("Invalid HEIF auxiliary image count");
    std::array<heif_item_id,32> ids{};
    heif_image_handle_get_list_of_auxiliary_image_IDs(primary,LIBHEIF_AUX_IMAGE_FILTER_OMIT_ALPHA|LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH,ids.data(),count);
    for (int i=0;i<count;++i) {
        heif_image_handle* aux=nullptr; checked(heif_image_handle_get_auxiliary_image_handle(primary,ids[i],&aux)); Handle owner(aux,heif_image_handle_release);
        const char* type=nullptr; checked(heif_image_handle_get_auxiliary_type(aux,&type));
        const bool apple=type && std::strcmp(type,"urn:com:apple:photo:2020:aux:hdrgainmap")==0;
        heif_image_handle_release_auxiliary_type(aux,&type);
        if (apple && !iso) { if (file.gain) invalid("Ambiguous Apple gain maps"); file.gain=std::move(owner); }
    }
    if (!file.gain) {
        const auto* begin=static_cast<const uint8_t*>(data);
        for (const auto* marker:{"urn:iso:std:iso:ts:21496:-1","urn:com:apple:photo:2020:aux:hdrgainmap","tmap"})
            if (std::search(begin,begin+size,marker,marker+std::strlen(marker))!=begin+size)
                unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,"Unsupported HEIF gain-map association");
        unsupported(SONY2FUJI_HDR_REASON_NOT_HDR,"HEIF contains no HDR gain map");
    }
    const int mapWidth=heif_image_handle_get_ispe_width(file.gain.get()),mapHeight=heif_image_handle_get_ispe_height(file.gain.get());
    if (mapWidth<=0 || mapHeight<=0 || uint64_t(mapWidth)*mapHeight>128000000) invalid("Invalid Apple gain-map dimensions");
    file.exif=exif(primary);
    if (!iso) {
        const float xmpHeadroom=appleMetadata(file.gain.get());
        file.info.content_headroom=xmpHeadroom ? xmpHeadroom : appleHeadroom(file.exif.data(),file.exif.size());
        file.info.protocol=SONY2FUJI_HDR_PROTOCOL_APPLE;
    }
    file.info.headroom_kind=SONY2FUJI_HDR_HEADROOM_DECLARED;
    file.icc=heifRGBProfile(primary);
    file.info.color_description=iccColorDescription(file.icc.data(),file.icc.size());
    if (!file.info.color_description) unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,"Unsupported HEIF RGB profile");
    if (iso) {
        if(file.iso->use_base_cg)file.gainColor=file.info.color_description;
        else {const auto alternate=heifItemRGBProfile(data,size,file.toneMapItem);file.gainColor=iccColorDescription(alternate.data(),alternate.size());}
        if (!file.gainColor) unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,"ISO gain map has no supported alternate gamut");
    }
    return file;
}
Image decode(const heif_image_handle* handle,bool mono,uint32_t longEdge) {
    auto* options=heif_decoding_options_alloc(); if (!options) throw std::bad_alloc();
    const auto owner=std::unique_ptr<heif_decoding_options,decltype(&heif_decoding_options_free)>(options,heif_decoding_options_free);
    options->ignore_transformations=0; options->strict_decoding=1; options->convert_hdr_to_8bit=0;
    heif_image* decoded=nullptr;
    checked(heif_decode_image(handle,&decoded,mono ? heif_colorspace_monochrome : heif_colorspace_RGB,
        mono ? heif_chroma_monochrome : heif_chroma_interleaved_RRGGBB_LE,options));
    Image result(decoded,heif_image_release);
    const auto channel=mono ? heif_channel_Y : heif_channel_interleaved;
    const int width=heif_image_get_width(decoded,channel),height=heif_image_get_height(decoded,channel);
    if (width<=0 || height<=0) invalid("Invalid decoded HEIF canvas");
    if (longEdge && uint32_t(std::max(width,height))>longEdge) {
        const double scale=double(longEdge)/std::max(width,height); heif_image* scaled=nullptr;
        checked(heif_image_scale_image(decoded,&scaled,std::max(1,int(std::lround(width*scale))),std::max(1,int(std::lround(height*scale))),nullptr));
        result.reset(scaled);
    }
    return result;
}
}

sony2fuji_hdr_source_info_v1 probeHEIF(const void* data,size_t size) { return open(data,size).info; }
std::vector<uint8_t> heifExif(const void* data,size_t size) { return open(data,size).exif; }
DecodedImage decodeHEIF(const void* data,size_t size,uint32_t edge) {
    auto file=open(data,size);
    // HEVC 仍完整解码两个 item；不能按缩小输出或只按 primary 估算原图和参考帧。
    const uint64_t nativePixels=uint64_t(file.info.width)*file.info.height;
    const uint64_t gainPixels=uint64_t(heif_image_handle_get_ispe_width(file.gain.get()))*heif_image_handle_get_ispe_height(file.gain.get());
    const double scale=edge && std::max(file.info.width,file.info.height)>edge ? double(edge)/std::max(file.info.width,file.info.height) : 1;
    const uint64_t outputPixels=uint64_t(std::max(1l,std::lround(file.info.width*scale)))*std::max(1l,std::lround(file.info.height*scale));
    admitMemory((nativePixels+gainPixels)*16+outputPixels*48);
    heif_colorspace gainSpace;heif_chroma gainChroma;
    checked(heif_image_handle_get_preferred_decoding_colorspace(file.gain.get(),&gainSpace,&gainChroma));
    const bool mono=!file.iso || gainSpace==heif_colorspace_monochrome;
    auto base=decode(file.primary.get(),false,edge); auto map=decode(file.gain.get(),mono,edge);
    const int width=heif_image_get_width(base.get(),heif_channel_interleaved),height=heif_image_get_height(base.get(),heif_channel_interleaved);
    const auto mapChannel=mono ? heif_channel_Y : heif_channel_interleaved;
    const int mapWidth=heif_image_get_width(map.get(),mapChannel),mapHeight=heif_image_get_height(map.get(),mapChannel);
    const int bits=heif_image_get_bits_per_pixel_range(base.get(),heif_channel_interleaved);
    const int mapBits=heif_image_get_bits_per_pixel_range(map.get(),mapChannel);
    if (bits<8 || bits>16 || mapBits<8 || mapBits>16 || (!file.iso && mapBits!=8)) invalid("Unsupported HEIF sample depth");
    int stride=0,mapStride=0; const auto* pixels=heif_image_get_plane_readonly(base.get(),heif_channel_interleaved,&stride);
    const auto* gain=heif_image_get_plane_readonly(map.get(),mapChannel,&mapStride);
    if (!pixels || !gain || stride<int64_t(width)*6 || mapStride<int64_t(mapWidth)*(mono ? (mapBits>8 ? 2 : 1) : 6)) invalid("Invalid HEIF pixel storage");
    DecodedImage output; output.info=file.info; output.pixels.sdr=ImageData(width,height);
    auto profile=cmsOpenProfileFromMem(file.icc.data(),uint32_t(file.icc.size()));
    const cmsCIExyY white{.3127,.3290,1}; const cmsCIExyYTRIPLE primaries{{.64,.33,1},{.3,.6,1},{.15,.06,1}};
    auto* curve=cmsBuildGamma(nullptr,1); cmsToneCurve* curves[]={curve,curve,curve};
    auto linear=curve ? cmsCreateRGBProfile(&white,&primaries,curves) : nullptr;
    auto transform=profile && linear ? cmsCreateTransform(profile,TYPE_RGB_FLT,linear,TYPE_RGB_FLT,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE) : nullptr;
    if (curve) cmsFreeToneCurve(curve); if (profile) cmsCloseProfile(profile); if (linear) cmsCloseProfile(linear);
    if (!transform) unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,"Cannot convert HEIF ICC profile");
    const auto cleanup=std::unique_ptr<std::remove_pointer_t<cmsHTRANSFORM>,decltype(&cmsDeleteTransform)>(transform,cmsDeleteTransform);
    const float maximum=float((1u<<bits)-1);
#if defined(_OPENMP)
    #pragma omp parallel for schedule(static)
#endif
    for (int y=0;y<height;++y) {
        for (int x=0;x<width;++x) {
            const auto* p=pixels+size_t(y)*stride+size_t(x)*6;
            output.pixels.sdr.at(x,y)={float(uint16_t(p[0])|uint16_t(p[1])<<8)/maximum,
                float(uint16_t(p[2])|uint16_t(p[3])<<8)/maximum,float(uint16_t(p[4])|uint16_t(p[5])<<8)/maximum};
        }
        cmsDoTransform(transform,&output.pixels.sdr.at(0,y),&output.pixels.sdr.at(0,y),width);
    }
    output.pixels.hdr=ImageData(width,height);
    std::unique_ptr<ultrahdr::GainLUT> lookup;
    ultrahdr::ColorTransformFn toApplication=nullptr,toCanonical=nullptr;
    if (file.iso) {
        lookup=std::make_unique<ultrahdr::GainLUT>(file.iso.get());
        const auto gamut=static_cast<uhdr_color_gamut_t>((file.iso->use_base_cg ? file.info.color_description : file.gainColor)-1);
        toApplication=ultrahdr::getGamutConversionFn(gamut,UHDR_CG_BT_709);
        toCanonical=ultrahdr::getGamutConversionFn(UHDR_CG_BT_709,gamut);
        if (!toApplication || !toCanonical) unsupported(SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,"Unsupported ISO application gamut");
    }
    std::array<float,256> inverse709{};
    for(size_t i=0;i<inverse709.size();++i) {const float v=float(i)/255;inverse709[i]=v<.081f ? v/4.5f : std::pow((v+.099f)/1.099f,1/.45f);}
    auto sample=[&](int x,int y,int channel) {
        if (file.iso) {
            const auto* p=gain+size_t(y)*mapStride+size_t(x)*(mono ? (mapBits>8 ? 2 : 1) : 6)+(mono ? 0 : channel*2);
            const auto sample=mono && mapBits<=8 ? uint16_t(p[0]) : uint16_t(p[0])|uint16_t(p[1])<<8;
            return float(sample)/float((1u<<mapBits)-1);
        }
        return inverse709[gain[size_t(y)*mapStride+x]];
    };
    std::atomic<bool> invalidPixels{false};
#if defined(_OPENMP)
    #pragma omp parallel for schedule(static)
#endif
    for (int y=0;y<height;++y) for (int x=0;x<width;++x) {
        const float sx=width>1 ? float(x)*(mapWidth-1)/(width-1) : (mapWidth-1)*.5f;
        const float sy=height>1 ? float(y)*(mapHeight-1)/(height-1) : (mapHeight-1)*.5f;
        const int x0=int(sx),y0=int(sy),x1=std::min(x0+1,mapWidth-1),y1=std::min(y0+1,mapHeight-1);
        const float fx=sx-x0,fy=sy-y0;
        auto interpolate=[&](int channel) { const float a=sample(x0,y0,channel),b=sample(x1,y0,channel),c=sample(x0,y1,channel),d=sample(x1,y1,channel); return (a+(b-a)*fx)*(1-fy)+(c+(d-c)*fx)*fy; };
        const auto p=output.pixels.sdr.at(x,y);
        if (file.iso) {
            const auto result=toCanonical(ultrahdr::applyGainLUT(toApplication({p.r,p.g,p.b}),
                ultrahdr::Color{interpolate(0),interpolate(1),interpolate(2)},*lookup,file.iso.get()));
            if (!std::isfinite(result.r) || !std::isfinite(result.g) || !std::isfinite(result.b))invalidPixels.store(true,std::memory_order_relaxed);
            output.pixels.hdr.at(x,y)={result.r,result.g,result.b}; continue;
        }
        const float boost=1+(file.info.content_headroom-1)*interpolate(0);
        if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b) || !std::isfinite(boost))invalidPixels.store(true,std::memory_order_relaxed);
        output.pixels.hdr.at(x,y)={p.r*boost,p.g*boost,p.b*boost};
    }
    if(invalidPixels.load())invalid("HEIF contains nonfinite samples");
    return output;
}
} // namespace sony2fuji::hdr
