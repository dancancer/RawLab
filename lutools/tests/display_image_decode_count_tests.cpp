#include "test_harness.h"
#include "platform/display_image.h"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <unistd.h>
#endif

extern "C" sony2fuji_status sony2fuji_load_display_image(
    const char* path, sony2fuji_buffer* out_buffer);

namespace {

using rawlab::test::checkPass;

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

FixtureImage makeRgb8Image(size_t width, size_t height, CGColorSpaceRef colorSpace,
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

FixtureImage makeRgb16Image(size_t width, size_t height, CGColorSpaceRef colorSpace) {
    FixtureImage result;
    result.bytes.resize(width * height * 6);
    for (size_t i = 0; i < width * height * 3; ++i) {
        const uint16_t val = static_cast<uint16_t>(i * 7919u + 1234u);
        result.bytes[i * 2] = static_cast<uint8_t>(val >> 8);
        result.bytes[i * 2 + 1] = static_cast<uint8_t>(val);
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

FixtureImage makeCmykImage(CGColorSpaceRef colorSpace) {
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

CFDictionaryRef makeOrientationProps(uint32_t orientation) {
    auto* num = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &orientation);
    if (!num) return nullptr;
    const void* keys[] = {kCGImagePropertyOrientation};
    const void* vals[] = {num};
    auto* dict = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(num);
    return dict;
}

bool writeImage(const std::filesystem::path& path, CFStringRef type, CGImageRef image,
                CFDictionaryRef props = nullptr) {
    const auto str = path.u8string();
    auto* url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, reinterpret_cast<const UInt8*>(str.data()), str.size(), false);
    if (!url) return false;
    auto* dest = CGImageDestinationCreateWithURL(url, type, 1, nullptr);
    CFRelease(url);
    if (!dest) return false;
    CGImageDestinationAddImage(dest, image, props);
    const bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
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
        const bool isProfile = std::memcmp(type, "iCCP", 4) == 0 ||
            std::memcmp(type, "cICP", 4) == 0 ||
            std::memcmp(type, "sRGB", 4) == 0 ||
            std::memcmp(type, "cHRM", 4) == 0 ||
            std::memcmp(type, "gAMA", 4) == 0;
        if (!isProfile) {
            stripped.insert(stripped.end(), source.begin() + offset, source.begin() + offset + chunkSize);
        }
        if (std::memcmp(type, "IEND", 4) == 0) {
            foundEnd = true;
            break;
        }
        offset += chunkSize;
    }
    if (!foundEnd) return false;
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(stripped.data()), static_cast<std::streamsize>(stripped.size()));
    return output.good();
}

void verifySingleDecodeLoad(const std::filesystem::path& path,
                            uint32_t expectedW,
                            uint32_t expectedH,
                            sony2fuji_pixel_format expectedFmt,
                            const char* label) {
    sony2fuji::resetDisplayImageDecodeCount();
    sony2fuji_buffer buf{};
    const auto status = sony2fuji_load_display_image(path.u8string().c_str(), &buf);
    const uint64_t count = sony2fuji::displayImageDecodeCount();
    checkPass(status == SONY2FUJI_STATUS_OK && buf.data &&
              buf.width == expectedW && buf.height == expectedH &&
              buf.pixel_format == expectedFmt,
              std::string(label) + " decoded with expected geometry and format");
    checkPass(count == 1,
              std::string(label) + " performed exactly 1 ImageIO decode (observed=" + std::to_string(count) + ")");
    sony2fuji_release_buffer(&buf);
}

#endif

} // namespace

int main() {
#if defined(__APPLE__)
    const auto dir = std::filesystem::temp_directory_path() /
        ("rawlab-display-decode-count-" + std::to_string(getpid()));
    std::filesystem::remove_all(dir);
    checkPass(std::filesystem::create_directories(dir), "create temp directory");

    auto* sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    auto* p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    auto* cmyk = CGColorSpaceCreateDeviceCMYK();
    checkPass(sRGB && p3 && cmyk, "create CoreGraphics color spaces");

    // 2x3 image with distinct corners for orientation=6 (90 CW -> 3x2)
    // Raw (row-major):
    // row 0: (255,0,0),   (0,255,0)
    // row 1: (0,0,255),   (255,255,0)
    // row 2: (0,255,255), (255,0,255)
    const std::vector<uint8_t> pixels2x3 = {
        255, 0, 0,     0, 255, 0,
        0, 0, 255,     255, 255, 0,
        0, 255, 255,   255, 0, 255,
    };
    const auto img2x3 = makeRgb8Image(2, 3, sRGB, pixels2x3);
    auto* ori6Props = makeOrientationProps(6);
    checkPass(img2x3.image && ori6Props, "create 2x3 RGB image and orientation=6 props");

    const auto jpgOri6 = dir / "ori6.jpg";
    const auto pngOri6 = dir / "ori6.png";
    const auto tifOri6 = dir / "ori6.tif";
    const auto heicOri6 = dir / "ori6.heic";
    checkPass(writeImage(jpgOri6, CFSTR("public.jpeg"), img2x3.image, ori6Props), "write 8-bit JPEG ori=6");
    checkPass(writeImage(pngOri6, CFSTR("public.png"), img2x3.image, ori6Props), "write 8-bit PNG ori=6");
    checkPass(writeImage(tifOri6, CFSTR("public.tiff"), img2x3.image, ori6Props), "write 8-bit TIFF ori=6");

    verifySingleDecodeLoad(jpgOri6, 3, 2, SONY2FUJI_PIXEL_RGBA8, "8-bit JPEG orientation=6");
    verifySingleDecodeLoad(pngOri6, 3, 2, SONY2FUJI_PIXEL_RGBA8, "8-bit PNG orientation=6");
    verifySingleDecodeLoad(tifOri6, 3, 2, SONY2FUJI_PIXEL_RGBA8, "8-bit TIFF orientation=6");

    // Verify exact oriented pixel layout for 8-bit PNG ori=6 (90 CW: bottom-left raw (0,255,255) -> top-left output)
    {
        sony2fuji::resetDisplayImageDecodeCount();
        sony2fuji::OwnedPixelBuffer owned;
        checkPass(sony2fuji::loadDisplayImage(pngOri6.u8string().c_str(), owned) == sony2fuji::RenderStatus::Ok &&
                  sony2fuji::displayImageDecodeCount() == 1 &&
                  owned.width == 3 && owned.height == 2,
                  "loadDisplayImage C++ single decode for PNG ori=6");
        const auto* px = static_cast<const uint8_t*>(owned.data);
        // Top-left pixel (x=0, y=0) after 90 CW is raw row 2 col 0 = (0, 255, 255, 255)
        checkPass(px[0] == 0 && px[1] == 255 && px[2] == 255 && px[3] == 255,
                  "8-bit PNG orientation=6 top-left pixel rotated accurately");
        // Top-right pixel (x=2, y=0) after 90 CW is raw row 0 col 0 = (255, 0, 0, 255)
        checkPass(px[8] == 255 && px[9] == 0 && px[10] == 0 && px[11] == 255,
                  "8-bit PNG orientation=6 top-right pixel rotated accurately");
    }

    if (writeImage(heicOri6, CFSTR("public.heic"), img2x3.image, ori6Props)) {
        verifySingleDecodeLoad(heicOri6, 3, 2, SONY2FUJI_PIXEL_RGBA8, "8-bit HEIC orientation=6");
    }

    // Untagged 8-bit PNG
    const std::vector<uint8_t> pixels2x2 = {
        12, 34, 56,   78, 90, 123,
        45, 67, 89,   200, 150, 100,
    };
    const auto img2x2 = makeRgb8Image(2, 2, sRGB, pixels2x2);
    const auto untaggedPng = dir / "untagged.png";
    checkPass(writeImage(untaggedPng, CFSTR("public.png"), img2x2.image) && stripPngColorProfile(untaggedPng),
              "write untagged 8-bit PNG");
    verifySingleDecodeLoad(untaggedPng, 2, 2, SONY2FUJI_PIXEL_RGBA8, "8-bit untagged PNG");

    // Display P3 8-bit PNG
    const auto imgP3 = makeRgb8Image(1, 1, p3, {255, 0, 0});
    const auto p3Png = dir / "p3.png";
    checkPass(writeImage(p3Png, CFSTR("public.png"), imgP3.image), "write 8-bit Display P3 PNG");
    verifySingleDecodeLoad(p3Png, 1, 1, SONY2FUJI_PIXEL_RGBA8, "8-bit Display P3 PNG");

    // 16-bit PNG
    const auto img16 = makeRgb16Image(2, 1, sRGB);
    const auto png16 = dir / "rgb16.png";
    checkPass(writeImage(png16, CFSTR("public.png"), img16.image), "write 16-bit PNG");
    verifySingleDecodeLoad(png16, 2, 1, SONY2FUJI_PIXEL_RGBA16, "16-bit PNG");

    // loadDisplayPreview on 8-bit 16x12 JPEG orientation=6 -> oriented source 12x16, edge=8 -> 6x8
    {
        std::vector<uint8_t> bytes16x12(16 * 12 * 3, 128);
        const auto img16x12 = makeRgb8Image(16, 12, sRGB, bytes16x12);
        const auto jpg16x12 = dir / "preview_ori6.jpg";
        checkPass(writeImage(jpg16x12, CFSTR("public.jpeg"), img16x12.image, ori6Props), "write 16x12 JPEG ori=6");
        sony2fuji::resetDisplayImageDecodeCount();
        sony2fuji::OwnedPixelBuffer preview;
        uint32_t srcW = 0, srcH = 0;
        const auto status = sony2fuji::loadDisplayPreview(jpg16x12.u8string().c_str(), 8, preview, &srcW, &srcH);
        const uint64_t count = sony2fuji::displayImageDecodeCount();
        checkPass(status == sony2fuji::RenderStatus::Ok &&
                  preview.format == sony2fuji::PixelBufferFormat::RGBA8 &&
                  srcW == 12 && srcH == 16 &&
                  preview.width == 6 && preview.height == 8 &&
                  count == 1,
                  "loadDisplayPreview 8-bit JPEG ori=6 single bounded decode");

        // C ABI sony2fuji_load_display_preview parity + opaque alpha + error/stale-buffer checks
        sony2fuji::resetDisplayImageDecodeCount();
        sony2fuji_buffer cPreview{};
        uint32_t cW = 0, cH = 0;
        const auto cStatus = sony2fuji_load_display_preview(
            jpg16x12.u8string().c_str(), 8, &cPreview, &cW, &cH);
        const uint64_t cCount = sony2fuji::displayImageDecodeCount();
        bool cOpaque = cPreview.data != nullptr && cPreview.size_bytes == 6u * 8u * 4u;
        if (cOpaque) {
            const auto* bytes = static_cast<const uint8_t*>(cPreview.data);
            for (size_t i = 3; i < cPreview.size_bytes; i += 4) {
                if (bytes[i] != 255) { cOpaque = false; break; }
            }
        }
        checkPass(cStatus == SONY2FUJI_STATUS_OK && cCount == 1 &&
                  cW == 12 && cH == 16 &&
                  cPreview.width == 6 && cPreview.height == 8 &&
                  cPreview.pixel_format == SONY2FUJI_PIXEL_RGBA8 && cOpaque,
                  "C ABI sony2fuji_load_display_preview decodes 8-bit JPEG ori=6 in 1 bounded pass");
        sony2fuji_release_buffer(&cPreview);

        sony2fuji_buffer zeroEdge{std::malloc(4), 4, 9, 9, 4, SONY2FUJI_PIXEL_RGBA8};
        uint32_t zeroW = 7, zeroH = 8;
        const auto zeroSt = sony2fuji_load_display_preview(
            jpg16x12.u8string().c_str(), 0, &zeroEdge, &zeroW, &zeroH);
        checkPass(zeroSt == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
                  zeroEdge.data == nullptr && zeroEdge.size_bytes == 0 &&
                  zeroW == 0 && zeroH == 0,
                  "C ABI sony2fuji_load_display_preview edge=0 clears stale buffer");
        sony2fuji_release_buffer(&zeroEdge);
        checkPass(sony2fuji_load_display_preview(jpg16x12.u8string().c_str(), 8, nullptr, &zeroW, &zeroH) ==
                  SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "C ABI sony2fuji_load_display_preview rejects nullptr out_buffer");

        // Transparent alpha PNG rejection via C ABI
        CGColorSpaceRef rgbaSpace = sRGB;
        CGContextRef alphaCtx = CGBitmapContextCreate(
            nullptr, 4, 4, 8, 16, rgbaSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        checkPass(alphaCtx != nullptr, "create alpha PNG context");
        if (alphaCtx) {
            auto* ptr = static_cast<uint8_t*>(CGBitmapContextGetData(alphaCtx));
            std::memset(ptr, 128, 4 * 4 * 4);
            CGImageRef alphaCg = CGBitmapContextCreateImage(alphaCtx);
            const auto alphaPng = dir / "alpha.png";
            checkPass(alphaCg && writeImage(alphaPng, CFSTR("public.png"), alphaCg), "write alpha PNG");
            if (alphaCg) CGImageRelease(alphaCg);
            CGContextRelease(alphaCtx);
            sony2fuji_buffer alphaBuf{std::malloc(4), 4, 9, 9, 4, SONY2FUJI_PIXEL_RGBA8};
            uint32_t aW = 5, aH = 6;
            const auto aSt = sony2fuji_load_display_preview(alphaPng.u8string().c_str(), 2, &alphaBuf, &aW, &aH);
            checkPass(aSt == SONY2FUJI_STATUS_UNSUPPORTED &&
                      alphaBuf.data == nullptr && alphaBuf.size_bytes == 0 &&
                      aW == 0 && aH == 0,
                      "C ABI sony2fuji_load_display_preview rejects alpha PNG and clears stale outputs");
            sony2fuji_release_buffer(&alphaBuf);
        }
    }

    // loadDisplayPreview on 16-bit PNG -> always RGBA8, single decode
    {
        sony2fuji::resetDisplayImageDecodeCount();
        sony2fuji::OwnedPixelBuffer preview16;
        uint32_t srcW = 0, srcH = 0;
        const auto status = sony2fuji::loadDisplayPreview(png16.u8string().c_str(), 2, preview16, &srcW, &srcH);
        checkPass(status == sony2fuji::RenderStatus::Ok &&
                  preview16.format == sony2fuji::PixelBufferFormat::RGBA8 &&
                  srcW == 2 && srcH == 1 &&
                  preview16.width == 2 && preview16.height == 1 &&
                  sony2fuji::displayImageDecodeCount() == 1,
                  "loadDisplayPreview 16-bit PNG returns RGBA8 in 1 decode");

        sony2fuji::resetDisplayImageDecodeCount();
        sony2fuji_buffer cPrev16{};
        uint32_t cW16 = 0, cH16 = 0;
        const auto cSt16 = sony2fuji_load_display_preview(png16.u8string().c_str(), 2, &cPrev16, &cW16, &cH16);
        checkPass(cSt16 == SONY2FUJI_STATUS_OK &&
                  cPrev16.pixel_format == SONY2FUJI_PIXEL_RGBA8 &&
                  cW16 == 2 && cH16 == 1 &&
                  cPrev16.width == 2 && cPrev16.height == 1 &&
                  sony2fuji::displayImageDecodeCount() == 1,
                  "C ABI sony2fuji_load_display_preview 16-bit PNG returns RGBA8 in 1 decode");
        sony2fuji_release_buffer(&cPrev16);
    }

    // CMYK TIFF rejection in both loadDisplayImage and loadDisplayPreview
    {
        const auto imgCmyk = makeCmykImage(cmyk);
        const auto cmykTiff = dir / "cmyk.tif";
        checkPass(writeImage(cmykTiff, CFSTR("public.tiff"), imgCmyk.image), "write CMYK TIFF");
        sony2fuji::OwnedPixelBuffer out;
        checkPass(sony2fuji::loadDisplayImage(cmykTiff.u8string().c_str(), out) == sony2fuji::RenderStatus::Unsupported,
                  "loadDisplayImage rejects CMYK TIFF");
        checkPass(sony2fuji::loadDisplayPreview(cmykTiff.u8string().c_str(), 1, out) == sony2fuji::RenderStatus::Unsupported,
                  "loadDisplayPreview rejects CMYK TIFF");
    }

    CFRelease(ori6Props);
    CFRelease(sRGB);
    CFRelease(p3);
    CFRelease(cmyk);
    std::filesystem::remove_all(dir);
    if (rawlab::test::failureCount() == 0) {
        std::cout << "PASS display_image single-decode count and preview checks\n";
    }
    return rawlab::test::exitCode();
#else
    return 0;
#endif
}
