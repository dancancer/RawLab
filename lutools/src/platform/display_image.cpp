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
    if (CGImageSourceGetCount(source.get()) != 1) return SONY2FUJI_STATUS_UNSUPPORTED;

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

    int64_t depth = 0;
    if (numberValue(properties.get(), kCGImagePropertyDepth, &depth) && depth != 8)
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
    if (isHDRColorSpace(decodedSpace) || CGImageGetBitsPerComponent(decoded.get()) != 8 ||
        (CGImageGetBitmapInfo(decoded.get()) & kCGBitmapFloatComponents) != 0)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    decoded.reset();

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

    CFUnique<CGImageRef> image(CGImageSourceCreateThumbnailAtIndex(source.get(), 0, options.get()));
    if (!image) return SONY2FUJI_STATUS_PROCESSING_ERROR;
    if (CGImageGetBitsPerComponent(image.get()) != 8 ||
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

    const size_t outputWidth = CGImageGetWidth(image.get());
    const size_t outputHeight = CGImageGetHeight(image.get());
    if (outputWidth == 0 || outputHeight == 0 || outputWidth > UINT32_MAX / 4 ||
        static_cast<uint64_t>(outputWidth) > kMaxDisplayPixels / outputHeight)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const size_t stride = outputWidth * 4;
    if (outputHeight > std::numeric_limits<size_t>::max() / stride)
        return SONY2FUJI_STATUS_UNSUPPORTED;
    const size_t total = stride * outputHeight;
    void* pixelsData = std::malloc(total);
    if (!pixelsData) return SONY2FUJI_STATUS_OUT_OF_MEMORY;

    CFUnique<CGColorSpaceRef> sRGB(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    if (!sRGB) {
        std::free(pixelsData);
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
    const CGBitmapInfo bitmapInfo = CGBitmapInfo(kCGImageAlphaPremultipliedLast) |
        CGBitmapInfo(kCGBitmapByteOrder32Big);
    CFUnique<CGContextRef> context(CGBitmapContextCreate(
        pixelsData, outputWidth, outputHeight, 8, stride, sRGB.get(), bitmapInfo));
    if (!context) {
        std::free(pixelsData);
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
    const bool checkAlpha = hasAlpha(CGImageGetAlphaInfo(image.get()));
    CGContextSetBlendMode(context.get(), kCGBlendModeCopy);
    CGContextDrawImage(context.get(), CGRectMake(0, 0, outputWidth, outputHeight), image.get());
    context.reset();
    image.reset();

    const auto* bytes = static_cast<const uint8_t*>(pixelsData);
    if (checkAlpha) {
        for (size_t offset = 3; offset < total; offset += 4) {
            if (bytes[offset] != 255) {
                std::free(pixelsData);
                return SONY2FUJI_STATUS_UNSUPPORTED;
            }
        }
    }

    output->data = pixelsData;
    output->size_bytes = total;
    output->width = static_cast<uint32_t>(outputWidth);
    output->height = static_cast<uint32_t>(outputHeight);
    output->stride_bytes = static_cast<uint32_t>(stride);
    output->pixel_format = SONY2FUJI_PIXEL_RGBA8;
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
