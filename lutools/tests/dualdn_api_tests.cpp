#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/raw_processor.h"
#include "ai/dualdn_cache.h"
#include "ai/model_package.h"
#include "ai/network_graph.h"
#include "ai/directml_device.h"
#include <filesystem>
#include <fstream>
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
        const auto* firstBytes = static_cast<const uint8_t*>(buffer.data);
        const std::vector<uint8_t> original(firstBytes,firstBytes+buffer.size_bytes);
        sony2fuji_release_buffer(&buffer);
        config.enabled = 1;
        require(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_UNSUPPORTED,
                "CPU AI mode must be unsupported");
#ifdef _WIN32
        config.backend = SONY2FUJI_AI_DIRECTML;
#else
        config.backend = SONY2FUJI_AI_COREML;
#endif
        if (!sony2fuji_ai_available()) {
            require(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_UNSUPPORTED, "unsupported build accepted AI");
        } else {
            require(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_OK, "enabled AI config");
            request.wb_mode = SONY2FUJI_WB_AUTO;
            require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_UNSUPPORTED,
                    "unsupported AI auto WB misreported as cache miss");
            request.wb_mode = SONY2FUJI_WB_CAMERA;
            require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_AI_NOT_READY && !buffer.data,
                    "missing result was rejected by camera brand or silently rendered");
            require(sony2fuji_session_get_ai_error(session)[0], "missing AI result has no error detail");
            auto cancel = [](void*, int32_t, uint64_t, uint64_t) -> int32_t { return 0; };
            require(sony2fuji_session_prepare_ai(session, &request, cancel, nullptr) == SONY2FUJI_STATUS_CANCELLED,
                    "cancelled AI preparation did not stop");
            require(!std::filesystem::exists(argv[3]), "cancelled AI preparation wrote cache");
            auto cancelInference = [](void*,int32_t phase,uint64_t,uint64_t) -> int32_t { return phase < 2; };
            const auto preparation = sony2fuji_session_prepare_ai(session,&request,cancelInference,nullptr);
            bool gpuAvailable = true;
#if defined(_WIN32) && defined(RAWLAB_TEST_AI)
            try { sony2fuji::ai::findDirectMLAdapter(); }
            catch (const std::runtime_error&) { gpuAvailable = false; }
#elif defined(__APPLE__) && defined(RAWLAB_TEST_AI)
            gpuAvailable = sony2fuji::ai::CoreMLGraph::available();
#endif
            require(gpuAvailable ? preparation == SONY2FUJI_STATUS_CANCELLED :
                    preparation == SONY2FUJI_STATUS_PROCESSING_ERROR && sony2fuji_session_get_ai_error(session)[0],
                    "model preparation neither cancelled nor rejected missing GPU hardware");
            if (!gpuAvailable) std::cout << "PASS unavailable GPU rejected; hardware inference NOT REACHED\n";
            require(!std::filesystem::exists(argv[3]), "cancelled inference wrote a partial cache");
            const auto missingModel = std::string(argv[2])+"-missing";
            config.model_directory = missingModel.c_str();
            require(sony2fuji_session_set_ai_denoise(session,&config) == SONY2FUJI_STATUS_OK, "missing package configuration");
            require(sony2fuji_process(session,&request,&buffer) == SONY2FUJI_STATUS_PROCESSING_ERROR && !buffer.data,
                    "missing model was treated as a retryable cache miss");
            config.model_directory = argv[2];
            require(sony2fuji_session_set_ai_denoise(session,&config) == SONY2FUJI_STATUS_OK, "restored model configuration");
            const auto invalidSource = std::string(argv[3])+"-invalid.raw";
            { std::ofstream file(std::filesystem::u8path(invalidSource),std::ios::binary); file << std::string(4096,'x'); }
            request.input_path = invalidSource.c_str();
            const auto invalidStatus = sony2fuji_session_prepare_ai(session,&request,nullptr,nullptr);
            request.input_path = argv[1]; std::filesystem::remove(std::filesystem::u8path(invalidSource));
            require(invalidStatus == SONY2FUJI_STATUS_UNSUPPORTED,"RAW decode error lost unsupported classification");
#ifdef RAWLAB_TEST_AI
            // 恒等 RGB 缓存验证 ABI 的实际颜色/曝光路径，模型本身另做 GPU 数值回归。
            using namespace sony2fuji;
            using namespace sony2fuji::ai;
            RAWProcessor decoder; ImageData source; RAWProcessOptions options;
            require(decoder.loadFile(argv[1]) == ErrorCode::Success && decoder.process(options, source) == ErrorCode::Success,
                    "synthetic cache source");
            const auto package = loadModelPackage(argv[2]);
            const auto runtimeIdentity = package.digest + ":" + NetworkGraph::runtimeVersion(static_cast<Backend>(config.backend));
            const auto identity = sha256Bytes(runtimeIdentity.data(), runtimeIdentity.size());
            const auto rawKey = rawCacheKey(argv[1], identity, static_cast<int>(config.backend));
            DenoiseCache cache(argv[3]);
            const auto sceneKey = sceneRGBCacheKey(rawKey,options);
            std::vector<float> zero(source.pixels.size()*3,0);
            cache.store(sceneKey,CacheKind::SceneRGB,source.width,source.height,zero.data(),zero.size(),{},"test-identity");
            require(sony2fuji_process(session,&request,&buffer) == SONY2FUJI_STATUS_OK && buffer.data,
                    "complete generic RGB cache did not render");
            require(buffer.size_bytes == original.size() &&
                    std::equal(original.begin(),original.end(),static_cast<const uint8_t*>(buffer.data)),
                    "generic RGB identity changed the original render");
            require(std::string(sony2fuji_session_get_ai_backend(session)) == "SceneRGB=test-identity", "generic cache lost producer");
            sony2fuji_release_buffer(&buffer);
            request.wb_mode = SONY2FUJI_WB_TEMPERATURE; request.temperature = 4500;
            require(sony2fuji_process(session,&request,&buffer) == SONY2FUJI_STATUS_AI_NOT_READY && !buffer.data,
                    "white balance reused an incompatible generic cache");
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
