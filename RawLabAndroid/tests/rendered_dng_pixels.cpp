#define STB_IMAGE_IMPLEMENTATION
#include "core/stb_image.h"

#include <tiffio.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint16_t kLinearRaw = 34892;
double srgb(double linear) {
    return linear <= 0.0031308
        ? linear * 12.92
        : 1.055 * std::pow(linear, 1.0 / 2.4) - 0.055;
}
uint16_t encode16(float linear) { return static_cast<uint16_t>(srgb(linear) * 65535.0 + 0.5); }
uint8_t encode8(float linear) { return static_cast<uint8_t>(srgb(linear) * 255.0 + 0.5); }
uint8_t pngTo8(uint16_t value) { return static_cast<uint8_t>(value * 255.0 / 65535.0 + 0.5); }

struct DngReader {
    TIFF* file = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<float> row;

    explicit DngReader(const std::string& path) : file(TIFFOpen(path.c_str(), "r")) {
        if (!file) throw std::runtime_error("cannot open DNG: " + path);
        try {
            uint16_t bits = 0, samples = 0, photometric = 0, orientation = 0;
            uint16_t planar = 0, sampleFormat = 0;
            if (!TIFFGetField(file, TIFFTAG_IMAGEWIDTH, &width) ||
                !TIFFGetField(file, TIFFTAG_IMAGELENGTH, &height) ||
                !TIFFGetField(file, TIFFTAG_BITSPERSAMPLE, &bits) ||
                !TIFFGetField(file, TIFFTAG_SAMPLESPERPIXEL, &samples) ||
                !TIFFGetField(file, TIFFTAG_PHOTOMETRIC, &photometric) ||
                !TIFFGetField(file, TIFFTAG_ORIENTATION, &orientation) ||
                !TIFFGetField(file, TIFFTAG_PLANARCONFIG, &planar) ||
                !TIFFGetField(file, TIFFTAG_SAMPLEFORMAT, &sampleFormat))
                throw std::runtime_error("missing DNG image fields");
            if (photometric != kLinearRaw || bits != 32 || samples != 3 ||
                orientation != ORIENTATION_TOPLEFT || planar != PLANARCONFIG_CONTIG ||
                sampleFormat != SAMPLEFORMAT_IEEEFP)
                throw std::runtime_error("DNG is not top-left contiguous float32 LinearRaw RGB");
            if (TIFFFindField(file, TIFFTAG_DNGVERSION, TIFF_ANY)) {
                uint8_t* version = nullptr;
                if (!TIFFGetField(file, TIFFTAG_DNGVERSION, &version) || !version ||
                    version[0] != 1 || version[1] != 4 || version[2] != 0 || version[3] != 0)
                    throw std::runtime_error("DNG version is not 1.4.0.0");
            }
            if (width == 0 || height == 0 ||
                static_cast<uint64_t>(width) * 3 > std::numeric_limits<size_t>::max())
                throw std::runtime_error("invalid DNG dimensions");
            row.resize(static_cast<size_t>(width) * 3);
        } catch (...) {
            TIFFClose(file);
            file = nullptr;
            throw;
        }
    }

    ~DngReader() { if (file) TIFFClose(file); }
    DngReader(const DngReader&) = delete;
    void readRow(uint32_t y) {
        if (TIFFReadScanline(file, row.data(), y, 0) < 0)
            throw std::runtime_error("cannot read DNG scanline");
        for (float value : row) if (!std::isfinite(value) || value < 0.0f || value > 1.0f)
            throw std::runtime_error("DNG contains non-finite or out-of-range pixel");
    }
};
struct Png16 {
    int width = 0;
    int height = 0;
    int channels = 0;
    std::unique_ptr<stbi_us, decltype(&stbi_image_free)> pixels;

    explicit Png16(const std::string& path)
        : pixels(stbi_load_16(path.c_str(), &width, &height, &channels, 3), stbi_image_free) {
        if (!stbi_is_16_bit(path.c_str())) throw std::runtime_error("reference is not a 16-bit PNG");
        if (!pixels) {
            const char* reason = stbi_failure_reason();
            throw std::runtime_error("cannot decode PNG: " + path +
                (reason ? " (" + std::string(reason) + ")" : ""));
        }
        if (width <= 0 || height <= 0) throw std::runtime_error("invalid PNG dimensions");
    }
};
} // namespace

int main(int argc, char** argv) {
    if (argc < 3 || argc > 4) {
        std::cerr << "usage: rendered_dng_pixels <dng> <png16> [second-dng]\n";
        return 2;
    }
    try {
        DngReader dng(argv[1]);
        Png16 png(argv[2]);
        if (dng.width != static_cast<uint32_t>(png.width) ||
            dng.height != static_cast<uint32_t>(png.height))
            throw std::runtime_error("DNG and PNG dimensions differ");
        std::unique_ptr<DngReader> second;
        if (argc == 4) {
            second = std::make_unique<DngReader>(argv[3]);
            if (second->width != dng.width || second->height != dng.height)
                throw std::runtime_error("DNG dimensions differ");
        }

        std::vector<float> secondRow;
        if (second) secondRow.resize(dng.row.size());
        uint32_t maxError = 0, maxRgb8 = 0, secondMaxRgb8 = 0;
        long double errorSum = 0;
        const uint64_t pixels = static_cast<uint64_t>(dng.width) * dng.height * 3;
        for (uint32_t y = 0; y < dng.height; ++y) {
            dng.readRow(y);
            if (second) { second->readRow(y); secondRow = second->row; }
            for (size_t i = 0; i < dng.row.size(); ++i) {
                const uint16_t actual = png.pixels.get()[static_cast<size_t>(y) * dng.row.size() + i];
                const uint32_t expected = encode16(dng.row[i]);
                const uint32_t error = expected > actual ? expected - actual : actual - expected;
                maxError = std::max(maxError, error);
                errorSum += error;
                const uint32_t png8 = pngTo8(actual);
                const uint32_t dng8 = encode8(dng.row[i]);
                maxRgb8 = std::max(maxRgb8, dng8 > png8 ? dng8 - png8 : png8 - dng8);
                if (second) {
                    const uint32_t first8 = encode8(dng.row[i]);
                    const uint32_t other8 = encode8(secondRow[i]);
                    secondMaxRgb8 = std::max(secondMaxRgb8,
                        first8 > other8 ? first8 - other8 : other8 - first8);
                }
            }
        }
        std::cout << dng.width << 'x' << dng.height
                  << " max65535=" << maxError
                  << " mean65535=" << static_cast<double>(errorSum / pixels)
                  << " maxRGB8=" << static_cast<double>(maxError) / 257.0
                  << " maxQuantizedRGB8=" << maxRgb8;
        if (second) std::cout << " secondMaxRGB8=" << secondMaxRgb8;
        std::cout << '\n';
        if (maxError > 257 || (second && secondMaxRgb8 > 2))
            throw std::runtime_error("pixel comparison exceeded acceptance threshold");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
