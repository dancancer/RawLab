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
    sony2fuji_tone_controls_config tone{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tone), -.2f, .3f, .4f};
    require(sony2fuji_session_set_tone_controls(pointer, &tone) == SONY2FUJI_STATUS_OK, "tone controls");
    sony2fuji_atmosphere_config atmosphere{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(atmosphere), .2f, .1f};
    require(sony2fuji_session_set_atmosphere(pointer, &atmosphere) == SONY2FUJI_STATUS_OK, "atmosphere controls");
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

static void basicControlsBackendChecks(const std::string& path) {
    sony2fuji_session* pointer = nullptr;
    require(sony2fuji_session_create(&pointer) == SONY2FUJI_STATUS_OK, "backend session");
    Session session(pointer, sony2fuji_session_destroy);
    require(sony2fuji_session_set_processing_version(pointer, SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK,
        "backend version");
    for (int control = 0; control < 8; ++control) {
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path.c_str();
        request.temperature = 6500; request.brightness = request.contrast = request.saturation = 1;
        request.wb_mode = SONY2FUJI_WB_CAMERA; request.intent = SONY2FUJI_INTENT_FINAL;
        request.size_mode = SONY2FUJI_SIZE_LIMIT_LONG_EDGE; request.long_edge = 128;
        request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
        sony2fuji_tone_controls_config tone{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tone), 0, 0, 0};
        sony2fuji_atmosphere_config atmosphere{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(atmosphere), 0, 0};
        switch (control) {
            case 0: request.highlights = .5f; break;
            case 1: request.shadows = .5f; break;
            case 2: request.contrast = 1.5f; break;
            case 3: tone.black_point = -.5f; break;
            case 4: tone.white_point = .5f; break;
            case 5: tone.vibrance = .5f; break;
            case 6: atmosphere.clarity = .5f; break;
            case 7: atmosphere.dehaze = .5f; break;
        }
        require(sony2fuji_session_set_tone_controls(pointer, &tone) == SONY2FUJI_STATUS_OK, "backend tone");
        require(sony2fuji_session_set_atmosphere(pointer, &atmosphere) == SONY2FUJI_STATUS_OK, "backend atmosphere");
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
        require(sony2fuji_session_set_gpu_config(pointer, &gpu) == SONY2FUJI_STATUS_OK, "backend off");
        const auto expected = render(pointer, request);
        gpu.mode = SONY2FUJI_GPU_AUTO;
        require(sony2fuji_session_set_gpu_config(pointer, &gpu) == SONY2FUJI_STATUS_OK, "backend auto");
        require(render(pointer, request) == expected &&
            sony2fuji_session_get_last_backend(pointer) == SONY2FUJI_BACKEND_CPU,
            "each active v3 control routes Auto to identical CPU output");
        gpu.mode = SONY2FUJI_GPU_FORCE;
        require(sony2fuji_session_set_gpu_config(pointer, &gpu) == SONY2FUJI_STATUS_OK, "backend force");
        sony2fuji_buffer output{};
        require(sony2fuji_process(pointer, &request, &output) == SONY2FUJI_STATUS_UNSUPPORTED,
            "each active v3 control reports Force unsupported");
    }
}

int main(int argc, char** argv) {
    try {
        const std::string path = argc > 1 ? argv[1] : std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
        basicControlsBackendChecks(path);
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
            request.highlights = .4f; request.shadows = .35f; request.contrast = 1.15f; request.saturation = 1.1f;
            request.wb_mode = mode == 3 ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA;
            request.intent = mode == 0 ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
            request.size_mode = SONY2FUJI_SIZE_NATIVE; request.preview_long_edge = 128;
            request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
            const auto defaultPixels = render(session.get(), request);
            for (const auto version : {SONY2FUJI_PROCESSING_LEGACY, SONY2FUJI_PROCESSING_C5_V2,
                                       SONY2FUJI_PROCESSING_BASIC_V3,
                                       SONY2FUJI_PROCESSING_C5_V2, SONY2FUJI_PROCESSING_LEGACY}) {
                require(sony2fuji_session_set_processing_version(session.get(), version) == SONY2FUJI_STATUS_OK, "version");
                auto fresh = makeSession(interactive, viewport, exposure, wavelet);
                require(sony2fuji_session_set_processing_version(fresh.get(), version) == SONY2FUJI_STATUS_OK, "fresh version");
                const auto expected = render(fresh.get(), request);
                require(render(session.get(), request) == expected, "version switch must equal fresh session");
                if (version == SONY2FUJI_PROCESSING_LEGACY)
                    require(defaultPixels == expected, "default session must remain legacy");
                for (int invalid : {-1, 0, 4, 99})
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
