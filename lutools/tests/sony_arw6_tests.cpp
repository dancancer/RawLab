#include "sony_arw6_fixture.h"
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
    return sony_arw6_fixture::arw6Tiff(64, 32, std::vector<unsigned char>(640), compression);
}

int unpackStatus(const std::vector<unsigned char>& bytes) {
    auto raw = std::make_unique<LibRaw>();
    require(raw->open_buffer(bytes.data(), bytes.size()) == LIBRAW_SUCCESS, "Synthetic ARW6 must open");
    require(raw->unpack_function_name() &&
        std::strcmp(raw->unpack_function_name(), "sony_arw6_load_raw()") == 0,
        "Synthetic ARW6 must select the ARW6 decoder");
    return raw->unpack();
}

void checkSyntheticStreams() {
    // 对齐高度与需要保护行的高度都必须仍能完整解码，防止新增边界检查误拒正常码流。
    for (int rows : {32, 18, 50})
        require(unpackStatus(sony_arw6_fixture::tiledArw6(64, rows)) == LIBRAW_SUCCESS,
            "Well-formed synthetic ARW6 tiles must decode");
    require(unpackStatus(sony_arw6_fixture::tiledArw6(16, 2)) != LIBRAW_SUCCESS,
        "Tiles without a low-frequency row must be rejected before reconstruction");
    int rejected = 0;
    for (int rows : {32, 18, 50})
        sony_arw6_fixture::sweepLargeCoefficients(rows, [&](const std::vector<unsigned char>& bytes) {
            const int status = unpackStatus(bytes);
            require(status == LIBRAW_SUCCESS || status == LIBRAW_IO_ERROR,
                "Large ARW6 coefficients must decode or fail as corrupt data");
            rejected += status == LIBRAW_IO_ERROR;
        });
    require(rejected > 0, "Reconstruction values outside int32 must reject the stream");
    std::cout << "PASS ARW6 synthetic tiles, short-tile refusal and " << rejected
              << " out-of-range reconstructions refused\n";
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
        checkSyntheticStreams();
        if (argc == 2) checkPhoto(argv[1]);
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
