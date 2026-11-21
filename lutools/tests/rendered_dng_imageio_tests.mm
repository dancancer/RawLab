#include "core/rendered_dng.h"

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <vector>

int main() {
    @autoreleasepool {
        constexpr int width = 640;
        constexpr int height = 480;
        constexpr float reference[][3] = {
            {0.05f, 0.05f, 0.05f}, {0.5f, 0.5f, 0.5f}, {0.95f, 0.95f, 0.95f},
            {1.0f, 0.0f, 0.0f}, {0.0f, 1.0f, 0.0f}, {0.0f, 0.0f, 1.0f},
            {0.8f, 0.5f, 0.3f},
        };
        constexpr int patches = sizeof(reference) / sizeof(reference[0]);
        sony2fuji::ImageData image(width, height);
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const auto& color = reference[x * patches / width];
                image.at(x, y) = sony2fuji::RGB(color[0], color[1], color[2]);
            }
        }

        const auto pattern = (std::filesystem::temp_directory_path() / "rawlab-dng-imageio-XXXXXX").string();
        std::vector<char> path(pattern.begin(), pattern.end());
        path.push_back('\0');
        const char* created = mkdtemp(path.data());
        if (!created) {
            std::cerr << "FAIL cannot create temporary DNG directory\n";
            return 1;
        }
        const std::filesystem::path directory(created);
        const auto output = directory / "rendered.dng";
        const bool written = sony2fuji::saveRenderedDNG(image, output.string()) == sony2fuji::ErrorCode::Success;
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:output.c_str()]];
        CGImageSourceRef source = written ? CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr) : nullptr;
        NSDictionary* thumbnailOptions = @{
            (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageIfAbsent: @YES,
            (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize: @160,
        };
        CGImageRef thumbnail = source ? CGImageSourceCreateThumbnailAtIndex(
            source, 0, (__bridge CFDictionaryRef)thumbnailOptions) : nullptr;
        constexpr int thumbWidth = 160;
        constexpr int thumbHeight = 120;
        bool previewValid = thumbnail && CGImageGetWidth(thumbnail) == thumbWidth &&
            CGImageGetHeight(thumbnail) == thumbHeight;
        if (previewValid) {
            std::vector<uint8_t> pixels(thumbWidth * thumbHeight * 4);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context = colorSpace ? CGBitmapContextCreate(
                pixels.data(), thumbWidth, thumbHeight, 8, thumbWidth * 4, colorSpace,
                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : nullptr;
            if (context) {
                CGContextDrawImage(context, CGRectMake(0, 0, thumbWidth, thumbHeight), thumbnail);
                for (int i = 0; i < patches; ++i) {
                    const size_t offset = (static_cast<size_t>(thumbHeight / 2) * thumbWidth +
                        (2 * i + 1) * thumbWidth / (2 * patches)) * 4;
                    for (size_t channel = 0; channel < 3; ++channel)
                        previewValid = previewValid && std::abs(pixels[offset + channel] / 255.0f - reference[i][channel]) < 0.04f;
                }
                CGContextRelease(context);
            } else {
                previewValid = false;
            }
            if (colorSpace) CGColorSpaceRelease(colorSpace);
        }
        CGImageRef decoded = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
        bool valid = decoded && CGImageGetWidth(decoded) == width && CGImageGetHeight(decoded) == height;

        if (valid) {
            std::vector<uint8_t> pixels(width * height * 4);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context = colorSpace ? CGBitmapContextCreate(
                pixels.data(), width, height, 8, width * 4, colorSpace,
                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : nullptr;
            if (context) {
                CGContextDrawImage(context, CGRectMake(0, 0, width, height), decoded);
                for (int i = 0; i < patches; ++i) {
                    const size_t offset = (static_cast<size_t>(height / 2) * width + (2 * i + 1) * width / (2 * patches)) * 4;
                    if (i >= 3 && i <= 5) {
                        // RAW readers may apply gamut mapping; check channel identity, not exact saturation.
                        const int primary = i - 3;
                        const int value = pixels[offset + primary];
                        valid = valid && value > 160 && value > pixels[offset + (primary + 1) % 3] + 50 &&
                            value > pixels[offset + (primary + 2) % 3] + 50;
                    } else {
                        for (size_t channel = 0; channel < 3; ++channel)
                            valid = valid && std::abs(pixels[offset + channel] / 255.0f - reference[i][channel]) < 0.08f;
                    }
                }
                CGContextRelease(context);
            } else {
                valid = false;
            }
            if (colorSpace) CGColorSpaceRelease(colorSpace);
        }
        if (thumbnail) CGImageRelease(thumbnail);
        if (decoded) CGImageRelease(decoded);
        if (source) CFRelease(source);
        std::filesystem::remove_all(directory);
        std::cout << (previewValid ? "PASS" : "FAIL") << " ImageIO reads the embedded sRGB thumbnail with matching colors\n";
        std::cout << (valid ? "PASS" : "FAIL") << " ImageIO decodes rendered DNG at the expected size with recognizable colors\n";
        return previewValid && valid ? 0 : 1;
    }
}
