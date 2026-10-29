#include "platform/hdr_image.h"
#include "core/hdr_jpeg.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>

namespace sony2fuji::hdr {
namespace {
#define HDR_AVAILABLE API_AVAILABLE(macos(15.0), ios(18.0))
std::atomic<uint64_t> revision{1};

[[noreturn]] void error(sony2fuji_status status, uint32_t reason, const char* message) {
    throw Error(status, reason, SONY2FUJI_HDR_FIELD_PATH, message);
}
void require(bool condition, uint32_t reason, const char* message) {
    if (!condition) error(SONY2FUJI_STATUS_PROCESSING_ERROR, reason, message);
}

struct File {
    NSData* data = nil;
    NSDictionary* properties = nil;
    CGImageSourceRef source = nullptr;
    sony2fuji_hdr_source_info_v1 info{};
    ~File() { if (source) CFRelease(source); }
};

bool has(NSData* data, const char* marker) {
    const auto* begin = static_cast<const char*>(data.bytes);
    return std::search(begin, begin + data.length, marker, marker + std::strlen(marker)) != begin + data.length;
}

bool declaresGainMap(NSData* data) {
    return has(data,"urn:iso:std:iso:ts:21496:-1") || has(data,"http://ns.adobe.com/hdr-gain-map/1.0/") ||
        has(data,"urn:com:apple:photo:2020:aux:hdrgainmap") || has(data,"http://ns.apple.com/HDRGainMap/1.0/");
}

void validateMap(NSDictionary* map) {
    NSDictionary* description = map[(__bridge NSString*)kCGImageAuxiliaryDataInfoDataDescription];
    NSData* data = map[(__bridge NSString*)kCGImageAuxiliaryDataInfoData];
    // ImageIO 可返回仅含描述/元数据的 ISO map；像素仍在原 JPEG 的辅助码流中。
    // 这类 JPEG 还必须通过共享 codec 的 MPF/ISO probe，不能把缺少字典 Data 当作截断。
    require([description isKindOfClass:NSDictionary.class] && (!data || [data isKindOfClass:NSData.class]),
        SONY2FUJI_HDR_REASON_MALFORMED_AUX, "Invalid auxiliary description");
    const uint64_t width = [description[(__bridge NSString*)kCGImagePropertyWidth] unsignedLongLongValue];
    const uint64_t height = [description[(__bridge NSString*)kCGImagePropertyHeight] unsignedLongLongValue];
    const uint64_t stride = [description[(__bridge NSString*)kCGImagePropertyBytesPerRow] unsignedLongLongValue];
    require(width && height && width <= 128000000 / height && stride >= width &&
        stride <= SIZE_MAX / height && (!data || stride * height <= data.length),
        SONY2FUJI_HDR_REASON_MALFORMED_AUX, "Invalid auxiliary dimensions or storage");
}

void read(File& file, const char* path) {
    NSString* name = [NSString stringWithUTF8String:path];
    if (!name) error(SONY2FUJI_STATUS_INVALID_ARGUMENT, SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, "Invalid UTF-8 HDR path");
    NSNumber* regular = nil;
    NSURL* url = [NSURL fileURLWithPath:name];
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    if (!regular.boolValue) error(SONY2FUJI_STATUS_IO_ERROR, SONY2FUJI_HDR_REASON_INPUT_IO, "HDR source is not a regular file");
    file.data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!file.data.length) error(SONY2FUJI_STATUS_IO_ERROR, SONY2FUJI_HDR_REASON_INPUT_IO, "Cannot read HDR source");
    file.source = CGImageSourceCreateWithData((__bridge CFDataRef)file.data,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceShouldCache:@NO});
    require(file.source, SONY2FUJI_HDR_REASON_MALFORMED_AUX, "Cannot parse HDR container");
    const CFStringRef type = CGImageSourceGetType(file.source);
    file.info.version = 1; file.info.struct_size = sizeof(file.info);
    if (type && CFEqual(type, CFSTR("public.jpeg"))) file.info.container = SONY2FUJI_HDR_CONTAINER_JPEG;
    else if (type && (CFEqual(type, CFSTR("public.heic")) || CFEqual(type, CFSTR("public.heif"))))
        file.info.container = SONY2FUJI_HDR_CONTAINER_HEIF;
    else error(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL, "Unsupported HDR container");
    if (CGImageSourceGetCount(file.source) != 1)
        error(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL, "HDR input must have one primary image");
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(file.source, 0, nullptr));
    file.properties=properties;
    const uint64_t width = [properties[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    const uint64_t height = [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    require(width && height && width <= 128000000 / height, SONY2FUJI_HDR_REASON_INVALID_BUFFER, "HDR source pixel budget exceeded");
    if ([properties[(__bridge NSString*)kCGImagePropertyHasAlpha] boolValue])
        error(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR, "HDR input must be opaque");
    file.info.width = uint32_t(width); file.info.height = uint32_t(height);
    const uint32_t orientation = [properties[(__bridge NSString*)kCGImagePropertyOrientation] unsignedIntValue];
    require(orientation <= 8, SONY2FUJI_HDR_REASON_INVALID_BUFFER, "Invalid EXIF orientation");
    file.info.orientation = orientation ? orientation : 1;
}

void open(File& file, const char* path) HDR_AVAILABLE {
    read(file,path);
    const bool xmp=file.info.container==SONY2FUJI_HDR_CONTAINER_JPEG && has(file.data,"http://ns.adobe.com/hdr-gain-map/1.0/");
    const bool isoDeclared=file.info.container==SONY2FUJI_HDR_CONTAINER_JPEG && has(file.data,"urn:iso:std:iso:ts:21496:-1");
    // 旧式 Apple JPEG 也使用 Adobe namespace；以原容器的辅助类型区分，不能依赖 ImageIO 合成的 ISO 字典。
    const bool appleDeclared=!isoDeclared && (has(file.data,"urn:com:apple:photo:2020:aux:hdrgainmap") ||
        has(file.data,"http://ns.apple.com/HDRGainMap/1.0/"));
    const bool modernJPEG=file.info.container==SONY2FUJI_HDR_CONTAINER_JPEG &&
        (isoDeclared || (xmp && !appleDeclared));
    JPEGInfo jpeg;
    if (modernJPEG) {
        // 先检查压缩辅助图，避免原生接口为坏引用分配像素或只交付底图。
        jpeg=probeJPEG(file.data.bytes,file.data.length);
        require(jpeg.width==file.info.width && jpeg.height==file.info.height,
            SONY2FUJI_HDR_REASON_MALFORMED_AUX,"JPEG metadata canvases disagree");
    }
    NSDictionary* iso = CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file.source, 0, kCGImageAuxiliaryDataTypeISOGainMap));
    NSDictionary* apple = CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file.source, 0, kCGImageAuxiliaryDataTypeHDRGainMap));
    if (iso && !appleDeclared) validateMap(iso);
    // ImageIO 也会为旧 Android XMP 照片合成 ISO 字典；文件协议由原容器决定。
    if (modernJPEG) file.info.protocol=isoDeclared ? (xmp ? SONY2FUJI_HDR_PROTOCOL_ISO_XMP : SONY2FUJI_HDR_PROTOCOL_ISO) : SONY2FUJI_HDR_PROTOCOL_XMP;
    else if (appleDeclared) {
        require(apple,SONY2FUJI_HDR_REASON_MALFORMED_AUX,"Declared Apple gain map cannot be read");
        validateMap(apple); file.info.protocol=SONY2FUJI_HDR_PROTOCOL_APPLE;
    }
    else if (iso) file.info.protocol=SONY2FUJI_HDR_PROTOCOL_ISO;
    else if (apple) { validateMap(apple); file.info.protocol = SONY2FUJI_HDR_PROTOCOL_APPLE; }
    else if (declaresGainMap(file.data))
        error(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_MALFORMED_AUX,"Declared gain map cannot be read");
    else error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_NOT_HDR,"No HDR gain map");
    CIImage* expanded = [CIImage imageWithData:file.data options:@{kCIImageExpandToHDR:@YES}];
    require(expanded, SONY2FUJI_HDR_REASON_MALFORMED_AUX, "Cannot construct HDR representation");
    CGColorSpaceRef color = expanded.colorSpace;
    if (!color || CGColorSpaceGetModel(color) != kCGColorSpaceModelRGB)
        error(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR, "Missing RGB color interpretation");
    CFStringRef colorName = CGColorSpaceCopyName(color);
    NSString* profile = file.properties[(__bridge NSString*)kCGImagePropertyProfileName];
    if ((colorName && (CFEqual(colorName,kCGColorSpaceDisplayP3) || CFEqual(colorName,kCGColorSpaceExtendedLinearDisplayP3))) ||
        (profile && [profile rangeOfString:@"P3" options:NSCaseInsensitiveSearch].location != NSNotFound))
        file.info.color_description = SONY2FUJI_HDR_COLOR_DISPLAY_P3;
    else if ((colorName && (CFEqual(colorName,kCGColorSpaceITUR_2020) || CFEqual(colorName,kCGColorSpaceExtendedLinearITUR_2020))) ||
        (profile && [profile rangeOfString:@"2020" options:NSCaseInsensitiveSearch].location != NSNotFound))
        file.info.color_description = SONY2FUJI_HDR_COLOR_BT2020;
    else if ((colorName && (CFEqual(colorName,kCGColorSpaceSRGB) || CFEqual(colorName,kCGColorSpaceExtendedSRGB) ||
            CFEqual(colorName,kCGColorSpaceExtendedLinearSRGB))) ||
        (profile && [profile rangeOfString:@"sRGB" options:NSCaseInsensitiveSearch].location != NSNotFound))
        file.info.color_description = SONY2FUJI_HDR_COLOR_SRGB;
    if (colorName) CFRelease(colorName);
    const float headroom = expanded.contentHeadroom;
    require(std::isfinite(headroom) && headroom >= 1, SONY2FUJI_HDR_REASON_NONFINITE, "Invalid source content headroom");
    file.info.content_headroom = headroom; file.info.headroom_kind = SONY2FUJI_HDR_HEADROOM_DECLARED;
    if (file.info.container==SONY2FUJI_HDR_CONTAINER_JPEG && file.info.protocol!=SONY2FUJI_HDR_PROTOCOL_APPLE) {
        if (!modernJPEG) jpeg=probeJPEG(file.data.bytes,file.data.length);
        file.info.content_headroom=jpeg.headroom;
    }
    // 源身份不依赖路径/mtime，元数据保存使用同一 SHA-256 校验原容器。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256_CTX digest; CC_SHA256_Init(&digest);
    const auto* bytes = static_cast<const uint8_t*>(file.data.bytes);
    for (size_t offset = 0; offset < file.data.length;) {
        const size_t count = std::min<size_t>(file.data.length-offset, 1024*1024);
        CC_SHA256_Update(&digest,bytes+offset,CC_LONG(count)); offset+=count;
    }
    CC_SHA256_Final(file.info.source_sha256,&digest);
#pragma clang diagnostic pop
}

ImageData pixels(CIContext* context, CIImage* input, int width, int height) {
    ImageData result(width, height);
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    if (!color) throw std::bad_alloc();
    std::unique_ptr<std::remove_pointer_t<CGColorSpaceRef>, decltype(&CGColorSpaceRelease)> managed(color, CGColorSpaceRelease);
    // 分条取 CGImage 的上向下存储，避免额外常驻整张 RGBA32F；工作图也是左上起点。
    for (int top = 0; top < height; top += 128) {
        @autoreleasepool {
            const int rows = std::min(128, height-top);
            CGImageRef image = [context createCGImage:input fromRect:CGRectMake(0,height-top-rows,width,rows)
                format:kCIFormatRGBAf colorSpace:color];
            require(image, SONY2FUJI_HDR_REASON_INVALID_BUFFER, "HDR pixel rendering failed");
            CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
            const size_t stride = CGImageGetBytesPerRow(image);
            const bool valid = data && CGImageGetBitsPerComponent(image)==32 && CGImageGetBitsPerPixel(image)==128 &&
                stride >= size_t(width)*16 && stride <= SIZE_MAX/rows && CFDataGetLength(data) >= CFIndex(stride*rows);
            if (!valid) {
                if (data) CFRelease(data); CGImageRelease(image);
                error(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_INVALID_BUFFER,"Invalid native HDR storage");
            }
            const uint8_t* bytes=CFDataGetBytePtr(data);
            bool finite=true, opaque=true;
            for (int y=0;y<rows;++y) for (int x=0;x<width;++x) {
                float rgba[4]; std::memcpy(rgba,bytes+y*stride+x*16,16);
                for (float c:rgba) finite &= std::isfinite(c);
                opaque &= std::abs(rgba[3]-1)<1e-5f;
                result.at(x,top+y)={rgba[0],rgba[1],rgba[2]};
            }
            CFRelease(data); CGImageRelease(image);
            require(finite,SONY2FUJI_HDR_REASON_NONFINITE,"Native HDR contains nonfinite pixels");
            require(opaque,SONY2FUJI_HDR_REASON_UNSUPPORTED_COLOR,"Native HDR contains transparency");
        }
    }
    return result;
}

DecodedImage decode(File& file, const sony2fuji_hdr_decode_options_v1& options) HDR_AVAILABLE {
    CIImage* h=[CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@YES}];
    CIImage* s=[CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@NO}];
    require(h && s && CGRectEqualToRect(h.extent,s.extent),SONY2FUJI_HDR_REASON_MALFORMED_AUX,"HDR/SDR canvases differ");
    const bool swapped=file.info.orientation>=5;
    const uint32_t nativeWidth=swapped ? file.info.height : file.info.width;
    const uint32_t nativeHeight=swapped ? file.info.width : file.info.height;
    require(h.extent.size.width==nativeWidth && h.extent.size.height==nativeHeight,
        SONY2FUJI_HDR_REASON_INVALID_BUFFER,"Decoded HDR canvas differs from metadata");
    uint32_t width=nativeWidth,height=nativeHeight;
    if (options.intent==SONY2FUJI_INTENT_PREVIEW && options.long_edge && std::max(width,height)>options.long_edge) {
        const double scale=double(options.long_edge)/std::max(width,height);
        width=std::max(1u,uint32_t(std::lround(width*scale))); height=std::max(1u,uint32_t(std::lround(height*scale)));
    }
    admitMemory(uint64_t(width)*height*48);
    auto resize=[&](CIImage* image) {
        image=[image imageByApplyingTransform:CGAffineTransformMakeTranslation(-image.extent.origin.x,-image.extent.origin.y)];
        if (width!=nativeWidth || height!=nativeHeight)
            image=[image imageByApplyingTransform:CGAffineTransformMakeScale(double(width)/nativeWidth,double(height)/nativeHeight)];
        return image;
    };
    CIContext* context=[CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf),kCIContextCacheIntermediates:@NO,
        kCIContextUseSoftwareRenderer:@YES}];
    DecodedImage result; result.info=file.info;
    if (h.contentHeadroom<=1 && file.info.container==SONY2FUJI_HDR_CONTAINER_JPEG &&
            file.info.protocol!=SONY2FUJI_HDR_PROTOCOL_APPLE) {
        result.pixels.hdr=decodeJPEG(file.data.bytes,file.data.length,
            options.intent==SONY2FUJI_INTENT_PREVIEW ? options.long_edge : 0);
        GeometryOptions geometry;
        switch (file.info.orientation) {
            case 2: geometry.flip_horizontal=true; break;
            case 3: geometry.quarter_turns=2; break;
            case 4: geometry.flip_vertical=true; break;
            case 5: geometry.quarter_turns=1; geometry.flip_horizontal=true; break;
            case 6: geometry.quarter_turns=1; break;
            case 7: geometry.quarter_turns=1; geometry.flip_vertical=true; break;
            case 8: geometry.quarter_turns=3; break;
        }
        require(applyGeometry(result.pixels.hdr,geometry)==ErrorCode::Success,
            SONY2FUJI_HDR_REASON_INVALID_BUFFER,"JPEG fallback orientation failed");
        require(uint32_t(result.pixels.hdr.width)==width && uint32_t(result.pixels.hdr.height)==height,
            SONY2FUJI_HDR_REASON_INVALID_BUFFER,"JPEG fallback and SDR canvases disagree");
    } else result.pixels.hdr=pixels(context,resize(h),width,height);
    result.pixels.sdr=pixels(context,resize(s),width,height);
    [context clearCaches];
    if (file.info.content_headroom<=1)
        error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,"Native codec did not expand the gain map");
    result.pixels.nativeWidth=nativeWidth; result.pixels.nativeHeight=nativeHeight;
    result.pixels.sourceHeadroom=file.info.content_headroom;
    result.pixels.sourceQuality=result.pixels.renderQuality=static_cast<HDRQuality>(options.intent);
    result.pixels.isProxy=options.intent==SONY2FUJI_INTENT_PREVIEW;
    result.pixels.decodeRevision=revision.fetch_add(1);
    return result;
}

void differentFile(const char* source,const char* target) {
    if (!source) return;
    NSURL* a=[[NSURL fileURLWithPath:[NSString stringWithUTF8String:source]] URLByResolvingSymlinksInPath];
    NSURL* b=[[NSURL fileURLWithPath:[NSString stringWithUTF8String:target]] URLByResolvingSymlinksInPath];
    id aid=nil,bid=nil;
    [a getResourceValue:&aid forKey:NSURLFileResourceIdentifierKey error:nil];
    [b getResourceValue:&bid forKey:NSURLFileResourceIdentifierKey error:nil];
    if ([a.URLByStandardizingPath isEqual:b.URLByStandardizingPath] || (aid && bid && [aid isEqual:bid]))
        error(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_SAME_FILE,"HDR export cannot replace its source");
}

NSDictionary* metadata(const char* source,const uint8_t sha[32],uint32_t width,uint32_t height,const char* target) HDR_AVAILABLE {
    if (!source) return @{(__bridge NSString*)kCGImagePropertyOrientation:@1};
    differentFile(source,target);
    File file; open(file,source);
    if (std::memcmp(file.info.source_sha256,sha,32)!=0)
        error(SONY2FUJI_STATUS_INVALID_ARGUMENT,SONY2FUJI_HDR_REASON_SOURCE_CHANGED,"HDR metadata source has changed");
    NSDictionary* original=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(file.source,0,nullptr));
    NSMutableDictionary* exif=[original[(__bridge NSString*)kCGImagePropertyExifDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString* key in @[(__bridge NSString*)kCGImagePropertyExifMakerNote,(__bridge NSString*)kCGImagePropertyExifCFAPattern,
            (__bridge NSString*)kCGImagePropertyExifComponentsConfiguration,(__bridge NSString*)kCGImagePropertyExifCompressedBitsPerPixel,
            (__bridge NSString*)kCGImagePropertyExifSubjectArea,(__bridge NSString*)kCGImagePropertyExifSubjectLocation]) [exif removeObjectForKey:key];
    exif[(__bridge NSString*)kCGImagePropertyExifPixelXDimension]=@(width);
    exif[(__bridge NSString*)kCGImagePropertyExifPixelYDimension]=@(height);
    // ICC 是颜色解释的权威；Exif 的 uncalibrated 避免将 P3 成片误标为 sRGB。
    exif[(__bridge NSString*)kCGImagePropertyExifColorSpace]=@65535;
    NSDictionary* originalTIFF=original[(__bridge NSString*)kCGImagePropertyTIFFDictionary];
    NSMutableDictionary* tiff=[NSMutableDictionary dictionary];
    for (NSString* key in @[(__bridge NSString*)kCGImagePropertyTIFFMake,(__bridge NSString*)kCGImagePropertyTIFFModel,
            (__bridge NSString*)kCGImagePropertyTIFFDateTime,(__bridge NSString*)kCGImagePropertyTIFFArtist,
            (__bridge NSString*)kCGImagePropertyTIFFCopyright,(__bridge NSString*)kCGImagePropertyTIFFImageDescription])
        if (originalTIFF[key]) tiff[key]=originalTIFF[key];
    tiff[(__bridge NSString*)kCGImagePropertyTIFFOrientation]=@1;
    tiff[(__bridge NSString*)kCGImagePropertyTIFFSoftware]=@"RawLab";
    NSMutableDictionary* values=[@{(__bridge NSString*)kCGImagePropertyExifDictionary:exif,
        (__bridge NSString*)kCGImagePropertyTIFFDictionary:tiff,(__bridge NSString*)kCGImagePropertyOrientation:@1} mutableCopy];
    if (original[(__bridge NSString*)kCGImagePropertyGPSDictionary])
        values[(__bridge NSString*)kCGImagePropertyGPSDictionary]=original[(__bridge NSString*)kCGImagePropertyGPSDictionary];
    return values;
}

NSData* addBaseMetadata(NSData* base,NSDictionary* properties) {
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)base,nullptr);
    NSMutableData* data=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,nullptr);
    CGMutableImageMetadataRef tags=CGImageMetadataCreateMutable();
    bool success=source && destination && tags;
    for (NSString* dictionary in properties) {
        if (![properties[dictionary] isKindOfClass:NSDictionary.class]) continue;
        for (NSString* key in properties[dictionary])
            success &= CGImageMetadataSetValueMatchingImageProperty(tags,(__bridge CFStringRef)dictionary,
                (__bridge CFStringRef)key,(__bridge CFTypeRef)properties[dictionary][key]);
    }
    if (success) success=CGImageDestinationCopyImageSource(destination,source,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageDestinationMetadata:(__bridge id)tags},nullptr);
    if (source) CFRelease(source); if (destination) CFRelease(destination); if (tags) CFRelease(tags);
    require(success,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot write JPEG base metadata"); return data;
}

void atomicWrite(NSData* data,const char* path) {
    NSString* name=[NSString stringWithUTF8String:path];
    if (!name || ![data writeToFile:name options:NSDataWritingAtomic error:nil])
        error(SONY2FUJI_STATUS_OUTPUT_IO_ERROR,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Atomic HDR output write failed");
}

CGImageRef sdrImage(const ImageData& image,bool sixteenBit) {
    const size_t componentBytes=sixteenBit ? 2 : 1;
    auto bytes=std::make_unique<std::vector<uint8_t>>(image.pixels.size()*3*componentBytes);
    auto encode=[sixteenBit](float v) {
        v=std::clamp(v,0.0f,1.0f);
        return uint16_t(std::lround((sixteenBit ? 65535 : 255)*(v<=.0031308f ? 12.92f*v : 1.055f*std::pow(v,1/2.4f)-.055f)));
    };
    for (size_t i=0;i<image.pixels.size();++i) {
        const float values[]={image.pixels[i].r,image.pixels[i].g,image.pixels[i].b};
        for (size_t channel=0;channel<3;++channel) {
            const uint16_t value=encode(values[channel]);
            const size_t index=(i*3+channel)*componentBytes;
            if (sixteenBit) std::memcpy(bytes->data()+index,&value,sizeof(value));
            else (*bytes)[index]=uint8_t(value);
        }
    }
    auto release=[](void* context,const void*,size_t) { delete static_cast<std::vector<uint8_t>*>(context); };
    auto* owner=bytes.get();
    CGDataProviderRef provider=CGDataProviderCreateWithData(owner,owner->data(),owner->size(),release);
    if (!provider) throw std::bad_alloc();
    bytes.release();
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    const CGBitmapInfo bitmap=CGBitmapInfo(kCGImageAlphaNone | (sixteenBit ? kCGBitmapByteOrder16Little : kCGBitmapByteOrderDefault));
    CGImageRef result=CGImageCreate(image.width,image.height,componentBytes*8,componentBytes*24,
        size_t(image.width)*3*componentBytes,color,bitmap,provider,nullptr,false,kCGRenderingIntentDefault);
    CGDataProviderRelease(provider); if (color) CGColorSpaceRelease(color);
    if (!result) throw std::bad_alloc(); return result;
}
} // namespace

void admitMemory(uint64_t additionalBytes) {
    uint64_t available=0;
#if TARGET_OS_IPHONE
    available=os_proc_available_memory();
#if TARGET_OS_SIMULATOR
    // 模拟器没有 jetsam 限额，独立工具和 .app 都可能返回 0；真机的 0 仍拒绝。
    if (!available) available=std::min<uint64_t>(NSProcessInfo.processInfo.physicalMemory/4,2ull*1024*1024*1024);
#endif
#else
    task_vm_info_data_t task{}; mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&task),&count)!=KERN_SUCCESS)
        error(SONY2FUJI_STATUS_OUT_OF_MEMORY,SONY2FUJI_HDR_REASON_OUT_OF_MEMORY,"Cannot determine HDR task memory budget");
    const uint64_t limit=NSProcessInfo.processInfo.physicalMemory/2;
    available=task.phys_footprint<limit ? limit-task.phys_footprint : 0;
#endif
    if (additionalBytes>available*.65)
        error(SONY2FUJI_STATUS_OUT_OF_MEMORY,SONY2FUJI_HDR_REASON_OUT_OF_MEMORY,"HDR task exceeds current memory budget");
}

sony2fuji_hdr_source_info_v1 probeFile(const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) { File file; open(file,path); return file.info; }
        File file; read(file,path);
        NSDictionary* apple=CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file.source,0,kCGImageAuxiliaryDataTypeHDRGainMap));
        if (!apple && !declaresGainMap(file.data))
            error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_NOT_HDR,"No HDR gain map");
        error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,"HDR requires macOS15/iOS18");
    }
}
DecodedImage decodeFile(const char* path,const sony2fuji_hdr_decode_options_v1& options) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) { File file; open(file,path); return decode(file,options); }
        error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,"HDR requires macOS15/iOS18");
    }
}
void exportJPEG(const HDRImagePair& image,const sony2fuji_hdr_export_config_v1& config,const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            if (config.metadata_policy!=SONY2FUJI_HDR_METADATA_ISO_XMP)
                throw std::invalid_argument("HDR JPEG requires ISO and XMP metadata");
            NSDictionary* properties=metadata(config.metadata_source_path,config.source_sha256,image.hdr.width,image.hdr.height,path);
            auto data=encodeJPEG(image,config.jpeg_quality ? config.jpeg_quality : 95,config.base_color);
            if (config.metadata_source_path) {
                const auto base=jpegBase(data.data(),data.size());
                NSData* tagged=addBaseMetadata([NSData dataWithBytes:base.data() length:base.size()],properties);
                data=replaceJPEGBase(data.data(),data.size(),tagged.bytes,tagged.length);
            }
            probeJPEG(data.data(),data.size());
            atomicWrite([NSData dataWithBytes:data.data() length:data.size()],path); return;
        }
        error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,"HDR requires macOS15/iOS18");
    }
}
void exportSDR(const HDRImagePair& image,const sony2fuji_hdr_sdr_export_config_v1& config,const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            if (config.output_format!=SONY2FUJI_OUTPUT_JPEG && config.output_format!=SONY2FUJI_OUTPUT_PNG)
                error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,"Unsupported SDR rendition output format");
            if (config.quality>100) throw std::invalid_argument("Invalid SDR quality");
            NSDictionary* properties=metadata(config.metadata_source_path,config.source_sha256,image.sdr.width,image.sdr.height,path);
            NSMutableDictionary* values=[properties mutableCopy];
            values[(__bridge NSString*)kCGImageDestinationLossyCompressionQuality]=@((config.quality ? config.quality : 95)/100.0);
            NSMutableData* data=[NSMutableData data];
            CGImageRef pixels=sdrImage(image.sdr,config.output_format==SONY2FUJI_OUTPUT_PNG);
            CFStringRef type=config.output_format==SONY2FUJI_OUTPUT_JPEG ? CFSTR("public.jpeg") : CFSTR("public.png");
            CGImageDestinationRef dest=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,type,1,nullptr);
            if (!dest) { CGImageRelease(pixels); throw std::bad_alloc(); }
            CGImageDestinationAddImage(dest,pixels,(__bridge CFDictionaryRef)values);
            const bool success=CGImageDestinationFinalize(dest); CGImageRelease(pixels); CFRelease(dest);
            require(success,SONY2FUJI_HDR_REASON_OUTPUT_IO,"Cannot encode SDR rendition");
            atomicWrite(data,path); return;
        }
        error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,"HDR requires macOS15/iOS18");
    }
}
} // namespace sony2fuji::hdr
