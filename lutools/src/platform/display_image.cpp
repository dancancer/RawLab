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

bool hasSigmaTIFFPreview(CGImageSourceRef source, CFDictionaryRef properties,
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
        std::abs(width * previewHeight - height * previewWidth) <= std::max(width, height);
}

CGAffineTransform tiffOrientation(int64_t orientation, CGFloat width, CGFloat height) {
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
    if (depth != 8 && !tiff16) return SONY2FUJI_STATUS_UNSUPPORTED;
    if (imageCount == 2 && (!tiff16 || !hasSigmaTIFFPreview(source.get(), properties.get(), width, height)))
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
    const size_t bits = tiff16 ? 16 : 8;
    if (isHDRColorSpace(decodedSpace) || CGImageGetBitsPerComponent(decoded.get()) != bits ||
        (CGImageGetBitmapInfo(decoded.get()) & kCGBitmapFloatComponents) != 0)
        return SONY2FUJI_STATUS_UNSUPPORTED;

    // Use the original decode for TIFF16. ImageIO's orientation/thumbnail
    // path does not guarantee retention of the original component depth.
    CFUnique<CGImageRef> image = std::move(decoded);
    if (!tiff16) {
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
    const bool swapAxes = tiff16 && orientation >= 5;
    const size_t outputWidth = swapAxes ? imageHeight : imageWidth;
    const size_t outputHeight = swapAxes ? imageWidth : imageHeight;
    const size_t pixelBytes = tiff16 ? 8 : 4;
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
        CGBitmapInfo(tiff16 ? kCGBitmapByteOrder16Little : kCGBitmapByteOrder32Big);
    CFUnique<CGContextRef> context(CGBitmapContextCreate(
        pixelsData.get(), outputWidth, outputHeight, bits, stride, sRGB.get(), bitmapInfo));
    if (!context) return SONY2FUJI_STATUS_PROCESSING_ERROR;
    if (tiff16 && orientation != 1) {
        CGContextSetInterpolationQuality(context.get(), kCGInterpolationNone);
        CGContextConcatCTM(context.get(), tiffOrientation(orientation, imageWidth, imageHeight));
    }
    const bool checkAlpha = hasAlpha(CGImageGetAlphaInfo(image.get()));
    CGContextSetBlendMode(context.get(), kCGBlendModeCopy);
    CGContextDrawImage(context.get(), CGRectMake(0, 0, imageWidth, imageHeight), image.get());
    context.reset();
    image.reset();

    const auto* bytes = static_cast<const uint8_t*>(pixelsData.get());
    if (checkAlpha) {
        for (size_t offset = pixelBytes - 1; offset < total; offset += pixelBytes) {
            if (bytes[offset] != 255 || (tiff16 && bytes[offset - 1] != 255))
                return SONY2FUJI_STATUS_UNSUPPORTED;
        }
    }

    output->data = pixelsData.release();
    output->size_bytes = total;
    output->width = static_cast<uint32_t>(outputWidth);
    output->height = static_cast<uint32_t>(outputHeight);
    output->stride_bytes = static_cast<uint32_t>(stride);
    output->pixel_format = tiff16 ? SONY2FUJI_PIXEL_RGBA16 : SONY2FUJI_PIXEL_RGBA8;
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
