#include "test_harness.h"
#include "sony2fuji/edit_recipe.h"
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using sony2fuji::EditRecipe;
using rawlab::test::check;
std::string document(const std::string& exposure = R"({"mode":"scene"})",
                     const std::string& edits = "", const std::string& output = "",
                     const std::string& format = "jpeg") {
    return R"({"schema_version":1,"input":{"path":"in.ARW"},"edits":{"exposure":)" +
        exposure + edits + R"(},"output":{"path":"out.jpg","format":")" + format + '"' + output + "}}";
}

std::string hdrDocument(const std::string& cameraDevelopment) {
    return R"({"schema_version":14,"processing":{"family":"rawlab_hdr","version":7,"quality":"standard"},)"
        R"("input":{"path":"photo.ARW","type":"raw","camera_development":{)" + cameraDevelopment + R"(}},)"
        R"("edits":{"exposure":{"ev":0.5},"white_balance":{"mode":"relative"}},)"
        R"("output":{"path":"out.jpg","format":"hdr_jpeg","base_color":"srgb"}})";
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
    // profile_id 与 HDR 的 lens_profile 使用同一套约束：长度上限与控制字符。
    // '\n' 是目录 id 的合成分隔符（maker/model/mount/crop factor），必须放行；其余控制字符拒绝。
    reject(v4(R"(,"lens_correction":{"profile_id":")" + std::string(1025, 'a') + R"("})"),
           "overlong lens profile id", "edits.lens_correction.profile_id");
    reject(v4(R"(,"lens_correction":{"profile_id":"a\u0001b"})"),
           "control character in lens profile id", "edits.lens_correction.profile_id");
    reject(v4(R"(,"lens_correction":{"profile_id":"a\rb"})"),
           "carriage return in lens profile id", "edits.lens_correction.profile_id");
    parse(v4(R"(,"lens_correction":{"profile_id":")" + std::string(1024, 'a') + R"("})"));
    // 合成目录 id 必须能通过解析并往返，且解码值逐字保留分隔符（fixture lenses.xml 中匹配镜头的真实 id 形态）。
    const auto composite = parse(v4(R"(,"lens_correction":{"profile_id":"RawLab\nTest 24mm f/2.8\nRawLab Test\n1.000000"})"));
    check(composite.lensProfileId == "RawLab\nTest 24mm f/2.8\nRawLab Test\n1.000000",
          "composite catalog id parses with its newline separators intact");
    check(sameRecipe(parse(sony2fuji::serializeEditRecipe(composite)), composite), "composite catalog id round trips");
    parse(v4(R"(,"tone":{"contrast":0,"saturation":2,"highlights":-1,"shadows":1,"s_curve":-1},"detail":{"sharpening":2},"hsl":{"hue":[-100,100,0,0,0,0,0,0]},"look":{"path":null,"strength":2})"));
}


// HDR lens_profile 与 SDR profile_id 共用 validProfileId：'\n' 是目录 id 的分隔符必须放行，其余控制字符照旧拒绝。
void hdrLensProfileBounds() {
    const auto parsed = parse(hdrDocument(R"("lens_distortion":true,"lens_profile":"RawLab\nTest 24mm f/2.8\nRawLab Test\n1.000000")"));
    check(parsed.hdr && parsed.hdr->lensProfile == "RawLab\nTest 24mm f/2.8\nRawLab Test\n1.000000",
          "HDR lens_profile accepts newline-separated catalog ids");
    reject(hdrDocument(R"("lens_distortion":true,"lens_profile":"a\rb")"),
           "HDR carriage return lens profile", "lens_profile");
    reject(hdrDocument(R"("lens_distortion":true,"lens_profile":"a\u0001b")"),
           "HDR control character lens profile", "lens_profile");
}

void invalidFields() {
    const auto minimal = document();
    for (const auto& entry : std::vector<std::pair<std::string, std::string>>{
             {replaceOnce(minimal, R"("schema_version":1,)", ""), "schema_version"},
             {replaceOnce(minimal, R"("input":{"path":"in.ARW"},)", ""), "recipe.input"},
             {replaceOnce(minimal, R"("edits":{"exposure":{"mode":"scene"}},)", ""), "recipe.edits"},
             {replaceOnce(minimal, R"("output":{"path":"out.jpg","format":"jpeg"})", R"("output":{})"), "output.path"},
             {replaceOnce(minimal, R"("format":"jpeg")", R"("format":null)"), "output.format"},
             {replaceOnce(minimal, R"("schema_version":1)", R"("schema_version":99)"), "schema_version"},
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

void v16AndV17Contracts() {
    // 1. SDR v17 round trip, default omission, raster relative WB, and legacy rejection.
    const std::string sdr17Doc = R"({
        "schema_version": 17,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "photo.png", "type": "raster"},
        "edits": {
            "exposure": {"mode": "sensor", "ev": 0.0, "brightness": 1.0},
            "white_balance": {"mode": "relative", "relative_temperature": 5600, "relative_tint": -12},
            "tone": {
                "curve": {
                    "mode": "custom",
                    "points": [[0.0, 0.08], [0.5, 0.55], [1.0, 0.92]],
                    "apply_to_luminosity": true,
                    "parametric": {
                        "highlights": -15,
                        "lights": 10,
                        "darks": -5,
                        "shadows": 20,
                        "split_shadow": 0.22,
                        "split_midtone": 0.50,
                        "split_highlight": 0.78
                    }
                }
            },
            "color_grading": {
                "shadows": {"hue": 210, "saturation": 25, "luminance": -15},
                "midtones": {"hue": 35, "saturation": 10, "luminance": 5},
                "highlights": {"hue": 45, "saturation": 15, "luminance": 10},
                "global": {"hue": 180, "saturation": 5, "luminance": -3},
                "blending": 65,
                "balance": -20
            }
        },
        "output": {"path": "out.jpg", "format": "jpeg", "output_sharpening": "standard"}
    })";
    const auto sdr17 = parse(sdr17Doc);
    check(sdr17.schemaVersion == 17 && sdr17.rasterInput && sdr17.rasterRelativeWb, "v17 raster relative WB parses");
    check(sdr17.temperatureKelvin == 5600.0f && sdr17.tint == -12.0f, "v17 relative WB values");
    check(sdr17.curveApplyToLuminosity && sdr17.parametricCurve.highlights == -15.0f &&
          sdr17.parametricCurve.split_shadow == 0.22f, "v17 curve v2 fields parse");
    check(sdr17.colorGradingV2.shadows_luminance == -15.0f && sdr17.colorGradingV2.global_hue == 180.0f &&
          sdr17.colorGradingV2.blending == 65.0f && sdr17.colorGradingV2.balance == -20.0f, "v17 grading v2 fields parse");
    check(sdr17.outputSharpening == SONY2FUJI_OUTPUT_SHARPENING_STANDARD, "v17 output_sharpening parses");
    const auto sdr17Saved = sony2fuji::serializeEditRecipe(sdr17);
    check(sameRecipe(parse(sdr17Saved), sdr17), "v17 round trip is idempotent");

    // Default v17 recipe omits all v0.12 additive keys.
    const std::string sdr17DefaultDoc = R"({
        "schema_version": 17,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "photo.ARW", "type": "raw"},
        "edits": {"exposure": {"mode": "preview"}},
        "output": {"path": "out.jpg", "format": "jpeg"}
    })";
    const auto sdr17DefaultSaved = sony2fuji::serializeEditRecipe(parse(sdr17DefaultDoc));
    check(sdr17DefaultSaved.find("apply_to_luminosity") == std::string::npos &&
          sdr17DefaultSaved.find("parametric") == std::string::npos &&
          sdr17DefaultSaved.find("output_sharpening") == std::string::npos &&
          sdr17DefaultSaved.find("luminance") == std::string::npos &&
          sdr17DefaultSaved.find("blending") == std::string::npos, "v17 omits default v0.12 fields");

    // Legacy v5 rejects free endpoints, parametric, apply_to_luminosity, grading v2, output_sharpening, raster relative WB.
    reject(replaceOnce(sdr17Doc, "\"schema_version\": 17", "\"schema_version\": 5"), "v5 rejects v0.12 fields");
    reject(replaceOnce(sdr17Doc, "\"split_midtone\": 0.50", "\"split_midtone\": 0.23"), "v17 rejects split gap < 0.02");

    // 2. HDR v16 round trip & toHDRRenderRequestV9.
    const std::string hdr16Doc = R"({
        "schema_version": 16,
        "processing": {"family": "rawlab_hdr", "version": 9, "quality": "standard"},
        "input": {"path": "photo.ARW", "type": "raw"},
        "edits": {
            "exposure": {"ev": 0.25},
            "white_balance": {"mode": "relative"},
            "tone": {
                "curve": {
                    "mode": "custom",
                    "points": [[0.0, 0.05], [1.0, 0.95]],
                    "apply_to_luminosity": true,
                    "parametric": {"highlights": 10, "shadows": -10}
                }
            },
            "color_grading": {
                "shadows": {"hue": 190, "saturation": 20, "luminance": -10},
                "global": {"hue": 40, "saturation": 8, "luminance": 4},
                "blending": 70,
                "balance": 15
            }
        },
        "output": {"path": "out.jpg", "format": "hdr_jpeg", "base_color": "srgb", "output_sharpening": "high"}
    })";
    const auto hdr16 = parse(hdr16Doc);
    check(hdr16.schemaVersion == 16 && hdr16.hdr && hdr16.hdr->processingVersion == 9, "HDR v16 parses");
    const auto hdrReqV9 = hdr16.toHDRRenderRequestV9();
    check(hdrReqV9.base.base.base.base.base.base.base.base.hdr_processing_version == SONY2FUJI_HDR_PROCESSING_V2_GRADING_CURVE_VERSION &&
          hdrReqV9.base.base.base.base.base.base.base.base.struct_size == sizeof(hdrReqV9) &&
          hdrReqV9.curve_apply_to_luminosity == 1 &&
          hdrReqV9.output_sharpening == SONY2FUJI_OUTPUT_SHARPENING_HIGH &&
          hdrReqV9.parametric_curve.highlights == 10.0f &&
          hdrReqV9.grading_v2.global_hue == 40.0f &&
          hdrReqV9.grading_v2.blending == 70.0f, "toHDRRenderRequestV9 maps all v9 fields");
    check(sameRecipe(parse(sony2fuji::serializeEditRecipe(hdr16)), hdr16), "HDR v16 round trip is idempotent");
    reject(replaceOnce(hdr16Doc, "\"schema_version\": 16", "\"schema_version\": 15"), "v15 rejects processing.version 9 / v16 fields");
}

void v20SdrContractsAndStubs() {
    const std::string sdr20Doc = R"({
        "schema_version": 20,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "photo.png", "type": "raster"},
        "edits": {
            "exposure": {"mode": "sensor"},
            "white_balance": {"mode": "none"},
            "color": {
                "vibrance": 0.15,
                "calibration": {"shadow_tint": -12, "red_hue": 8, "red_saturation": 14, "green_hue": -5, "green_saturation": 6, "blue_hue": -10, "blue_saturation": 18},
                "point_color": {"swatches": [{"src_hue": 210, "src_saturation": 0.65, "src_luminance": 0.45, "hue_shift": 12, "saturation_shift": -8, "luminance_shift": 5, "variance": -10, "range": 60, "hue_range": 45, "sat_range": 55, "lum_range": 50, "enabled": true}]},
                "selective_color": {"method": "absolute", "bands": {"reds": {"cyan": -15, "magenta": 10, "yellow": 5, "black": -5}}},
                "bw": {"enabled": true, "mixer": {"red": 20, "yellow": 15, "blue": -25}}
            },
            "detail": {
                "sharpening": 0.5,
                "luminance_v2": true,
                "sharpening_radius": 1.4,
                "sharpening_detail": 40,
                "sharpening_masking": 35
            },
            "effects": {
                "texture": 0.35,
                "grain_amount": 20,
                "grain_tone_curve": "negative_asymmetric",
                "grain_format_preset": "135",
                "halation": {"amount": 25, "threshold": 80, "radius": 45, "hue": -15},
                "bloom": {"amount": 18, "threshold": 72, "radius": 50}
            },
            "lens_correction": {
                "distortion": false,
                "tca": false,
                "vignetting": false,
                "auto_crop": true,
                "profile_id": null,
                "defringe_purple_amount": 6,
                "defringe_purple_hue": 45,
                "defringe_green_amount": 4,
                "defringe_green_hue": 55
            }
        },
        "output": {"path": "out.jpg", "format": "jpeg"}
    })";
    const auto sdr20 = parse(sdr20Doc);
    check(sdr20.schemaVersion == 20 && sdr20.rasterInput, "v20 raster defringe parses with allowRasterLensCorrection=false");
    check(sdr20.calibration.shadowTint == -12.0f && sdr20.calibration.blueSaturation == 18.0f, "v20 calibration parses");
    check(sdr20.pointColor.swatchCount == 1 && sdr20.pointColor.swatches[0].srcHue == 210.0f, "v20 point_color parses");
    check(sdr20.selectiveColor.absolute && sdr20.selectiveColor.bands[0].cyan == -15.0f, "v20 selective_color parses");
    check(sdr20.bw.enabled && sdr20.bw.weights[0] == 20.0f && sdr20.bw.weights[5] == -25.0f, "v20 bw mixer parses");
    check(sdr20.texture == 0.35f, "v20 texture parses");
    check(sdr20.sharpenV2.luminanceV2 && sdr20.sharpenV2.radius == 1.4f && sdr20.sharpenV2.masking == 35.0f, "v20 sharpen v2 parses");
    check(sdr20.grainToneCurve == sony2fuji::EditGrainToneCurve::NegativeAsymmetric &&
          sdr20.grainFormatPreset == sony2fuji::EditGrainFormatPreset::Film135, "v20 grain curve/preset parse");
    check(sdr20.filmOptics.halationAmount == 25.0f && sdr20.filmOptics.bloomAmount == 18.0f, "v20 halation/bloom parse");
    check(sdr20.defringe.purpleAmount == 6.0f && sdr20.defringe.greenAmount == 4.0f, "v20 defringe parses");
    const auto saved20 = sony2fuji::serializeEditRecipe(sdr20);
    check(saved20.find("\"schema_version\": 20") != std::string::npos, "active v20 emits schema_version 20");
    check(sameRecipe(parse(saved20), sdr20), "v20 round trip is idempotent");

    // Default v20 drops back to <= 18 and omits all v0.14.0 keys.
    const std::string v20Defaults = R"({
        "schema_version": 20,
        "processing": {"family": "rawlab", "version": 3, "quality": "standard"},
        "input": {"path": "photo.ARW", "type": "raw"},
        "edits": {"exposure": {"mode": "preview"}},
        "output": {"path": "out.jpg", "format": "jpeg"}
    })";
    const auto parsedDefault20 = parse(v20Defaults);
    const auto serializedDefault20 = sony2fuji::serializeEditRecipe(parsedDefault20);
    check(serializedDefault20.find("\"schema_version\": 17") != std::string::npos &&
          serializedDefault20.find("calibration") == std::string::npos &&
          serializedDefault20.find("point_color") == std::string::npos &&
          serializedDefault20.find("luminance_v2") == std::string::npos &&
          serializedDefault20.find("halation") == std::string::npos,
          "default v20 emits schema_version <= 18 and omits v0.14.0 keys");

    // Legacy v18 rejects v20 fields and serializing v20 features as v18 throws.
    reject(replaceOnce(sdr20Doc, "\"schema_version\": 20", "\"schema_version\": 18"), "v18 rejects v20 fields");
    auto badDowngrade = sdr20;
    badDowngrade.schemaVersion = 18;
    bool rejectedSerialize = false;
    try { (void)sony2fuji::serializeEditRecipe(badDowngrade); } catch (const std::invalid_argument&) { rejectedSerialize = true; }
    check(rejectedSerialize, "serializeEditRecipe rejects schemaVersion < 20 when v0.14.0 features are active");

    // Narrow Wave 0 C ABI helpers validate arguments and return UNSUPPORTED.
    uint8_t dummyPixel[3] = {128, 128, 128};
    sony2fuji_buffer srcBuf{};
    srcBuf.data = dummyPixel;
    srcBuf.width = 1;
    srcBuf.height = 1;
    sony2fuji_buffer outMask{};
    check(sony2fuji_render_sharpen_mask_preview(nullptr, 1.0f, 50.0f, &outMask) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "sharpen mask preview rejects null source");
    check(sony2fuji_render_sharpen_mask_preview(&srcBuf, 1.0f, 50.0f, &outMask) == SONY2FUJI_STATUS_UNSUPPORTED,
          "sharpen mask preview returns clean UNSUPPORTED stub in Wave 0");
    float srcRgb[3]{}, dstRgb[3]{};
    check(sony2fuji_point_color_preview_swatch(360.0f, 0.5f, 0.5f, 0.0f, 0.0f, 0.0f, srcRgb, dstRgb) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "point color swatch preview rejects src_hue >= 360");
    check(sony2fuji_point_color_preview_swatch(120.0f, 0.5f, 0.5f, 10.0f, 0.0f, 0.0f, srcRgb, dstRgb) == SONY2FUJI_STATUS_UNSUPPORTED,
          "point color swatch preview returns clean UNSUPPORTED stub in Wave 0");
}

} // namespace

TEST_MAIN(
    {
        sony2fuji::EditRecipe x3f;
        x3f.inputPath = "photo.X3F"; x3f.outputPath = "photo.png";
        x3f.schemaVersion = 7; x3f.x3fMode = SONY2FUJI_X3F_NORMAL;
        const auto serialized = sony2fuji::serializeEditRecipe(x3f);
        sony2fuji::EditRecipe restored; std::string error;
        RAWLAB_CHECK(sony2fuji::parseEditRecipe(serialized, restored, error) && restored.x3fMode == SONY2FUJI_X3F_NORMAL,
            "v7 preserves normal X3F identity");
        RAWLAB_CHECK(!sony2fuji::parseEditRecipe(replaceOnce(serialized,"normal-v1","future"), restored, error),
            "unknown X3F mode rejected");
        RAWLAB_CHECK(x3f.toRequest().input_type == SONY2FUJI_INPUT_RAW, "v7 maps to the RAW request rather than HDR");
        x3f.schemaVersion = 5;
        bool rejected = false;
        try { sony2fuji::serializeEditRecipe(x3f); } catch (const std::invalid_argument&) { rejected = true; }
        RAWLAB_CHECK(rejected,"old schemas cannot silently discard normal X3F identity");
    }
    defaultsAndExposure();
    whiteBalanceAndLook();
    outputAndRoundTrip();
    legacyRequestParity();
    completeEdits();
    hdrLensProfileBounds();
    invalidFields();
    unknownAndDuplicateKeys();
    malformedAndUnicode();
    atmosphereCompatibility();
    v16AndV17Contracts();
    v20SdrContractsAndStubs();
    if (rawlab::test::failureCount() != 0) {
        std::cerr << rawlab::test::failureCount() << " of " << rawlab::test::checkCount() << " rawlab::test::checkCount() failed\n";
    } else {
        std::cout << rawlab::test::checkCount() << " edit recipe parsing, normalization and legacy request mapping rawlab::test::checkCount() passed\n";
    }
)
