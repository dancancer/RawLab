#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_tone_curve.h"
#include "native_gpu_test_support.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

static void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
static sony2fuji_request requestFor(const std::vector<uint8_t>& pixels) {
    sony2fuji_request r{};
    r.version=SONY2FUJI_REQUEST_VERSION;r.struct_size=sizeof(r);
    r.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;r.input_pixels=pixels.data();
    r.input_width=static_cast<uint32_t>(pixels.size()/3);r.input_height=1;
    r.input_pixel_format=SONY2FUJI_PIXEL_RGB8;r.input_color_space=SONY2FUJI_COLOR_SRGB;
    r.wb_mode=SONY2FUJI_WB_CAMERA;r.temperature=6500;r.brightness=r.contrast=r.saturation=1;
    r.output_target=SONY2FUJI_TARGET_BUFFER;r.output_format=SONY2FUJI_OUTPUT_RGB8;
    r.size_mode=SONY2FUJI_SIZE_NATIVE;r.intent=SONY2FUJI_INTENT_FINAL;
    return r;
}
static std::vector<uint8_t> render(sony2fuji_session* s, const sony2fuji_request& r) {
    sony2fuji_buffer b{};
    require(sony2fuji_process(s,&r,&b)==SONY2FUJI_STATUS_OK,"render succeeds");
    const auto* p=static_cast<const uint8_t*>(b.data);
    std::vector<uint8_t> result(p,p+b.size_bytes);sony2fuji_release_buffer(&b);return result;
}
int main(int argc, char** argv) {
    sony2fuji_session* s=nullptr;
    try {
        static_assert(sizeof(sony2fuji_request)==(sizeof(void*)==8 ? 184u : 156u),"request v2 unchanged");
        static_assert(sizeof(sony2fuji_tone_curve_config)==544,"curve ABI layout");
        require(sony2fuji_session_create(&s)==SONY2FUJI_STATUS_OK,"create session");
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(gpu),SONY2FUJI_GPU_OFF};
        require(sony2fuji_session_set_gpu_config(s,&gpu)==SONY2FUJI_STATUS_OK,"CPU");
        std::vector<uint8_t> pixels;
        for (int i=0;i<256;++i) { pixels.push_back(i);pixels.push_back(255-i);pixels.push_back((i*17)%256); }
        auto r=requestFor(pixels);
        require(render(s,r)==pixels,"baseline bytes preserved");
        r.tone_curve=.65f;
        const auto legacy=render(s,r);
        sony2fuji_tone_curve_config reset{SONY2FUJI_TONE_CURVE_CONFIG_VERSION,sizeof(reset),SONY2FUJI_CURVE_LEGACY,0,{}};
        require(sony2fuji_session_set_tone_curve(s,&reset)==SONY2FUJI_STATUS_OK,"explicit legacy");
        require(render(s,r)==legacy && legacy!=pixels,"legacy exact output preserved");
        sony2fuji_tone_curve_config custom{SONY2FUJI_TONE_CURVE_CONFIG_VERSION,sizeof(custom),SONY2FUJI_CURVE_CUSTOM,4,
            {{0,0},{.25,.12},{.75,.88},{1,1}}};
        require(sony2fuji_session_set_tone_curve(s,&custom)==SONY2FUJI_STATUS_OK,"custom setter");
        sony2fuji_buffer buffer{};
        require(sony2fuji_process(s,&r,&buffer)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"scalar and custom conflict rejected");
        r.tone_curve=0;
        const auto changed=render(s,r);
        require(changed!=pixels,"custom curve reaches rendering");
        sony2fuji::ToneCurve reference(custom);
        double positions[]{0,.125,.25,.5,.75,.875,1}, samples[7]{};
        require(sony2fuji_sample_tone_curve(&custom,positions,samples,7)==SONY2FUJI_STATUS_OK,"shared curve canvas samples");
        for (int i=0;i<7;++i) require(samples[i]==reference.evaluate(positions[i]),"canvas matches rendered curve");
        positions[2]=std::numeric_limits<double>::quiet_NaN();
        std::fill(std::begin(samples),std::end(samples),-7);
        require(sony2fuji_sample_tone_curve(&custom,positions,samples,7)==SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            std::all_of(std::begin(samples),std::end(samples),[](double y){return y==-7;}),"invalid sampling preserves output");
        for (size_t i=0;i<pixels.size();++i)
            require(std::abs(int(changed[i])-int(std::lround(reference.evaluate(pixels[i]/255.0)*255)))<=1,
                "custom rendering follows PCHIP reference");
        auto bad=custom;bad.points[2].x=.25;
        require(sony2fuji_session_set_tone_curve(s,&bad)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"bad setter rejected");
        require(render(s,r)==changed,"bad setter keeps previous state");
        require(sony2fuji_session_set_tone_curve(nullptr,&custom)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null session rejected");
        require(sony2fuji_session_set_tone_curve(s,nullptr)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"null config rejected");
        auto identity=custom;identity.count=2;identity.points[1]={1,1};
        require(sony2fuji_session_set_tone_curve(s,&identity)==SONY2FUJI_STATUS_OK,"custom identity");
        require(render(s,r)==pixels,"identity exact output");
        require(sony2fuji_session_set_tone_curve(s,&reset)==SONY2FUJI_STATUS_OK,"reset reused session");
        require(render(s,r)==pixels,"next photo clears curve");
        r.tone_curve=.65f;require(render(s,r)==legacy,"return to original legacy pixels");r.tone_curve=0;
        require(sony2fuji_session_set_tone_curve(s,&custom)==SONY2FUJI_STATUS_OK,"probe curve");
        sony2fuji_hsl_probe* probe=nullptr;
        require(sony2fuji_session_create_hsl_probe(s,&r,9,10,&probe)==SONY2FUJI_STATUS_OK,"probe captures curve");
        sony2fuji_hsl_probe_query query{SONY2FUJI_HSL_PROBE_VERSION,sizeof(query),9,10,.25,0};
        sony2fuji_hsl_probe_result sample{};sample.version=SONY2FUJI_HSL_PROBE_VERSION;sample.struct_size=sizeof(sample);
        require(sony2fuji_hsl_probe_sample(probe,&query,&sample)==SONY2FUJI_STATUS_OK,"probe sample");
        require(sample.availability==SONY2FUJI_HSL_PROBE_AVAILABLE &&
            std::abs(sample.rgb[0]-reference.evaluate(.25))<1e-4,"probe includes the custom curve before HSL");
        sony2fuji_hsl_probe_destroy(probe);
        const bool available=rawlabtest::nativeGpuAvailable();
        auto scene=r;scene.input_type=SONY2FUJI_INPUT_BUFFER;
        for (int shape=0;shape<3;++shape) {
            if (shape==1) { custom.points[1].y=0;custom.points[2].y=1; }
            if (shape==2) { custom.points[1].x=.5;custom.points[2].x=std::nextafter(.5,1.0);custom.points[1].y=.1;custom.points[2].y=.9; }
            require(sony2fuji_session_set_tone_curve(s,&custom)==SONY2FUJI_STATUS_OK,"curve shape");
            gpu.mode=SONY2FUJI_GPU_OFF;sony2fuji_session_set_gpu_config(s,&gpu);
            const auto cpu=render(s,scene);
            gpu.mode=available && shape<2 ? SONY2FUJI_GPU_FORCE : SONY2FUJI_GPU_AUTO;
            sony2fuji_session_set_gpu_config(s,&gpu);
            const auto actual=render(s,scene);
            if (available && shape<2) require(sony2fuji_session_get_last_backend(s)==rawlabtest::nativeBackend,"custom uses required GPU");
            if (shape==2) require(sony2fuji_session_get_last_backend(s)==SONY2FUJI_BACKEND_CPU,"precision fallback is CPU");
            for (size_t i=0;i<cpu.size();++i) require(std::abs(int(actual[i])-int(cpu[i]))<=2,"curve GPU within two DN");
        }
        gpu.mode=SONY2FUJI_GPU_FORCE;sony2fuji_session_set_gpu_config(s,&gpu);
        require(sony2fuji_process(s,&scene,&buffer)==SONY2FUJI_STATUS_UNSUPPORTED,"precision-limited Force is honest");
        gpu.mode=SONY2FUJI_GPU_OFF;sony2fuji_session_set_gpu_config(s,&gpu);
        if (argc>1) {
            r.input_type=SONY2FUJI_INPUT_RAW;r.input_path=argv[1];r.input_pixels=nullptr;r.input_width=r.input_height=0;
            r.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;r.long_edge=192;
            sony2fuji_session_set_tone_curve(s,&reset);const auto before=render(s,r);
            custom.points[1]={.25,.12};custom.points[2]={.75,.88};
            sony2fuji_session_set_tone_curve(s,&custom);require(render(s,r)!=before,"curve reaches real RAW");
            sony2fuji_session_set_tone_curve(s,&identity);require(render(s,r)==before,"RAW identity exact");
        }
        sony2fuji_session_destroy(s);std::cout << "Tone curve API checks passed\n";return 0;
    } catch (const std::exception& error) { if(s)sony2fuji_session_destroy(s);std::cerr<<error.what()<<'\n';return 1; }
}
