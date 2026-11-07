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
        auto normalized=sony2fuji::serializeEditRecipe(recipe);
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
        invalid=document; invalid["schema_version"]=99; reject(invalid,"schema_version");
        invalid=document; invalid["schema_version"]=5; reject(invalid,"processing.family");
        bool refused=false;
        try { recipe.toRequest(); } catch (const std::invalid_argument&) { refused=true; }
        check(refused,"HDR recipe entered legacy request v2");

        document["schema_version"]=8;
        document["processing"]["version"]=2;
        auto& tone=document["edits"]["tone"];
        tone["black_point"]=-.25;
        tone["white_point"]=.5;
        tone["curve"]={{"mode","custom"},{"points",{{0,0},{.5,.625},{1,1}}}};
        check(sony2fuji::parseEditRecipe(document.dump(),recipe,error),"HDR v8 recipe: "+error);
        normalized=sony2fuji::serializeEditRecipe(recipe);
        check(sony2fuji::parseEditRecipe(normalized,recipe,error),"HDR v8 normalized parse: "+error);
        check(sony2fuji::serializeEditRecipe(recipe)==normalized,"HDR v8 roundtrip changed fields");
        const auto request=recipe.toHDRRenderRequest().base.base.base.base.base;
        check(request.base.hdr_processing_version==2 && request.base.struct_size==sizeof(request) &&
            request.black_point==-25 && request.white_point==50 && request.curve.count==3 &&
            request.curve.points[1].y==.625,"HDR v8 typed request lost tone fields");
        invalid=document; invalid["processing"]["version"]=1; reject(invalid,"processing.version");
        invalid=document; invalid["edits"]["tone"]["white_point"]=1.01; reject(invalid,"white_point");
        invalid=document; invalid["edits"]["tone"]["s_curve"]=.25; reject(invalid,"s_curve");
        invalid=document; invalid["edits"]["tone"]["curve"]["points"][1]={.5,-.25}; reject(invalid,"curve.points");
        refused=false;
        try { recipe.toHDRRequest(); } catch (const std::invalid_argument&) { refused=true; }
        check(refused,"HDR v8 recipe entered the v1 HDR request");
        invalid=document; invalid["edits"]["color"]["vibrance"]=.45; reject(invalid,"color");
        document["schema_version"]=9;
        document["processing"]["version"]=3;
        document["edits"]["color"]["vibrance"]=.45;
        document["edits"]["hsl"]["hue"]={0,20,0,0,0,0,0,0};
        document["edits"]["color_grading"]["highlights"]={{"hue",210},{"saturation",32}};
        check(sony2fuji::parseEditRecipe(document.dump(),recipe,error),"HDR v9 recipe: "+error);
        normalized=sony2fuji::serializeEditRecipe(recipe);
        check(sony2fuji::parseEditRecipe(normalized,recipe,error),"HDR v9 normalized parse: "+error);
        check(sony2fuji::serializeEditRecipe(recipe)==normalized,"HDR v9 roundtrip changed fields");
        const auto color=recipe.toHDRRenderRequest().base.base.base.base;
        check(color.base.base.struct_size==sizeof(color) && color.base.base.hdr_processing_version==3 &&
            color.base.white_point==50 && color.vibrance==45 && color.hsl.hue[1]==20 &&
            color.grading.highlights_hue==210 && color.grading.highlights_saturation==32,"HDR v9 request lost color");
        invalid=document; invalid["edits"]["color"]["vibrance"]=1.01; reject(invalid,"vibrance");
        invalid=document; invalid["edits"]["hsl"]["hue"]={0,1}; reject(invalid,"hue");
        invalid=document; invalid["edits"]["color_grading"]["highlights"]["hue"]=360; reject(invalid,"hue");
        invalid=document; invalid["edits"]["rendition"]["peak_limit_ev"]=2; reject(invalid,"rendition");
        document["schema_version"]=10;
        document["processing"]["version"]=4;
        document["edits"]["rendition"]={{"peak_limit_ev",2.25},{"sdr_exposure_ev",-.5},{"sdr_contrast",.5},{"sdr_saturation",-.25}};
        check(sony2fuji::parseEditRecipe(document.dump(),recipe,error),"HDR v10 recipe: "+error);
        normalized=sony2fuji::serializeEditRecipe(recipe);
        check(sony2fuji::parseEditRecipe(normalized,recipe,error) && sony2fuji::serializeEditRecipe(recipe)==normalized,
            "HDR v10 roundtrip changed fields");
        const auto rendition=recipe.toHDRRenderRequest().base.base.base;
        check(rendition.base.base.base.struct_size==sizeof(rendition) && rendition.base.base.base.hdr_processing_version==4 &&
            rendition.peak_limit_ev==2.25f && rendition.sdr_exposure_ev==-.5f &&
            rendition.sdr_contrast==50 && rendition.sdr_saturation==-25,"HDR v10 request lost rendition settings");
        invalid=document; invalid["edits"]["rendition"]["peak_limit_ev"]=7; reject(invalid,"peak_limit_ev");
        invalid=document; invalid["edits"]["effects"]["grain_amount"]=25; reject(invalid,"effects");
        document["schema_version"]=11;
        document["processing"]["version"]=5;
        document["edits"]["effects"]={{"vignette_amount",-50},{"grain_amount",25},{"grain_size",37}};
        check(sony2fuji::parseEditRecipe(document.dump(),recipe,error),"HDR v11 recipe: "+error);
        normalized=sony2fuji::serializeEditRecipe(recipe);
        check(sony2fuji::parseEditRecipe(normalized,recipe,error) && sony2fuji::serializeEditRecipe(recipe)==normalized,
            "HDR v11 roundtrip changed effects");
        const auto effects=recipe.toHDRRenderRequest().base.base;
        check(effects.base.base.base.base.struct_size==sizeof(effects) && effects.base.base.base.base.hdr_processing_version==5 &&
            effects.effects.vignette_amount==-50 && effects.effects.vignette_midpoint==50 &&
            effects.effects.grain_amount==25 && effects.effects.grain_size==37,"HDR v11 request lost effects");
        invalid=document; invalid["edits"]["effects"]["dehaze"]=.5; reject(invalid,"dehaze");
        invalid=document; invalid["edits"]["detail"]["denoise"]=.65; reject(invalid,"detail");
        document["schema_version"]=12;
        document["processing"]["version"]=6;
        document["edits"]["detail"]={{"sharpening",1.3},{"clarity",-.45},{"dehaze",.5},{"denoise",.65}};
        check(sony2fuji::parseEditRecipe(document.dump(),recipe,error),"HDR v12 recipe: "+error);
        normalized=sony2fuji::serializeEditRecipe(recipe);
        check(sony2fuji::parseEditRecipe(normalized,recipe,error) && sony2fuji::serializeEditRecipe(recipe)==normalized,
            "HDR v12 roundtrip changed detail");
        const auto detail=recipe.toHDRRenderRequest().base;
        check(detail.base.base.base.base.base.struct_size==sizeof(detail) &&
            detail.base.base.base.base.base.hdr_processing_version==6 && detail.sharpening==1.3f &&
            detail.clarity==-.45f && detail.dehaze==.5f && detail.denoise==.65f,"HDR v12 request lost detail settings");
        invalid=document; invalid["edits"]["detail"]["denoise"]=1.01; reject(invalid,"denoise");
        invalid=document; invalid["edits"]["detail"]["wavelet"]=true; reject(invalid,"wavelet");
        invalid=document; invalid["edits"]["look"]["path"]="look.cube"; reject(invalid,"look");
        document["schema_version"]=13;
        document["processing"]["version"]=7;
        const std::string digest(64,'a');
        document["edits"]["look"]={{"path","look.cube"},{"sha256",digest},{"strength",.75}};
        check(sony2fuji::parseEditRecipe(document.dump(),recipe,error),"HDR v13 recipe: "+error);
        normalized=sony2fuji::serializeEditRecipe(recipe);
        check(sony2fuji::parseEditRecipe(normalized,recipe,error) && sony2fuji::serializeEditRecipe(recipe)==normalized,
            "HDR v13 roundtrip changed look identity");
        const auto look=recipe.toHDRRenderRequest();
        check(look.base.base.base.base.base.base.struct_size==sizeof(look) &&
            look.base.base.base.base.base.base.hdr_processing_version==7 && std::string(look.look_path)=="look.cube" &&
            look.look_strength==.75f && look.look_sha256==digest,"HDR v13 request lost look identity");
        invalid=document; invalid["edits"]["look"]["sha256"]="short"; reject(invalid,"sha256");
        invalid=document; invalid["edits"]["look"]["strength"]=2.1; reject(invalid,"strength");
        std::cout<<"PASS HDR v6/v8/v9/v10/v11/v12/v13 roundtrip, strict fields and typed request isolation\n";
        return 0;
    } catch (const std::exception& e) { std::cerr<<"FAIL "<<e.what()<<'\n'; return 1; }
}
