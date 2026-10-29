#include "lut_compatibility.h"
#include "lut_contract_json.h"
#include "sha256.h"
#include "sony2fuji/lut_parser.h"
#include <cctype>
#include <filesystem>
#include <fstream>
#include <sstream>

namespace sony2fuji {
class LUTCompatibilityAccess {
public:
    static void assign(LUT3D& lut,const LUTColorContract& contract) {
        lut.colorContract_=contract;lut.explicitContract_=true;
        lut.contractState_=contract.base==LUTBaseRendering::RawLabNeutral ?
            LUTContractState::ApproximateBase:LUTContractState::Compatibility;
    }
};
namespace {
using nlohmann::json;
json candidates(const json& contract, bool fixed, const std::string& style, const json& hints) {
    json result=json::array();
    const auto append=[&](const json& value) {
        json assumptions=json::array();
        if(!fixed) {
            if(contract["input"]["space"]=="") assumptions.push_back("input-space");
            if(contract["output"]["space"]=="") assumptions.push_back("output-space");
            assumptions.push_back("ranges-and-interpolation");
            if(value["base_rendering"]=="rawlab-neutral-v1") assumptions.push_back("neutral-base");
        }
        result.push_back({{"id","candidate-"+std::to_string(result.size()+1)}, {"contract",value},
            {"basis",fixed?"file-parameters":hints.empty()?"assumed":"partial-metadata"},
            {"assumptions",assumptions}});
    };
    if(fixed) { append(contract);return result; }
    std::vector<std::string> inputs,outputs;
    if(contract["input"]["space"]!="") inputs.push_back(contract["input"]["space"].get<std::string>());
    else {
        inputs={"srgb","rec709-gamma24"};
        if(style!="std") inputs.insert(inputs.end(),{"vlog-vgamut","slog3-sgamut3-cine","slog3-sgamut3"});
    }
    if(contract["output"]["space"]!="") outputs.push_back(contract["output"]["space"].get<std::string>());
    else outputs={"srgb","rec709-gamma24"};
    for(const auto& input:inputs) for(const auto& output:outputs) {
        auto value=contract;
        if(value["input"]["space"]=="") {
            const bool display=input=="srgb" || input=="rec709-gamma24";
            value["input"]["space"]=input;value["input"]["reference"]=display?"display":"scene";
            value["base_rendering"]=display?"rawlab-neutral-v1":"none";
        }
        if(value["output"]["space"]=="") {value["output"]["space"]=output;value["output"]["reference"]="display";}
        LUTColorContract parsed;
        if(parseLUTColorContract(value.dump(),parsed)==LUTContractState::MissingReference) append(value);
    }
    return result;
}
std::string sourceBytes(const std::string& path) {
    const auto file = std::filesystem::u8path(path);
    const auto size = std::filesystem::file_size(file);
    if (size > 256u*1024u*1024u) throw std::invalid_argument("LUT exceeds size limit");
    std::ifstream input(file,std::ios::binary);
    std::string bytes(static_cast<size_t>(size),'\0');
    if (!input.read(bytes.data(),bytes.size())) throw std::runtime_error("Cannot read LUT");
    return bytes;
}
json options(const std::string& path, const std::string& bytes) {
    const auto format=LUTParser::detectFormat(path);
    auto lut=std::make_unique<LUT3D>();
    json result={{"eligible",false}};
    if ((format!="cube" && format!="vlt") || lut->loadFromData(bytes,format=="vlt")!=ErrorCode::Success) return result;
    const bool alreadyCompatible=lut->contractState()==LUTContractState::Compatibility || lut->contractState()==LUTContractState::ApproximateBase;
    if(!alreadyCompatible && lut->contractState()!=LUTContractState::MissingColor && lut->contractState()!=LUTContractState::MissingReference) return result;
    json contract={{"version",1},
        {"input",{{"space",""},{"reference","display"},{"range","full"}}},
        {"output",{{"space",""},{"reference","display"},{"range","full"}}},
        {"interpolation","linear"},{"base_rendering","rawlab-neutral-v1"}};
    std::string style;
    bool fixed=false, extreme=false, legacy=false;
    json hints=json::array();
    std::istringstream stream(bytes);
    std::string line;
    while(std::getline(stream,line)) {
        const auto first=line.find_first_not_of(" \t\r");
        if(first==std::string::npos) continue;
        line.erase(0,first);
        if(line.rfind("#LUMIXPHOTOSTYLE ",0)==0) {
            style=line.substr(17);
            style.erase(std::remove_if(style.begin(),style.end(),[](unsigned char c){return std::isspace(c);}),style.end());
            std::transform(style.begin(),style.end(),style.begin(),[](unsigned char c){return std::tolower(c);});
        }
        if(line.rfind("#",0)==0) {
            auto colon=line.find(':');
            auto key=line.substr(1,colon==std::string::npos?line.size():colon-1);
            key.erase(std::remove_if(key.begin(),key.end(),[](unsigned char c){return !std::isalnum(c);}),key.end());
            std::transform(key.begin(),key.end(),key.begin(),[](unsigned char c){return std::tolower(c);});
            if(key=="gamma" || key=="gamut") legacy=true;
            if(key=="rawlabcolorcontract" && colon!=std::string::npos) {
                contract=parseLUTJSON(line.substr(colon+1));contract.erase("evidence");fixed=true;
            }
            if(key=="rawlabcompatibility" && colon!=std::string::npos) {
                contract=parseLUTJSON(line.substr(colon+1)).at("contract");fixed=true;
            }
            if (!fixed && line.find("Created with LUTCalc")!=std::string::npos) {
                if(line.find("S-Log3/Sony S-Gamut3.cine ->")!=std::string::npos) contract["input"]["space"]="slog3-sgamut3-cine";
                else if(line.find("S-Log3/Sony S-Gamut3 ->")!=std::string::npos) contract["input"]["space"]="slog3-sgamut3";
                if(contract["input"]["space"]!="") {
                    contract["input"]["reference"]="scene";contract["base_rendering"]="none";
                    hints.push_back("lutcalc-input");
                }
                if(line.find("Input 100% ->")!=std::string::npos) contract["input"]["range"]="legal10";
                if(line.find("Output 100%")!=std::string::npos) contract["output"]["range"]="legal10";
            }
            if(!fixed && line.find("# Color profile:")==0 && line.find("Rec709gamma2.4.icc")!=std::string::npos) {
                contract["input"]["space"]="rec709-gamma24";contract["output"]["space"]="rec709-gamma24";
                hints.push_back("rec709-profile");
            }
        } else {
            std::istringstream numbers(line); double r,g,b;
            if(numbers>>r>>g>>b) extreme |= std::max({std::abs(r),std::abs(g),std::abs(b)})/(format=="vlt"?4095.:1.)>16;
        }
    }
    if(legacy || (!style.empty() && style!="std" && style!="vlog")) return result;
    if(!fixed && style=="vlog") {
        contract["input"]["space"]="vlog-vgamut";contract["input"]["reference"]="scene";contract["base_rendering"]="none";
        hints.push_back("panasonic-vlog");
    } else if(style=="std") hints.push_back("panasonic-standard");
    return {{"eligible",true},{"source_sha256",hash::sha256Bytes(bytes.data(),bytes.size())},
        {"contract",contract},{"fixed_contract",fixed},{"photo_style",style},{"extreme_values",extreme},{"hints",hints},
        {"already_compatible",alreadyCompatible},{"candidates",candidates(contract,fixed,style,hints)}};
}
LUTColorContract validatedContract(const json& info,const json& value) {
    LUTColorContract contract;
    if(value.contains("evidence") || parseLUTColorContract(value.dump(),contract)!=LUTContractState::MissingReference)
        throw std::invalid_argument("Complete supported color parameters are required");
    if(info["fixed_contract"]==true && info["contract"]!=value)
        throw std::invalid_argument("Original color parameters must be preserved");
    if((info["photo_style"]=="std" && contract.input.reference!=LUTReference::Display) ||
        (info["photo_style"]=="vlog" && contract.input.space!=LUTColorSpace::VLogVGamut))
        throw std::invalid_argument("Input conflicts with the original photo style");
    return contract;
}
}
std::string inspectLUTCompatibility(const std::string& path) { return options(path,sourceBytes(path)).dump(); }
std::shared_ptr<LUT3D> loadLUTCompatibilityPreview(const std::string& path,const std::string& text) {
    if(text.size()>65536) throw std::invalid_argument("Preview request exceeds limit");
    const auto request=parseLUTJSON(text);
    if(!request.is_object() || request.size()!=2 || !request.contains("source_sha256") || !request.contains("contract"))
        throw std::invalid_argument("Preview requires a source hash and complete parameters");
    const auto bytes=sourceBytes(path);
    const auto info=options(path,bytes);
    if(!info.value("eligible",false) || info["source_sha256"]!=request["source_sha256"])
        throw std::invalid_argument("Source changed or cannot use compatibility");
    const auto contract=validatedContract(info,request["contract"]);
    auto lut=std::make_shared<LUT3D>();
    if(lut->loadFromData(bytes,LUTParser::detectFormat(path)=="vlt")!=ErrorCode::Success)
        throw std::invalid_argument("Invalid LUT table");
    LUTCompatibilityAccess::assign(*lut,contract);
    return lut;
}
std::string prepareLUTCompatibility(const std::string& path, const std::string& text) {
    if(text.size()>65536) throw std::invalid_argument("Compatibility request exceeds limit");
    auto request=parseLUTJSON(text);
    const bool extremeConfirmed=request.value("confirmed_extreme_values",false);
    request.erase("confirmed_extreme_values");
    if(!request.is_object() || request.size()!=3 || !request.contains("source_sha256") ||
        !request.contains("contract") || !request.contains("confirmed") || !request["confirmed"].is_boolean() ||
        !request["confirmed"].get<bool>()) throw std::invalid_argument("Explicit compatibility confirmation is required");
    const auto bytes=sourceBytes(path);
    const auto info=options(path,bytes);
    if(!info.value("eligible",false) || info["source_sha256"]!=request["source_sha256"])
        throw std::invalid_argument("Source changed or cannot use compatibility");
    if(info["extreme_values"]==true && !extremeConfirmed) throw std::invalid_argument("Extreme LUT values require explicit confirmation");
    validatedContract(info,request["contract"]);
    if(info["already_compatible"]==true) return bytes;
    json record={{"version",1},{"source_bytes",bytes.size()},{"source_sha256",info["source_sha256"]},
        {"confirmed",true},{"confirmed_extreme_values",extremeConfirmed},{"contract",request["contract"]}};
    auto prepared=bytes+"\n#RawLabCompatibility:"+record.dump()+"\n";
    LUT3D validation;
    if(validation.loadFromData(prepared,LUTParser::detectFormat(path)=="vlt")!=ErrorCode::Success || !validation.isPhotoLUT())
        throw std::invalid_argument("Invalid prepared compatibility asset");
    return prepared;
}
}
