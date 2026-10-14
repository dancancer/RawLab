#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <set>
#include <stdexcept>
#include <vector>

namespace sony2fuji {
namespace {

using Json = nlohmann::json;

void fields(const Json& object, const std::string& path,
            std::initializer_list<const char*> allowed) {
    if (!object.is_object()) throw std::invalid_argument(path + " must be an object");
    for (const auto& item : object.items()) {
        bool known = false;
        for (const char* key : allowed) known |= item.key() == key;
        if (!known) throw std::invalid_argument(path + "." + item.key() + " is unsupported");
    }
}

const Json& required(const Json& object, const char* key, const std::string& path) {
    if (!object.contains(key)) throw std::invalid_argument(path + "." + key + " is required");
    return object.at(key);
}

std::string text(const Json& value, const std::string& path) {
    if (!value.is_string()) throw std::invalid_argument(path + " must be a string");
    auto result = value.get<std::string>();
    if (result.empty() || result.find('\0') != std::string::npos)
        throw std::invalid_argument(path + " must be nonempty and contain no NUL");
    return result;
}

float number(const Json& object, const char* key, float fallback, double minimum,
             double maximum, const std::string& path) {
    if (!object.contains(key)) return fallback;
    const auto& value = object.at(key);
    if (!value.is_number()) throw std::invalid_argument(path + "." + key + " must be a number");
    const double result = value.get<double>();
    if (!std::isfinite(result) || result < minimum || result > maximum)
        throw std::invalid_argument(path + "." + key + " is out of range");
    return static_cast<float>(result);
}

uint32_t integer(const Json& value, uint32_t minimum, uint32_t maximum, const std::string& path) {
    if (!value.is_number_integer()) throw std::invalid_argument(path + " must be an integer");
    const double result = value.get<double>();
    if (result < minimum || result > maximum) throw std::invalid_argument(path + " is out of range");
    return static_cast<uint32_t>(result);
}

int32_t boolean(const Json& object, const char* key, const std::string& path) {
    if (!object.contains(key)) return 0;
    if (!object.at(key).is_boolean()) throw std::invalid_argument(path + "." + key + " must be a boolean");
    return object.at(key).get<bool>() ? 1 : 0;
}

const char* exposureName(sony2fuji_raw_exposure_mode mode) {
    switch (mode) {
        case SONY2FUJI_EXPOSURE_SCENE: return "scene";
        case SONY2FUJI_EXPOSURE_PREVIEW: return "preview";
        case SONY2FUJI_EXPOSURE_SENSOR: return "sensor";
    }
    throw std::invalid_argument("Invalid exposure mode");
}

const char* formatName(sony2fuji_output_format format) {
    switch (format) {
        case SONY2FUJI_OUTPUT_JPEG: return "jpeg";
        case SONY2FUJI_OUTPUT_PNG: return "png";
        case SONY2FUJI_OUTPUT_DNG: return "dng";
        default: throw std::invalid_argument("Invalid file output format");
    }
}

} // namespace

bool parseEditRecipe(const std::string& document, EditRecipe& recipe, std::string& error) {
    try {
        if (document.size() > 1024 * 1024) throw std::invalid_argument("Recipe exceeds 1 MiB");
        if (document.find('\0') != std::string::npos) throw std::invalid_argument("Recipe contains a literal NUL");
        std::vector<std::set<std::string>> objectKeys;
        auto checkKeys = [&](int depth, Json::parse_event_t event, Json& value) {
            if (depth > 16) throw std::invalid_argument("Recipe nesting exceeds 16 levels");
            if (event == Json::parse_event_t::object_start) objectKeys.emplace_back();
            if (event == Json::parse_event_t::object_end) objectKeys.pop_back();
            if (event == Json::parse_event_t::key && !objectKeys.back().insert(value.get<std::string>()).second)
                throw std::invalid_argument("Duplicate key: " + value.get<std::string>());
            return true;
        };
        const auto root = Json::parse(document, checkKeys);
        fields(root, "recipe", {"schema_version", "input", "edits", "output"});
        const auto version = integer(required(root, "schema_version", "recipe"), 1,
                                     std::numeric_limits<uint32_t>::max(), "schema_version");
        if (version < 1 || version > 3) throw std::invalid_argument("Unsupported schema_version: " + std::to_string(version));

        EditRecipe parsed;
        parsed.schemaVersion = version;
        const auto& input = required(root, "input", "recipe");
        fields(input, "input", {"path"});
        parsed.inputPath = text(required(input, "path", "input"), "input.path");

        const auto& edits = required(root, "edits", "recipe");
        if (version == 1) fields(edits, "edits", {"exposure", "white_balance", "look"});
        else fields(edits, "edits", {"exposure", "white_balance", "look", "geometry"});
        const auto& exposure = required(edits, "exposure", "edits");
        fields(exposure, "edits.exposure", {"mode", "ev", "brightness"});
        const auto mode = text(required(exposure, "mode", "edits.exposure"), "edits.exposure.mode");
        if (mode == "scene") parsed.exposureMode = SONY2FUJI_EXPOSURE_SCENE;
        else if (mode == "preview") parsed.exposureMode = SONY2FUJI_EXPOSURE_PREVIEW;
        else if (mode == "sensor") parsed.exposureMode = SONY2FUJI_EXPOSURE_SENSOR;
        else throw std::invalid_argument("edits.exposure.mode must be scene, preview or sensor");
        parsed.exposureEv = number(exposure, "ev", 0, -20, 20, "edits.exposure");
        parsed.brightness = number(exposure, "brightness", 1, std::numeric_limits<float>::min(),
                                   std::numeric_limits<float>::max(), "edits.exposure");

        if (edits.contains("white_balance")) {
            const auto& wb = edits.at("white_balance");
            fields(wb, "edits.white_balance", {"mode", "temperature_kelvin", "tint"});
            const auto wbMode = text(required(wb, "mode", "edits.white_balance"), "edits.white_balance.mode");
            if (wbMode == "camera") parsed.whiteBalanceMode = SONY2FUJI_WB_CAMERA;
            else if (wbMode == "auto") parsed.whiteBalanceMode = SONY2FUJI_WB_AUTO;
            else if (wbMode == "temperature") {
                parsed.whiteBalanceMode = SONY2FUJI_WB_TEMPERATURE;
                required(wb, "temperature_kelvin", "edits.white_balance");
                parsed.temperatureKelvin = number(wb, "temperature_kelvin", 6500, 2000, 50000, "edits.white_balance");
                parsed.tint = number(wb, "tint", 0, -150, 150, "edits.white_balance");
            } else throw std::invalid_argument("edits.white_balance.mode must be camera, auto or temperature");
            if (wbMode != "temperature" && (wb.contains("temperature_kelvin") || wb.contains("tint")))
                throw std::invalid_argument("Kelvin/tint require edits.white_balance.mode=temperature");
        }

        if (edits.contains("look")) {
            const auto& look = edits.at("look");
            fields(look, "edits.look", {"path", "strength"});
            const auto& path = required(look, "path", "edits.look");
            if (!path.is_null()) parsed.lookPath = text(path, "edits.look.path");
            parsed.lookStrength = number(look, "strength", 1, 0, 1, "edits.look");
        }

        if (edits.contains("geometry")) {
            const auto& geometry = edits.at("geometry");
            const std::string geoPath = "edits.geometry";
            if (version == 2)
                fields(geometry, geoPath, {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten_degrees"});
            else fields(geometry, geoPath, {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten_degrees", "perspective"});
            auto& config = parsed.geometry;
            if (geometry.contains("quarter_turns"))
                config.quarter_turns = integer(geometry.at("quarter_turns"), 0, 3, geoPath + ".quarter_turns");
            config.flip_horizontal = boolean(geometry, "flip_horizontal", geoPath);
            config.flip_vertical = boolean(geometry, "flip_vertical", geoPath);
            config.straighten_degrees = number(geometry, "straighten_degrees", 0, -45, 45, geoPath);
            if (geometry.contains("perspective")) {
                const auto& perspective = geometry.at("perspective");
                const auto perspectivePath = geoPath + ".perspective";
                fields(perspective, perspectivePath, {"horizontal", "vertical"});
                parsed.perspective.horizontal = number(perspective, "horizontal", 0, -1, 1, perspectivePath);
                parsed.perspective.vertical = number(perspective, "vertical", 0, -1, 1, perspectivePath);
            }
            if (geometry.contains("crop")) {
                const auto& crop = geometry.at("crop");
                const std::string cropPath = geoPath + ".crop";
                fields(crop, cropPath, {"x", "y", "width", "height"});
                config.crop_x = number(crop, "x", 0, 0, 1, cropPath);
                config.crop_y = number(crop, "y", 0, 0, 1, cropPath);
                config.crop_width = number(crop, "width", 1, std::numeric_limits<float>::min(), 1, cropPath);
                config.crop_height = number(crop, "height", 1, std::numeric_limits<float>::min(), 1, cropPath);
                if (double(config.crop_x) + config.crop_width > 1 + 1e-6 ||
                    double(config.crop_y) + config.crop_height > 1 + 1e-6 ||
                    config.crop_x >= 1 || config.crop_y >= 1)
                    throw std::invalid_argument(cropPath + " must fit inside the normalized canvas");
                config.crop_width = std::min(config.crop_width, 1 - config.crop_x);
                config.crop_height = std::min(config.crop_height, 1 - config.crop_y);
            }
        }

        const auto& output = required(root, "output", "recipe");
        fields(output, "output", {"path", "format", "jpeg_quality", "size"});
        parsed.outputPath = text(required(output, "path", "output"), "output.path");
        const auto format = text(required(output, "format", "output"), "output.format");
        if (format == "jpeg") parsed.outputFormat = SONY2FUJI_OUTPUT_JPEG;
        else if (format == "png") parsed.outputFormat = SONY2FUJI_OUTPUT_PNG;
        else if (format == "dng") parsed.outputFormat = SONY2FUJI_OUTPUT_DNG;
        else throw std::invalid_argument("output.format must be jpeg, png or dng");
        if (output.contains("jpeg_quality"))
            parsed.jpegQuality = integer(output.at("jpeg_quality"), 1, 100, "output.jpeg_quality");
        if (output.contains("size")) {
            const auto& size = output.at("size");
            fields(size, "output.size", {"mode", "long_edge"});
            const auto sizeMode = text(required(size, "mode", "output.size"), "output.size.mode");
            if (sizeMode == "limit_long_edge")
                parsed.outputLongEdge = integer(required(size, "long_edge", "output.size"), 1,
                    std::numeric_limits<uint32_t>::max(), "output.size.long_edge");
            else if (sizeMode != "native") throw std::invalid_argument("output.size.mode must be native or limit_long_edge");
            else if (size.contains("long_edge")) throw std::invalid_argument("output.size.long_edge requires limit_long_edge mode");
        }
        recipe = std::move(parsed);
        error.clear();
        return true;
    } catch (const Json::exception& exception) {
        error = exception.what();
    } catch (const std::invalid_argument& exception) {
        error = exception.what();
    }
    return false;
}

std::string serializeEditRecipe(const EditRecipe& recipe) {
    if (recipe.schemaVersion < 1 || recipe.schemaVersion > 3)
        throw std::invalid_argument("Unsupported schema_version");
    const char* wbMode = nullptr;
    switch (recipe.whiteBalanceMode) {
        case SONY2FUJI_WB_CAMERA: wbMode = "camera"; break;
        case SONY2FUJI_WB_AUTO: wbMode = "auto"; break;
        case SONY2FUJI_WB_TEMPERATURE: wbMode = "temperature"; break;
        default: throw std::invalid_argument("Invalid white balance mode");
    }
    Json wb = {{"mode", wbMode}};
    if (recipe.whiteBalanceMode == SONY2FUJI_WB_TEMPERATURE) {
        wb["temperature_kelvin"] = recipe.temperatureKelvin;
        wb["tint"] = recipe.tint;
    }
    Json size = {{"mode", "native"}};
    if (recipe.outputLongEdge) size = {{"mode", "limit_long_edge"}, {"long_edge", recipe.outputLongEdge}};
    Json document = {{"schema_version", recipe.schemaVersion}, {"input", {{"path", recipe.inputPath}}},
        {"edits", {{"exposure", {{"mode", exposureName(recipe.exposureMode)}, {"ev", recipe.exposureEv},
                                 {"brightness", recipe.brightness}}},
                   {"white_balance", wb},
                   {"look", {{"path", recipe.lookPath.empty() ? Json(nullptr) : Json(recipe.lookPath)},
                             {"strength", recipe.lookStrength}}}}},
        {"output", {{"path", recipe.outputPath}, {"format", formatName(recipe.outputFormat)},
                    {"jpeg_quality", recipe.jpegQuality}, {"size", size}}}};
    if (recipe.schemaVersion >= 2) {
        const auto& geo = recipe.geometry;
        document["edits"]["geometry"] = {{"crop", {{"x", geo.crop_x}, {"y", geo.crop_y},
            {"width", geo.crop_width}, {"height", geo.crop_height}}}, {"quarter_turns", geo.quarter_turns},
            {"flip_horizontal", geo.flip_horizontal != 0}, {"flip_vertical", geo.flip_vertical != 0},
            {"straighten_degrees", geo.straighten_degrees}};
        if (recipe.schemaVersion == 3)
            document["edits"]["geometry"]["perspective"] = {{"horizontal", recipe.perspective.horizontal},
                {"vertical", recipe.perspective.vertical}};
    }
    return document.dump(2) + "\n";
}

sony2fuji_request EditRecipe::toRequest() const {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = inputPath.c_str();
    request.lut_path = lookPath.empty() ? nullptr : lookPath.c_str();
    request.lut_strength = lookStrength;
    request.wb_mode = whiteBalanceMode;
    request.exposure_ev = exposureEv;
    request.brightness = brightness;
    request.contrast = request.saturation = 1;
    request.temperature = temperatureKelvin;
    request.tint = tint;
    request.size_mode = outputLongEdge ? SONY2FUJI_SIZE_LIMIT_LONG_EDGE : SONY2FUJI_SIZE_NATIVE;
    request.long_edge = outputLongEdge;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.output_target = SONY2FUJI_TARGET_FILE;
    request.output_path = outputPath.c_str();
    request.output_format = outputFormat;
    request.jpeg_quality = jpegQuality;
    return request;
}

} // namespace sony2fuji
