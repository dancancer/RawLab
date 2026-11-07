#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
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

void clearBuffer(sony2fuji_buffer* buffer) {
    if (!buffer) return;
    sony2fuji_release_buffer(buffer);
    *buffer = {};
    buffer->pixel_format = SONY2FUJI_PIXEL_RGB8;
}

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
    CFUnique<CFStringRef> name(CGColorSpaceCopyName(colorSpace));
    return stringContains(name.get(), CFSTR("extended")) ||
        stringContains(name.get(), CFSTR("hdr")) ||
        stringContains(name.get(), CFSTR("pq")) ||
        stringContains(name.get(), CFSTR("hlg"));
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

sony2fuji_status loadDisplayImageApple(const char* path, sony2fuji_buffer* output) {
    if (!output) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    clearBuffer(output);
    if (!path || path[0] == '\0') return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (isDNGPath(path)) return SONY2FUJI_STATUS_UNSUPPORTED;
    if (!regularFile(path)) return SONY2FUJI_STATUS_IO_ERROR;

    CFUnique<CFURLRef> url(CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(path), std::strlen(path), false));
    if (!url) return SONY2FUJI_STATUS_IO_ERROR;

    CFUnique<CGImageSourceRef> source(CGImageSourceCreateWithURL(url.get(), nullptr));
    if (!source) return SONY2FUJI_STATUS_PROCESSING_ERROR;
    const CFStringRef type = CGImageSourceGetType(source.get());
    if (!supportedUTI(type)) return SONY2FUJI_STATUS_UNSUPPORTED;
    const size_t imageCount = CGImageSourceGetCount(source.get());
    if (imageCount != 1 && !(imageCount == 2 && equalUTI(type, CFSTR("public.tiff"))))
        return SONY2FUJI_STATUS_UNSUPPORTED;

    // A gain map turns an otherwise ordinary 8-bit base image into an HDR asset.
    // This adapter promises opaque SDR pixels, so reject it before ImageIO can
    // hand us only the SDR base image.
    if (hasHDRGainMap(source.get())) return SONY2FUJI_STATUS_UNSUPPORTED;

    CFUnique<CFDictionaryRef> properties(CGImageSourceCopyPropertiesAtIndex(source.get(), 0, nullptr));
    if (!properties) return SONY2FUJI_STATUS_PROCESSING_ERROR;

    int64_t width = 0, height = 0;
    if (!numberValue(properties.get(), kCGImagePropertyPixelWidth, &width) ||
        !numberValue(properties.get(), kCGImagePropertyPixelHeight, &height) ||
        width <= 0 || height <= 0) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
    if (static_cast<uint64_t>(width) > kMaxDisplayPixels / static_cast<uint64_t>(height))
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const uint64_t pixels = static_cast<uint64_t>(width) * static_cast<uint64_t>(height);
    if (pixels > kMaxDisplayPixels || width > std::numeric_limits<uint32_t>::max() / 4)
        return SONY2FUJI_STATUS_UNSUPPORTED;

    int64_t depth = 8;
    numberValue(properties.get(), kCGImagePropertyDepth, &depth);
    const bool tiff16 = depth == 16 && equalUTI(type, CFSTR("public.tiff"));
    const bool rgb16 = tiff16 || (depth == 16 && equalUTI(type, CFSTR("public.png")));
    if (depth != 8 && !rgb16) return SONY2FUJI_STATUS_UNSUPPORTED;
    if (imageCount == 2 && (!tiff16 || !hasSigmaTIFFPreview(path, source.get(), properties.get(), width, height)))
        return SONY2FUJI_STATUS_UNSUPPORTED;

    int64_t orientation = 1;
    if (numberValue(properties.get(), kCGImagePropertyOrientation, &orientation) &&
        (orientation < 1 || orientation > 8)) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    const void* decodeKeys[] = {kCGImageSourceShouldCacheImmediately};
    const void* decodeValues[] = {kCFBooleanTrue};
    CFUnique<CFDictionaryRef> decodeOptions(CFDictionaryCreate(
        kCFAllocatorDefault, decodeKeys, decodeValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    if (!decodeOptions) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    CFUnique<CGImageRef> decoded(CGImageSourceCreateImageAtIndex(source.get(), 0, decodeOptions.get()));
    if (!decoded) return SONY2FUJI_STATUS_PROCESSING_ERROR;
    const CGColorSpaceRef decodedSpace = CGImageGetColorSpace(decoded.get());
    if (!decodedSpace || CGColorSpaceGetModel(decodedSpace) != kCGColorSpaceModelRGB)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const bool hasProfile = CFDictionaryGetValue(properties.get(), kCGImagePropertyProfileName) != nullptr;
    const size_t bits = rgb16 ? 16 : 8;
    if (isHDRColorSpace(decodedSpace) || CGImageGetBitsPerComponent(decoded.get()) != bits ||
        (CGImageGetBitmapInfo(decoded.get()) & kCGBitmapFloatComponents) != 0)
        return SONY2FUJI_STATUS_UNSUPPORTED;

    // 16 位输入直接使用原始解码；ImageIO 缩略图路径不保证保留分量精度。
    CFUnique<CGImageRef> image = std::move(decoded);
    if (!rgb16) {
        image.reset();
        const int maxPixelSize = static_cast<int>(std::max(width, height));
        CFUnique<CFNumberRef> maxSize(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &maxPixelSize));
        if (!maxSize) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
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
        if (!options) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        image.reset(CGImageSourceCreateThumbnailAtIndex(source.get(), 0, options.get()));
    }
    if (!image) return SONY2FUJI_STATUS_PROCESSING_ERROR;
    if (CGImageGetBitsPerComponent(image.get()) != bits ||
        (CGImageGetBitmapInfo(image.get()) & kCGBitmapFloatComponents) != 0) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }

    CGColorSpaceRef sourceSpace = CGImageGetColorSpace(image.get());
    if (!sourceSpace || CGColorSpaceGetModel(sourceSpace) != kCGColorSpaceModelRGB)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    if (isHDRColorSpace(sourceSpace)) return SONY2FUJI_STATUS_UNSUPPORTED;

    if (!hasProfile) {
        CFUnique<CGColorSpaceRef> sRGB(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        if (!sRGB) return SONY2FUJI_STATUS_PROCESSING_ERROR;
        CFUnique<CGImageRef> retagged(CGImageCreateCopyWithColorSpace(image.get(), sRGB.get()));
        if (!retagged) return SONY2FUJI_STATUS_PROCESSING_ERROR;
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
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const size_t stride = outputWidth * pixelBytes;
    if (outputHeight > std::numeric_limits<size_t>::max() / stride)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const size_t total = stride * outputHeight;
    std::unique_ptr<void, decltype(&std::free)> pixelsData(std::malloc(total), &std::free);
    if (!pixelsData) return SONY2FUJI_STATUS_OUT_OF_MEMORY;

    CFUnique<CGColorSpaceRef> sRGB(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    if (!sRGB) return SONY2FUJI_STATUS_PROCESSING_ERROR;
    const CGBitmapInfo bitmapInfo = CGBitmapInfo(kCGImageAlphaPremultipliedLast) |
        CGBitmapInfo(rgb16 ? kCGBitmapByteOrder16Little : kCGBitmapByteOrder32Big);
    CFUnique<CGContextRef> context(CGBitmapContextCreate(
        pixelsData.get(), outputWidth, outputHeight, bits, stride, sRGB.get(), bitmapInfo));
    if (!context) return SONY2FUJI_STATUS_PROCESSING_ERROR;
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
                return SONY2FUJI_STATUS_UNSUPPORTED;
        }
    }

    output->data = pixelsData.release();
    output->size_bytes = total;
    output->width = static_cast<uint32_t>(outputWidth);
    output->height = static_cast<uint32_t>(outputHeight);
    output->stride_bytes = static_cast<uint32_t>(stride);
    output->pixel_format = rgb16 ? SONY2FUJI_PIXEL_RGBA16 : SONY2FUJI_PIXEL_RGBA8;
    return SONY2FUJI_STATUS_OK;
}

#endif

} // namespace

extern "C" sony2fuji_status sony2fuji_load_display_image(
    const char* path, sony2fuji_buffer* out_buffer) {
#if defined(__APPLE__)
    try {
        return loadDisplayImageApple(path, out_buffer);
    } catch (const std::bad_alloc&) {
        if (out_buffer) clearBuffer(out_buffer);
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        if (out_buffer) clearBuffer(out_buffer);
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
#else
    if (!out_buffer) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    clearBuffer(out_buffer);
    (void)path;
    return SONY2FUJI_STATUS_UNSUPPORTED;
#endif
}
