#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#define HDR_AVAILABLE API_AVAILABLE(macos(15.0), ios(18.0))

#if RAWLAB_HDR_ULTRAHDR
NSData* makeUltraHDRJPEG(bool rgb);
void checkUltraHDRJPEG(NSData* data, bool rgb);
#endif
#if RAWLAB_HDR_PRODUCTION
void checkProductionHDR(NSData* data);
void checkProductionFile(const char* path,bool final);
#endif

namespace {

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

CIContext* makeContext() {
    return [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES,
        kCIContextWorkingFormat: @(kCIFormatRGBAf)}];
}

struct Fixture {
    CIImage* hdr;
    CIImage* sdr;
};

Fixture makeFixture(bool colorMap) HDR_AVAILABLE {
    constexpr size_t width = 96, height = 64;
    std::vector<float> hdr(width * height * 4), sdr(hdr.size());
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            const float base[] = {0.18f, 0.5f, 0.8f};
            const float boost = 1.0f + static_cast<float>(x / 24);
            for (size_t c = 0; c < 3; ++c) {
                const size_t index = (y * width + x) * 4 + c;
                sdr[index] = base[c];
                hdr[index] = base[c] * (colorMap ? std::min(4.0f, boost + c * 0.25f) : boost);
            }
            sdr[(y * width + x) * 4 + 3] = hdr[(y * width + x) * 4 + 3] = 1;
        }
    }
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    require(linear != nullptr, "extended-linear color space unavailable");
    CIImage* hdrImage = [CIImage imageWithBitmapData:[NSData dataWithBytes:hdr.data() length:hdr.size() * sizeof(float)]
        bytesPerRow:width * 4 * sizeof(float) size:CGSizeMake(width, height) format:kCIFormatRGBAf colorSpace:linear];
    CIImage* sdrImage = [CIImage imageWithBitmapData:[NSData dataWithBytes:sdr.data() length:sdr.size() * sizeof(float)]
        bytesPerRow:width * 4 * sizeof(float) size:CGSizeMake(width, height) format:kCIFormatRGBAf colorSpace:linear];
    CGImageRef cg = [makeContext() createCGImage:hdrImage fromRect:hdrImage.extent format:kCIFormatRGBAf colorSpace:linear];
    CGImageRef tagged = cg ? CGImageCreateCopyWithContentHeadroom(4.0f, cg) : nullptr;
    CIImage* taggedImage = tagged ? [CIImage imageWithCGImage:tagged] : nil;
    if (tagged) CGImageRelease(tagged);
    if (cg) CGImageRelease(cg);
    CGColorSpaceRelease(linear);
    require(taggedImage && sdrImage, "cannot construct HDR/SDR reference pair");
    return {taggedImage, sdrImage};
}

NSData* encode(const Fixture& fixture, bool rgb, bool heic) HDR_AVAILABLE {
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSDictionary* options = @{kCIImageRepresentationHDRImage: fixture.hdr,
        kCIImageRepresentationHDRGainMapAsRGB: @(rgb),
        (__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @0.95};
    NSData* data = heic
        // RGBA 会在 HEIF 中保留 alpha 平面，即使样本的 alpha 全为 1；手机照片合同要求不透明容器。
        ? [makeContext() HEIFRepresentationOfImage:fixture.sdr format:kCIFormatRGBX8 colorSpace:srgb options:options]
        : [makeContext() JPEGRepresentationOfImage:fixture.sdr colorSpace:srgb options:options];
    CGColorSpaceRelease(srgb);
    require(data.length > 0, "system gain-map encoder produced no file");
    return data;
}

NSDictionary* isoMap(NSData* data) HDR_AVAILABLE {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    CFDictionaryRef map = source ? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) : nullptr;
    if (source) CFRelease(source);
    return CFBridgingRelease(map);
}

std::vector<float> pixels(CIImage* image) {
    require(image && !CGRectIsEmpty(image.extent) && !CGRectIsInfinite(image.extent), "invalid decoded image");
    const CGRect bounds = CGRectIntegral(image.extent);
    require(std::isfinite(bounds.size.width) && std::isfinite(bounds.size.height) &&
        bounds.size.width > 0 && bounds.size.width <= 4096 && bounds.size.height > 0 && bounds.size.height <= 4096,
        "codec probe fixture exceeds its bounded allocation");
    const size_t width = static_cast<size_t>(bounds.size.width);
    const size_t height = static_cast<size_t>(bounds.size.height);
    std::vector<float> result(width * height * 4);
    CGColorSpaceRef linear = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    [makeContext() render:image toBitmap:result.data() rowBytes:width * 4 * sizeof(float)
        bounds:bounds format:kCIFormatRGBAf colorSpace:linear];
    CGColorSpaceRelease(linear);
    require(std::all_of(result.begin(), result.end(), [](float x) { return std::isfinite(x); }), "nonfinite decoded pixels");
    return result;
}

CIImage* decodeHDR(NSData* data) HDR_AVAILABLE {
    if (std::getenv("RAWLAB_HDR_PROBE_IMAGEIO")) {
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
        if (!source) return nil;
        NSDictionary* options = @{(__bridge NSString*)kCGImageSourceDecodeRequest: (__bridge NSString*)kCGImageSourceDecodeToHDR,
            (__bridge NSString*)kCGImageSourceShouldAllowFloat: @YES};
        CGImageRef cg = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
        CIImage* result = cg ? [CIImage imageWithCGImage:cg] : nil;
        const int orientation = [properties[(__bridge NSString*)kCGImagePropertyOrientation] intValue];
        if (orientation >= 1 && orientation <= 8) result = [result imageByApplyingOrientation:orientation];
        if (cg) CGImageRelease(cg);
        CFRelease(source);
        return result;
    }
    // 默认读取只返回 SDR 底图，HDR 主图必须显式展开增益图。
    return [CIImage imageWithData:data options:@{kCIImageApplyOrientationProperty: @YES, kCIImageExpandToHDR: @YES}];
}

void checkPair(NSData* data) HDR_AVAILABLE {
    require(isoMap(data) != nil, "encoded file has no ISO auxiliary gain map");
    CIImage* hdr = decodeHDR(data);
    CIImage* sdr = [CIImage imageWithData:data options:@{kCIImageApplyOrientationProperty: @YES,kCIImageExpandToHDR:@NO}];
    require(hdr && sdr && CGRectEqualToRect(hdr.extent, sdr.extent), "HDR/SDR canvases differ");
    const auto h = pixels(hdr), s = pixels(sdr);
    const float hdrPeak = *std::max_element(h.begin(), h.end());
    const float sdrPeak = *std::max_element(s.begin(), s.end());
    std::cout << "hdr_peak=" << hdrPeak << " sdr_peak=" << sdrPeak << " content_headroom=" << hdr.contentHeadroom << '\n';
    require(hdrPeak > 1.5f, "HDR decoding lost super-white pixels");
    require(hdr.contentHeadroom > 1, "decoded HDR headroom was not retained");
    require(sdrPeak <= 1.01f, "SDR base is not an SDR rendition");
}

NSData* oriented(NSData* data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    NSMutableData* output = [NSMutableData data];
    CGImageDestinationRef destination = source ? CGImageDestinationCreateWithData((__bridge CFMutableDataRef)output,
        CGImageSourceGetType(source), 1, nullptr) : nullptr;
    require(destination != nullptr, "cannot create oriented fixture");
    NSDictionary* properties = @{(__bridge NSString*)kCGImagePropertyOrientation: @6};
    CGImageDestinationAddImageFromSource(destination, source, 0, (__bridge CFDictionaryRef)properties);
    if (@available(macOS 15.0, iOS 18.0, *)) {
        CFDictionaryRef map = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap);
        require(map != nullptr, "orientation source lost its gain map");
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeISOGainMap, map);
        CFRelease(map);
    }
    bool success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CFRelease(source);
    require(success, "cannot finalize oriented fixture");
    return output;
}

void run(const std::string& name) HDR_AVAILABLE {
#if RAWLAB_HDR_PRODUCTION
    if (name.rfind("production_",0)==0) {
        const auto kind=name.substr(11);
        NSData* data=kind=="ultrahdr" ? makeUltraHDRJPEG(true) : encode(makeFixture(kind=="rgb_map"),kind=="rgb_map",kind=="heic");
        if (kind=="orientation") data=oriented(data);
        checkProductionHDR(data); return;
    }
#endif
#if RAWLAB_HDR_ULTRAHDR
    if (name == "ultrahdr" || name == "dual_metadata") {
        NSData* data = makeUltraHDRJPEG(name == "dual_metadata");
        checkUltraHDRJPEG(data, name == "dual_metadata");
        checkPair(data);
        return;
    }
#endif
    const Fixture fixture = makeFixture(name == "rgb_map");
    NSData* data = encode(fixture, name == "rgb_map", name == "heic");
    if (name == "bad_aux") {
        NSData* truncated = [data subdataWithRange:NSMakeRange(0, data.length / 2)];
        require(isoMap(truncated) == nil, "truncated auxiliary image must not be treated as valid");
        return;
    }
    if (name == "orientation") {
        data = oriented(data);
        checkPair(data);
        CIImage* hdr = decodeHDR(data);
        CIImage* sdr = [CIImage imageWithData:data options:@{kCIImageApplyOrientationProperty: @YES}];
        require(hdr.extent.size.width == 64 && hdr.extent.size.height == 96, "EXIF orientation not applied exactly once");
        require(CGRectEqualToRect(hdr.extent, sdr.extent), "oriented HDR/SDR canvases differ");
        return;
    }
    checkPair(data);
    if (name == "rgb_map") {
        NSDictionary* description = isoMap(data)[(__bridge NSString*)kCGImageAuxiliaryDataInfoDataDescription];
        std::cout << "map_description=" << description.description.UTF8String << '\n';
        require(description != nil, "RGB gain map description missing");
    }
}

void inspectExternal(const char* path) HDR_AVAILABLE {
    NSData* data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    require(data.length > 0, "cannot read external fixture");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    require(source != nullptr, "cannot identify external image");
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    NSDictionary* iso = isoMap(data);
    NSDictionary* legacy = CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0,
        kCGImageAuxiliaryDataTypeHDRGainMap));
    CFRelease(source);
    require(iso || legacy, "external image has no supported auxiliary gain map");
    const uint64_t width = [properties[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    const uint64_t height = [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    require(width > 0 && height > 0 && width <= 128000000 / height, "external image exceeds source pixel budget");
    CIImage* hdr = decodeHDR(data);
    CIImage* sdr = [CIImage imageWithData:data options:@{kCIImageApplyOrientationProperty: @YES}];
    require(hdr && sdr && CGRectEqualToRect(hdr.extent, sdr.extent), "external HDR/SDR canvases differ");
    const CGSize orientedSize = hdr.extent.size;
    const float headroom = hdr.contentHeadroom;
    const CGFloat scale = std::min(1.0, 1024.0 / std::max(hdr.extent.size.width, hdr.extent.size.height));
    hdr = [hdr imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    sdr = [sdr imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    const auto h = pixels(hdr), s = pixels(sdr);
    require(h.size() == s.size(), "external decoded buffer sizes differ");
    double difference = 0;
    for (size_t i = 0; i < h.size(); ++i) if (i % 4 != 3) difference += std::abs(h[i] - s[i]);
    const double meanDifference = difference / (h.size() / 4 * 3);
    const std::string container(static_cast<const char*>(data.bytes),data.length);
    const bool xmp=container.find("http://ns.adobe.com/hdr-gain-map/1.0/")!=std::string::npos;
    const bool declaredISO=container.find("urn:iso:std:iso:ts:21496:-1")!=std::string::npos;
    NSDictionary* report = @{
        @"protocol": xmp ? (declaredISO ? @"iso_xmp" : @"xmp") : (iso ? @"iso" : @"apple_legacy"),
        @"source_width": @(width), @"source_height": @(height),
        @"headroom": @(headroom), @"hdr_peak": @(*std::max_element(h.begin(), h.end())),
        @"sdr_peak": @(*std::max_element(s.begin(), s.end())), @"mean_linear_difference": @(meanDifference),
        @"oriented_width": @(orientedSize.width), @"oriented_height": @(orientedSize.height)
    };
    NSData* json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    std::cout.write(static_cast<const char*>(json.bytes), static_cast<std::streamsize>(json.length));
    std::cout << '\n';
    require(headroom > 1 && meanDifference > 0.001, "external gain map did not produce a distinct HDR representation");
}

} // namespace

#if RAWLAB_HDR_DEVICE_APP
int rawlabHDRCodecMain(int argc, const char* argv[]) {
#else
int main(int argc, const char* argv[]) {
#endif
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
#if RAWLAB_HDR_PRODUCTION
            if (argc==3 && (std::string(argv[1])=="production_external" || std::string(argv[1])=="production_external_final")) {
                try { checkProductionFile(argv[2],std::string(argv[1])=="production_external_final"); return 0; }
                catch (const std::exception& error) { std::cerr<<"FAIL production: "<<error.what()<<'\n'; return 1; }
            }
#endif
            if (argc == 3 && std::string(argv[1]) == "external") {
                try { inspectExternal(argv[2]); return 0; }
                catch (const std::exception& error) { std::cerr << "FAIL external: " << error.what() << '\n'; return 1; }
            }
            if (argc != 2) { std::cerr << "usage: hdr_codec_probe CASE\n"; return 2; }
            const std::string name = argv[1];
            std::vector<std::string> cases{"iso", "rgb_map", "heic", "orientation", "bad_aux"};
#if RAWLAB_HDR_ULTRAHDR
            cases.insert(cases.end(), {"ultrahdr", "dual_metadata"});
#endif
#if RAWLAB_HDR_PRODUCTION
            cases.insert(cases.end(),{"production_iso","production_rgb_map","production_heic","production_orientation","production_ultrahdr"});
#endif
            if (std::find(cases.begin(), cases.end(), name) == cases.end()) return 2;
            try {
                run(name);
                std::cout << "PASS hdr_codec_" << name << '\n';
                return 0;
            } catch (const std::exception& error) {
                std::cerr << "FAIL hdr_codec_" << name << ": " << error.what() << '\n';
                return 1;
            }
        }
        std::cerr << "SKIP: HDR codec probe requires macOS 15 / iOS 18\n";
        return 77;
    }
}
