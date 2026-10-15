#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <utility>
#include <vector>
#if defined(__APPLE__)
#include <unistd.h>
#endif

extern "C" sony2fuji_status sony2fuji_load_display_image(
    const char* path, sony2fuji_buffer* out_buffer);

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#endif

namespace {

int failures = 0;

void check(bool condition, const std::string& message) {
    std::cout << (condition ? "PASS " : "FAIL ") << message << '\n';
    if (!condition) ++failures;
}

#if defined(__APPLE__)

struct FixtureImage {
    CGImageRef image = nullptr;
    std::vector<uint8_t> bytes;

    FixtureImage() = default;
    FixtureImage(const FixtureImage&) = delete;
    FixtureImage& operator=(const FixtureImage&) = delete;
    FixtureImage(FixtureImage&& other) noexcept : image(other.image), bytes(std::move(other.bytes)) {
        other.image = nullptr;
    }
    FixtureImage& operator=(FixtureImage&& other) noexcept {
        if (this == &other) return *this;
        if (image) CGImageRelease(image);
        image = other.image;
        bytes = std::move(other.bytes);
        other.image = nullptr;
        return *this;
    }

    ~FixtureImage() {
        if (image) CGImageRelease(image);
    }
};

FixtureImage rgbaImage(size_t width, size_t height, CGColorSpaceRef colorSpace,
                       const std::vector<uint8_t>& bytes) {
    FixtureImage result;
    result.bytes = bytes;
    auto* provider = CGDataProviderCreateWithData(nullptr, result.bytes.data(), result.bytes.size(), nullptr);
    if (!provider) return result;
    result.image = CGImageCreate(
        width, height, 8, 32, width * 4, colorSpace,
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) |
            static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big),
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return result;
}

FixtureImage rgbImage(size_t width, size_t height, CGColorSpaceRef colorSpace,
                      const std::vector<uint8_t>& bytes) {
    FixtureImage result;
    result.bytes = bytes;
    auto* provider = CGDataProviderCreateWithData(nullptr, result.bytes.data(), result.bytes.size(), nullptr);
    if (!provider) return result;
    result.image = CGImageCreate(
        width, height, 8, 24, width * 3, colorSpace, static_cast<CGBitmapInfo>(kCGImageAlphaNone),
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return result;
}

FixtureImage grayImage(size_t width, size_t height, CGColorSpaceRef colorSpace,
                       const std::vector<uint8_t>& bytes) {
    FixtureImage result;
    result.bytes = bytes;
    auto* provider = CGDataProviderCreateWithData(nullptr, result.bytes.data(), result.bytes.size(), nullptr);
    if (!provider) return result;
    result.image = CGImageCreate(
        width, height, 8, 8, width, colorSpace, static_cast<CGBitmapInfo>(kCGImageAlphaNone),
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return result;
}

FixtureImage rgb16Image(size_t width, size_t height, CGColorSpaceRef colorSpace) {
    FixtureImage result;
    result.bytes.resize(width * height * 6);
    for (size_t index = 0; index < width * height * 3; ++index) {
        const uint16_t value = static_cast<uint16_t>(index * 7919u + 1234u);
        result.bytes[index * 2] = static_cast<uint8_t>(value >> 8);
        result.bytes[index * 2 + 1] = static_cast<uint8_t>(value);
    }
    auto* provider = CGDataProviderCreateWithData(nullptr, result.bytes.data(), result.bytes.size(), nullptr);
    if (!provider) return result;
    result.image = CGImageCreate(
        width, height, 16, 48, width * 6, colorSpace,
        static_cast<CGBitmapInfo>(kCGBitmapByteOrder16Big) | static_cast<CGBitmapInfo>(kCGImageAlphaNone),
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return result;
}

FixtureImage cmykImage(CGColorSpaceRef colorSpace) {
    FixtureImage result;
    result.bytes = {0, 32, 64, 16};
    auto* provider = CGDataProviderCreateWithData(nullptr, result.bytes.data(), result.bytes.size(), nullptr);
    if (!provider) return result;
    result.image = CGImageCreate(
        1, 1, 8, 32, 4, colorSpace, static_cast<CGBitmapInfo>(kCGImageAlphaNone),
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return result;
}

bool writeImage(const std::filesystem::path& path, CFStringRef type, CGImageRef image,
                CFDictionaryRef properties = nullptr, size_t frameCount = 1) {
    const auto pathString = path.u8string();
    auto* url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(pathString.data()), pathString.size(), false);
    if (!url) return false;
    auto* destination = CGImageDestinationCreateWithURL(
        url, type, frameCount, nullptr);
    CFRelease(url);
    if (!destination) return false;
    for (size_t index = 0; index < frameCount; ++index)
        CGImageDestinationAddImage(destination, image, properties);
    const bool finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return finalized;
}

bool stripPngColorProfile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) return false;
    const std::vector<uint8_t> source((std::istreambuf_iterator<char>(input)),
        std::istreambuf_iterator<char>());
    static constexpr uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (source.size() < sizeof(signature) ||
        !std::equal(std::begin(signature), std::end(signature), source.begin())) {
        return false;
    }

    std::vector<uint8_t> stripped(source.begin(), source.begin() + sizeof(signature));
    size_t offset = sizeof(signature);
    bool foundEnd = false;
    while (offset + 12 <= source.size()) {
        const uint32_t length = (static_cast<uint32_t>(source[offset]) << 24) |
            (static_cast<uint32_t>(source[offset + 1]) << 16) |
            (static_cast<uint32_t>(source[offset + 2]) << 8) |
            static_cast<uint32_t>(source[offset + 3]);
        if (length > source.size() - offset - 12) return false;
        const size_t chunkSize = static_cast<size_t>(length) + 12;
        const char* type = reinterpret_cast<const char*>(source.data() + offset + 4);
        const bool colorProfile = std::memcmp(type, "iCCP", 4) == 0 ||
            std::memcmp(type, "sRGB", 4) == 0 || std::memcmp(type, "cHRM", 4) == 0 ||
            std::memcmp(type, "gAMA", 4) == 0;
        if (!colorProfile)
            stripped.insert(stripped.end(), source.begin() + offset, source.begin() + offset + chunkSize);
        if (std::memcmp(type, "IEND", 4) == 0) {
            foundEnd = true;
            break;
        }
        offset += chunkSize;
    }
    if (!foundEnd) return false;
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output.write(reinterpret_cast<const char*>(stripped.data()), static_cast<std::streamsize>(stripped.size()));
    return output.good();
}

CFDictionaryRef orientationProperties(uint32_t orientation) {
    auto* number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &orientation);
    if (!number) return nullptr;
    const void* keys[] = {kCGImagePropertyOrientation};
    const void* values[] = {number};
    auto* dictionary = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    return dictionary;
}

std::vector<uint8_t> drawSRGB(CGImageRef image) {
    const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    std::vector<uint8_t> bytes(width * height * 4);
    auto* space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    auto* context = CGBitmapContextCreate(
        bytes.data(), width, height, 8, width * 4, space,
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) |
            static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Big));
    if (context) {
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(space);
    return bytes;
}

std::vector<uint8_t> outputBytes(const sony2fuji_buffer& buffer) {
    if (!buffer.data) return {};
    const auto* bytes = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(buffer.size_bytes);
    std::copy(bytes, bytes + buffer.size_bytes, result.begin());
    return result;
}

void expectUnsupported(const std::filesystem::path& path, const std::string& label) {
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
    check(status == SONY2FUJI_STATUS_UNSUPPORTED || status == SONY2FUJI_STATUS_PROCESSING_ERROR,
          label + " is rejected");
    check(!buffer.data && buffer.size_bytes == 0 && buffer.width == 0 && buffer.height == 0,
          label + " clears output on rejection");
    sony2fuji_release_buffer(&buffer);
}

void expectEmptyPathClearsBuffer() {
    sony2fuji_buffer buffer{
        std::malloc(4), 4, 1, 1, 4, SONY2FUJI_PIXEL_RGBA8
    };
    const auto status = sony2fuji_load_display_image("", &buffer);
    check(status == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "Empty display-image path is an invalid argument");
    check(!buffer.data && buffer.size_bytes == 0 && buffer.width == 0 && buffer.height == 0 &&
        buffer.stride_bytes == 0 && buffer.pixel_format == SONY2FUJI_PIXEL_RGB8,
        "Empty display-image path clears an existing output buffer");
    sony2fuji_release_buffer(&buffer);
}

void runMacTests() {
    const auto root = std::filesystem::temp_directory_path() /
        ("rawlab-display-image-" + std::to_string(getpid()));
    std::filesystem::create_directories(root);
    struct Cleanup { std::filesystem::path path; ~Cleanup() { std::error_code error; std::filesystem::remove_all(path, error); } } cleanup{root};

    auto* sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    const std::vector<uint8_t> pattern = {
        255, 0, 0, 255, 0, 255, 0, 255,
        0, 0, 255, 255, 255, 255, 255, 255,
        32, 64, 96, 255, 160, 128, 96, 255
    };
    auto fixture = rgbaImage(2, 3, sRGB, pattern);
    std::vector<uint8_t> rgbPattern;
    rgbPattern.reserve(2 * 3 * 3);
    for (size_t index = 0; index < pattern.size(); index += 4)
        rgbPattern.insert(rgbPattern.end(), pattern.begin() + index, pattern.begin() + index + 3);
    auto jpegFixture = rgbImage(2, 3, sRGB, rgbPattern);
    const auto properties = orientationProperties(6);
    const auto jpeg = root / "oriented.jpg";
    const auto png = root / "oriented.png";
    check(jpegFixture.image && properties && writeImage(jpeg, CFSTR("public.jpeg"), jpegFixture.image, properties),
          "Generate oriented JPEG fixture");
    check(fixture.image && properties && writeImage(png, CFSTR("public.png"), fixture.image, properties),
          "Generate oriented PNG fixture");
    if (properties) CFRelease(properties);

    for (const auto& path : {jpeg, png}) {
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
        check(status == SONY2FUJI_STATUS_OK, path.extension().string() + " decodes as display image");
        if (status == SONY2FUJI_STATUS_OK) {
            check(buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8 && buffer.stride_bytes == buffer.width * 4,
                  path.extension().string() + " is tightly packed RGBA8");
            check(buffer.width == 3 && buffer.height == 2,
                  path.extension().string() + " applies EXIF orientation exactly once");
            const auto bytes = outputBytes(buffer);
            const std::vector<uint8_t> expected = {
                32, 64, 96, 255, 0, 0, 255, 255, 255, 0, 0, 255,
                160, 128, 96, 255, 255, 255, 255, 255, 0, 255, 0, 255
            };
            int maximumError = 0;
            if (bytes.size() == expected.size()) {
                for (size_t index = 0; index < bytes.size(); ++index)
                    maximumError = std::max(maximumError,
                        std::abs(static_cast<int>(bytes[index]) - static_cast<int>(expected[index])));
            }
            if (path.extension() == ".jpg") {
                check(bytes.size() == expected.size(), ".jpg preserves oriented pixel count");
            } else {
                check(bytes.size() == expected.size() && maximumError == 0,
                      path.extension().string() + " preserves oriented pixels");
            }
            bool opaque = bytes.size() == expected.size();
            for (size_t index = 3; opaque && index < bytes.size(); index += 4) opaque = bytes[index] == 255;
            check(opaque,
                  path.extension().string() + " output is opaque");
        }
        sony2fuji_release_buffer(&buffer);
    }

    const auto tiff = root / "photo.tiff";
    check(fixture.image && writeImage(tiff, CFSTR("public.tiff"), fixture.image),
          "Generate TIFF fixture");
    sony2fuji_buffer tiffBuffer{};
    const auto tiffStatus = sony2fuji_load_display_image(tiff.u8string().c_str(), &tiffBuffer);
    check(tiffStatus == SONY2FUJI_STATUS_OK, "TIFF decodes when the system encoder is available");
    sony2fuji_release_buffer(&tiffBuffer);

    const auto heif = root / "photo.heic";
    bool heifWritten = fixture.image && writeImage(heif, CFSTR("public.heic"), fixture.image);
    if (!heifWritten) {
        std::cout << "SKIP HEIF: system encoder unavailable\n";
    } else {
        sony2fuji_buffer heifBuffer{};
        const auto status = sony2fuji_load_display_image(heif.u8string().c_str(), &heifBuffer);
        check(status == SONY2FUJI_STATUS_OK, "HEIF decodes when the system encoder is available");
        sony2fuji_release_buffer(&heifBuffer);
    }

    auto* p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    const std::vector<uint8_t> p3Bytes = {204, 51, 26, 255};
    auto p3Fixture = rgbaImage(1, 1, p3, p3Bytes);
    const auto p3Path = root / "display-p3.png";
    check(p3Fixture.image && writeImage(p3Path, CFSTR("public.png"), p3Fixture.image),
          "Generate Display P3 PNG fixture");
    if (p3Fixture.image) {
        sony2fuji_buffer p3Buffer{};
        const auto status = sony2fuji_load_display_image(p3Path.u8string().c_str(), &p3Buffer);
        const auto expected = drawSRGB(p3Fixture.image);
        const auto actual = outputBytes(p3Buffer);
        check(status == SONY2FUJI_STATUS_OK && actual.size() == expected.size(),
              "Display P3 PNG decodes through the sRGB path");
        if (status == SONY2FUJI_STATUS_OK && actual.size() == expected.size()) {
            bool close = true;
            for (size_t index = 0; index < actual.size(); ++index)
                close = close && std::abs(static_cast<int>(actual[index]) - static_cast<int>(expected[index])) <= 2;
            check(close, "Display P3 conversion matches an independent CGContext sRGB reference");
        }
        sony2fuji_release_buffer(&p3Buffer);
    }
    CGColorSpaceRelease(p3);

    auto* deviceRGB = CGColorSpaceCreateDeviceRGB();
    const std::vector<uint8_t> untaggedBytes = {
        0, 1, 2, 3, 17, 31, 47, 63, 127, 128, 129, 255
    };
    auto untaggedFixture = rgbImage(2, 2, deviceRGB, untaggedBytes);
    const auto untagged = root / "untagged-rgb.png";
    const bool untaggedWritten = untaggedFixture.image &&
        writeImage(untagged, CFSTR("public.png"), untaggedFixture.image) &&
        stripPngColorProfile(untagged);
    check(untaggedWritten, "Generate unprofiled RGB PNG fixture");
    bool untaggedHasProfile = false;
    if (untaggedWritten) {
        const auto pathString = untagged.u8string();
        auto* url = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, reinterpret_cast<const UInt8*>(pathString.data()), pathString.size(), false);
        auto* source = url ? CGImageSourceCreateWithURL(url, nullptr) : nullptr;
        auto* properties = source ? CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr) : nullptr;
        untaggedHasProfile = !properties ||
            CFDictionaryGetValue(properties, kCGImagePropertyProfileName) != nullptr;
        if (properties) CFRelease(properties);
        if (source) CFRelease(source);
        if (url) CFRelease(url);
    }
    if (untaggedWritten) {
        check(!untaggedHasProfile, "Unprofiled RGB PNG has no ImageIO profile property");
    }
    if (untaggedWritten && !untaggedHasProfile) {
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_load_display_image(untagged.u8string().c_str(), &buffer);
        const auto actual = outputBytes(buffer);
        std::vector<uint8_t> expected;
        expected.reserve(untaggedBytes.size() / 3 * 4);
        for (size_t index = 0; index < untaggedBytes.size(); index += 3) {
            expected.insert(expected.end(), untaggedBytes.begin() + index,
                untaggedBytes.begin() + index + 3);
            expected.push_back(255);
        }
        check(status == SONY2FUJI_STATUS_OK && actual == expected,
              "Unprofiled RGB PNG is explicitly sRGB-tagged without changing code values");
        sony2fuji_release_buffer(&buffer);
    }
    CGColorSpaceRelease(deviceRGB);

    auto* deviceGray = CGColorSpaceCreateDeviceGray();
    auto grayFixture = grayImage(2, 1, deviceGray, {32, 224});
    const auto gray = root / "untagged-gray.png";
    const bool grayWritten = grayFixture.image &&
        writeImage(gray, CFSTR("public.png"), grayFixture.image) &&
        stripPngColorProfile(gray);
    check(grayWritten, "Generate unprofiled grayscale PNG fixture");
    if (grayWritten) expectUnsupported(gray, "Unprofiled grayscale PNG");
    CGColorSpaceRelease(deviceGray);

    const auto transparent = root / "transparent.png";
    auto transparentFixture = rgbaImage(1, 1, sRGB, {255, 0, 0, 127});
    check(transparentFixture.image && writeImage(transparent, CFSTR("public.png"), transparentFixture.image),
          "Generate transparent PNG fixture");
    expectUnsupported(transparent, "Transparent PNG");

    auto rgb16 = rgb16Image(2, 1, sRGB);
    const auto sixteen = root / "sixteen.png";
    check(rgb16.image && writeImage(sixteen, CFSTR("public.png"), rgb16.image),
          "Generate 16-bit PNG fixture");
    expectUnsupported(sixteen, "16-bit PNG");

    const auto multipage = root / "multipage.tiff";
    check(fixture.image && writeImage(multipage, CFSTR("public.tiff"), fixture.image, nullptr, 2),
          "Generate multi-page TIFF fixture");
    expectUnsupported(multipage, "Multi-page TIFF");

    const auto dng = root / "not-a-dng.dng";
    check(fixture.image && writeImage(dng, CFSTR("public.tiff"), fixture.image),
          "Generate TIFF bytes with a DNG extension");
    expectUnsupported(dng, "DNG extension");

    auto* cmykSpace = CGColorSpaceCreateDeviceCMYK();
    auto cmykFixture = cmykImage(cmykSpace);
    const auto cmyk = root / "cmyk.tiff";
    check(cmykFixture.image && writeImage(cmyk, CFSTR("public.tiff"), cmykFixture.image),
          "Generate CMYK TIFF fixture");
    expectUnsupported(cmyk, "CMYK TIFF");
    CGColorSpaceRelease(cmykSpace);

    const auto corrupt = root / "corrupt.jpg";
    std::ofstream(corrupt, std::ios::binary) << "not an image";
    expectUnsupported(corrupt, "Corrupt JPEG");

    expectEmptyPathClearsBuffer();

    CGColorSpaceRelease(sRGB);
}

#endif

} // namespace

int main() {
#if defined(__APPLE__)
    runMacTests();
#else
    sony2fuji_buffer output{};
    const auto status = sony2fuji_load_display_image("missing.jpg", &output);
    check(status == SONY2FUJI_STATUS_UNSUPPORTED && output.data == nullptr,
          "Non-Apple display decoder is an explicit unsupported stub");
    sony2fuji_release_buffer(&output);
#endif
    return failures == 0 ? 0 : 1;
}
