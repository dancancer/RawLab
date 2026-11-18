#include "core/jpeg_mpf.h"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {
using Bytes = std::vector<uint8_t>;

void put(Bytes& bytes, size_t offset, uint32_t value, size_t width, bool littleEndian = true) {
    for (size_t index = 0; index < width; ++index) {
        bytes[offset + index] = static_cast<uint8_t>(value >> (8 * (littleEndian ? index : width - 1 - index)));
    }
}

Bytes jpeg(uint16_t width = 5184, uint16_t height = 3888) {
    Bytes bytes {0xff, 0xd8, 0xff, 0xc0, 0, 17, 8, 0, 0, 0, 0, 3, 1, 0x21, 0, 2, 0x11, 1, 3, 0x11, 1,
                 0xff, 0xda, 0, 12, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 63, 0,
                 1, 2, 0xff, 0, 3, 0xff, 0xd0, 4, 0xff, 0xd9};
    put(bytes, 7, height, 2, false);
    put(bytes, 9, width, 2, false);
    return bytes;
}

struct Fixture {
    Bytes bytes;
    size_t primaryEnd = 0;
    std::vector<size_t> thumbnailStarts;
};

Fixture makeMpf(uint32_t attributes = 0xa0030000, std::vector<uint32_t> types = {0x010002},
                bool littleEndian = true, bool vendorTail = false, uint16_t thumbnailWidth = 480) {
    Bytes bytes(2 + 4 + 54 + (types.size() + 1) * 16);
    bytes[0] = 0xff; bytes[1] = 0xd8; bytes[2] = 0xff; bytes[3] = 0xe2;
    put(bytes, 4, static_cast<uint32_t>(bytes.size() - 4), 2, false);
    bytes[6] = 'M'; bytes[7] = 'P'; bytes[8] = 'F';
    bytes[10] = bytes[11] = littleEndian ? 'I' : 'M';
    auto word = [&](size_t p, uint16_t value) { put(bytes, p, value, 2, littleEndian); };
    auto number = [&](size_t p, uint32_t value) { put(bytes, p, value, 4, littleEndian); };
    word(12, 42); number(14, 8); word(18, 3);
    word(20, 0xb000); word(22, 7); number(24, 4);
    bytes[28] = '0'; bytes[29] = '1'; bytes[30] = '0'; bytes[31] = '0';
    word(32, 0xb001); word(34, 4); number(36, 1); number(40, static_cast<uint32_t>(types.size() + 1));
    word(44, 0xb002); word(46, 7); number(48, static_cast<uint32_t>((types.size() + 1) * 16)); number(52, 50);

    const auto primary = jpeg();
    const auto thumbnail = jpeg(thumbnailWidth, 360);
    bytes.insert(bytes.end(), primary.begin() + 2, primary.end());
    const size_t primaryEnd = bytes.size();
    number(60, attributes); number(64, static_cast<uint32_t>(primaryEnd)); word(72, 2);
    if (types.size() == 2) word(74, 3);
    std::vector<size_t> starts;
    for (size_t index = 0; index < types.size(); ++index) {
        bytes.insert(bytes.end(), 17, 0x31);
        starts.push_back(bytes.size());
        const size_t entry = 76 + index * 16;
        number(entry, 0x40000000 | types[index]);
        number(entry + 4, static_cast<uint32_t>(thumbnail.size()));
        number(entry + 8, static_cast<uint32_t>(bytes.size() - 10));
        bytes.insert(bytes.end(), thumbnail.begin(), thumbnail.end());
    }
    if (vendorTail) {
        bytes.insert(bytes.end(), {0xdc, 0xff, 0x00, 0x36, 0x73});
        bytes.insert(bytes.end(), 396, 0x2a);
    }
    return {std::move(bytes), primaryEnd, std::move(starts)};
}

class TestFile {
public:
    TestFile() : path_(fs::temp_directory_path() / ("rawlab-mpf-test-" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".jpg")) {}
    ~TestFile() {
        std::error_code error;
        fs::remove(path_, error);
    }

    void expect(const Bytes& bytes, int expected, const char* description) const {
        std::ofstream file(path_, std::ios::binary);
        file.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        file.close();
        if (!file) throw std::runtime_error("could not write JPEG fixture");
        const int actual = sony2fuji::inspectSdrJpegMpf(path_);
        if (actual != expected) {
            throw std::runtime_error(std::string(description) + " expected " +
                std::to_string(expected) + " got " + std::to_string(actual));
        }
    }

private:
    fs::path path_;
};
}

int main(int argc, char** argv) {
    try {
        const TestFile test;
        test.expect(makeMpf(0x80030000, {0x010002}, true, true, 1440).bytes, 2,
                    "Panasonic-style JPEG without representative bit and with a vendor trailer");
        test.expect(makeMpf(0x80030000).bytes, 2, "representative flag is optional independently of trailer");
        test.expect(makeMpf(0xa0030000, {0x010002}, true, true).bytes, 2, "MPF accepts a non-JPEG trailer");
        auto withoutIndex = jpeg();
        test.expect(withoutIndex, 0, "ordinary single JPEG has no MPF index");
        withoutIndex.insert(withoutIndex.begin() + 2, {0xff, 0xe2, 0, 6, 'M', 'P', 'F', 0});
        test.expect(withoutIndex, -1, "MPF declaration without an index");
        for (const bool littleEndian : {false, true}) {
            test.expect(makeMpf(0xa0030000, {0x010001}, littleEndian).bytes, 2, "VGA thumbnail in either byte order");
            test.expect(makeMpf(0xa0030000, {0x010002}, littleEndian).bytes, 2, "HD thumbnail in either byte order");
            test.expect(makeMpf(0xa0030000, {0x010002, 0x010001}, littleEndian).bytes, 3, "both thumbnail classes");
            auto shifted = makeMpf(0xa0030000, {0x010002}, littleEndian);
            // APP1 before MPF moves the TIFF base without changing its internal offsets.
            constexpr size_t shift = 9;
            shifted.bytes.insert(shifted.bytes.begin() + 2, {0xff, 0xe1, 0, 7, 'E', 'x', 'i', 'f', 0});
            put(shifted.bytes, 64 + shift, static_cast<uint32_t>(shifted.primaryEnd + shift), 4, littleEndian);
            test.expect(shifted.bytes, 2, "MPEntry offsets remain relative to a relocated TIFF header");
            auto badOffset = shifted.bytes;
            put(badOffset, 84 + shift,
                static_cast<uint32_t>(shifted.thumbnailStarts.front() + shift), 4, littleEndian);
            test.expect(badOffset, -1, "absolute auxiliary offset is not a TIFF-relative offset");
            auto badCount = shifted.bytes;
            put(badCount, 18 + shift, 8, 2, littleEndian);
            test.expect(badCount, -1, "IFD entry count extends past APP2");
            auto badTableSize = shifted.bytes;
            put(badTableSize, 48 + shift, 31, 4, littleEndian);
            test.expect(badTableSize, -1, "MPEntry byte count must match the number of images");
        }
        for (uint32_t type : {0u, 0x050000u, 0x020002u}) {
            test.expect(makeMpf(0xa0030000, {type}).bytes, -1, "unknown, gain map, or stereo auxiliary image");
        }
        test.expect(makeMpf(0xa0030000, {0x010002, 0x010002}).bytes, -1, "duplicate thumbnail class");
        test.expect(makeMpf(0xa0030000, {0x010002}, true, false, 2000).bytes, -1, "oversized thumbnail");

        const auto valid = makeMpf();
        auto malformed = [&](size_t offset, uint32_t value, size_t width, const char* description) {
            auto bytes = valid.bytes;
            put(bytes, offset, value, width);
            test.expect(bytes, -1, description);
        };
        malformed(40, 1, 4, "missing auxiliary entry");
        malformed(40, 4, 4, "too many auxiliary entries");
        malformed(84, UINT32_MAX, 4, "thumbnail starts beyond EOF");
        malformed(84, static_cast<uint32_t>(valid.primaryEnd - 11), 4, "overlapping JPEG ranges");
        malformed(64, static_cast<uint32_t>(valid.primaryEnd - 1), 4, "primary EOI outside indexed range");
        malformed(52, UINT32_MAX, 4, "MPEntry table outside APP2");
        malformed(56, 50, 4, "unexpected extra attribute directory");
        malformed(60, 0x20030000, 4, "primary is missing the parent flag");
        malformed(60, 0xc0030000, 4, "unexpected child flag on primary");
        malformed(76, 0x00010002, 4, "thumbnail is missing the child flag");
        malformed(72, 1, 2, "primary depends on itself");
        malformed(72, 2u << 16, 4, "single thumbnail must be the first dependency");
        malformed(valid.thumbnailStarts.front(), 0, 1, "thumbnail has no SOI");
        malformed(valid.bytes.size() - 1, 0, 1, "thumbnail has no EOI");
        test.expect(Bytes(valid.bytes.begin(), valid.bytes.end() - 3), -1, "truncated thumbnail");
        test.expect(Bytes(valid.bytes.begin(), valid.bytes.begin() + 50), -1, "truncated MPF segment");

        auto appended = valid.bytes;
        const auto unindexed = jpeg(4, 3);
        appended.insert(appended.end(), unindexed.begin(), unindexed.end());
        test.expect(appended, -1, "unindexed JPEG immediately after MPF ranges");
        auto duplicate = valid.bytes;
        duplicate.insert(duplicate.begin() + 2, valid.bytes.begin() + 2, valid.bytes.begin() + 92);
        test.expect(duplicate, -1, "duplicate MPF index");
        auto declaredPastEoi = valid.bytes;
        put(declaredPastEoi, 64, static_cast<uint32_t>(valid.primaryEnd + 2), 4);
        declaredPastEoi[valid.primaryEnd] = 0xff;
        declaredPastEoi[valid.primaryEnd + 1] = 0xd9;
        test.expect(declaredPastEoi, -1, "later EOI in gap cannot extend primary JPEG");

        if (argc > 1 && sony2fuji::inspectSdrJpegMpf(fs::u8path(argv[1])) != 2) {
            throw std::runtime_error("reported JPEG should contain an accepted MPF thumbnail");
        }
        std::cout << "PASS shared JPEG MPF validation\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
