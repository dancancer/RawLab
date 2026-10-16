#include "sony2fuji/edit_recipe.h"
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using sony2fuji::EditRecipe;
size_t checks = 0;

void check(bool condition, const std::string& name) {
    ++checks;
    if (!condition) throw std::runtime_error(name);
}

std::string document(uint32_t version, const std::string& geometry = "") {
    return "{\"schema_version\":" + std::to_string(version) +
        R"(,"input":{"path":"photo.dng"},"edits":{"exposure":{"mode":"scene"})" +
        (geometry.empty() ? "" : ",\"geometry\":" + geometry) +
        R"(},"output":{"path":"result.png","format":"png"}})";
}

EditRecipe parse(const std::string& value) {
    EditRecipe recipe;
    std::string error = "old error";
    check(sony2fuji::parseEditRecipe(value, recipe, error), "valid geometry recipe: " + error);
    check(error.empty(), "valid parse clears error");
    return recipe;
}

bool sameGeometry(const sony2fuji_geometry_config& a, const sony2fuji_geometry_config& b) {
    return a.version == b.version && a.struct_size == b.struct_size && a.crop_x == b.crop_x &&
        a.crop_y == b.crop_y && a.crop_width == b.crop_width && a.crop_height == b.crop_height &&
        a.quarter_turns == b.quarter_turns && a.flip_horizontal == b.flip_horizontal &&
        a.flip_vertical == b.flip_vertical && a.straighten_degrees == b.straighten_degrees;
}

void identity(const EditRecipe& recipe, const std::string& name) {
    const auto& geometry = recipe.geometry;
    check(geometry.version == SONY2FUJI_GEOMETRY_CONFIG_VERSION && geometry.struct_size == sizeof(geometry), name + " valid setter config");
    check(geometry.crop_x == 0 && geometry.crop_y == 0 && geometry.crop_width == 1 && geometry.crop_height == 1 &&
          geometry.quarter_turns == 0 && geometry.flip_horizontal == 0 && geometry.flip_vertical == 0 && geometry.straighten_degrees == 0,
          name + " identity geometry");
}

EditRecipe sentinel() {
    auto recipe = parse(document(2, R"({"crop":{"x":0.125,"y":0.25,"width":0.5,"height":0.5},"quarter_turns":3,"flip_horizontal":true,"flip_vertical":true,"straighten_degrees":-12.5})"));
    recipe.inputPath = "retained-input.dng";
    recipe.outputPath = "retained-output.png";
    recipe.lookPath = "retained-look.cube";
    recipe.exposureMode = SONY2FUJI_EXPOSURE_SENSOR;
    recipe.exposureEv = -2.5f;
    recipe.brightness = 1.25f;
    recipe.whiteBalanceMode = SONY2FUJI_WB_TEMPERATURE;
    recipe.temperatureKelvin = 4500;
    recipe.tint = 20;
    recipe.lookStrength = .75f;
    recipe.jpegQuality = 81;
    recipe.outputLongEdge = 1024;
    return recipe;
}

void reject(const std::string& value, const std::string& name) {
    const auto before = sentinel();
    auto recipe = before;
    const auto serialized = sony2fuji::serializeEditRecipe(before);
    std::string error;
    check(!sony2fuji::parseEditRecipe(value, recipe, error), "reject " + name);
    check(!error.empty(), name + " returns a diagnostic");
    check(recipe.schemaVersion == before.schemaVersion && sameGeometry(recipe.geometry, before.geometry), name + " preserves schema and geometry");
    check(sony2fuji::serializeEditRecipe(recipe) == serialized, name + " preserves every previous recipe field");
}

void defaultsAndVersions() {
    const EditRecipe fresh;
    check(fresh.schemaVersion == 1, "default constructed recipe preserves v1");
    identity(fresh, "fresh recipe");
    for (uint32_t version : {1u, 2u}) {
        const auto recipe = parse(document(version));
        check(recipe.schemaVersion == version, "parsed schema version is retained");
        identity(recipe, "omitted geometry v" + std::to_string(version));
        const auto serialized = sony2fuji::serializeEditRecipe(recipe);
        const auto restored = parse(serialized);
        check(restored.schemaVersion == version && sameGeometry(restored.geometry, recipe.geometry), "schema-preserving identity round trip");
        if (version == 1) check(serialized.find("geometry") == std::string::npos, "v1 serialization does not introduce geometry");
        else for (const char* field : {"geometry", "crop", "x", "y", "width", "height", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten_degrees"})
            check(serialized.find('"' + std::string(field) + '"') != std::string::npos, std::string("v2 serialization emits default ") + field);
        check(recipe.toRequest().version == SONY2FUJI_REQUEST_VERSION, "JSON schema does not change request ABI version");
    }
    identity(parse(document(2, "{}")), "empty v2 geometry");
    identity(parse(document(2, R"({"crop":{"x":0,"y":0,"width":1,"height":1}})")), "explicit v2 crop identity");
    reject(document(1, "{}"), "geometry in v1");
    reject(document(5), "unsupported schema version");
}

void validGeometry() {
    const auto recipe = parse(document(2, R"({"crop":{"x":0.125,"y":0.25,"width":0.5,"height":0.5},"quarter_turns":1,"flip_horizontal":true,"flip_vertical":false,"straighten_degrees":12.5})"));
    const auto& geometry = recipe.geometry;
    check(geometry.crop_x == .125f && geometry.crop_y == .25f && geometry.crop_width == .5f && geometry.crop_height == .5f,
          "normalized crop maps without percent conversion");
    check(geometry.quarter_turns == 1 && geometry.flip_horizontal == 1 && geometry.flip_vertical == 0 && geometry.straighten_degrees == 12.5f,
          "rotation, booleans and clockwise degrees map to setter config");
    const auto restored = parse(sony2fuji::serializeEditRecipe(recipe));
    check(restored.schemaVersion == 2 && sameGeometry(restored.geometry, geometry), "full geometry round trip");
    for (const auto& value : {R"({"quarter_turns":0})", R"({"quarter_turns":3})", R"({"flip_horizontal":false,"flip_vertical":true})",
                            R"({"straighten_degrees":-45})", R"({"straighten_degrees":45})",
                            R"({"crop":{"x":0,"y":0,"width":0.000001,"height":1}})",
                            R"({"crop":{"x":0.6666667,"y":0,"width":0.33333334,"height":1}})",
                            R"({"crop":{"x":0.5,"y":0,"width":0.5000008,"height":1}})"}) {
        const auto parsed = parse(document(2, value));
        check(sameGeometry(parse(sony2fuji::serializeEditRecipe(parsed)).geometry, parsed.geometry), "valid boundary geometry round trip");
    }
}

void invalidGeometry() {
    for (const auto& value : {"null", "[]", "true", "0", R"("geometry")", R"({"perspective":0})", R"({"crop":null})", R"({"crop":[]})",
             R"({"crop":{"x":-0.1,"y":0,"width":1,"height":1}})",
             R"({"crop":{"x":1,"y":0,"width":0.000001,"height":1}})",
             R"({"crop":{"x":0,"y":-0.1,"width":1,"height":1}})",
             R"({"crop":{"x":0,"y":1,"width":1,"height":0.000001}})",
             R"({"crop":{"x":0,"y":0,"width":0,"height":1}})",
             R"({"crop":{"x":0,"y":0,"width":1,"height":0}})",
             R"({"crop":{"x":0,"y":0,"width":-0.1,"height":1}})",
             R"({"crop":{"x":0,"y":0,"width":1.1,"height":1}})",
             R"({"crop":{"x":0,"y":0,"width":1,"height":1.1}})",
             R"({"crop":{"x":0.5,"y":0,"width":0.50001,"height":1}})",
             R"({"crop":{"x":0,"y":0.5,"width":1,"height":0.50001}})",
             R"({"crop":{"x":true,"y":0,"width":1,"height":1}})",
             R"({"crop":{"x":0,"y":"0","width":1,"height":1}})",
             R"({"crop":{"x":0,"y":0,"width":null,"height":1}})",
             R"({"crop":{"x":0,"y":0,"width":1,"height":[],"future":0}})",
             R"({"quarter_turns":-1})", R"({"quarter_turns":4})", R"({"quarter_turns":1.0})", R"({"quarter_turns":true})", R"({"quarter_turns":"1"})",
             R"({"flip_horizontal":1})", R"({"flip_horizontal":null})", R"({"flip_vertical":0})", R"({"flip_vertical":"false"})",
             R"({"straighten_degrees":-45.01})", R"({"straighten_degrees":45.01})", R"({"straighten_degrees":true})", R"({"straighten_degrees":"0"})",
             R"({"quarter_turns":1,"quarter_turns":2})", R"({"crop":{"x":0,"x":0.1,"y":0,"width":0.5,"height":1}})"})
        reject(document(2, value), "invalid geometry " + std::string(value));
    reject(document(2, R"({"straighten_degrees":1e999})"), "non-finite numeric JSON");
}

} // namespace

int main() {
    try {
        defaultsAndVersions();
        validGeometry();
        invalidGeometry();
        std::cout << checks << " geometry recipe compatibility and validation checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
