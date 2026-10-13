#include "core/wavelet_cache.h"
#include "gpu/denoise.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <atomic>
#include <cassert>
#include <iostream>
#include <vector>

static std::atomic<int> failures{0};

// 仅此测试替换静态库的 GPU 滤波实现，不在生产接口加入故障开关。
namespace sony2fuji {
bool gpuWaveletFilter(const float*, int, int, const WaveletFilterSettings&, float*) {
    ++failures;
    return false;
}
bool gpuGuidedFilter(const float*, const float*, int, int, int, float, float*) { return false; }
bool gpuPhotoEffects(ImageData&, const PhotoEffectsOptions&) { return false; }
bool gpuDetailFilter(ImageData&, float, float) { return false; }
}

int main(int argc, char** argv) {
    assert(argc==2);
    sony2fuji_request request{};
    request.version=SONY2FUJI_REQUEST_VERSION; request.struct_size=sizeof(request);
    request.input_type=SONY2FUJI_INPUT_RAW; request.input_path=argv[1];
    request.temperature=6500; request.brightness=request.contrast=request.saturation=1;
    request.wb_mode=SONY2FUJI_WB_TEMPERATURE; request.intent=SONY2FUJI_INTENT_FINAL;
    request.size_mode=SONY2FUJI_SIZE_FIT_LONG_EDGE; request.long_edge=128;
    request.output_target=SONY2FUJI_TARGET_BUFFER; request.output_format=SONY2FUJI_OUTPUT_RGB8;
    auto create=[](sony2fuji_gpu_mode mode) {
        sony2fuji_session* session=nullptr;
        assert(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK);
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),mode};
        assert(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK);
        sony2fuji_wavelet_denoise_config denoise{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,sizeof(denoise),1,10,72,100};
        assert(sony2fuji_session_set_wavelet_denoise(session,&denoise)==SONY2FUJI_STATUS_OK);
        return session;
    };
    auto render=[&](sony2fuji_session* session) {
        sony2fuji_buffer buffer{};
        assert(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_OK);
        assert(buffer.data && buffer.size_bytes>0);
        const auto* bytes=static_cast<const uint8_t*>(buffer.data);
        std::vector<uint8_t> output(bytes,bytes+buffer.size_bytes);
        sony2fuji_release_buffer(&buffer);
        return output;
    };
    auto* cpu=create(SONY2FUJI_GPU_OFF);
    const auto expected=render(cpu);
    sony2fuji_session_destroy(cpu);
    assert(failures==0);
    auto* automatic=create(SONY2FUJI_GPU_AUTO);
    assert(render(automatic)==expected);
    assert(failures>0);
    auto info=sony2fuji::waveletCacheDiagnostics(automatic);
    assert(info.filterRuns==2 && info.analysisHits==1 && info.outputHits==0);
    assert(render(automatic)==expected);
    info=sony2fuji::waveletCacheDiagnostics(automatic);
    assert(info.filterRuns==4 && info.analysisHits==3 && info.outputHits==0);
    sony2fuji_session_destroy(automatic);
    auto* forced=create(SONY2FUJI_GPU_FORCE);
    sony2fuji_buffer buffer{};
    assert(sony2fuji_process(forced,&request,&buffer)==SONY2FUJI_STATUS_PROCESSING_ERROR);
    assert(!buffer.data);
    sony2fuji_release_buffer(&buffer);
    sony2fuji_session_destroy(forced);
    std::cout << "PASS: C API Auto retries released RAW working image; Force reports GPU failure\n";
}
