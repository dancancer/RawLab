#include "core/wavelet_cache.h"
#include <chrono>
#include <iostream>

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    sony2fuji_session* session=nullptr;
    if (sony2fuji_session_create(&session)!=SONY2FUJI_STATUS_OK) return 1;
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_AUTO};
    sony2fuji_session_set_gpu_config(session,&gpu);
    sony2fuji_session_set_viewport_preview(session,1);
    sony2fuji_session_set_raw_exposure_mode(session,SONY2FUJI_EXPOSURE_PREVIEW);
    sony2fuji_request request{};
    request.version=SONY2FUJI_REQUEST_VERSION; request.struct_size=sizeof(request);
    request.input_type=SONY2FUJI_INPUT_RAW; request.input_path=argv[1];
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.temperature=6500;
    request.brightness=request.contrast=request.saturation=request.lut_strength=1;
    request.lut_path=argv[2]; request.intent=SONY2FUJI_INTENT_PREVIEW;
    request.size_mode=SONY2FUJI_SIZE_NATIVE; request.preview_long_edge=1600;
    request.output_target=SONY2FUJI_TARGET_BUFFER; request.output_format=SONY2FUJI_OUTPUT_RGBA8;
    auto render=[&](const char* label) {
        const auto before=sony2fuji::waveletCacheDiagnostics(session);
        sony2fuji_buffer buffer{};
        const auto start=std::chrono::steady_clock::now();
        const auto status=sony2fuji_process(session,&request,&buffer);
        const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        sony2fuji_release_buffer(&buffer);
        const auto after=sony2fuji::waveletCacheDiagnostics(session);
        std::cout<<label<<" "<<ms<<" ms, filter="<<after.filterRuns-before.filterRuns
                 <<", output-hit="<<after.outputHits-before.outputHits
                 <<", analysis-hit="<<after.analysisHits-before.analysisHits
                 <<", preview-bytes="<<after.previewBytes<<", status="<<status<<std::endl;
        return status==SONY2FUJI_STATUS_OK;
    };
    bool ok=render("raw-warm");
    sony2fuji_wavelet_denoise_config options{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,sizeof(options),1,0,46,50};
    sony2fuji_session_set_wavelet_denoise(session,&options);
    ok=render("denoise-1600-cold")&&ok;
    for (float exposure : {-.2f,0.f,.2f}) {
        request.exposure_ev=exposure;
        ok=render("exposure-1600-hit")&&ok;
    }
    request.preview_long_edge=1200; ok=render("resize-1200-cold")&&ok;
    request.preview_long_edge=1600; ok=render("return-1600-hit")&&ok;
    options.chroma=60; sony2fuji_session_set_wavelet_denoise(session,&options);
    ok=render("strength-analysis-hit")&&ok;
    options.enabled=0; sony2fuji_session_set_wavelet_denoise(session,&options);
    ok=render("disabled")&&ok;
    options.enabled=1; sony2fuji_session_set_wavelet_denoise(session,&options);
    ok=render("reenabled-output-hit")&&ok;
    sony2fuji_session_destroy(session);
    return ok ? 0 : 1;
}
