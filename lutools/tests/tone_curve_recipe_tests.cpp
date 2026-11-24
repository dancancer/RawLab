#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <iostream>
#include <stdexcept>
using namespace sony2fuji;
using Json=nlohmann::json;
static void require(bool ok,const std::string& message) { if(!ok)throw std::runtime_error(message); }
int main() {
    try {
        Json doc={{"schema_version",5},{"processing",{{"family","rawlab"},{"version",2},{"quality","standard"}}},
            {"input",{{"path","input.dng"}}},{"edits",{{"exposure",{{"mode","sensor"}}},{"tone",{{"curve",{
                {"mode","custom"},{"points",{{0,0},{.25,.12},{.75,.88},{1,1}}}}}}}}},
            {"output",{{"path","output.png"},{"format","png"}}}};
        EditRecipe recipe;std::string error;
        require(parseEditRecipe(doc.dump(),recipe,error),"v5 custom accepted: "+error);
        require(recipe.toneCurve.count==4,"points preserved");
        const auto saved=serializeEditRecipe(recipe);
        require(Json::parse(saved)["edits"]["tone"]["curve"]==doc["edits"]["tone"]["curve"],"curve round trip exact");
        for (int kind=0;kind<13;++kind) {
            auto bad=doc;auto& curve=bad["edits"]["tone"]["curve"];
            if(kind==0)curve["mode"]="unknown";
            if(kind==1)curve["extra"]=0;
            if(kind==2)curve.erase("points");
            if(kind==3)curve["points"]={{0,0}};
            if(kind==4)curve["points"][1]={.75,.1};
            if(kind==5)curve["points"][2]={.75,.01};
            if(kind==6)curve["points"][0]={0,.1};
            if(kind==7)curve["points"][3]={1,.9};
            if(kind==8)curve["points"][1]={true,.1};
            if(kind==9)curve["points"][1]={.1,.2,.3};
            if(kind==10)bad["edits"]["tone"]["s_curve"]=.1;
            if(kind==11)curve["mode"]="legacy";
            if(kind==12)curve["points"][0]={.1,0};
            require(!parseEditRecipe(bad.dump(),recipe,error),"invalid curve rejected "+std::to_string(kind));
            require(serializeEditRecipe(recipe)==saved,"invalid parse retains previous recipe");
        }
        for(int version=1;version<=4;++version) {
            auto old=doc;old["schema_version"]=version;old.erase("processing");
            require(!parseEditRecipe(old.dump(),recipe,error),"old schemas reject custom curve");
        }
        auto channels=doc;
        channels["edits"]["tone"]["curve"]["channels"]={{"red",doc["edits"]["tone"]["curve"]}};
        require(parseEditRecipe(channels.dump(),recipe,error),"independent channel recipe: "+error);
        require(recipe.channelCurves[0].count==4 && recipe.channelCurves[1].mode==SONY2FUJI_CURVE_LEGACY,"channel defaults");
        require(Json::parse(serializeEditRecipe(recipe))["edits"]["tone"]["curve"]["channels"]["red"]==doc["edits"]["tone"]["curve"],"channel recipe roundtrip");
        channels["edits"]["tone"]["curve"]["channels"]["red"]["channels"]=Json::object();
        require(!parseEditRecipe(channels.dump(),recipe,error),"recursive channel rejected");
        doc["edits"]["tone"].erase("curve");
        require(parseEditRecipe(doc.dump(),recipe,error),"absent curve defaults legacy");
        require(recipe.toneCurve.mode==SONY2FUJI_CURVE_LEGACY,"old scalar mode retained");
        require(Json::parse(serializeEditRecipe(recipe))["edits"]["tone"]["curve"]==Json({{"mode","legacy"},{"points",Json::array()}}),
            "v5 normalization emits explicit curve default");
        doc["schema_version"]=4;doc.erase("processing");
        require(parseEditRecipe(doc.dump(),recipe,error),"v4 remains valid");
        require(!Json::parse(serializeEditRecipe(recipe))["edits"]["tone"].contains("curve"),"v4 serialization stays unchanged");

        Json v17={{"schema_version",17},{"processing",{{"family","rawlab"},{"version",3},{"quality","standard"}}},
            {"input",{{"path","input.dng"}}},{"edits",{{"exposure",{{"mode","sensor"}}},{"tone",{{"curve",{
                {"mode","custom"},
                {"points",{{0.15,0.12},{0.5,0.52},{0.85,0.88}}},
                {"apply_to_luminosity",true},
                {"parametric",{{"shadows",25},{"darks",-15},{"lights",10},{"highlights",-20},
                    {"split_shadow",0.20},{"split_midtone",0.48},{"split_highlight",0.78}}},
                {"channels",{{"red",{{"mode","custom"},{"points",{{0.1,0.05},{0.9,0.95}}}}}}}
            }}}}}},
            {"output",{{"path","output.png"},{"format","png"}}}};
        require(parseEditRecipe(v17.dump(),recipe,error),"v17 v2 tone curve accepted: "+error);
        require(recipe.curveApplyToLuminosity,"v17 apply_to_luminosity parsed");
        require(recipe.parametricCurve.shadows==25 && recipe.parametricCurve.split_shadow==0.20f,"v17 parametric parsed");
        require(recipe.toneCurve.points[0].x==0.15 && recipe.toneCurve.points[0].y==0.12 &&
                recipe.toneCurve.points[2].x==0.85 && recipe.toneCurve.points[2].y==0.88,"v17 unpinned master X/Y endpoints parsed");
        require(recipe.channelCurves[0].points[0].x==0.1 && recipe.channelCurves[0].points[0].y==0.05 &&
                recipe.channelCurves[0].points[1].x==0.9 && recipe.channelCurves[0].points[1].y==0.95,"v17 unpinned channel X/Y endpoints parsed");
        const auto savedV17=Json::parse(serializeEditRecipe(recipe));
        require(savedV17["edits"]["tone"]["curve"]["apply_to_luminosity"]==true &&
                savedV17["edits"]["tone"]["curve"]["parametric"]["shadows"]==25 &&
                savedV17["edits"]["tone"]["curve"]["points"][0][0]==0.15 &&
                savedV17["edits"]["tone"]["curve"]["points"][0][1]==0.12,"v17 v2 tone curve roundtrips");

        std::cout<<"Tone curve recipe checks passed\n";return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
