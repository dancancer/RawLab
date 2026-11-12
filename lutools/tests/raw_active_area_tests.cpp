#include "sony2fuji/raw_processor.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include <libraw/libraw.h>

#include <array>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
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

void savedCrop(const char* path, uint32_t legacyWidth, uint32_t fullWidth, uint32_t height) {
    sony2fuji_session* handle = nullptr;
    require(sony2fuji_session_create(&handle) == SONY2FUJI_STATUS_OK, "Create crop test session");
    const std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>
        session(handle, sony2fuji_session_destroy);
    const sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    require(sony2fuji_session_set_gpu_config(handle, &gpu) == SONY2FUJI_STATUS_OK, "Use CPU");
    const sony2fuji_geometry_config geometry{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(geometry),
        .25f, 0, .5f, 1, 0, 0, 0, 0};
    require(sony2fuji_session_set_geometry(handle, &geometry) == SONY2FUJI_STATUS_OK, "Apply saved 50% crop");
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.brightness = request.contrast = request.saturation = 1;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE;
    request.long_edge = 128;
    auto render = [&](sony2fuji_processing_version version, uint32_t expectedWidth) {
        require(sony2fuji_session_set_processing_version(handle, version) == SONY2FUJI_STATUS_OK,
                "Set saved processing version");
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_process(handle, &request, &buffer);
        sony2fuji_release_buffer(&buffer);
        require(status == SONY2FUJI_STATUS_OK, "Render saved Sony crop");
        uint32_t width = 0, actualHeight = 0;
        require(sony2fuji_session_get_geometry_size(handle, &width, &actualHeight) == SONY2FUJI_STATUS_OK,
                "Read native cropped size");
        std::cout << "Processing v" << version << ": " << width << 'x' << actualHeight << '\n';
        require(width == expectedWidth && actualHeight == height, "Saved crop must use its processing version's canvas");
    };
    render(SONY2FUJI_PROCESSING_C5_V2, legacyWidth);
    sony2fuji_processing_migration_result result{};
    require(sony2fuji_session_migrate_processing(handle, &request, &result) == SONY2FUJI_STATUS_UNSUPPORTED,
            "Automatic adjustment migration must leave a different Sony canvas alone");
    render(SONY2FUJI_PROCESSING_BASIC_V3, fullWidth);
    render(SONY2FUJI_PROCESSING_C5_V2, legacyWidth);
}

void savedHdrCrop(const char* path, uint32_t legacyWidth, uint32_t fullWidth, uint32_t height) {
    sony2fuji_session* handle = nullptr;
    require(sony2fuji_session_create(&handle) == SONY2FUJI_STATUS_OK, "Create HDR crop test session");
    const std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>
        session(handle, sony2fuji_session_destroy);
    const sony2fuji_hdr_decode_options_v1 decode{SONY2FUJI_HDR_VERSION, sizeof(decode), SONY2FUJI_INTENT_PREVIEW, 128};
    sony2fuji_hdr_request_v1 settings{};
    settings.version = SONY2FUJI_HDR_VERSION; settings.struct_size = sizeof(settings);
    settings.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_VERSION; settings.intent = SONY2FUJI_INTENT_PREVIEW;
    settings.temperature = 6500;
    settings.crop_x = .25f; settings.crop_width = .5f; settings.crop_height = 1; settings.long_edge = 128;
    struct Pair {
        sony2fuji_hdr_image_pair_v1 value{SONY2FUJI_HDR_VERSION, sizeof(value)};
        ~Pair() { sony2fuji_hdr_release_pair(&value); }
    };
    auto render = [&](uint32_t expectedWidth) {
        Pair source, cropped;
        require(sony2fuji_hdr_decode_camera_raw(handle, path, &decode, &source.value, nullptr) == SONY2FUJI_STATUS_OK &&
                source.value.native_width == expectedWidth && source.value.native_height == height, "HDR decode uses the saved canvas");
        require(sony2fuji_hdr_render(handle, &source.value, &settings, &cropped.value, nullptr) == SONY2FUJI_STATUS_OK &&
                cropped.value.output_native_width == expectedWidth / 2 && cropped.value.output_native_height == height,
                "HDR crop uses the saved canvas");
    };
    sony2fuji_hdr_source_info_v1 defaults{SONY2FUJI_HDR_VERSION, sizeof(defaults)};
    require(sony2fuji_hdr_probe_camera_raw(path, &defaults, nullptr) == SONY2FUJI_STATUS_OK &&
            defaults.width == legacyWidth && defaults.height == height, "Unversioned HDR probe uses the Legacy canvas");
    Pair sessionless;
    require(sony2fuji_hdr_decode_camera_raw(nullptr, path, &decode, &sessionless.value, nullptr) == SONY2FUJI_STATUS_OK,
            "HDR decode with a null session failed");
    std::cout << "Unversioned HDR probe " << defaults.width << 'x' << defaults.height
              << ", null-session decode " << sessionless.value.native_width << 'x' << sessionless.value.native_height << '\n';
    require(sessionless.value.native_width == defaults.width && sessionless.value.native_height == defaults.height,
            "Sessionless HDR decode must match the unversioned probe");
    render(legacyWidth);
    for (const auto version : {SONY2FUJI_PROCESSING_C5_V2, SONY2FUJI_PROCESSING_BASIC_V3}) {
        const uint32_t expectedWidth = version == SONY2FUJI_PROCESSING_C5_V2 ? legacyWidth : fullWidth;
        sony2fuji_hdr_source_info_v1 info{SONY2FUJI_HDR_VERSION, sizeof(info)};
        require(sony2fuji_hdr_probe_camera_raw_with_processing(path, version, &info, nullptr) == SONY2FUJI_STATUS_OK &&
                info.width == expectedWidth && info.height == height, "HDR probe reports the saved canvas");
        require(sony2fuji_session_set_processing_version(handle, version) == SONY2FUJI_STATUS_OK, "Set HDR canvas");
        render(expectedWidth);
    }
}

void syntheticSavedCrop() {
    const auto bytes = sonyMetadata({12, 8, 900, 600}, {62, 8, 800, 600});
    const auto suffix = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto path = std::filesystem::temp_directory_path() / ("rawlab-sony-crop-" + std::to_string(suffix) + ".arw");
    struct Cleanup {
        std::filesystem::path path;
        ~Cleanup() { std::error_code ignored; std::filesystem::remove(path, ignored); }
    } cleanup{path};
    std::ofstream file(path, std::ios::binary);
    file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    file.close();
    require(bool(file), "Write synthetic Sony crop fixture");
    const auto input = path.u8string();
    savedCrop(input.c_str(), 400, 450, 600);
    savedHdrCrop(input.c_str(), 800, 900, 600);
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
    savedCrop(path, 3112, 3504, 4672);
    savedHdrCrop(path, 6224, 7008, 4672);
}
}

int main(int argc, char** argv) {
    try {
        if (argc == 2) {
            const char* path = *argv[1] ? argv[1] : std::getenv("RAWLAB_TEST_SONY_ASPECT_RAW");
            if (!path || !*path || !std::filesystem::exists(std::filesystem::u8path(path))) {
                std::cout << "SKIP raw_active_area_sony: supply SONY2FUJI_TEST_SONY_ASPECT_RAW or RAWLAB_TEST_SONY_ASPECT_RAW\n";
                return 77;
            }
            sonyPhoto(path);
        } else { metadataCases(); syntheticSavedCrop(); }
        std::cout << "PASS RAW active area\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
