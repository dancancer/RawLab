#include "core/lut_compatibility.h"
#include "core/lut_preview_comparison.h"
#include "sony2fuji/lut_parser.h"
#include "nlohmann/json.hpp"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>

using namespace sony2fuji;
using nlohmann::json;
namespace {
int failures=0;
void check(bool value,const char* label) { if(!value) {++failures;std::cerr<<"FAIL "<<label<<'\n';} }
template<class F> void rejects(F action,const char* label) {try {action();check(false,label);}catch(const std::exception&){} }
void write(const std::filesystem::path& file,const std::string& data) {std::ofstream(file,std::ios::binary)<<data;}
}
int main() {
    const auto dir=std::filesystem::temp_directory_path()/("rawlab-guided-lut-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directory(dir);const auto path=dir/"unknown.cube";
    const std::string table="LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
    write(path,table);
    try {
        auto info=json::parse(inspectLUTCompatibility(path.u8string()));
        auto request=json{{"source_sha256",info["source_sha256"]},{"contract",info["candidates"][0]["contract"]}};
        auto preview=loadLUTCompatibilityPreview(path.u8string(),request.dump());
        check(preview && preview->hasColorContract() && preview->isPhotoLUT(),"A complete candidate can preview without import confirmation");
        check(json::parse(inspectLUTCompatibility(path.u8string()))["source_sha256"]==info["source_sha256"] &&
              LUTParser::loadLUT(path.u8string())->contractState()==LUTContractState::MissingColor,
              "Preview leaves original bytes and original import state untouched");
        check(std::distance(std::filesystem::directory_iterator(dir),std::filesystem::directory_iterator())==1,
              "Preview writes no temporary LUT or installed record");
        auto invalid=request;invalid["source_sha256"]="changed";
        rejects([&]{loadLUTCompatibilityPreview(path.u8string(),invalid.dump());},"Preview rejects a stale source hash");
        invalid=request;invalid["contract"]["output"]["space"]="";
        rejects([&]{loadLUTCompatibilityPreview(path.u8string(),invalid.dump());},"Preview rejects incomplete configurations");
        write(path,"#LUMIXPHOTOSTYLE VLOG\n"+table);info=json::parse(inspectLUTCompatibility(path.u8string()));
        request["source_sha256"]=info["source_sha256"];
        rejects([&]{loadLUTCompatibilityPreview(path.u8string(),request.dump());},"Preview cannot override a declared VLOG input");

        std::vector<unsigned char> a{20,30,40,255,60,70,80,255}, b=a;
        sony2fuji_buffer candidate{a.data(),a.size(),2,1,8,SONY2FUJI_PIXEL_RGBA8};
        sony2fuji_buffer reference{b.data(),b.size(),2,1,8,SONY2FUJI_PIXEL_RGBA8};
        json conditions={{"same_source",true},{"same_geometry",true},{"same_processing",true},{"known_srgb",true},
            {"reference_source","Synthetic exact-value fixture; not author appearance evidence"}};
        auto comparison=json::parse(compareLUTPreviews(candidate,reference,conditions.dump()));
        check(comparison.value("mean_absolute_rgb",-1.)==0. && comparison.value("appearance","")=="unverified",
              "Identical pixels report zero error without certifying appearance");
        b[0]=30;comparison=json::parse(compareLUTPreviews(candidate,reference,conditions.dump()));
        check(std::abs(comparison.value("mean_absolute_rgb",-1.)-10./(255*6))<1e-12 &&
              std::abs(comparison.value("max_absolute_rgb",-1.)-10./255)<1e-12,"Reference comparison measures actual channel differences");
        for(const auto* key:{"same_source","same_geometry","same_processing","known_srgb"}) {
            auto missing=conditions;missing[key]=false;
            rejects([&]{compareLUTPreviews(candidate,reference,missing.dump());},"Unconfirmed comparison conditions cannot produce metrics");
        }
        auto missing=conditions;missing["reference_source"]="   ";
        rejects([&]{compareLUTPreviews(candidate,reference,missing.dump());},"Reference provenance cannot be blank");
        reference.width=1;rejects([&]{compareLUTPreviews(candidate,reference,conditions.dump());},"Different preview dimensions cannot be compared");
        reference.width=2;reference.size_bytes=3;
        rejects([&]{compareLUTPreviews(candidate,reference,conditions.dump());},"Short buffers fail before pixel reads");
        reference.size_bytes=b.size();reference.stride_bytes=7;
        rejects([&]{compareLUTPreviews(candidate,reference,conditions.dump());},"Invalid stride is rejected");
        reference.stride_bytes=8;b[3]=0;
        rejects([&]{compareLUTPreviews(candidate,reference,conditions.dump());},"Transparent reference pixels are not silently compared");
    } catch(const std::exception& error) {check(false,error.what());}
    std::filesystem::remove_all(dir);std::cout<<"Guided LUT failures: "<<failures<<'\n';return failures?1:0;
}
