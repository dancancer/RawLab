#include "core/hdr_jpeg.h"
#include "platform/hdr_image.h"
#include <ultrahdr_api.h>
#include <algorithm>
#include <cmath>
#include <memory>

namespace sony2fuji::hdr {
namespace {
using Decoder=std::unique_ptr<uhdr_codec_private_t,decltype(&uhdr_release_decoder)>;
using Encoder=std::unique_ptr<uhdr_codec_private_t,decltype(&uhdr_release_encoder)>;
void checked(uhdr_error_info_t result) {
    if (result.error_code!=UHDR_CODEC_OK)
        throw Error(result.error_code==UHDR_CODEC_MEM_ERROR ? SONY2FUJI_STATUS_OUT_OF_MEMORY : SONY2FUJI_STATUS_PROCESSING_ERROR,
            result.error_code==UHDR_CODEC_MEM_ERROR ? SONY2FUJI_HDR_REASON_OUT_OF_MEMORY : SONY2FUJI_HDR_REASON_MALFORMED_AUX,
            SONY2FUJI_HDR_FIELD_SOURCE,result.has_detail ? result.detail : "Ultra HDR codec rejected the image");
}
uhdr_compressed_image_t compressed(const void* bytes,size_t size) {
    uhdr_compressed_image_t image{};
    image.data=const_cast<void*>(bytes); image.data_sz=image.capacity=size;
    image.cg=UHDR_CG_UNSPECIFIED; image.ct=UHDR_CT_UNSPECIFIED; image.range=UHDR_CR_UNSPECIFIED;
    return image;
}
Decoder decoder(const void* bytes,size_t size,bool linear) {
    Decoder result(uhdr_create_decoder(),uhdr_release_decoder);
    if (!result) throw std::bad_alloc();
    auto image=compressed(bytes,size); checked(uhdr_dec_set_image(result.get(),&image));
    if (linear) {
        checked(uhdr_dec_set_out_color_transfer(result.get(),UHDR_CT_LINEAR));
        checked(uhdr_dec_set_out_img_format(result.get(),UHDR_IMG_FMT_64bppRGBAHalfFloat));
    }
    checked(uhdr_dec_probe(result.get())); return result;
}
RGB toSRGB(RGB p,uhdr_color_gamut_t gamut) {
    if (gamut==UHDR_CG_BT_709) return p;
    if (gamut==UHDR_CG_DISPLAY_P3) return {
        1.2247453f*p.r-.2249044f*p.g-.0000000f*p.b,
        -.0420581f*p.r+1.0420810f*p.g+.0000000f*p.b,
        -.0196423f*p.r-.0786549f*p.g+1.0985372f*p.b};
    if (gamut==UHDR_CG_BT_2100) return {
        1.6604910f*p.r-.5876411f*p.g-.0728499f*p.b,
        -.1245505f*p.r+1.1328999f*p.g-.0083494f*p.b,
        -.0181508f*p.r-.1005789f*p.g+1.1187297f*p.b};
    throw Error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,SONY2FUJI_HDR_FIELD_SOURCE,
        "Unknown Ultra HDR output gamut");
}
RGB outputRGB(RGB p,uint32_t color) {
    if (color==SONY2FUJI_HDR_COLOR_DISPLAY_P3) return {
        .8225929f*p.r+.1775339f*p.g,
        .0331995f*p.r+.9667835f*p.g,
        .0170854f*p.r+.0723957f*p.g+.9103015f*p.b};
    return p;
}
float srgb(float value) {
    value=std::clamp(value,0.0f,1.0f);
    return value<=.0031308f ? 12.92f*value : 1.055f*std::pow(value,1/2.4f)-.055f;
}
std::vector<uint8_t> stream(uhdr_codec_private_t* enc) {
    checked(uhdr_encode(enc)); const auto* data=uhdr_get_encoded_stream(enc);
    if (!data || !data->data || !data->data_sz) throw std::runtime_error("Empty Ultra HDR output");
    const auto* bytes=static_cast<const uint8_t*>(data->data);
    return {bytes,bytes+data->data_sz};
}

void validateDualMetadata(const void* bytes,size_t size,const uhdr_gainmap_metadata_t& iso) {
    const std::string isoName="urn:iso:std:iso:ts:21496:-1",xmpName="http://ns.adobe.com/hdr-gain-map/1.0/";
    const auto* begin=static_cast<const uint8_t*>(bytes); const auto* end=begin+size;
    if (std::search(begin,end,isoName.begin(),isoName.end())==end ||
        std::search(begin,end,xmpName.begin(),xmpName.end())==end) return;
    // 上游优先 ISO；隐藏同长 namespace 才能独立解析 XMP，保留 JPEG/MPF 字节偏移。
    std::vector<uint8_t> xmpOnly(begin,end);
    for (auto found=std::search(xmpOnly.begin(),xmpOnly.end(),isoName.begin(),isoName.end());found!=xmpOnly.end();
         found=std::search(found+isoName.size(),xmpOnly.end(),isoName.begin(),isoName.end()))
        std::fill_n(found,isoName.size(),'x');
    auto forced=decoder(xmpOnly.data(),xmpOnly.size(),false);
    const auto* xmp=uhdr_dec_get_gainmap_metadata(forced.get());
    auto same=[](float a,float b) { return std::isfinite(a) && std::isfinite(b) && std::abs(a-b)<=1e-4f*std::max({1.0f,std::abs(a),std::abs(b)}); };
    bool consistent=xmp && xmp->use_base_cg==iso.use_base_cg && same(xmp->hdr_capacity_min,iso.hdr_capacity_min) &&
        same(xmp->hdr_capacity_max,iso.hdr_capacity_max);
    for (int c=0;xmp && c<3;++c)
        consistent &= same(xmp->min_content_boost[c],iso.min_content_boost[c]) && same(xmp->max_content_boost[c],iso.max_content_boost[c]) &&
            same(xmp->gamma[c],iso.gamma[c]) && same(xmp->offset_sdr[c],iso.offset_sdr[c]) && same(xmp->offset_hdr[c],iso.offset_hdr[c]);
    if (!consistent) throw Error(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_MALFORMED_AUX,
        SONY2FUJI_HDR_FIELD_SOURCE,"Conflicting ISO and XMP gain-map descriptions");
}
} // namespace

JPEGInfo probeJPEG(const void* data,size_t size) {
    auto dec=decoder(data,size,false);
    const int width=uhdr_dec_get_image_width(dec.get()),height=uhdr_dec_get_image_height(dec.get());
    const int mapWidth=uhdr_dec_get_gainmap_width(dec.get()),mapHeight=uhdr_dec_get_gainmap_height(dec.get());
    auto* metadata=uhdr_dec_get_gainmap_metadata(dec.get());
    if (width<=0 || height<=0 || uint64_t(width)*height>128000000 ||
        mapWidth<=0 || mapHeight<=0 || uint64_t(mapWidth)*mapHeight>128000000 || !metadata ||
        !std::isfinite(metadata->hdr_capacity_max) || metadata->hdr_capacity_max<1)
        throw Error(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_MALFORMED_AUX,SONY2FUJI_HDR_FIELD_SOURCE,
            "Invalid Ultra HDR dimensions or headroom");
    validateDualMetadata(data,size,*metadata);
    return {uint32_t(width),uint32_t(height),0,metadata->hdr_capacity_max};
}

ImageData decodeJPEG(const void* data,size_t size,uint32_t longEdge) {
    auto dec=decoder(data,size,true);
    const int w=uhdr_dec_get_image_width(dec.get()),h=uhdr_dec_get_image_height(dec.get());
    if (w<=0 || h<=0 || uint64_t(w)*h>128000000) throw std::invalid_argument("Ultra HDR dimensions exceed source budget");
    if (longEdge && uint32_t(std::max(w,h))>longEdge) {
        const double scale=double(longEdge)/std::max(w,h);
        checked(uhdr_add_effect_resize(dec.get(),std::max(1,int(std::lround(w*scale))),std::max(1,int(std::lround(h*scale)))));
    }
    checked(uhdr_decode(dec.get())); const auto* image=uhdr_get_decoded_image(dec.get());
    if (!image || !image->planes[0] || image->fmt!=UHDR_IMG_FMT_64bppRGBAHalfFloat || image->stride[0]<image->w)
        throw std::runtime_error("Invalid Ultra HDR decoded storage");
    ImageData output(image->w,image->h);
    const auto* pixels=static_cast<const _Float16*>(image->planes[0]);
    for (unsigned y=0;y<image->h;++y) for (unsigned x=0;x<image->w;++x) {
        const auto* p=pixels+(y*image->stride[0]+x)*4;
        output.at(x,y)=toSRGB({float(p[0]),float(p[1]),float(p[2])},image->cg);
    }
    return output;
}

std::vector<uint8_t> jpegBase(const void* data,size_t size) {
    auto dec=decoder(data,size,false); const auto* base=uhdr_dec_get_base_image(dec.get());
    if (!base || !base->data || !base->data_sz) throw std::runtime_error("Missing HDR JPEG base");
    const auto* bytes=static_cast<const uint8_t*>(base->data); return {bytes,bytes+base->data_sz};
}

std::vector<uint8_t> replaceJPEGBase(const void* data,size_t size,const void* base,size_t baseSize) {
    auto dec=decoder(data,size,false);
    const auto* gain=uhdr_dec_get_gainmap_image(dec.get());
    auto* metadata=uhdr_dec_get_gainmap_metadata(dec.get());
    if (!gain || !metadata) throw std::runtime_error("Missing HDR JPEG gain map");
    Encoder enc(uhdr_create_encoder(),uhdr_release_encoder); if (!enc) throw std::bad_alloc();
    auto b=compressed(base,baseSize),g=compressed(gain->data,gain->data_sz);
    checked(uhdr_enc_set_compressed_image(enc.get(),&b,UHDR_BASE_IMG));
    checked(uhdr_enc_set_gainmap_image(enc.get(),&g,metadata)); return stream(enc.get());
}

std::vector<uint8_t> encodeJPEG(const HDRImagePair& image,uint32_t quality,uint32_t baseColor) {
    if (quality<1 || quality>100 || (baseColor!=SONY2FUJI_HDR_COLOR_SRGB && baseColor!=SONY2FUJI_HDR_COLOR_DISPLAY_P3))
        throw std::invalid_argument("Invalid HDR JPEG quality or gamut");
    const unsigned width=image.hdr.width,height=image.hdr.height;
    if (width>65500 || height>65500) throw std::invalid_argument("HDR JPEG exceeds codec dimension ceiling");
    std::vector<_Float16> hdr(size_t(width)*height*4);
    std::vector<uint8_t> sdr(hdr.size());
    float headroom=1;
    for (size_t i=0;i<image.hdr.pixels.size();++i) {
        const RGB h=outputRGB(image.hdr.pixels[i],baseColor),s=outputRGB(image.sdr.pixels[i],baseColor);
        const float hc[]={h.r,h.g,h.b},sc[]={s.r,s.g,s.b};
        for (size_t c=0;c<3;++c) {
            if (!std::isfinite(hc[c]) || std::abs(hc[c])>65504 || !std::isfinite(sc[c]))
                throw std::overflow_error("HDR JPEG exceeds finite half-float codec range");
            // 输出色域映射只在 writer 中进行，不回写扩展线性工作图。
            hdr[i*4+c]=static_cast<_Float16>(std::max(0.0f,hc[c]));
            sdr[i*4+c]=uint8_t(std::lround(srgb(sc[c])*255));
            headroom=std::max(headroom,hc[c]);
        }
        hdr[i*4+3]=1; sdr[i*4+3]=255;
    }
    uhdr_raw_image_t h{},s{};
    h.fmt=UHDR_IMG_FMT_64bppRGBAHalfFloat; s.fmt=UHDR_IMG_FMT_32bppRGBA8888;
    h.cg=s.cg=baseColor==SONY2FUJI_HDR_COLOR_DISPLAY_P3 ? UHDR_CG_DISPLAY_P3 : UHDR_CG_BT_709;
    h.ct=UHDR_CT_LINEAR; s.ct=UHDR_CT_SRGB; h.range=s.range=UHDR_CR_FULL_RANGE;
    h.w=s.w=width; h.h=s.h=height; h.stride[0]=s.stride[0]=width; h.planes[0]=hdr.data(); s.planes[0]=sdr.data();
    Encoder enc(uhdr_create_encoder(),uhdr_release_encoder); if (!enc) throw std::bad_alloc();
    checked(uhdr_enc_set_raw_image(enc.get(),&h,UHDR_HDR_IMG)); checked(uhdr_enc_set_raw_image(enc.get(),&s,UHDR_SDR_IMG));
    checked(uhdr_enc_set_quality(enc.get(),quality,UHDR_BASE_IMG)); checked(uhdr_enc_set_quality(enc.get(),quality,UHDR_GAIN_MAP_IMG));
    checked(uhdr_enc_set_using_multi_channel_gainmap(enc.get(),1)); checked(uhdr_enc_set_gainmap_scale_factor(enc.get(),1));
    checked(uhdr_enc_set_preset(enc.get(),UHDR_USAGE_BEST_QUALITY));
    // Ultra HDR 要求 capacity_max > capacity_min；工作图的 measured headroom 仍可为 1。
    // 留出可由 ISO rational 和 XMP 小数共同表达的最小间隔，避免暗片生成非法文件。
    const float capacity=std::max(1.001f,headroom);
    checked(uhdr_enc_set_target_display_peak_brightness(enc.get(),std::min(capacity*203,10000.0f)));
    auto encoded=stream(enc.get());
    // 第二次只封装已生成的 JPEG，更新真实成片容量；不受 setter 的 10000-nit 上限限制。
    auto dec=decoder(encoded.data(),encoded.size(),false);
    auto metadata=*uhdr_dec_get_gainmap_metadata(dec.get()); metadata.hdr_capacity_max=capacity;
    const auto* base=uhdr_dec_get_base_image(dec.get()); const auto* gain=uhdr_dec_get_gainmap_image(dec.get());
    if (!base || !gain) throw std::runtime_error("Missing freshly encoded base or gain map");
    Encoder packed(uhdr_create_encoder(),uhdr_release_encoder); if (!packed) throw std::bad_alloc();
    auto b=compressed(base->data,base->data_sz),g=compressed(gain->data,gain->data_sz);
    checked(uhdr_enc_set_compressed_image(packed.get(),&b,UHDR_BASE_IMG));
    checked(uhdr_enc_set_gainmap_image(packed.get(),&g,&metadata));
    return stream(packed.get());
}
} // namespace sony2fuji::hdr
