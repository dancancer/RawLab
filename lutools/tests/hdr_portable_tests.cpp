#include "core/hdr_jpeg.h"
#include "platform/hdr_image.h"
#include "platform/hdr_metadata.h"
#include <libheif/heif.h>
#include <lcms2.h>
#include <libheif/heif_items.h>
#include <ultrahdr/gainmapmetadata.h>
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#ifdef RAWLAB_HDR_TEST_APPLE_AUTHOR
std::vector<uint8_t> authorISOHEIF();
std::vector<uint8_t> authorAppleJPEG(const char* path);
#endif

namespace {
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
template<class T> T init() { T value{}; value.version=1; value.struct_size=sizeof(value); return value; }
std::vector<uint8_t> read(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}
void write(const std::filesystem::path& path, const std::vector<uint8_t>& data) {
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char*>(data.data()), data.size());
    check(output.good(), "fixture write failed");
}
}

int main(int argc, const char* argv[]) {
    const auto root=std::filesystem::temp_directory_path()/
        ("rawlab-portable-hdr-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(root);
    try {
        const std::string xmp="<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" xmlns:g=\"http://ns.apple.com/HDRGainMap/1.0/\"><g:HDRGainMapVersion>65536</g:HDRGainMapVersion></x:xmpmeta>";
        check(sony2fuji::hdr::appleXMPHeadroom(xmp.data(),xmp.size())==0,"valid Apple gain-map metadata rejected");
        auto future=xmp; future.replace(future.find("65536"),5,"65537");
        try { sony2fuji::hdr::appleXMPHeadroom(future.data(),future.size()); check(false,"unknown Apple version admitted"); }
        catch (const sony2fuji::hdr::Error& error) { check(error.reason==SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION,"future Apple version has wrong diagnostic"); }
        sony2fuji::HDRImagePair synthetic;
        synthetic.hdr=sony2fuji::ImageData(64,32); synthetic.sdr=sony2fuji::ImageData(64,32);
        for (int y=0;y<32;++y) for (int x=0;x<64;++x) {
            const float gain=1+float(x)/16;
            synthetic.sdr.at(x,y)={.18f,.4f,.6f};
            synthetic.hdr.at(x,y)={.18f*gain,.4f*gain,.6f*gain};
        }
        // JPEG 的线性化路径仅支持 sRGB TRC；HEIF 的 LCMS 路径仍可处理线性 profile。
        for (const bool linear : {false,true}) {
            auto profile=cmsCreate_sRGBProfile();check(profile!=nullptr,"cannot create ICC fixture");
            if (linear) {
                auto curve=cmsBuildGamma(nullptr,1);
                for (auto tag : {cmsSigRedTRCTag,cmsSigGreenTRCTag,cmsSigBlueTRCTag})
                    check(cmsWriteTag(profile,tag,curve)!=0,"cannot write ICC fixture TRC");
                cmsFreeToneCurve(curve);
            }
            cmsUInt32Number count=0;cmsSaveProfileToMem(profile,nullptr,&count);
            std::vector<uint8_t> icc(count);cmsSaveProfileToMem(profile,icc.data(),&count);cmsCloseProfile(profile);
            const uint32_t length=count+16;
            std::vector<uint8_t> jpeg{255,0xd8,255,0xe2,uint8_t(length>>8),uint8_t(length),'I','C','C','_','P','R','O','F','I','L','E',0,1,1};
            jpeg.insert(jpeg.end(),icc.begin(),icc.end());jpeg.insert(jpeg.end(),{255,0xd9});
            check(sony2fuji::hdr::iccColorDescription(icc.data(),icc.size())==SONY2FUJI_HDR_COLOR_SRGB,"HEIF gamut detection rejects linear TRC");
            check(sony2fuji::hdr::jpegColorDescription(jpeg.data(),jpeg.size())==(linear ? SONY2FUJI_HDR_COLOR_UNKNOWN : SONY2FUJI_HDR_COLOR_SRGB),
                "JPEG admits non-sRGB TRC or rejects valid sRGB");
        }
        const auto source=root/"source.jpg", output=root/"output.jpg";
        write(source,sony2fuji::hdr::encodeJPEG(synthetic,98,SONY2FUJI_HDR_COLOR_SRGB));
        const auto path=source.u8string();
        auto info=init<sony2fuji_hdr_source_info_v1>(); auto diagnostic=init<sony2fuji_hdr_diagnostic_v1>();
        auto status=sony2fuji_hdr_probe(path.c_str(),&info,&diagnostic);
        if (status) std::cerr<<"probe status="<<status<<" reason="<<diagnostic.reason<<'\n';
        check(status==SONY2FUJI_STATUS_OK,"portable HDR probe must accept a valid gain-map JPEG");
        check(info.width==64 && info.height==32 && info.orientation==1 && info.content_headroom>2,
            "portable source metadata differs");
        check(info.protocol==SONY2FUJI_HDR_PROTOCOL_ISO_XMP,"export must retain both interoperable metadata forms");
        auto options=init<sony2fuji_hdr_decode_options_v1>(); options.intent=SONY2FUJI_INTENT_PREVIEW; options.long_edge=16;
        auto pair=init<sony2fuji_hdr_image_pair_v1>();
        check(sony2fuji_hdr_decode(path.c_str(),&options,&pair,&diagnostic)==SONY2FUJI_STATUS_OK,"bounded portable preview failed");
        check(pair.hdr.width==16 && pair.hdr.height==8 && pair.sdr.width==16 && pair.is_proxy &&
            pair.native_width==64 && pair.native_height==32,"preview size/provenance lost");
        const auto* s=static_cast<const float*>(pair.sdr.data);
        check(std::abs(s[0]-.18f)<.025f && std::abs(s[1]-.4f)<.025f,"SDR rendition must be the independently decoded base");
        auto config=init<sony2fuji_hdr_export_config_v1>(); config.jpeg_quality=95;
        config.base_color=SONY2FUJI_HDR_COLOR_SRGB; config.metadata_policy=SONY2FUJI_HDR_METADATA_ISO_XMP;
        check(sony2fuji_hdr_export_jpeg(&pair,&config,output.u8string().c_str(),&diagnostic)!=SONY2FUJI_STATUS_OK,
            "proxy export was admitted");
        sony2fuji_hdr_release_pair(&pair);
        options.intent=SONY2FUJI_INTENT_FINAL; options.long_edge=0;
        pair=init<sony2fuji_hdr_image_pair_v1>();
        check(sony2fuji_hdr_decode(path.c_str(),&options,&pair,&diagnostic)==SONY2FUJI_STATUS_OK,"portable FINAL failed");
        check(pair.hdr.width==64 && !pair.is_proxy,"FINAL resolution lost");
        const auto original=read(source);
        check(sony2fuji_hdr_export_jpeg(&pair,&config,path.c_str(),&diagnostic)!=SONY2FUJI_STATUS_OK &&
            read(source)==original,"source overwrite protection failed");
        check(sony2fuji_hdr_export_jpeg(&pair,&config,output.u8string().c_str(),&diagnostic)==SONY2FUJI_STATUS_OK,
            "portable HDR export failed");
        config.jpeg_quality=0;
        check(sony2fuji_hdr_export_jpeg(&pair,&config,output.u8string().c_str(),&diagnostic)==SONY2FUJI_STATUS_OK,
            "zero JPEG quality must use the shared default 95");
        auto roundtrip=init<sony2fuji_hdr_source_info_v1>();
        check(sony2fuji_hdr_probe(output.u8string().c_str(),&roundtrip,&diagnostic)==SONY2FUJI_STATUS_OK &&
            roundtrip.width==64 && roundtrip.height==32,"portable exported gain map cannot be reopened");
        for (uint32_t format : {SONY2FUJI_OUTPUT_JPEG,SONY2FUJI_OUTPUT_PNG,SONY2FUJI_OUTPUT_DNG}) {
            auto sdr=init<sony2fuji_hdr_sdr_export_config_v1>(); sdr.output_format=format; sdr.quality=95;
            const auto destination=(root/("sdr-"+std::to_string(format))).u8string();
            check(sony2fuji_hdr_export_sdr(&pair,&sdr,destination.c_str(),&diagnostic)==SONY2FUJI_STATUS_OK,
                "portable SDR export failed");
            check(read(std::filesystem::u8path(destination)).size()>100,"SDR export is empty");
        }
        sony2fuji_hdr_release_pair(&pair);
        const auto broken=root/"missing-gain-map.jpg"; write(broken,sony2fuji::hdr::jpegBase(original.data(),original.size()));
        check(sony2fuji_hdr_probe(broken.u8string().c_str(),&info,&diagnostic)!=SONY2FUJI_STATUS_OK &&
            diagnostic.reason!=SONY2FUJI_HDR_REASON_NOT_HDR,"declared but missing gain map was downgraded to SDR");
        const auto plain=root/"plain.jpg"; write(plain,sony2fuji::hdr::encodeSDRJPEG(synthetic.sdr,95));
        check(sony2fuji_hdr_probe(plain.u8string().c_str(),&info,&diagnostic)==SONY2FUJI_STATUS_UNSUPPORTED &&
            diagnostic.reason==SONY2FUJI_HDR_REASON_NOT_HDR,"ordinary SDR must have an explicit NOT_HDR result");
        try { sony2fuji::hdr::admitMemory(UINT64_MAX); check(false,"unbounded allocation admitted"); }
        catch (const sony2fuji::hdr::Error& error) { check(error.status==SONY2FUJI_STATUS_OUT_OF_MEMORY,"memory rejection has wrong status"); }
        if (argc==2) {
            options.intent=SONY2FUJI_INTENT_PREVIEW; options.long_edge=512;
            pair=init<sony2fuji_hdr_image_pair_v1>();
            check(sony2fuji_hdr_decode(argv[1],&options,&pair,&diagnostic)==SONY2FUJI_STATUS_OK,"real portable fixture failed");
            check(std::max(pair.hdr.width,pair.hdr.height)<=512 && pair.source_headroom>1,"real fixture lost HDR/bound");
            const auto* hdr=static_cast<const float*>(pair.hdr.data);
            const auto* sdr=static_cast<const float*>(pair.sdr.data);
            float maximum=0; double delta=0;
            for (size_t i=0;i<size_t(pair.hdr.width)*pair.hdr.height*3;++i) {
                check(std::isfinite(hdr[i]) && std::isfinite(sdr[i]),"real fixture has nonfinite pixels");
                maximum=std::max(maximum,hdr[i]); delta+=std::abs(hdr[i]-sdr[i]);
            }
            check(maximum>1.05f && delta>1,"gain-map expansion did not change real pixels");
            sony2fuji_hdr_release_pair(&pair);
#ifdef RAWLAB_HDR_TEST_APPLE_AUTHOR
            if(std::filesystem::path(argv[1]).extension()==".HEIC") {
                const auto apple=root/"apple.jpg";write(apple,authorAppleJPEG(argv[1]));
                const auto status=sony2fuji_hdr_probe(apple.u8string().c_str(),&info,&diagnostic);
                if(status)std::cerr<<"Apple JPEG status="<<status<<" reason="<<diagnostic.reason<<'\n';
                check(status==SONY2FUJI_STATUS_OK && info.protocol==SONY2FUJI_HDR_PROTOCOL_APPLE,"Apple JPEG protocol/headroom failed");
                pair=init<sony2fuji_hdr_image_pair_v1>();
                check(sony2fuji_hdr_decode(apple.u8string().c_str(),&options,&pair,&diagnostic)==SONY2FUJI_STATUS_OK,"Apple JPEG expansion failed");
                sony2fuji_hdr_release_pair(&pair);
            }
            {
                const auto iso=root/"iso.heic"; write(iso,authorISOHEIF());
                const auto isoStatus=sony2fuji_hdr_probe(iso.u8string().c_str(),&info,&diagnostic);
                if (isoStatus) std::cerr<<"ISO status="<<isoStatus<<" reason="<<diagnostic.reason<<" protocol="<<info.protocol<<'\n';
                check(isoStatus==SONY2FUJI_STATUS_OK &&
                    info.protocol==SONY2FUJI_HDR_PROTOCOL_ISO && info.content_headroom>1,"ISO HEIF association/metadata failed");
                pair=init<sony2fuji_hdr_image_pair_v1>();
                check(sony2fuji_hdr_decode(iso.u8string().c_str(),&options,&pair,&diagnostic)==SONY2FUJI_STATUS_OK &&
                    pair.hdr.width && pair.hdr.height,"ISO HEIF gain-map reconstruction failed");
                sony2fuji_hdr_release_pair(&pair);
            }
#endif
        }
        std::filesystem::remove_all(root);
        std::cout<<"portable HDR file checks passed\n"; return 0;
    } catch (const std::exception& error) {
        std::cerr<<error.what()<<'\n'; std::filesystem::remove_all(root); return 1;
    }
}
