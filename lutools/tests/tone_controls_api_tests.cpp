#include "sony2fuji/ffi/sony2fuji_c.h"
#include "native_gpu_test_support.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static sony2fuji_request requestFor(const std::vector<uint8_t>& pixels) {
    sony2fuji_request r{};
    r.version=SONY2FUJI_REQUEST_VERSION; r.struct_size=sizeof(r);
    r.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER; r.input_pixels=pixels.data();
    r.input_width=static_cast<uint32_t>(pixels.size()/3); r.input_height=1;
    r.input_pixel_format=SONY2FUJI_PIXEL_RGB8; r.input_color_space=SONY2FUJI_COLOR_SRGB;
    r.wb_mode=SONY2FUJI_WB_CAMERA; r.temperature=6500;
    r.brightness=r.contrast=r.saturation=1;
    r.output_target=SONY2FUJI_TARGET_BUFFER; r.output_format=SONY2FUJI_OUTPUT_RGB8;
    r.size_mode=SONY2FUJI_SIZE_NATIVE; r.intent=SONY2FUJI_INTENT_FINAL;
    return r;
}

static std::vector<uint8_t> render(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_OK,"native render succeeds");
    const auto* data=static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(data,data+buffer.size_bytes);
    sony2fuji_release_buffer(&buffer); return result;
}

int main(int argc, char** argv) {
    sony2fuji_session* session=nullptr;
    try {
        static_assert(sizeof(sony2fuji_request)==(sizeof(void*)==8 ? 184u : 156u),"request v2 unchanged");
        static_assert(sizeof(sony2fuji_tone_controls_config)==20,"additive tone config ABI");
        require(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK,"create session");
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_OFF};
        require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"CPU mode");
        const std::vector<uint8_t> pixels{0,0,0,51,51,51,128,128,128,255,255,255,180,130,90,80,120,160};
        auto request=requestFor(pixels);
        const auto original=render(session,request);
        require(original==pixels,"display baseline bytes preserved");
        sony2fuji_tone_controls_config config{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION,sizeof(config),0,0,0};
        require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"identity setter");
        require(render(session,request)==original,"zero controls preserve old output");
        config.black_point=1; config.white_point=-1; config.vibrance=.7f;
        require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"active setter");
        const auto changed=render(session,request);
        require(changed[0]==51 && changed[9]==204 && changed!=original,"endpoint controls reach rendering");
        require(!std::equal(changed.begin()+12,changed.end(),original.begin()+12),"vibrance reaches rendering");
        require(sony2fuji_session_set_tone_controls(nullptr,&config)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null session rejected");
        require(sony2fuji_session_set_tone_controls(session,nullptr)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null config rejected");
        for (int kind=0;kind<5;++kind) {
            auto bad=config;
            if (kind==0) bad.version=2;
            if (kind==1) --bad.struct_size;
            if (kind==2) ++bad.struct_size;
            if (kind==3) bad.black_point=-1.01f;
            if (kind==4) bad.white_point=1.01f;
            require(sony2fuji_session_set_tone_controls(session,&bad)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"invalid config rejected");
            require(render(session,request)==changed,"invalid config retains previous state");
        }
        for (float bad : {std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN(),-1.01f,1.01f}) {
            auto invalid=config; invalid.vibrance=bad;
            require(sony2fuji_session_set_tone_controls(session,&invalid)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"invalid vibrance rejected");
            require(render(session,request)==changed,"invalid vibrance retains previous state");
        }
        config.white_point=config.vibrance=0;
        require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"black-only setter");
        request.contrast=1.5f;
        const auto order=render(session,request);
        require(std::abs(int(order[3])-43)<=1,"black point executes before legacy contrast");
        config.black_point=0; config.vibrance=1;
        require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"vibrance-only setter");
        request.contrast=1; request.saturation=0;
        const auto gray=render(session,request);
        for (size_t i=0;i<gray.size();i+=3) require(gray[i]==gray[i+1] && gray[i]==gray[i+2],"vibrance after desaturation cannot recolor");
        request.saturation=1;
        config={SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION,sizeof(config),0,0,0};
        require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"clear reused session");
        require(render(session,request)==original,"next photo never inherits cleared tone state");
        // Legacy contrast can exceed SDR before HSL. A tiny vibrance change must
        // not discard that working residual and suddenly change HSL's result.
        const std::vector<uint8_t> saturated{250,40,40};
        auto combined=requestFor(saturated); combined.contrast=1.8f;
        sony2fuji_hsl_config hsl{SONY2FUJI_HSL_CONFIG_VERSION,sizeof(hsl),{},{},{}};
        hsl.lightness[0]=30;
        require(sony2fuji_session_set_hsl(session,&hsl)==SONY2FUJI_STATUS_OK,"HSL combination");
        const auto combinationBaseline=render(session,combined);
        for (float tiny : {-1e-6f,1e-6f}) {
            config.vibrance=tiny;
            require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"tiny vibrance");
            const auto actual=render(session,combined);
            for (size_t i=0;i<actual.size();++i)
                require(std::abs(int(actual[i])-int(combinationBaseline[i]))<=1,"vibrance is continuous through zero with contrast and HSL");
        }
        hsl.lightness[0]=0;
        require(sony2fuji_session_set_hsl(session,&hsl)==SONY2FUJI_STATUS_OK,"clear HSL");
        config.vibrance=0;
        require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"clear tiny vibrance");
        auto scene=request; scene.input_type=SONY2FUJI_INPUT_BUFFER;
        const bool available=rawlabtest::nativeGpuAvailable();
        for (const auto values : std::vector<std::vector<float>>{{1,-1,1},{-1,1,-1},{.4f,-.3f,.7f},{0,0,-.5f}}) {
            config.black_point=values[0]; config.white_point=values[1]; config.vibrance=values[2];
            gpu.mode=SONY2FUJI_GPU_OFF;
            require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"CPU parity mode");
            require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"parity controls");
            const auto expected=render(session,scene);
            gpu.mode=available ? SONY2FUJI_GPU_FORCE : SONY2FUJI_GPU_AUTO;
            require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"GPU parity mode");
            const auto actual=render(session,scene);
            if (available) require(sony2fuji_session_get_last_backend(session)==rawlabtest::nativeBackend,"active controls execute on required GPU");
            require(actual.size()==expected.size(),"GPU dimensions preserved");
            for (size_t i=0;i<actual.size();++i) require(std::abs(int(actual[i])-int(expected[i]))<=2,"tone GPU RGB8 within two DN");
        }
        gpu.mode=SONY2FUJI_GPU_OFF;
        require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"restore CPU");
        config.black_point=config.white_point=config.vibrance=0;
        require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"restore identity");
        if (argc>1) {
            request.input_type=SONY2FUJI_INPUT_RAW; request.input_path=argv[1];
            request.input_pixels=nullptr; request.input_width=request.input_height=0;
            request.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE; request.long_edge=192;
            const auto baseline=render(session,request);
            config={SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION,sizeof(config),.4f,-.3f,.5f};
            require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"RAW setter");
            require(render(session,request)!=baseline,"RAW tone controls reach same display chain");
            config.black_point=config.white_point=config.vibrance=0;
            require(sony2fuji_session_set_tone_controls(session,&config)==SONY2FUJI_STATUS_OK,"RAW clear");
            require(render(session,request)==baseline,"RAW cache reuse preserves identity bytes");
        }
        sony2fuji_session_destroy(session);
        std::cout<<"Tone C ABI, session reset, display stage order and compatibility checks passed\n"; return 0;
    } catch (const std::exception& error) {
        sony2fuji_session_destroy(session); std::cerr<<error.what()<<'\n'; return 1;
    }
}
