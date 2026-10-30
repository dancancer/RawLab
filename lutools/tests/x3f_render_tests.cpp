#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/raw_processor.h"
#include "core/processing_cancellation.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>
#include <chrono>
#include <filesystem>
#include <fstream>

namespace {
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
using Session = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;
Session session() {
    sony2fuji_session* result = nullptr;
    require(sony2fuji_session_create(&result) == SONY2FUJI_STATUS_OK, "create session");
    sony2fuji_gpu_config gpu{};
    gpu.version = SONY2FUJI_GPU_CONFIG_VERSION; gpu.struct_size = sizeof(gpu);
    gpu.mode = SONY2FUJI_GPU_OFF;
    require(sony2fuji_session_set_gpu_config(result, &gpu) == SONY2FUJI_STATUS_OK, "CPU mode");
    return Session(result, sony2fuji_session_destroy);
}
struct Render { uint32_t width, height; std::vector<uint8_t> pixels; };
struct TemporaryDirectory {
    std::filesystem::path path;
    TemporaryDirectory() : path(std::filesystem::temp_directory_path() /
        ("rawlab-x3f-test-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()))) {
        require(std::filesystem::create_directory(path), "create test workspace");
    }
    ~TemporaryDirectory() { std::error_code error; std::filesystem::remove_all(path, error); }
};
Render render(sony2fuji_session* s, const char* path, sony2fuji_x3f_mode mode, float ev = 0) {
    require(sony2fuji_session_set_x3f_mode(s, mode) == SONY2FUJI_STATUS_OK, "set X3F mode");
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path;
    request.wb_mode = SONY2FUJI_WB_CAMERA; request.temperature = 6500;
    std::fill(std::begin(request.wb_mul), std::end(request.wb_mul), 1);
    request.brightness = request.contrast = request.saturation = 1;
    request.exposure_ev = ev;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_process(s, &request, &buffer);
    if (status != SONY2FUJI_STATUS_OK) {
        throw std::runtime_error(std::string(sony2fuji_status_message(status)) + ": " + sony2fuji_session_x3f_error(s));
    }
    const auto* bytes = static_cast<const uint8_t*>(buffer.data);
    Render result{buffer.width, buffer.height, std::vector<uint8_t>(bytes, bytes + buffer.size_bytes)};
    sony2fuji_release_buffer(&buffer);
    return result;
}

void replacedSource(const char* source) {
    std::ifstream original(std::filesystem::u8path(source), std::ios::binary);
    unsigned char header[232]{};
    original.read(reinterpret_cast<char*>(header), sizeof(header));
    if (!original || header[4] != 2 || header[6] != 2) return;
    TemporaryDirectory temp;
    const auto input = temp.path / "source.X3F", replacement = temp.path / "replacement.X3F";
    std::filesystem::copy_file(source, input);
    const auto stamp = std::filesystem::last_write_time(input);
    const auto size = std::filesystem::file_size(input);
    auto cached = session();
    const auto before = render(cached.get(), input.u8string().c_str(), SONY2FUJI_X3F_NORMAL);
    std::filesystem::copy_file(input, replacement);
    std::filesystem::permissions(replacement, std::filesystem::perms::owner_write, std::filesystem::perm_options::add);
    int slot = -1;
    for (int i = 0; i < 32; ++i) if (header[72 + i] == 1) slot = i;
    require(slot >= 0, "fixture has saved exposure");
    uint32_t bits = 0;
    for (int i = 0; i < 4; ++i) bits |= uint32_t(header[104 + slot * 4 + i]) << (8 * i);
    float exposure; std::memcpy(&exposure, &bits, sizeof(bits)); exposure += .25f;
    std::memcpy(&bits, &exposure, sizeof(bits));
    unsigned char value[4]; for (int i = 0; i < 4; ++i) value[i] = bits >> (8 * i);
    {
        std::fstream edit(replacement, std::ios::binary | std::ios::in | std::ios::out);
        edit.seekp(104 + slot * 4); edit.write(reinterpret_cast<const char*>(value), 4);
        require(bool(edit), "modify only temporary copy");
    }
    std::error_code replaceError;
    std::filesystem::remove(input, replaceError);
#ifdef _WIN32
    // LibRaw 的 Windows 流没有 FILE_SHARE_DELETE；此平台不能制造打开期间的同路径替换。
    if (replaceError.value() == 32) {
        std::cout << "SKIP same-path replacement: Windows LibRaw input denies file deletion while open\n";
        return;
    }
#endif
    require(!replaceError, "remove temporary source for replacement");
    std::filesystem::rename(replacement, input);
    std::filesystem::last_write_time(input, stamp);
    require(std::filesystem::file_size(input) == size && std::filesystem::last_write_time(input) == stamp,
            "replacement retains size and timestamp");
    const auto after = render(cached.get(), input.u8string().c_str(), SONY2FUJI_X3F_NORMAL);
    auto fresh = session();
    const auto expected = render(fresh.get(), input.u8string().c_str(), SONY2FUJI_X3F_NORMAL);
    require(after.pixels != before.pixels && after.pixels == expected.pixels, "source replacement invalidates decode cache");
    std::cout << "PASS same-path same-size same-mtime X3F replacement\n";
}

void cancellation(const char* source) {
    sony2fuji::RAWProcessor processor;
    require(processor.loadFile(source) == sony2fuji::ErrorCode::Success, "load cancellation fixture");
    const auto started = std::chrono::steady_clock::now();
    const auto callback = [](void* context) -> int32_t {
        const auto start = *static_cast<const std::chrono::steady_clock::time_point*>(context);
        return std::chrono::steady_clock::now() - start >= std::chrono::milliseconds(75);
    };
    bool cancelled = false;
    sony2fuji::ImageData output;
    {
        sony2fuji::ProcessingCancellationScope scope({callback, const_cast<std::chrono::steady_clock::time_point*>(&started)});
        sony2fuji::RAWProcessOptions options; options.x3fMode = sony2fuji::X3fMode::Normal;
        try { processor.process(options, output); } catch (const sony2fuji::ProcessingCancelled&) { cancelled = true; }
    }
    const auto milliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
    require(cancelled && output.pixels.empty(), "in-flight native cancellation does not publish pixels");
    require(milliseconds < 2000, "native cancellation must reach the decoder promptly");
    std::cout << "PASS native X3F cancellation " << milliseconds << " ms\n";
}

void formatIdentity() {
    const auto fixture = std::filesystem::path(__FILE__).parent_path() / "fixtures" / "linear-uncompressed.dng";
    TemporaryDirectory temp;
    const auto disguised = temp.path / "incorrect.X3F";
    std::filesystem::copy_file(fixture, disguised);
    sony2fuji::RAWProcessor processor;
    require(processor.loadFile(disguised.u8string()) == sony2fuji::ErrorCode::Success, "LibRaw recognizes renamed DNG");
    sony2fuji::RAWProcessOptions options; options.x3fMode = sony2fuji::X3fMode::Normal;
    sony2fuji::ImageData image;
    require(processor.process(options, image) == sony2fuji::ErrorCode::InvalidFormat && image.pixels.empty(),
            "an X3F name cannot silently select a different decoder in normal mode");
    require(processor.loadFile(fixture.u8string()) == sony2fuji::ErrorCode::Success, "ordinary DNG still loads");
    require(processor.process(options, image) == sony2fuji::ErrorCode::Success, "X3F mode does not override other RAW formats");
    const auto normal = image.pixels;
    options.x3fMode = sony2fuji::X3fMode::Legacy;
    require(processor.process(options, image) == sony2fuji::ErrorCode::Success, "ordinary DNG legacy mode");
    require(normal.size() == image.pixels.size() &&
            std::memcmp(normal.data(), image.pixels.data(), normal.size() * sizeof(sony2fuji::RGB)) == 0,
            "non-X3F pixels remain unchanged");
}

void errorSemantics(const char* path) {
    auto s = session();
    require(sony2fuji_session_set_x3f_mode(s.get(), SONY2FUJI_X3F_NORMAL) == SONY2FUJI_STATUS_OK, "normal error probe");
    sony2fuji_lens_correction_config lens{};
    lens.version = SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION; lens.struct_size = sizeof(lens); lens.distortion = 1;
    require(sony2fuji_session_set_lens_correction(s.get(), &lens) == SONY2FUJI_STATUS_OK, "lens error probe");
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    request.wb_mode = SONY2FUJI_WB_CAMERA; request.temperature = 6500;
    request.brightness = request.contrast = request.saturation = 1;
    std::fill(std::begin(request.wb_mul), std::end(request.wb_mul), 1);
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 32;
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(s.get(), &request, &buffer) == SONY2FUJI_STATUS_UNSUPPORTED, "normal lens rejection");
    require(std::string(sony2fuji_session_x3f_error(s.get())).find("lens") != std::string::npos, "normal lens error is specific");
    float ev = 0; request.version = 0;
    require(sony2fuji_session_estimate_auto_exposure(s.get(), &request, &ev) == SONY2FUJI_STATUS_INVALID_ARGUMENT, "invalid meter request");
    require(std::strlen(sony2fuji_session_x3f_error(s.get())) == 0, "meter failure does not reuse a previous X3F error");
}
}

int main(int argc, char** argv) {
    try {
        auto s = session();
        require(sony2fuji_session_set_x3f_mode(nullptr, SONY2FUJI_X3F_NORMAL) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "null setter rejected");
        require(sony2fuji_session_set_x3f_mode(s.get(), static_cast<sony2fuji_x3f_mode>(99)) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "unknown mode rejected");
        formatIdentity();
        if (argc == 1) {
            std::cout << "PASS X3F mode validation; real RAW coverage requires explicit fixture arguments\n";
            return 0;
        }
        require(sony2fuji_x3f_available() == 1, "normal decoder included");
        errorSemantics(argv[1]);
        for (int i = 1; i < argc; ++i) {
            const auto legacy = render(s.get(), argv[i], SONY2FUJI_X3F_LEGACY);
            const auto normal = render(s.get(), argv[i], SONY2FUJI_X3F_NORMAL);
            const auto restored = render(s.get(), argv[i], SONY2FUJI_X3F_LEGACY);
            require(legacy.width == restored.width && legacy.height == restored.height && legacy.pixels == restored.pixels,
                    "legacy pixels survive a mode round trip");
            auto fresh = session();
            const auto repeat = render(fresh.get(), argv[i], SONY2FUJI_X3F_NORMAL);
            require(normal.width == repeat.width && normal.height == repeat.height && normal.pixels == repeat.pixels,
                    "normal cache matches a fresh session");
            require(normal.pixels != legacy.pixels, "normal mode changes actual decoded color");

            sony2fuji::RAWProcessor processor;
            require(processor.loadFile(argv[i]) == sony2fuji::ErrorCode::Success, "direct RAW load");
            sony2fuji::RAWProcessOptions options;
            options.x3fMode = sony2fuji::X3fMode::Normal;
            options.outputLinear = false;
            options.outputBitsPerSample = 8;
            sony2fuji::ImageData direct;
            require(processor.process(options, direct) == sony2fuji::ErrorCode::Success, "direct normal output");
            require(processor.isDisplayReferred(), "normal output declares display reference");
            require(direct.width == normal.width && direct.height == normal.height, "native crop and orientation agree");
            const auto channels = normal.pixels.size() / direct.pixels.size();
            int maximum = 0;
            for (size_t n = 0; n < direct.pixels.size(); ++n) {
                const auto& p = direct.pixels[n];
                const float values[] = {p.r, p.g, p.b};
                for (int c = 0; c < 3; ++c) maximum = std::max(maximum,
                    std::abs(int(std::lround(values[c] * 255)) - int(normal.pixels[n * channels + c])));
            }
            require(maximum <= 1, "shared workflow must not apply another neutral display curve");
            if (i == 1) {
                sony2fuji::RAWProcessor identified;
                require(identified.loadFile(argv[i], sony2fuji::X3fMode::Normal) == sony2fuji::ErrorCode::Success,
                        "normal X3F identification without duplicate unpack");
                sony2fuji::ImageData identifiedNormal, identifiedLegacy, referenceLegacy;
                require(identified.process(options, identifiedNormal) == sony2fuji::ErrorCode::Success,
                        "metadata-only normal process");
                auto equal = [](const auto& a, const auto& b) {
                    return a.width == b.width && a.height == b.height && a.pixels.size() == b.pixels.size() &&
                        std::equal(a.pixels.begin(), a.pixels.end(), b.pixels.begin(), [](const auto& x, const auto& y) {
                            return x.r == y.r && x.g == y.g && x.b == y.b;
                        });
                };
                require(equal(direct, identifiedNormal), "metadata-only normal pixels remain exact");
                options.x3fMode = sony2fuji::X3fMode::Legacy;
                require(identified.process(options, identifiedLegacy) == sony2fuji::ErrorCode::Success &&
                        processor.process(options, referenceLegacy) == sony2fuji::ErrorCode::Success,
                        "legacy mode lazily unpacks the identified source");
                require(equal(identifiedLegacy, referenceLegacy), "lazy legacy pixels remain exact");
                std::cout << "PASS metadata-only X3F load and lazy legacy round trip\n";
            }
            const auto brighter = render(fresh.get(), argv[i], SONY2FUJI_X3F_NORMAL, 1);
            require(brighter.pixels != normal.pixels, "relative exposure participates in normal workflow");
            std::cout << "PASS native X3F workflow " << argv[i] << " " << normal.width << "x" << normal.height
                      << " display rounding max=" << maximum << '\n';
        }
        replacedSource(argv[1]);
        cancellation(argv[1]);
        return 0;
    } catch (const std::exception& e) { std::cerr << "FAIL " << e.what() << '\n'; return 1; }
}
