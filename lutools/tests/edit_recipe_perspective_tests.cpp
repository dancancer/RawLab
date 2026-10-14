#include "sony2fuji/edit_recipe.h"
#include <iostream>
#include <stdexcept>
#include <string>

namespace {
int checks = 0;
void check(bool value, const std::string& message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
std::string document(int version, const std::string& perspective = "") {
    return "{\"schema_version\":" + std::to_string(version) +
        R"(,"input":{"path":"photo.dng"},"edits":{"exposure":{"mode":"preview"},"geometry":{)" +
        (perspective.empty() ? "" : "\"perspective\":" + perspective) +
        R"(}},"output":{"path":"final.png","format":"png"}})";
}
sony2fuji::EditRecipe parse(const std::string& text) {
    sony2fuji::EditRecipe recipe;
    std::string error;
    check(sony2fuji::parseEditRecipe(text, recipe, error), "valid parse: " + error);
    check(error.empty(), "success clears error");
    return recipe;
}
void reject(int version, const std::string& text) {
    auto destination = parse(document(3, R"({"horizontal":0.75,"vertical":-0.5})"));
    destination.geometry.quarter_turns = 3;
    destination.geometry.flip_horizontal = 1;
    destination.geometry.crop_width = .5f;
    const auto before = sony2fuji::serializeEditRecipe(destination);
    std::string error;
    check(!sony2fuji::parseEditRecipe(document(version, text), destination, error), "invalid perspective rejected: " + text);
    check(!error.empty(), "invalid perspective has diagnostic");
    check(sony2fuji::serializeEditRecipe(destination) == before, "invalid parse preserves whole recipe");
}
}
int main() {
    try {
        for (const auto& object : {"", "{}", R"({"horizontal":0,"vertical":0})"}) {
            const auto recipe = parse(document(3, object));
            check(recipe.perspective.horizontal == 0 && recipe.perspective.vertical == 0, "v3 defaults to identity");
            check(recipe.perspective.version == 1 && recipe.perspective.struct_size == 16, "additive perspective config ABI");
            const auto serialized = sony2fuji::serializeEditRecipe(recipe);
            check(serialized.find("perspective") != std::string::npos, "v3 normalization emits perspective defaults");
            const auto restored = parse(serialized);
            check(restored.schemaVersion == 3 && restored.perspective.horizontal == 0 && restored.perspective.vertical == 0,
                  "v3 identity round trip");
        }
        for (const auto& object : {R"({"horizontal":-1,"vertical":1})", R"({"horizontal":1,"vertical":-1})",
                                  R"({"horizontal":0.75})", R"({"vertical":-0.5})"}) {
            const auto recipe = parse(document(3, object));
            const auto restored = parse(sony2fuji::serializeEditRecipe(recipe));
            check(restored.schemaVersion == 3 && restored.perspective.horizontal == recipe.perspective.horizontal &&
                  restored.perspective.vertical == recipe.perspective.vertical, "perspective normalized-unit round trip");
        }
        for (const auto& object : {"null", "[]", "0", "true", R"({"horizontal":-1.01})", R"({"vertical":1.01})",
                                  R"({"horizontal":true})", R"({"vertical":"0"})", R"({"horizontal":null})",
                                  R"({"horizontal":0,"horizontal":1})", R"({"future":0})"}) reject(3, object);
        reject(1, "{}");
        reject(2, "{}");
        const auto old = parse(document(2));
        check(old.perspective.horizontal == 0 && old.perspective.vertical == 0, "v2 perspective stays identity");
        check(sony2fuji::serializeEditRecipe(old).find("perspective") == std::string::npos, "v2 normalized recipe remains compatible");
        std::cout << "PASS " << checks << " perspective recipe compatibility checks\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
