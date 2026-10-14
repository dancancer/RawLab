#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

size_t checks = 0;
void check(bool condition, const std::string& name) {
    ++checks;
    if (!condition) throw std::runtime_error(name);
}
void status(sony2fuji_status actual, sony2fuji_status expected, const std::string& name) {
    check(actual == expected, name + ": " + sony2fuji_status_message(actual));
}
struct Session {
    sony2fuji_session* value = nullptr;
    Session() { status(sony2fuji_session_create(&value), SONY2FUJI_STATUS_OK, "create session"); }
    ~Session() { sony2fuji_session_destroy(value); }
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;
};
struct Buffer {
    sony2fuji_buffer value{};
    ~Buffer() { sony2fuji_release_buffer(&value); }
};
struct Pixels {
    uint32_t width, height;
    std::vector<unsigned char> bytes;
};
sony2fuji_geometry_config identity() {
    return {SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(sony2fuji_geometry_config), 0, 0, 1, 1, 0, 0, 0, 0};
}
sony2fuji_geometry_config geometry() {
    auto config = identity();
    config.quarter_turns = 1; config.flip_horizontal = 1; config.straighten_degrees = 13;
    config.crop_x = .125f; config.crop_y = .25f; config.crop_width = .75f; config.crop_height = .5f;
    return config;
}
sony2fuji_perspective_config perspective(float horizontal = 0, float vertical = 0) {
    return {SONY2FUJI_PERSPECTIVE_CONFIG_VERSION, sizeof(sony2fuji_perspective_config), horizontal, vertical};
}
void setGeometry(sony2fuji_session* session, const sony2fuji_geometry_config& config) {
    status(sony2fuji_session_set_geometry(session, &config), SONY2FUJI_STATUS_OK, "set geometry");
}
void setPerspective(sony2fuji_session* session, const sony2fuji_perspective_config& config) {
    status(sony2fuji_session_set_perspective(session, &config), SONY2FUJI_STATUS_OK, "set perspective");
}
void setGpu(sony2fuji_session* session, sony2fuji_gpu_mode mode) {
    sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), mode};
    status(sony2fuji_session_set_gpu_config(session, &config), SONY2FUJI_STATUS_OK, "set GPU");
}
void size(sony2fuji_session* session, uint32_t expectedWidth, uint32_t expectedHeight, const std::string& name) {
    uint32_t width = 999, height = 999;
    status(sony2fuji_session_get_geometry_size(session, &width, &height),
        expectedWidth ? SONY2FUJI_STATUS_OK : SONY2FUJI_STATUS_UNSUPPORTED, name);
    check(width == expectedWidth && height == expectedHeight, name + " dimensions");
}
Pixels grid(uint32_t width = 95, uint32_t height = 67) {
    Pixels source{width, height, std::vector<unsigned char>(size_t(width) * height * 3)};
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        const size_t i = (size_t(y) * width + x) * 3;
        source.bytes[i] = static_cast<unsigned char>(15 + (x * 37 + y * 11) % 225);
        source.bytes[i + 1] = static_cast<unsigned char>(15 + (x * 7 + y * 43) % 225);
        source.bytes[i + 2] = static_cast<unsigned char>(15 + (x * 23 + y * 17) % 225);
    }
    return source;
}
sony2fuji_request requestFor(const Pixels& source) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = source.bytes.data();
    request.input_width = source.width; request.input_height = source.height;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8; request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1; request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500; request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.size_mode = SONY2FUJI_SIZE_NATIVE; request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8; request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}
Pixels render(sony2fuji_session* session, const sony2fuji_request& request, const std::string& name) {
    Buffer output;
    status(sony2fuji_process(session, &request, &output.value), SONY2FUJI_STATUS_OK, name);
    const auto& b = output.value;
    check(b.data && b.width && b.height && b.pixel_format == SONY2FUJI_PIXEL_RGB8, name + " RGB8 pixels");
    check(b.stride_bytes >= size_t(b.width) * 3 &&
        b.size_bytes >= size_t(b.stride_bytes) * (b.height - 1) + size_t(b.width) * 3, name + " buffer layout");
    Pixels result{b.width, b.height, std::vector<unsigned char>(size_t(b.width) * b.height * 3)};
    for (uint32_t y = 0; y < b.height; ++y)
        std::copy_n(static_cast<const unsigned char*>(b.data) + size_t(y) * b.stride_bytes,
            size_t(b.width) * 3, result.bytes.data() + size_t(y) * b.width * 3);
    return result;
}
void equal(const Pixels& actual, const Pixels& expected, const std::string& name, int tolerance = 0) {
    check(actual.width == expected.width && actual.height == expected.height &&
        actual.bytes.size() == expected.bytes.size(), name + " dimensions and byte count");
    for (size_t i = 0; i < expected.bytes.size(); ++i)
        if (std::abs(int(actual.bytes[i]) - int(expected.bytes[i])) > tolerance)
            check(false, name + " pixel byte " + std::to_string(i));
    check(true, name + " all pixels");
}
std::pair<uint32_t, uint32_t> dimensions(uint32_t width, uint32_t height,
    const sony2fuji_geometry_config& g, const sony2fuji_perspective_config& p) {
    if (g.quarter_turns % 2) std::swap(width, height);
    const double k = 1 / (1 + .25 * std::abs(p.horizontal) + .25 * std::abs(p.vertical));
    width = std::max(1u, uint32_t(std::floor(width * k)));
    height = std::max(1u, uint32_t(std::floor(height * k)));
    const double angle = g.straighten_degrees * std::acos(-1.0) / 180;
    const double c = std::cos(angle), s = std::abs(std::sin(angle));
    const double scale = std::min(width / (width * c + height * s), height / (width * s + height * c));
    width = std::max(1u, uint32_t(std::floor(width * scale)));
    height = std::max(1u, uint32_t(std::floor(height * scale)));
    const auto extent = [](uint32_t length, float start, float count) {
        const auto left = uint32_t(std::floor(double(start) * length));
        return std::min(length, std::max(left + 1,
            uint32_t(std::ceil(std::min(1.0, double(start) + count) * length)))) - left;
    };
    return {extent(width, g.crop_x, g.crop_width), extent(height, g.crop_y, g.crop_height)};
}
void resized(const Pixels& actual, const Pixels& native, const std::string& name) {
    for (uint32_t y = 0; y < actual.height; ++y) for (uint32_t x = 0; x < actual.width; ++x) {
        const float sx = actual.width == 1 ? 0 : x * (float(native.width - 1) / (actual.width - 1));
        const float sy = actual.height == 1 ? 0 : y * (float(native.height - 1) / (actual.height - 1));
        const auto x0 = uint32_t(sx), y0 = uint32_t(sy);
        const auto x1 = std::min(x0 + 1, native.width - 1), y1 = std::min(y0 + 1, native.height - 1);
        for (size_t channel = 0; channel < 3; ++channel) {
            const auto sample = [&](uint32_t px, uint32_t py) { return native.bytes[(size_t(py) * native.width + px) * 3 + channel]; };
            const float top = sample(x0, y0) * (1 - (sx - x0)) + sample(x1, y0) * (sx - x0);
            const float bottom = sample(x0, y1) * (1 - (sx - x0)) + sample(x1, y1) * (sx - x0);
            // The native RGB8 reference adds one quantization step; float resizing differs by at most one code.
            check(std::abs(actual.bytes[(size_t(y) * actual.width + x) * 3 + channel] -
                (top * (1 - (sy - y0)) + bottom * (sy - y0))) <= 1.01f, name + " bilinear sample");
        }
    }
}

void abiTests() {
    using P = sony2fuji_perspective_config;
    check(SONY2FUJI_PERSPECTIVE_CONFIG_VERSION == 1 && sizeof(P) == 16, "perspective version/16-byte ABI");
    check(offsetof(P, version) == 0 && offsetof(P, struct_size) == 4 &&
        offsetof(P, horizontal) == 8 && offsetof(P, vertical) == 12, "perspective ABI offsets");
    using G = sony2fuji_geometry_config;
    check(SONY2FUJI_GEOMETRY_CONFIG_VERSION == 1 && sizeof(G) == 40 &&
        offsetof(G, version) == 0 && offsetof(G, struct_size) == 4 &&
        offsetof(G, crop_x) == 8 && offsetof(G, crop_y) == 12 &&
        offsetof(G, crop_width) == 16 && offsetof(G, crop_height) == 20 &&
        offsetof(G, quarter_turns) == 24 && offsetof(G, flip_horizontal) == 28 &&
        offsetof(G, flip_vertical) == 32 && offsetof(G, straighten_degrees) == 36, "unchanged geometry v1 ABI");
    using R = sony2fuji_request;
    const bool wide = sizeof(void*) == 8;
    check(SONY2FUJI_REQUEST_VERSION == 2 && sizeof(R) == (wide ? 184u : 156u), "unchanged request v2 size");
    check(offsetof(R, input_pixels) == (wide ? 24u : 16u) && offsetof(R, lut_strength) == (wide ? 64u : 44u) &&
        offsetof(R, output_path) == (wide ? 160u : 136u) && offsetof(R, preview_long_edge) == sizeof(R) - 4,
        "unchanged request v2 offsets");
}

void validationTests() {
    const auto source = grid(); const auto request = requestFor(source);
    Session session; setGpu(session.value, SONY2FUJI_GPU_OFF);
    size(session.value, 0, 0, "new session query");
    auto p = perspective(.6f, -.4f); setGeometry(session.value, geometry()); setPerspective(session.value, p);
    const auto expected = render(session.value, request, "validation reference");
    status(sony2fuji_session_set_perspective(nullptr, &p), SONY2FUJI_STATUS_INVALID_ARGUMENT, "null session");
    status(sony2fuji_session_set_perspective(session.value, nullptr), SONY2FUJI_STATUS_INVALID_ARGUMENT, "null config");
    size(session.value, expected.width, expected.height, "null config keeps size");
    equal(render(session.value, request, "after null config"), expected, "null config keeps pixels");
    std::vector<sony2fuji_perspective_config> invalid;
    for (uint32_t version : {0u, SONY2FUJI_PERSPECTIVE_CONFIG_VERSION + 1}) {
        auto bad = p; bad.version = version; invalid.push_back(bad);
    }
    for (uint32_t bytes : {0u, uint32_t(sizeof(p) - 1), uint32_t(sizeof(p) + 1)}) {
        auto bad = p; bad.struct_size = bytes; invalid.push_back(bad);
    }
    for (auto field : {&sony2fuji_perspective_config::horizontal, &sony2fuji_perspective_config::vertical})
        for (float value : {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
            -std::numeric_limits<float>::infinity(), -1.0001f, 1.0001f}) {
            auto bad = p; bad.*field = value; invalid.push_back(bad);
        }
    for (const auto& bad : invalid) {
        status(sony2fuji_session_set_perspective(session.value, &bad), SONY2FUJI_STATUS_INVALID_ARGUMENT, "invalid perspective");
        size(session.value, expected.width, expected.height, "invalid perspective keeps size");
        equal(render(session.value, request, "after invalid perspective"), expected, "invalid perspective keeps pixels");
    }
    auto badGeometry = geometry(); badGeometry.straighten_degrees = std::numeric_limits<float>::quiet_NaN();
    status(sony2fuji_session_set_geometry(session.value, &badGeometry), SONY2FUJI_STATUS_INVALID_ARGUMENT, "invalid geometry with perspective");
    size(session.value, expected.width, expected.height, "invalid geometry keeps perspective size");
    equal(render(session.value, request, "after invalid geometry"), expected, "invalid geometry keeps perspective pixels");
    for (float edge : {-1.f, 1.f}) {
        setPerspective(session.value, perspective(edge, -edge));
        const auto output = render(session.value, request, "inclusive perspective bounds");
        const auto d = dimensions(source.width, source.height, geometry(), perspective(edge, -edge));
        check(output.width == d.first && output.height == d.second, "inclusive bounds dimensions");
    }
}

void setterTests() {
    const auto source = grid(); const auto request = requestFor(source);
    const auto g = geometry(); const auto p = perspective(.6f, -.4f);
    Session first, second, reference;
    for (auto* session : {first.value, second.value, reference.value}) setGpu(session, SONY2FUJI_GPU_OFF);
    const auto baseline = render(reference.value, request, "setter identity reference");
    setPerspective(reference.value, p); const auto perspectiveOnly = render(reference.value, request, "perspective-only reference");
    setPerspective(reference.value, perspective()); setGeometry(reference.value, g);
    const auto geometryOnly = render(reference.value, request, "geometry-only reference");
    setGeometry(first.value, g); setPerspective(first.value, p);
    setPerspective(second.value, p); setGeometry(second.value, g);
    const auto combined = render(first.value, request, "geometry then perspective");
    equal(render(second.value, request, "perspective then geometry"), combined, "setter order preserves both groups");
    setPerspective(first.value, p); size(first.value, 0, 0, "same perspective clears size");
    equal(render(first.value, request, "same perspective"), combined, "same perspective preserves pixels");
    setGeometry(first.value, g); size(first.value, 0, 0, "same geometry clears size");
    equal(render(first.value, request, "same geometry"), combined, "same geometry preserves perspective");
    setPerspective(first.value, perspective()); size(first.value, 0, 0, "zero perspective clears size");
    equal(render(first.value, request, "zero perspective"), geometryOnly, "perspective reset retains geometry");
    setPerspective(first.value, p); setGeometry(first.value, identity()); size(first.value, 0, 0, "zero geometry clears size");
    equal(render(first.value, request, "zero geometry"), perspectiveOnly, "geometry reset retains perspective");
    setPerspective(first.value, perspective()); equal(render(first.value, request, "both groups reset"), baseline, "both resets restore identity");
    auto failed = request; failed.version = 0; Buffer output;
    status(sony2fuji_process(first.value, &failed, &output.value), SONY2FUJI_STATUS_INVALID_ARGUMENT, "invalid process");
    size(first.value, 0, 0, "invalid process clears size");
    render(first.value, request, "recover after invalid process"); size(first.value, source.width, source.height, "recovery publishes size");
    failed = request; failed.input_type = SONY2FUJI_INPUT_RAW; failed.input_path = "/no/such/rawlab-perspective-input.ARW";
    status(sony2fuji_process(first.value, &failed, &output.value), SONY2FUJI_STATUS_IO_ERROR, "missing RAW process");
    size(first.value, 0, 0, "input failure clears size");
    check(source.bytes == grid().bytes, "perspective leaves caller pixels unchanged");
}

void previewTests() {
    const auto source = grid(); auto request = requestFor(source); Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    status(sony2fuji_session_set_interactive_preview(session.value, 1), SONY2FUJI_STATUS_OK, "interactive preview");
    status(sony2fuji_session_set_viewport_preview(session.value, 1), SONY2FUJI_STATUS_OK, "viewport preview");
    for (float angle : {-13.f, 0.f, 13.f}) {
        auto g = geometry(); g.straighten_degrees = angle;
        const auto p = perspective(angle == 0 ? 1.f : .6f, angle == 0 ? -1.f : -.4f);
        setGeometry(session.value, g); setPerspective(session.value, p);
        request.intent = SONY2FUJI_INTENT_FINAL; request.size_mode = SONY2FUJI_SIZE_NATIVE; request.preview_long_edge = 0;
        const auto native = render(session.value, request, "native perspective FINAL");
        const auto d = dimensions(source.width, source.height, g, p);
        check(native.width == d.first && native.height == d.second, "perspective then straighten then crop dimensions");
        size(session.value, d.first, d.second, "native perspective size");
        request.intent = SONY2FUJI_INTENT_PREVIEW;
        equal(render(session.value, request, "native perspective PREVIEW"), native, "exact native preview/final parity");
        request.size_mode = SONY2FUJI_SIZE_EXACT;
        for (const auto target : {std::pair<uint32_t, uint32_t>{31, 23}, {1, 9}, {9, 1}}) {
            request.target_width = target.first; request.target_height = target.second;
            const auto preview = render(session.value, request, "resized perspective PREVIEW");
            check(preview.width == target.first && preview.height == target.second, "requested exact size");
            resized(preview, native, "resize after perspective"); size(session.value, d.first, d.second, "resize retains native query");
            request.intent = SONY2FUJI_INTENT_FINAL;
            equal(render(session.value, request, "resized perspective FINAL"), preview, "resized preview/final parity");
            request.intent = SONY2FUJI_INTENT_PREVIEW;
        }
        request.preview_long_edge = 19;
        const auto small = render(session.value, request, "perspective preview long edge");
        const float scale = 19.f / std::max(native.width, native.height);
        check(small.width == std::max(1u, uint32_t(std::round(native.width * scale))) &&
            small.height == std::max(1u, uint32_t(std::round(native.height * scale))), "preview limit follows perspective canvas");
        resized(small, native, "long-edge resize after perspective"); size(session.value, d.first, d.second, "long-edge native query");
    }
}

void gpuTests(bool nativeGpu) {
    const auto source = grid(); const auto request = requestFor(source); Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF); const auto baseline = render(session.value, request, "identity CPU");
    setGpu(session.value, SONY2FUJI_GPU_AUTO); const auto automatic = render(session.value, request, "identity Auto");
    const auto backend = sony2fuji_session_get_last_backend(session.value);
    check(backend == (nativeGpu ? rawlabtest::nativeBackend : SONY2FUJI_BACKEND_CPU), "identity actual backend");
    equal(automatic, baseline, "identity CPU/Auto", nativeGpu ? 2 : 0);
    setPerspective(session.value, perspective(.6f, -.4f));
    setGpu(session.value, SONY2FUJI_GPU_OFF); const auto cpu = render(session.value, request, "perspective CPU");
    setGpu(session.value, SONY2FUJI_GPU_AUTO);
    equal(render(session.value, request, "perspective Auto"), cpu, "perspective CPU/Auto", nativeGpu ? 2 : 0);
    check(sony2fuji_session_get_last_backend(session.value) == SONY2FUJI_BACKEND_CPU, "mixed perspective result reports CPU");
    size(session.value, cpu.width, cpu.height, "Auto perspective query");
    setGpu(session.value, SONY2FUJI_GPU_FORCE); Buffer rejected;
    status(sony2fuji_process(session.value, &request, &rejected.value), SONY2FUJI_STATUS_UNSUPPORTED, "perspective Force unsupported");
    size(session.value, 0, 0, "Force failure clears query");
    setPerspective(session.value, perspective()); setGpu(session.value, SONY2FUJI_GPU_AUTO);
    equal(render(session.value, request, "zero perspective Auto"), automatic, "zero perspective restores Auto pixels");
    check(sony2fuji_session_get_last_backend(session.value) == backend, "zero perspective restores backend");
    if (nativeGpu) {
        setGpu(session.value, SONY2FUJI_GPU_FORCE);
        equal(render(session.value, request, "zero perspective Force"), automatic, "zero perspective restores GPU Force");
        check(sony2fuji_session_get_last_backend(session.value) == rawlabtest::nativeBackend, "zero Force native backend");
    } else std::cout << "SKIP native GPU hardware parity: actual backend probe unavailable\n";
}

void rawTests(const char* path, bool nativeGpu) {
    if (!path || !*path) {
        std::cout << "SKIP real RAW perspective/cache/orientation: supply RAW_PATH or RAWLAB_TEST_RAW\n";
        return;
    }
    const Pixels empty{0, 0, {}}; auto request = requestFor(empty);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_pixels = nullptr; request.input_path = path;
    Session session; setGpu(session.value, SONY2FUJI_GPU_OFF);
    const auto baseline = render(session.value, request, "RAW oriented identity");
    size(session.value, baseline.width, baseline.height, "RAW oriented source query");
    const auto g = geometry(); const auto p = perspective(.6f, -.4f);
    setGeometry(session.value, g); const auto geometryOnly = render(session.value, request, "RAW geometry reference");
    setPerspective(session.value, p); const auto native = render(session.value, request, "RAW combined FINAL");
    const auto d = dimensions(baseline.width, baseline.height, g, p);
    check(native.width == d.first && native.height == d.second, "RAW perspective uses already-oriented canvas");
    size(session.value, d.first, d.second, "RAW combined native query");
    status(sony2fuji_session_set_interactive_preview(session.value, 1), SONY2FUJI_STATUS_OK, "RAW interactive preview");
    status(sony2fuji_session_set_viewport_preview(session.value, 1), SONY2FUJI_STATUS_OK, "RAW viewport preview");
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    equal(render(session.value, request, "RAW native PREVIEW"), native, "RAW exact preview/final parity");
    request.preview_long_edge = 23; const auto preview = render(session.value, request, "RAW small PREVIEW");
    const float scale = 23.f / std::max(native.width, native.height);
    check(preview.width == std::max(1u, uint32_t(std::round(native.width * scale))) &&
        preview.height == std::max(1u, uint32_t(std::round(native.height * scale))), "RAW preview size follows combined canvas");
    resized(preview, native, "RAW resize after exact perspective"); size(session.value, d.first, d.second, "RAW small preview query");
    request.intent = SONY2FUJI_INTENT_FINAL; request.preview_long_edge = 0;
    equal(render(session.value, request, "RAW FINAL after preview"), native, "RAW cache retains exact combined pixels");
    setGpu(session.value, SONY2FUJI_GPU_AUTO);
    equal(render(session.value, request, "RAW combined Auto"), native, "RAW CPU/Auto perspective", nativeGpu ? 2 : 0);
    check(sony2fuji_session_get_last_backend(session.value) == SONY2FUJI_BACKEND_CPU, "RAW combined Auto reports CPU");
    size(session.value, d.first, d.second, "RAW Auto native query");
    setGpu(session.value, SONY2FUJI_GPU_OFF); setPerspective(session.value, perspective());
    equal(render(session.value, request, "RAW perspective reset"), geometryOnly, "RAW perspective reset retains geometry/cache");
    setGeometry(session.value, identity());
    equal(render(session.value, request, "RAW complete reset"), baseline, "RAW complete reset retains original orientation/cache");
    size(session.value, baseline.width, baseline.height, "RAW reset source query");
    std::cout << "PASS optional real RAW perspective/cache/orientation\n";
}

} // namespace

int main(int argc, char** argv) {
    if (argc > 2) { std::cerr << "usage: perspective_api_tests [RAW_PATH]\n"; return 2; }
    try {
        abiTests(); validationTests(); setterTests(); previewTests();
        const bool nativeGpu = rawlabtest::nativeGpuAvailable();
        gpuTests(nativeGpu); rawTests(argc == 2 ? argv[1] : std::getenv("RAWLAB_TEST_RAW"), nativeGpu);
        std::cout << "PASS " << checks << " perspective ABI, validation, setter, canvas, preview/final and GPU checks\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL after " << checks << " checks: " << error.what() << '\n';
        return 1;
    }
}
