#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/photo_rendering.h"
#include "nlohmann/json.hpp"
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
using nlohmann::json;
namespace {
int failures=0;
void check(bool value,const char* label) { if (!value) { ++failures; std::cerr<<"FAIL "<<label<<'\n'; } }
json contract(std::string input, std::string output="srgb", std::string reference="scene", std::string base="none") {
    return {{"version",1},{"input",{{"space",input},{"reference",reference},{"range","full"}}},
        {"output",{{"space",output},{"reference",output=="linear-srgb"?"scene":"display"},{"range","full"}}},
        {"interpolation","linear"},{"base_rendering",base},
        {"evidence",{{"source","Synthetic independent analytical reference"},{"conditions","identity table, D65, no additional tone mapping"}}}};
}
void write(const std::filesystem::path& path,const json& data) {
    std::ofstream file(path);file<<"#RawLabColorContract:"<<data.dump()<<"\nLUT_3D_SIZE 2\n";
    for(int b=0;b<2;++b) for(int g=0;g<2;++g) for(int r=0;r<2;++r) file<<r<<' '<<g<<' '<<b<<'\n';
}
std::vector<unsigned char> render(sony2fuji_session* session,sony2fuji_request& r,sony2fuji_gpu_mode mode,sony2fuji_status* out=nullptr) {
    sony2fuji_gpu_config cfg{SONY2FUJI_GPU_CONFIG_VERSION,sizeof(sony2fuji_gpu_config),mode};
    sony2fuji_session_set_gpu_config(session,&cfg);sony2fuji_buffer b{};
    auto status=sony2fuji_process(session,&r,&b);if(out)*out=status;
    std::vector<unsigned char> values;
    if(status==SONY2FUJI_STATUS_OK && b.data) {auto p=static_cast<unsigned char*>(b.data);values.assign(p,p+b.size_bytes);}
    sony2fuji_release_buffer(&b);return values;
}
}
int main() {
    const auto dir=std::filesystem::temp_directory_path()/("rawlab-contract-render-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directory(dir);auto path=dir/"look.cube";std::string filename=path.u8string();
    const auto vlt=dir/"identity.vlt";
    {
        std::ofstream file(vlt);file<<"# panasonic vlt file version 1.0\n# source vlt file \"\"\nLUT_3D_SIZE 17\n\n";
        for(int b=0;b<17;++b)for(int g=0;g<17;++g)for(int r=0;r<17;++r)
            file<<std::min(r*256,4095)<<' '<<std::min(g*256,4095)<<' '<<std::min(b*256,4095)<<'\n';
        file<<"#RawLabColorContract:"<<contract("linear-srgb").dump()<<'\n';
    }
    sony2fuji_look_format format=SONY2FUJI_LOOK_UNKNOWN;uint32_t version=0;
    check(sony2fuji_validate_look(vlt.u8string().c_str(),&format,&version)==SONY2FUJI_STATUS_OK &&
          int(format)==3 && version==1,"VLT is validated as its own format through the shared import ABI");
    const std::array<unsigned char,12> pixels{0,0,0,46,46,46,230,230,230,255,255,255};
    sony2fuji_request r{};r.version=SONY2FUJI_REQUEST_VERSION;r.struct_size=sizeof(r);
    r.input_type=SONY2FUJI_INPUT_BUFFER;r.input_pixels=pixels.data();r.input_width=4;r.input_height=1;
    r.input_pixel_format=SONY2FUJI_PIXEL_RGB8;r.input_color_space=SONY2FUJI_COLOR_SRGB;r.input_is_linear=1;
    r.brightness=r.contrast=r.saturation=1;r.temperature=6500;r.size_mode=SONY2FUJI_SIZE_NATIVE;
    r.output_target=SONY2FUJI_TARGET_BUFFER;r.output_format=SONY2FUJI_OUTPUT_RGB8;r.intent=SONY2FUJI_INTENT_FINAL;
    sony2fuji_session* session=nullptr;sony2fuji_session_create(&session);
    const auto neutral=render(session,r,SONY2FUJI_GPU_OFF);
    r.lut_path=filename.c_str();r.lut_strength=1;
    for (const auto* name : {"linear-srgb","vlog-vgamut","slog3-sgamut3","slog3-sgamut3-cine"}) {
        write(path,contract(name));auto actual=render(session,r,SONY2FUJI_GPU_OFF);
        check(actual.size()==12,"Explicit contract renders on CPU");
        for(size_t i=0;i<actual.size();++i) {
            const double x=pixels[i]/255.;double expected=x;
            if(std::string(name)=="vlog-vgamut")expected=x<.01?5.6*x+.125:.241514*std::log10(x+.00873)+.598206;
            if(std::string(name).find("slog3")==0)expected=x<.01125?(x*(171.2102946929-95)/.01125+95)/1023.:(420+std::log10((x+.01)/.19)*261.5)/1023.;
            check(std::abs(int(actual[i])-std::lround(expected*255))<=1,"Published Log anchors; no extra neutral display curve");
        }
        auto automatic=render(session,r,SONY2FUJI_GPU_AUTO);
        check(automatic==actual && sony2fuji_session_get_last_backend(session)==SONY2FUJI_BACKEND_CPU,"Auto uses the verified CPU contract");
        sony2fuji_status status;render(session,r,SONY2FUJI_GPU_FORCE,&status);
        check(status==SONY2FUJI_STATUS_UNSUPPORTED,"Force never silently evaluates an unsupported contract on GPU");
    }
    write(path,contract("linear-srgb","linear-srgb"));
    check(render(session,r,SONY2FUJI_GPU_OFF)==neutral,"Scene-output identity receives neutral once");
    write(path,contract("rec709-gamma24","rec709-gamma24","display","rawlab-neutral-v1"));
    check(render(session,r,SONY2FUJI_GPU_OFF)==neutral,"Display Gamma 2.4 identity preserves the neutral reference");
    write(path,contract("srgb","srgb","display","source-display"));
    sony2fuji_status status;render(session,r,SONY2FUJI_GPU_OFF,&status);
    check(status==SONY2FUJI_STATUS_UNSUPPORTED,"Source-display base cannot be invented from RAW/scene input");
    r.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;r.input_is_linear=0;
    check(render(session,r,SONY2FUJI_GPU_OFF)==std::vector<unsigned char>(pixels.begin(),pixels.end()),"Source-display identity preserves already rendered input");
    write(path,contract("vlog-vgamut"));render(session,r,SONY2FUJI_GPU_OFF,&status);
    check(status==SONY2FUJI_STATUS_UNSUPPORTED,"Scene Log contract cannot recover scene light from a display image");
    {
        auto parameters=contract("rec709-gamma24","rec709-gamma24","display","rawlab-neutral-v1");
        parameters.erase("evidence");write(path,parameters);
        sony2fuji_blob info{}, prepared{};
        check(sony2fuji_inspect_lut_compatibility(filename.c_str(),&info)==SONY2FUJI_STATUS_OK && info.data,
              "Shared C ABI returns a compatibility draft");
        if(info.data) {
            auto draft=json::parse(std::string(static_cast<char*>(info.data),info.size_bytes));
            json request={{"source_sha256",draft["source_sha256"]},{"confirmed",true},{"contract",parameters}};
            json previewRequest={{"source_sha256",draft["source_sha256"]},{"contract",parameters}};
            sony2fuji_buffer preview{};
            r.input_type=SONY2FUJI_INPUT_BUFFER;r.input_is_linear=1;r.intent=SONY2FUJI_INTENT_PREVIEW;r.preview_long_edge=4;
            check(sony2fuji_preview_lut_compatibility(session,&r,previewRequest.dump().c_str(),&preview)==SONY2FUJI_STATUS_OK && preview.data,
                  "C ABI previews a candidate without a confirmation record");
            if(preview.data) {
                check(preview.width==4 && preview.height==1,"Parity comparison uses equal preview and reference dimensions");
                auto bytes=static_cast<unsigned char*>(preview.data);
                check(std::vector<unsigned char>(bytes,bytes+preview.size_bytes)==neutral,"Transient preview agrees with the confirmed PHOTO evaluator");
                sony2fuji_blob report{};
                const auto conditions=json{{"same_source",true},{"same_geometry",true},{"same_processing",true},{"known_srgb",true},
                    {"reference_source","Synthetic parity test, not independent appearance evidence"}};
                check(sony2fuji_compare_lut_previews(&preview,&preview,conditions.dump().c_str(),&report)==SONY2FUJI_STATUS_OK && report.data,
                      "Reference comparison is exposed through the shared C ABI");
                if(report.data) check(json::parse(std::string(static_cast<char*>(report.data),report.size_bytes))["appearance"]=="unverified",
                    "Zero pixel error does not certify the LUT");
                check(sony2fuji_compare_lut_previews(&preview,nullptr,conditions.dump().c_str(),&report)==SONY2FUJI_STATUS_INVALID_ARGUMENT && !report.data,
                    "Invalid comparison clears owned output");
                sony2fuji_release_blob(&report);
            }
            r.output_target=SONY2FUJI_TARGET_FILE;
            check(sony2fuji_preview_lut_compatibility(session,&r,previewRequest.dump().c_str(),&preview)==SONY2FUJI_STATUS_INVALID_ARGUMENT && !preview.data,
                  "Unconfirmed compatibility cannot use the preview API to export a file");
            r.output_target=SONY2FUJI_TARGET_BUFFER;r.intent=SONY2FUJI_INTENT_FINAL;r.preview_long_edge=0;
            sony2fuji_release_buffer(&preview);
            check(sony2fuji_prepare_lut_compatibility(filename.c_str(),request.dump().c_str(),&prepared)==SONY2FUJI_STATUS_OK && prepared.data,
                  "Shared C ABI prepares the confirmed immutable asset");
            if(prepared.data) {
                auto installed=dir/"compatible.cube";
                {std::ofstream file(installed,std::ios::binary);file.write(static_cast<char*>(prepared.data),prepared.size_bytes);}
                const auto installedName=installed.u8string();r.lut_path=installedName.c_str();
                r.input_type=SONY2FUJI_INPUT_BUFFER;r.input_is_linear=1;
                check(sony2fuji_inspect_lut_color(installedName.c_str())==SONY2FUJI_LUT_APPROXIMATE_BASE,
                      "C ABI distinguishes the approximate base from author evidence");
                check(render(session,r,SONY2FUJI_GPU_AUTO)==neutral,"Compatible Gamma 2.4 identity preserves RAW neutral rendering");
                render(session,r,SONY2FUJI_GPU_FORCE,&status);
                check(status==SONY2FUJI_STATUS_UNSUPPORTED,"Compatible looks retain Force rejection");
                r.lut_path=filename.c_str();
            }
            request["confirmed"]=false;
            check(sony2fuji_prepare_lut_compatibility(filename.c_str(),request.dump().c_str(),&prepared)!=SONY2FUJI_STATUS_OK &&
                  !prepared.data && prepared.size_bytes==0,"Rejected confirmation clears previously allocated output");
        }
        sony2fuji_release_blob(&info);sony2fuji_release_blob(&prepared);
    }
    sony2fuji_session_destroy(session);std::filesystem::remove_all(dir);
    std::cout<<"LUT contract render failures: "<<failures<<'\n';return failures?1:0;
}
