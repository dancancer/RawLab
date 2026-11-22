#include "platform/hdr_image.h"
#include "core/hdr_jpeg.h"
#include "core/hdr_progress.h"
#include "core/hdr_srgb_lut.h"
#include "core/jpeg_mpf.h"
#include "core/output_file_mode.h"
#include "core/parallel_pixels.h"
#include "core/hdr_storage.h"
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
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <limits>
#include <string>
#include <malloc/malloc.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

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
std::atomic<uint64_t> sourceHashPasses{0};

[[noreturn]] void error(RenderStatus status, uint32_t reason, const char* message) {
    throw Error(status, reason, kHdrFieldPath, message);
}
void require(bool condition, uint32_t reason, const char* message) {
    if (!condition) error(RenderStatus::ProcessingError, reason, message);
}

// fstat 级源身份快照：发布前核对「路径未被替换/改写」，取代再读一遍并整文件重算摘要。
// `.atomic` 替换换 inode；就地覆写改 size/mtime/ctime，两个方向都能命中。
struct SourceSnapshot {
    dev_t device = 0;
    ino_t inode = 0;
    off_t size = 0;
    struct timespec modification{};
    struct timespec statusChange{};
    bool valid = false;
};
SourceSnapshot snapshotOf(const struct stat& details) {
    SourceSnapshot snapshot;
    snapshot.device = details.st_dev; snapshot.inode = details.st_ino; snapshot.size = details.st_size;
    snapshot.modification = details.st_mtimespec; snapshot.statusChange = details.st_ctimespec;
    snapshot.valid = true;
    return snapshot;
}
SourceSnapshot snapshotSource(const char* path) {
    struct stat details{};
    if (!path || ::stat(path, &details) != 0) return {};
    return snapshotOf(details);
}
bool snapshotMatches(const SourceSnapshot& left, const SourceSnapshot& right) {
    return left.valid && right.valid && left.device == right.device && left.inode == right.inode &&
        left.size == right.size &&
        left.modification.tv_sec == right.modification.tv_sec && left.modification.tv_nsec == right.modification.tv_nsec &&
        left.statusChange.tv_sec == right.statusChange.tv_sec && left.statusChange.tv_nsec == right.statusChange.tv_nsec;
}

struct File {
    NSData* data = nil;
    NSDictionary* properties = nil;
    CGImageSourceRef source = nullptr;
    HDRSourceInfo info{};
    SourceSnapshot snapshot{};
    ~File() { if (source) CFRelease(source); }
};

// 流式导出的源冻结快照（对 hdr_image.h 的 StreamSourcePin::impl 不透明）。
struct StreamSourcePinImpl {
    NSData* data = nil;               // validate 时单次读取的源容器
    CGImageSourceRef source = nullptr; // 与 data 同一解析，publish 复用其元数据
    SourceSnapshot snapshot{};
    std::string path;
};

void pinFile(const File& source, const char* path, StreamSourcePin& pin) {
    if (!pin.impl) pin.impl = new StreamSourcePinImpl();
    auto* impl = static_cast<StreamSourcePinImpl*>(pin.impl);
    if (impl->source) CFRelease(impl->source);
    impl->data = source.data;
    impl->source = source.source ? (CGImageSourceRef)CFRetain(source.source) : nullptr;
    impl->snapshot = source.snapshot; impl->path = path;
    std::copy_n(source.info.sourceSha256, 32, pin.digest);
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

void readMetadataSource(File& file, const char* path, const uint8_t* expectedSHA = nullptr) {
    NSString* name = [NSString stringWithUTF8String:path];
    if (!name) error(RenderStatus::InvalidArgument, kHdrReasonInvalidArgument, "Invalid UTF-8 HDR path");
    // 单次打开：数据读取与前后两次 fstat 共享同一 fd，「数据 ↔ 快照身份」原子绑定；
    // 读后「路径被原子替换」不会被误记为本体快照（B1）。堆内读取不跨流式周期持有
    // 文件映射，外部就地 O_TRUNC 不会在延后解析时触发 SIGBUS。
    const int descriptor = ::open([name fileSystemRepresentation], O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) error(RenderStatus::IoError, kHdrReasonInputIo, "HDR source is not a regular file");
    struct stat before{};
    if (::fstat(descriptor, &before) != 0 || !S_ISREG(before.st_mode)) {
        ::close(descriptor);
        error(RenderStatus::IoError, kHdrReasonInputIo, "HDR source is not a regular file");
    }
    struct DescriptorGuard {
        int descriptor;
        ~DescriptorGuard() { if (descriptor >= 0) ::close(descriptor); }
    } guard{descriptor};
    NSMutableData* storage = [[NSMutableData alloc] initWithLength:(NSUInteger)std::max<off_t>(before.st_size, 0)];
    if (before.st_size > 0) {
        auto* bytes = static_cast<uint8_t*>(storage.mutableBytes);
        off_t filled = 0;
        bool firstChunk = true;
        while (true) {
            checkProcessingCancellation();
            ssize_t got = -1; errno = 0;
            if (filled < before.st_size)
                got = ::read(descriptor, bytes + filled,
                    std::min<size_t>(4u * 1024 * 1024, size_t(before.st_size - filled)));
            else { // 容量已满仍可能有并发增长；探测一次即可，由后一次 fstat 夹逼裁决。
                unsigned char probe = 0;
                got = ::read(descriptor, &probe, 1);
                if (got != 0) { ++filled; break; }
                break;
            }
            if (got < 0 && errno == EINTR) continue;
            if (got < 0) { ::close(guard.descriptor); guard.descriptor = -1;
                error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read HDR source"); }
            if (got == 0) break; // 并发截断：短读由后一次 fstat 夹逼裁决。
            filled += got;
            if (firstChunk) {
                firstChunk = false;
                if (sourceReadTestHook) sourceReadTestHook(); // 测试注入缝：读中途恰好触发一次。
            }
        }
    }
    struct stat after{};
    if (::fstat(descriptor, &after) != 0 || !snapshotMatches(snapshotOf(before), snapshotOf(after)))
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source has changed");
    file.data = storage;
    if (!file.data.length) error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read HDR source");
    file.snapshot = snapshotOf(before);
    // 源身份不依赖路径/mtime，元数据保存使用同一 SHA-256 校验原容器。
    sourceHashPasses.fetch_add(1, std::memory_order_relaxed);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA256_CTX digest; CC_SHA256_Init(&digest);
    const auto* bytes = static_cast<const uint8_t*>(file.data.bytes);
    for (size_t offset = 0; offset < file.data.length;) {
        checkProcessingCancellation();
        const size_t count = std::min<size_t>(file.data.length-offset, 1024*1024);
        CC_SHA256_Update(&digest,bytes+offset,CC_LONG(count)); offset+=count;
    }
    CC_SHA256_Final(file.info.sourceSha256, &digest);
#pragma clang diagnostic pop
    if (expectedSHA && std::memcmp(file.info.sourceSha256, expectedSHA, 32) != 0)
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR metadata source has changed");
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

void differentFile(const char* source,const char* target) {
    if (!source) return;
    NSURL* a=[[NSURL fileURLWithPath:[NSString stringWithUTF8String:source]] URLByResolvingSymlinksInPath];
    NSURL* b=[[NSURL fileURLWithPath:[NSString stringWithUTF8String:target]] URLByResolvingSymlinksInPath];
    id aid=nil,bid=nil;
    [a getResourceValue:&aid forKey:NSURLFileResourceIdentifierKey error:nil];
    [b getResourceValue:&bid forKey:NSURLFileResourceIdentifierKey error:nil];
    if ([a.URLByStandardizingPath isEqual:b.URLByStandardizingPath] || (aid && bid && [aid isEqual:bid]))
        error(RenderStatus::InvalidArgument, kHdrReasonSameFile, "HDR export cannot replace its source");
}

NSDictionary* buildMetadata(File& file,uint32_t width,uint32_t height) {
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

NSDictionary* metadata(File& file,const char* source,const uint8_t sha[32],uint32_t width,uint32_t height,const char* target) HDR_AVAILABLE {
    if (!source) return @{(__bridge NSString*)kCGImagePropertyOrientation:@1};
    differentFile(source,target);
    readMetadataSource(file,source,sha);
    return buildMetadata(file,width,height);
}

NSData* addBaseMetadata(NSData* base,NSDictionary* properties,CGImageSourceRef original) {
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)base,nullptr);
    NSMutableData* data=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,nullptr);
    CGMutableImageMetadataRef tags=CGImageMetadataCreateMutable();
    CGImageMetadataRef originalTags=original ? CGImageSourceCopyMetadataAtIndex(original,0,nullptr) : nullptr;
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
    if (originalTags) CFRelease(originalTags);
    if (source) CFRelease(source); if (destination) CFRelease(destination); if (tags) CFRelease(tags);
    require(success, kHdrReasonOutputIo, "Cannot write JPEG base metadata"); return data;
}

void atomicWrite(NSData* data,const char* path) {
    NSString* name=[NSString stringWithUTF8String:path];
    if (!name || ![data writeToFile:name options:NSDataWritingAtomic error:nil])
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Atomic HDR output write failed");
}

void atomicStreamWrite(NSData* data, const char* path, const HDRExportConfig& config,
    const StreamSourcePin& pin) {
    std::string temporary;
    int createdFd = -1;
    for (int attempt = 0; attempt < 64 && createdFd < 0; ++attempt) {
        temporary = std::string(path) + ".rawlab-" + stagingSuffix() + ".tmp";
        createdFd = ::open(temporary.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0666);
        if (createdFd < 0) {
            if (errno != EEXIST) break;
            temporary.clear();
        }
    }
    if (createdFd < 0)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot stage streamed JPEG output");
    struct Pending {
        int descriptor;
        const std::string& path;
        ~Pending() { if (descriptor >= 0) close(descriptor); unlink(path.c_str()); }
    } pending{createdFd, temporary};
    preserveDestinationMode(pending.descriptor, std::filesystem::u8path(path));
    const auto* bytes = static_cast<const uint8_t*>(data.bytes);
    for (size_t offset = 0; offset < data.length;) {
        checkProcessingCancellation();
        const auto written = write(pending.descriptor, bytes + offset, std::min<size_t>(1024 * 1024, data.length - offset));
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0)
            error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot write streamed JPEG output");
        offset += size_t(written);
    }
    if (fsync(pending.descriptor) != 0)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot finish streamed JPEG output");
    const int closed = close(pending.descriptor); pending.descriptor = -1;
    if (closed != 0)
        error(RenderStatus::OutputIoError, kHdrReasonOutputIo, "Cannot close streamed JPEG output");
    // 发布前再次核对来源；解码完成后的原片替换不能配上旧像素与新 EXIF。
    if (pin.impl) {
        verifyStreamSource(pin);
    } else if (config.metadataSourcePath) {
        File verification; readMetadataSource(verification, config.metadataSourcePath, config.sourceSha256);
    }
    differentFile(config.metadataSourcePath, path);
    checkProcessingCancellation();
    if (rename(temporary.c_str(), path) != 0)
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

StreamSourcePin::~StreamSourcePin() {
    auto* impl = static_cast<StreamSourcePinImpl*>(this->impl);
    if (!impl) return;
    if (impl->source) CFRelease(impl->source);
    delete impl;
}

void freezeStreamSourceFile(const char* path, StreamSourcePin& pin) {
    @autoreleasepool {
        // 相机 RAW 不复制原始元数据；仅固定文件身份，不追加 ImageIO 解码能力要求。
        File source; source.snapshot = snapshotSource(path);
        if (!source.snapshot.valid)
            error(RenderStatus::IoError, kHdrReasonInputIo, "Cannot read camera source identity");
        pinFile(source, path, pin);
    }
}

void verifyStreamSource(const StreamSourcePin& pin) {
    const auto* impl = static_cast<const StreamSourcePinImpl*>(pin.impl);
    if (!impl || !snapshotMatches(snapshotSource(impl->path.c_str()), impl->snapshot))
        error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source has changed during export");
}

HDRRowSource openRasterRows(const char* path, const uint8_t expectedSHA[32], StreamSourcePin& pin, uint64_t& decodeRevision) {
    @autoreleasepool {
        if (@available(macOS 15.0, iOS 18.0, *)) {
            File file; open(file, path);
            if (std::memcmp(file.info.sourceSha256, expectedSHA, 32) != 0)
                error(RenderStatus::InvalidArgument, kHdrReasonSourceChanged, "HDR source differs from the frozen file");
            pinFile(file, path, pin);
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
        File source; readMetadataSource(source, config.metadataSourcePath, hasExpected ? config.sourceSha256 : nullptr);
        NSDictionary* values = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source.source, 0, nullptr));
        uint32_t actualWidth = [values[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedIntValue];
        uint32_t actualHeight = [values[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedIntValue];
        const auto orientation = [values[(__bridge NSString*)kCGImagePropertyOrientation] unsignedIntValue];
        if (orientation >= 5 && orientation <= 8) std::swap(actualWidth, actualHeight);
        if (actualWidth != width || actualHeight != height)
            error(RenderStatus::InvalidArgument, kHdrReasonPreviewSource,
                "Stream must read the complete oriented source canvas");
        // C-08：此处冻结一次源；publish 直接复用这份数据与解析，改名前只核对 fstat 快照。
        pinFile(source, config.metadataSourcePath, pin);
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
    std::shared_ptr<const void> pinnedSource;
    if (impl && impl->source) {
        pinnedSource.reset(CFRetain(impl->source), [](const void* ref) {
            if (ref) CFRelease(ref);
        });
    }
    return [metadataPath = std::move(metadataPath), hasTargetPath, targetPath = std::move(targetPath),
            expectedSha, width, height, hasPin, pinnedData, pinnedSource](const std::vector<uint8_t>& base) {
        @autoreleasepool {
            if (@available(macOS 15.0, iOS 18.0, *)) {
                checkProcessingCancellation();
                const char* destPath = hasTargetPath ? targetPath.c_str() : nullptr;
                File source;
                NSDictionary* properties = nil;
                if (hasPin) {
                    source.data = pinnedData;
                    source.source = pinnedSource ? (CGImageSourceRef)CFRetain(pinnedSource.get()) : nullptr;
                    differentFile(metadataPath.c_str(), destPath);
                    properties = buildMetadata(source, width, height);
                } else {
                    properties = metadata(source, metadataPath.c_str(), expectedSha.data(), width, height, destPath);
                }
                NSData* tagged = addBaseMetadata(
                    [NSData dataWithBytesNoCopy:const_cast<uint8_t*>(base.data()) length:base.size() freeWhenDone:NO],
                    properties, source.source);
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
            if (impl && impl->data) sourceSize = impl->data.length;
            else if (config.metadataSourcePath) {
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
                    source.source = impl->source ? (CGImageSourceRef)CFRetain(impl->source) : nullptr;
                    differentFile(config.metadataSourcePath, path);
                    properties = buildMetadata(source, width, height);
                } else {
                    properties = metadata(source, config.metadataSourcePath, config.sourceSha256, width, height, path);
                }
                if (hdr) {
                    const auto base = jpegBase(data.data(), data.size());
                    NSData* tagged = addBaseMetadata([NSData dataWithBytesNoCopy:const_cast<uint8_t*>(base.data()) length:base.size() freeWhenDone:NO],
                        properties, source.source);
                    data = replaceJPEGBase(data.data(), data.size(), tagged.bytes, tagged.length);
                } else {
                    data = withSRGBProfile(data);
                    NSData* tagged = addBaseMetadata([NSData dataWithBytesNoCopy:data.data() length:data.size() freeWhenDone:NO], properties, source.source);
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
        if (@available(macOS 15.0,iOS 18.0,*)) { File file; open(file,path); return decode(file,options); }
        error(RenderStatus::Unsupported, kHdrReasonUnsupportedSystem, "HDR requires macOS15/iOS18");
    }
}
DecodedImage decodeFileROI(const char* path, const RoiSubRect& rect) {
    @autoreleasepool {
        if (@available(macOS 15.0,iOS 18.0,*)) { File file; open(file,path); return decodeROI(file,rect); }
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
                    NSData* tagged = addBaseMetadata(
                        [NSData dataWithBytesNoCopy:const_cast<uint8_t*>(base.data()) length:base.size() freeWhenDone:NO],
                        properties, metadataFile.source);
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
                if (!snapshotMatches(snapshotSource(config.metadataSourcePath), metadataFile.snapshot))
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
                if (!snapshotMatches(snapshotSource(config.metadataSourcePath), metadataFile.snapshot))
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
            differentFile(impl->path.c_str(), path);
            File source; source.data = impl->data;
            source.source = impl->source ? (CGImageSourceRef)CFRetain(impl->source) : nullptr;
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

uint64_t sourceHashPassCount() { return sourceHashPasses.load(std::memory_order_relaxed); }
void resetSourceHashPassCount() { sourceHashPasses.store(0, std::memory_order_relaxed); }
void (*sourceReadTestHook)() = nullptr;
} // namespace sony2fuji::hdr
