#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "platform/hdr_image.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <tiffio.h>

namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<class T> T init() { T v{}; v.version=1; v.struct_size=sizeof(v); return v; }

}
#include "hdr_codec/numeric_acceptance.h"
namespace {

NSData* fixture(bool changed=false) API_AVAILABLE(macos(15.0), ios(18.0)) {
    std::vector<float> h(64 * 32 * 4), s(h.size());
    for (size_t i=0; i<h.size(); ++i) {
        const float base[] = {.18f,.5f,.8f,1};
        s[i]=base[i%4]; h[i]=i%4==3 ? 1 : s[i]*(1+float(i/4%64/16)+(changed ? .25f : 0));
    }
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CIImage* hdr = [CIImage imageWithBitmapData:[NSData dataWithBytes:h.data() length:h.size()*4]
        bytesPerRow:64*16 size:CGSizeMake(64,32) format:kCIFormatRGBAf colorSpace:linear];
    CIImage* sdr = [CIImage imageWithBitmapData:[NSData dataWithBytes:s.data() length:s.size()*4]
        bytesPerRow:64*16 size:CGSizeMake(64,32) format:kCIFormatRGBAf colorSpace:linear];
    CIContext* context = [CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf)}];
    CGImageRef image = [context createCGImage:hdr fromRect:hdr.extent format:kCIFormatRGBAf colorSpace:linear];
    CGImageRef tagged = image ? CGImageCreateCopyWithContentHeadroom(4,image) : nullptr;
    check(tagged, "cannot author HDR fixture");
    hdr = [CIImage imageWithCGImage:tagged];
    CGColorSpaceRef srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSData* data=[context JPEGRepresentationOfImage:sdr colorSpace:srgb options:@{kCIImageRepresentationHDRImage:hdr,
        (__bridge NSString*)kCGImageDestinationLossyCompressionQuality:@.98}];
    CGImageRelease(tagged); CGImageRelease(image); CGColorSpaceRelease(linear); CGColorSpaceRelease(srgb);
    check(data.length>0,"cannot encode HDR fixture"); return data;
}
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            if (argc==3 && std::string(argv[1])=="--fixture") {
                return [fixture() writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES] ? 0 : 1;
            }
            NSURL* directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
            [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
            try {
                NSURL* file=[directory URLByAppendingPathComponent:@"source.jpg"];
                check([fixture() writeToURL:file atomically:YES],"fixture write failed");
                const char* path=argc==2 ? argv[1] : file.fileSystemRepresentation;
                auto info=init<sony2fuji_hdr_source_info_v1>(); auto d=init<sony2fuji_hdr_diagnostic_v1>();
                auto status=sony2fuji_hdr_probe(path,&info,&d);
                if (status) std::cerr << "probe status=" << status << " reason=" << d.reason << '\n';
                check(status==SONY2FUJI_STATUS_OK,"HDR probe failed");
                check(info.width && info.height && info.protocol,"HDR source identity missing");
                if (argc==2 && info.container==SONY2FUJI_HDR_CONTAINER_JPEG) {
                    NSData* data=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
                    auto hasNamespace=[&](const std::string& name) {
                        const auto* begin=static_cast<const char*>(data.bytes); const auto* end=begin+data.length;
                        return std::search(begin,end,name.begin(),name.end())!=end;
                    };
                    if (hasNamespace("http://ns.adobe.com/hdr-gain-map/1.0/") && !hasNamespace("urn:iso:std:iso:ts:21496:-1") &&
                        !hasNamespace("urn:com:apple:photo:2020:aux:hdrgainmap"))
                        check(info.protocol==SONY2FUJI_HDR_PROTOCOL_XMP,"ImageIO synthesized ISO metadata for an XMP-only original");
                }
                auto options=init<sony2fuji_hdr_decode_options_v1>(); options.intent=SONY2FUJI_INTENT_PREVIEW; options.long_edge=1024;
                auto pair=init<sony2fuji_hdr_image_pair_v1>();
                status=sony2fuji_hdr_decode(path,&options,&pair,&d);
                if (status) std::cerr << "decode status=" << status << " reason=" << d.reason << '\n';
                check(status==SONY2FUJI_STATUS_OK,"HDR decode failed");
                check(pair.hdr.width==pair.sdr.width && pair.hdr.height==pair.sdr.height && pair.is_proxy,
                    "decoded pair/provenance mismatch");
                const auto* h=static_cast<float*>(pair.hdr.data); const auto* s=static_cast<float*>(pair.sdr.data);
                double delta=0; float maximum=0;
                for (size_t i=0; i<pair.hdr.width*pair.hdr.height*3; ++i) {
                    check(std::isfinite(h[i]) && std::isfinite(s[i]),"nonfinite decoded value");
                    delta+=std::abs(h[i]-s[i]); maximum=std::max(maximum,h[i]);
                }
                check(maximum>1.5 && delta>1,"HDR expansion lost its luminance range");
                check(pair.source_headroom>1 && pair.source_headroom_kind,"source headroom missing");
                sony2fuji_hdr_release_pair(&pair);
                if (argc==1) {
                    try {
                        sony2fuji::hdr::admitMemory(UINT64_MAX);
                        check(false,"unbounded HDR allocation admitted");
                    } catch (const sony2fuji::hdr::Error& error) {
                        check(error.status==SONY2FUJI_STATUS_OUT_OF_MEMORY && error.reason==SONY2FUJI_HDR_REASON_OUT_OF_MEMORY,
                            "memory budget has no recoverable resource diagnostic");
                    }
                    const std::string legacyPath=std::string(TEST_FIXTURE_DIR)+"/hdr/apple-legacy-macos26.jpg";
                    auto legacyInfo=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(legacyPath.c_str(),&legacyInfo,&d)==SONY2FUJI_STATUS_OK &&
                        legacyInfo.protocol==SONY2FUJI_HDR_PROTOCOL_APPLE,"Apple legacy JPEG was treated as modern XMP/ISO");
                    for (auto intent:{SONY2FUJI_INTENT_PREVIEW,SONY2FUJI_INTENT_FINAL}) {
                        auto legacyPair=init<sony2fuji_hdr_image_pair_v1>();
                        options.intent=intent; options.long_edge=intent==SONY2FUJI_INTENT_PREVIEW ? 32 : 0;
                        check(sony2fuji_hdr_decode(legacyPath.c_str(),&options,&legacyPair,&d)==SONY2FUJI_STATUS_OK,
                            "Apple legacy JPEG decode failed");
                        const auto* pixels=static_cast<const float*>(legacyPair.hdr.data);
                        check(*std::max_element(pixels,pixels+legacyPair.hdr.width*legacyPair.hdr.height*3)>1.5f,
                            "Apple legacy JPEG lost HDR expansion");
                        sony2fuji_hdr_release_pair(&legacyPair);
                    }
                    numericAcceptance(directory);
                    pair=init<sony2fuji_hdr_image_pair_v1>();
                    options.intent=SONY2FUJI_INTENT_FINAL; options.long_edge=0;
                    check(sony2fuji_hdr_decode(path,&options,&pair,&d)==SONY2FUJI_STATUS_OK,"FINAL decode failed");
                    auto config=init<sony2fuji_hdr_export_config_v1>();
                    config.jpeg_quality=95; config.base_color=SONY2FUJI_HDR_COLOR_SRGB;
                    config.metadata_policy=SONY2FUJI_HDR_METADATA_ISO_XMP;
                    NSURL* other=[directory URLByAppendingPathComponent:@"different-source.jpg"];
                    check([fixture(true) writeToURL:other atomically:YES],"cannot stage different metadata source");
                    auto otherInfo=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(other.fileSystemRepresentation,&otherInfo,&d)==SONY2FUJI_STATUS_OK,
                        "cannot probe different metadata source");
                    config.metadata_source_path=other.fileSystemRepresentation;
                    std::copy_n(otherInfo.source_sha256,32,config.source_sha256);
                    NSURL* protectedOutput=[directory URLByAppendingPathComponent:@"protected.jpg"];
                    NSData* previous=[@"previous output" dataUsingEncoding:NSUTF8StringEncoding];
                    [previous writeToURL:protectedOutput atomically:YES];
                    check(sony2fuji_hdr_export_jpeg(&pair,&config,protectedOutput.fileSystemRepresentation,&d)!=SONY2FUJI_STATUS_OK &&
                        d.reason==SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"unrelated metadata source was accepted");
                    check([previous isEqualToData:[NSData dataWithContentsOfURL:protectedOutput]],"failed metadata export replaced destination");
                    config.metadata_source_path=nullptr;
                    std::fill_n(config.source_sha256,32,0);
                    NSData* original=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
                    check(sony2fuji_hdr_export_jpeg(&pair,&config,path,&d)==SONY2FUJI_STATUS_INVALID_ARGUMENT,
                        "export was allowed to replace its decoded source without metadata_source_path");
                    check([original isEqualToData:[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]]],
                        "export changed the source container");
                    NSURL* output=[directory URLByAppendingPathComponent:@"output.jpg"];
                    status=sony2fuji_hdr_export_jpeg(&pair,&config,output.fileSystemRepresentation,&d);
                    if (status) std::cerr<<"export status="<<status<<" reason="<<d.reason<<'\n';
                    check(status==SONY2FUJI_STATUS_OK,"HDR JPEG export failed");
                    NSMutableData* conflicting=[[NSData dataWithContentsOfURL:output] mutableCopy];
                    const std::string capacityTag="hdrgm:HDRCapacityMax=\"";
                    auto* text=static_cast<char*>(conflicting.mutableBytes); auto* limit=text+conflicting.length;
                    auto* capacity=std::search(text,limit,capacityTag.begin(),capacityTag.end());
                    check(capacity!=limit,"missing XMP capacity in dual metadata output");
                    capacity+=capacityTag.size(); *capacity=*capacity=='1' ? '2' : '1';
                    NSURL* conflictingFile=[directory URLByAppendingPathComponent:@"conflicting-dual.jpg"];
                    check([conflicting writeToURL:conflictingFile atomically:YES],"cannot stage conflicting metadata");
                    // Apple 标记不能绕过实际 ISO/XMP 描述的一致性检查。
                    const char* appleMarker="urn:com:apple:photo:2020:aux:hdrgainmap";
                    [conflicting appendBytes:appleMarker length:std::strlen(appleMarker)];
                    check([conflicting writeToURL:conflictingFile atomically:YES],"cannot stage mixed protocol metadata");
                    auto conflictingInfo=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(conflictingFile.fileSystemRepresentation,&conflictingInfo,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"contradictory ISO/XMP descriptions were accepted");
                    NSMutableData* xmpOnly=[[NSData dataWithContentsOfURL:output] mutableCopy];
                    const std::string isoName="urn:iso:std:iso:ts:21496:-1";
                    auto* begin=static_cast<char*>(xmpOnly.mutableBytes); auto* end=begin+xmpOnly.length;
                    for (auto* found=std::search(begin,end,isoName.begin(),isoName.end()); found!=end;
                            found=std::search(found+isoName.size(),end,isoName.begin(),isoName.end()))
                        std::fill_n(found,isoName.size(),'x');
                    NSURL* xmpFile=[directory URLByAppendingPathComponent:@"xmp-only.jpg"];
                    check([xmpOnly writeToURL:xmpFile atomically:YES],"cannot stage XMP-only fixture");
                    auto xmpInfo=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(xmpFile.fileSystemRepresentation,&xmpInfo,&d)==SONY2FUJI_STATUS_OK &&
                        xmpInfo.protocol==SONY2FUJI_HDR_PROTOCOL_XMP,"synthesized ImageIO ISO dictionary mislabelled an XMP file");
                    NSMutableData* invalidXMP=[xmpOnly mutableCopy];
                    const std::string versionTag="hdrgm:Version";
                    auto* invalidBegin=static_cast<char*>(invalidXMP.mutableBytes); auto* invalidEnd=invalidBegin+invalidXMP.length;
                    auto* version=std::search(invalidBegin,invalidEnd,versionTag.begin(),versionTag.end());
                    check(version!=invalidEnd,"missing XMP version in test output");
                    for (;version!=invalidEnd;version=std::search(version+versionTag.size(),invalidEnd,versionTag.begin(),versionTag.end()))
                        std::fill_n(version,versionTag.size(),'x');
                    NSURL* invalidFile=[directory URLByAppendingPathComponent:@"invalid-xmp.jpg"];
                    check([invalidXMP writeToURL:invalidFile atomically:YES],"cannot stage malformed XMP");
                    auto invalidInfo=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(invalidFile.fileSystemRepresentation,&invalidInfo,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"malformed modern XMP was admitted as legacy Apple");
                    [invalidXMP appendBytes:appleMarker length:std::strlen(appleMarker)];
                    check([invalidXMP writeToURL:invalidFile atomically:YES],"cannot stage malformed XMP with Apple marker");
                    invalidInfo=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(invalidFile.fileSystemRepresentation,&invalidInfo,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"Apple marker bypassed malformed modern XMP validation");
                    auto roundtrip=init<sony2fuji_hdr_image_pair_v1>();
                    status=sony2fuji_hdr_decode(output.fileSystemRepresentation,&options,&roundtrip,&d);
                    if (status) std::cerr<<"roundtrip status="<<status<<" reason="<<d.reason<<'\n';
                    check(status==SONY2FUJI_STATUS_OK,
                        "exported JPEG could not be decoded");
                    check(roundtrip.hdr.content_headroom>1.5,"HDR JPEG lost edited headroom");
                    sony2fuji_hdr_release_pair(&roundtrip);
                    // 编辑后全图低于参考白仍是有效的增益图来源，不能按峰值误判成坏图。
                    sony2fuji_session* session=nullptr;
                    check(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK,"session creation failed");
                    auto settings=init<sony2fuji_hdr_request_v1>(); settings.hdr_processing_version=1;
                    settings.intent=SONY2FUJI_INTENT_FINAL; settings.temperature=6500;
                    settings.crop_width=settings.crop_height=1; settings.exposure_ev=-4;
                    auto dark=init<sony2fuji_hdr_image_pair_v1>();
                    check(sony2fuji_hdr_render(session,&pair,&settings,&dark,&d)==SONY2FUJI_STATUS_OK,"dark edit failed");
                    NSURL* darkOutput=[directory URLByAppendingPathComponent:@"dark.jpg"];
                    status=sony2fuji_hdr_export_jpeg(&dark,&config,darkOutput.fileSystemRepresentation,&d);
                    if (status) std::cerr<<"dark export status="<<status<<" reason="<<d.reason<<'\n';
                    check(status==SONY2FUJI_STATUS_OK,
                        "dark HDR encoding failed");
                    roundtrip=init<sony2fuji_hdr_image_pair_v1>();
                    status=sony2fuji_hdr_decode(darkOutput.fileSystemRepresentation,&options,&roundtrip,&d);
                    if (status) std::cerr<<"dark decode status="<<status<<" reason="<<d.reason<<'\n';
                    check(status==SONY2FUJI_STATUS_OK,"valid headroom-one HDR file rejected");
                    sony2fuji_hdr_release_pair(&roundtrip); sony2fuji_hdr_release_pair(&dark);
                    sony2fuji_session_destroy(session);
                    auto sdrConfig=init<sony2fuji_hdr_sdr_export_config_v1>();
                    sdrConfig.output_format=SONY2FUJI_OUTPUT_JPEG; sdrConfig.quality=95;
                    sdrConfig.metadata_source_path=other.fileSystemRepresentation;
                    std::copy_n(otherInfo.source_sha256,32,sdrConfig.source_sha256);
                    check(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,protectedOutput.fileSystemRepresentation,&d)!=SONY2FUJI_STATUS_OK &&
                        d.reason==SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"SDR export accepted unrelated metadata source");
                    check([previous isEqualToData:[NSData dataWithContentsOfURL:protectedOutput]],"failed SDR metadata export replaced destination");
                    sdrConfig.metadata_source_path=nullptr; std::fill_n(sdrConfig.source_sha256,32,0);
                    NSURL* sdrOutput=[directory URLByAppendingPathComponent:@"sdr.jpg"];
                    check(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,sdrOutput.fileSystemRepresentation,&d)==SONY2FUJI_STATUS_OK,
                        "SDR rendition export failed");
                    info=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(sdrOutput.fileSystemRepresentation,&info,&d)==SONY2FUJI_STATUS_UNSUPPORTED,
                        "ordinary SDR export retained gain-map metadata");
                    check(d.reason==SONY2FUJI_HDR_REASON_NOT_HDR,
                        "ordinary SDR is indistinguishable from unsupported or damaged HDR");
                    NSMutableData* falseApple=[[NSData dataWithContentsOfURL:sdrOutput] mutableCopy];
                    [falseApple appendBytes:appleMarker length:std::strlen(appleMarker)];
                    NSURL* falseAppleFile=[directory URLByAppendingPathComponent:@"false-apple.jpg"];
                    check([falseApple writeToURL:falseAppleFile atomically:YES],"cannot stage missing Apple gain map");
                    info=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(falseAppleFile.fileSystemRepresentation,&info,&d)==SONY2FUJI_STATUS_PROCESSING_ERROR &&
                        d.reason==SONY2FUJI_HDR_REASON_MALFORMED_AUX,"Apple marker without a gain map was accepted");
                    sdrConfig.output_format=SONY2FUJI_OUTPUT_PNG;
                    NSURL* pngOutput=[directory URLByAppendingPathComponent:@"sdr.png"];
                    check(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,pngOutput.fileSystemRepresentation,&d)==SONY2FUJI_STATUS_OK,
                        "SDR PNG export failed");
                    NSData* png=[NSData dataWithContentsOfURL:pngOutput];
                    check(png.length>25 && static_cast<const uint8_t*>(png.bytes)[24]==16,"SDR PNG lost existing 16-bit precision");
                    sdrConfig.output_format=SONY2FUJI_OUTPUT_DNG;
                    NSURL* dngOutput=[directory URLByAppendingPathComponent:@"sdr.dng"];
                    check(sony2fuji_hdr_export_sdr(&pair,&sdrConfig,dngOutput.fileSystemRepresentation,&d)==SONY2FUJI_STATUS_OK,
                        "SDR rendered DNG export failed");
                    TIFF* dng=TIFFOpen(dngOutput.fileSystemRepresentation,"r");
                    check(dng,"cannot inspect rendered DNG");
                    uint16_t bits=0,format=0; uint32_t w=0,height=0;
                    TIFFGetField(dng,TIFFTAG_BITSPERSAMPLE,&bits); TIFFGetField(dng,TIFFTAG_SAMPLEFORMAT,&format);
                    TIFFGetField(dng,TIFFTAG_IMAGEWIDTH,&w); TIFFGetField(dng,TIFFTAG_IMAGELENGTH,&height);
                    std::vector<float> row(w*3);
                    const bool read=TIFFReadScanline(dng,row.data(),0,0)>=0; TIFFClose(dng);
                    check(read && bits==32 && format==SAMPLEFORMAT_IEEEFP && w==pair.sdr.width && height==pair.sdr.height,
                        "SDR DNG format/canvas changed");
                    const auto* expected=static_cast<const float*>(pair.sdr.data);
                    for (size_t i=0;i<row.size();++i)
                        check(std::abs(row[i]-std::clamp(expected[i],0.0f,1.0f))<1e-6f,"SDR DNG used HDR or the wrong transfer");
                    NSURL* damaged=[directory URLByAppendingPathComponent:@"damaged.jpg"];
                    NSData* source=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
                    check([[source subdataWithRange:NSMakeRange(0,source.length/2)] writeToURL:damaged atomically:YES],
                        "cannot stage damaged auxiliary fixture");
                    info=init<sony2fuji_hdr_source_info_v1>();
                    check(sony2fuji_hdr_probe(damaged.fileSystemRepresentation,&info,&d)!=SONY2FUJI_STATUS_OK &&
                        d.reason!=SONY2FUJI_HDR_REASON_NOT_HDR,"damaged HDR was classified as ordinary SDR");
                    sony2fuji_hdr_release_pair(&pair);
                }
                [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
                std::cout << "PASS hdr_image_decode\n"; return 0;
            } catch (const std::exception& e) {
                if (std::getenv("RAWLAB_HDR_KEEP_TEST")) std::cerr<<"fixture directory="<<directory.fileSystemRepresentation<<'\n';
                else [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
                std::cerr << "FAIL: " << e.what() << '\n'; return 1;
            }
        }
        return 77;
    }
}
