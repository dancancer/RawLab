#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <libraw/libraw.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char **argv) {
    if (argc != 3) {
        std::cerr << "Usage: nikon_he_reference_tests input.NEF reference.pgm\n";
        return 2;
    }
    try {
        auto raw = std::make_unique<LibRaw>();
        if (raw->open_file(argv[1]) != LIBRAW_SUCCESS || raw->unpack() != LIBRAW_SUCCESS ||
            raw->error_count() || !raw->imgdata.rawdata.raw_image)
            throw std::runtime_error("LibRaw must unpack the original NEF successfully");
        const auto compression = raw->imgdata.makernotes.nikon.NEFCompression;
        if (compression != 13 && compression != 14)
            throw std::runtime_error("The fixture must use Nikon HE or HE*");
        std::ifstream reference(argv[2], std::ios::binary);
        std::string magic;
        size_t width = 0, height = 0, maximum = 0;
        reference >> magic >> width >> height >> maximum;
        if (magic != "P5" || maximum != 65535 || width != raw->imgdata.sizes.raw_width ||
            height != raw->imgdata.sizes.raw_height || reference.get() != '\n')
            throw std::runtime_error("Expected an unrotated 16-bit PGM sensor reference");
        const size_t stride = raw->imgdata.sizes.raw_pitch / sizeof(uint16_t);
        if (stride < width)
            throw std::runtime_error("Invalid LibRaw sensor stride");
        size_t changed = 0;
        unsigned maxError = 0;
        for (size_t y = 0; y < height; ++y)
            for (size_t x = 0; x < width; ++x) {
                const int hi = reference.get(), lo = reference.get();
                if (hi < 0 || lo < 0)
                    throw std::runtime_error("Truncated reference pixels");
                const int expected = (hi << 8) | lo;
                const int actual = raw->imgdata.rawdata.raw_image[y * stride + x];
                const unsigned error = actual < expected ? expected - actual : actual - expected;
                changed += error != 0;
                if (error > maxError)
                    maxError = error;
            }
        std::cout << raw->imgdata.idata.model << " compression=" << compression
                  << " samples=" << width * height << " changed=" << changed
                  << " max_abs=" << maxError << '\n';
        if (changed)
            return 1;
        std::ifstream input(argv[1], std::ios::binary);
        std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), {});
        const auto offset = size_t(raw->get_internal_data_pointer()->unpacker_data.data_offset);
        if (offset > bytes.size() || bytes.size() - offset < 80)
            throw std::runtime_error("Missing Nikon codestream");
        const auto *length = bytes.data() + offset + 42;
        const size_t lcod = (size_t(length[0]) << 24) | (size_t(length[1]) << 16) |
                            (size_t(length[2]) << 8) | length[3];
        if (lcod < 80 || lcod > bytes.size() - offset)
            throw std::runtime_error("Invalid test codestream length");
        auto invalid = std::make_unique<LibRaw>();
        bytes[offset + lcod - 1] ^= 1;
        if (invalid->open_buffer(bytes.data(), bytes.size()) != LIBRAW_SUCCESS ||
            invalid->unpack() != LIBRAW_DATA_ERROR)
            throw std::runtime_error(
                "Damaged HE pixels must report a decode error, not a path error");
        bytes[offset + lcod - 1] ^= 1;
        bytes[offset + 66] ^= 1;
        if (invalid->open_buffer(bytes.data(), bytes.size()) != LIBRAW_SUCCESS ||
            invalid->unpack() != LIBRAW_FILE_UNSUPPORTED)
            throw std::runtime_error("Unknown HE transfer must remain unsupported");
        if (invalid->open_file(argv[1]) != LIBRAW_SUCCESS)
            throw std::runtime_error("Cannot reopen memory-budget fixture");
        // 足够 LibRaw 分配原始像素，但不足以分配 HE 重建平面。
        invalid->imgdata.rawparams.max_raw_memory_mb =
            static_cast<unsigned>(width * height * 4 / (1024 * 1024) + 1);
        if (invalid->unpack() != LIBRAW_UNSUFFICIENT_MEMORY)
            throw std::runtime_error("HE decoding must respect LibRaw's memory budget");
        std::cout << "PASS: corrupt/unsupported/memory error categories\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
