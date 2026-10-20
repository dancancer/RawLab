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

static_assert(sizeof(sony2fuji_geometry_config) == 40, "geometry config ABI");
size_t checks = 0;

void check(bool condition, const std::string& name) {
    ++checks;
    if (!condition) throw std::runtime_error(name);
}

void checkStatus(sony2fuji_status actual, sony2fuji_status expected, const std::string& name) {
    check(actual == expected, name + ": " + sony2fuji_status_message(actual));
}

struct Session {
    sony2fuji_session* value = nullptr;
    Session() { checkStatus(sony2fuji_session_create(&value), SONY2FUJI_STATUS_OK, "create session"); }
    ~Session() { sony2fuji_session_destroy(value); }
    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;
};

struct Buffer {
    sony2fuji_buffer value{};
    ~Buffer() { sony2fuji_release_buffer(&value); }
};

struct Pixels {
    uint32_t width = 0, height = 0;
    std::vector<unsigned char> bytes;
};

sony2fuji_geometry_config identity() {
    return {SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(sony2fuji_geometry_config),
        0, 0, 1, 1, 0, 0, 0, 0};
}

void setGeometry(sony2fuji_session* session, const sony2fuji_geometry_config& config) {
    checkStatus(sony2fuji_session_set_geometry(session, &config), SONY2FUJI_STATUS_OK,
        "set geometry");
}

void setGpu(sony2fuji_session* session, sony2fuji_gpu_mode mode) {
    sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), mode};
    checkStatus(sony2fuji_session_set_gpu_config(session, &config), SONY2FUJI_STATUS_OK,
        "set GPU mode");
}

void geometrySize(const sony2fuji_session* session, uint32_t expectedWidth, uint32_t expectedHeight,
    const std::string& name) {
    uint32_t width = 999, height = 999;
    checkStatus(sony2fuji_session_get_geometry_size(session, &width, &height), SONY2FUJI_STATUS_OK, name);
    check(width == expectedWidth && height == expectedHeight, name + " native canvas dimensions");
}

void geometrySizeUnavailable(const sony2fuji_session* session, const std::string& name) {
    uint32_t width = 999, height = 999;
    checkStatus(sony2fuji_session_get_geometry_size(session, &width, &height),
        SONY2FUJI_STATUS_UNSUPPORTED, name);
    check(width == 0 && height == 0, name + " clears output dimensions");
}

sony2fuji_request bufferRequest(const Pixels& source) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_pixels = source.bytes.data();
    request.input_width = source.width;
    request.input_height = source.height;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}

Pixels grid(uint32_t width, uint32_t height) {
    Pixels result{width, height, std::vector<unsigned char>(size_t(width) * height * 3)};
    for (uint32_t y = 0; y < height; ++y) for (uint32_t x = 0; x < width; ++x) {
        const size_t offset = (size_t(y) * width + x) * 3;
        result.bytes[offset] = static_cast<unsigned char>(15 + (x * 37 + y * 11) % 225);
        result.bytes[offset + 1] = static_cast<unsigned char>(15 + (x * 7 + y * 43) % 225);
        result.bytes[offset + 2] = static_cast<unsigned char>(15 + (x * 23 + y * 17) % 225);
    }
    return result;
}

Pixels render(sony2fuji_session* session, const sony2fuji_request& request,
    const std::string& name) {
    Buffer output;
    checkStatus(sony2fuji_process(session, &request, &output.value), SONY2FUJI_STATUS_OK, name);
    const auto& buffer = output.value;
    check(buffer.data && buffer.width > 0 && buffer.height > 0, name + " has pixels");
    check(buffer.pixel_format == SONY2FUJI_PIXEL_RGB8, name + " RGB8 format");
    check(buffer.stride_bytes >= size_t(buffer.width) * 3 &&
        buffer.size_bytes >= size_t(buffer.stride_bytes) * (buffer.height - 1) + size_t(buffer.width) * 3,
        name + " buffer layout");
    Pixels result{buffer.width, buffer.height,
        std::vector<unsigned char>(size_t(buffer.width) * buffer.height * 3)};
    const auto* source = static_cast<const unsigned char*>(buffer.data);
    for (uint32_t y = 0; y < buffer.height; ++y)
        std::copy_n(source + size_t(y) * buffer.stride_bytes, size_t(buffer.width) * 3,
            result.bytes.data() + size_t(y) * buffer.width * 3);
    return result;
}

void equal(const Pixels& actual, const Pixels& expected, const std::string& name, int tolerance = 0) {
    check(actual.width == expected.width && actual.height == expected.height,
        name + " dimensions: " + std::to_string(actual.width) + "x" + std::to_string(actual.height) +
        ", expected " + std::to_string(expected.width) + "x" + std::to_string(expected.height));
    check(actual.bytes.size() == expected.bytes.size(), name + " byte count");
    for (size_t i = 0; i < expected.bytes.size(); ++i)
        if (std::abs(int(actual.bytes[i]) - int(expected.bytes[i])) > tolerance)
            check(false, name + " pixel byte " + std::to_string(i) + ": " +
                std::to_string(actual.bytes[i]) + ", expected " + std::to_string(expected.bytes[i]));
    check(true, name + " all pixel bytes");
}

void abiTests() {
    using Config = sony2fuji_geometry_config;
    check(sizeof(Config) == 40, "geometry config has 40-byte ABI");
    check(offsetof(Config, version) == 0, "geometry version offset");
    check(offsetof(Config, struct_size) == 4, "geometry size offset");
    check(offsetof(Config, crop_x) == 8, "geometry crop x offset");
    check(offsetof(Config, crop_y) == 12, "geometry crop y offset");
    check(offsetof(Config, crop_width) == 16, "geometry crop width offset");
    check(offsetof(Config, crop_height) == 20, "geometry crop height offset");
    check(offsetof(Config, quarter_turns) == 24, "geometry quarter turns offset");
    check(offsetof(Config, flip_horizontal) == 28, "geometry horizontal flip offset");
    check(offsetof(Config, flip_vertical) == 32, "geometry vertical flip offset");
    check(offsetof(Config, straighten_degrees) == 36, "geometry straighten offset");
}

// Independent forward permutations, operating on the already rendered neutral
// bytes. These do not call the geometry implementation or duplicate its inverse map.
Pixels integerReference(Pixels source, const sony2fuji_geometry_config& config) {
    for (int turn = 0; turn < config.quarter_turns; ++turn) {
        Pixels rotated{source.height, source.width, std::vector<unsigned char>(source.bytes.size())};
        for (uint32_t y = 0; y < source.height; ++y) for (uint32_t x = 0; x < source.width; ++x) {
            const size_t from = (size_t(y) * source.width + x) * 3;
            const size_t to = (size_t(x) * rotated.width + source.height - 1 - y) * 3;
            std::copy_n(source.bytes.data() + from, 3, rotated.bytes.data() + to);
        }
        source = std::move(rotated);
    }
    if (config.flip_horizontal || config.flip_vertical) {
        Pixels flipped{source.width, source.height, std::vector<unsigned char>(source.bytes.size())};
        for (uint32_t y = 0; y < source.height; ++y) for (uint32_t x = 0; x < source.width; ++x) {
            const uint32_t targetX = config.flip_horizontal ? source.width - 1 - x : x;
            const uint32_t targetY = config.flip_vertical ? source.height - 1 - y : y;
            std::copy_n(source.bytes.data() + (size_t(y) * source.width + x) * 3, 3,
                flipped.bytes.data() + (size_t(targetY) * source.width + targetX) * 3);
        }
        source = std::move(flipped);
    }
    const uint32_t left = static_cast<uint32_t>(std::floor(double(config.crop_x) * source.width));
    const uint32_t top = static_cast<uint32_t>(std::floor(double(config.crop_y) * source.height));
    const uint32_t right = std::min(source.width, std::max(left + 1,
        static_cast<uint32_t>(std::ceil(std::min(1.0, double(config.crop_x) + config.crop_width) * source.width))));
    const uint32_t bottom = std::min(source.height, std::max(top + 1,
        static_cast<uint32_t>(std::ceil(std::min(1.0, double(config.crop_y) + config.crop_height) * source.height))));
    Pixels cropped{right - left, bottom - top,
        std::vector<unsigned char>(size_t(right - left) * (bottom - top) * 3)};
    for (uint32_t y = 0; y < cropped.height; ++y)
        std::copy_n(source.bytes.data() + (size_t(top + y) * source.width + left) * 3,
            size_t(cropped.width) * 3, cropped.bytes.data() + size_t(y) * cropped.width * 3);
    return cropped;
}

std::pair<uint32_t, uint32_t> nativeDimensions(uint32_t width, uint32_t height,
    const sony2fuji_geometry_config& config) {
    if (config.quarter_turns % 2) std::swap(width, height);
    const double angle = double(config.straighten_degrees) * std::acos(-1.0) / 180;
    const double cosine = std::cos(angle), sine = std::abs(std::sin(angle));
    const double scale = std::min(width / (width * cosine + height * sine),
        height / (width * sine + height * cosine));
    width = std::max(1u, static_cast<uint32_t>(std::floor(width * scale)));
    height = std::max(1u, static_cast<uint32_t>(std::floor(height * scale)));
    const uint32_t left = static_cast<uint32_t>(std::floor(double(config.crop_x) * width));
    const uint32_t top = static_cast<uint32_t>(std::floor(double(config.crop_y) * height));
    const uint32_t right = std::min(width, std::max(left + 1,
        static_cast<uint32_t>(std::ceil(std::min(1.0, double(config.crop_x) + config.crop_width) * width))));
    const uint32_t bottom = std::min(height, std::max(top + 1,
        static_cast<uint32_t>(std::ceil(std::min(1.0, double(config.crop_y) + config.crop_height) * height))));
    return {right - left, bottom - top};
}

void resizedFromNative(const Pixels& actual, const Pixels& native, const std::string& name) {
    for (uint32_t y = 0; y < actual.height; ++y) for (uint32_t x = 0; x < actual.width; ++x) {
        const float sx = actual.width == 1 ? 0 : x * (float(native.width - 1) / (actual.width - 1));
        const float sy = actual.height == 1 ? 0 : y * (float(native.height - 1) / (actual.height - 1));
        const uint32_t x0 = static_cast<uint32_t>(sx), y0 = static_cast<uint32_t>(sy);
        const uint32_t x1 = std::min(x0 + 1, native.width - 1), y1 = std::min(y0 + 1, native.height - 1);
        const float tx = sx - x0, ty = sy - y0;
        for (size_t c = 0; c < 3; ++c) {
            const auto sample = [&](uint32_t px, uint32_t py) {
                return native.bytes[(size_t(py) * native.width + px) * 3 + c];
            };
            const float top = sample(x0, y0) * (1 - tx) + sample(x1, y0) * tx;
            const float bottom = sample(x0, y1) * (1 - tx) + sample(x1, y1) * tx;
            const float expected = top * (1 - ty) + bottom * ty;
            // Native RGB8 already contains one quantization step. Resizing float
            // display pixels and quantizing once can differ by at most one code.
            check(std::abs(actual.bytes[(size_t(y) * actual.width + x) * 3 + c] - expected) <= 1.01f,
                name + " align-corners bilinear byte " + std::to_string((size_t(y) * actual.width + x) * 3 + c));
        }
    }
}

void integerTests() {
    const auto source = grid(17, 11);
    const auto original = source.bytes;
    auto request = bufferRequest(source);
    Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    const auto baseline = render(session.value, request, "default identity");
    setGeometry(session.value, identity());
    equal(render(session.value, request, "explicit identity"), baseline, "identity bypass");
    for (int turn = 0; turn < 4; ++turn) for (int horizontal = 0; horizontal <= 1; ++horizontal)
        for (int vertical = 0; vertical <= 1; ++vertical) {
            auto config = identity();
            config.quarter_turns = turn;
            config.flip_horizontal = horizontal;
            config.flip_vertical = vertical;
            for (int crop = 0; crop < 2; ++crop) {
                if (crop) {
                    config.crop_x = .125f; config.crop_y = .25f;
                    config.crop_width = .625f; config.crop_height = .5f;
                }
                setGeometry(session.value, config);
                const std::string name = "integer transform " + std::to_string(turn) + "/" +
                    std::to_string(horizontal) + "/" + std::to_string(vertical) + "/" + std::to_string(crop);
                equal(render(session.value, request, name), integerReference(baseline, config), name);
            }
        }
    auto tiny = identity();
    tiny.crop_x = .5f; tiny.crop_y = .5f;
    tiny.crop_width = tiny.crop_height = 1e-6f;
    setGeometry(session.value, tiny);
    const auto one = render(session.value, request, "subpixel crop");
    check(one.width == 1 && one.height == 1, "positive subpixel crop retains a pixel");
    equal(one, integerReference(baseline, tiny), "subpixel crop position");
    setGeometry(session.value, identity());
    equal(render(session.value, request, "identity after changes"), baseline, "session reset restores baseline");
    check(source.bytes == original, "geometry never modifies caller input");
}

void validationTests() {
    const auto source = grid(17, 11);
    const auto request = bufferRequest(source);
    Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    auto valid = identity();
    valid.quarter_turns = 1; valid.flip_horizontal = 1;
    valid.crop_x = .125f; valid.crop_y = .25f;
    valid.crop_width = .625f; valid.crop_height = .5f;
    setGeometry(session.value, valid);
    const auto expected = render(session.value, request, "validation baseline");
    checkStatus(sony2fuji_session_set_geometry(nullptr, &valid), SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null session rejected");
    checkStatus(sony2fuji_session_set_geometry(session.value, nullptr), SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null config rejected");
    equal(render(session.value, request, "after null config"), expected, "null config preserves state");
    std::vector<std::pair<std::string, sony2fuji_geometry_config>> invalid;
    auto add = [&](const std::string& name, auto change) {
        auto config = valid; change(config); invalid.emplace_back(name, config);
    };
    add("version zero", [](auto& c) { c.version = 0; });
    add("future version", [](auto& c) { c.version = SONY2FUJI_GEOMETRY_CONFIG_VERSION + 1; });
    add("size zero", [](auto& c) { c.struct_size = 0; });
    add("short struct", [](auto& c) { c.struct_size = sizeof(c) - 1; });
    for (int value : {-1, 4}) add("quarter turns " + std::to_string(value),
        [=](auto& c) { c.quarter_turns = value; });
    for (int value : {-1, 2}) {
        add("horizontal flip " + std::to_string(value), [=](auto& c) { c.flip_horizontal = value; });
        add("vertical flip " + std::to_string(value), [=](auto& c) { c.flip_vertical = value; });
    }
    using Config = sony2fuji_geometry_config;
    const std::vector<std::pair<const char*, float Config::*>> fields{
        {"crop x", &Config::crop_x}, {"crop y", &Config::crop_y},
        {"crop width", &Config::crop_width}, {"crop height", &Config::crop_height},
        {"straighten", &Config::straighten_degrees}};
    for (const auto& field : fields) for (float value : {std::numeric_limits<float>::quiet_NaN(),
        std::numeric_limits<float>::infinity(), -std::numeric_limits<float>::infinity()})
        add(std::string(field.first) + " nonfinite", [=](auto& c) { c.*field.second = value; });
    for (float value : {-1.f, 1.f}) {
        add("crop x out of range", [=](auto& c) { c.crop_x = value; });
        add("crop y out of range", [=](auto& c) { c.crop_y = value; });
    }
    for (float value : {-1.f, 0.f, 1.f}) {
        add("crop width invalid", [=](auto& c) { c.crop_width = value; });
        add("crop height invalid", [=](auto& c) { c.crop_height = value; });
    }
    for (float value : {-45.01f, 45.01f})
        add("straighten out of range", [=](auto& c) { c.straighten_degrees = value; });
    for (const auto& item : invalid) {
        checkStatus(sony2fuji_session_set_geometry(session.value, &item.second),
            SONY2FUJI_STATUS_INVALID_ARGUMENT, item.first + " rejected");
        geometrySize(session.value, expected.width, expected.height,
            item.first + " preserves previously computed dimensions");
        equal(render(session.value, request, "after " + item.first), expected,
            item.first + " preserves previous geometry");
    }
    for (float angle : {-45.f, 45.f}) {
        auto edge = identity(); edge.straighten_degrees = angle;
        setGeometry(session.value, edge);
        const auto result = render(session.value, request, "inclusive straighten boundary");
        const auto dimensions = nativeDimensions(source.width, source.height, edge);
        check(result.width == dimensions.first && result.height == dimensions.second,
            "inclusive straighten boundary dimensions");
    }
}

void floatBoundaryTests() {
    const auto source = grid(17, 11);
    const auto request = bufferRequest(source);
    Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    const auto baseline = render(session.value, request, "float boundary neutral reference");
    auto config = identity();
    config.crop_x = config.crop_y = .2f;
    config.crop_width = config.crop_height = .8f;
    setGeometry(session.value, config);
    const auto expected = integerReference(baseline, config);
    const auto cropped = render(session.value, request, "UI float boundary crop");
    equal(cropped, expected, "0.2 plus 0.8 crop retains complete right and bottom edges");
    for (size_t channel = 0; channel < 3; ++channel)
        check(cropped.bytes[cropped.bytes.size() - 3 + channel] ==
            baseline.bytes[baseline.bytes.size() - 3 + channel],
            "float boundary crop preserves bottom-right pixel");
    using Config = sony2fuji_geometry_config;
    for (auto field : {&Config::crop_width, &Config::crop_height}) {
        auto tolerated = config;
        tolerated.*field = .8000005f;
        setGeometry(session.value, tolerated);
        equal(render(session.value, request, "tolerated float boundary crop"), expected,
            "tiny normalized crop overshoot clamps to source edge");
        geometrySize(session.value, expected.width, expected.height,
            "clamped float boundary native dimensions");
        auto invalid = tolerated;
        invalid.*field = .8000011f;
        checkStatus(sony2fuji_session_set_geometry(session.value, &invalid),
            SONY2FUJI_STATUS_INVALID_ARGUMENT, "crop overshoot beyond tolerance rejected");
        geometrySize(session.value, expected.width, expected.height,
            "rejected float boundary setter preserves computed dimensions");
        equal(render(session.value, request, "after rejected float boundary setter"), expected,
            "rejected float boundary setter preserves previous crop");
    }
}

void geometrySizeTests() {
    Session session;
    geometrySizeUnavailable(session.value, "new session dimensions unavailable");
    uint32_t width = 999, height = 999;
    checkStatus(sony2fuji_session_get_geometry_size(nullptr, &width, &height),
        SONY2FUJI_STATUS_INVALID_ARGUMENT, "size getter null session");
    check(width == 0 && height == 0, "null session clears both size outputs");
    height = 999;
    checkStatus(sony2fuji_session_get_geometry_size(session.value, nullptr, &height),
        SONY2FUJI_STATUS_INVALID_ARGUMENT, "size getter null width");
    check(height == 0, "null width clears height output");
    width = 999;
    checkStatus(sony2fuji_session_get_geometry_size(session.value, &width, nullptr),
        SONY2FUJI_STATUS_INVALID_ARGUMENT, "size getter null height");
    check(width == 0, "null height clears width output");
    checkStatus(sony2fuji_session_get_geometry_size(session.value, nullptr, nullptr),
        SONY2FUJI_STATUS_INVALID_ARGUMENT, "size getter null outputs");

    const auto source = grid(95, 67);
    auto request = bufferRequest(source);
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.preview_long_edge = 19;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    const auto reduced = render(session.value, request, "identity early reduced preview");
    check(reduced.width < source.width && reduced.height < source.height,
        "identity preview output is smaller than source");
    geometrySize(session.value, source.width, source.height, "identity early preview reports source size");
    checkStatus(sony2fuji_session_set_viewport_preview(session.value, 1), SONY2FUJI_STATUS_OK,
        "size getter viewport opt-in");
    render(session.value, request, "identity viewport reduced preview");
    geometrySize(session.value, source.width, source.height, "identity viewport reports source size");

    auto config = identity();
    config.quarter_turns = 1; config.flip_horizontal = 1; config.straighten_degrees = 13;
    config.crop_x = .125f; config.crop_y = .25f;
    config.crop_width = .75f; config.crop_height = .5f;
    setGeometry(session.value, config);
    geometrySizeUnavailable(session.value, "new valid geometry clears old dimensions");
    const auto output = render(session.value, request, "active geometry reduced preview");
    const auto dimensions = nativeDimensions(source.width, source.height, config);
    check(output.width < dimensions.first && output.height < dimensions.second,
        "active geometry preview output is smaller than native canvas");
    geometrySize(session.value, dimensions.first, dimensions.second,
        "active preview reports geometry before output resize");
    auto invalid = config; invalid.straighten_degrees = std::numeric_limits<float>::quiet_NaN();
    checkStatus(sony2fuji_session_set_geometry(session.value, &invalid),
        SONY2FUJI_STATUS_INVALID_ARGUMENT, "invalid size-state setter rejected");
    geometrySize(session.value, dimensions.first, dimensions.second,
        "invalid setter preserves computed dimensions");
    equal(render(session.value, request, "render after invalid size-state setter"), output,
        "invalid setter preserves geometry as well as dimensions");
    setGeometry(session.value, config);
    geometrySizeUnavailable(session.value, "setting same valid geometry clears dimensions");
    render(session.value, request, "recompute size after same setter");
    geometrySize(session.value, dimensions.first, dimensions.second, "same setter size republished");

    auto badRequest = request; badRequest.version = 0;
    Buffer rejected;
    checkStatus(sony2fuji_process(session.value, &badRequest, &rejected.value),
        SONY2FUJI_STATUS_INVALID_ARGUMENT, "invalid request rejected after successful render");
    geometrySizeUnavailable(session.value, "invalid request clears previous dimensions");
    render(session.value, request, "size recovery after invalid request");
    geometrySize(session.value, dimensions.first, dimensions.second, "successful render restores dimensions");
    setGpu(session.value, SONY2FUJI_GPU_FORCE);
    checkStatus(sony2fuji_process(session.value, &request, &rejected.value),
        SONY2FUJI_STATUS_UNSUPPORTED, "active geometry Force rejected after successful render");
    geometrySizeUnavailable(session.value, "Force failure clears previous dimensions");
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    render(session.value, request, "size recovery after Force failure");
    auto missingInput = request;
    missingInput.input_type = SONY2FUJI_INPUT_RAW;
    missingInput.input_path = "/no/such/rawlab-geometry-input.ARW";
    checkStatus(sony2fuji_process(session.value, &missingInput, &rejected.value),
        SONY2FUJI_STATUS_IO_ERROR, "missing RAW rejected after successful render");
    geometrySizeUnavailable(session.value, "input IO failure clears previous dimensions");
}

void previewTests() {
    const auto source = grid(95, 67);
    auto request = bufferRequest(source);
    Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    auto config = identity();
    config.quarter_turns = 1; config.flip_horizontal = 1;
    config.crop_x = .125f; config.crop_y = .25f;
    config.crop_width = .75f; config.crop_height = .5f;
    for (float angle : {-13.f, 0.f, 13.f}) {
        config.straighten_degrees = angle;
        setGeometry(session.value, config);
        request.intent = SONY2FUJI_INTENT_FINAL;
        request.size_mode = SONY2FUJI_SIZE_NATIVE;
        request.preview_long_edge = 0;
        const auto native = render(session.value, request, "native geometric final");
        const auto dimensions = nativeDimensions(source.width, source.height, config);
        check(native.width == dimensions.first && native.height == dimensions.second,
            "native dimensions follow inscribed canvas then crop");
        check(*std::min_element(native.bytes.begin(), native.bytes.end()) > 0,
            "straightening and crop introduce no black border");
        checkStatus(sony2fuji_session_set_interactive_preview(session.value, 1), SONY2FUJI_STATUS_OK,
            "enable interactive preview");
        checkStatus(sony2fuji_session_set_viewport_preview(session.value, 0), SONY2FUJI_STATUS_OK,
            "exact geometry preview opts out of viewport approximation");
        request.intent = SONY2FUJI_INTENT_PREVIEW;
        equal(render(session.value, request, "native geometric preview"), native,
            "active geometry preview keeps exact source canvas");
        request.size_mode = SONY2FUJI_SIZE_EXACT;
        for (const auto& size : {std::pair<uint32_t, uint32_t>{7, 5}, {31, 23}, {1, 9}, {9, 1}}) {
            request.target_width = size.first; request.target_height = size.second;
            const auto preview = render(session.value, request, "resized geometric preview");
            check(preview.width == size.first && preview.height == size.second, "exact output dimensions");
            resizedFromNative(preview, native, "preview resizes after geometry");
            request.intent = SONY2FUJI_INTENT_FINAL;
            equal(render(session.value, request, "resized geometric final"), preview,
                "same output size has exact preview/final parity");
            request.intent = SONY2FUJI_INTENT_PREVIEW;
        }
        request.preview_long_edge = 19;
        const auto preview = render(session.value, request, "preview long edge priority");
        const float scale = 19.f / std::max(native.width, native.height);
        check(preview.width == std::max(1u, static_cast<uint32_t>(std::round(native.width * scale))) &&
            preview.height == std::max(1u, static_cast<uint32_t>(std::round(native.height * scale))),
            "preview limit uses geometric dimensions");
        resizedFromNative(preview, native, "long edge preview resizes after geometry");
    }
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.preview_long_edge = 1;
    request.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE;
    request.long_edge = 1000;
    const auto result = render(session.value, request, "final ignores preview limit");
    const auto dimensions = nativeDimensions(source.width, source.height, config);
    check(result.width == dimensions.first && result.height == dimensions.second,
        "final preserves geometric native dimensions without enlargement");
}

void gpuTests(bool nativeGpu) {
    const auto source = grid(95, 67);
    auto request = bufferRequest(source);
    Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    const auto baseline = render(session.value, request, "GPU comparison baseline");
    setGpu(session.value, SONY2FUJI_GPU_AUTO);
    const auto automatic = render(session.value, request, "identity Auto");
    const auto identityBackend = sony2fuji_session_get_last_backend(session.value);
    if (nativeGpu) {
        check(identityBackend == rawlabtest::nativeBackend, "identity retains native GPU backend");
        equal(automatic, baseline, "identity CPU/native GPU", 2);
    } else {
        check(identityBackend == SONY2FUJI_BACKEND_CPU, "unavailable native GPU falls back to CPU");
        equal(automatic, baseline, "identity CPU fallback");
        std::cout << "SKIP native GPU hardware parity: backend unavailable\n";
    }
    auto config = identity();
    config.quarter_turns = 1; config.flip_vertical = 1;
    config.crop_x = .125f; config.crop_y = .25f;
    config.crop_width = .75f; config.crop_height = .5f;
    for (float angle : {0.f, 13.f}) {
        config.straighten_degrees = angle;
        setGeometry(session.value, config);
        setGpu(session.value, SONY2FUJI_GPU_OFF);
        const auto cpu = render(session.value, request, "active geometry CPU");
        setGpu(session.value, SONY2FUJI_GPU_AUTO);
        equal(render(session.value, request, "active geometry Auto"), cpu,
            "geometry CPU/Auto RGB8 parity", nativeGpu ? 2 : 0);
        check(sony2fuji_session_get_last_backend(session.value) == SONY2FUJI_BACKEND_CPU,
            "Auto reports final CPU geometry stage");
        setGpu(session.value, SONY2FUJI_GPU_FORCE);
        Buffer rejected;
        checkStatus(sony2fuji_process(session.value, &request, &rejected.value),
            SONY2FUJI_STATUS_UNSUPPORTED, "Force rejects CPU-only active geometry");
    }
    setGeometry(session.value, identity());
    setGpu(session.value, SONY2FUJI_GPU_AUTO);
    equal(render(session.value, request, "identity after GPU geometry"), automatic,
        "reset geometry retains previous Auto behavior");
    check(sony2fuji_session_get_last_backend(session.value) == identityBackend,
        "reset geometry restores actual backend");
    if (nativeGpu) {
        setGpu(session.value, SONY2FUJI_GPU_FORCE);
        equal(render(session.value, request, "identity Force"), automatic,
            "identity Force native GPU behavior");
        check(sony2fuji_session_get_last_backend(session.value) == rawlabtest::nativeBackend,
            "identity Force reports native GPU");
    }
}

void rawTests(const char* path) {
    if (!path || !*path) {
        std::cout << "SKIP real RAW geometry/cache/orientation: supply a path or RAWLAB_TEST_RAW\n";
        return;
    }
    Session session;
    setGpu(session.value, SONY2FUJI_GPU_OFF);
    auto request = bufferRequest(Pixels{});
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_pixels = nullptr;
    request.input_path = path;
    const auto baseline = render(session.value, request, "RAW native identity");
    geometrySize(session.value, baseline.width, baseline.height, "RAW identity native canvas");
    checkStatus(sony2fuji_session_set_interactive_preview(session.value, 1), SONY2FUJI_STATUS_OK,
        "RAW identity interactive preview opt-in");
    checkStatus(sony2fuji_session_set_viewport_preview(session.value, 1), SONY2FUJI_STATUS_OK,
        "RAW identity viewport preview opt-in");
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.preview_long_edge = 23;
    render(session.value, request, "RAW identity reduced preview");
    geometrySize(session.value, baseline.width, baseline.height,
        "RAW identity preview reports full cached source dimensions");
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.preview_long_edge = 0;
    auto config = identity();
    config.quarter_turns = 1; config.flip_horizontal = 1;
    config.crop_x = .25f; config.crop_y = .125f;
    config.crop_width = .5f; config.crop_height = .625f;
    setGeometry(session.value, config);
    geometrySizeUnavailable(session.value, "RAW geometry setter clears identity dimensions");
    const auto expected = integerReference(baseline, config);
    equal(render(session.value, request, "RAW geometry after identity"), expected,
        "RAW transforms already oriented pixels exactly once");
    geometrySize(session.value, expected.width, expected.height, "RAW native geometric canvas");
    auto second = identity();
    second.quarter_turns = 3; second.flip_vertical = 1;
    second.crop_y = .5f; second.crop_height = .5f;
    setGeometry(session.value, second);
    equal(render(session.value, request, "RAW second crop"), integerReference(baseline, second),
        "reused RAW cache does not retain previous geometry");
    setGeometry(session.value, config);
    checkStatus(sony2fuji_session_set_interactive_preview(session.value, 1), SONY2FUJI_STATUS_OK,
        "RAW interactive preview opt-in");
    checkStatus(sony2fuji_session_set_viewport_preview(session.value, 1), SONY2FUJI_STATUS_OK,
        "RAW viewport preview opt-in");
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.preview_long_edge = 23;
    const auto preview = render(session.value, request, "RAW geometric preview");
    geometrySize(session.value, expected.width, expected.height,
        "RAW cropped canvas dimensions before preview resize");
    const float scale = 23.f / std::max(expected.width, expected.height);
    check(preview.width == std::max(1u, static_cast<uint32_t>(std::round(expected.width * scale))) &&
        preview.height == std::max(1u, static_cast<uint32_t>(std::round(expected.height * scale))),
        "RAW preview dimensions follow oriented crop");
    checkStatus(sony2fuji_session_set_viewport_preview(session.value, 0), SONY2FUJI_STATUS_OK,
        "RAW exact preview opts out of viewport approximation");
    resizedFromNative(render(session.value, request, "RAW exact geometric preview"), expected,
        "RAW exact geometry before preview resize");
    request.intent = SONY2FUJI_INTENT_FINAL;
    equal(render(session.value, request, "RAW final after preview"), expected,
        "RAW final retains full geometry after preview");
    setGeometry(session.value, identity());
    geometrySizeUnavailable(session.value, "RAW identity reset clears geometric dimensions");
    equal(render(session.value, request, "RAW identity restored"), baseline,
        "RAW geometry reset preserves original orientation and cache");
    geometrySize(session.value, baseline.width, baseline.height, "RAW identity size restored");
    std::cout << "PASS optional RAW geometry/cache/orientation: " << path << '\n';
}

} // namespace

int main(int argc, char** argv) {
    if (argc > 2) {
        std::cerr << "usage: geometry_api_tests [RAW_PATH]\n";
        return 2;
    }
    try {
        abiTests();
        integerTests();
        validationTests();
        floatBoundaryTests();
        geometrySizeTests();
        previewTests();
        gpuTests(rawlabtest::nativeGpuAvailable());
        rawTests(argc == 2 ? argv[1] : std::getenv("RAWLAB_TEST_RAW"));
        std::cout << "PASS " << checks << " geometry ABI, setter, source-canvas, preview/final and GPU checks\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL after " << checks << " checks: " << error.what() << '\n';
        return 1;
    }
}
