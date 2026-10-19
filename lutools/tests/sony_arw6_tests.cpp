#include <libraw/libraw.h>
#include <algorithm>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

std::vector<unsigned char> malformedArw6(unsigned compression = 32766) {
    // 合成容器只验证解码器分派和损坏流拒绝，不使用个人照片或内嵌 JPEG。
    std::vector<unsigned char> bytes(1024 + 640, 0);
    auto word = [&](size_t offset, uint16_t value) {
        bytes.at(offset) = static_cast<unsigned char>(value);
        bytes.at(offset + 1) = static_cast<unsigned char>(value >> 8);
    };
    auto dword = [&](size_t offset, uint32_t value) {
        word(offset, static_cast<uint16_t>(value));
        word(offset + 2, static_cast<uint16_t>(value >> 16));
    };
    bytes[0] = bytes[1] = 'I'; word(2, 42); dword(4, 8);
    word(8, 14);
    size_t entry = 10;
    auto tag = [&](unsigned id, unsigned type, unsigned count, uint32_t value) {
        word(entry, id); word(entry + 2, type); dword(entry + 4, count);
        dword(entry + 8, value); entry += 12;
    };
    tag(256, 4, 1, 64); tag(257, 4, 1, 32); tag(258, 3, 1, 14);
    tag(259, 3, 1, compression); tag(262, 3, 1, 32803);
    tag(271, 2, 5, 512); tag(272, 2, 9, 520);
    tag(273, 4, 1, 1024); tag(274, 3, 1, 1); tag(277, 3, 1, 1);
    tag(278, 4, 1, 32); tag(279, 4, 1, 640);
    tag(33421, 3, 2, 0x00020002); tag(33422, 1, 4, 0x02010100);
    std::memcpy(bytes.data() + 512, "SONY", 5);
    std::memcpy(bytes.data() + 520, "ILCE-7M5", 9);
    return bytes;
}

void checkDispatch() {
    auto bytes = malformedArw6();
    auto raw = std::make_unique<LibRaw>();
    const auto status = raw->open_buffer(bytes.data(), bytes.size());
    require(status == LIBRAW_SUCCESS, "Sony Compression=32766 must be identified as RAW");
    require(raw->unpack_function_name() &&
        std::strcmp(raw->unpack_function_name(), "sony_arw6_load_raw()") == 0,
        "Sony Compression=32766 must select the ARW6 decoder");
    require(raw->imgdata.color.black == 1024 && raw->imgdata.color.maximum == 39002,
        "ARW6 must use the corrected upstream black and white levels");
    require(std::abs(raw->imgdata.color.cam_xyz[0][0] - 0.9089f) < 0.00001f,
        "ILCE-7M5 must use its upstream color matrix");
    require(raw->unpack() != LIBRAW_SUCCESS, "Malformed ARW6 packets must fail decoding");
    auto invalid = malformedArw6(65000);
    const auto invalidStatus = raw->open_buffer(invalid.data(), invalid.size());
    require(invalidStatus != LIBRAW_SUCCESS || !raw->unpack_function_name() ||
        std::strcmp(raw->unpack_function_name(), "sony_arw6_load_raw()") != 0,
        "Unknown Sony compression must not enter the ARW6 decoder");
    std::cout << "PASS ARW6 identification, decoder selection, levels and malformed-stream refusal\n";
}

void checkPhoto(const char* path) {
    auto raw = std::make_unique<LibRaw>();
    require(raw->open_file(path) == LIBRAW_SUCCESS, "External Sony ARW6 photo must open");
    require(std::strcmp(raw->imgdata.idata.model, "ILCE-7M5") == 0,
        "External regression photo must be the supplied ILCE-7M5 RAW");
    require(raw->unpack_function_name() &&
        std::strcmp(raw->unpack_function_name(), "sony_arw6_load_raw()") == 0,
        "External photo must decode RAW pixels through ARW6");
    require(raw->unpack() == LIBRAW_SUCCESS && raw->error_count() == 0,
        "External ARW6 photo must fully unpack without decoder errors");
    require(raw->imgdata.rawdata.raw_image != nullptr, "ARW6 must produce Bayer pixels");
    const auto count = size_t(raw->imgdata.sizes.raw_width) * raw->imgdata.sizes.raw_height;
    const auto range = std::minmax_element(raw->imgdata.rawdata.raw_image,
        raw->imgdata.rawdata.raw_image + count);
    require(*range.second > *range.first, "ARW6 pixel output must contain image detail");
    raw->imgdata.params.use_camera_wb = 1;
    raw->imgdata.params.no_auto_bright = 1;
    raw->imgdata.params.output_bps = 16;
    require(raw->dcraw_process() == LIBRAW_SUCCESS, "External ARW6 photo must develop");
    require(raw->imgdata.sizes.width == 7028 && raw->imgdata.sizes.height == 4688,
        "Supplied ILCE-7M5 photo must apply the upstream active-area crop");
    std::cout << "PASS supplied ILCE-7M5 ARW6 unpack and 7028x4688 development\n";
}
}

int main(int argc, char** argv) {
    try {
        checkDispatch();
        if (argc == 2) checkPhoto(argv[1]);
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
