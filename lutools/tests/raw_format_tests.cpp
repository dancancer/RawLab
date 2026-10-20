#include <libraw/libraw.h>
#include <algorithm>
#include <cstdint>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "core/stb_image_write.h"

namespace {
void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}

std::vector<unsigned char> jpegDng() {
    std::vector<unsigned char> pixels(32 * 32 * 3), jpeg;
    for (unsigned y = 0; y < 32; ++y) for (unsigned x = 0; x < 32; ++x) {
        const auto p = (y * 32 + x) * 3;
        pixels[p] = x * 7; pixels[p + 1] = y * 7; pixels[p + 2] = 64;
    }
    auto append = [](void* context, void* data, int size) {
        auto& output = *static_cast<std::vector<unsigned char>*>(context);
        const auto* first = static_cast<unsigned char*>(data);
        output.insert(output.end(), first, first + size);
    };
    require(stbi_write_jpg_to_func(append, &jpeg, 32, 32, 3, pixels.data(), 95), "Encode test JPEG");
    std::vector<unsigned char> bytes(2048, 0);
    auto word = [&](size_t offset, uint16_t value) {
        bytes.at(offset) = value; bytes.at(offset + 1) = value >> 8;
    };
    auto dword = [&](size_t offset, uint32_t value) {
        word(offset, value); word(offset + 2, value >> 16);
    };
    bytes[0] = bytes[1] = 'I'; word(2, 42); dword(4, 8);
    size_t entry = 10; unsigned tags = 0;
    auto tag = [&](unsigned id, unsigned type, unsigned count, uint32_t value) {
        word(entry, id); word(entry + 2, type); dword(entry + 4, count);
        dword(entry + 8, value); entry += 12; ++tags;
    };
    constexpr char model[] = "JPEG DNG regression";
    tag(256, 4, 1, 32); tag(257, 4, 1, 32); tag(258, 3, 3, 512);
    tag(259, 3, 1, 34892); tag(262, 3, 1, 34892);
    tag(271, 2, 7, 520); tag(272, 2, sizeof(model), 550);
    tag(273, 4, 1, 2048); tag(277, 3, 1, 3); tag(278, 4, 1, 32);
    tag(279, 4, 1, static_cast<uint32_t>(jpeg.size())); tag(284, 3, 1, 1);
    tag(50706, 1, 4, 0x00000401); tag(50707, 1, 4, 0x00000101);
    tag(50708, 2, sizeof(model), 550); tag(50717, 3, 1, 255);
    tag(50721, 10, 9, 600); tag(50728, 5, 3, 680); tag(50778, 3, 1, 21);
    word(8, tags);
    for (unsigned c = 0; c < 3; ++c) word(512 + c * 2, 8);
    std::memcpy(bytes.data() + 520, "RawLab", 7);
    std::memcpy(bytes.data() + 550, model, sizeof(model));
    for (unsigned i = 0; i < 9; ++i) { dword(600 + i * 8, i % 4 == 0 ? 1 : 0); dword(604 + i * 8, 1); }
    for (unsigned c = 0; c < 3; ++c) { dword(680 + c * 8, 1); dword(684 + c * 8, 1); }
    bytes.insert(bytes.end(), jpeg.begin(), jpeg.end());
    return bytes;
}

void develop(LibRaw& raw, const std::string& name) {
    const auto status = raw.unpack();
    require(status == LIBRAW_SUCCESS && raw.error_count() == 0,
        name + " must fully unpack: " + libraw_strerror(status));
    raw.imgdata.params.use_camera_wb = 1;
    raw.imgdata.params.no_auto_bright = 1;
    require(raw.dcraw_process() == LIBRAW_SUCCESS, name + " must develop RGB pixels");
    auto* image = raw.dcraw_make_mem_image();
    require(image && image->type == LIBRAW_IMAGE_BITMAP && image->data_size > 0,
        name + " must return developed pixels");
    const auto range = std::minmax_element(image->data, image->data + image->data_size);
    const bool detail = *range.first < *range.second;
    LibRaw::dcraw_clear_mem(image);
    require(detail, name + " must contain photo detail");
    std::cout << "PASS full decode/development: " << name << '\n';
}

void externalPhotos(const char* directory) {
    struct Photo { const char* path; const char* model; unsigned width, height; int matrix00 = 0; };
    const Photo photos[] = {
        {"6598fd78ac45f0d142e5685eff02b7b202be67ff6a51c7d857e8d17a70b4a9d5.x3f", "DP2 Merrill", 4807, 3205},
        {"e89f40df6881bbf60a83e56eee92d04f71b89e9ff55d6ff5d498afd4590cfcb3.x3f", "dp2 Quattro", 5446, 3624},
        {"159326856c29073e845c3c5a9ecf98c6474f43ca15798a88ad5e2baecd0664b7.dng", "EOS 5D Mark III", 5760, 3840},
        {"b22f1e36331f679abb8b13e433b9bbde3988723adf10fee7aa0dda6381016a98.dng", "EOS 5D Mark III", 3960, 2640},
        {"raw-pixls-20261019/7def3c8d80537f79af199052c6e13d86750203122dcb94888ada65291dabb793.ARW", "ILCE-1M2", 8660, 5784, 10058},
        {"raw-pixls-20261019/33ec5187659f8af4589113afbd138ec8d1cd14f6999d36a12de87ad5d8c7d439.ARW", "ILCE-1M2", 8660, 5784, 10058},
        {"raw-pixls-20261019/dfc66d4a6175378074bddf7deeb15f591083be1cb9fea1ccb7bac3c888db6e49.ARW", "ILCE-1M2", 5628, 3756, 10058},
        {"raw-pixls-20261019/bfe5113d3a6bc237ed0852a23d99da1c9733eb3f63056e362f40450fdd9644f8.ARW", "ILCE-1M2", 8660, 5784, 10058},
        {"raw-pixls-20261019/955ff98710505498ce7f98cbcc5875793ef2d6941b3b5692ed3baf2817ee7c9f.CR3", "EOS R50 V", 6000, 4000, 9089},
        {"raw-pixls-20261019/0a0abfd81b3a34fa513ac8ed24c809275160d65b07e892c2eb4353b77c535a31.CR3", "PowerShot V1", 5759, 3839, 12600},
    };
    for (const auto& photo : photos) {
        const auto path = std::filesystem::u8path(directory) / std::filesystem::u8path(photo.path);
        auto raw = std::make_unique<LibRaw>();
        require(raw->open_file(path.u8string().c_str()) == LIBRAW_SUCCESS, std::string(photo.model) + " must open");
        require(std::strstr(raw->imgdata.idata.model, photo.model) != nullptr, "External fixture model must match");
        if (photo.matrix00) require(std::abs(raw->imgdata.color.cam_xyz[0][0] - photo.matrix00 / 10000.f) < 0.00001f,
            std::string(photo.model) + " must use its own upstream color matrix");
        require(raw->imgdata.sizes.width == photo.width && raw->imgdata.sizes.height == photo.height,
            std::string(photo.model) + " active-area dimensions must match the upstream crop");
        develop(*raw, photo.path);
    }
}
}

int main(int argc, char** argv) {
    try {
        auto bytes = jpegDng();
        auto raw = std::make_unique<LibRaw>();
        require(raw->open_buffer(bytes.data(), bytes.size()) == LIBRAW_SUCCESS,
            "Synthetic JPEG-compressed DNG must open");
        require(raw->unpack_function_name() &&
            std::strcmp(raw->unpack_function_name(), "lossy_dng_load_raw()") == 0,
            "Synthetic DNG must exercise the real JPEG decoder");
        develop(*raw, "synthetic JPEG DNG");
        if (argc == 2) externalPhotos(argv[1]);
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
