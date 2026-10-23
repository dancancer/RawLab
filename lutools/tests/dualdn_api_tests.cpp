#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/raw_processor.h"
#include "ai/dualdn_cache.h"
#include "ai/model_package.h"
#include "ai/onnx_graph.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <vector>

void require(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }

int main(int argc, char** argv) {
    sony2fuji_session* session = nullptr;
    try {
        require(argc == 4, "requires RAW, model directory and temporary cache directory");
        require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "session create");
        require(!sony2fuji_session_get_ai_backend(session)[0] && !sony2fuji_session_get_ai_backend(nullptr)[0],
                "unused AI session reported an inference backend");
        sony2fuji_ai_denoise_config config{};
        config.version = SONY2FUJI_AI_DENOISE_CONFIG_VERSION; config.struct_size = sizeof(config);
        config.backend = SONY2FUJI_AI_CPU; config.model_directory = argv[2]; config.cache_directory = argv[3];
        require(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_OK, "disabled AI config");
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = argv[1];
        request.wb_mode = SONY2FUJI_WB_CAMERA; request.temperature = 6500;
        request.brightness = 1; request.saturation = 1;
        request.wb_mul[0] = request.wb_mul[1] = request.wb_mul[2] = request.wb_mul[3] = 1;
        request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
        request.intent = SONY2FUJI_INTENT_FINAL; request.size_mode = SONY2FUJI_SIZE_NATIVE;
        sony2fuji_buffer buffer{};
        require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK && buffer.data, "AI-off render changed");
        sony2fuji_release_buffer(&buffer);
        config.enabled = 1;
        if (!sony2fuji_ai_available()) {
            require(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_UNSUPPORTED, "unsupported build accepted AI");
        } else {
            require(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_OK, "enabled AI config");
            request.wb_mode = SONY2FUJI_WB_AUTO;
            require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_UNSUPPORTED,
                    "unsupported AI auto WB misreported as cache miss");
            request.wb_mode = SONY2FUJI_WB_CAMERA;
            require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_UNSUPPORTED && !buffer.data,
                    "uncalibrated RAW silently rendered with AI enabled");
            require(sony2fuji_session_get_ai_error(session)[0], "missing AI result has no error detail");
            auto cancel = [](void*, int32_t, uint64_t, uint64_t) -> int32_t { return 0; };
            require(sony2fuji_session_prepare_ai(session, &request, cancel, nullptr) == SONY2FUJI_STATUS_CANCELLED,
                    "cancelled AI preparation did not stop");
            require(!std::filesystem::exists(argv[3]), "cancelled AI preparation wrote cache");
            require(sony2fuji_session_prepare_ai(session, &request, nullptr, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
                    "uncalibrated fixture silently received a camera profile");
            require(std::string(sony2fuji_session_get_ai_error(session)).find("calibration") != std::string::npos,
                    "unsupported result did not come from the camera calibration gate");
#ifdef RAWLAB_TEST_AI
            // 为接口回归显式构造恒等缓存；不把此合成相机声称为模型标定结果。
            using namespace sony2fuji;
            using namespace sony2fuji::ai;
            RAWProcessor decoder; RAWBayerSource source; RAWProcessOptions options;
            require(decoder.loadFile(argv[1]) == ErrorCode::Success && decoder.readBayerSource(options, source) == ErrorCode::Success,
                    "synthetic cache source");
            const auto package = loadModelPackage(argv[2]);
            const auto runtimeIdentity = package.digest + ":" + OnnxGraph::runtimeVersion();
            const auto identity = sha256Bytes(runtimeIdentity.data(), runtimeIdentity.size());
            const auto rawKey = rawCacheKey(argv[1], identity, static_cast<int>(Backend::Cpu));
            std::vector<float> mosaic;
            for (int y = 0; y < source.height; ++y) for (int x = 0; x < source.width; ++x) {
                const float black = source.black[source.pattern[(y%2)*2+x%2]];
                mosaic.push_back((source.pixels[size_t(y)*source.width+x]-black)/(source.white-black));
            }
            DenoiseCache cache(argv[3]);
            cache.store(rawKey, CacheKind::Raw, source.width, source.height, mosaic.data(), mosaic.size());
            options.useCameraWhiteBalance = false; options.useTemperatureWhiteBalance = true; options.temperature = 4500;
            const auto rgbKey = rgbCacheKey(rawKey, options);
            std::vector<float> zero(mosaic.size()*3, 0);
            cache.store(rgbKey, CacheKind::RGB, source.width, source.height, zero.data(), zero.size(),
                        sha256Bytes(mosaic.data(), mosaic.size() * sizeof(float)));
            // 即使放入结构正确的完整缓存，也不能绕过相机标定入口。
            require(sony2fuji_session_set_raw_exposure_mode(session, SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK, "preview baseline");
            request.wb_mode = SONY2FUJI_WB_TEMPERATURE; request.temperature = 4500;
            require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_UNSUPPORTED && !buffer.data,
                    "valid cache bypassed the camera calibration gate");
            sony2fuji_release_buffer(&buffer);
            std::filesystem::remove_all(argv[3]);
#endif
        }
        config.enabled = 0;
        require(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_OK &&
            sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK, "AI disable did not restore rendering");
        sony2fuji_release_buffer(&buffer); sony2fuji_session_destroy(session);
        std::cout << "PASS AI C ABI default-off, not-ready, cancellation and unsupported input\n";
        return 0;
    } catch (const std::exception& error) {
        sony2fuji_session_destroy(session); std::cerr << error.what() << '\n'; return 1;
    }
}
