#include "core/wavelet_cache.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <cassert>
#include <filesystem>
#include <iostream>
#include <vector>

using namespace sony2fuji;

static void checkPreviewExposureRoundTrip(const char* path, bool viewport, bool strengthChange, int initialFbdd) {
    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    assert(sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_viewport_preview(session, viewport ? 1 : 0) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_raw_exposure_mode(session, SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK);
    sony2fuji_wavelet_denoise_config config{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(config), 1, 40, 46, 50};
    if (!viewport) { config.chroma = 0; config.coarse = 0; }
    assert(sony2fuji_session_set_wavelet_denoise(session, &config) == SONY2FUJI_STATUS_OK);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path;
    request.temperature = 8000; request.brightness = request.contrast = request.saturation = 1;
    request.wb_mode = SONY2FUJI_WB_CAMERA; request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.size_mode = SONY2FUJI_SIZE_NATIVE; request.preview_long_edge = 512;
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    auto render = [&](sony2fuji_session* target) {
        sony2fuji_buffer buffer{};
        assert(sony2fuji_process(target, &request, &buffer) == SONY2FUJI_STATUS_OK);
        const auto* bytes = static_cast<const uint8_t*>(buffer.data);
        std::vector<uint8_t> pixels(bytes, bytes + buffer.size_bytes);
        sony2fuji_release_buffer(&buffer);
        return pixels;
    };
    assert(sony2fuji_session_set_raw_noise_reduction(session, initialFbdd) == SONY2FUJI_STATUS_OK);
    render(session);
    float oldEV = 0, metadata = 0;
    assert(sony2fuji_session_get_raw_exposure(session, &oldEV, &metadata) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_raw_noise_reduction(session, 1) == SONY2FUJI_STATUS_OK);
    request.wb_mode = SONY2FUJI_WB_TEMPERATURE;
    render(session);
    if (!viewport) {
        config.enabled = 0;
        assert(sony2fuji_session_set_wavelet_denoise(session, &config) == SONY2FUJI_STATUS_OK);
    }
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    render(session);
    float newEV = 0;
    assert(sony2fuji_session_get_raw_exposure(session, &newEV, &metadata) == SONY2FUJI_STATUS_OK);
    request.wb_mode = SONY2FUJI_WB_TEMPERATURE;
    config.enabled = 1;
    if (strengthChange) config.chroma = 72;
    assert(sony2fuji_session_set_wavelet_denoise(session, &config) == SONY2FUJI_STATUS_OK);
    const auto before = waveletCacheDiagnostics(session);
    const auto restored = render(session);
    const auto after = waveletCacheDiagnostics(session);
    sony2fuji_session* fresh = nullptr;
    assert(sony2fuji_session_create(&fresh) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_gpu_config(fresh, &gpu) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_viewport_preview(fresh, viewport ? 1 : 0) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_raw_exposure_mode(fresh, SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_raw_noise_reduction(fresh, 1) == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_wavelet_denoise(fresh, &config) == SONY2FUJI_STATUS_OK);
    const auto expected = render(fresh);
    assert(expected.size() == restored.size());
    size_t differences = 0;
    for (size_t i = 0; i < expected.size(); ++i) differences += expected[i] != restored[i];
    std::cout << (viewport ? "Viewport" : "Exact") << " anchor FBDD " << initialFbdd << "->1: " << oldEV << " -> " << newEV
              << ", output hits=" << after.outputHits - before.outputHits
              << ", analysis hits=" << after.analysisHits - before.analysisHits
              << ", different bytes=" << differences << std::endl;
    assert(restored == expected);
    if (oldEV != newEV) {
        assert(after.outputHits == before.outputHits && after.analysisHits == before.analysisHits);
        assert(after.filterRuns == before.filterRuns + 1);
    } else if (!strengthChange) {
        assert(after.outputHits == before.outputHits + 1);
    }
    sony2fuji_session_destroy(fresh);
    sony2fuji_session_destroy(session);
}

int main(int argc, char** argv) {
    if (argc > 1) {
        checkPreviewExposureRoundTrip(argv[1], true, false, 2);
        checkPreviewExposureRoundTrip(argv[1], true, true, 2);
        checkPreviewExposureRoundTrip(argv[1], false, false, 2);
        checkPreviewExposureRoundTrip(argv[1], true, false, 1);
    }
    WaveletRenderCache small(256);
    ImageData pixels(4,4);
    WaveletDenoiseOptions options{true,40,46,50};
    auto& a=small.select("a",true);
    small.store(a,pixels,options,GpuMode::Off);
    auto& b=small.select("b",true);
    small.store(b,pixels,options,GpuMode::Off);
    assert(small.previewBytes()<=256 && a.image.pixels.empty() && !b.image.pixels.empty());
    auto& exact=small.select("exact",false);
    small.store(exact,pixels,options,GpuMode::Off);
    ImageData oversized(9,9);
    auto& tooLarge = small.select("oversized",false);
    small.store(tooLarge,oversized,options,GpuMode::Off);
    assert(tooLarge.image.pixels.empty() && !tooLarge.completed);
    small.store(small.select("exact",false),pixels,options,GpuMode::Off);
    small.select("c",true);
    assert(!small.select("exact",false).image.pixels.empty());

    if (argc < 2) {
        std::cout<<"PASS: cache slots and preview budget; RAW pipeline needs an external fixture\n";
        return 0;
    }

    sony2fuji_session* session=nullptr;
    assert(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK);
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_OFF};
    assert(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK);
    sony2fuji_wavelet_denoise_config config{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,sizeof(config),1,40,46,50};
    assert(sony2fuji_session_set_wavelet_denoise(session,&config)==SONY2FUJI_STATUS_OK);
    const std::string path=argv[1];
    sony2fuji_request request{};
    request.version=SONY2FUJI_REQUEST_VERSION; request.struct_size=sizeof(request);
    request.input_type=SONY2FUJI_INPUT_RAW; request.input_path=path.c_str();
    request.temperature=6500; request.brightness=request.contrast=request.saturation=1;
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.intent=SONY2FUJI_INTENT_FINAL;
    request.size_mode=SONY2FUJI_SIZE_NATIVE; request.output_target=SONY2FUJI_TARGET_BUFFER;
    request.output_format=SONY2FUJI_OUTPUT_RGB8;
    auto render=[&]() {
        sony2fuji_buffer buffer{};
        assert(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_OK);
        const auto* bytes=static_cast<const uint8_t*>(buffer.data);
        std::vector<uint8_t> result(bytes,bytes+buffer.size_bytes);
        sony2fuji_release_buffer(&buffer);
        return result;
    };
    const auto native=render();
    assert(waveletCacheDiagnostics(session).filterRuns==1);
    assert(sony2fuji_session_set_viewport_preview(session,1)==SONY2FUJI_STATUS_OK);
    request.intent=SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge=16;
    const auto preview=render();
    request.preview_long_edge=24; render();
    assert(waveletCacheDiagnostics(session).filterRuns==3);
    request.preview_long_edge=16;
    assert(render()==preview && waveletCacheDiagnostics(session).filterRuns==3);
    request.exposure_ev=.5f; request.contrast=1.2f; render();
    assert(waveletCacheDiagnostics(session).filterRuns==3);
    request.exposure_ev=0; request.contrast=1;
    request.intent=SONY2FUJI_INTENT_FINAL;
    assert(render()==native && waveletCacheDiagnostics(session).filterRuns==3);
    config.chroma=72;
    assert(sony2fuji_session_set_wavelet_denoise(session,&config)==SONY2FUJI_STATUS_OK);
    render();
    auto stats=waveletCacheDiagnostics(session);
    assert(stats.filterRuns==4 && stats.analysisHits==1 && stats.outputHits==3);
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.temperature=8000; render();
    stats=waveletCacheDiagnostics(session);
    assert(stats.filterRuns==5 && stats.analysisHits==1);
    gpu.mode=SONY2FUJI_GPU_AUTO;
    assert(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK);
    render();
    stats=waveletCacheDiagnostics(session);
    assert(stats.filterRuns==6 && stats.analysisHits==2);
    assert(stats.previewBytes<=WaveletRenderCache::defaultPreviewBudget);
    sony2fuji_session_destroy(session);
    std::cout<<"PASS: real wavelet call counts, exact/preview slots, size A-B-A, post-filter edits, analysis and backend isolation, memory budget\n";
}
