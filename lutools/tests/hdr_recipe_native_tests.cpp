#include "sony2fuji/edit_recipe.h"
#include "core/hdr_rendering.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>

namespace {
void check(bool value,const char* message) { if (!value) throw std::runtime_error(message); }
template<class T> T init() { T value{}; value.version=1; value.struct_size=sizeof(value); return value; }
}

int main() {
    try {
        using namespace sony2fuji;
        using Json=nlohmann::json;
        HDRImagePair source;
        source.hdr=ImageData(4,2); source.sdr=ImageData(4,2);
        source.nativeWidth=4; source.nativeHeight=2; source.sourceHeadroom=16;
        source.hdr.pixels={{-.1f,.18f,.5f},{.1f,.25f,1},{1,2,4},{4,8,16},
            {.18f,.18f,.18f},{.05f,.1f,.2f},{.8f,.5f,.2f},{2,4,8}};
        for (size_t i=0;i<source.hdr.pixels.size();++i) {
            const auto p=source.hdr.pixels[i]; source.sdr.pixels[i]={p.r/16,p.g/16,p.b/16};
        }
        auto borrowed=init<sony2fuji_hdr_image_pair_v1>();
        auto buffer=[&](ImageData& image) {
            auto value=init<sony2fuji_hdr_buffer_v1>(); value.width=4; value.height=2;
            value.data=image.pixels.data(); value.size_bytes=image.pixels.size()*sizeof(RGB); value.stride_bytes=4*sizeof(RGB);
            value.pixel_format=SONY2FUJI_HDR_RGB32F_LINEAR; value.color_encoding=SONY2FUJI_HDR_LINEAR_SRGB; return value;
        };
        borrowed.hdr=buffer(source.hdr); borrowed.sdr=buffer(source.sdr);
        borrowed.native_width=4; borrowed.native_height=2; borrowed.orientation_applied=1;
        borrowed.source_intent=borrowed.render_intent=SONY2FUJI_INTENT_FINAL;
        borrowed.source_headroom=16; borrowed.source_headroom_kind=SONY2FUJI_HDR_HEADROOM_DECLARED;
        sony2fuji_session* pointer=nullptr;
        check(sony2fuji_session_create(&pointer)==SONY2FUJI_STATUS_OK,"session failed");
        const std::unique_ptr<sony2fuji_session,decltype(&sony2fuji_session_destroy)> session(pointer,sony2fuji_session_destroy);
        auto hsl=init<sony2fuji_hsl_config>(); hsl.saturation[0]=80;
        sony2fuji_session_set_hsl(session.get(),&hsl);
        sony2fuji_session_set_raw_exposure_mode(session.get(),SONY2FUJI_EXPOSURE_PREVIEW);
        for (int variant=0;variant<10;++variant) {
            HDRRenderOptions expected;
            if (variant==1) expected.exposureEV=1.25f;
            if (variant>=2) {
                expected.temperature=7200; expected.tint=-12; expected.contrast=30;
                expected.highlights=20; expected.shadows=40; expected.saturation=10;
            }
            if (variant==3) { expected.geometry.quarter_turns=1; expected.geometry.flip_horizontal=true; }
            const bool extendedTone=variant>=4;
            if (extendedTone) {
                expected.processingVersion=2;
                expected.tone.blackPoint=-25;
                expected.tone.whitePoint=50;
                if (variant==4) expected.tone.curveStrength=25;
                else {
                    expected.tone.curve.mode=SONY2FUJI_CURVE_CUSTOM;
                    expected.tone.curve.count=3;
                    expected.tone.curve.points[1]={.5,.625};
                    expected.tone.curve.points[2]={1,1};
                }
            }
            const bool extendedColor=variant>=6;
            const bool rendition=variant>=7;
            const bool effects=variant>=8;
            const bool detail=variant==9;
            if (extendedColor) {
                expected.processingVersion=3;
                expected.color.vibrance=40;
                expected.color.hsl.saturation[1]=25;
                expected.color.grading.wheels[2]={180,30};
            }
            if (rendition) {
                expected.processingVersion=4;
                expected.rendition={1.5f,.5f,20,-30};
            }
            if (effects) {
                expected.processingVersion=5;
                expected.effects.vignetteAmount=-50;
                expected.effects.grainAmount=70;
            }
            if (detail) {
                expected.processingVersion=6;
                expected.detail={1.2f, .7f, -.5f, .6f};
            }
            const auto schema=extendedTone ? expected.processingVersion + 6 : 6;
            Json document={{"schema_version",schema},
                {"processing",{{"family","rawlab_hdr"},{"version",expected.processingVersion},{"quality","standard"}}},
                {"input",{{"path","phone.heic"},{"type","hdr_raster"}}},
                {"edits",{{"exposure",{{"ev",expected.exposureEV}}},
                    {"white_balance",{{"mode","relative"},{"relative_temperature",expected.temperature},{"relative_tint",expected.tint}}},
                    {"tone",{{"contrast",1+expected.contrast/100.0},{"saturation",1+expected.saturation/100.0},
                        {"highlights",-expected.highlights/100.0},{"shadows",expected.shadows/100.0}}},
                    {"geometry",{{"quarter_turns",expected.geometry.quarter_turns},{"flip_horizontal",expected.geometry.flip_horizontal}}}}},
                {"output",{{"path","output.jpg"},{"format","hdr_jpeg"},{"base_color","srgb"}}}};
            if (extendedTone) {
                auto& tone=document["edits"]["tone"];
                tone["black_point"]=-.25;
                tone["white_point"]=.5;
                if (variant==4) tone["s_curve"]=.25;
                else tone["curve"]={{"mode","custom"},{"points",{{0,0},{.5,.625},{1,1}}}};
            }
            if (extendedColor) {
                document["edits"]["color"]["vibrance"]=.4;
                document["edits"]["hsl"]["saturation"]=expected.color.hsl.saturation;
                document["edits"]["color_grading"]["highlights"]={{"hue",180},{"saturation",30}};
            }
            if (rendition) document["edits"]["rendition"]={{"peak_limit_ev",1.5},{"sdr_exposure_ev",.5},
                {"sdr_contrast",.2},{"sdr_saturation",-.3}};
            if (effects) document["edits"]["effects"]={{"vignette_amount",-50},{"grain_amount",70}};
            if (detail) document["edits"]["detail"]={{"sharpening",1.2},{"clarity",.7},{"dehaze",-.5},{"denoise",.6}};
            EditRecipe recipe; std::string error;
            check(parseEditRecipe(document.dump(),recipe,error),error.c_str());
            auto request=recipe.toHDRRenderRequest();
            auto result=init<sony2fuji_hdr_image_pair_v1>(); auto diagnostic=init<sony2fuji_hdr_diagnostic_v1>();
            const auto release=[](sony2fuji_hdr_image_pair_v1* value) { sony2fuji_hdr_release_pair(value); };
            const std::unique_ptr<sony2fuji_hdr_image_pair_v1,decltype(release)> guard(&result,release);
            check(sony2fuji_hdr_render(session.get(),&borrowed,&request.base.base.base.base.base.base,&result,&diagnostic)==SONY2FUJI_STATUS_OK,"recipe native render failed");
            const auto reference=renderHDRPair(source,expected);
            auto compare=[&](const sony2fuji_hdr_buffer_v1& actual,const ImageData& wanted) {
                check(actual.width==uint32_t(wanted.width) && actual.height==uint32_t(wanted.height),"recipe geometry differs");
                const auto* values=static_cast<const float*>(actual.data);
                const auto* oracle=reinterpret_cast<const float*>(wanted.pixels.data());
                for (size_t i=0;i<wanted.pixels.size()*3;++i)
                    check(std::abs(values[i]-oracle[i])<=1e-5f*std::max(1.0f,std::abs(oracle[i])),"recipe/native HDR request differs");
            };
            compare(result.hdr,reference.hdr); compare(result.sdr,reference.sdr);
        }
        std::cout<<"PASS HDR recipe/native parity and old session isolation\n"; return 0;
    } catch (const std::exception& e) { std::cerr<<"FAIL "<<e.what()<<'\n'; return 1; }
}
