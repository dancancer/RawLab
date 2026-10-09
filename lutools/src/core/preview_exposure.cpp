#include "preview_exposure.h"
#include "file_path.h"
#include <libraw/libraw.h>
#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>

#define STB_IMAGE_IMPLEMENTATION
#define STBIDEF static inline
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif
#include "stb_image.h"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

namespace sony2fuji {

float estimatePreviewExposureEV(std::vector<float> raw, std::vector<float> preview, bool* matched) {
    if (matched) *matched=false;
    auto prepare=[](std::vector<float>& values) {
        values.erase(std::remove_if(values.begin(),values.end(),[](float v) {
            return !std::isfinite(v) || v<0;
        }),values.end());
        std::sort(values.begin(),values.end());
    };
    prepare(raw);
    prepare(preview);
    if (raw.size()<64 || preview.size()<64) return 0;
    // Match middle tones, not the white point or the camera's contrast curve.
    // The median does not require matching orientation/resolution or let a few
    // specular highlights dominate. Black/clipped references cannot set EV.
    const float source=raw[raw.size()/2], reference=preview[preview.size()/2];
    if (source<=1e-7f || reference<=.0003f || reference>=.95f) return 0;
    if (matched) *matched=true;
    return std::clamp(std::log2(reference/source),-8.0f,8.0f);
}

std::vector<float> loadPreviewLuminance(const std::string& path) {
    // Keep thumbnail failures/recycle separate from the active RAW decoder.
    // LibRaw is larger than a macOS dispatch worker's default stack.
    auto raw=std::make_unique<LibRaw>();
    if (openRawFile(*raw,path)!=LIBRAW_SUCCESS) return {};
    int thumbnail=-1;
    const auto& defaultThumb=raw->imgdata.thumbnail;
    if (static_cast<size_t>(defaultThumb.twidth)*defaultThumb.theight>64000000) {
        // High-resolution cameras may select a full-size JPEG as the default preview.
        size_t largest=0;
        const auto& list=raw->imgdata.thumbs_list;
        for (int i=0;i<list.thumbcount;++i) {
            const auto& candidate=list.thumblist[i];
            const size_t pixels=static_cast<size_t>(candidate.twidth)*candidate.theight;
            if (pixels>largest && pixels<=64000000) {
                thumbnail=i;
                largest=pixels;
            }
        }
    }
    if ((thumbnail<0 ? raw->unpack_thumb() : raw->unpack_thumb_ex(thumbnail))!=LIBRAW_SUCCESS) return {};
    // DNG: 0 unspecified, 1 gray gamma 2.2, 2 sRGB. Do not reinterpret a
    // declared Adobe RGB/ProPhoto preview as sRGB for exposure metering.
    const unsigned previewSpace=raw->imgdata.color.dng_levels.preview_colorspace;
    if (previewSpace>2) return {};
    std::unique_ptr<libraw_processed_image_t,decltype(&LibRaw::dcraw_clear_mem)>
        thumb(raw->dcraw_make_mem_thumb(),LibRaw::dcraw_clear_mem);
    if (!thumb) return {};
    int width=thumb->width,height=thumb->height,channels=thumb->colors;
    const unsigned char* pixels=thumb->data;
    std::unique_ptr<unsigned char,decltype(&stbi_image_free)> decoded(nullptr,stbi_image_free);
    if (thumb->type==LIBRAW_IMAGE_JPEG) {
        if (thumb->data_size>static_cast<unsigned>(std::numeric_limits<int>::max())) return {};
        const int length=static_cast<int>(thumb->data_size);
        if (!stbi_info_from_memory(pixels,length,&width,&height,&channels) ||
            width<=0 || height<=0 || static_cast<size_t>(width)*height>64000000) return {};
        decoded.reset(stbi_load_from_memory(pixels,length,&width,&height,&channels,3));
        pixels=decoded.get();
        channels=3;
    } else if (thumb->type!=LIBRAW_IMAGE_BITMAP || thumb->bits!=8 ||
               static_cast<size_t>(width)*height*channels!=thumb->data_size) return {};
    if (!pixels || width<=0 || height<=0 || (channels!=1 && channels!=3)) return {};
    float linear[256];
    for (int i=0;i<256;++i) {
        const float v=i/255.0f;
        linear[i]=previewSpace==1 ? std::pow(v,2.2f) :
            (v<=.04045f ? v/12.92f : std::pow((v+.055f)/1.055f,2.4f));
    }
    std::vector<float> luminance;
    luminance.reserve(128*128);
    for (int y=0;y<128;++y) for (int x=0;x<128;++x) {
        const size_t row=static_cast<size_t>(2*y+1)*height/256;
        const size_t col=static_cast<size_t>(2*x+1)*width/256;
        const auto* p=pixels+(row*width+col)*channels;
        luminance.push_back(channels==1 ? linear[p[0]] :
            .2126f*linear[p[0]]+.7152f*linear[p[1]]+.0722f*linear[p[2]]);
    }
    return luminance;
}

} // namespace sony2fuji
