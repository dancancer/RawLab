#include "png16_decoder.h"
#include <array>
#include <cassert>
#include <filesystem>
#include <fstream>
#include <vector>
#include <zlib.h>

using Bytes = std::vector<unsigned char>;
static void number(Bytes& bytes, uint32_t value) {
    for (int shift : {24, 16, 8, 0}) bytes.push_back((value >> shift) & 255);
}
static void chunk(Bytes& png, const char* type, const Bytes& bytes) {
    number(png, static_cast<uint32_t>(bytes.size()));
    const auto start = png.size();
    png.insert(png.end(), type, type + 4);
    png.insert(png.end(), bytes.begin(), bytes.end());
    number(png, crc32(0, png.data() + start, static_cast<uInt>(png.size() - start)));
}
static Bytes fixture(bool rgba = false, uint16_t alpha = 65535, bool interlaced = false) {
    Bytes png{137, 80, 78, 71, 13, 10, 26, 10};
    Bytes header;
    number(header, 2); number(header, 3);
    header.insert(header.end(), {16, static_cast<unsigned char>(rgba ? 6 : 2), 0, 0,
        static_cast<unsigned char>(interlaced)});
    chunk(png, "IHDR", header);
    chunk(png, "sRGB", {0});
    Bytes raw;
    const std::array<int, 7> xs{0, 4, 0, 2, 0, 1, 0}, ys{0, 0, 4, 0, 2, 0, 1};
    const std::array<int, 7> dx{8, 8, 4, 4, 2, 2, 1}, dy{8, 8, 8, 4, 4, 2, 2};
    for (int pass = 0; pass < (interlaced ? 7 : 1); ++pass) {
        const int startX = interlaced ? xs[pass] : 0, startY = interlaced ? ys[pass] : 0;
        if (startX >= 2) continue;
        for (int y = startY; y < 3; y += interlaced ? dy[pass] : 1) {
            raw.push_back(0);
            for (int x = startX; x < 2; x += interlaced ? dx[pass] : 1) {
                for (uint16_t value : {uint16_t(0x1234 + (y * 2 + x) * 16), uint16_t(0x5678), uint16_t(0x7a01)}) {
                    raw.push_back(value >> 8); raw.push_back(value & 255);
                }
                if (rgba) { raw.push_back(alpha >> 8); raw.push_back(alpha & 255); }
            }
        }
    }
    Bytes compressed(compressBound(raw.size()));
    uLongf size = compressed.size();
    assert(compress2(compressed.data(), &size, raw.data(), raw.size(), 6) == Z_OK);
    compressed.resize(size);
    chunk(png, "IDAT", compressed); chunk(png, "IEND", {});
    return png;
}
template<class F> static void rejects(F operation) {
    bool rejected = false;
    try { operation(); } catch (const std::exception&) { rejected = true; }
    assert(rejected);
}
int main(int argc, char** argv) {
    assert(argc == 2);
    const std::filesystem::path path = std::filesystem::path(argv[1]) / "generated-png16.png";
    auto write = [&](const Bytes& bytes) {
        std::ofstream output(path, std::ios::binary);
        output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    };
    const std::array<std::array<int, 6>, 8> positions{{
        {0, 1, 2, 3, 4, 5}, {1, 0, 3, 2, 5, 4}, {5, 4, 3, 2, 1, 0}, {4, 5, 2, 3, 0, 1},
        {0, 2, 4, 1, 3, 5}, {4, 2, 0, 5, 3, 1}, {5, 3, 1, 4, 2, 0}, {1, 3, 5, 0, 2, 4}}};
    for (bool interlaced : {false, true}) for (bool rgba : {false, true}) {
        write(fixture(rgba, 65535, interlaced));
        for (int orientation = 1; orientation <= 8; ++orientation) {
            auto pixels = rawlab::decodePng16(path.c_str(), 2, 3, orientation);
            for (int i = 0; i < 6; ++i) {
                assert(pixels.get()[i * 4] == 0x1234 + positions[orientation - 1][i] * 16);
                assert(pixels.get()[i * 4 + 1] == 0x5678);
                assert(pixels.get()[i * 4 + 2] == 0x7a01);
                assert(pixels.get()[i * 4 + 3] == 65535);
            }
        }
    }
    write(fixture(true, 65534));
    rejects([&] { rawlab::decodePng16(path.c_str(), 2, 3, 1); });
    write(fixture());
    rejects([&] { rawlab::decodePng16(path.c_str(), 3, 2, 1); });
    rejects([&] { rawlab::decodePng16(path.c_str(), 2, 3, 9); });
    rejects([&] { rawlab::decodePng16(path.c_str(), 16001, 8000, 1); });
    auto eightBit = fixture(); eightBit[24] = 8; write(eightBit);
    rejects([&] { rawlab::decodePng16(path.c_str(), 2, 3, 1); });
    auto truncated = fixture(); truncated.resize(50); write(truncated);
    rejects([&] { rawlab::decodePng16(path.c_str(), 2, 3, 1); });
    std::filesystem::remove(path);
}
