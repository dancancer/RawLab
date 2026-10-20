#include "sony_arw6_fixture.h"
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
#include RAWLAB_ARW6_SOURCE

namespace {
// 直接调用本编译单元内带 UBSan 的解码器；open_buffer/unpack 会走动态库里未插桩的副本。
struct Arw6Harness : LibRaw {
    int decode(const std::vector<unsigned char>& bytes) {
        if (open_buffer(bytes.data(), bytes.size()) != LIBRAW_SUCCESS)
            throw std::runtime_error("Synthetic ARW6 must open");
        std::vector<ushort> pixels(size_t(raw_width) * raw_height);
        raw_image = pixels.data();
        int status = LIBRAW_SUCCESS;
        try { sony_arw6_load_raw(); }
        catch (LibRaw_exceptions error) { status = error == LIBRAW_EXCEPTION_IO_CORRUPT ? LIBRAW_IO_ERROR : -1; }
        raw_image = nullptr;
        return status;
    }
};

int decode(const std::vector<unsigned char>& bytes) {
    return std::make_unique<Arw6Harness>()->decode(bytes);
}

void checkHelpers() {
    const unsigned char signs[16] = {0x80};
    SonyArw6NativeBits bits(signs, sizeof(signs), 0, sizeof(signs));
    int32_t values[4] = {1073758208, 0, 0, 0};
    sony_arw6_apply_signs(bits, values);
    if (values[0] != -1073758208 || bits.status)
        throw std::runtime_error("Large positive coefficients must negate without overflow");
    const unsigned char oversized[16] = {
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    SonyArw6NativeBits malformed(oversized, sizeof(oversized), 0, sizeof(oversized));
    bool rejected = false;
    try { sony_arw6_decode_coeff_group(malformed, 19, 15, values); }
    catch (LibRaw_exceptions error) { rejected = error == LIBRAW_EXCEPTION_IO_CORRUPT; }
    if (!rejected) throw std::runtime_error("Out-of-range coefficient magnitudes must reject the stream");
    std::cout << "PASS ARW6 coefficient narrowing and sign arithmetic boundaries\n";
}

void checkContainers() {
    for (int rows : {32, 18, 50})
        if (decode(sony_arw6_fixture::tiledArw6(64, rows)) != LIBRAW_SUCCESS)
            throw std::runtime_error("Well-formed synthetic ARW6 tiles must decode");
    if (decode(sony_arw6_fixture::tiledArw6(16, 2)) != LIBRAW_IO_ERROR)
        throw std::runtime_error("Tiles without a low-frequency row must be rejected before reconstruction");
    int decoded = 0, rejected = 0;
    auto check = [&](const std::vector<unsigned char>& bytes) {
        const int status = decode(bytes);
        if (status != LIBRAW_SUCCESS && status != LIBRAW_IO_ERROR)
            throw std::runtime_error("Large ARW6 coefficients must decode or fail as corrupt data");
        ++(status == LIBRAW_SUCCESS ? decoded : rejected);
    };
    // 18/50 行走保护行重建分支，32 行走对齐分支；50 行才会执行高位优先逆变换的中间行。
    for (int rows : {32, 18, 50}) {
        sony_arw6_fixture::sweepLargeCoefficients(rows, check);
        sony_arw6_fixture::randomLargeCoefficients(rows, 2000, check);
    }
    if (!decoded || !rejected)
        throw std::runtime_error("Coefficient sweep must cover both accepted and refused reconstructions");
    std::cout << "PASS ARW6 container-to-pixel reconstruction: " << decoded << " decoded, "
              << rejected << " refused without undefined behavior\n";
}
} // namespace

int main() {
    try {
        checkHelpers();
        checkContainers();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
