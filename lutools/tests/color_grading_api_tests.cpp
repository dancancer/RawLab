#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "native_gpu_test_support.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static sony2fuji_request requestFor(const std::vector<uint8_t>& pixels) {
    sony2fuji_request r{};r.version=SONY2FUJI_REQUEST_VERSION;r.struct_size=sizeof(r);
    r.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;r.input_pixels=pixels.data();
    r.input_width=static_cast<uint32_t>(pixels.size()/3);r.input_height=1;
    r.input_pixel_format=SONY2FUJI_PIXEL_RGB8;r.input_color_space=SONY2FUJI_COLOR_SRGB;
    r.wb_mode=SONY2FUJI_WB_CAMERA;r.temperature=6500;r.brightness=r.contrast=r.saturation=1;
    r.output_target=SONY2FUJI_TARGET_BUFFER;r.output_format=SONY2FUJI_OUTPUT_RGB8;
    r.size_mode=SONY2FUJI_SIZE_NATIVE;r.intent=SONY2FUJI_INTENT_FINAL;return r;
}
static std::vector<uint8_t> render(sony2fuji_session* s, const sony2fuji_request& r) {
    sony2fuji_buffer buffer{};require(sony2fuji_process(s,&r,&buffer)==SONY2FUJI_STATUS_OK,"native grading render");
    const auto* p=static_cast<const uint8_t*>(buffer.data);std::vector<uint8_t> out(p,p+buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);return out;
}

int main(int argc, char** argv) {
    sony2fuji_session* session=nullptr;
    try {
        static_assert(sizeof(sony2fuji_request)==(sizeof(void*)==8 ? 184u : 156u),"request v2 ABI unchanged");
        static_assert(sizeof(sony2fuji_color_grading_config)==32,"grading additive ABI");
        require(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK,"session creation");
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_OFF};
        require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"CPU mode");
        const std::vector<uint8_t> pixels{0,0,0,51,51,51,128,128,128,220,220,220,255,255,255,180,130,90,80,120,160};
        auto request=requestFor(pixels);const auto original=render(session,request);
        require(original==pixels,"display baseline bytes");
        sony2fuji_color_grading_config identity{1,sizeof(identity),0,0,0,0,0,0};
        auto config=identity;config.shadows_hue=220;config.shadows_saturation=75;
        config.midtones_hue=110;config.midtones_saturation=35;config.highlights_hue=35;config.highlights_saturation=60;
        require(sony2fuji_session_set_color_grading(session,&config)==SONY2FUJI_STATUS_OK,"active grading setter");
        const auto changed=render(session,request);require(changed!=original,"grading reaches native rendering");
        require(std::equal(changed.begin(),changed.begin()+3,original.begin()) &&
            std::equal(changed.begin()+12,changed.begin()+15,original.begin()+12),"grading preserves black and white endpoints");
        auto invalid=[&](const sony2fuji_color_grading_config& bad) {
            require(sony2fuji_session_set_color_grading(session,&bad)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"invalid grading config rejected");
            require(render(session,request)==changed,"invalid setter preserves full prior grading state");
        };
        require(sony2fuji_session_set_color_grading(nullptr,&config)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null session");
        require(sony2fuji_session_set_color_grading(session,nullptr)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null config");
        auto bad=config;bad.version=2;invalid(bad);bad=config;--bad.struct_size;invalid(bad);bad=config;++bad.struct_size;invalid(bad);
        for (int field=0;field<6;++field) {
            for (float value : {-1.f,field%2==0 ? 360.f : 100.01f,std::numeric_limits<float>::quiet_NaN(),std::numeric_limits<float>::infinity()}) {
                bad=config;float* fields[]={&bad.shadows_hue,&bad.shadows_saturation,&bad.midtones_hue,&bad.midtones_saturation,&bad.highlights_hue,&bad.highlights_saturation};
                *fields[field]=value;invalid(bad);
            }
        }
        auto dormant=identity;dormant.shadows_hue=223;dormant.midtones_hue=111;dormant.highlights_hue=35;
        require(sony2fuji_session_set_color_grading(session,&dormant)==SONY2FUJI_STATUS_OK,"dormant hues setter");
        require(render(session,request)==original,"zero saturation clears reused rendering without discarding valid hue");
        sony2fuji_hsl_config hsl{1,sizeof(hsl),{},{},{}};hsl.hue[0]=50;hsl.lightness[0]=15;
        require(sony2fuji_session_set_hsl(session,&hsl)==SONY2FUJI_STATUS_OK,"HSL setter");
        require(sony2fuji_session_set_color_grading(session,&config)==SONY2FUJI_STATUS_OK,"grading after HSL setter");
        const auto ordered=render(session,request);
        sony2fuji::HslOptions hslOptions;hslOptions.hue[0]=50;hslOptions.lightness[0]=15;
        sony2fuji::ColorGradingOptions grading;
        grading.wheels={sony2fuji::ColorGradingWheel{220,75},sony2fuji::ColorGradingWheel{110,35},sony2fuji::ColorGradingWheel{35,60}};
        for (size_t i=0;i<pixels.size();i+=3) {
            const sony2fuji::RGB p(pixels[i]/255.f,pixels[i+1]/255.f,pixels[i+2]/255.f);
            const auto out=sony2fuji::applyColorGrading(sony2fuji::applyHsl(p,hslOptions),grading);
            int c=0;for (float value : {out.r,out.g,out.b}) require(std::abs(int(ordered[i+c++])-int(std::lround(std::clamp(value,0.f,1.f)*255)))<=1,"native ordering is HSL then grading");
        }
        // 旧 tone 越界后启用极小 grading 不能突然丢弃高光/负通道残差。
        request.contrast=1.8f;
        require(sony2fuji_session_set_color_grading(session,&identity)==SONY2FUJI_STATUS_OK,"clear grading");
        const auto highContrast=render(session,request);auto tiny=config;
        tiny.shadows_saturation=tiny.midtones_saturation=tiny.highlights_saturation=.0001f;
        require(sony2fuji_session_set_color_grading(session,&tiny)==SONY2FUJI_STATUS_OK,"tiny grading");
        const auto close=render(session,request);
        for (size_t i=0;i<close.size();++i)require(std::abs(int(close[i])-int(highContrast[i]))<=1,"tiny grading remains continuous in combined native pipeline");
        request.contrast=1;hsl.hue[0]=hsl.lightness[0]=0;
        require(sony2fuji_session_set_hsl(session,&hsl)==SONY2FUJI_STATUS_OK,"clear HSL");
        require(sony2fuji_session_set_color_grading(session,&identity)==SONY2FUJI_STATUS_OK,"clear reused grading");
        require(render(session,request)==original,"explicit identity restores original bytes");
        auto scene=request;scene.input_type=SONY2FUJI_INPUT_BUFFER;
        const bool available=rawlabtest::nativeGpuAvailable();
        require(sony2fuji_session_set_color_grading(session,&config)==SONY2FUJI_STATUS_OK,"GPU grading configuration");
        const auto cpu=render(session,scene);
        for (const auto mode : {SONY2FUJI_GPU_AUTO,SONY2FUJI_GPU_FORCE}) {
            gpu.mode=mode;require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"GPU mode");
            if (!available && mode==SONY2FUJI_GPU_FORCE) {
                sony2fuji_buffer buffer{};
                require(sony2fuji_process(session,&scene,&buffer)!=SONY2FUJI_STATUS_OK,"unavailable Force cannot fake success");
                sony2fuji_release_buffer(&buffer);continue;
            }
            const auto actual=render(session,scene);
            if (available)require(sony2fuji_session_get_last_backend(session)==rawlabtest::nativeBackend,"grading uses actual requested GPU backend");
            for (size_t i=0;i<actual.size();++i)require(std::abs(int(actual[i])-int(cpu[i]))<=2,"grading GPU RGB8 within two DN");
        }
        gpu.mode=SONY2FUJI_GPU_OFF;require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"restore CPU mode");
        require(sony2fuji_session_set_color_grading(session,&identity)==SONY2FUJI_STATUS_OK,"restore grading identity");
        if (argc>1) {
            request.input_type=SONY2FUJI_INPUT_RAW;request.input_path=argv[1];request.input_pixels=nullptr;
            request.input_width=request.input_height=0;request.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;request.long_edge=192;
            const auto raw=render(session,request);
            require(sony2fuji_session_set_color_grading(session,&config)==SONY2FUJI_STATUS_OK,"RAW grading setter");
            require(render(session,request)!=raw,"RAW grading reaches the same FINAL chain");
            require(sony2fuji_session_set_color_grading(session,&identity)==SONY2FUJI_STATUS_OK,"RAW grading clear");
            require(render(session,request)==raw,"RAW identity remains exact through cache reuse");
        }
        sony2fuji_session_destroy(session);std::cout<<"PASS grading C ABI, ordering, invalid state and RAW/raster reset\n";return 0;
    } catch(const std::exception& error) {sony2fuji_session_destroy(session);std::cerr<<error.what()<<'\n';return 1;}
}
