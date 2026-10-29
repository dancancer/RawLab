#pragma once

#include <array>
#include <numeric>

namespace {
void numericAcceptance(NSURL* directory) {
    using Pixel=std::array<float,3>;
    const std::array<Pixel,16> sdr{{
        {.01f,.01f,.01f},{.02f,.02f,.02f},{.05f,.05f,.05f},{.18f,.18f,.18f},
        {.5f,.5f,.5f},{.5f,.5f,.5f},{.5f,.5f,.5f},{.5f,.5f,.5f},
        {.5f,.5f,.5f},{.5f,.25f,.1f},{.8f,.4f,.2f},{.05f,.3f,.6f},
        {.6f,.1f,.2f},{.2f,.6f,.1f},{.18f,.18f,.18f},{.8f,.8f,.8f}}};
    const std::array<Pixel,16> hdr{{
        {.02f,.02f,.02f},{.04f,.04f,.04f},{.1f,.1f,.1f},{.36f,.36f,.36f},
        {1,1,1},{2,2,2},{4,4,4},{8,8,8},
        {16,16,16},{1.5f,.75f,.2f},{3.2f,1.6f,.8f},{.1f,.9f,2.4f},
        {2.4f,.2f,.6f},{.4f,2.4f,.3f},{.18f,.18f,.18f},{.8f,.8f,.8f}}};
    constexpr int width=512,height=32,patchWidth=32;
    std::vector<Pixel> h(width*height),s(h.size());
    for (int y=0;y<height;++y) for (int x=0;x<width;++x) {
        h[y*width+x]=hdr[x/patchWidth]; s[y*width+x]=sdr[x/patchWidth];
    }
    auto source=init<sony2fuji_hdr_image_pair_v1>();
    auto makeView=[&](std::vector<Pixel>& pixels) {
        auto b=init<sony2fuji_hdr_buffer_v1>(); b.data=pixels.data();
        b.width=width; b.height=height; b.stride_bytes=width*sizeof(Pixel); b.size_bytes=pixels.size()*sizeof(Pixel);
        b.pixel_format=SONY2FUJI_HDR_RGB32F_LINEAR; b.color_encoding=SONY2FUJI_HDR_LINEAR_SRGB;
        b.content_headroom=16; b.headroom_kind=SONY2FUJI_HDR_HEADROOM_MEASURED;
        return b;
    };
    source.hdr=makeView(h); source.sdr=makeView(s);
    source.native_width=width; source.native_height=height; source.orientation_applied=1;
    source.source_intent=source.render_intent=SONY2FUJI_INTENT_FINAL;
    source.source_headroom=16; source.source_headroom_kind=SONY2FUJI_HDR_HEADROOM_DECLARED;
    auto percentile=[](std::vector<double> values,double quantile) {
        std::sort(values.begin(),values.end());
        return values[size_t(std::ceil(quantile*values.size()))-1];
    };
    auto gamma8=[](double x) { return 255*(x<=.0031308 ? 12.92*x : 1.055*std::pow(x,1/2.4)-.055); };
    auto luminance=[](const float* p) { return .2126*p[0]+.7152*p[1]+.0722*p[2]; };
    auto targetColor=[](const float* p,uint32_t color) -> Pixel {
        if (color==SONY2FUJI_HDR_COLOR_SRGB) return {p[0],p[1],p[2]};
        return {.8225929f*p[0]+.1775339f*p[1],.0331995f*p[0]+.9667835f*p[1],
            .0170854f*p[0]+.0723957f*p[1]+.9103015f*p[2]};
    };
    for (uint32_t color:{uint32_t(SONY2FUJI_HDR_COLOR_SRGB),uint32_t(SONY2FUJI_HDR_COLOR_DISPLAY_P3)}) {
        auto config=init<sony2fuji_hdr_export_config_v1>();
        config.jpeg_quality=95; config.base_color=color; config.metadata_policy=SONY2FUJI_HDR_METADATA_ISO_XMP;
        auto diagnostic=init<sony2fuji_hdr_diagnostic_v1>();
        NSURL* encoded=[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"a08-%u.jpg",color]];
        check(sony2fuji_hdr_export_jpeg(&source,&config,encoded.fileSystemRepresentation,&diagnostic)==SONY2FUJI_STATUS_OK,
            "A08 source pair encoding failed");
        NSData* dual=[NSData dataWithContentsOfURL:encoded];
        CGImageSourceRef baseSource=CGImageSourceCreateWithData((__bridge CFDataRef)dual,nullptr);
        CGImageRef baseImage=baseSource ? CGImageSourceCreateImageAtIndex(baseSource,0,nullptr) : nullptr;
        CFDataRef profile=baseImage ? CGColorSpaceCopyICCData(CGImageGetColorSpace(baseImage)) : nullptr;
        const bool tagged=profile && CFDataGetLength(profile)>128;
        if (profile) CFRelease(profile); if (baseImage) CGImageRelease(baseImage); if (baseSource) CFRelease(baseSource);
        check(tagged,"A08 encoded base is missing its actual ICC profile");
        for (uint32_t protocol:{uint32_t(SONY2FUJI_HDR_PROTOCOL_ISO_XMP),uint32_t(SONY2FUJI_HDR_PROTOCOL_ISO),uint32_t(SONY2FUJI_HDR_PROTOCOL_XMP)}) {
            NSMutableData* data=[dual mutableCopy];
            const std::string hidden=protocol==SONY2FUJI_HDR_PROTOCOL_ISO ? "http://ns.adobe.com/hdr-gain-map/1.0/" :
                protocol==SONY2FUJI_HDR_PROTOCOL_XMP ? "urn:iso:std:iso:ts:21496:-1" : "";
            if (!hidden.empty()) {
                auto* begin=static_cast<char*>(data.mutableBytes); auto* end=begin+data.length;
                for (auto* found=std::search(begin,end,hidden.begin(),hidden.end());found!=end;
                     found=std::search(found+hidden.size(),end,hidden.begin(),hidden.end()))
                    std::fill_n(found,hidden.size(),'x');
            }
            NSURL* file=[directory URLByAppendingPathComponent:[NSString stringWithFormat:@"a08-%u-%u.jpg",color,protocol]];
            check([data writeToURL:file atomically:YES],"A08 protocol fixture write failed");
            auto info=init<sony2fuji_hdr_source_info_v1>();
            check(sony2fuji_hdr_probe(file.fileSystemRepresentation,&info,&diagnostic)==SONY2FUJI_STATUS_OK &&
                info.protocol==protocol && info.color_description==color,"A08 protocol/color identity mismatch");
            auto options=init<sony2fuji_hdr_decode_options_v1>(); options.intent=SONY2FUJI_INTENT_FINAL;
            auto actual=init<sony2fuji_hdr_image_pair_v1>();
            check(sony2fuji_hdr_decode(file.fileSystemRepresentation,&options,&actual,&diagnostic)==SONY2FUJI_STATUS_OK,
                "A08 production FINAL decode failed");
            std::vector<double> ev,rgb;
            for (int y=2;y<height-2;++y) for (int x=2;x<width;++x) {
                if (x%patchWidth<2 || x%patchWidth>=patchWidth-2) continue;
                const auto* hp=reinterpret_cast<const float*>(static_cast<const uint8_t*>(actual.hdr.data)+y*actual.hdr.stride_bytes)+x*3;
                const auto* sp=reinterpret_cast<const float*>(static_cast<const uint8_t*>(actual.sdr.data)+y*actual.sdr.stride_bytes)+x*3;
                const double expectedY=luminance(h[y*width+x].data()),actualY=luminance(hp);
                check(actualY>0 && std::isfinite(actualY),"A08 invalid luminance");
                if (expectedY>=.01) ev.push_back(std::abs(std::log2(actualY/expectedY)));
                const auto actualTarget=targetColor(sp,color),expectedTarget=targetColor(s[y*width+x].data(),color);
                for (int c=0;c<3;++c) rgb.push_back(std::abs(gamma8(std::clamp(double(actualTarget[c]),0.0,1.0))-gamma8(expectedTarget[c])));
            }
            const double p95=percentile(ev,.95),mae=std::accumulate(rgb.begin(),rgb.end(),0.0)/rgb.size(),p99=percentile(rgb,.99);
            std::cout<<"A08 color="<<color<<" protocol="<<protocol<<" HDR_P95_EV="<<p95<<" SDR_MAE="<<mae<<" SDR_P99="<<p99<<'\n';
            if (p95>.10 || mae>2 || p99>8) {
                for (int patch=0;patch<16;++patch) {
                    const int x=patch*patchWidth+patchWidth/2,y=height/2;
                    const auto* hp=reinterpret_cast<const float*>(static_cast<const uint8_t*>(actual.hdr.data)+y*actual.hdr.stride_bytes)+x*3;
                    const auto* sp=reinterpret_cast<const float*>(static_cast<const uint8_t*>(actual.sdr.data)+y*actual.sdr.stride_bytes)+x*3;
                    std::cerr<<"patch="<<patch<<" hdr="<<hp[0]<<','<<hp[1]<<','<<hp[2]<<" sdr="<<sp[0]<<','<<sp[1]<<','<<sp[2]<<'\n';
                }
            }
            sony2fuji_hdr_release_pair(&actual);
            check(p95<=.10 && mae<=2 && p99<=8,"A08 HDR/SDR numerical acceptance failed");
        }
    }
    check(h[0]==hdr[0] && s[0]==sdr[0],"A08 encoding changed caller-owned pixels");
}
}
