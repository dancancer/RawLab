#include "core/lut_compatibility.h"
#include "sony2fuji/lut_parser.h"
#include "nlohmann/json.hpp"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>

using nlohmann::json;
using namespace sony2fuji;
namespace {
int failures = 0;
void check(bool ok, const char* label) { if (!ok) { ++failures; std::cerr << "FAIL " << label << '\n'; } }
template<class F> void rejects(F operation, const char* label) { try { operation(); check(false,label); } catch (const std::exception&) {} }
void write(const std::filesystem::path& path, const std::string& text) { std::ofstream(path, std::ios::binary) << text; }
json config() { return {{"version",1},
    {"input",{{"space","srgb"},{"reference","display"},{"range","full"}}},
    {"output",{{"space","srgb"},{"reference","display"},{"range","full"}}},
    {"interpolation","linear"},{"base_rendering","rawlab-neutral-v1"}}; }
}
int main() {
    const auto dir = std::filesystem::temp_directory_path()/ ("rawlab-compatibility-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(dir);
    const auto source=dir/"source.cube", managed=dir/"managed.cube";
    const std::string table="LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
    write(source,table);
    try {
        auto info=json::parse(inspectLUTCompatibility(source.u8string()));
        check(info["eligible"]==true && info["contract"]["input"]["space"]=="" && info["contract"]["output"]["space"]=="",
              "Unknown colors stay unselected in the compatibility prompt");
        check(info.contains("candidates") && info["candidates"].size()==10,
              "Unknown input offers bounded display and Log hypotheses without selecting one");
        if(info.contains("candidates")) {
            check(info["candidates"][0]["contract"]["input"]["space"]=="srgb" &&
                  info["candidates"][0]["basis"]=="assumed" && !info["candidates"][0].contains("confidence"),
                  "Candidate order is stable and does not invent calibrated confidence");
        }
        auto request=json{{"source_sha256",info["source_sha256"]},{"confirmed",true},{"contract",config()}};
        auto unconfirmed=request; unconfirmed["confirmed"]=false;
        rejects([&]{prepareLUTCompatibility(source.u8string(),unconfirmed.dump());}, "No prepared bytes before confirmation");
        auto prepared=prepareLUTCompatibility(source.u8string(),request.dump());
        check(prepared.rfind(table,0)==0, "Original source bytes are preserved exactly");
        write(managed,prepared);
        auto lut=LUTParser::loadLUT(managed.u8string());
        check(lut && lut->isPhotoLUT() && int(lut->contractState())==8, "A neutral base substitution is marked approximate");
        auto reimport=json::parse(inspectLUTCompatibility(managed.u8string()));
        check(reimport["eligible"]==true && reimport["fixed_contract"]==true, "External compatibility assets still expose a confirmation draft");
        auto reimportRequest=request; reimportRequest["source_sha256"]=reimport["source_sha256"];
        check(prepareLUTCompatibility(managed.u8string(),reimportRequest.dump())==prepared, "Reimport preserves the confirmed record without nesting it");
        write(source,"# source changed\n"+table);
        rejects([&]{prepareLUTCompatibility(source.u8string(),request.dump());}, "Changed source cannot reuse an earlier confirmation");

        write(source,"#LUMIXPHOTOSTYLE STD\n"+table);
        info=json::parse(inspectLUTCompatibility(source.u8string())); request["source_sha256"]=info["source_sha256"];
        check(info.contains("candidates") && info["candidates"].size()==4,
              "STD restricts hypotheses to four common display encoding combinations");
        for(const auto& candidate:info.value("candidates",json::array()))
            check(candidate["contract"]["input"]["reference"]=="display" &&
                  candidate["contract"]["base_rendering"]=="rawlab-neutral-v1" &&
                  candidate["basis"]=="partial-metadata", "STD candidates retain the approximate base");
        request["contract"]["base_rendering"]="source-display";
        write(managed,prepareLUTCompatibility(source.u8string(),request.dump())); lut=LUTParser::loadLUT(managed.u8string());
        check(lut && int(lut->contractState())==7, "An existing rendered source does not claim camera base emulation");
        request["contract"]["input"]={{"space","vlog-vgamut"},{"reference","scene"},{"range","full"}};
        request["contract"]["base_rendering"]="none";
        rejects([&]{prepareLUTCompatibility(source.u8string(),request.dump());}, "STD cannot silently become a Log-input LUT");

        write(source,"#LUMIXPHOTOSTYLE VLOG\n"+table);
        info=json::parse(inspectLUTCompatibility(source.u8string()));
        check(info["contract"]["input"]["space"]=="vlog-vgamut" && info["contract"]["output"]["space"]=="", "VLOG suggests input but does not guess output");
        check(info.contains("candidates") && info["candidates"].size()==2,
              "Known VLOG input only varies the unknown output");
        request["source_sha256"]=info["source_sha256"];request["contract"]=config();
        rejects([&]{prepareLUTCompatibility(source.u8string(),request.dump());}, "Known VLOG input cannot be replaced by sRGB");
        write(source,"#LUMIXPHOTOSTYLE STD\n#LUMIXPHOTOSTYLE VLOG\n"+table);
        check(json::parse(inspectLUTCompatibility(source.u8string()))["eligible"]==false,"Conflicting declarations do not offer compatibility");

        write(source,"# S-Log3/Sony S-Gamut3.cine -> LA - :FLog2_to_ACROS/LA, Input 109% -> Output 100% - Created with LUTCalc v4.09 by Ben Turley\n"+table);
        info=json::parse(inspectLUTCompatibility(source.u8string()));
        check(info["contract"]["input"]["space"]=="slog3-sgamut3-cine" && info["contract"]["output"]["space"]=="" &&
              info["contract"]["input"]["range"]=="full" && info["contract"]["output"]["range"]=="legal10", "Recognized LUTCalc metadata suggests only declared fields");
        auto authored=config();authored["base_rendering"]="source-display";
        write(source,"#RawLabColorContract:"+authored.dump()+"\n"+table);
        info=json::parse(inspectLUTCompatibility(source.u8string()));
        check(info["eligible"]==true && info["contract"]==authored,"Missing evidence preserves complete original color parameters");
        check(info.contains("candidates") && info["candidates"].size()==1 &&
              info["candidates"][0]["contract"]==authored && info["candidates"][0]["basis"]=="file-parameters",
              "Fixed parameters expose one unchanged candidate, without appearance certification");
        request["source_sha256"]=info["source_sha256"];request["contract"]=authored;
        write(managed,prepareLUTCompatibility(source.u8string(),request.dump()));
        lut=LUTParser::loadLUT(managed.u8string());
        check(lut && lut->isPhotoLUT(),"User-assigned missing evidence is not fabricated author evidence");
        request["contract"]["output"]["space"]="rec709-gamma24";
        rejects([&]{prepareLUTCompatibility(source.u8string(),request.dump());},"Complete original color parameters cannot be silently overridden");
    } catch(const std::exception& error) { check(false,error.what()); }
    std::filesystem::remove_all(dir);
    std::cout<<"LUT compatibility failures: "<<failures<<'\n';return failures?1:0;
}
