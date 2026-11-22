#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <iostream>

int main() {
    using Json = nlohmann::json;
    Json document = {{"schema_version", 4}, {"input", {{"path", "photo.png"}, {"type", "raster"}}},
        {"edits", {{"exposure", {{"mode", "sensor"}}}, {"white_balance", {{"mode", "none"}}}}},
        {"output", {{"path", "edited.png"}, {"format", "png"}}}};
    sony2fuji::EditRecipe recipe;
    std::string error;
    if (!sony2fuji::parseEditRecipe(document.dump(), recipe, error)) {
        std::cerr << "FAIL raster recipe: " << error << '\n'; return 1;
    }
    if (recipe.toRequest().input_type != static_cast<sony2fuji_input_type>(2)) return 1;
    const auto normalized = sony2fuji::serializeEditRecipe(recipe);
    if (!sony2fuji::parseEditRecipe(normalized, recipe, error) ||
        sony2fuji::serializeEditRecipe(recipe) != normalized) return 1;
    int failures = 0;
    auto reject = [&](const Json& invalid) {
        const auto before = sony2fuji::serializeEditRecipe(recipe);
        if (sony2fuji::parseEditRecipe(invalid.dump(), recipe, error) || error.empty() ||
            sony2fuji::serializeEditRecipe(recipe) != before) ++failures;
    };
    for (const auto& mode : {"camera", "auto", "temperature"}) {
        auto invalid = document;
        invalid["edits"]["white_balance"] = {{"mode", mode}, {"temperature_kelvin", 6500}};
        reject(invalid);
    }
    for (const auto& type : {"guess", "buffer", ""}) {
        auto invalid = document; invalid["input"]["type"] = type; reject(invalid);
    }
    auto invalid = document;
    invalid["edits"]["denoise"]["raw_level"] = 1; reject(invalid);
    invalid = document; invalid["edits"]["lens_correction"]["distortion"] = true; reject(invalid);
    invalid = document; invalid["edits"]["exposure"]["mode"] = "scene"; reject(invalid);
    invalid = document; invalid["schema_version"] = 3; reject(invalid);
    document["edits"].erase("white_balance");
    if (!sony2fuji::parseEditRecipe(document.dump(), recipe, error) ||
        sony2fuji::serializeEditRecipe(recipe).find("none") == std::string::npos) ++failures;
    Json v17Relative = {
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"input", {{"path", "photo.png"}, {"type", "raster"}}},
        {"edits", {{"exposure", {{"mode", "sensor"}}},
                   {"white_balance", {{"mode", "relative"}, {"relative_temperature", 5400}, {"relative_tint", 12}}}}},
        {"output", {{"path", "edited.png"}, {"format", "png"}}}
    };
    sony2fuji::EditRecipe relativeRecipe;
    if (!sony2fuji::parseEditRecipe(v17Relative.dump(), relativeRecipe, error)) {
        std::cerr << "FAIL v17 raster relative recipe: " << error << '\n';
        ++failures;
    } else {
        const auto req = relativeRecipe.toRequest();
        if (req.input_type != SONY2FUJI_INPUT_DISPLAY_BUFFER ||
            req.wb_mode != SONY2FUJI_WB_CAMERA ||
            req.temperature != 6500.0f ||
            req.tint != 0.0f) {
            std::cerr << "FAIL v17 raster relative toRequest must normalize base request to CAMERA 6500/0\n";
            ++failures;
        }
    }
    if (!failures) std::cout << "PASS raster protocol round trip, explicit defaults and RAW-only rejection\n";
    return failures ? 1 : 0;
}
