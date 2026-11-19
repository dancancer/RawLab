#include "platform/display_image.h"
#include "core/jpeg_mpf.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <new>
#include <string>
#include <system_error>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <TargetConditionals.h>
#include <tiffio.h>
#include <unistd.h>
#include <vector>
#endif

namespace {

constexpr uint64_t kMaxDisplayPixels = 128000000ull;

std::string lowerExtension(const char* path) {
    if (!path) return {};
    const std::string value(path);
    const auto slash = value.find_last_of("/\\");
    const auto dot = value.find_last_of('.');
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) return {};
    std::string extension = value.substr(dot + 1);
    std::transform(extension.begin(), extension.end(), extension.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return extension;
}

#if defined(__APPLE__)

template <typename T>
struct CFReleaseDeleter {
    void operator()(T value) const noexcept {
        if (value) CFRelease(value);
    }
};

template <typename T>
using CFUnique = std::unique_ptr<std::remove_pointer_t<T>, CFReleaseDeleter<T>>;

bool equalUTI(CFStringRef actual, CFStringRef expected) {
    return actual && CFStringCompare(actual, expected, 0) == kCFCompareEqualTo;
}

bool supportedUTI(CFStringRef type) {
    return equalUTI(type, CFSTR("public.jpeg")) ||
        equalUTI(type, CFSTR("public.png")) ||
        equalUTI(type, CFSTR("public.tiff")) ||
        equalUTI(type, CFSTR("public.heif")) ||
        equalUTI(type, CFSTR("public.heic"));
}

bool isDNGPath(const char* path) {
    return lowerExtension(path) == "dng";
}

bool numberValue(CFDictionaryRef dictionary, CFStringRef key, int64_t* value) {
    if (!dictionary || !value) return false;
    const auto candidate = static_cast<CFTypeRef>(CFDictionaryGetValue(dictionary, key));
    if (!candidate || CFGetTypeID(candidate) != CFNumberGetTypeID()) return false;
    return CFNumberGetValue(static_cast<CFNumberRef>(candidate), kCFNumberSInt64Type, value);
}

bool stringContains(CFStringRef value, CFStringRef needle) {
    if (!value || !needle) return false;
    return CFStringFind(value, needle, kCFCompareCaseInsensitive).location != kCFNotFound;
}

bool isHDRColorSpace(CGColorSpaceRef colorSpace) {
    if (!colorSpace) return false;
    // 内嵌 ICC 不一定有名字，须先检查实际传递函数和扩展范围。
    if (CGColorSpaceUsesITUR_2100TF(colorSpace) || CGColorSpaceUsesExtendedRange(colorSpace)) return true;
    CFUnique<CFStringRef> name(CGColorSpaceCopyName(colorSpace));
    return stringContains(name.get(), CFSTR("extended")) ||
        stringContains(name.get(), CFSTR("hdr")) ||
        stringContains(name.get(), CFSTR("pq")) ||
        stringContains(name.get(), CFSTR("hlg"));
}

sony2fuji::RenderStatus pngColorMetadataStatus(const char* path, CFStringRef* colorSpaceName) {
    std::ifstream file(path, std::ios::binary);
    if (!file) return sony2fuji::RenderStatus::IoError;
    file.seekg(8);
    while (file) {
        std::array<uint8_t, 8> header{};
        if (!file.read(reinterpret_cast<char*>(header.data()), header.size()))
            return sony2fuji::RenderStatus::ProcessingError;
        const uint32_t length = (uint32_t(header[0]) << 24) | (uint32_t(header[1]) << 16) |
            (uint32_t(header[2]) << 8) | header[3];
        const auto is = [&](const char* type) { return std::memcmp(header.data() + 4, type, 4) == 0; };
        // ImageIO 可能忽略这些块；拒绝规则不能只依赖解码后的色彩空间。
        if (is("mDCv") || is("mDCV") || is("cLLi") || is("cLLI")) return sony2fuji::RenderStatus::Unsupported;
        if (is("cICP")) {
            if (length != 4) return sony2fuji::RenderStatus::Unsupported;
            std::array<uint8_t, 4> cicp{};
            if (!file.read(reinterpret_cast<char*>(cicp.data()), cicp.size()))
                return sony2fuji::RenderStatus::ProcessingError;
            if (cicp == std::array<uint8_t, 4>{1, 13, 0, 1}) *colorSpaceName = kCGColorSpaceSRGB;
            else if (cicp == std::array<uint8_t, 4>{12, 13, 0, 1}) *colorSpaceName = kCGColorSpaceDisplayP3;
            else if (cicp == std::array<uint8_t, 4>{1, 1, 0, 1}) *colorSpaceName = kCGColorSpaceITUR_709;
            else return sony2fuji::RenderStatus::Unsupported;
        } else {
            file.seekg(static_cast<std::streamoff>(length), std::ios::cur);
        }
        std::array<char, 4> crc{};
        if (!file.read(crc.data(), crc.size())) return sony2fuji::RenderStatus::ProcessingError;
        if (is("IEND")) return length == 0 ? sony2fuji::RenderStatus::Ok : sony2fuji::RenderStatus::ProcessingError;
    }
    return sony2fuji::RenderStatus::ProcessingError;
}

bool hasAlpha(CGImageAlphaInfo alpha) {
    return alpha != kCGImageAlphaNone && alpha != kCGImageAlphaNoneSkipFirst &&
        alpha != kCGImageAlphaNoneSkipLast;
}

bool regularFile(const char* path) {
    try {
        std::error_code error;
        const auto file = std::filesystem::u8path(path);
        return std::filesystem::is_regular_file(file, error) && !error;
    } catch (...) {
        return false;
    }
}

bool hasHDRGainMap(CGImageSourceRef source) {
    CFUnique<CFDictionaryRef> hdrGainMap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        source, 0, kCGImageAuxiliaryDataTypeHDRGainMap));
    if (hdrGainMap) return true;
#if (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 150000) || \
    (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000)
    if (__builtin_available(macOS 15.0, iOS 18.0, *)) {
        CFUnique<CFDictionaryRef> isoGainMap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeISOGainMap));
        if (isoGainMap) return true;
    }
#endif
    return false;
}

bool tiffDirectoryHasNoPageMarker(TIFF* tiff) {
    // libtiff locates the IFD, but discards OldSubfileType. Read the page
    // entries directly so a legacy tag cannot be mistaken for an absent one.
    const bool bigTIFF = TIFFIsBigTIFF(tiff);
    const bool bigEndian = TIFFIsBigEndian(tiff);
    const size_t countSize = bigTIFF ? 8 : 2;
    const size_t entrySize = bigTIFF ? 20 : 12;
    const size_t valueOffset = bigTIFF ? 12 : 8;
    const auto readUnsigned = [bigEndian](const uint8_t* bytes, size_t size) {
        uint64_t value = 0;
        for (size_t i = 0; i < size; ++i)
            value = (value << 8) | bytes[bigEndian ? i : size - 1 - i];
        return value;
    };
    const uint64_t offset = TIFFCurrentDirOffset(tiff);
    constexpr uint64_t maxOffset = std::numeric_limits<off_t>::max();
    if (offset == 0 || offset > maxOffset - countSize) return false;
    const int fd = TIFFFileno(tiff);
    uint8_t countBytes[8];
    if (pread(fd, countBytes, countSize, static_cast<off_t>(offset)) != static_cast<ssize_t>(countSize))
        return false;
    const uint64_t count = readUnsigned(countBytes, countSize);
    if (count == 0 || count > UINT16_MAX) return false;
    const size_t length = static_cast<size_t>(count) * entrySize;
    if (offset > maxOffset - countSize - length) return false;
    std::vector<uint8_t> entries(length);
    if (pread(fd, entries.data(), length, static_cast<off_t>(offset + countSize)) !=
        static_cast<ssize_t>(length)) return false;

    for (size_t i = 0; i < length; i += entrySize) {
        const uint8_t* entry = entries.data() + i;
        const uint64_t tag = readUnsigned(entry, 2);
        if (tag == TIFFTAG_PAGENUMBER) return false;
        const bool legacy = tag == TIFFTAG_OSUBFILETYPE;
        if (!legacy && tag != TIFFTAG_SUBFILETYPE) continue;
        if (readUnsigned(entry + 2, 2) != (legacy ? TIFF_SHORT : TIFF_LONG) ||
            readUnsigned(entry + 4, valueOffset - 4) != 1) return false;
        const uint64_t type = readUnsigned(entry + valueOffset, legacy ? 2 : 4);
        if (legacy ? type == OFILETYPE_PAGE : (type & FILETYPE_PAGE) != 0) return false;
    }
    return true;
}

bool hasUnpaginatedTIFFPair(const char* path) {
    // ImageIO's TIFF properties omit the page tags. Check the two IFDs
    // without decoding their pixels.
    std::unique_ptr<TIFFOpenOptions, decltype(&TIFFOpenOptionsFree)> options(
        TIFFOpenOptionsAlloc(), TIFFOpenOptionsFree);
    if (!options) return false;
    TIFFOpenOptionsSetMaxCumulatedMemAlloc(options.get(), 16 * 1024 * 1024);
    const auto ignoreDiagnostic = [](TIFF*, void*, const char*, const char*, va_list) { return 1; };
    TIFFOpenOptionsSetErrorHandlerExtR(options.get(), ignoreDiagnostic, nullptr);
    TIFFOpenOptionsSetWarningHandlerExtR(options.get(), ignoreDiagnostic, nullptr);
    std::unique_ptr<TIFF, decltype(&TIFFClose)> tiff(
        TIFFOpenExt(path, "rm", options.get()), TIFFClose);
    return tiff && tiffDirectoryHasNoPageMarker(tiff.get()) && TIFFReadDirectory(tiff.get()) &&
        TIFFLastDirectory(tiff.get()) && tiffDirectoryHasNoPageMarker(tiff.get());
}

bool hasSigmaTIFFPreview(const char* path, CGImageSourceRef source, CFDictionaryRef properties,
                        int64_t width, int64_t height) {
    // Sigma Photo Pro writes its 160-pixel thumbnail as a second IFD without
    // the TIFF reduced-resolution flag. Check both writer and preview geometry
    // before treating the second IFD as anything other than a separate page.
    if (CGImageSourceGetCount(source) != 2) return false;
    const auto tiff = static_cast<CFDictionaryRef>(
        CFDictionaryGetValue(properties, kCGImagePropertyTIFFDictionary));
    if (!tiff || CFGetTypeID(tiff) != CFDictionaryGetTypeID()) return false;
    const auto writer = static_cast<CFStringRef>(CFDictionaryGetValue(tiff, kCGImagePropertyTIFFSoftware));
    if (!writer || CFGetTypeID(writer) != CFStringGetTypeID() ||
        !CFStringHasPrefix(writer, CFSTR("SIGMA Photo Pro "))) return false;
    CFUnique<CFDictionaryRef> preview(CGImageSourceCopyPropertiesAtIndex(source, 1, nullptr));
    int64_t previewWidth = 0, previewHeight = 0, previewDepth = 0;
    return numberValue(preview.get(), kCGImagePropertyPixelWidth, &previewWidth) &&
        numberValue(preview.get(), kCGImagePropertyPixelHeight, &previewHeight) &&
        numberValue(preview.get(), kCGImagePropertyDepth, &previewDepth) && previewDepth == 8 &&
        previewWidth > 0 && previewHeight > 0 && previewWidth < width && previewHeight < height &&
        std::max(previewWidth, previewHeight) == 160 &&
        std::abs(width * previewHeight - height * previewWidth) <= std::max(width, height) &&
        hasUnpaginatedTIFFPair(path);
}

CGAffineTransform displayOrientation(int64_t orientation, CGFloat width, CGFloat height) {
    // Convert the top-left EXIF mapping to Core Graphics' bottom-left origin.
    switch (orientation) {
        case 2: return CGAffineTransformMake(-1, 0, 0, 1, width, 0);
        case 3: return CGAffineTransformMake(-1, 0, 0, -1, width, height);
        case 4: return CGAffineTransformMake(1, 0, 0, -1, 0, height);
        case 5: return CGAffineTransformMake(0, -1, -1, 0, height, width);
        case 6: return CGAffineTransformMake(0, -1, 1, 0, 0, width);
        case 7: return CGAffineTransformMake(0, 1, 1, 0, 0, 0);
        case 8: return CGAffineTransformMake(0, 1, -1, 0, height, 0);
        default: return CGAffineTransformIdentity;
    }
}

sony2fuji::RenderStatus loadDisplayImageApple(const char* path, sony2fuji::OwnedPixelBuffer& output) {
    output.reset();
    if (!path || path[0] == '\0') return sony2fuji::RenderStatus::InvalidArgument;
    if (isDNGPath(path)) return sony2fuji::RenderStatus::Unsupported;
    if (!regularFile(path)) return sony2fuji::RenderStatus::IoError;

    CFUnique<CFURLRef> url(CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(path), std::strlen(path), false));
    if (!url) return sony2fuji::RenderStatus::IoError;

    CFUnique<CGImageSourceRef> source(CGImageSourceCreateWithURL(url.get(), nullptr));
    if (!source) return sony2fuji::RenderStatus::ProcessingError;
    const CFStringRef type = CGImageSourceGetType(source.get());
    if (!supportedUTI(type)) return sony2fuji::RenderStatus::Unsupported;
    CFStringRef pngColorSpaceName = nullptr;
    if (equalUTI(type, CFSTR("public.png"))) {
        const auto status = pngColorMetadataStatus(path, &pngColorSpaceName);
        if (status != sony2fuji::RenderStatus::Ok) return status;
    }
    const size_t imageCount = CGImageSourceGetCount(source.get());
    const bool tiffPair = imageCount == 2 && equalUTI(type, CFSTR("public.tiff"));
    const int mpfCount = equalUTI(type, CFSTR("public.jpeg")) ?
        sony2fuji::inspectSdrJpegMpf(std::filesystem::u8path(path)) : 0;
    if (mpfCount < 0 || (imageCount != 1 && !tiffPair &&
        (mpfCount == 0 || imageCount != static_cast<size_t>(mpfCount))))
        return sony2fuji::RenderStatus::Unsupported;

    // A gain map turns an otherwise ordinary 8-bit base image into an HDR asset.
    // This adapter promises opaque SDR pixels, so reject it before ImageIO can
    // hand us only the SDR base image.
    if (hasHDRGainMap(source.get())) return sony2fuji::RenderStatus::Unsupported;

    CFUnique<CFDictionaryRef> properties(CGImageSourceCopyPropertiesAtIndex(source.get(), 0, nullptr));
    if (!properties) return sony2fuji::RenderStatus::ProcessingError;

    int64_t width = 0, height = 0;
    if (!numberValue(properties.get(), kCGImagePropertyPixelWidth, &width) ||
        !numberValue(properties.get(), kCGImagePropertyPixelHeight, &height) ||
        width <= 0 || height <= 0) {
        return sony2fuji::RenderStatus::ProcessingError;
    }
    if (static_cast<uint64_t>(width) > kMaxDisplayPixels / static_cast<uint64_t>(height))
        return sony2fuji::RenderStatus::Unsupported;
    const uint64_t pixels = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
    if (pixels > kMaxDisplayPixels || width > std::numeric_limits<uint32_t>::max() / 4)
        return sony2fuji::RenderStatus::Unsupported;

    int64_t depth = 8;
    numberValue(properties.get(), kCGImagePropertyDepth, &depth);
    const bool tiff16 = depth == 16 && equalUTI(type, CFSTR("public.tiff"));
    const bool rgb16 = tiff16 || (depth == 16 && equalUTI(type, CFSTR("public.png")));
    if (depth != 8 && !rgb16) return sony2fuji::RenderStatus::Unsupported;
    if (tiffPair && (!tiff16 || !hasSigmaTIFFPreview(path, source.get(), properties.get(), width, height)))
        return sony2fuji::RenderStatus::Unsupported;

    int64_t orientation = 1;
    if (numberValue(properties.get(), kCGImagePropertyOrientation, &orientation) &&
        (orientation < 1 || orientation > 8)) {
        return sony2fuji::RenderStatus::Unsupported;
    }

    const void* decodeKeys[] = {kCGImageSourceShouldCacheImmediately};
    const void* decodeValues[] = {kCFBooleanTrue};
    CFUnique<CFDictionaryRef> decodeOptions(CFDictionaryCreate(
        kCFAllocatorDefault, decodeKeys, decodeValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    if (!decodeOptions) return sony2fuji::RenderStatus::OutOfMemory;
    CFUnique<CGImageRef> decoded(CGImageSourceCreateImageAtIndex(source.get(), 0, decodeOptions.get()));
    if (!decoded) return sony2fuji::RenderStatus::ProcessingError;
    const CGColorSpaceRef decodedSpace = CGImageGetColorSpace(decoded.get());
    if (!decodedSpace || CGColorSpaceGetModel(decodedSpace) != kCGColorSpaceModelRGB)
        return sony2fuji::RenderStatus::Unsupported;
    const bool hasProfile = CFDictionaryGetValue(properties.get(), kCGImagePropertyProfileName) != nullptr;
    const size_t bits = rgb16 ? 16 : 8;
    if (isHDRColorSpace(decodedSpace) || CGImageGetBitsPerComponent(decoded.get()) != bits ||
        (CGImageGetBitmapInfo(decoded.get()) & kCGBitmapFloatComponents) != 0)
        return sony2fuji::RenderStatus::Unsupported;

    // 16 位输入直接使用原始解码；ImageIO 缩略图路径不保证保留分量精度。
    CFUnique<CGImageRef> image = std::move(decoded);
    if (!rgb16) {
        image.reset();
        const int maxPixelSize = static_cast<int>(std::max(width, height));
        CFUnique<CFNumberRef> maxSize(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxPixelSize));
        if (!maxSize) return sony2fuji::RenderStatus::OutOfMemory;
        const void* keys[] = {
            kCGImageSourceCreateThumbnailFromImageAlways,
            kCGImageSourceCreateThumbnailWithTransform,
            kCGImageSourceThumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately
        };
        const void* values[] = {kCFBooleanTrue, kCFBooleanTrue, maxSize.get(), kCFBooleanTrue};
        CFUnique<CFDictionaryRef> options(CFDictionaryCreate(
            kCFAllocatorDefault, keys, values, 4,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
        if (!options) return sony2fuji::RenderStatus::OutOfMemory;
        image.reset(CGImageSourceCreateThumbnailAtIndex(source.get(), 0, options.get()));
    }
    if (!image) return sony2fuji::RenderStatus::ProcessingError;
    if (CGImageGetBitsPerComponent(image.get()) != bits ||
        (CGImageGetBitmapInfo(image.get()) & kCGBitmapFloatComponents) != 0) {
        return sony2fuji::RenderStatus::Unsupported;
    }

    CGColorSpaceRef sourceSpace = CGImageGetColorSpace(image.get());
    if (!sourceSpace || CGColorSpaceGetModel(sourceSpace) != kCGColorSpaceModelRGB)
        return sony2fuji::RenderStatus::Unsupported;
    if (pngColorSpaceName) {
        // 旧版 ImageIO 若忽略 cICP，不能把非 sRGB 像素误当作 sRGB 接受。
        CFUnique<CGColorSpaceRef> expected(CGColorSpaceCreateWithName(pngColorSpaceName));
        if (!expected || !CFEqual(sourceSpace, expected.get())) return sony2fuji::RenderStatus::Unsupported;
    }
    if (isHDRColorSpace(sourceSpace)) return sony2fuji::RenderStatus::Unsupported;

    if (!hasProfile && !pngColorSpaceName) {
        CFUnique<CGColorSpaceRef> sRGB(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        if (!sRGB) return sony2fuji::RenderStatus::ProcessingError;
        CFUnique<CGImageRef> retagged(CGImageCreateCopyWithColorSpace(image.get(), sRGB.get()));
        if (!retagged) return sony2fuji::RenderStatus::ProcessingError;
        image = std::move(retagged);
    }

    const size_t imageWidth = CGImageGetWidth(image.get());
    const size_t imageHeight = CGImageGetHeight(image.get());
    const bool swapAxes = rgb16 && orientation >= 5;
    const size_t outputWidth = swapAxes ? imageHeight : imageWidth;
    const size_t outputHeight = swapAxes ? imageWidth : imageHeight;
    const size_t pixelBytes = rgb16 ? 8 : 4;
    if (outputWidth == 0 || outputHeight == 0 || outputWidth > UINT32_MAX / pixelBytes ||
        static_cast<uint64_t>(outputWidth) > kMaxDisplayPixels / outputHeight)
        return sony2fuji::RenderStatus::Unsupported;
    const size_t stride = outputWidth * pixelBytes;
    if (outputHeight > std::numeric_limits<size_t>::max() / stride)
        return sony2fuji::RenderStatus::Unsupported;
    const size_t total = stride * outputHeight;
    std::unique_ptr<void, decltype(&std::free)> pixelsData(std::malloc(total), &std::free);
    if (!pixelsData) return sony2fuji::RenderStatus::OutOfMemory;

    CFUnique<CGColorSpaceRef> sRGB(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    if (!sRGB) return sony2fuji::RenderStatus::ProcessingError;
    const CGBitmapInfo bitmapInfo = CGBitmapInfo(kCGImageAlphaPremultipliedLast) |
        CGBitmapInfo(rgb16 ? kCGBitmapByteOrder16Little : kCGBitmapByteOrder32Big);
    CFUnique<CGContextRef> context(CGBitmapContextCreate(
        pixelsData.get(), outputWidth, outputHeight, bits, stride, sRGB.get(), bitmapInfo));
    if (!context) return sony2fuji::RenderStatus::ProcessingError;
    if (rgb16 && orientation != 1) {
        CGContextSetInterpolationQuality(context.get(), kCGInterpolationNone);
        CGContextConcatCTM(context.get(), displayOrientation(orientation, imageWidth, imageHeight));
    }
    const bool checkAlpha = hasAlpha(CGImageGetAlphaInfo(image.get()));
    CGContextSetBlendMode(context.get(), kCGBlendModeCopy);
    CGContextDrawImage(context.get(), CGRectMake(0, 0, imageWidth, imageHeight), image.get());
    context.reset();
    image.reset();

    const auto* bytes = static_cast<const uint8_t*>(pixelsData.get());
    if (checkAlpha) {
        for (size_t offset = pixelBytes - 1; offset < total; offset += pixelBytes) {
            if (bytes[offset] != 255 || (rgb16 && bytes[offset - 1] != 255))
                return sony2fuji::RenderStatus::Unsupported;
        }
    }

    output.data = pixelsData.release();
    output.sizeBytes = total;
    output.width = static_cast<uint32_t>(outputWidth);
    output.height = static_cast<uint32_t>(outputHeight);
    output.strideBytes = static_cast<uint32_t>(stride);
    output.format = rgb16 ? sony2fuji::PixelBufferFormat::RGBA16 : sony2fuji::PixelBufferFormat::RGBA8;
    return sony2fuji::RenderStatus::Ok;
}

#endif

} // namespace

namespace sony2fuji {

RenderStatus loadDisplayImage(const char* path, OwnedPixelBuffer& output) {
#if defined(__APPLE__)
    try {
        return loadDisplayImageApple(path, output);
    } catch (const std::bad_alloc&) {
        output.reset();
        return RenderStatus::OutOfMemory;
    } catch (...) {
        output.reset();
        return RenderStatus::ProcessingError;
    }
#else
    output.reset();
    (void)path;
    return RenderStatus::Unsupported;
#endif
}

RenderStatus loadDisplayPreview(const char* path,
                                uint32_t edge,
                                OwnedPixelBuffer& output,
                                uint32_t* orientedSourceWidth,
                                uint32_t* orientedSourceHeight) {
    if (orientedSourceWidth) *orientedSourceWidth = 0;
    if (orientedSourceHeight) *orientedSourceHeight = 0;
    output.reset();
    (void)path;
    (void)edge;
    return RenderStatus::Unsupported;
}

} // namespace sony2fuji
