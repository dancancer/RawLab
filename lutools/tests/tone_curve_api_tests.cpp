#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_tone_curve.h"
#include "native_gpu_test_support.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
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
        sony2fuji::ToneCurveConfig coreCustom{sony2fuji::ToneCurveMode::Custom, 4,
            {{{0,0},{.25,.12},{.75,.88},{1,1}}}};
        sony2fuji::ToneCurve reference(coreCustom);
        // Free-endpoint Y validation & active_ check (Wave 0).
        sony2fuji::ToneCurveConfig freeEnd{sony2fuji::ToneCurveMode::Custom, 2, {{{0, 0}, {1, 0.9}}}};
        require(!sony2fuji::validToneCurve(freeEnd, false), "v1 rejects unpinned endpoint Y");
        require(sony2fuji::validToneCurve(freeEnd, true), "v2 allows unpinned endpoint Y");
        sony2fuji::ToneCurve freeEndCurve(freeEnd, true);
        require(freeEndCurve.active(), "2-point curve with y1 < 1 must be active");
        require(std::abs(freeEndCurve.evaluate(0.0) - 0.0) < 1e-9 &&
                std::abs(freeEndCurve.evaluate(1.0) - 0.9) < 1e-9, "evaluate clamps to endpoint Y");
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
        sony2fuji_tone_curve_set_config curves{SONY2FUJI_TONE_CURVE_SET_CONFIG_VERSION, sizeof(curves),
            {reset, custom, reset, reset}};
        require(sony2fuji_session_set_tone_curves(s,&curves)==SONY2FUJI_STATUS_OK,"red channel setter");
        const auto redOnly=render(s,r);
        for(size_t i=0;i<pixels.size();++i) {
            const auto expected=i%3==0 ? std::lround(reference.evaluate(pixels[i]/255.0)*255) : pixels[i];
            require(std::abs(int(redOnly[i])-int(expected))<=1,"red curve preserves green and blue");
        }
        auto badSet=curves;badSet.curves[2].count=1;
        require(sony2fuji_session_set_tone_curves(s,&badSet)==SONY2FUJI_STATUS_INVALID_ARGUMENT,"invalid channel rejected");
        require(render(s,r)==redOnly,"invalid set is atomic");
        curves.curves[0]=custom;curves.curves[2]=custom;curves.curves[3]=custom;
        require(sony2fuji_session_set_tone_curves(s,&curves)==SONY2FUJI_STATUS_OK,"all channels setter");
        const auto combined=render(s,r);
        for(size_t i=0;i<pixels.size();++i)
            require(std::abs(int(combined[i])-int(std::lround(reference.evaluate(reference.evaluate(pixels[i]/255.0))*255)))<=1,
                "master precedes independent channels");
        gpu.mode=SONY2FUJI_GPU_AUTO;sony2fuji_session_set_gpu_config(s,&gpu);
        require(render(s,r)==combined && sony2fuji_session_get_last_backend(s)==SONY2FUJI_BACKEND_CPU,"channel GPU Auto fallback");
        gpu.mode=SONY2FUJI_GPU_FORCE;sony2fuji_session_set_gpu_config(s,&gpu);
        require(sony2fuji_process(s,&r,&buffer)==SONY2FUJI_STATUS_UNSUPPORTED,"channel Force reports unsupported");
        gpu.mode=SONY2FUJI_GPU_OFF;sony2fuji_session_set_gpu_config(s,&gpu);
        require(sony2fuji_session_set_tone_curve(s,&reset)==SONY2FUJI_STATUS_OK,"old setter clears all channels");
        require(render(s,r)==pixels,"old caller cannot inherit channel state");
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

        // v2: unpinned matte-fade endpoints, Luminosity mode, Parametric + sample_tone_curve_v2, GPU channel curves, setToneCurve reset isolation
        require(sony2fuji_session_set_tone_curve(s, &reset) == SONY2FUJI_STATUS_OK, "reset before v2 checks");
        {
            const std::vector<uint8_t> v2Pixels{
                0, 0, 0,
                128, 128, 128,
                255, 255, 255,
                217, 51, 38,
                230, 38, 38
            };
            auto v2Req = requestFor(v2Pixels);
            const auto v2Baseline = render(s, v2Req);
            require(v2Baseline == v2Pixels, "v2 baseline matches input bytes");

            auto makeLegacyCurve = []() {
                sony2fuji_tone_curve_config c{};
                c.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
                c.struct_size = sizeof(c);
                c.mode = SONY2FUJI_CURVE_LEGACY;
                return c;
            };
            auto makeV2Set = [&]() {
                sony2fuji_tone_curve_set_v2_config set{};
                set.version = SONY2FUJI_TONE_CURVE_SET_V2_CONFIG_VERSION;
                set.struct_size = sizeof(set);
                for (auto& c : set.curves) c = makeLegacyCurve();
                set.parametric.version = SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION;
                set.parametric.struct_size = sizeof(set.parametric);
                set.parametric.split_shadow = 0.25f;
                set.parametric.split_midtone = 0.50f;
                set.parametric.split_highlight = 0.75f;
                return set;
            };

            // 1) Unpinned matte-fade endpoints on CPU display buffer + Force GPU scene buffer
            auto matteSet = makeV2Set();
            matteSet.curves[0].mode = SONY2FUJI_CURVE_CUSTOM;
            matteSet.curves[0].count = 3;
            matteSet.curves[0].points[0] = {0.0, 0.12};
            matteSet.curves[0].points[1] = {0.5, 0.52};
            matteSet.curves[0].points[2] = {1.0, 0.88};
            require(sony2fuji_session_set_tone_curves_v2(s, &matteSet) == SONY2FUJI_STATUS_OK, "v2 matte-fade setter");
            const auto matteOut = render(s, v2Req);
            require(matteOut[0] == 31 && matteOut[1] == 31 && matteOut[2] == 31, "matte-fade (0,0,0) -> 31 DN");
            require(matteOut[6] == 224 && matteOut[7] == 224 && matteOut[8] == 224, "matte-fade (255,255,255) -> 224 DN");

            if (available) {
                auto sceneMatte = v2Req;
                sceneMatte.input_type = SONY2FUJI_INPUT_BUFFER;
                gpu.mode = SONY2FUJI_GPU_OFF;
                sony2fuji_session_set_gpu_config(s, &gpu);
                const auto cpuMatte = render(s, sceneMatte);
                gpu.mode = SONY2FUJI_GPU_FORCE;
                sony2fuji_session_set_gpu_config(s, &gpu);
                const auto gpuMatte = render(s, sceneMatte);
                require(sony2fuji_session_get_last_backend(s) == rawlabtest::nativeBackend, "v2 matte-fade runs on Force GPU");
                require(gpuMatte[0] == 31 && gpuMatte[1] == 31 && gpuMatte[2] == 31, "GPU matte-fade black -> 31 DN");
                for (size_t i = 0; i < cpuMatte.size(); ++i) {
                    require(std::abs(int(gpuMatte[i]) - int(cpuMatte[i])) <= 2, "GPU matte-fade matches CPU <= 2 DN");
                }
                gpu.mode = SONY2FUJI_GPU_OFF;
                sony2fuji_session_set_gpu_config(s, &gpu);
            }

            // 2) Luminosity mode: identity bypass, hue/saturation preservation, gamut protection
            auto lumIdentity = makeV2Set();
            lumIdentity.apply_to_luminosity = 1;
            lumIdentity.parametric.split_shadow = 0.15f;
            lumIdentity.parametric.split_midtone = 0.40f;
            lumIdentity.parametric.split_highlight = 0.85f;
            require(sony2fuji_session_set_tone_curves_v2(s, &lumIdentity) == SONY2FUJI_STATUS_OK, "luminosity identity setter");
            require(render(s, v2Req) == v2Baseline, "luminosity + non-default zero-band splits bypass exactly");

            auto sCurveSet = makeV2Set();
            sCurveSet.curves[0].mode = SONY2FUJI_CURVE_CUSTOM;
            sCurveSet.curves[0].count = 4;
            sCurveSet.curves[0].points[0] = {0.0, 0.0};
            sCurveSet.curves[0].points[1] = {0.25, 0.10};
            sCurveSet.curves[0].points[2] = {0.75, 0.90};
            sCurveSet.curves[0].points[3] = {1.0, 1.0};
            require(sony2fuji_session_set_tone_curves_v2(s, &sCurveSet) == SONY2FUJI_STATUS_OK, "RGB S-curve setter");
            const auto rgbS = render(s, v2Req);
            sCurveSet.apply_to_luminosity = 1;
            require(sony2fuji_session_set_tone_curves_v2(s, &sCurveSet) == SONY2FUJI_STATUS_OK, "Lum S-curve setter");
            const auto lumS = render(s, v2Req);
            // Neutral gray (128, 128, 128) at pixel index 1 (bytes 3..5) matches RGB mode
            require(std::abs(int(lumS[3]) - int(rgbS[3])) <= 1, "Luminosity gray matches RGB mode");
            // Vivid red-orange (217, 51, 38) at pixel index 3 (bytes 9..11) differs from RGB mode
            const int maxVividDiff = std::max({
                std::abs(int(lumS[9]) - int(rgbS[9])),
                std::abs(int(lumS[10]) - int(rgbS[10])),
                std::abs(int(lumS[11]) - int(rgbS[11]))
            });
            require(maxVividDiff > 10, "Luminosity vivid color differs materially from RGB mode");
            auto srgbToLin = [](double v) {
                return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4);
            };
            const double inRatio = (srgbToLin(217.0 / 255.0) - srgbToLin(38.0 / 255.0)) > 0
                ? (srgbToLin(51.0 / 255.0) - srgbToLin(38.0 / 255.0)) /
                  (srgbToLin(217.0 / 255.0) - srgbToLin(38.0 / 255.0))
                : 0.0;
            const double outRL = srgbToLin(lumS[9] / 255.0);
            const double outGL = srgbToLin(lumS[10] / 255.0);
            const double outBL = srgbToLin(lumS[11] / 255.0);
            const double outRatio = (outGL - outBL) / (outRL - outBL);
            require(std::abs(outRatio - inRatio) < 0.02, "Luminosity preserves linear RGB hue ratio");

            // Gamut protection on (230, 38, 38) at pixel index 4 (bytes 12..14)
            auto liftSet = makeV2Set();
            liftSet.apply_to_luminosity = 1;
            liftSet.curves[0].mode = SONY2FUJI_CURVE_CUSTOM;
            liftSet.curves[0].count = 3;
            liftSet.curves[0].points[0] = {0.0, 0.0};
            liftSet.curves[0].points[1] = {0.45, 0.72};
            liftSet.curves[0].points[2] = {1.0, 1.0};
            require(sony2fuji_session_set_tone_curves_v2(s, &liftSet) == SONY2FUJI_STATUS_OK, "Lum lift setter");
            const auto lumLift = render(s, v2Req);
            require(lumLift[12] == 255 && std::abs(int(lumLift[13]) - int(lumLift[14])) <= 1 && lumLift[13] >= 145,
                "Luminosity gamut clamp desaturates smoothly at constant luminance/hue");

            // 3) Parametric + unpinned point composite and sony2fuji_sample_tone_curve_v2 parity
            auto compSet = makeV2Set();
            compSet.curves[0] = matteSet.curves[0];
            compSet.parametric.shadows = 45.0f;
            compSet.parametric.darks = -25.0f;
            compSet.parametric.lights = 30.0f;
            compSet.parametric.highlights = -35.0f;
            compSet.parametric.split_shadow = 0.22f;
            compSet.parametric.split_midtone = 0.48f;
            compSet.parametric.split_highlight = 0.78f;
            require(sony2fuji_session_set_tone_curves_v2(s, &compSet) == SONY2FUJI_STATUS_OK, "composite v2 setter");
            const auto compOut = render(s, v2Req);
            double xs[5]{0.0, 128.0 / 255.0, 1.0, 217.0 / 255.0, 38.0 / 255.0};
            double ys[5]{};
            require(sony2fuji_sample_tone_curve_v2(&compSet.curves[0], &compSet.parametric, xs, ys, 5) == SONY2FUJI_STATUS_OK,
                "sample_tone_curve_v2 composite");
            require(std::abs(ys[0] - 0.12) < 1e-12 && std::abs(ys[2] - 0.88) < 1e-12,
                "composite preserves unpinned y0/y1 exactly");
            require(std::abs(int(compOut[0]) - int(std::lround(ys[0] * 255.0))) <= 1 &&
                    std::abs(int(compOut[3]) - int(std::lround(ys[1] * 255.0))) <= 1 &&
                    std::abs(int(compOut[6]) - int(std::lround(ys[2] * 255.0))) <= 1,
                "sample_tone_curve_v2 matches rendered composite output");

            // Parametric-only sampling (legacy point curve + active parametric)
            auto paramOnlyCurve = makeLegacyCurve();
            double pYs[5]{};
            require(sony2fuji_sample_tone_curve_v2(&paramOnlyCurve, &compSet.parametric, xs, pYs, 5) == SONY2FUJI_STATUS_OK,
                "sample_tone_curve_v2 parametric-only");
            require(pYs[0] == 0.0 && pYs[2] == 1.0 && pYs[1] != xs[1],
                "parametric-only sample keeps 0/1 endpoints and shapes midtones");

            // 4) Independent R/G/B + Luminosity + Parametric on Force GPU (SCENE BUFFER)
            if (available) {
                auto fullV2 = compSet;
                fullV2.apply_to_luminosity = 1;
                fullV2.curves[1].mode = SONY2FUJI_CURVE_CUSTOM;
                fullV2.curves[1].count = 3;
                fullV2.curves[1].points[0] = {0.0, 0.05};
                fullV2.curves[1].points[1] = {0.5, 0.62};
                fullV2.curves[1].points[2] = {1.0, 0.96};
                fullV2.curves[2].mode = SONY2FUJI_CURVE_CUSTOM;
                fullV2.curves[2].count = 3;
                fullV2.curves[2].points[0] = {0.0, 0.0};
                fullV2.curves[2].points[1] = {0.4, 0.35};
                fullV2.curves[2].points[2] = {1.0, 1.0};
                require(sony2fuji_session_set_tone_curves_v2(s, &fullV2) == SONY2FUJI_STATUS_OK, "full v2 GPU setter");
                auto sceneFull = v2Req;
                sceneFull.input_type = SONY2FUJI_INPUT_BUFFER;
                gpu.mode = SONY2FUJI_GPU_OFF;
                sony2fuji_session_set_gpu_config(s, &gpu);
                const auto cpuFull = render(s, sceneFull);
                gpu.mode = SONY2FUJI_GPU_FORCE;
                sony2fuji_session_set_gpu_config(s, &gpu);
                const auto gpuFull = render(s, sceneFull);
                require(sony2fuji_session_get_last_backend(s) == rawlabtest::nativeBackend,
                    "full v2 (RGB channels + Luminosity + Parametric) runs on Force GPU");
                for (size_t i = 0; i < cpuFull.size(); ++i) {
                    require(std::abs(int(gpuFull[i]) - int(cpuFull[i])) <= 2,
                        "full v2 Force GPU matches CPU within 2 DN");
                }
                gpu.mode = SONY2FUJI_GPU_OFF;
                sony2fuji_session_set_gpu_config(s, &gpu);
            }

            // 5) Free-X clip endpoints on master + channel + luminosity on CPU and Force GPU
            {
                const std::vector<uint8_t> clipPixels{
                    26, 26, 26,      // ~0.102 <= 0.20 -> crushes to 0
                    128, 128, 128,   // ~0.502 -> midtone
                    230, 230, 230,   // ~0.902 >= 0.80 -> clips to 255
                    200, 80, 40,
                };
                auto clipReq = requestFor(clipPixels);
                auto freeXSet = makeV2Set();
                freeXSet.apply_to_luminosity = 1;
                freeXSet.curves[0].mode = SONY2FUJI_CURVE_CUSTOM;
                freeXSet.curves[0].count = 2;
                freeXSet.curves[0].points[0] = {0.2, 0.0};
                freeXSet.curves[0].points[1] = {0.8, 1.0};
                freeXSet.curves[1].mode = SONY2FUJI_CURVE_CUSTOM;
                freeXSet.curves[1].count = 2;
                freeXSet.curves[1].points[0] = {0.15, 0.05};
                freeXSet.curves[1].points[1] = {0.85, 0.95};
                require(sony2fuji_session_set_tone_curves_v2(s, &freeXSet) == SONY2FUJI_STATUS_OK, "v2 free-X setter");
                const auto freeXOut = render(s, clipReq);
                // Master crushes 26->0, red channel lifts 0->0.05 (~13 DN), G/B stay 0
                require(freeXOut[0] == 13 && freeXOut[1] == 0 && freeXOut[2] == 0,
                    "free-X master crush + red channel lift on dark pixel");
                // Master clips 230->255, red channel drops 1->0.95 (~242 DN), G/B stay 255
                require(freeXOut[6] == 242 && freeXOut[7] == 255 && freeXOut[8] == 255,
                    "free-X master clip + red channel clamp on bright pixel");

                double fxXs[3]{0.1, 0.5, 0.9};
                double fxYs[3]{};
                require(sony2fuji_sample_tone_curve_v2(&freeXSet.curves[0], nullptr, fxXs, fxYs, 3) == SONY2FUJI_STATUS_OK,
                    "sample_tone_curve_v2 free-X");
                require(fxYs[0] == 0.0 && std::abs(fxYs[1] - 0.5) < 1e-12 && fxYs[2] == 1.0,
                    "sample_tone_curve_v2 clamps flat outside [x0, x1]");

                if (available) {
                    auto sceneClip = clipReq;
                    sceneClip.input_type = SONY2FUJI_INPUT_BUFFER;
                    gpu.mode = SONY2FUJI_GPU_OFF;
                    sony2fuji_session_set_gpu_config(s, &gpu);
                    const auto cpuClip = render(s, sceneClip);
                    gpu.mode = SONY2FUJI_GPU_FORCE;
                    sony2fuji_session_set_gpu_config(s, &gpu);
                    const auto gpuClip = render(s, sceneClip);
                    require(sony2fuji_session_get_last_backend(s) == rawlabtest::nativeBackend,
                        "free-X master + channel + luminosity runs on Force GPU");
                    for (size_t i = 0; i < cpuClip.size(); ++i) {
                        require(std::abs(int(gpuClip[i]) - int(cpuClip[i])) <= 2,
                            "free-X Force GPU matches CPU within 2 DN");
                    }
                    gpu.mode = SONY2FUJI_GPU_OFF;
                    sony2fuji_session_set_gpu_config(s, &gpu);
                }
            }

            // 6) Pipeline::setToneCurve resets curveApplyToLuminosity_ and parametricCurve_
            require(sony2fuji_session_set_tone_curve(s, &reset) == SONY2FUJI_STATUS_OK, "legacy setToneCurve reset");
            require(render(s, v2Req) == v2Baseline, "legacy setToneCurve clears v2 luminosity and parametric state");
        }
        if (argc>1) {
            const char* argRaw=*argv[1] ? argv[1] : nullptr;
            const char* envRaw=std::getenv("RAWLAB_TEST_RAW");
            if (envRaw && !*envRaw) envRaw=nullptr;
            const char* rawPath=argRaw ? argRaw : envRaw;
            if (!rawPath) {
                sony2fuji_session_destroy(s);
                std::cout << "SKIP tone_curve_raw: supply SONY2FUJI_TEST_RAW or RAWLAB_TEST_RAW\n";
                return 77;
            }
            if (!std::filesystem::is_regular_file(std::filesystem::u8path(rawPath))) {
                sony2fuji_session_destroy(s);
                std::cerr << "FAIL tone_curve_raw: RAW sample does not exist: " << rawPath << '\n';
                return 1;
            }
            r.input_type=SONY2FUJI_INPUT_RAW;r.input_path=rawPath;r.input_pixels=nullptr;r.input_width=r.input_height=0;
            r.size_mode=SONY2FUJI_SIZE_LIMIT_LONG_EDGE;r.long_edge=192;
            sony2fuji_session_set_tone_curve(s,&reset);const auto before=render(s,r);
            custom.points[1]={.25,.12};custom.points[2]={.75,.88};
            sony2fuji_session_set_tone_curve(s,&custom);require(render(s,r)!=before,"curve reaches real RAW");
            sony2fuji_session_set_tone_curve(s,&identity);require(render(s,r)==before,"RAW identity exact");
        }
        sony2fuji_session_destroy(s);std::cout << "Tone curve API checks passed\n";return 0;
    } catch (const std::exception& error) { if(s)sony2fuji_session_destroy(s);std::cerr<<error.what()<<'\n';return 1; }
}
