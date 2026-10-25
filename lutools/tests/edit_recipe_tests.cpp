#include "sony2fuji/edit_recipe.h"
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using sony2fuji::EditRecipe;
int failures = 0;
int checks = 0;

void check(bool condition, const std::string& message) {
    ++checks;
    if (!condition) {
        ++failures;
        std::cerr << "FAIL: " << message << '\n';
    }
}

std::string document(const std::string& exposure = R"({"mode":"scene"})",
                     const std::string& edits = "", const std::string& output = "",
                     const std::string& format = "jpeg") {
    return R"({"schema_version":1,"input":{"path":"in.ARW"},"edits":{"exposure":)" +
        exposure + edits + R"(},"output":{"path":"out.jpg","format":")" + format + '"' + output + "}}";
}

std::string replaceOnce(std::string value, const std::string& from, const std::string& to) {
    const auto position = value.find(from);
    if (position == std::string::npos) throw std::runtime_error("Missing test fixture token: " + from);
    value.replace(position, from.size(), to);
    return value;
}

EditRecipe parse(const std::string& value) {
    EditRecipe result;
    std::string error = "previous error";
    if (!sony2fuji::parseEditRecipe(value, result, error))
        throw std::runtime_error("Valid fixture rejected: " + error);
    check(error.empty(), "successful parse clears previous error");
    return result;
}

bool sameRecipe(const EditRecipe& a, const EditRecipe& b) {
    return sony2fuji::serializeEditRecipe(a) == sony2fuji::serializeEditRecipe(b);
}

EditRecipe sentinel() {
    EditRecipe value;
    value.schemaVersion = 4;
    value.inputPath = "kept-input.DNG";
    value.outputPath = "kept-output.png";
    value.lookPath = "kept-look.rlook";
    value.exposureMode = SONY2FUJI_EXPOSURE_SENSOR;
    value.exposureEv = -2.5f;
    value.brightness = 1.25f;
    value.whiteBalanceMode = SONY2FUJI_WB_TEMPERATURE;
    value.temperatureKelvin = 4200;
    value.tint = 18;
    value.lookStrength = .75f;
    value.outputFormat = SONY2FUJI_OUTPUT_PNG;
    value.jpegQuality = 81;
    value.outputLongEdge = 1200;
    value.contrast = 1.4f;
    value.effects.grain_amount = 23;
    value.hsl.hue[3] = -15;
    value.wavelet.enabled = 1;
    value.lensProfileId = "kept-profile";
    return value;
}

void reject(const std::string& value, const std::string& label, const std::string& field = "") {
    const auto original = sentinel();
    auto destination = original;
    std::string error;
    check(!sony2fuji::parseEditRecipe(value, destination, error), "reject " + label);
    check(!error.empty(), "error returned for " + label);
    if (!field.empty()) check(error.find(field) != std::string::npos, "error identifies " + field + " for " + label);
    check(sameRecipe(destination, original), "invalid " + label + " leaves destination unchanged");
}

void defaultsAndExposure() {
    check(EditRecipe().exposureMode == SONY2FUJI_EXPOSURE_PREVIEW, "new recipes use the native-client preview default");
    auto result = sentinel();
    std::string error;
    check(sony2fuji::parseEditRecipe(document(), result, error), "minimal explicit scene recipe parses");
    check(result.inputPath == "in.ARW" && result.outputPath == "out.jpg" && result.lookPath.empty(), "default paths and look bypass");
    check(result.exposureEv == 0 && result.brightness == 1, "default EV and linear brightness");
    check(result.whiteBalanceMode == SONY2FUJI_WB_CAMERA && result.temperatureKelvin == 6500 && result.tint == 0, "default camera WB");
    check(result.lookStrength == 1 && result.outputFormat == SONY2FUJI_OUTPUT_JPEG && result.jpegQuality == 95 && result.outputLongEdge == 0,
          "default look strength, JPEG quality and native size replace previous destination values");
    for (const auto& entry : std::vector<std::pair<std::string, sony2fuji_raw_exposure_mode>>{
             {"scene", SONY2FUJI_EXPOSURE_SCENE}, {"preview", SONY2FUJI_EXPOSURE_PREVIEW}, {"sensor", SONY2FUJI_EXPOSURE_SENSOR}}) {
        const auto value = parse(document("{\"mode\":\"" + entry.first + "\",\"ev\":1.5,\"brightness\":0.5}"));
        check(value.exposureMode == entry.second && value.exposureEv == 1.5f && value.brightness == .5f, "explicit " + entry.first + " exposure");
        check(sameRecipe(parse(sony2fuji::serializeEditRecipe(value)), value), entry.first + " exposure round trip");
    }
    check(parse(document(R"({"mode":"scene","ev":-20})")).exposureEv == -20, "minimum C API EV");
    check(parse(document(R"({"mode":"scene","ev":20})")).exposureEv == 20, "maximum C API EV");
    reject(document("{}"), "missing exposure mode", "edits.exposure.mode");
    reject(replaceOnce(document(), R"("exposure":{"mode":"scene"})", ""), "missing exposure object", "edits.exposure");
}

void whiteBalanceAndLook() {
    for (const auto& entry : std::vector<std::pair<std::string, sony2fuji_wb_mode>>{
             {"camera", SONY2FUJI_WB_CAMERA}, {"auto", SONY2FUJI_WB_AUTO}}) {
        const auto value = parse(document(R"({"mode":"preview"})", ",\"white_balance\":{\"mode\":\"" + entry.first + "\"}"));
        check(value.whiteBalanceMode == entry.second && value.toRequest().wb_mode == entry.second, entry.first + " WB maps to request");
        check(sameRecipe(parse(sony2fuji::serializeEditRecipe(value)), value), entry.first + " WB round trip");
    }
    const auto warm = parse(document(R"({"mode":"preview"})",
        R"(,"white_balance":{"mode":"temperature","temperature_kelvin":4200,"tint":-18})"));
    const auto request = warm.toRequest();
    check(warm.whiteBalanceMode == SONY2FUJI_WB_TEMPERATURE && request.wb_mode == SONY2FUJI_WB_TEMPERATURE &&
          request.temperature == 4200 && request.tint == -18, "absolute Kelvin/tint maps without UI percentage conversion");
    check(sameRecipe(parse(sony2fuji::serializeEditRecipe(warm)), warm), "temperature WB round trip");
    check(parse(document(R"({"mode":"sensor"})", R"(,"white_balance":{"mode":"temperature","temperature_kelvin":2000})")).tint == 0,
          "temperature WB omitted tint defaults to zero");
    for (const auto& wb : {R"(,"white_balance":{"mode":"temperature","temperature_kelvin":2000,"tint":-150})",
                          R"(,"white_balance":{"mode":"temperature","temperature_kelvin":50000,"tint":150})"})
        parse(document(R"({"mode":"scene"})", wb));
    for (const auto& strength : {"0", "0.5", "1"}) {
        const auto value = parse(document(R"({"mode":"scene"})", std::string(R"(,"look":{"path":"look.cube","strength":)") + strength + "}"));
        check(value.lookPath == "look.cube" && value.toRequest().lut_strength == value.lookStrength, "look path and factor strength map");
        check(sameRecipe(parse(sony2fuji::serializeEditRecipe(value)), value), "look strength " + std::string(strength) + " round trip");
    }
    const auto bypass = parse(document(R"({"mode":"scene"})", R"(,"look":{"path":null})"));
    check(bypass.lookPath.empty() && bypass.toRequest().lut_path == nullptr, "explicit null look bypasses LUT");
}

void outputAndRoundTrip() {
    for (const auto& entry : std::vector<std::pair<std::string, sony2fuji_output_format>>{
             {"jpeg", SONY2FUJI_OUTPUT_JPEG}, {"png", SONY2FUJI_OUTPUT_PNG}, {"dng", SONY2FUJI_OUTPUT_DNG}}) {
        const auto value = parse(document(R"({"mode":"scene"})", "", "", entry.first));
        const auto request = value.toRequest();
        check(request.output_format == entry.second && request.intent == SONY2FUJI_INTENT_FINAL, "explicit " + entry.first + " format wins over .jpg extension");
        check(sameRecipe(parse(sony2fuji::serializeEditRecipe(value)), value), entry.first + " output round trip");
    }
    for (const auto& quality : {"1", "100"})
        check(parse(document(R"({"mode":"scene"})", "", ",\"jpeg_quality\":" + std::string(quality))).jpegQuality == std::stoul(quality), "JPEG quality boundary " + std::string(quality));
    const auto native = parse(document(R"({"mode":"scene"})", "", R"(,"size":{"mode":"native"})"));
    check(native.outputLongEdge == 0 && native.toRequest().size_mode == SONY2FUJI_SIZE_NATIVE, "native size does not request a resize");
    for (const auto& edge : {"1", "2048", "4294967295"}) {
        const auto value = parse(document(R"({"mode":"scene"})", "", std::string(R"(,"size":{"mode":"limit_long_edge","long_edge":)") + edge + "}"));
        const auto request = value.toRequest();
        check(request.size_mode == SONY2FUJI_SIZE_LIMIT_LONG_EDGE && request.long_edge == std::stoull(edge) && request.preview_long_edge == 0,
              "no-upscale final long-edge ceiling " + std::string(edge));
        check(sameRecipe(parse(sony2fuji::serializeEditRecipe(value)), value), "long-edge " + std::string(edge) + " round trip");
    }
    const auto complete = parse(document(R"({"mode":"sensor","ev":-2.5,"brightness":1.25})",
        R"(,"white_balance":{"mode":"temperature","temperature_kelvin":4200,"tint":18},"look":{"path":"look.rlook","strength":0.75})",
        R"(,"jpeg_quality":81,"size":{"mode":"limit_long_edge","long_edge":1200})", "png"));
    const auto serialized = sony2fuji::serializeEditRecipe(complete);
    check(sameRecipe(parse(serialized), complete), "all supported parameters round trip together");
    check(sony2fuji::serializeEditRecipe(parse(serialized)) == serialized, "normalization is stable");
    check(serialized.find("schema_version") != std::string::npos && serialized.find("white_balance") != std::string::npos &&
          serialized.find("brightness") != std::string::npos && serialized.find("jpeg_quality") != std::string::npos, "serialization emits version and defaults");
}

void legacyRequestParity() {
    const auto recipe = parse(document(R"({"mode":"scene","ev":0.75,"brightness":1.2})", R"(,"look":{"path":"film.cube"})", R"(,"jpeg_quality":98)"));
    const auto actual = recipe.toRequest();
    // These are the legacy CLI's defaults and assignments, independent of toRequest.
    sony2fuji_request legacy{};
    legacy.version = SONY2FUJI_REQUEST_VERSION;
    legacy.struct_size = sizeof(legacy);
    legacy.input_type = SONY2FUJI_INPUT_RAW;
    legacy.input_path = "in.ARW";
    legacy.lut_path = "film.cube";
    legacy.lut_strength = 1;
    legacy.wb_mode = SONY2FUJI_WB_CAMERA;
    legacy.exposure_ev = .75f;
    legacy.brightness = 1.2f;
    legacy.contrast = legacy.saturation = 1;
    legacy.temperature = 6500;
    legacy.size_mode = SONY2FUJI_SIZE_NATIVE;
    legacy.intent = SONY2FUJI_INTENT_FINAL;
    legacy.output_target = SONY2FUJI_TARGET_FILE;
    legacy.output_path = "out.jpg";
    legacy.output_format = SONY2FUJI_OUTPUT_JPEG;
    legacy.jpeg_quality = 98;
    check(actual.version == legacy.version && actual.struct_size == legacy.struct_size && actual.input_type == legacy.input_type,
          "legacy request version, ABI layout and RAW input");
    check(std::string(actual.input_path) == legacy.input_path && std::string(actual.lut_path) == legacy.lut_path &&
          std::string(actual.output_path) == legacy.output_path, "legacy input/look/output paths");
    check(actual.lut_strength == legacy.lut_strength && actual.wb_mode == legacy.wb_mode && actual.exposure_ev == legacy.exposure_ev &&
          actual.brightness == legacy.brightness && actual.contrast == legacy.contrast && actual.saturation == legacy.saturation &&
          actual.temperature == legacy.temperature && actual.tint == legacy.tint, "legacy exposure and neutral color defaults");
    check(actual.highlights == 0 && actual.shadows == 0 && actual.tone_curve == 0 && actual.noise_reduction == 0 && actual.sharpening == 0,
          "unexposed legacy adjustment parameters remain neutral");
    check(actual.size_mode == legacy.size_mode && actual.target_width == 0 && actual.target_height == 0 && actual.long_edge == 0 &&
          actual.short_edge == 0 && actual.preview_long_edge == 0 && actual.intent == legacy.intent, "legacy native-size final intent");
    check(actual.output_target == legacy.output_target && actual.output_format == legacy.output_format && actual.jpeg_quality == legacy.jpeg_quality,
          "legacy file format and JPEG quality");
    check(actual.input_pixels == nullptr && actual.input_width == 0 && actual.input_height == 0 && actual.input_is_linear == 0 &&
          actual.input_pixel_format == legacy.input_pixel_format && actual.input_color_space == legacy.input_color_space,
          "legacy zero-initialized unused raster input fields");
    for (int channel = 0; channel < 4; ++channel)
        check(actual.wb_mul[channel] == legacy.wb_mul[channel], "legacy unused WB multiplier " + std::to_string(channel));
}

void completeEdits() {
    auto v4 = [](const std::string& edits) {
        return replaceOnce(document(R"({"mode":"scene"})", edits), "\"schema_version\":1", "\"schema_version\":4");
    };
    const auto complete = v4(R"(,"tone":{"contrast":1.2,"saturation":0.7,"highlights":-0.4,"shadows":0.3,"s_curve":0.5},"detail":{"sharpening":0.6},"hsl":{"hue":[1,2,3,4,5,6,7,8],"saturation":[-100,0,0,0,0,0,0,100],"lightness":[8,7,6,5,4,3,2,1]},"effects":{"vignette_amount":-35,"vignette_midpoint":60,"vignette_roundness":-20,"vignette_feather":70,"vignette_highlights":15,"grain_amount":25,"grain_size":30,"grain_roughness":45},"denoise":{"raw_level":1,"chroma_mode":2,"wavelet":{"enabled":true,"luma":15,"chroma":46,"coarse":50}},"lens_correction":{"distortion":true,"tca":true,"auto_crop":false,"profile_id":"test-profile"})");
    const auto recipe = parse(complete);
    const auto request = recipe.toRequest();
    check(request.contrast == 1.2f && request.saturation == .7f && request.highlights == -.4f &&
          request.shadows == .3f && request.tone_curve == .5f && request.sharpening == .6f,
          "v4 maps effective tone/detail values without UI percentage/sign or master-strength conversion");
    const auto normalized = sony2fuji::serializeEditRecipe(recipe);
    check(sony2fuji::serializeEditRecipe(parse(normalized)) == normalized, "all v4 parameters round trip stably");
    check(normalized.find("test-profile") != std::string::npos && normalized.find("grain_roughness") != std::string::npos &&
          normalized.find("raw_level") != std::string::npos, "v4 normalization preserves session controls");
    const auto defaults = sony2fuji::serializeEditRecipe(parse(v4("")));
    check(defaults.find("wavelet") != std::string::npos && defaults.find("hsl") != std::string::npos &&
          defaults.find("auto_crop") != std::string::npos, "v4 emits all explicit defaults");
    for (const auto& edit : {R"(,"tone":{"contrast":-0.01})", R"(,"tone":{"saturation":2.01})",
             R"(,"tone":{"highlights":1.01})", R"(,"tone":{"shadows":-1.01})", R"(,"tone":{"s_curve":1.01})",
             R"(,"detail":{"sharpening":-0.1})", R"(,"detail":{"sharpening":2.1})",
             R"(,"hsl":{"hue":[0]})", R"(,"hsl":{"hue":[101,0,0,0,0,0,0,0]})",
             R"(,"hsl":{"hue":[0,0,0,0,0,0,0,true]})", R"(,"hsl":{"unknown":[]})",
             R"(,"effects":{"grain_size":101})", R"(,"effects":{"vignette_roundness":-101})",
             R"(,"effects":{"grain_amount":1e999})", R"(,"effects":{"vignette_amount":null})",
             R"(,"denoise":{"raw_level":3})", R"(,"denoise":{"raw_level":1.0})", R"(,"denoise":{"chroma_mode":-1})",
             R"(,"denoise":{"ai":{"enabled":true}})",
             R"(,"denoise":{"wavelet":{"enabled":1}})", R"(,"denoise":{"wavelet":{"luma":101}})",
             R"(,"denoise":{"wavelet":{"coarse":-1}})", R"(,"lens_correction":{"tca":0})",
             R"(,"lens_correction":{"profile_id":""})", R"(,"tone":{"contrast":1,"contrast":2})"})
        reject(v4(edit), "v4 invalid/unknown/duplicate control");
    for (int version = 1; version <= 3; ++version)
        reject(replaceOnce(v4(R"(,"tone":{})"), "\"schema_version\":4", "\"schema_version\":" + std::to_string(version)),
               "old versions reject new controls", "edits.tone");
    parse(v4(R"(,"tone":{"contrast":0,"saturation":2,"highlights":-1,"shadows":1,"s_curve":-1},"detail":{"sharpening":2},"hsl":{"hue":[-100,100,0,0,0,0,0,0]},"look":{"path":null,"strength":2})"));
}


void invalidFields() {
    const auto minimal = document();
    for (const auto& entry : std::vector<std::pair<std::string, std::string>>{
             {replaceOnce(minimal, R"("schema_version":1,)", ""), "schema_version"},
             {replaceOnce(minimal, R"("input":{"path":"in.ARW"},)", ""), "recipe.input"},
             {replaceOnce(minimal, R"("edits":{"exposure":{"mode":"scene"}},)", ""), "recipe.edits"},
             {replaceOnce(minimal, R"("output":{"path":"out.jpg","format":"jpeg"})", R"("output":{})"), "output.path"},
             {replaceOnce(minimal, R"("format":"jpeg")", R"("format":null)"), "output.format"},
             {replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":6)"), "schema_version"},
             {replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":0)"), "schema_version"},
             {replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":1.0)"), "schema_version"},
             {replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":"1")"), "schema_version"},
             {replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":true)"), "schema_version"},
             {replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":4294967296)"), "schema_version"},
             {replaceOnce(minimal, R"("path":"in.ARW")", R"("path":"")"), "input.path"},
             {replaceOnce(minimal, R"("path":"in.ARW")", R"("path":7)"), "input.path"},
             {replaceOnce(minimal, R"("path":"out.jpg")", R"("path":false)"), "output.path"},
             {replaceOnce(minimal, R"("path":"out.jpg")", R"("path":"")"), "output.path"},
             {replaceOnce(minimal, R"("input":{"path":"in.ARW"})", R"("input":[])"), "input"},
             {replaceOnce(minimal, R"("edits":{"exposure":{"mode":"scene"}})", R"("edits":null)"), "edits"},
             {replaceOnce(minimal, R"("output":{"path":"out.jpg","format":"jpeg"})", R"("output":[])"), "output"}})
        reject(entry.first, entry.second + " required/type/range", entry.second);
    for (const auto& exposure : {R"({"mode":"automatic"})", R"({"mode":0})", R"({"mode":null})", R"({"mode":""})", "[]"})
        reject(document(exposure), "invalid exposure mode or object", "edits.exposure");
    for (const auto& ev : {"-20.01", "20.01", "true", "null", "\"1\"", "[]", "{}"})
        reject(document(std::string(R"({"mode":"scene","ev":)") + ev + "}"), "invalid EV " + std::string(ev), "edits.exposure.ev");
    for (const auto& brightness : {"0", "-1", "1e39", "1e-40", "false", "null", "\"1\""})
        reject(document(std::string(R"({"mode":"scene","brightness":)") + brightness + "}"), "invalid brightness " + std::string(brightness), "edits.exposure.brightness");
    for (const auto& wb : {R"({})", R"({"mode":"custom"})", R"({"mode":"temperature"})", R"({"mode":"camera","tint":0})",
                          R"({"mode":"auto","temperature_kelvin":6500})", R"({"mode":"temperature","temperature_kelvin":1999})",
                          R"({"mode":"temperature","temperature_kelvin":50001})", R"({"mode":"temperature","temperature_kelvin":true})",
                          R"({"mode":"temperature","temperature_kelvin":6500,"tint":151})", R"({"mode":"temperature","temperature_kelvin":6500,"tint":-151})"})
        reject(document(R"({"mode":"scene"})", ",\"white_balance\":" + std::string(wb)), "invalid WB " + std::string(wb));
    for (const auto& look : {R"({})", R"({"path":""})", R"({"path":true})", R"({"path":"film.cube","strength":-0.1})",
                            R"({"path":"film.cube","strength":1.1})", R"({"path":"film.cube","strength":"1"})", "[]"})
        reject(document(R"({"mode":"scene"})", ",\"look\":" + std::string(look)), "invalid look " + std::string(look), "edits.look");
    for (const auto& format : {"jpg", "tiff", "JPEG", "rgba8"})
        reject(document(R"({"mode":"scene"})", "", "", format), "unsupported output " + std::string(format), "output.format");
    for (const auto& quality : {"0", "101", "95.0", "-1", "true", "null", "\"95\""})
        reject(document(R"({"mode":"scene"})", "", ",\"jpeg_quality\":" + std::string(quality)), "invalid quality " + std::string(quality), "output.jpeg_quality");
    for (const auto& size : {R"({})", R"({"mode":"fit_long_edge","long_edge":100})", R"({"mode":"native","long_edge":100})",
                            R"({"mode":"limit_long_edge"})", R"({"mode":"limit_long_edge","long_edge":0})",
                            R"({"mode":"limit_long_edge","long_edge":-1})", R"({"mode":"limit_long_edge","long_edge":4294967296})",
                            R"({"mode":"limit_long_edge","long_edge":100.0})", R"({"mode":"limit_long_edge","long_edge":true})", "[]"})
        reject(document(R"({"mode":"scene"})", "", ",\"size\":" + std::string(size)), "invalid size " + std::string(size), "output.size");
}

void unknownAndDuplicateKeys() {
    const auto minimal = document();
    for (const auto& entry : std::vector<std::pair<std::string, std::string>>{
             {replaceOnce(minimal, "{", R"({"future":true,)"), "recipe.future"},
             {replaceOnce(minimal, R"("path":"in.ARW")", R"("path":"in.ARW","width":10)"), "input.width"},
             {document(R"({"mode":"scene"})", R"(,"crop":{})"), "edits.crop"},
             {document(R"({"mode":"scene","unit":"EV"})"), "edits.exposure.unit"},
             {document(R"({"mode":"scene"})", R"(,"white_balance":{"mode":"camera","future":0})"), "edits.white_balance.future"},
             {document(R"({"mode":"scene"})", R"(,"look":{"path":null,"future":0})"), "edits.look.future"},
             {document(R"({"mode":"scene"})", "", R"(,"future":0)"), "output.future"},
             {document(R"({"mode":"scene"})", "", R"(,"size":{"mode":"native","future":0})"), "output.size.future"}})
        reject(entry.first, "unknown " + entry.second, entry.second);
    for (const auto& duplicate : {
             replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":1,"schema_version":1)"),
             replaceOnce(minimal, R"("path":"in.ARW")", R"("path":"in.ARW","path":"other.ARW")"),
             document(R"({"mode":"scene","mode":"sensor"})"),
             document(R"({"mode":"scene","ev":0,"\u0065v":1})"),
             document(R"({"mode":"scene"})", R"(,"look":{"path":null,"path":"film.cube"})"),
             document(R"({"mode":"scene"})", "", R"(,"size":{"mode":"limit_long_edge","long_edge":10,"long_edge":20})")})
        reject(duplicate, "duplicate object key", "Duplicate key");
}

void malformedAndUnicode() {
    const auto minimal = document();
    for (const auto& invalid : {std::string(), std::string("null"), std::string("[]"), std::string("1"),
             minimal.substr(0, minimal.size() - 1), minimal + " trailing", minimal + minimal,
             replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":01)"),
             replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":1e999)"),
             replaceOnce(minimal, R"("path":"in.ARW")", R"("path":"\uD800")"),
             replaceOnce(minimal, R"("path":"in.ARW")", R"("path":"\uDC00")"),
             replaceOnce(minimal, R"("path":"in.ARW")", R"("path":"\x20")")})
        reject(invalid, "malformed JSON or Unicode");
    for (const auto& path : {R"("path":"in\u0000.ARW")", R"("path":"\u0000")"})
        reject(replaceOnce(minimal, R"("path":"in.ARW")", path), "escaped input NUL", "input.path");
    reject(replaceOnce(minimal, R"("path":"out.jpg")", R"("path":"out\u0000.jpg")"), "escaped output NUL", "output.path");
    reject(document(R"({"mode":"scene"})", R"(,"look":{"path":"look\u0000.cube"})"), "escaped look NUL", "edits.look.path");
    reject(replaceOnce(minimal, "in.ARW", std::string("in\0.ARW", 7)), "literal NUL inside path");
    reject(minimal + std::string("\0junk", 5), "literal trailing NUL and ignored suffix");
    for (const auto& bytes : {std::string("\xC0\xAF", 2), std::string("\xC3", 1), std::string("\xED\xA0\x80", 3), std::string("\xF4\x90\x80\x80", 4)})
        reject(replaceOnce(minimal, "in.ARW", bytes), "invalid UTF-8 path");
    auto unicode = replaceOnce(minimal, "in.ARW", u8"样片/日落 🌅.ARW");
    unicode = replaceOnce(unicode, "out.jpg", R"(exports/\u8c03\u8272-\uD83D\uDCF7.jpg)");
    const auto value = parse(unicode);
    check(value.inputPath == u8"样片/日落 🌅.ARW" && value.outputPath == u8"exports/调色-📷.jpg", "UTF-8 and surrogate-pair paths decode exactly");
    check(sameRecipe(parse(sony2fuji::serializeEditRecipe(value)), value), "Unicode paths round trip");
    const auto escaped = parse(replaceOnce(minimal, "in.ARW", R"(folder\\a\"b.ARW)"));
    check(escaped.inputPath == "folder\\a\"b.ARW", "backslashes and quotes in paths decode exactly");
    reject(std::string(1024 * 1024 + 1, ' '), "oversized document", "1 MiB");
}

void atmosphereCompatibility() {
    auto recipe=sentinel();
    const auto old=sony2fuji::serializeEditRecipe(recipe);
    check(old.find("clarity")==std::string::npos && old.find("dehaze")==std::string::npos,"v4 bytes omit new identity fields");
    recipe.schemaVersion=5;recipe.atmosphere.clarity=.625f;recipe.atmosphere.dehaze=-.375f;
    const auto saved=sony2fuji::serializeEditRecipe(recipe);
    const auto restored=parse(saved);
    check(restored.atmosphere.clarity==.625f && restored.atmosphere.dehaze==-.375f,"atmosphere signed values round trip");
    for(int version=1;version<=4;++version) {
        auto invalid=recipe;invalid.schemaVersion=version;
        bool rejected=false;
        try { sony2fuji::serializeEditRecipe(invalid); }catch(const std::invalid_argument&){rejected=true;}
        check(rejected,"old serializer rejects active atmosphere "+std::to_string(version));
    }
    for(int field=0;field<2;++field) for(float bad:{-1.01f,1.01f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
        auto invalid=recipe;(field==0?invalid.atmosphere.clarity:invalid.atmosphere.dehaze)=bad;
        bool rejected=false;
        try { sony2fuji::serializeEditRecipe(invalid); }catch(const std::invalid_argument&){rejected=true;}
        check(rejected,"serializer validates atmosphere finite range");
    }
    for(int kind=0;kind<2;++kind) {
        auto invalid=recipe;if(kind==0)++invalid.atmosphere.version;else --invalid.atmosphere.struct_size;
        bool rejected=false;
        try { sony2fuji::serializeEditRecipe(invalid); }catch(const std::invalid_argument&){rejected=true;}
        check(rejected,"serializer validates atmosphere ABI");
    }
    auto destination=recipe;std::string error;
    const auto bad=replaceOnce(saved,"\"clarity\": 0.625","\"clarity\": 1.01");
    check(!sony2fuji::parseEditRecipe(bad,destination,error) && sameRecipe(destination,recipe),"invalid atmosphere parse retains destination");
    check(sony2fuji::parseEditRecipe(old,destination,error) && destination.atmosphere.clarity==0 && destination.atmosphere.dehaze==0,
        "old recipe clears previously active atmosphere on reused destination");
}

} // namespace

int main() {
    try {
        defaultsAndExposure();
        whiteBalanceAndLook();
        outputAndRoundTrip();
        legacyRequestParity();
        completeEdits();
        invalidFields();
        unknownAndDuplicateKeys();
        malformedAndUnicode();
        atmosphereCompatibility();
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
    if (failures) {
        std::cerr << failures << " of " << checks << " checks failed\n";
        return 1;
    }
    std::cout << checks << " edit recipe parsing, normalization and legacy request mapping checks passed\n";
    return 0;
}
