#include "sony2fuji/ffi/sony2fuji_c.h"
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static std::vector<uint8_t> render(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK, "render");
    const auto bytes = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return result;
}

int main() {
    sony2fuji_session* session = nullptr;
    try {
        require(sizeof(sony2fuji_processing_migration_result) == 80, "shared migration ABI layout");
        require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "session");
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
        require(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK, "CPU");
        require(sony2fuji_session_set_processing_version(session, SONY2FUJI_PROCESSING_C5_V2) == SONY2FUJI_STATUS_OK, "v2");
        std::vector<uint8_t> input(96 * 64 * 3);
        for (int y = 0; y < 64; ++y) for (int x = 0; x < 96; ++x) {
            const int i = (y * 96 + x) * 3;
            input[i] = 15 + 220 * x / 95; input[i + 1] = 15 + 220 * y / 63; input[i + 2] = 70;
        }
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER; request.input_pixels = input.data();
        request.input_width = 96; request.input_height = 64; request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
        request.input_color_space = SONY2FUJI_COLOR_SRGB; request.wb_mode = SONY2FUJI_WB_CAMERA;
        request.temperature = 6500; request.brightness = request.contrast = request.saturation = 1;
        request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
        request.intent = SONY2FUJI_INTENT_FINAL; request.size_mode = SONY2FUJI_SIZE_NATIVE;
        const auto original = render(session, request);
        sony2fuji_processing_migration_result result{};
        require(sony2fuji_session_migrate_processing(session, &request, &result) == SONY2FUJI_STATUS_OK &&
            result.disposition == SONY2FUJI_MIGRATION_ACCEPTED && result.source_version == 2 && result.target_version == 3,
            "zero-edit v2 safely migrates to v3");
        require(result.rgb_rmse == 0 && render(session, request) == original,
            "probe does not change the source session or its pixels");
        const auto suffix = std::chrono::steady_clock::now().time_since_epoch().count();
        const auto lookPath = std::filesystem::temp_directory_path() /
            std::filesystem::u8path(u8"\u8fc1\u79fb-" + std::to_string(suffix) + ".cube");
        struct Cleanup {
            std::filesystem::path path;
            ~Cleanup() { std::error_code ignored; std::filesystem::remove(path, ignored); }
        } cleanup{lookPath};
        require(bool(std::ofstream(lookPath) << "zero-strength look"), "write UTF-8 look fixture");
        const auto lookUtf8 = lookPath.u8string();
        request.lut_path = lookUtf8.c_str();
        require(sony2fuji_session_migrate_processing(session, &request, &result) == SONY2FUJI_STATUS_OK &&
            result.disposition == SONY2FUJI_MIGRATION_ACCEPTED, "migration stamps the UTF-8 look path");
        request.lut_path = nullptr;
        request.contrast = 0;
        const auto flattened = render(session, request);
        const auto flattenedStatus = sony2fuji_session_migrate_processing(session, &request, &result);
        std::cout << "flat migration status=" << flattenedStatus << " disposition=" << result.disposition <<
            " evaluations=" << result.evaluation_count << " rmse=" << result.rgb_rmse << " p99=" << result.p99_error << '\n';
        require(flattenedStatus == SONY2FUJI_STATUS_OK &&
            result.disposition == SONY2FUJI_MIGRATION_REJECTED,
            "unrepresentable legacy flat contrast is retained");
        require(render(session, request) == flattened, "rejection leaves the old rendering unchanged");
        require(sony2fuji_session_set_cancellation_callback(session, [](void*) -> int32_t { return 1; }, nullptr) ==
            SONY2FUJI_STATUS_OK, "install cancellation");
        require(sony2fuji_session_migrate_processing(session, &request, &result) == SONY2FUJI_STATUS_CANCELLED &&
            result.version == 0, "cancellation never publishes an accepted partial result");
        sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
        gpu.mode = SONY2FUJI_GPU_FORCE;
        sony2fuji_session_set_gpu_config(session, &gpu);
        require(sony2fuji_session_migrate_processing(session, &request, &result) == SONY2FUJI_STATUS_UNSUPPORTED,
            "migration cannot silently replace Force with CPU");
        sony2fuji_session_destroy(session);
        std::cout << "Migration ABI acceptance, rejection, source isolation, cancellation and Force checks passed\n";
    } catch (const std::exception& error) {
        sony2fuji_session_destroy(session); std::cerr << error.what() << '\n'; return 1;
    }
}
