#include "sony2fuji/dcp_look.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <vector>
#ifdef SONY2FUJI_ENABLE_METAL
#include "gpu/photo_gpu.h"
#endif

namespace fs = std::filesystem;
using sony2fuji::DcpLook;
using sony2fuji::RGB;
using Bytes = std::vector<unsigned char>;
int failures = 0;

void check(bool ok, const char* label) {
    std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
    if (!ok) ++failures;
}

void integer(Bytes& bytes, uint64_t value, size_t count) {
    for (size_t i = 0; i < count; ++i) bytes.push_back(static_cast<unsigned char>(value >> (i * 8)));
}

template<class T> void floating(Bytes& bytes, T value) {
    uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(T));
    integer(bytes, bits, sizeof(T));
}

Bytes fixture(float hue = 0, float scale = 1, uint32_t encoding = 0, bool squareTone = false) {
    Bytes bytes{'R','L','O','O','K','D','C','P'};
    for (uint32_t value : {1u, 0u, encoding, 2u, 2u, 2u, 4097u, 2u}) integer(bytes, value, 4);
    for (int matrix = 0; matrix < 2; ++matrix)
        for (int i = 0; i < 9; ++i) floating(bytes, i % 4 == 0 ? 1.0 : 0.0);
    floating(bytes, 1.0);
    for (int v = 0; v < 2; ++v) for (int h = 0; h < 2; ++h) for (int s = 0; s < 2; ++s) {
        floating(bytes, hue); floating(bytes, 1.0f); floating(bytes, s ? scale : 1.0f);
    }
    for (int i = 0; i <= 4096; ++i) {
        double x = i / 4096.0;
        floating(bytes, squareTone ? x * x : x);
    }
    bytes.push_back('{'); bytes.push_back('}');
    return bytes;
}

Bytes fixtureV2(bool withLook = true, uint32_t calibrationEncoding = 0) {
    const auto base = fixture(120, calibrationEncoding ? .6f : 1.0f);
    Bytes bytes(base.begin(), base.begin() + 40);
    bytes[8] = 2;
    if (!withLook) std::fill(bytes.begin() + 16, bytes.begin() + 32, 0);
    for (uint32_t value : {calibrationEncoding, 2u, 2u, 2u}) integer(bytes, value, 4);
    bytes.insert(bytes.end(), base.begin() + 40, base.begin() + 192);
    bytes.insert(bytes.end(), base.begin() + 192, base.begin() + 288);
    if (withLook) for (int v = 0; v < 2; ++v) for (int h = 0; h < 2; ++h) for (int s = 0; s < 2; ++s) {
        floating(bytes, h ? 90.0f : 0.0f); floating(bytes, 1.0f); floating(bytes, 1.0f);
    }
    bytes.insert(bytes.end(), base.begin() + 288, base.end());
    return bytes;
}

void save(const fs::path& path, const Bytes& bytes) {
    std::ofstream stream(path, std::ios::binary);
    stream.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
}

double encode(double x) { return x <= .0031308 ? 12.92 * x : 1.055 * std::pow(x, 1 / 2.4) - .055; }
bool near(float actual, double expected) { return std::abs(actual - expected) <= 2e-6; }

void mathTests(const fs::path& root) {
    const auto path = root / "identity.rlook";
    save(path, fixture());
    auto look = DcpLook::loadCached(path.u8string());
    check(look != nullptr, "load native profile");
    if (!look) return;
    check(look == DcpLook::loadCached(path.u8string()), "immutable native profile cache hit");
    const auto identity = look->apply(RGB(.18f, .3f, .6f));
    check(near(identity.r, encode(.18f)) && near(identity.g, encode(.3f)) && near(identity.b, encode(.6f)),
          "identity stages and output transfer");
    const auto clipped = look->apply(RGB(-1, 2, 0));
    check(clipped.r == 0 && clipped.g == 1 && clipped.b == 0, "SDR stage clamp");
    auto changed = fixture(120);
    save(path, changed);
    fs::last_write_time(path, fs::last_write_time(path) + std::chrono::seconds(2));
    auto rotated = DcpLook::loadCached(path.u8string());
    check(rotated && rotated != look, "changed profile invalidates cache");
    if (rotated) {
        auto value = rotated->apply(RGB(.5f, 0, 0));
        check(near(value.r, 0) && near(value.g, encode(.5)) && near(value.b, 0), "hue shift uses degrees");
    }
    check(near(look->apply(RGB(.5f, 0, 0)).r, encode(.5)), "retained cached profile remains immutable");
    const auto encodedPath = root / "encoded.rlook";
    save(encodedPath, fixture(0, .5f, 1));
    auto encoded = DcpLook::loadCached(encodedPath.u8string());
    check(encoded && near(encoded->apply(RGB(.25f, 0, 0)).r, encode(.25) * .5), "value scale in encoded domain");
    const auto tonePath = root / "tone.rlook";
    save(tonePath, fixture(0, 1, 0, true));
    auto tone = DcpLook::loadCached(tonePath.u8string());
    if (tone) {
        auto value = tone->apply(RGB(.75f, .5f, .25f));
        check(near(value.r, encode(.5625)) && near(value.g, encode(.3125)) && near(value.b, encode(.0625)),
              "tone preserves middle channel position");
    } else check(false, "load tone profile");
    const auto wrapPath = root / "wrap.rlook";
    save(wrapPath, fixture(-1e-17f));
    auto wrapped = DcpLook::loadCached(wrapPath.u8string());
    check(wrapped && near(wrapped->apply(RGB(.5f, 0, 0)).r, encode(.5)), "tiny negative hue wraps safely");
    for (bool withLook : {false, true}) {
        const auto v2path = root / (withLook ? "v2-both.rlook" : "v2-calibration.rlook");
        save(v2path, fixtureV2(withLook));
        auto v2 = DcpLook::loadCached(v2path.u8string());
        check(v2 != nullptr, "load native v2 calibration stages");
        if (v2) {
            const auto result = v2->apply(RGB(.5f, 0, 0));
            check(near(result.r, 0) && near(withLook ? result.b : result.g, encode(.5)),
                  "v2 applies HSM and optional look exactly once");
        }
    }
}

void malformedTests(const fs::path& root) {
    std::vector<Bytes> cases;
    const auto valid = fixture();
    cases.push_back(Bytes(valid.begin(), valid.begin() + 12));
    cases.push_back(Bytes(valid.begin(), valid.end() - 1));
    cases.push_back(valid); cases.back().push_back(0);
    for (auto entry : std::vector<std::pair<size_t, uint32_t>>{{8,3},{12,1},{16,2},{20,0},{24,1},
             {28,0},{20,4000001},{32,4096},{36,65537}}) {
        auto bytes = valid;
        for (int i = 0; i < 4; ++i) bytes[entry.first + i] = (entry.second >> (i * 8)) & 255;
        cases.push_back(bytes);
    }
    for (size_t offset : {40u, 112u, 184u, 288u}) {
        auto bytes = valid;
        Bytes nan; floating(nan, std::numeric_limits<double>::quiet_NaN());
        std::copy(nan.begin(), nan.end(), bytes.begin() + offset);
        cases.push_back(bytes);
    }
    auto bytes = valid;
    Bytes negative; floating(negative, -1.0f);
    std::copy(negative.begin(), negative.end(), bytes.begin() + 196);
    cases.push_back(bytes);
    for (auto entry : std::vector<std::pair<size_t, uint32_t>>{{40,2},{44,0},{48,1},{52,0},{44,4000001}}) {
        auto bad = fixtureV2();
        for (int i = 0; i < 4; ++i) bad[entry.first + i] = (entry.second >> (i * 8)) & 255;
        cases.push_back(bad);
    }
    for (size_t i = 0; i < cases.size(); ++i) {
        const auto path = root / ("invalid-" + std::to_string(i) + ".rlook");
        save(path, cases[i]);
        check(!DcpLook::loadCached(path.u8string()), "reject malformed native profile");
    }
}

void photoTests(const fs::path& root) {
    const auto path = (root / "photo.rlook").u8string();
    save(fs::u8path(path), fixture());
    const unsigned char pixels[] = {32, 64, 96};
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = pixels;
    request.input_width = request.input_height = 1;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB; request.input_is_linear = 1;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_EXACT; request.target_width = request.target_height = 1;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500; request.lut_path = path.c_str(); request.lut_strength = 1;
    sony2fuji_session* session = nullptr;
    check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "create PHOTO session");
    if (!session) return;
    sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(sony2fuji_gpu_config), SONY2FUJI_GPU_OFF};
    sony2fuji_session_set_gpu_config(session, &config);
    auto render = [&](const char* label, std::array<unsigned char, 3>& result) {
        sony2fuji_buffer output{};
        const auto status = sony2fuji_process(session, &request, &output);
        check(status == SONY2FUJI_STATUS_OK, label);
        if (status == SONY2FUJI_STATUS_OK && output.data) std::memcpy(result.data(), output.data, 3);
        sony2fuji_release_buffer(&output);
        return status == SONY2FUJI_STATUS_OK;
    };
    std::array<unsigned char, 3> cpu{}, automatic{}, exposed{}, neutral{}, blended{};
    const bool cpuOk = render("PHOTO accepts compiled DCP", cpu);
    if (cpuOk) {
        for (int c = 0; c < 3; ++c)
            check(std::abs(cpu[c] - std::lround(encode(pixels[c] / 255.0f) * 255)) <= 1, "PHOTO skips RGB CUBE and double tone");
    }
    config.mode = SONY2FUJI_GPU_AUTO; sony2fuji_session_set_gpu_config(session, &config);
    const bool autoOk = render("PHOTO Auto renders compiled DCP", automatic);
    check(cpuOk && autoOk && cpu == automatic, "PHOTO Auto preserves native look output");
    config.mode = SONY2FUJI_GPU_FORCE; sony2fuji_session_set_gpu_config(session, &config);
    sony2fuji_buffer output{};
    const auto forced = sony2fuji_process(session, &request, &output);
    check(forced == SONY2FUJI_STATUS_PROCESSING_ERROR ||
          (forced == SONY2FUJI_STATUS_OK && sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_METAL),
          "PHOTO Force either uses Metal or fails explicitly");
    sony2fuji_release_buffer(&output);
    config.mode = SONY2FUJI_GPU_OFF; sony2fuji_session_set_gpu_config(session, &config);
    request.exposure_ev = 1;
    if (render("PHOTO exposure before native look", exposed))
        for (int c = 0; c < 3; ++c)
            check(std::abs(exposed[c] - std::lround(encode(pixels[c] / 255.0f * 2) * 255)) <= 1,
                  "PHOTO linear exposure applied once");
    request.exposure_ev = 0; request.lut_strength = 0; request.lut_path = "missing.rlook";
    render("PHOTO zero strength bypasses native file loading", neutral);
    request.lut_path = path.c_str(); request.lut_strength = .4f;
    if (render("PHOTO native strength blend", blended))
        for (int c = 0; c < 3; ++c)
            check(std::abs(blended[c] - std::lround(neutral[c] + .4 * (cpu[c] - neutral[c]))) <= 1,
                  "PHOTO blends in display RGB");
    request.lut_strength = 1; request.input_is_linear = 0;
    if (render("PHOTO display input is linearized", cpu))
        check(std::equal(cpu.begin(), cpu.end(), std::begin(pixels)), "PHOTO identity native stages preserve display input");
    auto extreme = fixture();
    Bytes number; floating(number, 1e38);
    std::copy(number.begin(), number.end(), extreme.begin() + 40);
    number.clear(); floating(number, 65536.0);
    std::copy(number.begin(), number.end(), extreme.begin() + 184);
    const auto extremePath = (root / "extreme.rlook").u8string();
    save(fs::u8path(extremePath), extreme);
    request.lut_path = extremePath.c_str();
    config.mode = SONY2FUJI_GPU_AUTO; sony2fuji_session_set_gpu_config(session, &config);
    render("PHOTO Auto handles FP32 overflow via precise CPU", automatic);
    check(sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_CPU, "nonfinite Metal stage cannot report success");
    config.mode = SONY2FUJI_GPU_FORCE; sony2fuji_session_set_gpu_config(session, &config);
    check(sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_PROCESSING_ERROR, "Force rejects nonfinite Metal stage");
    sony2fuji_release_buffer(&output);
    request.lut_path = path.c_str();
    config.mode = SONY2FUJI_GPU_AUTO; sony2fuji_session_set_gpu_config(session, &config);
    render("valid profile recovers after nonfinite GPU stage", automatic);
    check(std::equal(automatic.begin(), automatic.end(), std::begin(pixels)), "failed GPU output does not leak into next render");
    check(forced != SONY2FUJI_STATUS_OK || sony2fuji_session_get_last_backend(session) == SONY2FUJI_BACKEND_METAL,
          "valid native profile can use Metal again after fallback");
    sony2fuji_session_destroy(session);
}

#ifdef SONY2FUJI_ENABLE_METAL
bool metal(const std::shared_ptr<const DcpLook>& look, const sony2fuji::ImageData& input, sony2fuji::ImageData& output) {
    sony2fuji_request request{};
    request.brightness = request.contrast = request.saturation = request.lut_strength = 1;
    request.temperature = 6500;
    return sony2fuji::renderPhotoMetal(input, sony2fuji::ColorSpace::sRGB, request, nullptr, RGB(1, 1, 1),
                                     input.width, input.height, output, look);
}

void metalTests(const fs::path& root) {
    sony2fuji::ImageData input(257, 1), output;
    for (size_t i = 0; i < input.pixels.size(); ++i)
        input.pixels[i] = RGB(float(i % 17) / 11 - .1f, float(i % 29) / 23, float(i % 31) / 17);
    const auto path = root / "metal.rlook";
    std::vector<RGB> first;
    for (const auto& bytes : {fixture(), fixture(15, .7f, 1, true), fixtureV2(), fixtureV2(false), fixtureV2(false, 1)}) {
        save(path, bytes);
        fs::last_write_time(path, fs::last_write_time(path) + std::chrono::seconds(2));
        auto look = DcpLook::loadCached(path.u8string());
        const bool rendered = look && metal(look, input, output);
        check(rendered, "native stages execute on actual Metal");
        if (!rendered) continue;
        double maximum = 0;
        for (size_t i = 0; i < input.pixels.size(); ++i) {
            auto expected = look->apply(input.pixels[i]);
            const auto actual = output.pixels[i];
            maximum = std::max({maximum, double(std::abs(expected.r - actual.r)),
                                double(std::abs(expected.g - actual.g)), double(std::abs(expected.b - actual.b))});
        }
        check(maximum <= 5e-5, "native Metal synthetic parity within 5e-5");
        if (first.empty()) first = output.pixels;
        else {
            bool changed = false;
            for (size_t i = 0; i < first.size(); ++i)
                changed |= std::abs(first[i].r - output.pixels[i].r) + std::abs(first[i].g - output.pixels[i].g) > .1f;
            check(changed, "native Metal cache uses updated stage data");
        }
    }
}
#endif

int evaluate(int argc, char** argv) {
    if (argc != 5) return 2;
    auto look = DcpLook::loadCached(argv[2]);
    if (!look) return 3;
    std::ifstream input(fs::u8path(argv[3]), std::ios::binary);
    std::ofstream output(fs::u8path(argv[4]), std::ios::binary);
    if (!input || !output) return 4;
    RGB value;
    static_assert(sizeof(RGB) == 12, "float RGB probe layout");
    const bool gpu = std::string(argv[1]) == "--evaluate-metal";
    std::vector<RGB> points;
    while (input.read(reinterpret_cast<char*>(&value), sizeof(value))) {
        if (!std::isfinite(value.r) || !std::isfinite(value.g) || !std::isfinite(value.b)) return 5;
        if (gpu) { points.push_back(value); continue; }
        value = look->apply(value);
        output.write(reinterpret_cast<const char*>(&value), sizeof(value));
    }
    if (gpu) {
#ifdef SONY2FUJI_ENABLE_METAL
        sony2fuji::ImageData image, result;
        image.width = static_cast<int>(points.size()); image.height = 1; image.pixels = std::move(points);
        if (!metal(look, image, result)) return 8;
        output.write(reinterpret_cast<const char*>(result.pixels.data()), result.pixels.size() * sizeof(RGB));
#else
        return 8;
#endif
    }
    return input.gcount() == 0 && output ? 0 : 6;
}

int main(int argc, char** argv) {
    if (argc > 1 && (std::string(argv[1]) == "--evaluate" || std::string(argv[1]) == "--evaluate-metal")) return evaluate(argc, argv);
    auto root = fs::temp_directory_path() / ("rawlab-dcp-" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::create_directory(root);
#ifdef SONY2FUJI_ENABLE_METAL
    if (argc > 1 && std::string(argv[1]) == "--metal") {
        metalTests(root);
        fs::remove_all(root);
        return failures ? 1 : 0;
    }
#endif
    mathTests(root);
    malformedTests(root);
    photoTests(root);
    fs::remove_all(root);
    return failures ? 1 : 0;
}
