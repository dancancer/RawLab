#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_atmosphere.h"
#include "core/photo_tone_controls.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

static void require(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
static std::vector<uint8_t> render(sony2fuji_session* session,const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_OK,"native render succeeds");
    const auto* data=static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(data,data+buffer.size_bytes); sony2fuji_release_buffer(&buffer); return result;
}
int main(int argc,char** argv) {
    sony2fuji_session* session=nullptr;
    try {
        static_assert(sizeof(sony2fuji_request)==(sizeof(void*)==8?184u:156u),"request v2 unchanged");
        static_assert(sizeof(sony2fuji_atmosphere_config)==16,"additive atmosphere ABI");
        require(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK,"create session");
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_OFF};
        require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"CPU mode");
        const int width=1024,height=128;
        std::vector<uint8_t> pixels(width*height*3);
        for(int y=0;y<height;++y) for(int x=0;x<width;++x) for(int c=0;c<3;++c)
            pixels[(y*width+x)*3+c]=std::lround(130+20*std::sin(x*6.28318530718/64)+c*5);
        sony2fuji_request request{};
        request.version=SONY2FUJI_REQUEST_VERSION;request.struct_size=sizeof(request);
        request.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;request.input_pixels=pixels.data();
        request.input_width=width;request.input_height=height;
        request.input_pixel_format=SONY2FUJI_PIXEL_RGB8;request.input_color_space=SONY2FUJI_COLOR_SRGB;
        request.wb_mode=SONY2FUJI_WB_CAMERA;request.temperature=6500;
        request.brightness=request.contrast=request.saturation=1;
        request.output_target=SONY2FUJI_TARGET_BUFFER;request.output_format=SONY2FUJI_OUTPUT_RGB8;
        request.size_mode=SONY2FUJI_SIZE_NATIVE;request.intent=SONY2FUJI_INTENT_FINAL;
        const auto original=render(session,request);require(original==pixels,"display baseline identity");
        sony2fuji_atmosphere_config config{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION,sizeof(config),0,0};
        require(sony2fuji_session_set_atmosphere(session,&config)==SONY2FUJI_STATUS_OK,"identity setter");
        require(render(session,request)==original,"identity retains old output");
        for(const auto values:std::vector<std::vector<float>>{{1,0},{-1,0},{0,1},{0,-1},{.5f,.5f}}) {
            config.clarity=values[0];config.dehaze=values[1];
            require(sony2fuji_session_set_atmosphere(session,&config)==SONY2FUJI_STATUS_OK,"active setter");
            const auto active=render(session,request);require(active!=original,"both signs reach native pixels");
            require(sony2fuji_session_set_interactive_preview(session,1)==SONY2FUJI_STATUS_OK,"interactive opt in");
            require(sony2fuji_session_set_viewport_preview(session,1)==SONY2FUJI_STATUS_OK,"viewport opt in");
            for(int edge:{73,701,256}) {
                auto preview=request;preview.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;preview.long_edge=edge;
                const auto finalSmall=render(session,preview);preview.intent=SONY2FUJI_INTENT_PREVIEW;
                require(render(session,preview)==finalSmall,"small-large-small preview equals downsampled full-source FINAL");
            }
            gpu.mode=SONY2FUJI_GPU_AUTO;
            require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"Auto mode");
            require(render(session,request)==active && sony2fuji_session_get_last_backend(session)==SONY2FUJI_BACKEND_CPU,
                "Auto uses whole CPU path");
            gpu.mode=SONY2FUJI_GPU_FORCE;
            require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"Force mode");
            auto scene=request;scene.input_type=SONY2FUJI_INPUT_BUFFER;sony2fuji_buffer unsupported{};
            require(sony2fuji_process(session,&scene,&unsupported)==SONY2FUJI_STATUS_UNSUPPORTED,"Force reports unsupported");
            gpu.mode=SONY2FUJI_GPU_OFF;
            require(sony2fuji_session_set_gpu_config(session,&gpu)==SONY2FUJI_STATUS_OK,"restore CPU");
        }
        const auto active=render(session,request);
        for(int kind=0;kind<7;++kind) {
            auto bad=config;
            if(kind==0) ++bad.version;
            if(kind==1) --bad.struct_size;
            if(kind==2) ++bad.struct_size;
            if(kind==3) bad.clarity=-1.01f;
            if(kind==4) bad.dehaze=1.01f;
            if(kind==5) bad.clarity=std::numeric_limits<float>::infinity();
            if(kind==6) bad.dehaze=std::numeric_limits<float>::quiet_NaN();
            require(sony2fuji_session_set_atmosphere(session,&bad)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"invalid config rejected");
            require(render(session,request)==active,"invalid config preserves previous state");
        }
        require(sony2fuji_session_set_atmosphere(nullptr,&config)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null session");
        require(sony2fuji_session_set_atmosphere(session,nullptr)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null config");
        sony2fuji_tone_controls_config tone{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION,sizeof(tone),.2f,-.1f,0};
        require(sony2fuji_session_set_tone_controls(session,&tone)==SONY2FUJI_STATUS_OK,"ordered tone controls");
        sony2fuji::ImageData reference(width,height);
        for(size_t i=0;i<reference.pixels.size();++i)
            reference.pixels[i]=sony2fuji::RGB(pixels[3*i]/255.f,pixels[3*i+1]/255.f,pixels[3*i+2]/255.f);
        sony2fuji::applyDehaze(reference,config.dehaze);
        sony2fuji::applyBlackWhite(reference,{.2f,-.1f,0});
        sony2fuji_hsl_probe* probe=nullptr;
        require(sony2fuji_session_create_hsl_probe(session,&request,1,2,&probe)==SONY2FUJI_STATUS_OK,"probe includes upstream dehaze");
        for(int x:{64,128,175,511,777}) {
            sony2fuji_hsl_probe_query query{SONY2FUJI_HSL_PROBE_VERSION,sizeof(query),1,2,float(x)/(width-1),64.f/(height-1)};
            sony2fuji_hsl_probe_result sampled{};sampled.version=SONY2FUJI_HSL_PROBE_VERSION;sampled.struct_size=sizeof(sampled);
            require(sony2fuji_hsl_probe_sample(probe,&query,&sampled)==SONY2FUJI_STATUS_OK,"probe sample");
            const auto expected=reference.at(x,64);
            require(std::abs(sampled.rgb[0]-expected.r)<2e-5 && std::abs(sampled.rgb[1]-expected.g)<2e-5 &&
                std::abs(sampled.rgb[2]-expected.b)<2e-5,"Dehaze precedes black/white; downstream clarity absent from probe");
        }
        sony2fuji_hsl_probe_destroy(probe);tone.black_point=tone.white_point=0;
        require(sony2fuji_session_set_tone_controls(session,&tone)==SONY2FUJI_STATUS_OK,"clear ordered tone");
        config.clarity=config.dehaze=0;
        require(sony2fuji_session_set_atmosphere(session,&config)==SONY2FUJI_STATUS_OK,"clear session");
        require(render(session,request)==original,"next photo does not inherit atmosphere");
        if(argc>1) {
            request.input_type=SONY2FUJI_INPUT_RAW;request.input_path=argv[1];request.input_pixels=nullptr;
            request.input_width=request.input_height=0;request.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;request.long_edge=320;
            const auto rawBaseline=render(session,request);
            config.clarity=.6f;config.dehaze=.5f;
            require(sony2fuji_session_set_atmosphere(session,&config)==SONY2FUJI_STATUS_OK,"RAW atmosphere");
            const auto exact=render(session,request);require(exact!=rawBaseline,"RAW effect active");
            request.intent=SONY2FUJI_INTENT_PREVIEW;
            require(render(session,request)==exact,"interactive RAW uses full decode for atmosphere");
            request.intent=SONY2FUJI_INTENT_FINAL;config.clarity=config.dehaze=0;
            require(sony2fuji_session_set_atmosphere(session,&config)==SONY2FUJI_STATUS_OK,"RAW clear");
            require(render(session,request)==rawBaseline,"RAW old pixels restored");
        }
        sony2fuji_session_destroy(session);std::cout<<"Atmosphere ABI, preview, fallback and session tests passed\n";return 0;
    } catch(const std::exception& e) {sony2fuji_session_destroy(session);std::cerr<<e.what()<<'\n';return 1;}
}
