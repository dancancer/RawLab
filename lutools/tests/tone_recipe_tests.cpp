#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;
using Json = nlohmann::json;

static void require(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}

int main() {
    try {
        Json document = {{"schema_version", 5},
            {"processing", {{"family", "rawlab"}, {"version", 2}, {"quality", "standard"}}},
            {"input", {{"path", "input.dng"}}},
            {"edits", {{"exposure", {{"mode", "sensor"}}}, {"tone", {{"black_point", .3}, {"white_point", -.4}}},
                       {"color", {{"vibrance", .65}}}}},
            {"output", {{"path", "output.png"}, {"format", "png"}}}};
        EditRecipe recipe;
        std::string error;
        const bool parsed = parseEditRecipe(document.dump(), recipe, error);
        require(parsed, "v5 tone controls accepted: " + error);
        const auto normalized = Json::parse(serializeEditRecipe(recipe));
        require(std::abs(normalized["edits"]["tone"]["black_point"].get<double>() - .3) < 1e-6 &&
                std::abs(normalized["edits"]["tone"]["white_point"].get<double>() + .4) < 1e-6 &&
                std::abs(normalized["edits"]["color"]["vibrance"].get<double>() - .65) < 1e-6,
                "normalization preserves all tone controls");
        require(normalized["processing"] == document["processing"], "processing identity preserved");
        const auto saved = serializeEditRecipe(recipe);
        for (const auto& group : {"tone", "color"}) {
            const auto field = std::string(group) == "tone" ? "black_point" : "vibrance";
            for (const auto& value : {Json(-1.01), Json(1.01), Json(true), Json("0"), Json(nullptr)}) {
                auto invalid = document;
                invalid["edits"][group][field] = value;
                require(!parseEditRecipe(invalid.dump(), recipe, error), "invalid tone value rejected");
                require(serializeEditRecipe(recipe) == saved, "failed parsing preserves destination");
            }
        }
        for (int version = 1; version <= 4; ++version) {
            auto old = document;
            old["schema_version"] = version;
            old.erase("processing");
            require(!parseEditRecipe(old.dump(), recipe, error), "old versions reject new fields");
        }
        auto oldV5 = document;
        oldV5["edits"] = {{"exposure", {{"mode", "sensor"}}}};
        require(parseEditRecipe(oldV5.dump(), recipe, error), "existing v5 recipe stays valid");
        require(!Json::parse(serializeEditRecipe(recipe))["edits"]["tone"].contains("black_point") &&
                !Json::parse(serializeEditRecipe(recipe))["edits"].contains("color"),
                "zero controls preserve existing normalized recipe shape");
        std::cout << "Tone recipe checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
