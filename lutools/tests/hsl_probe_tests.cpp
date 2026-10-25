#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_color.h"
#include "native_gpu_test_support.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <vector>

static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
static bool close(float a, float b, float epsilon=2e-6f) { return std::abs(a-b)<=epsilon; }
using Probe = std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)>;
static sony2fuji_request requestFor(const std::vector<uint8_t>& pixels, int width, int height) {
    sony2fuji_request r{};r.version=SONY2FUJI_REQUEST_VERSION;r.struct_size=sizeof(r);
    r.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;r.input_pixels=pixels.data();r.input_width=width;r.input_height=height;
    r.input_pixel_format=SONY2FUJI_PIXEL_RGB8;r.input_color_space=SONY2FUJI_COLOR_SRGB;
    r.wb_mode=SONY2FUJI_WB_CAMERA;r.temperature=6500;r.brightness=r.contrast=r.saturation=1;
    r.output_target=SONY2FUJI_TARGET_BUFFER;r.output_format=SONY2FUJI_OUTPUT_RGB8;
    r.size_mode=SONY2FUJI_SIZE_NATIVE;r.intent=SONY2FUJI_INTENT_FINAL;return r;
}
static Probe capture(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_hsl_probe* p=nullptr;
    require(sony2fuji_session_create_hsl_probe(session,&request,13,27,&p)==SONY2FUJI_STATUS_OK && p,"capture pre-HSL snapshot");
    return Probe(p,sony2fuji_hsl_probe_destroy);
}
static sony2fuji_hsl_probe_result sample(const Probe& p,float x,float y,uint64_t source=13,uint64_t frame=27) {
    sony2fuji_hsl_probe_query q{1,sizeof(q),source,frame,x,y};sony2fuji_hsl_probe_result r{};
    require(sony2fuji_hsl_probe_sample(p.get(),&q,&r)==SONY2FUJI_STATUS_OK,"probe query accepted");return r;
}
static std::vector<uint8_t> render(sony2fuji_session* session,const sony2fuji_request& request,uint32_t& width,uint32_t& height) {
    sony2fuji_buffer b{};require(sony2fuji_process(session,&request,&b)==SONY2FUJI_STATUS_OK,"reference render");
    width=b.width;height=b.height;const auto* bytes=static_cast<const uint8_t*>(b.data);
    std::vector<uint8_t> out(bytes,bytes+b.size_bytes);sony2fuji_release_buffer(&b);return out;
}
int main(int argc,char** argv) {
    sony2fuji_session* session=nullptr;
    try {
        static_assert(sizeof(sony2fuji_request)==(sizeof(void*)==8?184u:156u),"unchanged request ABI");
        static_assert(sizeof(sony2fuji_hsl_probe_query)==32,"probe query ABI");
        static_assert(sizeof(sony2fuji_hsl_probe_result)==96,"probe result ABI");
        const auto midpoint=sony2fuji::analyzeHslColor({1,.25f,0});
        require(midpoint.valid && close(midpoint.hue,15) && close(midpoint.saturation,1) && close(midpoint.lightness,.5f),"pre-HSL color coordinates");
        auto weights=midpoint.weights();require(close(weights[0],.5f)&&close(weights[1],.5f),"red-orange midpoint has two equal weights");
        const auto wrap=sony2fuji::analyzeHslColor({1,0,.5f}).weights();
        require(close(wrap[7],.5f)&&close(wrap[0],.5f),"magenta-red circular midpoint");
        for(int channel=0;channel<8;++channel) {
            const float hues[]={0,30,60,120,180,240,270,300};
            const sony2fuji::RGB colors[]={{1,0,0},{1,.5f,0},{1,1,0},{0,1,0},{0,1,1},{0,0,1},{.5f,0,1},{1,0,1}};
            const auto c=sony2fuji::analyzeHslColor(colors[channel]);require(close(c.hue,hues[channel])&&close(c.weights()[channel],1),"eight original channel centers");
        }
        require(!sony2fuji::analyzeHslColor({.5f,.5f,.5f}).valid,"gray has no hue");
        require(!sony2fuji::analyzeHslColor({NAN,0,1}).valid,"nonfinite has no hue");
        require(sony2fuji_session_create(&session)==SONY2FUJI_STATUS_OK,"session");
        sony2fuji_gpu_config gpu{1,sizeof(gpu),SONY2FUJI_GPU_OFF};sony2fuji_session_set_gpu_config(session,&gpu);
        const std::vector<uint8_t> colors{255,64,0,128,128,128,255,0,128,0,0,255};
        auto request=requestFor(colors,4,1);auto p=capture(session,request);auto first=sample(p,0,0);
        require(first.availability==SONY2FUJI_HSL_PROBE_AVAILABLE && first.quality==SONY2FUJI_HSL_PROBE_EXACT_CPU,"exact CPU sample marked");
        require(first.source_revision==13 && first.request_revision==27 && first.width==4 && first.height==1,"sample binding and dimensions");
        require(close(first.rgb[0],1)&&close(first.rgb[1],64/255.f)&&close(first.rgb[2],0),"display input uses pre-HSL RGB");
        require(close(first.hsl[0],64/255.f*60)&&close(first.hsl[1],1)&&close(first.hsl[2],.5f),"HSL sample units are degrees and unit saturation/lightness");
        gpu.mode=SONY2FUJI_GPU_FORCE;sony2fuji_session_set_gpu_config(session,&gpu);
        auto forced=capture(session,request);sony2fuji_buffer rejected{};
        require(sony2fuji_process(session,&request,&rejected)==SONY2FUJI_STATUS_UNSUPPORTED,"capture restores Force; display render cannot secretly fall back");
        if(rawlabtest::nativeGpuAvailable()) {
            auto scene=request;scene.input_type=SONY2FUJI_INPUT_BUFFER;uint32_t w,h;render(session,scene,w,h);
            const auto backend=sony2fuji_session_get_last_backend(session);auto analyzed=capture(session,scene);
            require(backend==rawlabtest::nativeBackend&&sony2fuji_session_get_last_backend(session)==backend,"CPU analysis preserves reported real GPU backend");
            render(session,scene,w,h);require(sony2fuji_session_get_last_backend(session)==backend,"next Force render still uses real GPU");
        }
        gpu.mode=SONY2FUJI_GPU_OFF;sony2fuji_session_set_gpu_config(session,&gpu);
        require(sample(p,1.f/3,0).availability==SONY2FUJI_HSL_PROBE_NEAR_GRAY,"gray rejected");
        require(sample(p,-.000001f,0).availability==SONY2FUJI_HSL_PROBE_OUTSIDE,"strict normalized edge rejects negative");
        require(sample(p,1.000001f,0).availability==SONY2FUJI_HSL_PROBE_OUTSIDE,"strict normalized edge rejects overflow");
        require(sample(p,NAN,0).availability==SONY2FUJI_HSL_PROBE_OUTSIDE,"NaN coordinates rejected");
        require(sample(p,0,0,14).availability==SONY2FUJI_HSL_PROBE_STALE,"source revision rejected");
        const auto stale=sample(p,0,0,13,28);require(stale.availability==SONY2FUJI_HSL_PROBE_STALE,"frame revision rejected");
        require(std::all_of(std::begin(stale.weights),std::end(stale.weights),[](float w){return w==0;}),"stale cannot retain weights");
        sony2fuji_hsl_config hsl{1,sizeof(hsl),{},{},{}};hsl.hue[0]=100;hsl.saturation[0]=-60;hsl.lightness[0]=70;
        sony2fuji_session_set_hsl(session,&hsl);
        sony2fuji_color_grading_config grading{1,sizeof(grading),220,60,140,90,30,80};sony2fuji_session_set_color_grading(session,&grading);
        auto adjusted=capture(session,request);const auto noFeedback=sample(adjusted,0,0);
        for(int i=0;i<3;++i)require(close(first.rgb[i],noFeedback.rgb[i]),"HSL/grading do not feed back into selection");
        sony2fuji_tone_controls_config tone{1,sizeof(tone),-20,35,60};sony2fuji_session_set_tone_controls(session,&tone);
        request.saturation=.7f;auto toned=capture(session,request);auto tonedSample=sample(toned,0,0);
        require(!close(first.rgb[1],tonedSample.rgb[1],.001f),"tone/vibrance are present before selection");
        require(close(sample(p,0,0).rgb[1],first.rgb[1]),"snapshot independent of later session settings");
        hsl={1,sizeof(hsl),{},{},{}};grading={1,sizeof(grading),0,0,0,0,0,0};
        sony2fuji_session_set_hsl(session,&hsl);sony2fuji_session_set_color_grading(session,&grading);
        uint32_t width,height;const auto before=render(session,request,width,height);
        for(int i=0;i<3;++i)require(std::abs(int(before[i])-int(std::lround(std::clamp(tonedSample.rgb[i],0.f,1.f)*255)))<=1,"probe includes complete upstream tone chain");
        // 独立彩色网格，整图无 HSL 的渲染是几何与采样结果的外部对照。
        std::vector<uint8_t> grid;for(int y=0;y<32;++y)for(int x=0;x<48;++x){grid.push_back(90+x*3);grid.push_back(10+y*3);grid.push_back(20+(x+y)%40);}
        request=requestFor(grid,48,32);tone={1,sizeof(tone),0,0,0};sony2fuji_session_set_tone_controls(session,&tone);
        for(int turn=0;turn<4;++turn)for(int mirrored=0;mirrored<2;++mirrored)for(int slant=0;slant<2;++slant) {
            sony2fuji_geometry_config geometry{1,sizeof(geometry),.1f,.1f,.7f,.8f,turn,mirrored,1-mirrored,slant?12.f:0.f};
            sony2fuji_perspective_config perspective{1,sizeof(perspective),slant?.4f:0.f,slant?-.3f:0.f};
            require(sony2fuji_session_set_geometry(session,&geometry)==SONY2FUJI_STATUS_OK,"geometry setter");sony2fuji_session_set_perspective(session,&perspective);
            request.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;request.long_edge=19;
            const auto expected=render(session,request,width,height);uint32_t nativeW=0,nativeH=0;
            require(sony2fuji_session_get_geometry_size(session,&nativeW,&nativeH)==SONY2FUJI_STATUS_OK,"native canvas after render");
            auto transformed=capture(session,request);uint32_t retainedW=0,retainedH=0;
            require(sony2fuji_session_get_geometry_size(session,&retainedW,&retainedH)==SONY2FUJI_STATUS_OK && nativeW==retainedW && nativeH==retainedH,"analysis preserves rendered canvas metadata");
            for(uint32_t y=0;y<height;++y)for(uint32_t x=0;x<width;++x) {
                const auto actual=sample(transformed,width>1?float(x)/(width-1):0,height>1?float(y)/(height-1):0);
                require(actual.width==width&&actual.height==height&&actual.availability==SONY2FUJI_HSL_PROBE_AVAILABLE,"geometry result dimensions and valid sample");
                for(int c=0;c<3;++c)require(std::abs(int(expected[(y*width+x)*3+c])-int(std::lround(std::clamp(actual.rgb[c],0.f,1.f)*255)))<=1,"probe follows the same crop/turn/flip/perspective/straighten/resize");
            }
        }
        sony2fuji_geometry_config identity{1,sizeof(identity),0,0,1,1,0,0,0,0};sony2fuji_session_set_geometry(session,&identity);
        sony2fuji_perspective_config perspective{1,sizeof(perspective),0,0};sony2fuji_session_set_perspective(session,&perspective);
        request.intent=SONY2FUJI_INTENT_PREVIEW;request.preview_long_edge=16;sony2fuji_session_set_viewport_preview(session,1);
        auto preview=capture(session,request);const auto proxy=sample(preview,.5f,.5f);
        require(proxy.quality==SONY2FUJI_HSL_PROBE_PREVIEW_CPU&&std::max(proxy.width,proxy.height)<=16,"preview quality and proxy size explicit");
        sony2fuji_hsl_probe* bad=reinterpret_cast<sony2fuji_hsl_probe*>(uintptr_t(1));
        auto invalid=request;invalid.version=999;
        require(sony2fuji_session_create_hsl_probe(session,&invalid,13,27,&bad)==SONY2FUJI_STATUS_INVALID_ARGUMENT&&!bad,"failed capture clears out pointer");
        sony2fuji_hsl_probe_query q{99,sizeof(q),13,27,0,0};sony2fuji_hsl_probe_result result{};result.weights[0]=1;
        require(sony2fuji_hsl_probe_sample(p.get(),&q,&result)==SONY2FUJI_STATUS_INVALID_ARGUMENT&&result.weights[0]==0,"invalid metadata clears result");
        if(argc>1) {
            request.input_type=SONY2FUJI_INPUT_RAW;request.input_path=argv[1];request.input_pixels=nullptr;request.input_width=request.input_height=0;
            request.preview_long_edge=96;auto raw=capture(session,request);const auto rawSample=sample(raw,.5f,.5f);
            require(rawSample.width>0&&rawSample.height>0&&rawSample.availability!=SONY2FUJI_HSL_PROBE_STALE,"real RAW enters probe chain");
            // 只破坏临时副本的文件头，保持 cache key；第二次成功证明没有丢弃已解码 RAW。
            struct TemporaryRaw {
                std::filesystem::path path;
                ~TemporaryRaw(){std::error_code ignored;std::filesystem::remove(path,ignored);}
            } temporary{std::filesystem::temp_directory_path()/std::filesystem::path("rawlab-hsl-cache-"+
                std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())+".ARW")};
            std::filesystem::copy_file(argv[1],temporary.path);
            const auto path=temporary.path.string();request.input_path=path.c_str();
            sony2fuji_session_set_viewport_preview(session,0);
            auto preserved=capture(session,request);
            const auto stamp=std::filesystem::last_write_time(temporary.path);
            {std::fstream file(temporary.path,std::ios::binary|std::ios::in|std::ios::out);
                std::vector<char> zeros(4096,0);file.write(zeros.data(),zeros.size());require(bool(file),"controlled RAW fixture mutation");}
            std::filesystem::last_write_time(temporary.path,stamp);
            auto reused=capture(session,request);
            const auto oldSample=sample(preserved,.5f,.5f),newSample=sample(reused,.5f,.5f);
            for(int i=0;i<3;++i)require(close(oldSample.rgb[i],newSample.rgb[i]),"capture retains large RAW cache for the next request");
        }
        sony2fuji_session_destroy(session);std::cout<<"PASS immutable pre-HSL samples, upstream chain, geometry, revisions and RAW/raster\n";return 0;
    }catch(const std::exception& error){sony2fuji_session_destroy(session);std::cerr<<error.what()<<'\n';return 1;}
}
