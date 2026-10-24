#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;
using Json=nlohmann::json;
static void require(bool value, const std::string& message) { if (!value) throw std::runtime_error(message); }

int main() {
    try {
        Json document={{"schema_version",5},
            {"processing",{{"family","rawlab"},{"version",2},{"quality","standard"}}},
            {"input",{{"path","input.dng"}}},
            {"edits",{{"exposure",{{"mode","sensor"}}},
                {"color_grading",{{"shadows",{{"hue",223.5},{"saturation",31.25}}},
                    {"midtones",{{"hue",147.75},{"saturation",0}}},
                    {"highlights",{{"hue",37.25},{"saturation",16.5}}}}}}},
            {"output",{{"path","output.png"},{"format","png"}}}};
        EditRecipe recipe;std::string error;
        const bool accepted=parseEditRecipe(document.dump(),recipe,error);
        require(accepted,"v5 color grading accepted: "+error);
        const auto saved=serializeEditRecipe(recipe);
        const auto normalized=Json::parse(saved);
        require(normalized["edits"]["color_grading"]==document["edits"]["color_grading"],"all zones and dormant hue round-trip");
        require(normalized["processing"]==document["processing"],"grading does not change processing identity");
        auto reject=[&](const Json& value) {
            require(!parseEditRecipe(value.dump(),recipe,error),"invalid grading rejected");
            require(serializeEditRecipe(recipe)==saved,"invalid parse preserves destination");
        };
        for (const char* zone : {"shadows","midtones","highlights"}) {
            for (const auto& bad : {Json(-.000001),Json(360),Json(360.000001),Json(true),Json("0"),Json(nullptr)}) {
                auto value=document;value["edits"]["color_grading"][zone]["hue"]=bad;reject(value);
            }
            for (const auto& bad : {Json(-.000001),Json(100.000001),Json(true),Json("0"),Json(nullptr)}) {
                auto value=document;value["edits"]["color_grading"][zone]["saturation"]=bad;reject(value);
            }
            for (const char* key : {"hue","saturation"}) {
                auto value=document;value["edits"]["color_grading"][zone].erase(key);reject(value);
            }
            auto unknown=document;unknown["edits"]["color_grading"][zone]["future"]=1;reject(unknown);
            auto wrongShape=document;wrongShape["edits"]["color_grading"][zone]=Json::array({0,0});reject(wrongShape);
        }
        auto unknown=document;unknown["edits"]["color_grading"]["global"]={{"hue",0},{"saturation",0}};reject(unknown);
        for (int version=1;version<=4;++version) {
            auto old=document;old["schema_version"]=version;old.erase("processing");reject(old);
        }
        auto partial=document;partial["edits"]["color_grading"].erase("highlights");
        require(parseEditRecipe(partial.dump(),recipe,error),"absent recipe zone has identity default");
        require(Json::parse(serializeEditRecipe(recipe))["edits"]["color_grading"]["highlights"]==Json({{"hue",0},{"saturation",0}}),"normalization emits every zone when grading is stored");
        auto nearWrap=document;nearWrap["edits"]["color_grading"]["shadows"]["hue"]=359.999999;
        require(parseEditRecipe(nearWrap.dump(),recipe,error),"valid double hue near wrap is representable canonically");
        require(Json::parse(serializeEditRecipe(recipe))["edits"]["color_grading"]["shadows"]["hue"]==0,"float hue rounding to 360 wraps to zero");
        auto legacy=document;legacy["edits"].erase("color_grading");
        require(parseEditRecipe(legacy.dump(),recipe,error),"old v5 shape still accepted");
        require(!Json::parse(serializeEditRecipe(recipe))["edits"].contains("color_grading"),"all-default grading preserves normalized old shape");
        auto dormant=legacy;dormant["edits"]["color_grading"]["shadows"]={{"hue",210},{"saturation",0}};
        require(parseEditRecipe(dormant.dump(),recipe,error),"dormant hue accepted");
        require(Json::parse(serializeEditRecipe(recipe))["edits"]["color_grading"]["shadows"]["hue"]==210,"zero saturation does not discard stored hue");
        auto rejectSerialization=[&](EditRecipe bad) {
            bool rejected=false;try {serializeEditRecipe(bad);}catch(const std::invalid_argument&) {rejected=true;}
            require(rejected,"serializer rejects invalid or lossy in-memory grading");
        };
        auto old=recipe;old.schemaVersion=4;old.processingVersion=SONY2FUJI_PROCESSING_LEGACY;rejectSerialization(old);
        auto invalid=recipe;invalid.colorGrading.version=2;rejectSerialization(invalid);
        invalid=recipe;--invalid.colorGrading.struct_size;rejectSerialization(invalid);
        invalid=recipe;invalid.colorGrading.midtones_hue=360;rejectSerialization(invalid);
        invalid=recipe;invalid.colorGrading.highlights_saturation=101;rejectSerialization(invalid);
        std::cout<<"PASS color grading recipe compatibility\n";return 0;
    } catch(const std::exception& error) {std::cerr<<error.what()<<'\n';return 1;}
}
