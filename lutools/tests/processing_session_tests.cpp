#include "sony2fuji/ffi/sony2fuji_c.h"
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

static void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

using Session = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;

static Session makeSession(bool interactive, bool viewport, sony2fuji_raw_exposure_mode exposure, bool wavelet) {
    sony2fuji_session* pointer = nullptr;
    require(sony2fuji_session_create(&pointer) == SONY2FUJI_STATUS_OK, "session");
    Session session(pointer, sony2fuji_session_destroy);
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    require(sony2fuji_session_set_gpu_config(pointer, &gpu) == SONY2FUJI_STATUS_OK, "GPU off");
    require(sony2fuji_session_set_interactive_preview(pointer, interactive) == SONY2FUJI_STATUS_OK, "interactive");
    require(sony2fuji_session_set_viewport_preview(pointer, viewport) == SONY2FUJI_STATUS_OK, "viewport");
    require(sony2fuji_session_set_raw_exposure_mode(pointer, exposure) == SONY2FUJI_STATUS_OK, "exposure");
    sony2fuji_wavelet_denoise_config config{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(config),
        wavelet ? 1 : 0, 65, 72, 100};
    require(sony2fuji_session_set_wavelet_denoise(pointer, &config) == SONY2FUJI_STATUS_OK, "wavelet");
    return session;
}

static std::vector<uint8_t> render(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK, "render");
    const auto* bytes = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> pixels(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return pixels;
}

int main(int argc, char** argv) {
    try {
        const std::string path = argc > 1 ? argv[1] : std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
        require(sony2fuji_session_set_processing_version(nullptr, SONY2FUJI_PROCESSING_LEGACY) ==
                SONY2FUJI_STATUS_INVALID_ARGUMENT, "null setter");
        for (int mode = 0; mode < 4; ++mode) for (bool wavelet : {false, true}) {
            const bool interactive = mode == 1, viewport = mode == 2;
            const auto exposure = mode == 3 ? SONY2FUJI_EXPOSURE_PREVIEW : SONY2FUJI_EXPOSURE_SENSOR;
            auto session = makeSession(interactive, viewport, exposure, wavelet);
            sony2fuji_request request{};
            request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
            request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path.c_str();
            request.temperature = 8000; request.brightness = request.contrast = request.saturation = 1;
            request.wb_mode = mode == 3 ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA;
            request.intent = mode == 0 ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
            request.size_mode = SONY2FUJI_SIZE_NATIVE; request.preview_long_edge = 128;
            request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
            const auto defaultPixels = render(session.get(), request);
            for (const auto version : {SONY2FUJI_PROCESSING_LEGACY, SONY2FUJI_PROCESSING_SWT_V2,
                                       SONY2FUJI_PROCESSING_LEGACY}) {
                require(sony2fuji_session_set_processing_version(session.get(), version) == SONY2FUJI_STATUS_OK, "version");
                auto fresh = makeSession(interactive, viewport, exposure, wavelet);
                require(sony2fuji_session_set_processing_version(fresh.get(), version) == SONY2FUJI_STATUS_OK, "fresh version");
                const auto expected = render(fresh.get(), request);
                require(render(session.get(), request) == expected, "version switch must equal fresh session");
                if (version == SONY2FUJI_PROCESSING_LEGACY)
                    require(defaultPixels == expected, "default session must remain legacy");
                for (int invalid : {-1, 0, 3, 99})
                    require(sony2fuji_session_set_processing_version(session.get(),
                        static_cast<sony2fuji_processing_version>(invalid)) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                        "unknown version");
                require(render(session.get(), request) == expected, "invalid setter must not change session");
            }
        }
        std::cout << "Processing session default, invalid setters, exact/proxy/WB and version switches passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
