#include "lut_preview_comparison.h"
#include "lut_contract_json.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
namespace sony2fuji {
namespace {
uint32_t channels(const sony2fuji_buffer& image) {
    const uint32_t count=image.pixel_format==SONY2FUJI_PIXEL_RGB8?3:image.pixel_format==SONY2FUJI_PIXEL_RGBA8?4:0;
    if(!count || !image.data || !image.width || !image.height || image.width>1024 || image.height>1024 ||
        image.stride_bytes<image.width*count || image.size_bytes<uint64_t(image.height-1)*image.stride_bytes+image.width*count)
        throw std::invalid_argument("Invalid preview pixels, dimensions or stride");
    return count;
}
}
std::string compareLUTPreviews(const sony2fuji_buffer& candidate,const sony2fuji_buffer& reference,const std::string& text) {
    if(text.size()>8192) throw std::invalid_argument("Reference conditions exceed limit");
    const auto conditions=parseLUTJSON(text);
    if(!conditions.is_object() || conditions.size()!=5) throw std::invalid_argument("Explicit comparison conditions are required");
    for(const auto* key:{"same_source","same_geometry","same_processing","known_srgb"})
        if(!conditions.contains(key) || !conditions[key].is_boolean() || !conditions[key].get<bool>())
            throw std::invalid_argument("Comparison conditions are not confirmed");
    const auto source=conditions.at("reference_source").get<std::string>();
    if(source.size()>2048 || source.find_first_not_of(" \r\n\t")==std::string::npos)
        throw std::invalid_argument("Reference source and processing notes are required");
    const auto ac=channels(candidate),bc=channels(reference);
    if(candidate.width!=reference.width || candidate.height!=reference.height)
        throw std::invalid_argument("Preview dimensions must match");
    uint64_t total=0,boundaryA=0,boundaryB=0;
    std::array<uint64_t,256> histogram{};
    for(uint32_t y=0;y<candidate.height;++y) {
        const auto* a=static_cast<const uint8_t*>(candidate.data)+size_t(y)*candidate.stride_bytes;
        const auto* b=static_cast<const uint8_t*>(reference.data)+size_t(y)*reference.stride_bytes;
        for(uint32_t x=0;x<candidate.width;++x) {
            if((ac==4 && a[3]!=255) || (bc==4 && b[3]!=255)) throw std::invalid_argument("Transparent pixels are unsupported");
            bool edgeA=false,edgeB=false;
            for(int c=0;c<3;++c) {
                const auto error=std::abs(int(a[c])-int(b[c]));total+=error;++histogram[error];
                edgeA|=a[c]==0 || a[c]==255;edgeB|=b[c]==0 || b[c]==255;
            }
            boundaryA+=edgeA;boundaryB+=edgeB;a+=ac;b+=bc;
        }
    }
    const uint64_t pixels=uint64_t(candidate.width)*candidate.height,samples=pixels*3;
    uint64_t cumulative=0;int maximum=0,p95=0;
    for(int i=0;i<256;++i) {cumulative+=histogram[i];if(histogram[i])maximum=i;if(cumulative*100<samples*95)p95=i+1;}
    return nlohmann::json{{"comparison","preview-pixels"},{"appearance","unverified"},
        {"basis","user-declared-conditions"},{"conditions",conditions},{"width",candidate.width},{"height",candidate.height},
        {"mean_absolute_rgb",double(total)/(samples*255.)},{"max_absolute_rgb",maximum/255.},
        {"p95_absolute_rgb",p95/255.},{"candidate_boundary_fraction",double(boundaryA)/pixels},
        {"reference_boundary_fraction",double(boundaryB)/pixels}}.dump();
}
}
