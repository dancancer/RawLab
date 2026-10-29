#include "platform/hdr_image.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>

namespace {
void check(bool value,const char* message) { if (!value) throw std::runtime_error(message); }
void verify(const char* path,bool final) {
    auto options=sony2fuji_hdr_decode_options_v1{};
    options.version=1; options.struct_size=sizeof(options);
    options.intent=final ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
    options.long_edge=final ? 0 : 1024;
    auto source=sony2fuji::hdr::decodeFile(path,options);
    sony2fuji::HDRRenderOptions settings;
    settings.intent=final ? sony2fuji::HDRQuality::Final : sony2fuji::HDRQuality::Preview;
    auto identity=sony2fuji::renderHDRPair(source.pixels,settings);
    const size_t bytes=source.pixels.hdr.pixels.size()*sizeof(sony2fuji::RGB);
    check(std::memcmp(identity.hdr.pixels.data(),source.pixels.hdr.pixels.data(),bytes)==0,"production HDR identity changed pixels");
    check(std::memcmp(identity.sdr.pixels.data(),source.pixels.sdr.pixels.data(),bytes)==0,"production SDR identity changed pixels");
    identity={};
    settings.exposureEV=1;
    auto brighter=sony2fuji::renderHDRPair(source.pixels,settings);
    for (size_t i=0;i<brighter.hdr.pixels.size();++i) {
        const auto a=source.pixels.hdr.pixels[i],b=brighter.hdr.pixels[i];
        check(std::abs(b.r-2*a.r)<=1e-6f*std::max(1.0f,std::abs(2*a.r)) &&
            std::abs(b.g-2*a.g)<=1e-6f*std::max(1.0f,std::abs(2*a.g)) &&
            std::abs(b.b-2*a.b)<=1e-6f*std::max(1.0f,std::abs(2*a.b)),"production exposure did not double HDR");
    }
    check(!final || (!brighter.isProxy && brighter.hdr.width==int(source.pixels.nativeWidth) &&
        brighter.hdr.height==int(source.pixels.nativeHeight)),"FINAL used a reduced source");
    std::cout<<"production_canvas="<<brighter.hdr.width<<'x'<<brighter.hdr.height
        <<" final="<<final<<" source_headroom="<<brighter.sourceHeadroom<<" edited_headroom="<<brighter.editedHeadroom<<'\n';
}
}

void checkProductionHDR(NSData* data) {
    NSURL* file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"jpg"]]];
    check([data writeToURL:file atomically:YES],"cannot stage production fixture");
    try { verify(file.fileSystemRepresentation,false); }
    catch (...) { [NSFileManager.defaultManager removeItemAtURL:file error:nil]; throw; }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
}
void checkProductionFile(const char* path,bool final) { verify(path,final); }
