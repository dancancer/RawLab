#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"
#include "core/wavelet_denoise.h"
#include "core/photo_lut.h"
#include "sony2fuji/lut_applicator.h"
#include <cassert>
#include <cmath>
#include <filesystem>
#include <iostream>
#include <limits>
#include <random>
#include <vector>

int main() {
    const bool nativeGpu = rawlabtest::nativeGpuAvailable();
    sony2fuji_session* session=nullptr;
    assert(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK);
    sony2fuji_wavelet_denoise_config options{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,sizeof(options),0,40,46,50};
    assert(sony2fuji_session_set_wavelet_denoise(nullptr,&options)==SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(sony2fuji_session_set_wavelet_denoise(session,nullptr)==SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(sony2fuji_session_set_wavelet_denoise(session,&options)==SONY2FUJI_STATUS_OK);
    auto invalid=options; invalid.chroma=101;
    assert(sony2fuji_session_set_wavelet_denoise(session,&invalid)==SONY2FUJI_STATUS_INVALID_ARGUMENT);
    invalid=options; invalid.luma=std::numeric_limits<float>::quiet_NaN();
    assert(sony2fuji_session_set_wavelet_denoise(session,&invalid)==SONY2FUJI_STATUS_INVALID_ARGUMENT);
    std::vector<unsigned char> input(256*256*3);
    std::mt19937 rng(42);
    std::normal_distribution<float> noise(46,4);
    for (auto& value:input) value=static_cast<unsigned char>(std::lround(noise(rng)));
    sony2fuji_request request{};
    request.version=SONY2FUJI_REQUEST_VERSION; request.struct_size=sizeof(request);
    request.input_type=SONY2FUJI_INPUT_BUFFER; request.input_pixels=input.data();
    request.input_width=request.input_height=256; request.input_pixel_format=SONY2FUJI_PIXEL_RGB8;
    request.input_color_space=SONY2FUJI_COLOR_SRGB; request.input_is_linear=1;
    request.brightness=request.contrast=request.saturation=1; request.temperature=6500;
    request.wb_mode=SONY2FUJI_WB_CAMERA; request.intent=SONY2FUJI_INTENT_FINAL;
    request.size_mode=SONY2FUJI_SIZE_EXACT; request.target_width=request.target_height=100;
    request.output_target=SONY2FUJI_TARGET_BUFFER; request.output_format=SONY2FUJI_OUTPUT_RGB8;
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_OFF};
    assert(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK);
    auto render=[&]() {
        sony2fuji_buffer buffer{};
        assert(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_OK);
        const auto* bytes=static_cast<const unsigned char*>(buffer.data);
        std::vector<unsigned char> result(bytes,bytes+buffer.size_bytes);
        sony2fuji_release_buffer(&buffer);
        return result;
    };
    const auto off=render();
    options.enabled=1;
    assert(sony2fuji_session_set_wavelet_denoise(session,&options)==SONY2FUJI_STATUS_OK);
    const auto exact=render();
    assert(exact!=off);
    request.intent=SONY2FUJI_INTENT_PREVIEW;
    assert(render()==exact);
    assert(sony2fuji_session_set_interactive_preview(session,1)==SONY2FUJI_STATUS_OK);
    const auto fast=render();
    assert(fast!=exact);
    request.intent=SONY2FUJI_INTENT_FINAL;
    assert(render()==exact); // An interactive flag must never downgrade final output.
    assert(sony2fuji_session_set_interactive_preview(session,0)==SONY2FUJI_STATUS_OK);
    gpu.mode=SONY2FUJI_GPU_AUTO;
    assert(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK);
    const auto automatic = render();
    if (nativeGpu) {
        assert(sony2fuji_session_get_last_backend(session)==rawlabtest::nativeBackend);
        for (size_t i=0;i<exact.size();++i) assert(std::abs(int(automatic[i])-int(exact[i]))<=2);
    } else assert(automatic==exact && sony2fuji_session_get_last_backend(session)==SONY2FUJI_BACKEND_CPU);
    gpu.mode=SONY2FUJI_GPU_FORCE;
    assert(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK);
    sony2fuji_buffer rejected{};
    if (nativeGpu) {
        assert(sony2fuji_process(session,&request,&rejected)==SONY2FUJI_STATUS_OK);
        assert(sony2fuji_session_get_last_backend(session)==rawlabtest::nativeBackend);
        sony2fuji_release_buffer(&rejected);
    } else assert(sony2fuji_process(session,&request,&rejected)==SONY2FUJI_STATUS_PROCESSING_ERROR);
    gpu.mode=SONY2FUJI_GPU_OFF;
    assert(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK);
    options.enabled=0;
    assert(sony2fuji_session_set_wavelet_denoise(session,&options)==SONY2FUJI_STATUS_OK);
    assert(render()==off);
    options.enabled=1; options.luma=options.chroma=0;
    assert(sony2fuji_session_set_wavelet_denoise(session,&options)==SONY2FUJI_STATUS_OK);
    assert(render()==off);

    options.luma=40; options.chroma=46;
    assert(sony2fuji_session_set_wavelet_denoise(session,&options)==SONY2FUJI_STATUS_OK);
    const auto path=(std::filesystem::path(TEST_SOURCE_DIR)/"flog-2-new/FLog2_to_PROVIA_65grid_V.1.00.cube").string();
    request.lut_path=path.c_str(); request.lut_strength=1;
    request.size_mode=SONY2FUJI_SIZE_NATIVE;
    const auto actual=render();
    sony2fuji::ImageData reference(256,256);
    for (size_t i=0;i<reference.pixels.size();++i)
        reference.pixels[i]={input[i*3]/255.f,input[i*3+1]/255.f,input[i*3+2]/255.f};
    assert(sony2fuji::applyWaveletDenoise(reference,{true,40,46,50})==sony2fuji::ErrorCode::Success);
    auto lut=sony2fuji::LUTParser::loadLUTCached(path);
    assert(lut);
    sony2fuji::encodePhotoLUTInput(reference,lut->inputTransfer());
    assert(sony2fuji::LUTApplicator(lut).applyToImage(reference)==sony2fuji::ErrorCode::Success);
    sony2fuji::renderPhotoLUTOutput(reference,lut->outputTransfer());
    const float* channels=reinterpret_cast<const float*>(reference.pixels.data());
    for (size_t i=0;i<actual.size();++i) {
        const int expected=static_cast<int>(std::lround(std::clamp(channels[i],0.f,1.f)*255));
        assert(std::abs(expected-int(actual[i]))<=1);
    }
    sony2fuji_session_destroy(session);
    std::cout << "PASS: wavelet API, exact/interactive/final contracts, zero/off restoration, GPU policy, pre-LUT placement\n";
}
