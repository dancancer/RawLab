#include "core/wavelet_cache.h"
#include "native_gpu_test_support.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Session = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;
using Probe = std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)>;

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

sony2fuji_request makeRawRequest(const char* path) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = path;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.temperature = 6500;
    request.brightness = 1.0f;
    request.contrast = 1.0f;
    request.saturation = 1.0f;
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    return request;
}

std::vector<uint8_t> render(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_process(session, &request, &buffer);
    require(status == SONY2FUJI_STATUS_OK, "sony2fuji_process failed with status " + std::to_string(status));
    const auto* bytes = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> pixels(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return pixels;
}

Probe createProbe(sony2fuji_session* session, const sony2fuji_request& request, uint64_t requestRevision) {
    sony2fuji_hsl_probe* probe = nullptr;
    const auto status = sony2fuji_session_create_hsl_probe(session, &request, 1, requestRevision, &probe);
    require(status == SONY2FUJI_STATUS_OK && probe != nullptr,
        "sony2fuji_session_create_hsl_probe failed with status " + std::to_string(status));
    return Probe(probe, sony2fuji_hsl_probe_destroy);
}

Session makeWaveletSession(sony2fuji_gpu_mode gpuMode, sony2fuji_processing_version version) {
    sony2fuji_session* handle = nullptr;
    require(sony2fuji_session_create(&handle) == SONY2FUJI_STATUS_OK, "session create");
    Session session(handle, sony2fuji_session_destroy);
    require(sony2fuji_session_set_processing_version(handle, version) == SONY2FUJI_STATUS_OK,
        "set processing version");
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), gpuMode};
    require(sony2fuji_session_set_gpu_config(handle, &gpu) == SONY2FUJI_STATUS_OK, "set gpu config");
    sony2fuji_wavelet_denoise_config wavelet{
        SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(wavelet), 1, 40, 46, 50
    };
    require(sony2fuji_session_set_wavelet_denoise(handle, &wavelet) == SONY2FUJI_STATUS_OK,
        "set wavelet denoise");
    return session;
}

void verifySamplingPreservesWaveletCache(
    const char* rawPath, sony2fuji_gpu_mode gpuMode, sony2fuji_processing_version version, const std::string& label
) {
    auto session = makeWaveletSession(gpuMode, version);
    const auto request = makeRawRequest(rawPath);

    const auto firstPixels = render(session.get(), request);
    const auto afterFirstRender = sony2fuji::waveletCacheDiagnostics(session.get());
    require(afterFirstRender.filterRuns == 1,
        label + ": expected 1 initial wavelet filterRun, got " + std::to_string(afterFirstRender.filterRuns));
    const auto renderedBackend = sony2fuji_session_get_last_backend(session.get());

    const auto probe1 = createProbe(session.get(), request, 1);
    sony2fuji_hsl_probe_query query{SONY2FUJI_HSL_PROBE_VERSION, sizeof(query), 1, 1, 0.5f, 0.5f};
    sony2fuji_hsl_probe_result sample{};
    require(sony2fuji_hsl_probe_sample(probe1.get(), &query, &sample) == SONY2FUJI_STATUS_OK,
        label + ": hsl probe sample 1");
    require(sample.availability == SONY2FUJI_HSL_PROBE_AVAILABLE ||
            sample.availability == SONY2FUJI_HSL_PROBE_NEAR_GRAY,
        label + ": probe 1 unexpectedly unavailable");

    const auto afterProbe1 = sony2fuji::waveletCacheDiagnostics(session.get());
    const auto secondPixels = render(session.get(), request);
    const auto afterSecondRender = sony2fuji::waveletCacheDiagnostics(session.get());

    require(secondPixels == firstPixels, label + ": post-sample render changed pixels");
    require(afterSecondRender.filterRuns == afterProbe1.filterRuns,
        label + ": post-sample render recomputed wavelet (filterRuns " +
        std::to_string(afterProbe1.filterRuns) + " -> " + std::to_string(afterSecondRender.filterRuns) + ")");
    require(afterSecondRender.outputHits == afterProbe1.outputHits + 1,
        label + ": post-sample render missed wavelet output cache (outputHits " +
        std::to_string(afterProbe1.outputHits) + " -> " + std::to_string(afterSecondRender.outputHits) + ")");
    require(sony2fuji_session_get_last_backend(session.get()) == renderedBackend,
        label + ": post-sample render backend changed");

    // Repeated probe -> render cycle must also stay on the wavelet output cache.
    const auto probe2 = createProbe(session.get(), request, 2);
    const auto afterProbe2 = sony2fuji::waveletCacheDiagnostics(session.get());
    const auto thirdPixels = render(session.get(), request);
    const auto afterThirdRender = sony2fuji::waveletCacheDiagnostics(session.get());
    require(thirdPixels == firstPixels, label + ": third render changed pixels");
    require(afterThirdRender.filterRuns == afterProbe2.filterRuns,
        label + ": second post-sample render recomputed wavelet");
    require(afterThirdRender.outputHits == afterProbe2.outputHits + 1,
        label + ": second post-sample render missed wavelet output cache");
}

void verifyProbeBeforeRenderReusesCpuWavelet(const char* rawPath) {
    auto session = makeWaveletSession(SONY2FUJI_GPU_AUTO, SONY2FUJI_PROCESSING_C5_V2);
    const auto request = makeRawRequest(rawPath);

    const auto probe = createProbe(session.get(), request, 1);
    const auto afterProbe = sony2fuji::waveletCacheDiagnostics(session.get());
    require(afterProbe.filterRuns == 1,
        "probe-first C5_V2: expected 1 filterRun during initial probe, got " +
        std::to_string(afterProbe.filterRuns));

    const auto pixels = render(session.get(), request);
    const auto afterRender = sony2fuji::waveletCacheDiagnostics(session.get());
    require(!pixels.empty(), "probe-first C5_V2: empty render");
    require(afterRender.filterRuns == 1,
        "probe-first C5_V2: render after CPU wavelet probe recomputed wavelet");
    require(afterRender.outputHits == afterProbe.outputHits + 1,
        "probe-first C5_V2: render after CPU wavelet probe missed cache");
}

} // namespace

int main() {
    try {
        const std::string fixture = std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
        verifySamplingPreservesWaveletCache(fixture.c_str(), SONY2FUJI_GPU_AUTO, SONY2FUJI_PROCESSING_C5_V2,
            "Auto/C5_V2");
        verifySamplingPreservesWaveletCache(fixture.c_str(), SONY2FUJI_GPU_AUTO, SONY2FUJI_PROCESSING_LEGACY,
            "Auto/Legacy");
        if (rawlabtest::nativeGpuAvailable()) {
            verifySamplingPreservesWaveletCache(fixture.c_str(), SONY2FUJI_GPU_FORCE, SONY2FUJI_PROCESSING_LEGACY,
                "Force/Legacy");
        }
        verifyProbeBeforeRenderReusesCpuWavelet(fixture.c_str());
        std::cout << "PASS: HSL sampling preserves wavelet output cache across Auto/Force and C5_V2/Legacy\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
