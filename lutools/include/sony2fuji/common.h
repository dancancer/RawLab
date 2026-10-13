#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace sony2fuji {

// RGB 颜色结构
struct RGB {
    float r, g, b;

    RGB() : r(0), g(0), b(0) {}
    RGB(float r, float g, float b) : r(r), g(g), b(b) {}
};

// 图像数据结构
struct ImageData {
    int width;
    int height;
    std::vector<RGB> pixels;

    ImageData() : width(0), height(0) {}
    ImageData(int w, int h) : width(w), height(h), pixels(w * h) {}

    RGB& at(int x, int y) { return pixels[y * width + x]; }
    const RGB& at(int x, int y) const { return pixels[y * width + x]; }
};

// 色彩空间定义
enum class ColorSpace {
    SonyNative,    // Sony 原生色彩空间
    FujiFilm_FGamut,  // Fuji F-Gamut
    ACEScg,        // ACEScg (AP1)
    BT709,         // ITU-R BT.709
    ProPhotoRGB,   // ProPhoto RGB
    AdobeRGB,
    sRGB,          // sRGB
    ACES2065_1     // ACES2065-1 (AP0)
};

// 输出格式
enum class OutputFormat {
    JPEG,
    PNG,
    DNG
};

// 错误码
enum class ErrorCode {
    Success = 0,
    FileNotFound,
    ParseError,
    InvalidFormat,
    ProcessingError,
    OutOfMemory,
    IOError
};

} // namespace sony2fuji
