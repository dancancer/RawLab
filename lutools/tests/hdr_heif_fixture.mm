#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <stdexcept>
#include <vector>

std::vector<uint8_t> authorAppleJPEG(const char* path) {
    @autoreleasepool {
        auto url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        auto source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,nullptr);
        if(!source)throw std::runtime_error("Cannot read Apple gain-map reference");
        auto auxiliary=CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeHDRGainMap);
        auto data=[NSMutableData data];auto destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,nullptr);
        if(!auxiliary || !destination) {if(auxiliary)CFRelease(auxiliary);if(destination)CFRelease(destination);CFRelease(source);throw std::runtime_error("Cannot author Apple JPEG");}
        CGImageDestinationAddImageFromSource(destination,source,0,nullptr);
        CGImageDestinationAddAuxiliaryDataInfo(destination,kCGImageAuxiliaryDataTypeHDRGainMap,auxiliary);
        const bool okay=CGImageDestinationFinalize(destination);CFRelease(destination);CFRelease(auxiliary);CFRelease(source);
        if(!okay)throw std::runtime_error("Cannot finalize Apple JPEG");
        const auto* bytes=static_cast<const uint8_t*>(data.bytes);return {bytes,bytes+data.length};
    }
}

std::vector<uint8_t> authorISOHEIF() {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            std::vector<float> h(64*32*4),s(h.size());
            for (size_t i=0;i<h.size();++i) {
                const float base[]={.18f,.4f,.7f,1}; s[i]=base[i%4];
                h[i]=i%4==3 ? 1 : s[i]*(1+float(i/4%64)/16);
            }
            auto linear=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
            auto srgb=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            auto image=[&](const std::vector<float>& pixels) { return [CIImage imageWithBitmapData:
                [NSData dataWithBytes:pixels.data() length:pixels.size()*4] bytesPerRow:64*16 size:CGSizeMake(64,32)
                format:kCIFormatRGBAf colorSpace:linear]; };
            auto* context=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
            CGImageRef cg=[context createCGImage:image(h) fromRect:CGRectMake(0,0,64,32) format:kCIFormatRGBAf colorSpace:linear];
            CGImageRef tagged=cg ? CGImageCreateCopyWithContentHeadroom(4,cg) : nullptr;
            if (!tagged) { if (cg) CGImageRelease(cg); CGColorSpaceRelease(linear); CGColorSpaceRelease(srgb); throw std::runtime_error("Cannot author HEIF HDR reference"); }
            NSData* bytes=[context HEIFRepresentationOfImage:image(s) format:kCIFormatRGBX8 colorSpace:srgb
                options:@{kCIImageRepresentationHDRImage:[CIImage imageWithCGImage:tagged]}];
            CGImageRelease(tagged); CGImageRelease(cg); CGColorSpaceRelease(linear); CGColorSpaceRelease(srgb);
            if (!bytes.length) throw std::runtime_error("Cannot author ISO HEIF fixture");
            const auto* data=static_cast<const uint8_t*>(bytes.bytes); return {data,data+bytes.length};
        }
        throw std::runtime_error("ISO HEIF test author requires macOS15/iOS18");
    }
}
