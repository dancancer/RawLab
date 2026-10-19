#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void check(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}
void status(sony2fuji_status value) { check(value == SONY2FUJI_STATUS_OK, sony2fuji_status_message(value)); }

struct Session {
    sony2fuji_session* value = nullptr;
    Session(sony2fuji_gpu_mode mode) {
        status(sony2fuji_session_create(&value));
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), mode};
        status(sony2fuji_session_set_gpu_config(value, &gpu));
    }
    ~Session() { sony2fuji_session_destroy(value); }
};

struct Frame {
    uint32_t width = 0, height = 0, native_width = 0, native_height = 0;
    std::vector<unsigned char> pixels;
};

Frame render(Session& session, const sony2fuji_request& request, bool viewport) {
    status(sony2fuji_session_set_viewport_preview(session.value, viewport));
    sony2fuji_buffer buffer{};
    status(sony2fuji_process(session.value, &request, &buffer));
    Frame frame{buffer.width, buffer.height, 0, 0, {}};
    status(sony2fuji_session_get_geometry_size(session.value, &frame.native_width, &frame.native_height));
    const auto* bytes = static_cast<const unsigned char*>(buffer.data);
    const int channels = buffer.pixel_format == SONY2FUJI_PIXEL_RGBA8 ? 4 : 3;
    for (uint32_t y = 0; y < buffer.height; ++y)
        frame.pixels.insert(frame.pixels.end(), bytes + y * buffer.stride_bytes,
            bytes + y * buffer.stride_bytes + buffer.width * channels);
    sony2fuji_release_buffer(&buffer);
    if (request.output_target == SONY2FUJI_TARGET_FILE) {
        std::ifstream file(request.output_path, std::ios::binary);
        frame.pixels.assign(std::istreambuf_iterator<char>(file), {});
        check(!frame.pixels.empty(), "empty file output");
    }
    return frame;
}

sony2fuji_request requestFor() {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB; request.input_is_linear = 1;
    request.temperature = 6500; request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.brightness = request.contrast = request.saturation = 1;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE; request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}

sony2fuji_geometry_config geometry(int turn, int flips, int crop, int transform) {
    sony2fuji_geometry_config g{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(g), 0, 0, 1, 1,
        turn, flips & 1, (flips >> 1) & 1, 0};
    if (crop == 1) { g.crop_x = .125f; g.crop_y = .25f; g.crop_width = .5f; g.crop_height = .625f; }
    if (crop == 2) { g.crop_x = g.crop_y = .9f; g.crop_width = g.crop_height = .1f; }
    if (crop == 3) { g.crop_x = g.crop_y = .2f; g.crop_width = g.crop_height = .8000005f; }
    if (crop >= 4) {
        g.crop_x = g.crop_y = crop == 4 ? std::nextafter(1.f, 0.f) : 0;
        g.crop_width = g.crop_height = std::numeric_limits<float>::denorm_min();
    }
    if (transform == 1 || transform == 6) g.straighten_degrees = 3;
    if (transform == 2 || transform == 7) g.straighten_degrees = -45;
    if (transform == 3) g.straighten_degrees = 45;
    return g;
}

struct Comparison {
    std::fstream file;
    bool record;
    struct Metrics {
        size_t exact = 0, approximate = 0, changed = 0, count = 0;
        int maximum = 0;
        double absolute = 0, squared = 0;
    } metrics[2];
    int backend = 0;
    Comparison(const char* path, bool write) : file(path, std::ios::binary |
        (write ? std::ios::out | std::ios::trunc : std::ios::in)), record(write) {
        check(bool(file), "open baseline corpus");
    }
    void visit(Frame frame, bool reduced) {
        auto& m = metrics[backend];
        uint32_t dimensions[]{frame.width, frame.height, frame.native_width, frame.native_height};
        if (record) {
            file.write(reinterpret_cast<const char*>(dimensions), sizeof(dimensions));
            file.write(reinterpret_cast<const char*>(frame.pixels.data()), frame.pixels.size());
        } else {
            uint32_t expected[4]{};
            file.read(reinterpret_cast<char*>(expected), sizeof(expected));
            check(!std::memcmp(expected, dimensions, sizeof(expected)), "base output/native dimensions changed");
            std::vector<unsigned char> bytes(frame.pixels.size());
            file.read(reinterpret_cast<char*>(bytes.data()), bytes.size());
            check(bool(file), "truncated baseline corpus");
            if (!reduced) {
                check(bytes == frame.pixels, "base exact pixels changed at frame " + std::to_string(m.exact + m.approximate));
                ++m.exact;
            } else {
                ++m.approximate;
                if (bytes != frame.pixels) ++m.changed;
                for (size_t i = 0; i < bytes.size(); ++i) {
                    const int delta = std::abs(int(bytes[i]) - int(frame.pixels[i]));
                    m.maximum = std::max(m.maximum, delta); m.absolute += delta; m.squared += delta * delta; ++m.count;
                }
            }
        }
    }
    void finish() {
        if (record) { check(bool(file), "write corpus"); std::cout << "RECORDED baseline corpus\n"; return; }
        check(file.peek() == std::char_traits<char>::eof(), "unconsumed baseline frames");
        for (int mode = 0; mode < 2; ++mode) {
            const auto& m = metrics[mode];
            if (!m.exact) continue;
            const double mean = m.count ? m.absolute / m.count : 0;
            const double psnr = m.squared ? 10 * std::log10(255. * 255. * m.count / m.squared) : INFINITY;
            std::cout << "BASE " << (mode ? "GPU" : "CPU") << " exact=" << m.exact << " reduced=" << m.approximate
                      << " changed=" << m.changed << " max=" << m.maximum << " mean_abs=" << mean << " PSNR=" << psnr << " dB\n";
            /* 平滑测试图允许低分辨率裁剪边缘的一像素偏差，不接受大面积色调改变。 */
            check(m.maximum <= 32 && mean <= 2 && psnr >= 38, "viewport error exceeds smooth-fixture bound");
            check(m.changed > 0, "geometry viewport still bypassed");
        }
    }
};

void corpus(const char* path, bool record) {
    Comparison comparison(path, record);
    const bool gpu = rawlabtest::nativeGpuAvailable();
    if (!gpu) std::cout << "SKIP native GPU corpus: hardware unavailable\n";
    struct TemporaryOutput {
        std::filesystem::path path = std::filesystem::temp_directory_path() /
            ("rawlab-geometry-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
        ~TemporaryOutput() { std::error_code error; std::filesystem::remove(path, error); }
    } temporary;
    const auto outputPath = temporary.path.string();
    for (const auto mode : {SONY2FUJI_GPU_OFF, SONY2FUJI_GPU_AUTO}) {
        if (mode == SONY2FUJI_GPU_AUTO && !gpu) continue;
        comparison.backend = mode == SONY2FUJI_GPU_AUTO ? 1 : 0;
        Session session(mode);
        for (const auto size : {std::pair<int, int>{1, 1}, {1, 17}, {19, 1}, {3, 5}, {17, 11}, {31, 19}, {95, 67}}) {
            const int width = size.first, height = size.second;
            std::vector<unsigned char> pixels(width * height * 3);
            for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                const int offset = (y * width + x) * 3;
                pixels[offset] = 40 + 120 * x / width; pixels[offset + 1] = 40 + 120 * y / height;
                pixels[offset + 2] = 80 + int(20 * std::sin(3. * x / width) * std::cos(3. * y / height));
            }
            auto request = requestFor(); request.input_pixels = pixels.data();
            request.input_width = width; request.input_height = height;
            for (int turn = 0; turn < 4; ++turn) for (int flips = 0; flips < 4; ++flips)
                for (int crop = 0; crop < 6; ++crop) for (int transform = 0; transform < 8; ++transform) {
                    const auto g = geometry(turn, flips, crop, transform);
                    status(sony2fuji_session_set_geometry(session.value, &g));
                    sony2fuji_perspective_config p{SONY2FUJI_PERSPECTIVE_CONFIG_VERSION, sizeof(p),
                        transform == 4 || transform == 6 ? .2f : transform == 7 ? 1.f : 0.f,
                        transform == 5 ? -.3f : transform == 7 ? -1.f : 0.f};
                    status(sony2fuji_session_set_perspective(session.value, &p));
                    const bool active = turn || flips || crop || transform;
                    request.intent = SONY2FUJI_INTENT_FINAL; request.preview_long_edge = 0;
                    request.size_mode = SONY2FUJI_SIZE_NATIVE;
                    const auto native = render(session, request, false);
                    comparison.visit(native, false);
                    comparison.visit(render(session, request, true), false);
                    request.intent = SONY2FUJI_INTENT_PREVIEW;
                    comparison.visit(render(session, request, true), false);
                    request.size_mode = SONY2FUJI_SIZE_EXACT;
                    request.target_width = native.width + 3; request.target_height = native.height + 2;
                    comparison.visit(render(session, request, true), false);
                    request.size_mode = SONY2FUJI_SIZE_NATIVE; request.preview_long_edge = 9;
                    comparison.visit(render(session, request, false), false);
                    const auto reduced = render(session, request, true);
                    comparison.visit(reduced, active && reduced.width < native.width && reduced.height < native.height);
                    if (width == 31 && crop == 1 && (transform == 0 || transform == 6)) {
                        auto output = request; output.preview_long_edge = 0;
                        output.output_target = SONY2FUJI_TARGET_FILE; output.output_path = outputPath.c_str();
                        output.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE; output.long_edge = 13;
                        for (const auto format : {SONY2FUJI_OUTPUT_JPEG, SONY2FUJI_OUTPUT_PNG, SONY2FUJI_OUTPUT_DNG}) {
                            output.output_format = format; output.intent = SONY2FUJI_INTENT_FINAL;
                            comparison.visit(render(session, output, false), false);
                            comparison.visit(render(session, output, true), false);
                            if (format != SONY2FUJI_OUTPUT_DNG) {
                                output.intent = SONY2FUJI_INTENT_PREVIEW;
                                comparison.visit(render(session, output, true), false);
                            }
                        }
                    }
                }
            const auto identity = geometry(0, 0, 0, 0);
            status(sony2fuji_session_set_geometry(session.value, &identity));
            sony2fuji_perspective_config zero{SONY2FUJI_PERSPECTIVE_CONFIG_VERSION, sizeof(zero), 0, 0};
            status(sony2fuji_session_set_perspective(session.value, &zero));
            for (const auto input : {SONY2FUJI_INPUT_BUFFER, SONY2FUJI_INPUT_DISPLAY_BUFFER})
                for (int linear : {0, 1}) for (const auto format : {SONY2FUJI_OUTPUT_RGB8, SONY2FUJI_OUTPUT_RGBA8})
                    for (const auto intent : {SONY2FUJI_INTENT_PREVIEW, SONY2FUJI_INTENT_FINAL})
                        for (const auto sizeMode : {SONY2FUJI_SIZE_NATIVE, SONY2FUJI_SIZE_EXACT,
                                SONY2FUJI_SIZE_FIT_LONG_EDGE, SONY2FUJI_SIZE_FIT_SHORT_EDGE, SONY2FUJI_SIZE_LIMIT_LONG_EDGE}) {
                            if (input == SONY2FUJI_INPUT_DISPLAY_BUFFER && linear) continue;
                            auto identityRequest = request;
                            identityRequest.input_type = input; identityRequest.input_is_linear = linear;
                            identityRequest.output_format = format; identityRequest.intent = intent;
                            identityRequest.sharpening = .7f; identityRequest.preview_long_edge = 0;
                            identityRequest.size_mode = sizeMode;
                            identityRequest.target_width = 13; identityRequest.target_height = 9;
                            identityRequest.long_edge = 13; identityRequest.short_edge = 9;
                            comparison.visit(render(session, identityRequest, false), false);
                            comparison.visit(render(session, identityRequest, true), false);
                        }
        }
    }
    comparison.finish();
}

void bench(const char* raw, int edge, sony2fuji_gpu_mode mode) {
    if (mode != SONY2FUJI_GPU_OFF && !rawlabtest::nativeGpuAvailable())
        throw std::runtime_error("requested native GPU unavailable (not a CPU timing)");
    Session session(mode);
    auto request = requestFor(); request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = raw;
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = edge;
    for (int kind : {1, 2, 0}) {
        auto g = geometry(0, 0, 0, 0);
        if (kind) { g.crop_x = g.crop_y = .1f; g.crop_width = g.crop_height = .8f; }
        if (kind == 2) g.straighten_degrees = 3;
        status(sony2fuji_session_set_geometry(session.value, &g));
        render(session, request, true);
        std::vector<double> times;
        Frame last;
        for (int repeat = 0; repeat < 5; ++repeat) {
            const auto start = std::chrono::steady_clock::now();
            last = render(session, request, true);
            times.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
        }
        std::sort(times.begin(), times.end());
        std::cout << "BENCH " << (kind == 1 ? "crop" : kind == 2 ? "straighten_crop" : "identity")
                  << " edge=" << edge << " mode=" << mode << " median_ms=" << times[2]
                  << " range_ms=" << times.front() << ".." << times.back() << " output=" << last.width << 'x'
                  << last.height << " geometry=" << last.native_width << 'x' << last.native_height << '\n';
    }
}

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc == 3 && (std::string(argv[1]) == "--record" || std::string(argv[1]) == "--compare"))
            corpus(argv[2], std::string(argv[1]) == "--record");
        else if (argc == 5 && std::string(argv[1]) == "--bench")
            bench(argv[2], std::stoi(argv[3]), std::string(argv[4]) == "off" ? SONY2FUJI_GPU_OFF : SONY2FUJI_GPU_AUTO);
        else throw std::runtime_error("usage: probe --record|--compare CORPUS; probe --bench RAW EDGE off|auto");
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
