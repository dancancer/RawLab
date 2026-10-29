#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <iostream>
#include <stdexcept>

namespace {
using Json=nlohmann::json;
void check(bool value,const std::string& message) { if (!value) throw std::runtime_error(message); }
}

int main() {
    try {
        Json document={{"schema_version",6},
            {"processing",{{"family","rawlab_hdr"},{"version",1},{"quality","standard"}}},
            {"input",{{"path","phone.heic"},{"type","hdr_raster"}}},
            {"edits",{{"exposure",{{"ev",1.25}}},
                {"white_balance",{{"mode","relative"},{"relative_temperature",7200},{"relative_tint",-12}}},
                {"tone",{{"contrast",1.3},{"saturation",1.1},{"highlights",-.2},{"shadows",.4}}},
                {"geometry",{{"quarter_turns",1}}}}},
            {"output",{{"path","edited.jpg"},{"format","hdr_jpeg"},{"base_color","display_p3"},
                {"jpeg_quality",95},{"size",{{"mode","limit_long_edge"},{"long_edge",1600}}}}}};
        sony2fuji::EditRecipe recipe;
        std::string error;
        check(sony2fuji::parseEditRecipe(document.dump(),recipe,error),"HDR recipe: "+error);
        const auto normalized=sony2fuji::serializeEditRecipe(recipe);
        check(sony2fuji::parseEditRecipe(normalized,recipe,error),"HDR normalized parse: "+error);
        check(sony2fuji::serializeEditRecipe(recipe)==normalized,"HDR recipe roundtrip changed fields");
        auto reject=[&](Json invalid,const char* field) {
            check(!sony2fuji::parseEditRecipe(invalid.dump(),recipe,error),std::string("accepted ")+field);
            check(error.find(field)!=std::string::npos,"error lacks rejected field: "+error);
            check(sony2fuji::serializeEditRecipe(recipe)==normalized,"invalid recipe changed destination");
        };
        for (const char* group:{"look","effects","hsl","detail","denoise","lens_correction","color","color_grading"}) {
            auto invalid=document; invalid["edits"][group]=Json::object(); reject(invalid,group);
        }
        for (const char* field:{"s_curve","black_point","white_point","curve"}) {
            auto invalid=document; invalid["edits"]["tone"][field]=0; reject(invalid,field);
        }
        auto invalid=document; invalid["edits"]["exposure"]["mode"]="sensor"; reject(invalid,"mode");
        invalid=document; invalid["edits"]["exposure"]["brightness"]=1; reject(invalid,"brightness");
        invalid=document; invalid["edits"]["exposure"]["ev"]=4.01; reject(invalid,"ev");
        invalid=document; invalid["edits"]["white_balance"]["mode"]="temperature"; reject(invalid,"mode");
        invalid=document; invalid["edits"]["white_balance"]["temperature_kelvin"]=6500; reject(invalid,"temperature_kelvin");
        invalid=document; invalid["input"]["type"]="raster"; reject(invalid,"input.type");
        invalid=document; invalid["processing"]["family"]="rawlab"; reject(invalid,"processing.family");
        invalid=document; invalid["processing"]["version"]=2; reject(invalid,"processing.version");
        invalid=document; invalid["output"]["format"]="jpeg"; reject(invalid,"output.format");
        invalid=document; invalid["output"].erase("base_color"); reject(invalid,"base_color");
        invalid=document; invalid["output"]["base_color"]="bt2020"; reject(invalid,"base_color");
        invalid=document; invalid["schema_version"]=7; reject(invalid,"schema_version");
        invalid=document; invalid["schema_version"]=5; reject(invalid,"processing.family");
        bool refused=false;
        try { recipe.toRequest(); } catch (const std::invalid_argument&) { refused=true; }
        check(refused,"HDR recipe entered legacy request v2");
        std::cout<<"PASS HDR v6 roundtrip, strict fields, version isolation and legacy request refusal\n";
        return 0;
    } catch (const std::exception& e) { std::cerr<<"FAIL "<<e.what()<<'\n'; return 1; }
}
