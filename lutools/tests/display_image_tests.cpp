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

FixtureImage hdrImage(CGColorSpaceRef colorSpace) {
    FixtureImage result;
    std::vector<float> values(64 * 64 * 4);
    for (size_t index = 0; index < values.size(); ++index)
        values[index] = index % 4 == 3 ? 1.0f : static_cast<float>(index % 64) / 16.0f;
    result.bytes.resize(values.size() * sizeof(float));
    std::memcpy(result.bytes.data(), values.data(), result.bytes.size());
    auto* provider = CGDataProviderCreateWithData(nullptr, result.bytes.data(), result.bytes.size(), nullptr);
    if (!provider) return result;
    result.image = CGImageCreate(64, 64, 32, 128, 64 * 16, colorSpace,
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little,
        provider, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return result;
}

bool writeImage(const std::filesystem::path& path, CFStringRef type, CGImageRef image,
                CFDictionaryRef properties = nullptr, size_t frameCount = 1,
                CGImageRef lastFrame = nullptr) {
    const auto pathString = path.u8string();
    auto* url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(pathString.data()), pathString.size(), false);
    if (!url) return false;
    auto* destination = CGImageDestinationCreateWithURL(
        url, type, frameCount, nullptr);
    CFRelease(url);
    if (!destination) return false;
    for (size_t index = 0; index < frameCount; ++index) {
        if (lastFrame && index == frameCount - 1) CGImageDestinationAddImage(destination, lastFrame, nullptr);
        else CGImageDestinationAddImage(destination, image, properties);
    }
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

std::vector<uint8_t> drawSRGB(CGImageRef image, size_t bits = 8) {
    const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    const size_t pixelBytes = bits == 16 ? 8 : 4;
    std::vector<uint8_t> bytes(width * height * pixelBytes);
    auto* space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    auto* context = CGBitmapContextCreate(
        bytes.data(), width, height, bits, width * pixelBytes, space,
        static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast) |
            static_cast<CGBitmapInfo>(bits == 16 ? kCGBitmapByteOrder16Little : kCGBitmapByteOrder32Big));
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

void expectUnsupported(const std::filesystem::path& path, const std::string& label, bool validEncoding = false) {
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
    check(status == SONY2FUJI_STATUS_UNSUPPORTED ||
          (!validEncoding && status == SONY2FUJI_STATUS_PROCESSING_ERROR),
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

enum class TIFFPageMarker : uint16_t { NewSubfileType = 254, OldSubfileType = 255, PageNumber = 297 };

bool writeTIFFWithMarkedSecondPage(const std::filesystem::path& source,
                                  const std::filesystem::path& destination, TIFFPageMarker marker) {
    // Append a copy of ImageIO's second IFD with a page tag. All other offsets stay valid.
    std::ifstream input(source, std::ios::binary);
    const std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)),
        std::istreambuf_iterator<char>());
    if (bytes.size() < 8 || bytes.size() >= UINT32_MAX || bytes[0] != bytes[1] ||
        (bytes[0] != 'I' && bytes[0] != 'M')) return false;
    const bool littleEndian = bytes[0] == 'I';
    const auto read = [&](size_t offset, size_t size) {
        uint32_t value = 0;
        for (size_t i = 0; i < size; ++i)
            value = (value << 8) | bytes.at(offset + (littleEndian ? size - 1 - i : i));
        return value;
    };
    if (read(2, 2) != 42) return false;
    const size_t first = read(4, 4);
    const size_t nextOffset = first + 2 + read(first, 2) * 12;
    const size_t second = read(nextOffset, 4);
    const uint32_t entryCount = read(second, 2);
    const size_t entries = second + 2;
    const size_t end = entries + entryCount * 12;
    if (second == 0 || entryCount == 0 || entryCount == UINT16_MAX || read(end, 4) != 0)
        return false;
    const auto tag = static_cast<uint16_t>(marker);
    size_t insert = entries;
    while (insert < end && read(insert, 2) < tag) insert += 12;
    const bool replaceTag = insert < end && read(insert, 2) == tag;

    std::ofstream output(destination, std::ios::binary);
    const auto put = [&](uint32_t value, size_t size) {
        for (size_t i = 0; i < size; ++i)
            output.put(static_cast<char>(value >> (8 * (littleEndian ? i : size - 1 - i))));
    };
    output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    if (bytes.size() % 2) output.put(0);
    const auto markedIFD = static_cast<uint32_t>(output.tellp());
    put(entryCount + (replaceTag ? 0 : 1), 2);
    output.write(reinterpret_cast<const char*>(bytes.data() + entries), insert - entries);
    put(tag, 2);
    if (marker == TIFFPageMarker::NewSubfileType) {
        put(4, 2); // LONG
        put(1, 4);
        put(2, 4); // Page bit
    } else {
        put(3, 2); // SHORT
        if (marker == TIFFPageMarker::OldSubfileType) {
            put(1, 4);
            put(3, 2); // Page enumeration value
            put(0, 2); // Padding
        } else {
            put(2, 4);
            put(1, 2); // Second page, using a zero-based index
            put(2, 2); // Two pages
        }
    }
    const size_t remaining = insert + (replaceTag ? 12 : 0);
    output.write(reinterpret_cast<const char*>(bytes.data() + remaining), end - remaining);
    put(0, 4); // No next IFD
    output.seekp(nextOffset);
    put(markedIFD, 4);
    return output.good();
}

void checkTiff16(const std::filesystem::path& root, CGColorSpaceRef sRGB) {
    auto fixture = rgb16Image(2, 3, sRGB);
    constexpr size_t order[8][6] = {
        {0, 1, 2, 3, 4, 5}, {1, 0, 3, 2, 5, 4}, {5, 4, 3, 2, 1, 0}, {4, 5, 2, 3, 0, 1},
        {0, 2, 4, 1, 3, 5}, {4, 2, 0, 5, 3, 1}, {5, 3, 1, 4, 2, 0}, {1, 3, 5, 0, 2, 4}
    };
    for (uint32_t orientation = 1; orientation <= 8; ++orientation) {
        const auto path = root / ("rgb16-orientation-" + std::to_string(orientation) + ".tif");
        auto* properties = orientationProperties(orientation);
        check(fixture.image && properties && writeImage(path, CFSTR("public.tiff"), fixture.image, properties),
              "Generate oriented 16-bit TIFF " + std::to_string(orientation));
        if (properties) CFRelease(properties);
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
        const uint32_t width = orientation >= 5 ? 3 : 2;
        const uint32_t height = orientation >= 5 ? 2 : 3;
        bool matches = status == SONY2FUJI_STATUS_OK && buffer.width == width &&
            buffer.height == height && buffer.pixel_format == SONY2FUJI_PIXEL_RGBA16 &&
            buffer.stride_bytes == width * 8 && buffer.size_bytes == width * height * 8;
        for (size_t i = 0; matches && i < 6; ++i) {
            const auto* pixel = static_cast<const uint8_t*>(buffer.data) + i * 8;
            const auto* expected = fixture.bytes.data() + order[orientation - 1][i] * 6;
            matches = pixel[6] == 255 && pixel[7] == 255;
            for (size_t c = 0; matches && c < 3; ++c)
                matches = pixel[2 * c] == expected[2 * c + 1] && pixel[2 * c + 1] == expected[2 * c];
        }
        check(matches, "16-bit TIFF retains all channel bits and applies orientation " + std::to_string(orientation));
        sony2fuji_release_buffer(&buffer);
    }

    auto mainImage = rgb16Image(300, 200, sRGB);
    auto preview = rgbImage(160, 106, sRGB, std::vector<uint8_t>(160 * 106 * 3, 127));
    const auto path = root / "sigma-photo-pro.tif";
    const void* softwareKeys[] = {kCGImagePropertyTIFFSoftware};
    const void* softwareValues[] = {CFSTR("SIGMA Photo Pro 6.9.0")};
    auto* tiff = CFDictionaryCreate(kCFAllocatorDefault, softwareKeys, softwareValues, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void* keys[] = {kCGImagePropertyTIFFDictionary};
    const void* values[] = {tiff};
    auto* properties = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    check(mainImage.image && preview.image && writeImage(path, CFSTR("public.tiff"), mainImage.image,
          properties, 2, preview.image), "Generate Sigma TIFF with a separate preview IFD");
    CFRelease(properties);
    CFRelease(tiff);
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
    check(status == SONY2FUJI_STATUS_OK && buffer.width == 300 && buffer.height == 200 &&
          buffer.pixel_format == SONY2FUJI_PIXEL_RGBA16, "Sigma TIFF imports the main image");
    sony2fuji_release_buffer(&buffer);

    for (const auto marker : {TIFFPageMarker::NewSubfileType, TIFFPageMarker::OldSubfileType,
                              TIFFPageMarker::PageNumber}) {
        const auto tag = std::to_string(static_cast<uint16_t>(marker));
        const auto markedPage = root / ("sigma-with-page-tag-" + tag + ".tif");
        if (writeTIFFWithMarkedSecondPage(path, markedPage, marker)) {
            expectUnsupported(markedPage, "Sigma TIFF with second-IFD page tag " + tag, true);
        } else {
            check(false, "Generate a Sigma TIFF with page tag " + tag);
        }
    }

    const auto multipage = root / "rgb16-multipage.tif";
    check(mainImage.image && preview.image && writeImage(multipage, CFSTR("public.tiff"), mainImage.image,
          nullptr, 2, preview.image), "Generate two-page TIFF without Sigma writer metadata");
    expectUnsupported(multipage, "TIFF16 with another page");
}

void checkPng16(const std::filesystem::path& root, CGColorSpaceRef sRGB) {
    auto fixture = rgb16Image(2, 3, sRGB);
    constexpr size_t order[8][6] = {
        {0, 1, 2, 3, 4, 5}, {1, 0, 3, 2, 5, 4}, {5, 4, 3, 2, 1, 0}, {4, 5, 2, 3, 0, 1},
        {0, 2, 4, 1, 3, 5}, {4, 2, 0, 5, 3, 1}, {5, 3, 1, 4, 2, 0}, {1, 3, 5, 0, 2, 4}
    };
    for (uint32_t orientation = 1; orientation <= 8; ++orientation) {
        const auto path = root / ("png16-orientation-" + std::to_string(orientation) + ".png");
        auto* properties = orientationProperties(orientation);
        check(fixture.image && properties && writeImage(path, CFSTR("public.png"), fixture.image, properties),
              "Generate oriented 16-bit PNG " + std::to_string(orientation));
        if (properties) CFRelease(properties);
        if (orientation == 1) check(stripPngColorProfile(path), "Remove PNG16 profile to test untagged RGB");
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
        const uint32_t width = orientation >= 5 ? 3 : 2, height = orientation >= 5 ? 2 : 3;
        bool matches = status == SONY2FUJI_STATUS_OK && buffer.pixel_format == SONY2FUJI_PIXEL_RGBA16 &&
            buffer.width == width && buffer.height == height && buffer.stride_bytes == width * 8 &&
            buffer.size_bytes == width * height * 8;
        for (size_t i = 0; matches && i < 6; ++i) {
            const auto* pixel = static_cast<const uint8_t*>(buffer.data) + i * 8;
            const auto* expected = fixture.bytes.data() + order[orientation - 1][i] * 6;
            matches = pixel[6] == 255 && pixel[7] == 255;
            for (size_t c = 0; matches && c < 3; ++c)
                matches = pixel[2 * c] == expected[2 * c + 1] && pixel[2 * c + 1] == expected[2 * c];
        }
        check(matches, "PNG16 preserves low bits and applies orientation " + std::to_string(orientation));
        sony2fuji_release_buffer(&buffer);
    }

    auto* p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    auto p3Fixture = rgb16Image(2, 3, p3);
    const auto p3Path = root / "p3-16.png";
    check(p3Fixture.image && writeImage(p3Path, CFSTR("public.png"), p3Fixture.image), "Generate P3 PNG16");
    sony2fuji_buffer converted{};
    const auto p3Status = sony2fuji_load_display_image(p3Path.u8string().c_str(), &converted);
    const auto expected = drawSRGB(p3Fixture.image, 16);
    const auto actual = outputBytes(converted);
    bool close = p3Status == SONY2FUJI_STATUS_OK && converted.pixel_format == SONY2FUJI_PIXEL_RGBA16 &&
        actual.size() == expected.size();
    for (size_t i = 0; close && i < actual.size(); i += 2) {
        const int value = actual[i] | (actual[i + 1] << 8);
        const int reference = expected[i] | (expected[i + 1] << 8);
        close = std::abs(value - reference) <= 2;
    }
    check(close, "PNG16 ICC conversion retains 16-bit sRGB precision");
    sony2fuji_release_buffer(&converted);
    CGColorSpaceRelease(p3);

    for (const uint16_t alpha : {uint16_t(65535), uint16_t(65534), uint16_t(32768)}) {
        const uint16_t pixel[] = {1234, 9153, 17072, alpha};
        auto* provider = CGDataProviderCreateWithData(nullptr, pixel, sizeof(pixel), nullptr);
        auto* image = CGImageCreate(1, 1, 16, 64, 8, sRGB,
            CGBitmapInfo(kCGImageAlphaLast) | kCGBitmapByteOrder16Little,
            provider, nullptr, false, kCGRenderingIntentDefault);
        const auto path = root / ("alpha16-" + std::to_string(alpha) + ".png");
        check(image && writeImage(path, CFSTR("public.png"), image), "Generate PNG16 alpha fixture");
        if (image) CGImageRelease(image);
        CGDataProviderRelease(provider);
        if (alpha != 65535) expectUnsupported(path, "Transparent PNG16", true);
        else {
            sony2fuji_buffer buffer{};
            const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
            check(status == SONY2FUJI_STATUS_OK && buffer.pixel_format == SONY2FUJI_PIXEL_RGBA16 &&
                buffer.size_bytes == sizeof(pixel) && std::memcmp(buffer.data, pixel, sizeof(pixel)) == 0,
                "Opaque RGBA PNG16 preserves all channels");
            sony2fuji_release_buffer(&buffer);
        }
    }

    auto* graySpace = CGColorSpaceCreateDeviceGray();
    const uint16_t grayValue = 1234;
    auto* provider = CGDataProviderCreateWithData(nullptr, &grayValue, sizeof(grayValue), nullptr);
    auto* gray = CGImageCreate(1, 1, 16, 16, 2, graySpace, kCGBitmapByteOrder16Little,
        provider, nullptr, false, kCGRenderingIntentDefault);
    const auto grayPath = root / "gray16.png";
    check(gray && writeImage(grayPath, CFSTR("public.png"), gray), "Generate grayscale PNG16");
    expectUnsupported(grayPath, "Grayscale PNG16", true);
    if (gray) CGImageRelease(gray);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(graySpace);

    const auto path = root / "rawlab-export.png";
    const auto outputPath = path.u8string();
    const uint16_t pixels[] = {1234, 9153, 17072, 65535, 24991, 32910, 40829, 65535};
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
    request.input_pixels = pixels;
    request.input_width = 2; request.input_height = 1;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGBA16;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.temperature = 6500;
    request.brightness = request.contrast = request.saturation = 1;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.output_target = SONY2FUJI_TARGET_FILE;
    request.output_format = SONY2FUJI_OUTPUT_PNG;
    request.output_path = outputPath.c_str();
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    sony2fuji_session* session = nullptr;
    check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK &&
          sony2fuji_process(session, &request, nullptr) == SONY2FUJI_STATUS_OK,
          "RawLab writes its own PNG16 fixture through the C API");
    sony2fuji_session_destroy(session);
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
    check(status == SONY2FUJI_STATUS_OK && buffer.pixel_format == SONY2FUJI_PIXEL_RGBA16 &&
          buffer.size_bytes == sizeof(pixels) && std::memcmp(buffer.data, pixels, sizeof(pixels)) == 0,
          "RawLab PNG16 export reimports without losing low bits");
    sony2fuji_release_buffer(&buffer);
}

void runAppleTests() {
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

    for (uint32_t orientation = 1; orientation <= 8; ++orientation) {
        const auto path = root / ("orientation-" + std::to_string(orientation) + ".png");
        auto* properties = orientationProperties(orientation);
        check(properties && writeImage(path, CFSTR("public.png"), fixture.image, properties),
              "Generate EXIF orientation " + std::to_string(orientation));
        if (properties) CFRelease(properties);
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buffer);
        const uint32_t width = orientation >= 5 ? 3 : 2;
        const uint32_t height = orientation >= 5 ? 2 : 3;
        bool matches = status == SONY2FUJI_STATUS_OK && buffer.width == width && buffer.height == height;
        for (uint32_t y = 0; matches && y < height; ++y) {
            for (uint32_t x = 0; matches && x < width; ++x) {
                uint32_t sourceX = x, sourceY = y;
                switch (orientation) {
                    case 2: sourceX = 1 - x; break;
                    case 3: sourceX = 1 - x; sourceY = 2 - y; break;
                    case 4: sourceY = 2 - y; break;
                    case 5: sourceX = y; sourceY = x; break;
                    case 6: sourceX = y; sourceY = 2 - x; break;
                    case 7: sourceX = 1 - y; sourceY = 2 - x; break;
                    case 8: sourceX = 1 - y; sourceY = x; break;
                }
                const auto* actual = static_cast<const uint8_t*>(buffer.data) + (y * width + x) * 4;
                matches = std::equal(actual, actual + 4, pattern.begin() + (sourceY * 2 + sourceX) * 4);
            }
        }
        check(matches, "EXIF orientation " + std::to_string(orientation) + " transforms pixels exactly once");
        sony2fuji_release_buffer(&buffer);
    }

    const auto tiff = root / "photo.tiff";
    check(fixture.image && writeImage(tiff, CFSTR("public.tiff"), fixture.image),
          "Generate TIFF fixture");
    sony2fuji_buffer tiffBuffer{};
    const auto tiffStatus = sony2fuji_load_display_image(tiff.u8string().c_str(), &tiffBuffer);
    check(tiffStatus == SONY2FUJI_STATUS_OK, "TIFF decodes when the system encoder is available");
    sony2fuji_release_buffer(&tiffBuffer);
    checkTiff16(root, sRGB);

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

    auto* taggedGraySpace = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    auto taggedGrayFixture = grayImage(2, 1, taggedGraySpace, {32, 224});
    const auto taggedGray = root / "tagged-gray.png";
    const bool taggedGrayWritten = taggedGrayFixture.image &&
        writeImage(taggedGray, CFSTR("public.png"), taggedGrayFixture.image);
    check(taggedGrayWritten, "Generate profiled grayscale PNG fixture");
    if (taggedGrayWritten) {
        const auto pathString = taggedGray.u8string();
        auto* url = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, reinterpret_cast<const UInt8*>(pathString.data()), pathString.size(), false);
        auto* source = url ? CGImageSourceCreateWithURL(url, nullptr) : nullptr;
        auto* properties = source ? CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr) : nullptr;
        auto* image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
        check(properties && CFDictionaryGetValue(properties, kCGImagePropertyProfileName) && image &&
                  CGColorSpaceGetModel(CGImageGetColorSpace(image)) == kCGColorSpaceModelMonochrome,
              "Profiled grayscale fixture retains its profile and non-RGB source model");
        if (image) CGImageRelease(image);
        if (properties) CFRelease(properties);
        if (source) CFRelease(source);
        if (url) CFRelease(url);
        expectUnsupported(taggedGray, "Profiled grayscale PNG", true);
    }
    CGColorSpaceRelease(taggedGraySpace);

    const auto transparent = root / "transparent.png";
    auto transparentFixture = rgbaImage(1, 1, sRGB, {255, 0, 0, 127});
    check(transparentFixture.image && writeImage(transparent, CFSTR("public.png"), transparentFixture.image),
          "Generate transparent PNG fixture");
    expectUnsupported(transparent, "Transparent PNG");

    checkPng16(root, sRGB);

    const auto multipage = root / "multipage.tiff";
    check(fixture.image && writeImage(multipage, CFSTR("public.tiff"), fixture.image, nullptr, 2),
          "Generate multi-page TIFF fixture");
    expectUnsupported(multipage, "Multi-page TIFF");

#if (defined(__MAC_OS_X_VERSION_MAX_ALLOWED) && __MAC_OS_X_VERSION_MAX_ALLOWED >= 150000) || \
    (defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 180000)
    if (__builtin_available(macOS 15.0, iOS 18.0, *)) {
        auto* extended = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        auto hdr = hdrImage(extended);
        auto* withHeadroom = CGImageCreateCopyWithContentHeadroom(4.0f, hdr.image);
        check(withHeadroom != nullptr, "Create extended-linear HDR image with explicit headroom");
        const void* keys[] = {kCGImageDestinationEncodeRequest};
        const void* values[] = {kCGImageDestinationEncodeToISOGainmap};
        auto* properties = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const auto path = root / "iso-gain-map.jpg";
        const bool written = withHeadroom && writeImage(path, CFSTR("public.jpeg"), withHeadroom, properties);
        if (!written) std::cout << "SKIP ISO gain-map: system encoder could not create the fixture\n";
        if (written) {
            const auto name = path.u8string();
            auto* url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
                reinterpret_cast<const UInt8*>(name.data()), name.size(), false);
            auto* source = CGImageSourceCreateWithURL(url, nullptr);
            auto* auxiliary = source ? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0,
                kCGImageAuxiliaryDataTypeISOGainMap) : nullptr;
            check(auxiliary != nullptr, "ISO gain-map fixture contains an actual auxiliary gain map");
            if (auxiliary) {
                CFRelease(auxiliary);
                expectUnsupported(path, "HDR ISO gain-map JPEG", true);
                if (const char* output = std::getenv("RAWLAB_TEST_GAIN_MAP_OUTPUT"))
                    std::filesystem::copy_file(path, output, std::filesystem::copy_options::overwrite_existing);
            }
            if (source) CFRelease(source);
            CFRelease(url);
        }
        CFRelease(properties);
        if (withHeadroom) CGImageRelease(withHeadroom);
        CGColorSpaceRelease(extended);
    }
#endif
    if (const char* gainMap = std::getenv("RAWLAB_TEST_GAIN_MAP"); gainMap && *gainMap)
        expectUnsupported(gainMap, "External verified HDR gain-map JPEG", true);

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

    if (const char* large = std::getenv("RAWLAB_TEST_LARGE_RASTER"); large && *large) {
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_load_display_image(large, &buffer);
        check(status == SONY2FUJI_STATUS_OK, "Medium-format raster imports through ImageIO");
        if (status == SONY2FUJI_STATUS_OK)
            check(uint64_t(buffer.width) * buffer.height >= 100000000 &&
                  buffer.size_bytes == uint64_t(buffer.width) * buffer.height * 4,
                  "Medium-format raster retains full resolution and RGBA bytes");
        sony2fuji_release_buffer(&buffer);
    }

    if (const char* photo = std::getenv("RAWLAB_TEST_RASTER"); photo && *photo) {
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_load_display_image(photo, &buffer);
        check(status == SONY2FUJI_STATUS_OK,
              "Supplied ICC plus EXIF JPEG decodes through the Apple adapter");
        if (status == SONY2FUJI_STATUS_OK) {
            check(buffer.width == 2000 && buffer.height == 1334 &&
                  buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8,
                  "Supplied JPEG preserves its 2000x1334 oriented RGB image");
            const auto bytes = outputBytes(buffer);
            check(bytes.size() == 2000u * 1334u * 4u &&
                  *std::min_element(bytes.begin(), bytes.end()) < *std::max_element(bytes.begin(), bytes.end()),
                  "Supplied JPEG produces nonempty photo pixels");
        }
        sony2fuji_release_buffer(&buffer);
    }

    CGColorSpaceRelease(sRGB);
}

#endif

} // namespace

int main() {
#if defined(__APPLE__)
    runAppleTests();
#else
    sony2fuji_buffer output{};
    const auto status = sony2fuji_load_display_image("missing.jpg", &output);
    check(status == SONY2FUJI_STATUS_UNSUPPORTED && output.data == nullptr,
          "Non-Apple display decoder is an explicit unsupported stub");
    sony2fuji_release_buffer(&output);
#endif
    return failures == 0 ? 0 : 1;
}
