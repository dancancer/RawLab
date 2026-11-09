#include "sony2fuji/raw_processor.h"
#include <libraw/libraw.h>

#include <array>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

using Crop = std::array<unsigned, 4>;

std::vector<unsigned char> sonyMetadata(const Crop& active, const Crop& camera,
                                       bool cameraFirst = false, bool hasDefault = true,
                                       bool previewIFD = false) {
    constexpr unsigned width = 960, height = 640, pixels = 2048;
    std::vector<unsigned char> bytes(pixels + width * height * 2, 0);
    auto word = [&](size_t offset, uint16_t value) {
        bytes.at(offset) = value; bytes.at(offset + 1) = value >> 8;
    };
    auto dword = [&](size_t offset, uint32_t value) {
        word(offset, value); word(offset + 2, value >> 16);
    };
    bytes[0] = bytes[1] = 'I'; word(2, 42); dword(4, 8);
    size_t entry = 10;
    unsigned count = 0;
    auto tag = [&](unsigned id, unsigned type, unsigned length, uint32_t value) {
        word(entry, id); word(entry + 2, type); dword(entry + 4, length);
        dword(entry + 8, value); entry += 12; ++count;
    };
    constexpr char model[] = "ILCE-7CM2";
    tag(256, 4, 1, width); tag(257, 4, 1, height); tag(258, 3, 1, 16);
    tag(259, 3, 1, 1); tag(262, 3, 1, 32803);
    tag(271, 2, 5, 512); tag(272, 2, sizeof(model), 528);
    tag(273, 4, 1, pixels); tag(277, 3, 1, 1); tag(278, 4, 1, height);
    tag(279, 4, 1, width * height * 2);
    tag(33421, 3, 2, 0x00020002); tag(33422, 1, 4, 0x02010100);
    std::memcpy(bytes.data() + 512, "SONY", 5);
    std::memcpy(bytes.data() + 528, model, sizeof(model));
    for (unsigned i = 0; i < 4; ++i) {
        dword(576 + i * 4, active[i]);
        dword(608 + i * 4, camera[i]);
    }
    auto defaults = [&] {
        if (hasDefault) { tag(0xc61f, 4, 2, 576); tag(0xc620, 4, 2, 584); }
    };
    auto privateCrop = [&] { tag(0x74c7, 4, 2, 608); tag(0x74c8, 4, 2, 616); };
    if (cameraFirst) { privateCrop(); defaults(); }
    else { defaults(); privateCrop(); }
    word(8, count);
    if (previewIFD) {
        // 另一个 IFD 的 DefaultCrop 不能成为 RAW 的有效区。
        dword(entry, 1024);
        entry = 1026; count = 0;
        tag(256, 4, 1, 32); tag(257, 4, 1, 24); tag(258, 3, 1, 8);
        tag(259, 3, 1, 1); tag(262, 3, 1, 2); tag(277, 3, 1, 3);
        tag(273, 4, 1, bytes.size()); tag(279, 4, 1, 32 * 24 * 3);
        tag(0xc61f, 4, 2, 1536); tag(0xc620, 4, 2, 1544);
        dword(1544, 32); dword(1548, 24);
        word(1024, count);
        bytes.resize(bytes.size() + 32 * 24 * 3);
    }
    return bytes;
}

void metadataCrop(const Crop& active, const Crop& camera, const Crop& expected,
                  bool cameraFirst = false, bool hasDefault = true, bool previewIFD = false) {
    auto bytes = sonyMetadata(active, camera, cameraFirst, hasDefault, previewIFD);
    auto raw = std::make_unique<LibRaw>();
    require(raw->open_buffer(bytes.data(), bytes.size()) == LIBRAW_SUCCESS,
            "Synthetic Sony TIFF must identify");
    require(raw->imgdata.idata.maker_index == LIBRAW_CAMERAMAKER_Sony && !raw->imgdata.idata.dng_version,
            "Regression must exercise the non-DNG Sony path");
    raw->adjust_to_raw_inset_crop(3);
    const auto& size = raw->imgdata.sizes;
    require(Crop{size.left_margin, size.top_margin, size.width, size.height} == expected,
            "Sony active area must prefer valid DefaultCrop regardless of camera aspect or tag order");
}

void metadataCases() {
    const Crop active{12, 8, 900, 600};
    for (const Crop camera : {Crop{62, 8, 800, 600}, Crop{12, 55, 900, 506},
                              Crop{162, 8, 600, 600}, active}) {
        metadataCrop(active, camera, active);
        metadataCrop(active, camera, active, true);
    }
    // 相机声明的有效区可以更小，甚至不是精确 3:2；不得套用固定机型尺寸或比例。
    metadataCrop({100, 80, 600, 400}, {134, 80, 532, 400}, {100, 80, 600, 400});
    metadataCrop({12, 8, 896, 600}, {60, 8, 800, 600}, {12, 8, 896, 600});
    const Crop camera{62, 8, 800, 600};
    metadataCrop(active, camera, camera, false, false);
    metadataCrop({12, 8, 0, 600}, camera, camera);
    metadataCrop({100, 8, 900, 600}, camera, camera);
    metadataCrop({12, 100, 900, 600}, camera, camera);
    metadataCrop(active, camera, active, false, true, true);
}

void sonyPhoto(const char* path) {
    using namespace sony2fuji;
    RAWProcessor raw;
    require(raw.loadFile(path) == ErrorCode::Success, "Sony aspect-ratio fixture must load");
    require(raw.getCameraModel() == "ILCE-7CM2", "Fixture must be the Sony ILCE-7CM2 4:3 regression photo");
    std::cout << "Loaded " << raw.getWidth() << 'x' << raw.getHeight() << '\n';
    require(raw.getWidth() == 7008 && raw.getHeight() == 4672,
            "Sony 4:3 camera crop must retain the 7008x4672 active RAW area");

    RAWProcessOptions options;
    ImageData image;
    require(raw.process(options, image) == ErrorCode::Success, "Full-size RAW must render");
    require(image.width == 7008 && image.height == 4672, "Full render must retain the 3:2 frame");
    image = {};
    options.halfSize = true;
    require(raw.process(options, image) == ErrorCode::Success, "Half-size RAW must render");
    require(image.width == 3504 && image.height == 2336, "Half-size preview must retain the 3:2 frame");
    image = {};
    options.halfSize = false;
    options.useCameraWhiteBalance = false;
    options.useTemperatureWhiteBalance = true;
    options.temperature = 5000;
    require(raw.process(options, image) == ErrorCode::Success, "White-balance update must render");
    require(image.width == 7008 && image.height == 4672, "White-balance update must preserve the active area");
    image = {};

    RAWProcessor hdr;
    int width = 0, height = 0;
    uint64_t pixels = 0;
    require(hdr.inspectCameraHDR(path, width, height, pixels) == ErrorCode::Success,
            "HDR metadata inspection must accept the Sony RAW");
    require(width == 7008 && height == 4672, "HDR inspection and actual decoding must use the same active area");
    require(hdr.unpackInspectedCameraHDR() == ErrorCode::Success, "Inspected HDR source must unpack");
    require(hdr.getWidth() == width && hdr.getHeight() == height,
            "Deferred HDR unpack must preserve the inspected active area");
}
}

int main(int argc, char** argv) {
    try {
        if (argc == 2) sonyPhoto(argv[1]);
        else metadataCases();
        std::cout << "PASS RAW active area\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
