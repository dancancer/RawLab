// C8 回归：CPU 非视口预览不得移走大图 RAW 缓存；预览后的导出不得整幅重解码。
// 解码次数由 sony2fuji_session_get_raw_decode_count 探针给出。内置小图段常跑；
// 大图段按 *_raw 三态惯例（同 wavelet_exposure_cache）：raw_cache_preview_raw 传
// SONY2FUJI_TEST_RAW 或 RAWLAB_TEST_RAW，无素材/≤128 MiB 退出 77（ctest Skipped），
// 显式传入不存在的路径退出 1。
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

using Session = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;

namespace {

// 与 WaveletRenderCache::defaultPreviewBudget 一致（lutools/src/core/wavelet_cache.h）。
constexpr uint64_t kRawCacheBudgetBytes = 128ull * 1024ull * 1024ull;
constexpr uint64_t kRGBFloatBytes = 12;

struct Sample {
    uint64_t decodes;
    double ms;
};

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

Session makeSession(int viewport, bool wavelet) {
    sony2fuji_session* pointer = nullptr;
    require(sony2fuji_session_create(&pointer) == SONY2FUJI_STATUS_OK, "session create");
    Session session(pointer, sony2fuji_session_destroy);
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    require(sony2fuji_session_set_gpu_config(pointer, &gpu) == SONY2FUJI_STATUS_OK, "gpu off");
    require(sony2fuji_session_set_interactive_preview(pointer, 0) == SONY2FUJI_STATUS_OK, "interactive");
    require(sony2fuji_session_set_viewport_preview(pointer, viewport) == SONY2FUJI_STATUS_OK, "viewport");
    sony2fuji_wavelet_denoise_config denoise{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(denoise),
        wavelet ? 1 : 0, 60, 0, 0};
    require(sony2fuji_session_set_wavelet_denoise(pointer, &denoise) == SONY2FUJI_STATUS_OK, "wavelet");
    return session;
}

// exposure_ev 不参与 RAW 缓存键，调整它模拟滑杆的后续帧。
// 指针语义：input_path 只引用调用方保活的 C 字符串，request 不得比它活得更久。
sony2fuji_request makeRequest(const char* path, bool exportFrame, uint32_t long_edge) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = path;
    request.temperature = 6500;
    request.brightness = request.contrast = request.saturation = 1;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.intent = exportFrame ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
    request.size_mode = long_edge > 0 ? SONY2FUJI_SIZE_LIMIT_LONG_EDGE : SONY2FUJI_SIZE_NATIVE;
    request.long_edge = long_edge;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    return request;
}

Sample render(sony2fuji_session* session, const sony2fuji_request& request) {
    const uint64_t before = sony2fuji_session_get_raw_decode_count(session);
    const auto start = std::chrono::steady_clock::now();
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK, "render failed");
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    require(buffer.data != nullptr && buffer.size_bytes > 0, "render produced an empty buffer");
    sony2fuji_release_buffer(&buffer);
    return {sony2fuji_session_get_raw_decode_count(session) - before, ms};
}

void expect(const Sample& sample, uint64_t decodes, const std::string& name, std::vector<std::string>& failures) {
    std::cout << name << ": decodes=+" << sample.decodes << ", " << sample.ms << " ms\n";
    if (sample.decodes != decodes)
        failures.push_back(name + ": expected +" + std::to_string(decodes) +
            " decode(s), got +" + std::to_string(sample.decodes));
}

// 通用保留段：小图缓存本就走拷贝分支，预览与导出都必须复用同一次解码。
void retentionChecks(const std::string& path, std::vector<std::string>& failures) {
    auto session = makeSession(0, false);
    auto preview = makeRequest(path.c_str(), false, 0);
    expect(render(session.get(), preview), 1, "retention first preview", failures);
    preview.exposure_ev = 0.25f;
    expect(render(session.get(), preview), 0, "retention adjusted preview", failures);
    auto exportFrame = makeRequest(path.c_str(), true, 0);
    expect(render(session.get(), exportFrame), 0, "retention export", failures);
    expect(render(session.get(), exportFrame), 0, "retention export again", failures);
}

// C8 验收段（大图）：非视口预览保留缓存，预览后的导出不重解码；
// 导出完成后释放缓存（下一次导出重新解码），视口预览对照组行为不变，
// 小波非视口预览同样保留大图缓存。
void largeRawChecks(const std::string& path, std::vector<std::string>& failures) {
    auto session = makeSession(0, false);
    auto preview = makeRequest(path.c_str(), false, 0);
    expect(render(session.get(), preview), 1, "large first preview", failures);
    preview.exposure_ev = 0.25f;
    expect(render(session.get(), preview), 0, "large adjusted preview", failures);
    auto exportFrame = makeRequest(path.c_str(), true, 0);
    expect(render(session.get(), exportFrame), 0, "large export after preview", failures);
    expect(render(session.get(), exportFrame), 1, "large export after release", failures);

    auto viewport = makeSession(1, false);
    auto viewportPreview = makeRequest(path.c_str(), false, 2000);
    expect(render(viewport.get(), viewportPreview), 1, "viewport preview", failures);
    viewportPreview.exposure_ev = -0.25f;
    expect(render(viewport.get(), viewportPreview), 0, "viewport adjusted preview", failures);

    auto wavelet = makeSession(0, true);
    auto waveletPreview = makeRequest(path.c_str(), false, 0);
    expect(render(wavelet.get(), waveletPreview), 1, "wavelet preview", failures);
    waveletPreview.exposure_ev = 0.5f;
    expect(render(wavelet.get(), waveletPreview), 0, "wavelet adjusted preview", failures);
}

} // namespace

int main(int argc, char** argv) {
    try {
        std::vector<std::string> failures;
        retentionChecks(std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng", failures);
        for (const auto& failure : failures) std::cerr << "FAIL: " << failure << '\n';
        if (!failures.empty()) return 1;
        if (argc < 2) {
            std::cout << "PASS: raw cache retention; large RAW checks need an external fixture\n";
            return 0;
        }
        const char* argRaw = *argv[1] ? argv[1] : nullptr;
        const char* envRaw = std::getenv("RAWLAB_TEST_RAW");
        if (envRaw && !*envRaw) envRaw = nullptr;
        const char* rawPath = argRaw ? argRaw : envRaw;
        if (!rawPath) {
            std::cout << "SKIP raw_cache_preview_raw: supply SONY2FUJI_TEST_RAW or RAWLAB_TEST_RAW\n";
            return 77;
        }
        if (!std::filesystem::is_regular_file(std::filesystem::u8path(rawPath))) {
            std::cerr << "FAIL raw_cache_preview_raw: RAW sample does not exist: " << rawPath << '\n';
            return 1;
        }
        sony2fuji_session* probe = nullptr;
        require(sony2fuji_session_create(&probe) == SONY2FUJI_STATUS_OK, "probe session");
        auto probeRequest = makeRequest(rawPath, false, 0);
        sony2fuji_buffer buffer{};
        require(sony2fuji_process(probe, &probeRequest, &buffer) == SONY2FUJI_STATUS_OK, "probe render");
        const uint64_t cacheBytes = static_cast<uint64_t>(buffer.width) * buffer.height * kRGBFloatBytes;
        const uint32_t width = buffer.width, height = buffer.height;
        sony2fuji_release_buffer(&buffer);
        sony2fuji_session_destroy(probe);
        if (cacheBytes <= kRawCacheBudgetBytes) {
            std::cout << "SKIP raw_cache_preview_raw: " << rawPath << " decodes to "
                      << (cacheBytes / (1024 * 1024)) << " MiB (<= 128 MiB budget)\n";
            return 77;
        }
        std::cout << rawPath << " " << width << "x" << height << " decodes to "
                  << (cacheBytes / (1024 * 1024)) << " MiB (> 128 MiB budget)\n";
        largeRawChecks(rawPath, failures);
        for (const auto& failure : failures) std::cerr << "FAIL: " << failure << '\n';
        if (!failures.empty()) return 1;
        std::cout << "raw cache preview checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
