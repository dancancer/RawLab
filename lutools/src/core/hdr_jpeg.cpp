#include "core/hdr_jpeg.h"
#include "core/hdr_half.h"
#include "core/hdr_resample.h"
#include "platform/hdr_image.h"
#include <ultrahdr_api.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <csetjmp>
#include <cstdlib>
#include <jpeglib.h>
#include <ultrahdr/jpegr.h>
#include <ultrahdr/jpegdecoderhelper.h>
#include <ultrahdr/icc.h>
#include <cfloat>
#include <cstring>

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
struct JPEGError { jpeg_error_mgr manager{}; std::jmp_buf jump; };
struct ScaledJPEG {
    uhdr_raw_image_t image{};
    std::array<std::vector<uint8_t>,3> planes;
};
ScaledJPEG scaledJPEG(const void* bytes,size_t size,uint32_t longEdge,bool rawYUV) {
    struct State {
        jpeg_decompress_struct codec{}; JPEGError error;
        ScaledJPEG output;
        ~State() { jpeg_destroy_decompress(&codec); }
    };
    auto state=std::make_unique<State>(); auto& c=state->codec;
    c.err=jpeg_std_error(&state->error.manager);
    state->error.manager.error_exit=[](j_common_ptr p) { std::longjmp(reinterpret_cast<JPEGError*>(p->err)->jump,1); };
    if (setjmp(state->error.jump)) throw std::runtime_error("Cannot decode scaled JPEG planes");
    jpeg_create_decompress(&c); jpeg_mem_src(&c,static_cast<const unsigned char*>(bytes),size);
    jpeg_read_header(&c,TRUE);
    if (!c.image_width || !c.image_height || uint64_t(c.image_width)*c.image_height>128000000)
        throw std::invalid_argument("JPEG dimensions exceed source budget");
    if (longEdge && std::max(c.image_width,c.image_height)>longEdge) {
        c.scale_num=std::min(8u,std::max(1u,uint32_t(std::ceil(double(longEdge)*8/std::max(c.image_width,c.image_height)))));
        c.scale_denom=8;
    }
    const bool yuv=rawYUV && c.jpeg_color_space==JCS_YCbCr;
    c.out_color_space=yuv ? JCS_YCbCr : c.num_components==1 ? JCS_GRAYSCALE : JCS_RGB;
    c.raw_data_out=yuv; c.dct_method=JDCT_ISLOW;
    jpeg_calc_output_dimensions(&c);
    // Progressive/multi-scan JPEG 先保留原尺寸 DCT 系数，即使输出已缩小。
    const uint64_t coefficients=jpeg_has_multiple_scans(&c) ? uint64_t(c.image_width)*c.image_height*c.num_components*2+262144 : 0;
    admitMemory(uint64_t(c.output_width)*c.output_height*24+coefficients);
    jpeg_start_decompress(&c);
    auto& output=state->output; auto& image=output.image;
    image.w=c.output_width; image.h=c.output_height; image.ct=UHDR_CT_SRGB; image.range=UHDR_CR_FULL_RANGE;
    if (yuv) {
        const unsigned cw=c.comp_info[1].downsampled_width,ch=c.comp_info[1].downsampled_height;
        const std::array<std::array<unsigned,3>,6> formats={{{1,1,UHDR_IMG_FMT_24bppYCbCr444},{2,1,UHDR_IMG_FMT_16bppYCbCr422},
            {2,2,UHDR_IMG_FMT_12bppYCbCr420},{1,2,UHDR_IMG_FMT_16bppYCbCr440},
            {4,1,UHDR_IMG_FMT_12bppYCbCr411},{4,2,UHDR_IMG_FMT_10bppYCbCr410}}};
        image.fmt=UHDR_IMG_FMT_UNSPECIFIED;
        for (const auto& f:formats) if ((image.w+f[0]-1)/f[0]==cw && (image.h+f[1]-1)/f[1]==ch)
            image.fmt=static_cast<uhdr_img_fmt_t>(f[2]);
        if (image.fmt==UHDR_IMG_FMT_UNSPECIFIED || c.num_components!=3) throw std::runtime_error("Unsupported scaled JPEG subsampling");
        std::array<unsigned,3> blockRows{};
        for (int i=0;i<3;++i) {
            const auto& component=c.comp_info[i];
#if JPEG_LIB_VERSION >= 70
            image.stride[i]=component.width_in_blocks*component.DCT_h_scaled_size;
            blockRows[i]=component.v_samp_factor*component.DCT_v_scaled_size;
#else
            image.stride[i]=component.width_in_blocks*component.DCT_scaled_size;
            blockRows[i]=component.v_samp_factor*component.DCT_scaled_size;
#endif
            if (blockRows[i]>32) throw std::runtime_error("Invalid JPEG MCU rows");
            output.planes[i].resize(size_t(image.stride[i])*blockRows[i]*c.total_iMCU_rows);
            image.planes[i]=output.planes[i].data();
        }
        unsigned block=0;
        while (c.output_scanline<c.output_height) {
            JSAMPROW rows[3][32]{}; JSAMPARRAY planes[]={rows[0],rows[1],rows[2]};
            for (int i=0;i<3;++i) for (unsigned y=0;y<blockRows[i];++y)
                rows[i][y]=output.planes[i].data()+size_t(block*blockRows[i]+y)*image.stride[i];
#if JPEG_LIB_VERSION >= 70
            const unsigned lines=c.max_v_samp_factor*c.min_DCT_v_scaled_size;
#else
            const unsigned lines=c.max_v_samp_factor*c.min_DCT_scaled_size;
#endif
            if (!jpeg_read_raw_data(&c,planes,lines)) throw std::runtime_error("Truncated JPEG planes");
            ++block;
        }
    } else {
        image.fmt=c.output_components==1 ? UHDR_IMG_FMT_8bppYCbCr400 : UHDR_IMG_FMT_24bppRGB888;
        image.stride[0]=image.w;
        const size_t row=size_t(image.w)*c.output_components;
        output.planes[0].resize(row*image.h); image.planes[0]=output.planes[0].data();
        while (c.output_scanline<c.output_height) {
            JSAMPROW line=output.planes[0].data()+size_t(c.output_scanline)*row;
            if (!jpeg_read_scanlines(&c,&line,1)) throw std::runtime_error("Truncated JPEG scanline");
        }
    }
    jpeg_finish_decompress(&c); return std::move(output);
}
std::pair<uint32_t,uint32_t> targetSize(int width,int height,uint32_t edge) {
    const double scale=edge && uint32_t(std::max(width,height))>edge ? double(edge)/std::max(width,height) : 1;
    return {std::max(1u,uint32_t(std::lround(width*scale))),std::max(1u,uint32_t(std::lround(height*scale)))};
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
    return {uint32_t(width),uint32_t(height),0,std::max({1.0f,metadata->max_content_boost[0],metadata->max_content_boost[1],metadata->max_content_boost[2]})};
}

std::vector<uint8_t> jpegGainMapXMP(const void* data,size_t size) {
    auto dec=decoder(data,size,false);const auto* map=uhdr_dec_get_gainmap_image(dec.get());
    if(!map)throw std::runtime_error("Missing Apple JPEG gain map");
    ultrahdr::JpegDecoderHelper parser;checked(parser.parseImage(map->data,map->data_sz));
    const auto* bytes=static_cast<const uint8_t*>(parser.getXMPPtr());size_t count=parser.getXMPSize();
    const char prefix[]="http://ns.adobe.com/xap/1.0/";
    if(bytes && count>=sizeof(prefix) && !std::memcmp(bytes,prefix,sizeof(prefix))) {bytes+=sizeof(prefix);count-=sizeof(prefix);}
    if(!bytes || !count)throw std::runtime_error("Missing Apple JPEG XMP");return {bytes,bytes+count};
}

ImageData decodeAppleJPEG(const void* data,size_t size,float headroom,uint32_t longEdge) {
    auto dec=decoder(data,size,false);const auto* map=uhdr_dec_get_gainmap_image(dec.get());
    if(!map || !std::isfinite(headroom) || headroom<=1)throw std::invalid_argument("Invalid Apple JPEG gain map");
    auto encoded=scaledJPEG(map->data,map->data_sz,longEdge,false);
    if(encoded.image.fmt!=UHDR_IMG_FMT_8bppYCbCr400)throw std::runtime_error("Apple JPEG gain map must be monochrome");
    ImageData gains(encoded.image.w,encoded.image.h);const auto* bytes=static_cast<const uint8_t*>(encoded.image.planes[0]);
    std::array<float,256> inverse709{};
    for(size_t i=0;i<inverse709.size();++i){const float v=float(i)/255;inverse709[i]=v<.081f ? v/4.5f : std::pow((v+.099f)/1.099f,1/.45f);}
    for(unsigned y=0;y<encoded.image.h;++y)for(unsigned x=0;x<encoded.image.w;++x) {
        const float linear=inverse709[bytes[size_t(y)*encoded.image.stride[0]+x]];
        gains.at(x,y)={linear,linear,linear};
    }
    auto output=decodeSDRJPEG(data,size,longEdge);
    if(gains.width!=output.width || gains.height!=output.height)gains=resample(gains,output.width,output.height);
    for(size_t i=0;i<output.pixels.size();++i) {
        const float boost=1+(headroom-1)*gains.pixels[i].r;auto& p=output.pixels[i];p={p.r*boost,p.g*boost,p.b*boost};
    }
    return output;
}

ImageData decodeJPEG(const void* data,size_t size,uint32_t longEdge) {
    auto dec=decoder(data,size,true);
    const int w=uhdr_dec_get_image_width(dec.get()),h=uhdr_dec_get_image_height(dec.get());
    if (w<=0 || h<=0 || uint64_t(w)*h>128000000) throw std::invalid_argument("Ultra HDR dimensions exceed source budget");
    const int gainWidth=uhdr_dec_get_gainmap_width(dec.get()),gainHeight=uhdr_dec_get_gainmap_height(dec.get());
    if (gainWidth<=0 || gainHeight<=0 || uint64_t(gainWidth)*gainHeight>128000000)
        throw std::invalid_argument("Ultra HDR gain map exceeds source budget");
    // 上游 FINAL 路径完整解码底图与 gain map；辅助图可以大于底图。
    admitMemory(uint64_t(w)*h*48+uint64_t(gainWidth)*gainHeight*24);
    if (longEdge && uint32_t(std::max(w,h))>longEdge) {
        const double scale=double(longEdge)/std::max(w,h);
        checked(uhdr_add_effect_resize(dec.get(),std::max(1,int(std::lround(w*scale))),std::max(1,int(std::lround(h*scale)))));
    }
    checked(uhdr_decode(dec.get())); const auto* image=uhdr_get_decoded_image(dec.get());
    if (!image || !image->planes[0] || image->fmt!=UHDR_IMG_FMT_64bppRGBAHalfFloat || image->stride[0]<image->w)
        throw std::runtime_error("Invalid Ultra HDR decoded storage");
    ImageData output(image->w,image->h);
    const auto* pixels=static_cast<const uint16_t*>(image->planes[0]);
    for (unsigned y=0;y<image->h;++y) for (unsigned x=0;x<image->w;++x) {
        const auto* p=pixels+(y*image->stride[0]+x)*4;
        output.at(x,y)=toSRGB({halfToFloat(p[0]),halfToFloat(p[1]),halfToFloat(p[2])},image->cg);
    }
    return output;
}

ImageData decodeSDRJPEG(const void* data,size_t size,uint32_t longEdge) {
    auto dec=decoder(data,size,false);
    const int w=uhdr_dec_get_image_width(dec.get()),h=uhdr_dec_get_image_height(dec.get());
    if (w<=0 || h<=0 || uint64_t(w)*h>128000000) throw std::invalid_argument("Ultra HDR dimensions exceed source budget");
    const auto* base=uhdr_dec_get_base_image(dec.get()); const auto* icc=uhdr_dec_get_icc(dec.get());
    if (!base || !icc) throw std::runtime_error("Missing HDR JPEG base or RGB profile");
    auto scaled=scaledJPEG(base->data,base->data_sz,longEdge,false); const auto* image=&scaled.image;
    const auto gamut=ultrahdr::IccHelper::readIccColorGamut(icc->data,icc->data_sz);
    if (image->fmt!=UHDR_IMG_FMT_24bppRGB888) throw std::runtime_error("HDR JPEG base must be RGB");
    std::array<float,256> linear{};
    for(size_t i=0;i<linear.size();++i){const float v=float(i)/255;linear[i]=v<=.04045f ? v/12.92f : std::pow((v+.055f)/1.055f,2.4f);}
    ImageData output(image->w,image->h);
    const auto* pixels=static_cast<const uint8_t*>(image->planes[0]);
#if defined(_OPENMP)
    #pragma omp parallel for schedule(static)
#endif
    for (int y=0;y<int(image->h);++y) for (unsigned x=0;x<image->w;++x) {
        const auto* p=pixels+(y*image->stride[0]+x)*3;
        output.at(x,y)=toSRGB({linear[p[0]],linear[p[1]],linear[p[2]]},gamut);
    }
    const auto [width,height]=targetSize(w,h,longEdge);
    return width==uint32_t(output.width) && height==uint32_t(output.height) ? std::move(output) : resample(output,width,height);
}

ImageData decodeJPEGPreview(const void* data,size_t size,uint32_t longEdge) {
    auto dec=decoder(data,size,false);
    const auto* base=uhdr_dec_get_base_image(dec.get()); const auto* map=uhdr_dec_get_gainmap_image(dec.get());
    const auto* icc=uhdr_dec_get_icc(dec.get()); auto* description=uhdr_dec_get_gainmap_metadata(dec.get());
    if (!base || !map || !icc || !description) throw std::runtime_error("Incomplete HDR JPEG planes");
    auto sdr=scaledJPEG(base->data,base->data_sz,longEdge,true);
    auto gain=scaledJPEG(map->data,map->data_sz,longEdge,false);
    sdr.image.cg=ultrahdr::IccHelper::readIccColorGamut(icc->data,icc->data_sz);
    ultrahdr::JpegDecoderHelper parser; checked(parser.parseImage(map->data,map->data_sz));
    gain.image.cg=parser.getICCSize() ? ultrahdr::IccHelper::readIccColorGamut(const_cast<void*>(static_cast<const void*>(parser.getICCPtr())),parser.getICCSize()) : sdr.image.cg;
    if (sdr.image.cg==UHDR_CG_UNSPECIFIED || gain.image.cg==UHDR_CG_UNSPECIFIED || (!description->use_base_cg && !parser.getICCSize()))
        throw Error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,SONY2FUJI_HDR_FIELD_SOURCE,"Missing gain-map application gamut");
    ultrahdr::uhdr_gainmap_metadata_ext_t metadata(*description,"1.0");
    ultrahdr::uhdr_raw_image_ext_t output(UHDR_IMG_FMT_64bppRGBAHalfFloat,UHDR_CG_UNSPECIFIED,
        UHDR_CT_LINEAR,UHDR_CR_FULL_RANGE,sdr.image.w,sdr.image.h,64);
    ultrahdr::JpegR processor(nullptr);
    checked(processor.applyGainMap(&sdr.image,&gain.image,&metadata,UHDR_CT_LINEAR,UHDR_IMG_FMT_64bppRGBAHalfFloat,FLT_MAX,&output));
    ImageData linear(output.w,output.h); const auto* pixels=static_cast<const uint16_t*>(output.planes[0]);
    for (unsigned y=0;y<output.h;++y) for (unsigned x=0;x<output.w;++x) {
        const auto* p=pixels+(size_t(y)*output.stride[0]+x)*4;
        linear.at(x,y)=toSRGB({halfToFloat(p[0]),halfToFloat(p[1]),halfToFloat(p[2])},output.cg);
    }
    const auto [width,height]=targetSize(uhdr_dec_get_image_width(dec.get()),uhdr_dec_get_image_height(dec.get()),longEdge);
    return width==uint32_t(linear.width) && height==uint32_t(linear.height) ? std::move(linear) : resample(linear,width,height);
}

std::vector<uint8_t> encodeSDRJPEG(const ImageData& image,uint32_t quality) {
    if (image.width<=0 || image.height<=0 || image.width>65500 || image.height>65500 || quality<1 || quality>100)
        throw std::invalid_argument("Invalid SDR JPEG dimensions or quality");
    struct State {
        jpeg_compress_struct codec{}; JPEGError error;
        unsigned char* bytes=nullptr; unsigned long size=0;
        std::vector<uint8_t> row;
        ~State() { jpeg_destroy_compress(&codec); std::free(bytes); }
    };
    auto state=std::make_unique<State>(); state->row.resize(size_t(image.width)*3);
    state->codec.err=jpeg_std_error(&state->error.manager);
    state->error.manager.error_exit=[](j_common_ptr codec) { std::longjmp(reinterpret_cast<JPEGError*>(codec->err)->jump,1); };
    if (setjmp(state->error.jump)) throw std::runtime_error("SDR JPEG encoding failed");
    jpeg_create_compress(&state->codec); jpeg_mem_dest(&state->codec,&state->bytes,&state->size);
    state->codec.image_width=image.width; state->codec.image_height=image.height;
    state->codec.input_components=3; state->codec.in_color_space=JCS_RGB;
    jpeg_set_defaults(&state->codec); jpeg_set_quality(&state->codec,int(quality),TRUE);
    jpeg_start_compress(&state->codec,TRUE);
    while (state->codec.next_scanline<state->codec.image_height) {
        const int y=int(state->codec.next_scanline);
        for (int x=0;x<image.width;++x) {
            const auto& p=image.at(x,y); const float values[]={p.r,p.g,p.b};
            for (int c=0;c<3;++c) state->row[size_t(x)*3+c]=uint8_t(std::lround(srgb(values[c])*255));
        }
        JSAMPROW row=state->row.data(); jpeg_write_scanlines(&state->codec,&row,1);
    }
    jpeg_finish_compress(&state->codec);
    return {state->bytes,state->bytes+state->size};
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
    std::vector<uint16_t> hdr(size_t(width)*height*4);
    std::vector<uint8_t> sdr(hdr.size());
    float headroom=1;
    for (size_t i=0;i<image.hdr.pixels.size();++i) {
        const RGB h=outputRGB(image.hdr.pixels[i],baseColor),s=outputRGB(image.sdr.pixels[i],baseColor);
        const float hc[]={h.r,h.g,h.b},sc[]={s.r,s.g,s.b};
        for (size_t c=0;c<3;++c) {
            if (!std::isfinite(hc[c]) || std::abs(hc[c])>65504 || !std::isfinite(sc[c]))
                throw std::overflow_error("HDR JPEG exceeds finite half-float codec range");
            // 输出色域映射只在 writer 中进行，不回写扩展线性工作图。
            hdr[i*4+c]=floatToHalf(std::max(0.0f,hc[c]));
            sdr[i*4+c]=uint8_t(std::lround(srgb(sc[c])*255));
            headroom=std::max(headroom,hc[c]);
        }
        hdr[i*4+3]=floatToHalf(1); sdr[i*4+3]=255;
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
