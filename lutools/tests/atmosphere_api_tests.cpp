#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_atmosphere.h"
#include "core/photo_tone_controls.h"
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core.hpp>
#endif

static void require(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
static std::vector<uint8_t> render(sony2fuji_session* session,const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(session,&request,&buffer)==SONY2FUJI_STATUS_OK,"native render succeeds");
    const auto* data=static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(data,data+buffer.size_bytes); sony2fuji_release_buffer(&buffer); return result;
}
static void previewQuality(const std::vector<uint8_t>& preview,const std::vector<uint8_t>& exact) {
    require(preview.size()==exact.size(),"viewport preserves output byte count");
    std::vector<int> difference(preview.size());
    double sum=0;
    for(size_t i=0;i<preview.size();++i) { difference[i]=std::abs(int(preview[i])-int(exact[i]));sum+=difference[i]; }
    std::sort(difference.begin(),difference.end());
    const double mean=sum/difference.size();
    const int p999=difference[size_t(std::ceil(difference.size()*.999))-1],maximum=difference.back();
    std::cout<<"synthetic viewport RGB8 mean="<<mean<<" p99.9="<<p999<<" max="<<maximum<<'\n';
    require(mean<=1.5 && p999<=8 && maximum<=16,"smooth synthetic viewport stays within RGB8 approximation budget");
}
static void threadParity(const sony2fuji_request& request) {
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    struct RestoreThreads { int count=cv::getNumThreads(); ~RestoreThreads() { cv::setNumThreads(count); } } restore;
    struct ExportFile {
        std::filesystem::path path=std::filesystem::temp_directory_path()/
            ("rawlab-atmosphere-threads-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())+".png");
        ~ExportFile() { std::error_code error;std::filesystem::remove(path,error); }
    } exported;
    const auto exportPath=exported.path.string();
    for(const auto values:std::vector<std::vector<float>>{{1,0},{-1,0},{0,1},{0,-1},{.5f,-.5f}}) {
        std::vector<uint8_t> serial,serialPreview,serialExport;
        for(int threads:{1,2,4}) {
            cv::setNumThreads(threads);
            sony2fuji_session* fresh=nullptr;
            require(sony2fuji_session_create(&fresh)==SONY2FUJI_STATUS_OK,"thread parity session");
            sony2fuji_atmosphere_config atmosphere{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION,sizeof(atmosphere),values[0],values[1]};
            sony2fuji_tone_controls_config tone{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION,sizeof(tone),.1f,-.1f,.3f};
            require(sony2fuji_session_set_atmosphere(fresh,&atmosphere)==SONY2FUJI_STATUS_OK,"thread parity atmosphere");
            require(sony2fuji_session_set_tone_controls(fresh,&tone)==SONY2FUJI_STATUS_OK,"thread parity vibrance");
            const auto bytes=render(fresh,request);
            require(sony2fuji_session_set_viewport_preview(fresh,1)==SONY2FUJI_STATUS_OK,"thread parity viewport");
            require(sony2fuji_session_set_interactive_preview(fresh,1)==SONY2FUJI_STATUS_OK,"thread parity interactive");
            auto preview=request;preview.intent=SONY2FUJI_INTENT_PREVIEW;
            preview.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;preview.long_edge=768;
            const auto previewBytes=render(fresh,preview);
            auto file=request;file.intent=SONY2FUJI_INTENT_FINAL;
            file.output_target=SONY2FUJI_TARGET_FILE;file.output_format=SONY2FUJI_OUTPUT_PNG;
            file.output_path=exportPath.c_str();
            require(sony2fuji_process(fresh,&file,nullptr)==SONY2FUJI_STATUS_OK,"thread parity PNG16 export after viewport");
            std::ifstream stream(exported.path,std::ios::binary);
            require(stream.good(),"read thread parity export");
            const std::vector<uint8_t> exportBytes((std::istreambuf_iterator<char>(stream)),std::istreambuf_iterator<char>());
            sony2fuji_session_destroy(fresh);
            if(threads==1) {serial=bytes;serialPreview=previewBytes;serialExport=exportBytes;}
            else require(bytes==serial && previewBytes==serialPreview && exportBytes==serialExport,
                "1/2/4 threads produce identical FINAL/viewport RGB8 and PNG16 file bytes");
        }
    }
#else
    std::cout<<"SKIP: OpenCV thread parity (serial-only build)\n";
#endif
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
        threadParity(request);
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
                require(sony2fuji_session_set_viewport_preview(session,0)==SONY2FUJI_STATUS_OK,"disable viewport");
                require(render(session,preview)==finalSmall,"non-viewport preview retains full-source FINAL bytes");
                require(sony2fuji_session_set_viewport_preview(session,1)==SONY2FUJI_STATUS_OK,"enable viewport");
                const auto reduced=render(session,preview);
                require(reduced!=finalSmall,"viewport computes atmosphere on reduced pixels");
                if(edge==701) previewQuality(reduced,finalSmall);
                require(render(session,request)==active,"viewport analysis cannot pollute FINAL");
                require(render(session,preview)==reduced,"small-large-small viewport is deterministic");
            }
            auto nativePreview=request;nativePreview.intent=SONY2FUJI_INTENT_PREVIEW;
            require(render(session,nativePreview)==active,"native-size viewport retains exact bytes");
            nativePreview.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;nativePreview.long_edge=width*2;
            require(render(session,nativePreview)==active,"viewport requests above native size retain exact bytes");
            for(auto mode:{SONY2FUJI_SIZE_FIT_LONG_EDGE,SONY2FUJI_SIZE_EXACT}) {
                auto enlarged=request;enlarged.size_mode=mode;enlarged.long_edge=width*2;
                enlarged.target_width=width*2;enlarged.target_height=height*2;
                const auto finalLarge=render(session,enlarged);enlarged.intent=SONY2FUJI_INTENT_PREVIEW;
                require(render(session,enlarged)==finalLarge,"enlarging viewport retains FINAL dimensions and bytes");
                enlarged.size_mode=SONY2FUJI_SIZE_NATIVE;enlarged.preview_long_edge=width*2;
                require(render(session,enlarged)==finalLarge,"legacy preview edge above native retains output bytes");
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
        const char* raw=argc>1 ? argv[1] : std::getenv("RAWLAB_TEST_RAW");
        if(raw && *raw) {
            request.input_type=SONY2FUJI_INPUT_RAW;request.input_path=raw;request.input_pixels=nullptr;
            request.input_width=request.input_height=0;request.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;request.long_edge=320;
            threadParity(request);
            const auto rawBaseline=render(session,request);
            config.clarity=.6f;config.dehaze=.5f;
            require(sony2fuji_session_set_atmosphere(session,&config)==SONY2FUJI_STATUS_OK,"RAW atmosphere");
            const auto exact=render(session,request);require(exact!=rawBaseline,"RAW effect active");
            request.intent=SONY2FUJI_INTENT_PREVIEW;
            require(sony2fuji_session_set_viewport_preview(session,0)==SONY2FUJI_STATUS_OK,"RAW exact preview");
            require(render(session,request)==exact,"non-viewport RAW retains full decode");
            require(sony2fuji_session_set_viewport_preview(session,1)==SONY2FUJI_STATUS_OK,"RAW viewport preview");
            const auto reduced=render(session,request);
            require(reduced.size()==exact.size(),"RAW viewport preserves requested dimensions");
            request.intent=SONY2FUJI_INTENT_FINAL;
            require(render(session,request)==exact,"RAW FINAL survives viewport history");
            request.intent=SONY2FUJI_INTENT_FINAL;config.clarity=config.dehaze=0;
            require(sony2fuji_session_set_atmosphere(session,&config)==SONY2FUJI_STATUS_OK,"RAW clear");
            require(render(session,request)==rawBaseline,"RAW old pixels restored");
        }
        sony2fuji_session_destroy(session);std::cout<<"Atmosphere ABI, preview, fallback and session tests passed\n";return 0;
    } catch(const std::exception& e) {sony2fuji_session_destroy(session);std::cerr<<e.what()<<'\n';return 1;}
}
