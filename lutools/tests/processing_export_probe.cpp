#include "sony2fuji/ffi/sony2fuji_c.h"
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

static void check(sony2fuji_status status) {
    if (status != SONY2FUJI_STATUS_OK) throw std::runtime_error(sony2fuji_status_message(status));
}

int main(int argc, char** argv) {
    try {
        if (argc != 8 && argc != 9)
            throw std::runtime_error("usage: processing_export_probe INPUT OUTPUT VERSION GPU LUMA CHROMA COARSE [KELVIN]");
        sony2fuji_session* pointer = nullptr;
        check(sony2fuji_session_create(&pointer));
        std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)> session(pointer, sony2fuji_session_destroy);
        const int version = std::stoi(argv[3]);
#if defined(RAWLAB_LEGACY_REFERENCE)
        // 同一探针可链接到 v0.8.2；发布版尚无版本 setter，只允许测旧基准。
        if (version != 1) throw std::runtime_error("released reference only supports processing 1");
#else
        check(sony2fuji_session_set_processing_version(pointer, static_cast<sony2fuji_processing_version>(version)));
#endif
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu),
            static_cast<sony2fuji_gpu_mode>(std::stoi(argv[4]))};
        check(sony2fuji_session_set_gpu_config(pointer, &gpu));
        check(sony2fuji_session_set_raw_exposure_mode(pointer, SONY2FUJI_EXPOSURE_PREVIEW));
        sony2fuji_wavelet_denoise_config wavelet{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(wavelet),
            1, std::stof(argv[5]), std::stof(argv[6]), std::stof(argv[7])};
        wavelet.enabled = wavelet.luma > 0 || wavelet.chroma > 0;
        check(sony2fuji_session_set_wavelet_denoise(pointer, &wavelet));
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = argv[1];
        request.output_target = SONY2FUJI_TARGET_FILE; request.output_path = argv[2];
        request.output_format = SONY2FUJI_OUTPUT_PNG; request.size_mode = SONY2FUJI_SIZE_NATIVE;
        request.intent = SONY2FUJI_INTENT_FINAL;
        request.brightness = request.contrast = request.saturation = 1;
        request.wb_mode = argc == 9 ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA;
        request.temperature = argc == 9 ? std::stof(argv[8]) : 6500;
        check(sony2fuji_process(pointer, &request, nullptr));
        float baseline = 0, metadata = 0;
        check(sony2fuji_session_get_raw_exposure(pointer, &baseline, &metadata));
        std::cout << "{\"processing\":" << version << ",\"backend\":" <<
            sony2fuji_session_get_last_backend(pointer) << ",\"baseline_ev\":" << baseline << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
