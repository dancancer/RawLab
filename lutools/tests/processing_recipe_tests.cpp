#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <iostream>
#include <stdexcept>
#include <vector>

using namespace sony2fuji;
using Json = nlohmann::json;

static void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

int main() {
    try {
        Json document = {{"schema_version", 5}, {"processing", {{"family", "rawlab"}, {"version", 2}, {"quality", "standard"}}},
            {"input", {{"path", "input.dng"}}}, {"edits", {{"exposure", {{"mode", "sensor"}}}}},
            {"output", {{"path", "output.png"}, {"format", "png"}}}};
        EditRecipe recipe;
        std::string error;
        require(parseEditRecipe(document.dump(), recipe, error), "v5 processing recipe: " + error);
        require(Json::parse(serializeEditRecipe(recipe)).at("processing") == document.at("processing"),
                "processing identity survives normalization");
        require(recipe.processingVersion == SONY2FUJI_PROCESSING_C5_V2, "v5 selects current core");
        const auto unchanged = serializeEditRecipe(recipe);
        for (const Json& invalid : std::vector<Json>{nullptr, Json::array(), 2,
                 {{"family", "other"}, {"version", 1}, {"quality", "standard"}},
                 {{"family", "rawlab"}, {"version", 0}, {"quality", "standard"}},
                 {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}},
                 {{"family", "rawlab"}, {"version", true}, {"quality", "standard"}},
                 {{"family", "rawlab"}, {"version", 1.0}, {"quality", "standard"}},
                 {{"family", "rawlab"}, {"version", 1}, {"quality", "fast"}},
                 {{"family", "rawlab"}, {"version", 1}},
                 {{"family", "rawlab"}, {"version", 1}, {"quality", "standard"}, {"extra", 0}}}) {
            auto bad = document;
            bad["processing"] = invalid;
            require(!parseEditRecipe(bad.dump(), recipe, error) && !error.empty(), "unsupported processing rejected");
            require(serializeEditRecipe(recipe) == unchanged, "invalid processing preserves destination");
        }
        auto missing = document;
        missing.erase("processing");
        require(!parseEditRecipe(missing.dump(), recipe, error), "v5 requires processing");
        for (uint32_t version = 1; version <= 4; ++version) {
            auto old = missing;
            old["schema_version"] = version;
            require(parseEditRecipe(old.dump(), recipe, error), "old schema accepted");
            require(recipe.processingVersion == SONY2FUJI_PROCESSING_LEGACY &&
                    !Json::parse(serializeEditRecipe(recipe)).contains("processing"), "old schema remains legacy");
            old["processing"] = document.at("processing");
            require(!parseEditRecipe(old.dump(), recipe, error), "old schema rejects new field");
            recipe.processingVersion = SONY2FUJI_PROCESSING_C5_V2;
            bool rejected = false;
            try { serializeEditRecipe(recipe); } catch (const std::invalid_argument&) { rejected = true; }
            require(rejected, "old schema cannot silently discard current processing");
        }
        document["processing"]["version"] = 1;
        require(parseEditRecipe(document.dump(), recipe, error) &&
                recipe.processingVersion == SONY2FUJI_PROCESSING_LEGACY, "v5 can explicitly preserve legacy");
        recipe.processingVersion = static_cast<sony2fuji_processing_version>(99);
        bool rejected = false;
        try { serializeEditRecipe(recipe); } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "serializer rejects unsupported processing");
        std::cout << "Processing recipe checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
