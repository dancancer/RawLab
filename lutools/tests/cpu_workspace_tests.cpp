#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <iostream>
#include <new>
#include <vector>

namespace {
std::atomic<bool> measuring{false};
std::atomic<size_t> live{0}, peak{0};
struct alignas(std::max_align_t) Allocation { size_t bytes; bool measured; };

void* allocate(size_t bytes) {
    auto* allocation = static_cast<Allocation*>(std::malloc(sizeof(Allocation) + std::max<size_t>(1, bytes)));
    if (!allocation) throw std::bad_alloc();
    allocation->bytes = bytes;
    allocation->measured = measuring.load();
    if (allocation->measured) {
        const size_t current = live.fetch_add(bytes) + bytes;
        size_t previous = peak.load();
        while (previous < current && !peak.compare_exchange_weak(previous, current)) {}
    }
    return allocation + 1;
}

void release(void* pointer) noexcept {
    if (!pointer) return;
    auto* allocation = static_cast<Allocation*>(pointer) - 1;
    if (allocation->measured) live.fetch_sub(allocation->bytes);
    std::free(allocation);
}
}

void* operator new(size_t bytes) { return allocate(bytes); }
void* operator new[](size_t bytes) { return allocate(bytes); }
void operator delete(void* pointer) noexcept { release(pointer); }
void operator delete[](void* pointer) noexcept { release(pointer); }
void operator delete(void* pointer, size_t) noexcept { release(pointer); }
void operator delete[](void* pointer, size_t) noexcept { release(pointer); }

int main(int argc, char** argv) {
    if (argc != 2) return 1;
    constexpr uint32_t width = 2048, height = 1025;
    std::vector<uint8_t> input(size_t(width) * height * 3);
    for (size_t i = 0; i < input.size(); ++i) input[i] = uint8_t((i * 71 + i / 9) % 256);
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return 1;
    sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), SONY2FUJI_GPU_OFF};
    if (sony2fuji_session_set_gpu_config(session, &config) != SONY2FUJI_STATUS_OK) return 1;
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = input.data();
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8; request.input_is_linear = 1;
    request.input_color_space = SONY2FUJI_COLOR_SRGB; request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.temperature = 6500; request.brightness = request.contrast = request.saturation = 1;
    request.intent = SONY2FUJI_INTENT_FINAL; request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    request.lut_path = argv[1]; request.lut_strength = .83f;
    request.input_width = 2; request.input_height = 1;
    sony2fuji_buffer output{};
    // 预热只读 LUT 缓存；计量的是每次渲染的工作内存，而非共享素材。
    if (sony2fuji_process(session, &request, &output) != SONY2FUJI_STATUS_OK) return 1;
    sony2fuji_release_buffer(&output);
    request.input_width = width; request.input_height = height;
    bool passed = true;
    for (int scenario = 0; scenario < 4; ++scenario) {
        request.lut_path = scenario == 0 || scenario == 3 ? argv[1] : nullptr;
        request.noise_reduction = scenario == 2 || scenario == 3 ? .4f : 0;
        request.sharpening = scenario >= 2 ? .7f : 0;
        peak = live.load(); measuring = true;
        const auto result = sony2fuji_process(session, &request, &output);
        measuring = false;
        const size_t maximum = peak.load();
        const size_t imageBytes = size_t(width) * height * 3 * sizeof(float);
        // 允许一张工作图与有界小块；不能再增加一张完整 base/blurred 图。
        const size_t budget = imageBytes + imageBytes / 4 + 2 * 1024 * 1024;
        const bool valid = result == SONY2FUJI_STATUS_OK && output.width == width && output.height == height &&
            output.size_bytes == size_t(width) * height * 4 && maximum <= budget;
        std::cout << (valid ? "PASS" : "FAIL") << " CPU workspace scenario=" << scenario
            << " peak=" << maximum << " budget=" << budget << " status=" << result << '\n';
        passed &= valid;
        sony2fuji_release_buffer(&output);
    }
    sony2fuji_session_destroy(session);
    return passed ? 0 : 1;
}
