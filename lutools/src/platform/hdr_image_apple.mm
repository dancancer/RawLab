#include "platform/hdr_image.h"
#include "core/atomic_output_transaction.h"
#include "core/hdr_jpeg.h"
#include "core/hdr_progress.h"
#include "core/hdr_srgb_lut.h"
#include "core/jpeg_mpf.h"
#include "core/parallel_pixels.h"
#include "core/pinned_source_file.h"
#include "core/hdr_storage.h"
#include "core/tiff_ifd.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#if defined(SONY2FUJI_ENABLE_METAL)
#import <Metal/Metal.h>
#endif
#include <TargetConditionals.h>
#include <mach/mach.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <limits>
#include <optional>
#include <string>
#include <malloc/malloc.h>

@interface RawLabHDRFileProvider : NSObject {
@public
    std::shared_ptr<sony2fuji::hdr::storage::File> pixels;
    uint32_t imageWidth, imageHeight;
    sony2fuji::ProcessingCancellation cancellation;
    std::mutex failureLock;
    std::exception_ptr failure;
}
- (void)checkFailure;
@end

@implementation RawLabHDRFileProvider
- (void)provideImageData:(void*)data bytesPerRow:(size_t)rowbytes origin:(size_t)x :(size_t)y
    size:(size_t)width :(size_t)height userInfo:(id)info {
    try {
        cancellation.check();
        if (x > imageWidth || y > imageHeight || width > imageWidth - x || height > imageHeight - y || rowbytes < width * 16)
            throw std::invalid_argument("Invalid HEIF provider tile");
        std::vector<sony2fuji::RGB> row(width);
        for (size_t i = 0; i < height; ++i) {
            cancellation.check();
            pixels->read(((y + i) * imageWidth + x) * sizeof(sony2fuji::RGB), row.data(), width * sizeof(sony2fuji::RGB));
            auto* target = reinterpret_cast<float*>(static_cast<uint8_t*>(data) + i * rowbytes);
            for (size_t column = 0; column < width; ++column) {
                target[column * 4] = row[column].r;
                target[column * 4 + 1] = row[column].g;
                target[column * 4 + 2] = row[column].b;
                target[column * 4 + 3] = 1;
            }
        }
    } catch (...) {
        // Core Image 可在工作线程调用 provider；异常留给编码返回后统一处理。
        std::lock_guard<std::mutex> lock(failureLock);
        if (!failure) failure = std::current_exception();
        for (size_t i = 0; i < height; ++i)
            std::memset(static_cast<uint8_t*>(data) + i * rowbytes, 0, rowbytes);
    }
}
- (void)checkFailure {
    std::lock_guard<std::mutex> lock(failureLock);
    if (failure) std::rethrow_exception(failure);
}
@end

namespace sony2fuji::hdr {
namespace {
#define HDR_AVAILABLE API_AVAILABLE(macos(15.0), ios(18.0))
std::atomic<uint64_t> revision{1};

[[noreturn]] void error(RenderStatus status, uint32_t reason, const char* message) {
    throw Error(status, reason, kHdrFieldPath, message);
}
void require(bool condition, uint32_t reason, const char* message) {
    if (!condition) error(RenderStatus::ProcessingError, reason, message);
}

struct File {
    NSData* data = nil;
    NSDictionary* properties = nil;
    CGImageSourceRef source = nullptr;
    CGImageMetadataRef metadataTags = nullptr;
    HDRSourceInfo info{};
    PinnedSourceFile pinned;
    ~File() {
        if (source) CFRelease(source);
        if (metadataTags) CFRelease(metadataTags);
    }
};

// 流式导出的源冻结快照（对 hdr_image.h 的 StreamSourcePin::impl 不透明）。
struct StreamSourcePinImpl {
    NSData* data = nil;               // validate 时单次读取的源容器
    CGImageSourceRef source = nullptr; // 与 data 同一解析，publish 复用其元数据
    NSDictionary* cachedProperties = nil;
    CGImageMetadataRef cachedMetadata = nullptr;
    uint64_t sourceSize = 0;
    PinnedSourceFile pinned;
    ~StreamSourcePinImpl() {
        if (source) CFRelease(source);
        if (cachedMetadata) CFRelease(cachedMetadata);
    }
};

void pinFile(const File& source, StreamSourcePin& pin) {
    if (!pin.impl) pin.impl = new StreamSourcePinImpl();
    auto* impl = static_cast<StreamSourcePinImpl*>(pin.impl);
    if (impl->source) CFRelease(impl->source);
    if (impl->cachedMetadata) CFRelease(impl->cachedMetadata);
    impl->data = source.data;
    impl->source = source.source ? (CGImageSourceRef)CFRetain(source.source) : nullptr;
    impl->cachedProperties = source.properties;
    impl->cachedMetadata = source.metadataTags ? (CGImageMetadataRef)CFRetain(source.metadataTags) : nullptr;
    impl->sourceSize = source.data ? uint64_t(source.data.length) : 0;
    impl->pinned = source.pinned;
    std::copy_n(source.info.sourceSha256, 32, pin.digest);
}

bool isDNGPath(const char* path) {
    if (!path) return false;
    std::string ext = std::filesystem::u8path(path).extension().u8string();
    for (char& ch : ext) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return ext == ".dng";
}

const tiff::Entry* findTiffEntry(const std::vector<tiff::Entry>& entries, uint16_t tag) {
    for (const auto& entry : entries) {
        if (entry.tag == tag) return &entry;
    }
    return nullptr;
}

bool hasProRAWProfileTag(const std::vector<tiff::Entry>& entries) {
    return findTiffEntry(entries, 52525) != nullptr || findTiffEntry(entries, 52544) != nullptr;
}

bool isLinearProRAWIFD(const tiff::Reader& reader, const std::vector<tiff::Entry>& entries,
                       const std::vector<tiff::Entry>& rootEntries) {
    const tiff::Entry* photo = findTiffEntry(entries, 262);
    if (!photo || photo->type != 3 || photo->count64 != 1) return false;
    tiff::Payload photoPayload{};
    uint64_t photometric = 0;
    if (!reader.payload(*photo, photoPayload) || photoPayload.width != 2 ||
        !reader.integer(photoPayload.offset, photoPayload.width, photometric) ||
        photometric != 34892) {
        return false;
    }
    if (findTiffEntry(entries, 50712) == nullptr) return false;
    return hasProRAWProfileTag(entries) || hasProRAWProfileTag(rootEntries);
}

bool isLinearProRAWFile(const std::filesystem::path& path, uint64_t fileSize) {
    if (fileSize < 8 || fileSize > (512ull << 20)) return false;
    std::ifstream input(path, std::ios::binary);
    if (!input.is_open()) return false;
    tiff::Reader reader(input, static_cast<size_t>(fileSize));
    tiff::Traversal traversal;
    uint32_t first = 0;
    if (!reader.header(first)) return false;
    tiff::Directory rootDir{};
    if (!traversal.open(reader, first, 0, rootDir)) return false;
    std::vector<tiff::Entry> rootEntries;
    if (!reader.entries(rootDir, [&](const tiff::Entry& entry) {
            rootEntries.push_back(entry);
            return true;
        })) {
        return false;
    }
    if (findTiffEntry(rootEntries, 50706) == nullptr) return false;
    if (isLinearProRAWIFD(reader, rootEntries, rootEntries)) return true;

    const tiff::Entry* sub = findTiffEntry(rootEntries, 330);
    if (!sub || (sub->type != 4 && sub->type != 13) ||
        sub->count64 < 1 || sub->count64 > 32) {
        return false;
    }
    tiff::Payload subPayload{};
    if (!reader.payload(*sub, subPayload) || subPayload.width != 4) return false;
    for (size_t i = 0; i < static_cast<size_t>(sub->count64); ++i) {
        uint64_t childOffset = 0;
        if (!reader.integer(subPayload.offset + i * 4, 4, childOffset)) return false;
        tiff::Directory subDir{};
        if (!traversal.open(reader, childOffset, 1, subDir)) return false;
        std::vector<tiff::Entry> subEntries;
        if (!reader.entries(subDir, [&](const tiff::Entry& entry) {
                subEntries.push_back(entry);
                return true;
            })) {
            return false;
        }
        if (isLinearProRAWIFD(reader, subEntries, rootEntries)) return true;
    }
    return false;
}

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
        kHdrReasonMalformedAux, "Invalid auxiliary description");
    const uint64_t width = [description[(__bridge NSString*)kCGImagePropertyWidth] unsignedLongLongValue];
    const uint64_t height = [description[(__bridge NSString*)kCGImagePropertyHeight] unsignedLongLongValue];
    const uint64_t stride = [description[(__bridge NSString*)kCGImagePropertyBytesPerRow] unsignedLongLongValue];
    require(width && height && width <= 128000000 / height && stride >= width &&
        stride <= SIZE_MAX / height && (!data || stride * height <= data.length),
        kHdrReasonMalformedAux, "Invalid auxiliary dimensions or storage");
}

void readMetadataOnlySource(File& file, const char* path, const uint8_t* expectedSHA = nullptr) {
    NSString* name = path ? [NSString stringWithUTF8String:path] : nil;
    if (!name || !*path) error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
    PinnedSourceOptions options;
    options.maxBytes = 512ull * 1024 * 1024;
    options.allowEmpty = false;
    options.checkCancellation = true;
    options.computeSha256 = true;
    options.rejectSymlink = false;
    options.expectedSha256 = expectedSHA;
    const auto pinStatus = PinnedSourceFile::pinAndHash(
        std::filesystem::u8path(path), options, file.pinned);
    switch (pinStatus) {
        case SourcePinStatus::Ok:
            break;
        case SourcePinStatus::InvalidPath:
            error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
        case SourcePinStatus::SourceChanged:
            error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source has changed");
        case SourcePinStatus::Cancelled:
            throw ProcessingCancelled();
        case SourcePinStatus::IoError:
        case SourcePinStatus::TooLarge:
            error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read HDR source");
    }
    std::copy_n(file.pinned.sha256().data(), 32, file.info.sourceSha256);
    NSURL* url = [NSURL fileURLWithPath:name];
    CGImageSourceRef src = url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceShouldCache:@NO}) : nullptr;
    require(src, kHdrReasonMalformedAux, "Cannot parse HDR container");
    file.properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr));
    file.metadataTags = CGImageSourceCopyMetadataAtIndex(src, 0, nullptr);
    CFRelease(src);
    if (!file.pinned.verifyUnchanged()) {
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source has changed");
    }
}

void readMetadataSource(File& file, const char* path, const uint8_t* expectedSHA = nullptr) {
    NSString* name = path ? [NSString stringWithUTF8String:path] : nil;
    if (!name) error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
    PinnedSourceOptions options;
    options.maxBytes = 512ull * 1024 * 1024;
    options.allowEmpty = false;
    options.checkCancellation = true;
    options.computeSha256 = true;
    options.rejectSymlink = false;
    options.expectedSha256 = expectedSHA;
    std::vector<uint8_t> bytes;
    const auto pinStatus = PinnedSourceFile::pinAndRead(
        std::filesystem::u8path(path), options, file.pinned, bytes);
    switch (pinStatus) {
        case SourcePinStatus::Ok:
            break;
        case SourcePinStatus::InvalidPath:
            error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
        case SourcePinStatus::SourceChanged:
            error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source has changed");
        case SourcePinStatus::Cancelled:
            throw ProcessingCancelled();
        case SourcePinStatus::IoError:
        case SourcePinStatus::TooLarge:
            error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read HDR source");
    }
    if (bytes.empty()) error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read HDR source");
    file.data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    if (!file.data) throw std::bad_alloc();
    std::copy_n(file.pinned.sha256().data(), 32, file.info.sourceSha256);
    file.source = CGImageSourceCreateWithData((__bridge CFDataRef)file.data,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageSourceShouldCache:@NO});
    require(file.source, kHdrReasonMalformedAux, "Cannot parse HDR container");
}

void describe(File& file) {
    const CFStringRef type = CGImageSourceGetType(file.source);
    if (type && CFEqual(type, CFSTR("public.jpeg"))) file.info.container = kHdrContainerJpeg;
    else if (type && (CFEqual(type, CFSTR("public.heic")) || CFEqual(type, CFSTR("public.heif"))))
        file.info.container = kHdrContainerHeif;
    else error(RenderStatus::Unsupported, kHdrReasonUnsupportedProtocol, "Unsupported HDR container");
    if (CGImageSourceGetCount(file.source) != 1)
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedProtocol, "HDR input must have one primary image");
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(file.source, 0, nullptr));
    file.properties=properties;
    const uint64_t width = [properties[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    const uint64_t height = [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    require(width && height && width <= 128000000 / height, kHdrReasonInvalidBuffer, "HDR source pixel budget exceeded");
    if ([properties[(__bridge NSString*)kCGImagePropertyHasAlpha] boolValue])
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedColor, "HDR input must be opaque");
    file.info.width = uint32_t(width); file.info.height = uint32_t(height);
    const uint32_t orientation = [properties[(__bridge NSString*)kCGImagePropertyOrientation] unsignedIntValue];
    require(orientation <= 8, kHdrReasonInvalidBuffer, "Invalid EXIF orientation");
    file.info.orientation = orientation ? orientation : 1;
}

void read(File& file, const char* path) {
    readMetadataSource(file,path);
    const auto count = CGImageSourceGetCount(file.source);
    const auto type = CGImageSourceGetType(file.source);
    if (count > 1 && count <= 3 && type && CFEqual(type, CFSTR("public.jpeg")) &&
        !declaresGainMap(file.data) && inspectSdrJpegMpf(std::filesystem::u8path(path)) == static_cast<int>(count)) {
        // ImageIO can expose SDR thumbnails as frames. HDR gain maps still follow the HDR probe.
        bool gainMap = CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            file.source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)) != nil;
        if (@available(macOS 15.0, iOS 18.0, *)) {
            gainMap |= CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                file.source, 0, kCGImageAuxiliaryDataTypeISOGainMap)) != nil;
        }
        if (!gainMap)
            error(RenderStatus::Unsupported, kHdrReasonNotHdr, "No HDR gain map");
    }
    describe(file);
}

void inspectGainMap(File& file) HDR_AVAILABLE {
    const bool xmp=file.info.container==kHdrContainerJpeg && has(file.data,"http://ns.adobe.com/hdr-gain-map/1.0/");
    const bool isoDeclared=file.info.container==kHdrContainerJpeg && has(file.data,"urn:iso:std:iso:ts:21496:-1");
    // 旧式 Apple JPEG 也使用 Adobe namespace；以原容器的辅助类型区分，不能依赖 ImageIO 合成的 ISO 字典。
    const bool appleDeclared=!isoDeclared && (has(file.data,"urn:com:apple:photo:2020:aux:hdrgainmap") ||
        has(file.data,"http://ns.apple.com/HDRGainMap/1.0/"));
    const bool modernJPEG=file.info.container==kHdrContainerJpeg &&
        (isoDeclared || (xmp && !appleDeclared));
    JPEGInfo jpeg;
    if (modernJPEG) {
        // 先检查压缩辅助图，避免原生接口为坏引用分配像素或只交付底图。
        jpeg=probeJPEG(file.data.bytes,file.data.length);
        require(jpeg.width==file.info.width && jpeg.height==file.info.height,
            kHdrReasonMalformedAux, "JPEG metadata canvases disagree");
    }
    NSDictionary* iso = CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file.source, 0, kCGImageAuxiliaryDataTypeISOGainMap));
    NSDictionary* apple = CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file.source, 0, kCGImageAuxiliaryDataTypeHDRGainMap));
    if (iso && !appleDeclared) validateMap(iso);
    // ImageIO 也会为旧 Android XMP 照片合成 ISO 字典；文件协议由原容器决定。
    if (modernJPEG) file.info.protocol=isoDeclared ? (xmp ? kHdrProtocolIsoXmp : kHdrProtocolIso) : kHdrProtocolXmp;
    else if (appleDeclared) {
        require(apple, kHdrReasonMalformedAux, "Declared Apple gain map cannot be read");
        validateMap(apple); file.info.protocol=kHdrProtocolApple;
    }
    else if (iso) file.info.protocol=kHdrProtocolIso;
    else if (apple) { validateMap(apple); file.info.protocol = kHdrProtocolApple; }
    else if (declaresGainMap(file.data))
        error(RenderStatus::ProcessingError, kHdrReasonMalformedAux, "Declared gain map cannot be read");
    else error(RenderStatus::Unsupported, kHdrReasonNotHdr, "No HDR gain map");
    CIImage* expanded = [CIImage imageWithData:file.data options:@{kCIImageExpandToHDR:@YES}];
    require(expanded, kHdrReasonMalformedAux, "Cannot construct HDR representation");
    CGColorSpaceRef color = expanded.colorSpace;
    if (!color || CGColorSpaceGetModel(color) != kCGColorSpaceModelRGB)
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedColor, "Missing RGB color interpretation");
    CFStringRef colorName = CGColorSpaceCopyName(color);
    NSString* profile = file.properties[(__bridge NSString*)kCGImagePropertyProfileName];
    if ((colorName && (CFEqual(colorName,kCGColorSpaceDisplayP3) || CFEqual(colorName,kCGColorSpaceExtendedLinearDisplayP3))) ||
        (profile && [profile rangeOfString:@"P3" options:NSCaseInsensitiveSearch].location != NSNotFound))
        file.info.colorDescription = kHdrColorDisplayP3;
    else if ((colorName && (CFEqual(colorName,kCGColorSpaceITUR_2020) || CFEqual(colorName,kCGColorSpaceExtendedLinearITUR_2020))) ||
        (profile && [profile rangeOfString:@"2020" options:NSCaseInsensitiveSearch].location != NSNotFound))
        file.info.colorDescription = kHdrColorBt2020;
    else if ((colorName && (CFEqual(colorName,kCGColorSpaceSRGB) || CFEqual(colorName,kCGColorSpaceExtendedSRGB) ||
            CFEqual(colorName,kCGColorSpaceExtendedLinearSRGB))) ||
        (profile && [profile rangeOfString:@"sRGB" options:NSCaseInsensitiveSearch].location != NSNotFound))
        file.info.colorDescription = kHdrColorSrgb;
    if (colorName) CFRelease(colorName);
    const float headroom = expanded.contentHeadroom;
    require(std::isfinite(headroom) && headroom >= 1, kHdrReasonNonfinite, "Invalid source content headroom");
    file.info.contentHeadroom = headroom; file.info.headroomKind = kHdrHeadroomDeclared;
    if (file.info.container==kHdrContainerJpeg && file.info.protocol!=kHdrProtocolApple) {
        if (!modernJPEG) jpeg=probeJPEG(file.data.bytes,file.data.length);
        file.info.contentHeadroom=jpeg.headroom;
    }

}

void open(File& file, const char* path) HDR_AVAILABLE {
    read(file,path);
    inspectGainMap(file);
}

void pixelRows(CIContext* context, CIImage* input, int width, int height, int first, int count, RGB* output) {
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    if (!color) throw std::bad_alloc();
    std::unique_ptr<std::remove_pointer_t<CGColorSpaceRef>, decltype(&CGColorSpaceRelease)> managed(color, CGColorSpaceRelease);
    // 分条取 CGImage 的上向下存储，避免额外常驻整张 RGBA32F；工作图也是左上起点。
    for (int top = first; top < first + count; top += 128) {
        @autoreleasepool {
            checkProcessingCancellation();
            const int rows = std::min(128, first + count - top);
            CGImageRef image = [context createCGImage:input fromRect:CGRectMake(0,height-top-rows,width,rows)
                format:kCIFormatRGBAf colorSpace:color];
            require(image, kHdrReasonInvalidBuffer, "HDR pixel rendering failed");
            CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
            const size_t stride = CGImageGetBytesPerRow(image);
            const bool valid = data && CGImageGetBitsPerComponent(image)==32 && CGImageGetBitsPerPixel(image)==128 &&
                stride >= size_t(width)*16 && stride <= SIZE_MAX/rows && CFDataGetLength(data) >= CFIndex(stride*rows);
            if (!valid) {
                if (data) CFRelease(data); CGImageRelease(image);
                error(RenderStatus::ProcessingError, kHdrReasonInvalidBuffer, "Invalid native HDR storage");
            }
            const uint8_t* bytes=CFDataGetBytePtr(data);
            std::atomic<bool> finite{true}, opaque{true};
            parallelRowRanges(rows, width, [&](int firstRow, int lastRow) {
                for (int y = firstRow; y < lastRow; ++y) {
                    const uint8_t* srcRow = bytes + size_t(y) * stride;
                    RGB* dstRow = output + size_t(top + y - first) * width;
                    for (int x = 0; x < width; ++x) {
                        float rgba[4];
                        std::memcpy(rgba, srcRow + x * 16, 16);
                        if (!std::isfinite(rgba[0]) || !std::isfinite(rgba[1]) ||
                            !std::isfinite(rgba[2]) || !std::isfinite(rgba[3])) {
                            finite.store(false, std::memory_order_relaxed);
                        }
                        if (std::abs(rgba[3] - 1.0f) >= 1e-5f) {
                            opaque.store(false, std::memory_order_relaxed);
                        }
                        dstRow[x] = {rgba[0], rgba[1], rgba[2]};
                    }
                }
            });
            CFRelease(data); CGImageRelease(image);
            require(finite.load(std::memory_order_relaxed), kHdrReasonNonfinite, "Native HDR contains nonfinite pixels");
            require(opaque.load(std::memory_order_relaxed), kHdrReasonUnsupportedColor, "Native HDR contains transparency");
        }
    }
}

ImageData pixels(CIContext* context, CIImage* input, int width, int height) {
    ImageData result(width, height);
    pixelRows(context, input, width, height, 0, height, result.pixels.data());
    return result;
}

DecodedImage decode(File& file, const HDRDecodeOptions& options) HDR_AVAILABLE {
    CIImage* h=[CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@YES}];
    CIImage* s=[CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@NO}];
    require(h && s && CGRectEqualToRect(h.extent,s.extent), kHdrReasonMalformedAux, "HDR/SDR canvases differ");
    const bool swapped=file.info.orientation>=5;
    const uint32_t nativeWidth=swapped ? file.info.height : file.info.width;
    const uint32_t nativeHeight=swapped ? file.info.width : file.info.height;
    require(h.extent.size.width==nativeWidth && h.extent.size.height==nativeHeight,
        kHdrReasonInvalidBuffer, "Decoded HDR canvas differs from metadata");
    uint32_t width=nativeWidth,height=nativeHeight;
    if (options.intent==kHdrIntentPreview && options.longEdge && std::max(width,height)>options.longEdge) {
        const double scale=double(options.longEdge)/std::max(width,height);
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
    if (h.contentHeadroom<=1 && file.info.container==kHdrContainerJpeg &&
            file.info.protocol!=kHdrProtocolApple) {
        result.pixels.hdr=decodeJPEG(file.data.bytes,file.data.length,
            options.intent==kHdrIntentPreview ? options.longEdge : 0);
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
            kHdrReasonInvalidBuffer, "JPEG fallback orientation failed");
        require(uint32_t(result.pixels.hdr.width)==width && uint32_t(result.pixels.hdr.height)==height,
            kHdrReasonInvalidBuffer, "JPEG fallback and SDR canvases disagree");
    } else result.pixels.hdr=pixels(context,resize(h),width,height);
    result.pixels.sdr=pixels(context,resize(s),width,height);
    [context clearCaches];
    if (file.info.contentHeadroom<=1)
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedProtocol, "Native codec did not expand the gain map");
    result.pixels.nativeWidth=nativeWidth; result.pixels.nativeHeight=nativeHeight;
    result.pixels.sourceHeadroom=file.info.contentHeadroom;
    result.pixels.sourceQuality=result.pixels.renderQuality=static_cast<HDRQuality>(options.intent);
    result.pixels.isProxy=options.intent==kHdrIntentPreview;
    result.pixels.decodeRevision=revision.fetch_add(1);
    return result;
}

DecodedImage decodeROI(File& file, const RoiSubRect& rect) HDR_AVAILABLE {
    require(!rect.empty() && rect.x0 >= 0 && rect.y0 >= 0, kHdrReasonInvalidArgument, "Invalid HDR file ROI rect");
    CIImage* h=[CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@YES}];
    CIImage* s=[CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@NO}];
    require(h && s && CGRectEqualToRect(h.extent,s.extent), kHdrReasonMalformedAux, "HDR/SDR canvases differ");
    const bool swapped=file.info.orientation>=5;
    const uint32_t nativeWidth=swapped ? file.info.height : file.info.width;
    const uint32_t nativeHeight=swapped ? file.info.width : file.info.height;
    require(h.extent.size.width==nativeWidth && h.extent.size.height==nativeHeight,
        kHdrReasonInvalidBuffer, "Decoded HDR canvas differs from metadata");
    require(rect.x1 <= int(nativeWidth) && rect.y1 <= int(nativeHeight),
        kHdrReasonInvalidArgument, "HDR file ROI exceeds image bounds");
    const uint32_t rw = uint32_t(rect.width());
    const uint32_t rh = uint32_t(rect.height());
    admitMemory(uint64_t(rw) * rh * 48);
    const CGRect ciCrop = CGRectMake(rect.x0, double(nativeHeight) - double(rect.y1), rw, rh);
    auto cropCI = [&](CIImage* image) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
        image = [image imageByCroppingToRect:ciCrop];
        return [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-ciCrop.origin.x, -ciCrop.origin.y)];
    };
    CIContext* context=[CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf),kCIContextCacheIntermediates:@NO,
        kCIContextUseSoftwareRenderer:@YES}];
    DecodedImage result;
    result.info = file.info;
    if (h.contentHeadroom<=1 && file.info.container==kHdrContainerJpeg &&
            file.info.protocol!=kHdrProtocolApple) {
        admitMemory(uint64_t(nativeWidth) * nativeHeight * sizeof(RGB));
        ImageData fullHdr = decodeJPEG(file.data.bytes, file.data.length, 0);
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
        require(applyGeometry(fullHdr, geometry)==ErrorCode::Success,
            kHdrReasonInvalidBuffer, "JPEG fallback orientation failed");
        require(uint32_t(fullHdr.width)==nativeWidth && uint32_t(fullHdr.height)==nativeHeight,
            kHdrReasonInvalidBuffer, "JPEG fallback canvas size mismatch");
        result.pixels.hdr = ImageData(int(rw), int(rh));
        for (uint32_t y = 0; y < rh; ++y) {
            std::copy_n(fullHdr.pixels.data() + size_t(rect.y0 + y) * nativeWidth + rect.x0,
                rw, result.pixels.hdr.pixels.data() + size_t(y) * rw);
        }
    } else {
        result.pixels.hdr = pixels(context, cropCI(h), int(rw), int(rh));
    }
    result.pixels.sdr = pixels(context, cropCI(s), int(rw), int(rh));
    [context clearCaches];
    if (file.info.contentHeadroom<=1)
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedProtocol, "Native codec did not expand the gain map");
    result.pixels.nativeWidth = nativeWidth;
    result.pixels.nativeHeight = nativeHeight;
    result.pixels.sourceHeadroom = file.info.contentHeadroom;
    result.pixels.sourceQuality = result.pixels.renderQuality = HDRQuality::Final;
    result.pixels.isProxy = false;
    result.pixels.decodeRevision = revision.fetch_add(1);
    return result;
}

void differentFile(const char* source, const char* target) {
    if (!source || !target) return;
    if (PinnedSourceFile::isSameFile(std::filesystem::u8path(source), std::filesystem::u8path(target)))
        error(RenderStatus::InvalidArgument, kHdrReasonSameFile, "HDR export cannot replace its source");
}

NSDictionary* buildMetadataFromProperties(NSDictionary* original, uint32_t width, uint32_t height) {
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

NSDictionary* buildMetadata(File& file,uint32_t width,uint32_t height) {
    NSDictionary* original = file.properties ?: (file.source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(file.source,0,nullptr)) : nil);
    return buildMetadataFromProperties(original, width, height);
}

NSDictionary* metadata(File& file,const char* source,const uint8_t sha[32],uint32_t width,uint32_t height,const char* target) HDR_AVAILABLE {
    if (!source) return @{(__bridge NSString*)kCGImagePropertyOrientation:@1};
    differentFile(source,target);
    if (isDNGPath(source)) {
        const bool hasExpected = sha && std::any_of(sha, sha + 32, [](uint8_t value) { return value != 0; });
        readMetadataOnlySource(file, source, hasExpected ? sha : nullptr);
    } else {
        readMetadataSource(file,source,sha);
    }
    return buildMetadata(file,width,height);
}

NSData* addBaseMetadata(NSData* base,NSDictionary* properties,CGImageMetadataRef originalTags) {
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)base,nullptr);
    NSMutableData* data=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,nullptr);
    CGMutableImageMetadataRef tags=CGImageMetadataCreateMutable();
    bool success=source && destination && tags;
    for (NSString* dictionary in properties) {
        if (![properties[dictionary] isKindOfClass:NSDictionary.class]) continue;
        for (NSString* key in properties[dictionary]) {
            if ([key isEqualToString:(__bridge NSString*)kCGImagePropertyExifISOSpeedRatings]) {
                // ImageIO 的 XMP 序列需使用文本元素；NSNumber 序列会静默丢失 ISO。
                NSMutableArray* ratings=[NSMutableArray array];
                for (id value in properties[dictionary][key]) [ratings addObject:[value description]];
                success &= CGImageMetadataSetValueMatchingImageProperty(tags,(__bridge CFStringRef)dictionary,
                    (__bridge CFStringRef)key,(__bridge CFArrayRef)ratings);
                continue;
            }
            const bool replaced=[@[
                (__bridge NSString*)kCGImagePropertyExifPixelXDimension,
                (__bridge NSString*)kCGImagePropertyExifPixelYDimension,
                (__bridge NSString*)kCGImagePropertyExifColorSpace,
                (__bridge NSString*)kCGImagePropertyTIFFOrientation,
                (__bridge NSString*)kCGImagePropertyTIFFSoftware] containsObject:key];
            CGImageMetadataTagRef tag=originalTags && !replaced
                ? CGImageMetadataCopyTagMatchingImageProperty(originalTags,(__bridge CFStringRef)dictionary,(__bridge CFStringRef)key) : nullptr;
            NSString* prefix=tag ? CFBridgingRelease(CGImageMetadataTagCopyPrefix(tag)) : nil;
            NSString* name=tag ? CFBridgingRelease(CGImageMetadataTagCopyName(tag)) : nil;
            if (prefix && name) {
                NSString* path=[NSString stringWithFormat:@"%@:%@",prefix,name];
                success &= CGImageMetadataSetTagWithPath(tags,nullptr,(__bridge CFStringRef)path,tag);
            } else {
                success &= CGImageMetadataSetValueMatchingImageProperty(tags,(__bridge CFStringRef)dictionary,
                    (__bridge CFStringRef)key,(__bridge CFTypeRef)properties[dictionary][key]);
            }
            if (tag) CFRelease(tag);
        }
    }
    if (success) success=CGImageDestinationCopyImageSource(destination,source,
        (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageDestinationMetadata:(__bridge id)tags,
            (__bridge NSString*)kCGImageMetadataShouldExcludeXMP:@YES},nullptr);
    if (source) CFRelease(source); if (destination) CFRelease(destination); if (tags) CFRelease(tags);
    require(success, kHdrReasonOutputIo, "Cannot write JPEG base metadata"); return data;
}

NSData* addBaseMetadataFromFile(NSData* base, NSDictionary* properties, const File& file) {
    if (file.metadataTags) {
        return addBaseMetadata(base, properties, file.metadataTags);
    }
    CGImageMetadataRef copied = file.source ? CGImageSourceCopyMetadataAtIndex(file.source, 0, nullptr) : nullptr;
    @try {
        return addBaseMetadata(base, properties, copied);
    } @finally {
        if (copied) CFRelease(copied);
    }
}

void atomicWrite(NSData* data, const char* path) {
    NSString* name = path ? [NSString stringWithUTF8String:path] : nil;
    if (!name || !data)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Atomic HDR output write failed");
    AtomicOutputOptions options;
    options.stagingPrefix = ".rawlab-hdr";
    options.modePolicy = OutputModePolicy::PreserveDestinationOrUmask;
    options.rejectSymlinkTarget = false;
    options.syncFile = true;
    AtomicOutputTransaction tx(std::filesystem::u8path(path), options);
    if (tx.begin() != AtomicOutputStatus::Ok ||
        tx.writeAll(data.bytes, data.length, false) != AtomicOutputStatus::Ok ||
        tx.commit() != AtomicOutputStatus::Ok) {
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Atomic HDR output write failed");
    }
}

void atomicStreamWrite(NSData* data, const char* path, const HDRExportConfig& config,
    const StreamSourcePin& pin) {
    NSString* name = path ? [NSString stringWithUTF8String:path] : nil;
    if (!name || !data)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot stage streamed JPEG output");
    AtomicOutputOptions options;
    options.stagingPrefix = ".rawlab-hdr";
    options.modePolicy = OutputModePolicy::PreserveDestinationOrUmask;
    options.rejectSymlinkTarget = false;
    options.syncFile = true;
    AtomicOutputTransaction tx(std::filesystem::u8path(path), options);
    if (tx.begin() != AtomicOutputStatus::Ok)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot stage streamed JPEG output");
    if (tx.writeAll(data.bytes, data.length, true) != AtomicOutputStatus::Ok)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot write streamed JPEG output");
    const auto status = tx.commit([&]() {
        // 发布前再次核对来源；解码完成后的原片替换不能配上旧像素与新 EXIF。
        if (pin.impl) {
            verifyStreamSource(pin);
        } else if (config.metadataSourcePath) {
            File verification;
            if (isDNGPath(config.metadataSourcePath)) {
                readMetadataOnlySource(verification, config.metadataSourcePath, config.sourceSha256);
            } else {
                readMetadataSource(verification, config.metadataSourcePath, config.sourceSha256);
            }
        }
        differentFile(config.metadataSourcePath, path);
        checkProcessingCancellation();
        return true;
    });
    if (status != AtomicOutputStatus::Ok)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot publish streamed JPEG output");
}

bool hasICCProfileMarker(const std::vector<uint8_t>& jpeg) {
    if (jpeg.size() < 4 || jpeg[0] != 0xff || jpeg[1] != 0xd8) return false;
    static constexpr uint8_t kIccHeader[12] = {'I','C','C','_','P','R','O','F','I','L','E',0};
    size_t index = 2;
    while (index + 1 < jpeg.size()) {
        if (jpeg[index] != 0xff) {
            ++index;
            continue;
        }
        while (index < jpeg.size() && jpeg[index] == 0xff) ++index;
        if (index >= jpeg.size()) break;
        const uint8_t marker = jpeg[index++];
        if (marker == 0xd9 || marker == 0xda) break;
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd8)) continue;
        if (index + 2 > jpeg.size()) break;
        const size_t segmentLength = (size_t(jpeg[index]) << 8) | size_t(jpeg[index + 1]);
        if (segmentLength < 2 || index + segmentLength > jpeg.size()) break;
        if (marker == 0xe2 && segmentLength >= 16 &&
            std::memcmp(jpeg.data() + index + 2, kIccHeader, sizeof(kIccHeader)) == 0) {
            return true;
        }
        index += segmentLength;
    }
    return false;
}

std::vector<uint8_t> withSRGBProfile(const std::vector<uint8_t>& jpeg) {
    if (jpeg.size() < 2 || jpeg[0] != 0xff || jpeg[1] != 0xd8)
        throw std::runtime_error("Cannot attach SDR sRGB profile");
    if (hasICCProfileMarker(jpeg)) return jpeg;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSData* profile = space ? CFBridgingRelease(CGColorSpaceCopyICCData(space)) : nil;
    if (space) CGColorSpaceRelease(space);
    if (!profile.length || profile.length > 65519)
        throw std::runtime_error("Cannot attach SDR sRGB profile");
    const size_t length = profile.length + 16;
    std::vector<uint8_t> output{0xff, 0xd8, 0xff, 0xe2, uint8_t(length >> 8), uint8_t(length),
        'I','C','C','_','P','R','O','F','I','L','E',0,1,1};
    const auto* bytes = static_cast<const uint8_t*>(profile.bytes);
    output.insert(output.end(), bytes, bytes + profile.length);
    output.insert(output.end(), jpeg.begin() + 2, jpeg.end());
    return output;
}

CGImageRef sdrImage(const ImageData& image,bool sixteenBit) {
    const size_t componentBytes=sixteenBit ? 2 : 1;
    auto bytes=std::make_unique<std::vector<uint8_t>>(image.pixels.size()*3*componentBytes);
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        if (sixteenBit) {
            for (size_t i = first; i < last; ++i) {
                const float values[] = {image.pixels[i].r, image.pixels[i].g, image.pixels[i].b};
                for (size_t channel = 0; channel < 3; ++channel) {
                    const uint16_t value = uint16_t(std::lround(65535.0f * linearToSrgbUnit(values[channel])));
                    std::memcpy(bytes->data() + (i * 3 + channel) * 2, &value, sizeof(value));
                }
            }
        } else {
            for (size_t i = first; i < last; ++i) {
                const auto& pixel = image.pixels[i];
                const size_t base = i * 3;
                (*bytes)[base + 0] = srgbToUInt8(pixel.r);
                (*bytes)[base + 1] = srgbToUInt8(pixel.g);
                (*bytes)[base + 2] = srgbToUInt8(pixel.b);
            }
        }
    });
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

static uint64_t availableMemory() {
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
        error(RenderStatus::OutOfMemory, kHdrReasonOutOfMemory, "Cannot determine HDR task memory budget");
    const uint64_t limit=NSProcessInfo.processInfo.physicalMemory/2;
    available=task.phys_footprint<limit ? limit-task.phys_footprint : 0;
#endif
    return available;
}

void admitMemory(uint64_t additionalBytes) {
    const auto available = availableMemory();
    if (additionalBytes > available * .65)
        error(RenderStatus::OutOfMemory, kHdrReasonOutOfMemory, "HDR task exceeds current memory budget");
}

void admitStreamingMemory(uint64_t additionalBytes) {
    // 提交上一阶段已释放的 allocator 页；不能把仍活跃的预览/解码缓存扣除两次。
    malloc_zone_pressure_relief(nullptr, 0);
    const auto available = availableMemory();
    const auto reserve = std::max<uint64_t>(256ull << 20, available / 5);
    if (available < reserve || additionalBytes > available - reserve)
        error(RenderStatus::OutOfMemory, kHdrReasonOutOfMemory,
            "Streamed HDR codec exceeds current memory budget");
}

namespace {

struct AppleProRAWProbeDetails {
    PinnedSourceFile pinned;
    NSString* decoderVersion = nil;
    uint32_t width = 0;
    uint32_t height = 0;
};

AppleProRAWProbeDetails probeAppleProRAWDetails(const char* path) HDR_AVAILABLE {
    NSString* name = path ? [NSString stringWithUTF8String:path] : nil;
    if (!name || !*path) error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
    AppleProRAWProbeDetails details;
    const auto fsPath = std::filesystem::u8path(path);
    const auto pinStatus = PinnedSourceFile::pinIdentity(fsPath, false, details.pinned);
    if (pinStatus == SourcePinStatus::InvalidPath) {
        error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
    }
    if (pinStatus != SourcePinStatus::Ok) {
        error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read ProRAW source");
    }
    if (details.pinned.stamp().size < 8 || details.pinned.stamp().size > (512ull << 20)) {
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    }
    if (!isLinearProRAWFile(fsPath, details.pinned.stamp().size)) {
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    }
    NSURL* url = [NSURL fileURLWithPath:name];
    CIRAWFilter* raw = url ? [CIRAWFilter filterWithImageURL:url] : nil;
    NSDictionary* tiff = raw ? raw.properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary] : nil;
    NSString* make = [tiff isKindOfClass:NSDictionary.class] ? tiff[@"Make"] : nil;
    NSString* model = [tiff isKindOfClass:NSDictionary.class] ? tiff[@"Model"] : nil;
    if (![make isKindOfClass:NSString.class] ||
        [make caseInsensitiveCompare:@"Apple"] != NSOrderedSame ||
        ![model isKindOfClass:NSString.class] ||
        ![model hasPrefix:@"iPhone "]) {
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    }
    const CGSize canvas = raw.nativeSize;
    if (!std::isfinite(canvas.width) || !std::isfinite(canvas.height) ||
        canvas.width < 2.0 || canvas.height < 2.0 ||
        canvas.width * canvas.height > 128000000.0) {
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    }
    if (!details.pinned.verifyUnchanged()) {
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source has changed");
    }
    const bool rotated = int(raw.orientation) >= 5;
    details.decoderVersion = raw.decoderVersion;
    details.width = static_cast<uint32_t>(rotated ? canvas.height : canvas.width);
    details.height = static_cast<uint32_t>(rotated ? canvas.width : canvas.height);
    return details;
}

DecodedImage decodeAppleProRAWRegion(const char* path, const HDRDecodeOptions* options, const RoiSubRect* rect) HDR_AVAILABLE {
    const auto details = probeAppleProRAWDetails(path);
    std::optional<uint32_t> effectiveEdge;
    if (options) {
        if (options->intent == kHdrIntentPreview) {
            if (options->longEdge == 0) {
                error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Preview decode requires positive long edge");
            }
            effectiveEdge = std::min<uint32_t>(options->longEdge, 2048u);
        } else if (options->intent != kHdrIntentFinal || options->longEdge != 0) {
            error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid HDR decode options");
        }
    }
    if (rect) {
        require(!rect->empty() && rect->x0 >= 0 && rect->y0 >= 0 &&
                rect->x1 <= int(details.width) && rect->y1 <= int(details.height),
            kHdrReasonInvalidArgument, "Invalid HDR file ROI rect");
    }
    const bool isFinal = (!effectiveEdge.has_value() && rect == nullptr);
    const uint32_t longSide = std::max(details.width, details.height);
    const double scale = effectiveEdge
        ? std::min(1.0, double(*effectiveEdge) / double(longSide))
        : 1.0;
    const uint64_t expectedPixels = rect
        ? uint64_t(rect->width()) * uint64_t(rect->height())
        : uint64_t(std::ceil(double(details.width) * scale)) * uint64_t(std::ceil(double(details.height) * scale));
    admitMemory(expectedPixels * (isFinal ? 88ull : 56ull) + (64ull << 20));
    if (!details.pinned.verifyUnchanged()) {
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source has changed");
    }
    PinnedSourceOptions pinOpts;
    pinOpts.maxBytes = 512ull << 20;
    pinOpts.allowEmpty = false;
    pinOpts.checkCancellation = true;
    pinOpts.computeSha256 = true;
    pinOpts.rejectSymlink = false;
    PinnedSourceFile pinned;
    const auto pinStatus = PinnedSourceFile::pinAndHash(std::filesystem::u8path(path), pinOpts, pinned);
    switch (pinStatus) {
        case SourcePinStatus::Ok:
            break;
        case SourcePinStatus::SourceChanged:
            error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source has changed");
        case SourcePinStatus::Cancelled:
            throw ProcessingCancelled();
        case SourcePinStatus::InvalidPath:
            error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
        case SourcePinStatus::IoError:
        case SourcePinStatus::TooLarge:
            error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read ProRAW source");
    }
    if (!(pinned.stamp() == details.pinned.stamp())) {
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source has changed");
    }
    NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CIRAWFilter* raw = url ? [CIRAWFilter filterWithImageURL:url] : nil;
    if (!raw || ![raw.decoderVersion isEqualToString:details.decoderVersion]) {
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    }
    raw.scaleFactor = rect ? 1.0f : static_cast<float>(scale);
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    if (!color) throw std::bad_alloc();
    std::unique_ptr<std::remove_pointer_t<CGColorSpaceRef>, decltype(&CGColorSpaceRelease)> managedColor(color, CGColorSpaceRelease);
    CIContext* context = [CIContext contextWithOptions:@{
        kCIContextWorkingColorSpace: (__bridge id)color,
        kCIContextCacheIntermediates: @YES
    }];
    raw.extendedDynamicRangeAmount = 1.0f;
    CIImage* hdrImage = raw.outputImage;
    if (!hdrImage) error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    const CGRect bounds = CGRectIntegral(hdrImage.extent);
    if (bounds.size.width < 1.0 || bounds.size.height < 1.0 ||
        bounds.size.width * bounds.size.height > 128000000.0 ||
        (!effectiveEdge ? (bounds.size.width != double(details.width) || bounds.size.height != double(details.height))
                        : std::max(bounds.size.width, bounds.size.height) > double(*effectiveEdge))) {
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    }
    const int cropX = rect ? rect->x0 : 0;
    const int cropY = rect ? rect->y0 : 0;
    const int w = rect ? rect->width() : int(bounds.size.width);
    const int h = rect ? rect->height() : int(bounds.size.height);

    auto pack = [&](CIImage* image, bool isHDR, float& peakOut) -> ImageData {
        ImageData out(w, h);
        const int stripLimit = std::min(256, h);
        std::vector<float> rgba(size_t(w) * stripLimit * 4);
        float peak = 1.0f;
        for (int row = 0; row < h; row += stripLimit) {
            @autoreleasepool {
                checkProcessingCancellation();
                const int stripHeight = std::min(stripLimit, h - row);
                const CGRect tile = CGRectMake(
                    bounds.origin.x + CGFloat(cropX),
                    bounds.origin.y + bounds.size.height - CGFloat(cropY + row + stripHeight),
                    CGFloat(w),
                    CGFloat(stripHeight));
                for (int i = 0; i < w * stripHeight; ++i) {
                    rgba[size_t(i) * 4 + 3] = std::numeric_limits<float>::quiet_NaN();
                }
                [context render:image
                       toBitmap:rgba.data()
                       rowBytes:size_t(w) * 16
                         bounds:tile
                         format:kCIFormatRGBAf
                     colorSpace:color];
                checkProcessingCancellation();
                RGB* dst = out.pixels.data() + size_t(row) * w;
                for (int i = 0; i < w * stripHeight; ++i) {
                    const float r = rgba[size_t(i) * 4];
                    const float g = rgba[size_t(i) * 4 + 1];
                    const float b = rgba[size_t(i) * 4 + 2];
                    const float a = rgba[size_t(i) * 4 + 3];
                    require(std::isfinite(a) && std::isfinite(r) && std::isfinite(g) && std::isfinite(b),
                        kHdrReasonNonfinite, "Native HDR contains nonfinite pixels");
                    if (isHDR) {
                        dst[i] = {r, g, b};
                    } else {
                        dst[i] = {std::clamp(r, 0.0f, 1.0f), std::clamp(g, 0.0f, 1.0f), std::clamp(b, 0.0f, 1.0f)};
                    }
                    peak = std::max(peak, 0.2126f * r + 0.7152f * g + 0.0722f * b);
                }
            }
        }
        peakOut = peak;
        return out;
    };

    DecodedImage result;
    float headroom = 1.0f;
    float unusedPeak = 1.0f;
    result.pixels.hdr = pack(hdrImage, true, headroom);
    [context clearCaches];
    raw.extendedDynamicRangeAmount = 0.0f;
    CIImage* sdrImage = raw.outputImage;
    if (!sdrImage || !CGRectEqualToRect(CGRectIntegral(sdrImage.extent), bounds)) {
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
    }
    result.pixels.sdr = pack(sdrImage, false, unusedPeak);
    [context clearCaches];
    checkProcessingCancellation();
    if (!pinned.verifyUnchanged()) {
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source has changed");
    }

    result.info.width = details.width;
    result.info.height = details.height;
    result.info.orientation = 1;
    result.info.container = kHdrContainerProRaw;
    result.info.protocol = kHdrProtocolUnknown;
    result.info.colorDescription = kHdrColorSrgb;
    result.info.contentHeadroom = 0.0f;
    result.info.headroomKind = !effectiveEdge ? kHdrHeadroomMeasured : kHdrHeadroomUnknown;
    std::copy_n(pinned.sha256().data(), 32, result.info.sourceSha256);

    result.pixels.nativeWidth = details.width;
    result.pixels.nativeHeight = details.height;
    result.pixels.sourceHeadroom = !effectiveEdge ? headroom : 0.0f;
    result.pixels.sourceQuality = result.pixels.renderQuality = !effectiveEdge ? HDRQuality::Final : HDRQuality::Preview;
    result.pixels.isProxy = effectiveEdge.has_value();
    result.pixels.decodeRevision = appleProRAWRevision;
    return result;
}

} // namespace

StreamSourcePin::~StreamSourcePin() {
    delete static_cast<StreamSourcePinImpl*>(this->impl);
}

void freezeStreamSourceFile(const char* path, StreamSourcePin& pin) {
    @autoreleasepool {
        // 相机 RAW 不复制原始元数据；仅固定文件身份，不追加 ImageIO 解码能力要求。
        File source;
        if (!path || PinnedSourceFile::pinIdentity(std::filesystem::u8path(path), false, source.pinned) != SourcePinStatus::Ok)
            error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read camera source identity");
        pinFile(source, pin);
    }
}

void verifyStreamSource(const StreamSourcePin& pin) {
    const auto* impl = static_cast<const StreamSourcePinImpl*>(pin.impl);
    if (!impl || !impl->pinned.verifyUnchanged())
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source has changed during export");
}

HDRSourceInfo probeAppleProRAW(const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            const auto details = probeAppleProRAWDetails(path);
            HDRSourceInfo info{};
            info.width = details.width;
            info.height = details.height;
            info.orientation = 1;
            info.container = kHdrContainerProRaw;
            info.protocol = kHdrProtocolUnknown;
            info.colorDescription = kHdrColorSrgb;
            info.contentHeadroom = 0.0f;
            info.headroomKind = kHdrHeadroomUnknown;
            return info;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}

HDRSourceInfo probeFileOrAppleProRAW(const char* path) {
    if (isDNGPath(path)) return probeAppleProRAW(path);
    return probeFile(path);
}

HDRRowSource openAppleProRAWRows(const char* path, const uint8_t expectedSHA[32], StreamSourcePin& pin, uint64_t& decodeRevision) {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            const auto details = probeAppleProRAWDetails(path);
            const bool hasExpected = expectedSHA && std::any_of(expectedSHA, expectedSHA + 32,
                [](uint8_t value) { return value != 0; });
            File file;
            readMetadataOnlySource(file, path, hasExpected ? expectedSHA : nullptr);
            if (!(file.pinned.stamp() == details.pinned.stamp())) {
                error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source differs from the frozen file");
            }
            pinFile(file, pin);
            struct ProRAWReader {
                NSURL* url = nil;
                NSString* decoderVersion = nil;
                uint32_t width = 0;
                uint32_t height = 0;
                CIRAWFilter* raw = nil;
                CIContext* context = nil;
                CIImage* image = nil;
                std::optional<bool> rendition;
                std::vector<float> rgba;
                CGColorSpaceRef color = nullptr;
                ~ProRAWReader() {
                    release();
                    if (color) CGColorSpaceRelease(color);
                }
                void release() {
                    [context clearCaches];
                    image = nil;
                    raw = nil;
                    context = nil;
                    std::vector<float>().swap(rgba);
                }
            };
            auto reader = std::make_shared<ProRAWReader>();
            reader->url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
            reader->decoderVersion = details.decoderVersion;
            reader->width = details.width;
            reader->height = details.height;
            reader->color = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
            if (!reader->color) throw std::bad_alloc();

            HDRRowSource rows;
            rows.width = details.width;
            rows.height = details.height;
            rows.read = [reader, &pin](bool hdr, uint32_t first, uint32_t count, RGB* output) {
                @autoreleasepool {
                    verifyStreamSource(pin);
                    checkProcessingCancellation();
                    if (!output || !count || count > 256 || first > reader->height || count > reader->height - first) {
                        throw std::invalid_argument("Invalid complete HDR source row range");
                    }
                    if (!reader->raw) {
                        admitStreamingMemory(uint64_t(reader->width) * uint64_t(reader->height) * 16 + (128ull << 20));
                        CIRAWFilter* filter = [CIRAWFilter filterWithImageURL:reader->url];
                        if (!filter || ![filter.decoderVersion isEqualToString:reader->decoderVersion]) {
                            error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
                        }
                        reader->raw = filter;
                        NSMutableDictionary* contextOptions = [@{
                            kCIContextWorkingColorSpace: (__bridge id)reader->color,
                            kCIContextCacheIntermediates: @NO,
                            kCIContextMemoryLimit: @256
                        } mutableCopy];
#if defined(SONY2FUJI_ENABLE_METAL)
                        if (id<MTLDevice> device = MTLCreateSystemDefaultDevice()) {
                            reader->context = [CIContext contextWithMTLDevice:device options:contextOptions];
                        } else {
                            reader->context = [CIContext contextWithOptions:contextOptions];
                        }
#else
                        reader->context = [CIContext contextWithOptions:contextOptions];
#endif
                        reader->rgba.resize(size_t(reader->width) * std::min<uint32_t>(256, reader->height) * 4);
                    }
                    if (!reader->rendition.has_value() || *reader->rendition != hdr) {
                        if (first != 0) throw std::invalid_argument("Invalid ProRAW rendition start row");
                        [reader->context clearCaches];
                        reader->raw.extendedDynamicRangeAmount = hdr ? 1.0f : 0.0f;
                        reader->image = reader->raw.outputImage;
                        reader->rendition = hdr;
                    }
                    if (!reader->image || !reader->context) {
                        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
                    }
                    const CGRect bounds = CGRectIntegral(reader->image.extent);
                    if (bounds.size.width != double(reader->width) || bounds.size.height != double(reader->height)) {
                        error(RenderStatus::Unsupported, kHdrReasonUnsupportedRaw, "Unsupported ProRAW source");
                    }
                    const CGRect tile = CGRectMake(
                        bounds.origin.x,
                        bounds.origin.y + bounds.size.height - CGFloat(first + count),
                        bounds.size.width,
                        CGFloat(count));
                    for (size_t i = 0; i < size_t(reader->width) * count; ++i) {
                        reader->rgba[i * 4 + 3] = std::numeric_limits<float>::quiet_NaN();
                    }
                    [reader->context render:reader->image
                                   toBitmap:reader->rgba.data()
                                   rowBytes:size_t(reader->width) * 16
                                     bounds:tile
                                     format:kCIFormatRGBAf
                                 colorSpace:reader->color];
                    checkProcessingCancellation();
                    for (size_t i = 0; i < size_t(reader->width) * count; ++i) {
                        const float r = reader->rgba[i * 4];
                        const float g = reader->rgba[i * 4 + 1];
                        const float b = reader->rgba[i * 4 + 2];
                        const float a = reader->rgba[i * 4 + 3];
                        require(std::isfinite(a) && std::isfinite(r) && std::isfinite(g) && std::isfinite(b),
                            kHdrReasonNonfinite, "Native HDR contains nonfinite pixels");
                        if (hdr) {
                            output[i] = {r, g, b};
                        } else {
                            output[i] = {std::clamp(r, 0.0f, 1.0f), std::clamp(g, 0.0f, 1.0f), std::clamp(b, 0.0f, 1.0f)};
                        }
                    }
                }
            };
            rows.finish = [reader, &pin] { reader->release(); verifyStreamSource(pin); };
            decodeRevision = appleProRAWRevision;
            return rows;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}

HDRRowSource openRasterRows(const char* path, const uint8_t expectedSHA[32], StreamSourcePin& pin, uint64_t& decodeRevision) {
    if (isDNGPath(path)) {
        return openAppleProRAWRows(path, expectedSHA, pin, decodeRevision);
    }
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            if (!expectedSHA || std::all_of(expectedSHA, expectedSHA + 32, [](uint8_t value) { return value == 0; })) {
                error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source differs from the frozen file");
            }
            File file; open(file, path);
            if (std::memcmp(file.info.sourceSha256, expectedSHA, 32) != 0)
                error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source differs from the frozen file");
            pinFile(file, pin);
            struct Reader {
                CIImage* high = nil;
                CIImage* low = nil;
                CIContext* context = nil;
                NSData* compressed = nil;
                uint32_t width = 0, height = 0, orientation = 1;
                bool fallback = false;
                std::unique_ptr<ImageData> jpeg;
                void release() {
                    [context clearCaches]; context = nil; high = nil; low = nil; compressed = nil; jpeg.reset();
                }
                ~Reader() { release(); }
            };
            auto reader = std::make_shared<Reader>();
            reader->high = [CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@YES}];
            reader->low = [CIImage imageWithData:file.data options:@{kCIImageApplyOrientationProperty:@YES,kCIImageExpandToHDR:@NO}];
            require(reader->high && reader->low && CGRectEqualToRect(reader->high.extent, reader->low.extent),
                kHdrReasonMalformedAux, "HDR/SDR canvases differ");
            reader->orientation = file.info.orientation;
            reader->width = file.info.orientation >= 5 ? file.info.height : file.info.width;
            reader->height = file.info.orientation >= 5 ? file.info.width : file.info.height;
            require(reader->high.extent.size.width == reader->width && reader->high.extent.size.height == reader->height,
                kHdrReasonInvalidBuffer, "Decoded HDR canvas differs from metadata");
            reader->fallback = reader->high.contentHeadroom <= 1 && file.info.container == kHdrContainerJpeg &&
                file.info.protocol != kHdrProtocolApple;
            if (reader->fallback) reader->compressed = file.data;
            require(file.info.contentHeadroom > 1, kHdrReasonUnsupportedProtocol,
                "Native codec did not expand the gain map");
            auto normalize = [](CIImage* image) {
                return [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
            };
            reader->high = normalize(reader->high); reader->low = normalize(reader->low);
            NSMutableDictionary* contextOptions = [@{kCIContextWorkingFormat:@(kCIFormatRGBAf),
                kCIContextCacheIntermediates:@NO,kCIContextUseSoftwareRenderer:@YES} mutableCopy];
            contextOptions[kCIContextMemoryLimit] = @256;
            reader->context = [CIContext contextWithOptions:contextOptions];
            HDRRowSource rows; rows.width = reader->width; rows.height = reader->height;
            rows.read = [reader](bool hdr, uint32_t first, uint32_t count, RGB* output) {
                @autoreleasepool {
                    if (!output || !count || count > 256 || first > reader->height || count > reader->height - first)
                        throw std::invalid_argument("Invalid complete HDR source row range");
                    if (hdr && reader->fallback) {
                        if (!reader->jpeg) {
                            admitMemory(uint64_t(reader->width) * reader->height * sizeof(RGB) + (64ull << 20));
                            reader->jpeg = std::make_unique<ImageData>(decodeJPEG(reader->compressed.bytes, reader->compressed.length));
                            GeometryOptions geometry;
                            switch (reader->orientation) {
                                case 2: geometry.flip_horizontal = true; break;
                                case 3: geometry.quarter_turns = 2; break;
                                case 4: geometry.flip_vertical = true; break;
                                case 5: geometry.quarter_turns = 1; geometry.flip_horizontal = true; break;
                                case 6: geometry.quarter_turns = 1; break;
                                case 7: geometry.quarter_turns = 1; geometry.flip_vertical = true; break;
                                case 8: geometry.quarter_turns = 3; break;
                            }
                            require(applyGeometry(*reader->jpeg, geometry) == ErrorCode::Success &&
                                uint32_t(reader->jpeg->width) == reader->width && uint32_t(reader->jpeg->height) == reader->height,
                                kHdrReasonInvalidBuffer, "JPEG fallback and SDR canvases disagree");
                        }
                        std::copy_n(reader->jpeg->pixels.data() + size_t(first) * reader->width, size_t(count) * reader->width, output);
                    } else pixelRows(reader->context, hdr ? reader->high : reader->low, reader->width, reader->height, first, count, output);
                }
            };
            rows.finish = [reader, &pin] { reader->release(); verifyStreamSource(pin); };
            decodeRevision = revision.fetch_add(1);
            return rows;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}

void validateStreamSource(const HDRExportConfig& config, uint32_t width, uint32_t height,
    const char* path, StreamSourcePin& pin) {
    @autoreleasepool {
        differentFile(config.metadataSourcePath, path);
        // 全零 config.sourceSha256 表示调用方未预冻结：内部自采一次并贯穿发布阶段。
        const bool hasExpected = !std::all_of(config.sourceSha256, config.sourceSha256 + 32,
            [](uint8_t value) { return value == 0; });
        File source;
        NSDictionary* values = nil;
        if (isDNGPath(config.metadataSourcePath)) {
            readMetadataOnlySource(source, config.metadataSourcePath, hasExpected ? config.sourceSha256 : nullptr);
            values = source.properties;
        } else {
            readMetadataSource(source, config.metadataSourcePath, hasExpected ? config.sourceSha256 : nullptr);
            values = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source.source, 0, nullptr));
            source.properties = values;
        }
        uint32_t actualWidth = [values[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedIntValue];
        uint32_t actualHeight = [values[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedIntValue];
        const auto orientation = [values[(__bridge NSString*)kCGImagePropertyOrientation] unsignedIntValue];
        if (orientation >= 5 && orientation <= 8) std::swap(actualWidth, actualHeight);
        if (actualWidth != width || actualHeight != height)
            error(RenderStatus::InvalidArgument, kHdrReasonPreviewSource,
                "Stream must read the complete oriented source canvas");
        // C-08：此处冻结一次源；publish 直接复用这份数据与解析，改名前只核对 fstat 快照。
        pinFile(source, pin);
    }
}

JPEGTransformBase makeStreamBaseTransform(const HDRExportConfig& config, uint32_t width, uint32_t height,
    const char* path, const StreamSourcePin& pin) {
    if (!config.metadataSourcePath) return {};
    std::string metadataPath(config.metadataSourcePath);
    const bool hasTargetPath = path != nullptr;
    std::string targetPath(path ? path : "");
    std::array<uint8_t, 32> expectedSha{};
    std::copy_n(config.sourceSha256, 32, expectedSha.begin());
    const auto* impl = static_cast<const StreamSourcePinImpl*>(pin.impl);
    const bool hasPin = impl != nullptr;
    NSData* pinnedData = impl ? impl->data : nil;
    NSDictionary* pinnedProperties = impl ? impl->cachedProperties : nil;
    std::shared_ptr<const void> pinnedSource;
    if (impl && impl->source) {
        pinnedSource.reset(CFRetain(impl->source), [](const void* ref) {
            if (ref) CFRelease(ref);
        });
    }
    std::shared_ptr<const void> pinnedMetadata;
    if (impl && impl->cachedMetadata) {
        pinnedMetadata.reset(CFRetain(impl->cachedMetadata), [](const void* ref) {
            if (ref) CFRelease(ref);
        });
    }
    return [metadataPath = std::move(metadataPath), hasTargetPath, targetPath = std::move(targetPath),
            expectedSha, width, height, hasPin, pinnedData, pinnedProperties, pinnedSource, pinnedMetadata](const std::vector<uint8_t>& base) {
        @autoreleasepool {
            if (@available(macOS 15.0, iOS 18.0, *)) {
                checkProcessingCancellation();
                const char* destPath = hasTargetPath ? targetPath.c_str() : nullptr;
                File source;
                NSDictionary* properties = nil;
                if (hasPin) {
                    source.data = pinnedData;
                    source.properties = pinnedProperties;
                    source.source = pinnedSource ? (CGImageSourceRef)CFRetain(pinnedSource.get()) : nullptr;
                    source.metadataTags = pinnedMetadata ? (CGImageMetadataRef)CFRetain(pinnedMetadata.get()) : nullptr;
                    differentFile(metadataPath.c_str(), destPath);
                    properties = buildMetadata(source, width, height);
                } else {
                    properties = metadata(source, metadataPath.c_str(), expectedSha.data(), width, height, destPath);
                }
                NSData* tagged = addBaseMetadataFromFile(
                    [NSData dataWithBytesNoCopy:const_cast<uint8_t*>(base.data()) length:base.size() freeWhenDone:NO],
                    properties, source);
                const auto* ptr = static_cast<const uint8_t*>(tagged.bytes);
                return std::vector<uint8_t>(ptr, ptr + tagged.length);
            }
            error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
        }
    };
}

void publishStreamJPEG(std::vector<uint8_t> data, uint32_t width, uint32_t height,
    const HDRExportConfig& config, bool hdr, const char* path, const StreamSourcePin& pin, bool baseMetadataApplied) {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            checkProcessingCancellation();
            const auto* impl = static_cast<const StreamSourcePinImpl*>(pin.impl);
            uint64_t sourceSize = 0;
            if (impl) sourceSize = impl->sourceSize;
            else if (config.metadataSourcePath && !isDNGPath(config.metadataSourcePath)) {
                NSNumber* sourceBytes = [[[NSFileManager defaultManager]
                    attributesOfItemAtPath:[NSString stringWithUTF8String:config.metadataSourcePath] error:nil] objectForKey:NSFileSize];
                if (!sourceBytes)
                    error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot inspect streamed metadata source");
                sourceSize = sourceBytes.unsignedLongLongValue;
            }
            if (!(hdr && baseMetadataApplied)) {
                // 元数据重封装有自己的 compressed/NSData 工作集，不能沿用已结束的 codec 准入。
                admitStreamingMemory(uint64_t(data.size()) * 8 + sourceSize * 2 + (64ull << 20));
                File source;
                NSDictionary* properties = nil;
                if (impl) {
                    // 单次读取贯穿 validate→publish：元数据直接来自冻结的同一 NSData/解析，不再重开重算。
                    source.data = impl->data;
                    source.properties = impl->cachedProperties;
                    source.source = impl->source ? (CGImageSourceRef)CFRetain(impl->source) : nullptr;
                    source.metadataTags = impl->cachedMetadata ? (CGImageMetadataRef)CFRetain(impl->cachedMetadata) : nullptr;
                    differentFile(config.metadataSourcePath, path);
                    properties = buildMetadata(source, width, height);
                } else {
                    properties = metadata(source, config.metadataSourcePath, config.sourceSha256, width, height, path);
                }
                if (hdr) {
                    const auto base = jpegBase(data.data(), data.size());
                    NSData* tagged = addBaseMetadataFromFile([NSData dataWithBytesNoCopy:const_cast<uint8_t*>(base.data()) length:base.size() freeWhenDone:NO],
                        properties, source);
                    data = replaceJPEGBase(data.data(), data.size(), tagged.bytes, tagged.length);
                } else {
                    data = withSRGBProfile(data);
                    NSData* tagged = addBaseMetadataFromFile([NSData dataWithBytesNoCopy:data.data() length:data.size() freeWhenDone:NO], properties, source);
                    data.assign(static_cast<const uint8_t*>(tagged.bytes), static_cast<const uint8_t*>(tagged.bytes) + tagged.length);
                }
            }
            if (hdr) probeJPEG(data.data(), data.size());
            atomicStreamWrite([NSData dataWithBytesNoCopy:data.data() length:data.size() freeWhenDone:NO], path, config, pin);
            return;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}

HDRSourceInfo probeFile(const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) { File file; open(file,path); return file.info; }
        File file; read(file,path);
        NSDictionary* apple=CFBridgingRelease(CGImageSourceCopyAuxiliaryDataInfoAtIndex(file.source,0,kCGImageAuxiliaryDataTypeHDRGainMap));
        if (!apple && !declaresGainMap(file.data))
            error(RenderStatus::Unsupported, kHdrReasonNotHdr, "No HDR gain map");
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}
DecodedImage decodeFile(const char* path,const HDRDecodeOptions& options) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            if (isDNGPath(path)) return decodeAppleProRAWRegion(path, &options, nullptr);
            File file; open(file,path); return decode(file,options);
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}
DecodedImage decodeFileROI(const char* path, const RoiSubRect& rect) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            if (isDNGPath(path)) return decodeAppleProRAWRegion(path, nullptr, &rect);
            File file; open(file,path); return decodeROI(file,rect);
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}
void exportJPEG(const HDRImagePair& image,const HDRExportConfig& config,const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            if (config.metadataPolicy!=kHdrMetadataIsoXmp)
                throw std::invalid_argument("HDR JPEG requires ISO and XMP metadata");
            File metadataFile;
            NSDictionary* properties=metadata(metadataFile,config.metadataSourcePath,config.sourceSha256,image.hdr.width,image.hdr.height,path);
            reportHdrProgress(100, 1000);
            JPEGTransformBase transformBase;
            if (config.metadataSourcePath) {
                transformBase = [&](const std::vector<uint8_t>& base) {
                    NSData* tagged = addBaseMetadataFromFile(
                        [NSData dataWithBytesNoCopy:const_cast<uint8_t*>(base.data()) length:base.size() freeWhenDone:NO],
                        properties, metadataFile);
                    const auto* ptr = static_cast<const uint8_t*>(tagged.bytes);
                    return std::vector<uint8_t>(ptr, ptr + tagged.length);
                };
            }
            std::vector<uint8_t> data;
            {
                HdrProgressSubrangeScope sub(100, 900);
                data = encodeJPEG(image,config.jpegQuality ? config.jpegQuality : 95,config.baseColor,transformBase);
            }
            probeJPEG(data.data(),data.size());
            if (config.metadataSourcePath) {
                if (!metadataFile.pinned.verifyUnchanged())
                    error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source has changed");
                differentFile(config.metadataSourcePath,path);
            }
            reportHdrProgress(950, 1000);
            checkProcessingCancellation();
            atomicWrite([NSData dataWithBytesNoCopy:data.data() length:data.size() freeWhenDone:NO],path);
            reportHdrProgress(1000, 1000);
            return;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}
static CIImage* heifLinearImage(const ImageData& plane, CGColorSpaceRef color, bool hdr) HDR_AVAILABLE {
    const size_t bytesPerRow = size_t(plane.width) * sizeof(float) * 4;
    NSMutableData* data = [NSMutableData dataWithLength:bytesPerRow * plane.height];
    if (!data) throw std::bad_alloc();
    auto* pixels = static_cast<float*>(data.mutableBytes);
    // 以正通道峰值标记 HDR 输入，低于参考白的编辑仍可带增益图。
    float headroom = hdr ? 1.001f : 1;
    std::vector<float> rowHeadroom(plane.height > 0 ? size_t(plane.height) : 0, headroom);
    parallelRowRanges(plane.height, plane.width, [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            float* dst = pixels + size_t(y) * plane.width * 4;
            float rowMax = headroom;
            for (int x = 0; x < plane.width; ++x) {
                const auto& p = plane.pixels[size_t(y) * plane.width + x];
                dst[0] = p.r; dst[1] = p.g; dst[2] = p.b; dst[3] = 1;
                dst += 4;
                if (hdr) rowMax = std::max({rowMax, p.r, p.g, p.b});
            }
            rowHeadroom[size_t(y)] = rowMax;
        }
    });
    if (hdr) {
        for (float value : rowHeadroom) headroom = std::max(headroom, value);
    }
    auto provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) throw std::bad_alloc();
    auto pixelsImage = CGImageCreate(plane.width,plane.height,32,128,bytesPerRow,color,
        kCGBitmapFloatComponents | kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedLast,
        provider,nullptr,false,kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!pixelsImage) throw std::bad_alloc();
    auto tagged = headroom > 1 ? CGImageCreateCopyWithContentHeadroom(headroom,pixelsImage) : CGImageRetain(pixelsImage);
    CGImageRelease(pixelsImage);
    if (!tagged) throw std::bad_alloc();
    CIImage* image = [CIImage imageWithCGImage:tagged];
    CGImageRelease(tagged);
    return image;
}

static NSData* encodeHEIFImages(CIImage* hdr, CIImage* sdr, uint32_t width, uint32_t height,
    NSDictionary* properties, uint32_t color, uint32_t quality, bool tiled,
    const std::function<void()>& checkInput = {}) HDR_AVAILABLE {
    using ColorSpace = std::unique_ptr<std::remove_pointer_t<CGColorSpaceRef>,decltype(&CGColorSpaceRelease)>;
    ColorSpace linear(CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB),CGColorSpaceRelease);
    ColorSpace base(CGColorSpaceCreateWithName(color == kHdrColorDisplayP3 ?
        kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB),CGColorSpaceRelease);
    if (!linear || !base) throw std::bad_alloc();
    sdr = [sdr imageBySettingProperties:properties];
    require(hdr && sdr, kHdrReasonOutputIo, "Cannot build the HEIF renditions");
    NSMutableDictionary* contextOptions = [@{kCIContextUseSoftwareRenderer:@YES,
        kCIContextWorkingColorSpace:(__bridge id)linear.get()} mutableCopy];
    if (tiled) {
        contextOptions[kCIContextCacheIntermediates] = @NO;
        contextOptions[kCIContextMemoryLimit] = @256;
    }
    CIContext* context = [CIContext contextWithOptions:contextOptions];
    NSData* data = [context HEIFRepresentationOfImage:sdr format:kCIFormatRGBX8 colorSpace:base.get()
        options:@{kCIImageRepresentationHDRImage:hdr, kCIImageRepresentationHDRGainMapAsRGB:@YES,
            (__bridge NSString*)kCGImageDestinationLossyCompressionQuality:@((quality ? quality : 95)/100.0)}];
    if (checkInput) checkInput();
    checkProcessingCancellation();
    require(data.length, kHdrReasonOutputIo, "Cannot encode adaptive HDR HEIF");
    File verification; verification.data = data;
    verification.source = CGImageSourceCreateWithData((__bridge CFDataRef)data,nullptr);
    require(verification.source, kHdrReasonOutputIo, "Cannot read the encoded HEIF");
    describe(verification);
    inspectGainMap(verification);
    require(verification.info.container == kHdrContainerHeif && verification.info.protocol == kHdrProtocolIso &&
        verification.info.width == width && verification.info.height == height &&
        verification.info.orientation == 1 && verification.info.colorDescription == color &&
        [verification.properties[(__bridge NSString*)kCGImagePropertyDepth] unsignedIntValue] == 8 &&
        (hdr.contentHeadroom <= 1.001f || verification.info.contentHeadroom > 1),
        kHdrReasonOutputIo, "Encoded HEIF did not retain the expected ISO gain map, geometry or color");
    return data;
}

static NSData* encodeHEIF(const HDRImagePair& image, NSDictionary* properties, uint32_t color, uint32_t quality) HDR_AVAILABLE {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    if (!space) throw std::bad_alloc();
    std::unique_ptr<std::remove_pointer_t<CGColorSpaceRef>, decltype(&CGColorSpaceRelease)> linear(space, CGColorSpaceRelease);
    return encodeHEIFImages(heifLinearImage(image.hdr, space, true), heifLinearImage(image.sdr, space, false),
        uint32_t(image.hdr.width), uint32_t(image.hdr.height), properties, color, quality, false);
}

static bool probeHEIFExport() HDR_AVAILABLE {
    @autoreleasepool {
        try {
            // 系统提供编码接口也可能无法读回 ISO 增益图，先用小图验证当前运行环境。
            ProcessingCancellationScope capabilityProbe(ProcessingCancellation{});
            HDRImagePair sample;
            sample.hdr = ImageData(64,64);
            sample.sdr = ImageData(64,64);
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                const float v = 0.25f + 0.75f * x / 63;
                sample.sdr.at(x,y) = {v,v,v};
                sample.hdr.at(x,y) = {2*v,2*v,2*v};
            }
            return encodeHEIF(sample,@{},kHdrColorDisplayP3,95) != nil;
        } catch (...) {
            return false;
        }
    }
}

bool heifExportAvailable() {
    if (@available(macOS 15.0,iOS 18.0,*)) {
        static const bool supported = probeHEIFExport();
        return supported;
    }
    return false;
}

void exportHEIF(const HDRImagePair& image,const HDRExportConfig& config,const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            File metadataFile;
            NSDictionary* properties = metadata(metadataFile,config.metadataSourcePath,config.sourceSha256,image.hdr.width,image.hdr.height,path);
            reportHdrProgress(150, 1000);
            NSData* data = encodeHEIF(image,properties,config.baseColor,config.jpegQuality);
            reportHdrProgress(900, 1000);
            if (config.metadataSourcePath) {
                // 编码期间源若被替换/覆写，inode 或 size/mtime/ctime 已变；核对 metadata()
                // 单次读取时抓取的快照即可，不再整文件重算第二遍摘要（C-08：2→1）。
                if (!metadataFile.pinned.verifyUnchanged())
                    error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source has changed");
                differentFile(config.metadataSourcePath,path);
            }
            checkProcessingCancellation();
            atomicWrite(data,path);
            reportHdrProgress(1000, 1000);
            return;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR HEIF requires macOS15/iOS18");
    }
}

void publishTiledHEIF(const HDRStreamFiles& image, const HDRExportConfig& config,
    const char* path, const StreamSourcePin& pin) {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            const uint32_t width = image.result.width, height = image.result.height;
            // 工作平面由 provider 按块读取；预算仍覆盖目标尺寸的系统编码与增益图缓冲。
            admitStreamingMemory(uint64_t(width) * height * 16 + (128ull << 20));
            const auto* impl = static_cast<const StreamSourcePinImpl*>(pin.impl);
            verifyStreamSource(pin);
            differentFile(impl->pinned.path().u8string().c_str(), path);
            File source;
            source.data = impl->data;
            source.properties = impl->cachedProperties;
            source.source = impl->source ? (CGImageSourceRef)CFRetain(impl->source) : nullptr;
            source.metadataTags = impl->cachedMetadata ? (CGImageMetadataRef)CFRetain(impl->cachedMetadata) : nullptr;
            NSDictionary* properties = config.metadataSourcePath ? buildMetadata(source, width, height) : @{};
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
            if (!space) throw std::bad_alloc();
            std::unique_ptr<std::remove_pointer_t<CGColorSpaceRef>, decltype(&CGColorSpaceRelease)> linear(space, CGColorSpaceRelease);
            auto provider = [&](const std::filesystem::path& file) {
                RawLabHDRFileProvider* value = [RawLabHDRFileProvider new];
                value->pixels = std::make_shared<storage::File>(file);
                value->imageWidth = width; value->imageHeight = height;
                value->cancellation = processingCancellation;
                return value;
            };
            RawLabHDRFileProvider* high = provider(image.hdr);
            RawLabHDRFileProvider* low = provider(image.sdr);
            auto input = [&](RawLabHDRFileProvider* provider, float headroom) {
                return [CIImage imageWithImageProvider:provider size:width :height format:kCIFormatRGBAf colorSpace:space
                    options:@{kCIImageProviderTileSize:@128, kCIImageContentHeadroom:@(headroom)}];
            };
            NSData* data = encodeHEIFImages(input(high, image.rgbHeadroom), input(low, 1), width, height,
                properties, config.baseColor, config.jpegQuality, true, [&] { [high checkFailure]; [low checkFailure]; });
            atomicStreamWrite(data, path, config, pin);
            return;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR HEIF requires macOS15/iOS18");
    }
}

void exportSDR(const HDRImagePair& image,const HDRSdrExportConfig& config,const char* path) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) {
            if (config.outputFormat!=kHdrSdrOutputJpeg && config.outputFormat!=kHdrSdrOutputPng)
                error(RenderStatus::Unsupported, kHdrReasonUnsupportedProtocol, "Unsupported SDR rendition output format");
            if (config.quality>100) throw std::invalid_argument("Invalid SDR quality");
            File metadataFile;
            NSDictionary* properties=metadata(metadataFile,config.metadataSourcePath,config.sourceSha256,image.sdr.width,image.sdr.height,path);
            reportHdrProgress(150, 1000);
            NSMutableDictionary* values=[properties mutableCopy];
            values[(__bridge NSString*)kCGImageDestinationLossyCompressionQuality]=@((config.quality ? config.quality : 95)/100.0);
            NSMutableData* data=[NSMutableData data];
            CGImageRef pixels=sdrImage(image.sdr,config.outputFormat==kHdrSdrOutputPng);
            reportHdrProgress(500, 1000);
            CFStringRef type=config.outputFormat==kHdrSdrOutputJpeg ? CFSTR("public.jpeg") : CFSTR("public.png");
            CGImageDestinationRef dest=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,type,1,nullptr);
            if (!dest) { CGImageRelease(pixels); throw std::bad_alloc(); }
            CGImageDestinationAddImage(dest,pixels,(__bridge CFDictionaryRef)values);
            const bool success=CGImageDestinationFinalize(dest); CGImageRelease(pixels); CFRelease(dest);
            require(success, kHdrReasonOutputIo, "Cannot encode SDR rendition");
            NSData* outputData = data;
            if (config.outputFormat == kHdrSdrOutputJpeg) {
                std::vector<uint8_t> jpeg(static_cast<const uint8_t*>(data.bytes),
                                          static_cast<const uint8_t*>(data.bytes) + data.length);
                jpeg = withSRGBProfile(jpeg);
                outputData = [NSData dataWithBytes:jpeg.data() length:jpeg.size()];
            }
            reportHdrProgress(900, 1000);
            checkProcessingCancellation();
            atomicWrite(outputData,path);
            reportHdrProgress(1000, 1000);
            return;
        }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}
} // namespace sony2fuji::hdr
