#include "sony2fuji/raw_processor.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <iostream>
#include <stdexcept>
#include <vector>

using namespace sony2fuji;

void check(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
    std::cout << "PASS " << message << std::endl;
}

struct Session {
    sony2fuji_session* value = nullptr;
    Session() {
        check(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK, "create session");
        sony2fuji_gpu_config config{};
        config.version = SONY2FUJI_GPU_CONFIG_VERSION;
        config.struct_size = sizeof(config);
        config.mode = SONY2FUJI_GPU_OFF;
        sony2fuji_session_set_gpu_config(value, &config);
    }
    ~Session() { sony2fuji_session_destroy(value); }
};

std::vector<unsigned char> render(Session& session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_process(session.value, &request, &buffer);
    if (status != SONY2FUJI_STATUS_OK) {
        sony2fuji_release_buffer(&buffer);
        throw std::runtime_error("RAW render failed");
    }
    const auto* bytes = static_cast<const unsigned char*>(buffer.data);
    std::vector<unsigned char> pixels(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return pixels;
}

int main(int argc, char** argv) {
    if (argc < 2 || argc > 3) return 2;
    try {
        Session session;
        int32_t supported = -1;
        check(sony2fuji_session_get_raw_noise_reduction_support(session.value, &supported) ==
              SONY2FUJI_STATUS_INVALID_ARGUMENT, "support is unknown before loading a RAW");
        check(sony2fuji_session_set_raw_noise_reduction(nullptr, 1) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
              sony2fuji_session_set_raw_noise_reduction(session.value, -1) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
              sony2fuji_session_set_raw_noise_reduction(session.value, 3) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
              "reject invalid RAW denoise levels and null session");
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION;
        request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_RAW;
        request.input_path = argv[1];
        request.wb_mode = SONY2FUJI_WB_CAMERA;
        request.temperature = 6500;
        request.brightness = request.contrast = request.saturation = 1;
        request.intent = SONY2FUJI_INTENT_PREVIEW;
        request.preview_long_edge = 1200;
        request.size_mode = SONY2FUJI_SIZE_NATIVE;
        request.output_target = SONY2FUJI_TARGET_BUFFER;
        request.output_format = SONY2FUJI_OUTPUT_RGBA8;
        const auto original = render(session, request);
        check(sony2fuji_session_get_raw_noise_reduction_support(session.value, &supported) ==
              SONY2FUJI_STATUS_OK && supported == 1, "Bayer RAW supports FBDD");
        std::vector<unsigned char> previous = original;
        for (int level : {1, 2, 0}) {
            check(sony2fuji_session_set_raw_noise_reduction(session.value, level) == SONY2FUJI_STATUS_OK,
                  "set RAW noise reduction level");
            const auto changed = render(session, request);
            check(changed != previous, "changing level invalidates the RAW cache");
            Session fresh;
            sony2fuji_session_set_raw_noise_reduction(fresh.value, level);
            sony2fuji_session_set_interactive_preview(fresh.value, 1);
            if (level > 0)
                check(render(fresh, request) == changed, "interactive RAW retains full FBDD processing");
            if (level == 0) check(changed == original, "turning denoise off restores original pixels");
            previous = changed;
        }

        RAWProcessor processor;
        check(!processor.supportsNoiseReduction(), "unloaded processor has no denoise capability");
        check(processor.loadFile(argv[1]) == ErrorCode::Success, "load Bayer fixture");
        RAWProcessOptions options;
        options.rawNoiseReduction = 2;
        options.halfSize = true;
        ImageData full;
        check(processor.process(options, full) == ErrorCode::Success &&
              (full.width == processor.getWidth() || full.height == processor.getWidth()),
              "C++ half-size request cannot silently skip enabled FBDD");
        options.rawNoiseReduction = 3;
        check(processor.process(options, full) == ErrorCode::InvalidFormat && full.pixels.empty(),
              "C++ rejects an invalid denoise level without stale pixels");
        check(processor.loadFile("/nonexistent/raw-noise.raw") != ErrorCode::Success &&
              !processor.supportsNoiseReduction(), "failed load clears denoise capability");

        if (argc == 3) {
            request.input_path = argv[2];
            render(session, request);
            check(sony2fuji_session_get_raw_noise_reduction_support(session.value, &supported) ==
                  SONY2FUJI_STATUS_OK && supported == 0, "non-Bayer RAW reports unsupported");
            sony2fuji_session_set_raw_noise_reduction(session.value, 1);
            sony2fuji_buffer buffer{};
            const auto status = sony2fuji_process(session.value, &request, &buffer);
            sony2fuji_release_buffer(&buffer);
            check(status == SONY2FUJI_STATUS_UNSUPPORTED, "non-Bayer RAW never silently ignores enabled FBDD");
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << std::endl;
        return 1;
    }
}
