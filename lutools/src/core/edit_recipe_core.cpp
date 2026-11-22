#include "core/edit_recipe_params.h"

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

void hslAxis(const Json& object, const char* key, std::array<float, 8>& destination) {
    if (!object.contains(key)) return;
    const auto& values = object.at(key);
    const auto path = std::string("edits.hsl.") + key;
    if (!values.is_array() || values.size() != 8)
        throw std::invalid_argument(path + " must contain eight numbers");
    for (size_t i = 0; i < values.size(); ++i) {
        const auto& value = values[i];
        if (!value.is_number() || !std::isfinite(value.get<double>()) ||
            value.get<double>() < -100 || value.get<double>() > 100)
            throw std::invalid_argument(path + "[" + std::to_string(i) + "] is out of range");
        destination[i] = value.get<float>();
    }
}

void readToneCurve(const Json& curve, ToneCurveConfig& config, bool allowFreeEndpoints) {
    const std::string path = "edits.tone.curve";
    fields(curve, path, {"mode", "points"});
    const auto mode = text(required(curve, "mode", path), path + ".mode");
    if (mode == "legacy") config.mode = ToneCurveMode::Legacy;
    else if (mode == "custom") config.mode = ToneCurveMode::Custom;
    else throw std::invalid_argument(path + ".mode is unsupported");
    const auto& points = required(curve, "points", path);
    if (!points.is_array() || points.size() > kToneCurveMaxPoints)
        throw std::invalid_argument(path + ".points must be an array of at most 33 points");
    config.count = static_cast<uint32_t>(points.size());
    for (size_t i = 0; i < points.size(); ++i) {
        const auto& point = points[i];
        if (!point.is_array() || point.size() != 2 || !point[0].is_number() || !point[1].is_number())
            throw std::invalid_argument(path + ".points must contain [x,y] pairs");
        config.points[i] = {point[0].get<double>(), point[1].get<double>()};
    }
    if (!validToneCurve(config, allowFreeEndpoints))
        throw std::invalid_argument(path + ".points are invalid for the selected mode");
}

void readParametricCurve(const Json& param, ToneCurveParametricConfig& out) {
    const std::string path = "edits.tone.curve.parametric";
    fields(param, path, {"highlights", "lights", "darks", "shadows", "split_shadow", "split_midtone", "split_highlight"});
    out.highlights = number(param, "highlights", 0.0f, -100.0, 100.0, path);
    out.lights = number(param, "lights", 0.0f, -100.0, 100.0, path);
    out.darks = number(param, "darks", 0.0f, -100.0, 100.0, path);
    out.shadows = number(param, "shadows", 0.0f, -100.0, 100.0, path);
    out.splitShadow = number(param, "split_shadow", 0.25f, 0.05, 0.45, path);
    out.splitMidtone = number(param, "split_midtone", 0.50f, 0.25, 0.75, path);
    out.splitHighlight = number(param, "split_highlight", 0.75f, 0.55, 0.95, path);
    if (!out.valid()) {
        throw std::invalid_argument(path + " split points must be strictly increasing with minimum gap 0.02");
    }
}

void completeEdits(const Json& edits, CanonicalSdrRecipe& parsed) {
    const bool allowV12 = parsed.schemaVersion >= 17;
    if (edits.contains("color_grading")) {
        const auto& grading = edits.at("color_grading");
        if (allowV12)
            fields(grading, "edits.color_grading", {"shadows", "midtones", "highlights", "global", "blending", "balance"});
        else
            fields(grading, "edits.color_grading", {"shadows", "midtones", "highlights"});
        auto readWheel = [&](const char* zone, ColorGradingWheel& wheelOut) {
            if (!grading.contains(zone)) return;
            const auto path = std::string("edits.color_grading.") + zone;
            const auto& wheel = grading.at(zone);
            if (allowV12)
                fields(wheel, path, {"hue", "saturation", "luminance"});
            else
                fields(wheel, path, {"hue", "saturation"});
            required(wheel, "hue", path);
            required(wheel, "saturation", path);
            float hue = number(wheel, "hue", 0, 0, 360, path);
            if (wheel.at("hue").get<double>() >= 360)
                throw std::invalid_argument(path + ".hue is out of range");
            // 合法 double 在 float 环回点舍入为 360 时，保持等价的 canonical 0。
            if (hue == 360) hue = 0;
            wheelOut.hue = hue;
            wheelOut.saturation = number(wheel, "saturation", 0, 0, 100, path);
            if (allowV12)
                wheelOut.luminance = number(wheel, "luminance", 0, -100, 100, path);
        };
        readWheel("shadows", parsed.colorGrading.wheels[0]);
        readWheel("midtones", parsed.colorGrading.wheels[1]);
        readWheel("highlights", parsed.colorGrading.wheels[2]);
        if (allowV12) {
            readWheel("global", parsed.colorGrading.global);
            parsed.colorGrading.blending = number(grading, "blending", 50.0f, 0.0, 100.0, "edits.color_grading");
            parsed.colorGrading.balance = number(grading, "balance", 0.0f, -100.0, 100.0, "edits.color_grading");
        }
    }
    if (edits.contains("tone")) {
        const auto& tone = edits.at("tone");
        if (parsed.schemaVersion >= 5)
            fields(tone, "edits.tone", {"contrast", "saturation", "highlights", "shadows", "s_curve", "black_point", "white_point", "curve"});
        else
            fields(tone, "edits.tone", {"contrast", "saturation", "highlights", "shadows", "s_curve"});
        parsed.contrast = number(tone, "contrast", 1, 0, 2, "edits.tone");
        parsed.saturation = number(tone, "saturation", 1, 0, 2, "edits.tone");
        parsed.highlights = number(tone, "highlights", 0, -1, 1, "edits.tone");
        parsed.shadows = number(tone, "shadows", 0, -1, 1, "edits.tone");
        parsed.sCurve = number(tone, "s_curve", 0, -1, 1, "edits.tone");
        parsed.toneControls.blackPoint = number(tone, "black_point", 0, -1, 1, "edits.tone");
        parsed.toneControls.whitePoint = number(tone, "white_point", 0, -1, 1, "edits.tone");
        if (tone.contains("curve")) {
            const auto& root = tone.at("curve");
            if (!root.is_object()) throw std::invalid_argument("edits.tone.curve must be an object");
            auto master = root;
            if (root.contains("channels")) {
                const auto& channels = root.at("channels");
                fields(channels, "edits.tone.curve.channels", {"red", "green", "blue"});
                const char* names[]{"red", "green", "blue"};
                for (size_t i = 0; i < 3; ++i)
                    if (channels.contains(names[i])) readToneCurve(channels.at(names[i]), parsed.channelCurves[i], allowV12);
                master.erase("channels");
            }
            if (allowV12 && root.contains("apply_to_luminosity")) {
                parsed.curveApplyToLuminosity = boolean(root, "apply_to_luminosity", "edits.tone.curve") != 0;
                master.erase("apply_to_luminosity");
            }
            if (allowV12 && root.contains("parametric")) {
                readParametricCurve(root.at("parametric"), parsed.parametricCurve);
                master.erase("parametric");
            }
            readToneCurve(master, parsed.toneCurve, allowV12);
            if (parsed.toneCurve.mode == ToneCurveMode::Custom && parsed.sCurve != 0)
                throw std::invalid_argument("edits.tone.curve conflicts with nonzero edits.tone.s_curve");
        }
    }
    if (edits.contains("color")) {
        const auto& color = edits.at("color");
        fields(color, "edits.color", {"vibrance"});
        parsed.toneControls.vibrance = number(color, "vibrance", 0, -1, 1, "edits.color");
    }
    if (edits.contains("detail")) {
        const auto& detail = edits.at("detail");
        fields(detail, "edits.detail", {"sharpening"});
        parsed.sharpening = number(detail, "sharpening", 0, 0, 2, "edits.detail");
    }
    if (edits.contains("hsl")) {
        const auto& hsl = edits.at("hsl");
        fields(hsl, "edits.hsl", {"hue", "saturation", "lightness"});
        hslAxis(hsl, "hue", parsed.hsl.hue);
        hslAxis(hsl, "saturation", parsed.hsl.saturation);
        hslAxis(hsl, "lightness", parsed.hsl.lightness);
    }
    if (edits.contains("effects")) {
        const auto& fx = edits.at("effects");
        if (parsed.schemaVersion >= 5)
            fields(fx, "edits.effects", {"vignette_amount", "vignette_midpoint", "vignette_roundness",
                "vignette_feather", "vignette_highlights", "grain_amount", "grain_size", "grain_roughness", "clarity", "dehaze"});
        else
            fields(fx, "edits.effects", {"vignette_amount", "vignette_midpoint", "vignette_roundness",
                "vignette_feather", "vignette_highlights", "grain_amount", "grain_size", "grain_roughness"});
        parsed.atmosphere.clarity = number(fx, "clarity", 0, -1, 1, "edits.effects");
        parsed.atmosphere.dehaze = number(fx, "dehaze", 0, -1, 1, "edits.effects");
        auto& config = parsed.effects;
        config.vignetteAmount = number(fx, "vignette_amount", 0, -100, 100, "edits.effects");
        config.vignetteMidpoint = number(fx, "vignette_midpoint", 50, 0, 100, "edits.effects");
        config.vignetteRoundness = number(fx, "vignette_roundness", 0, -100, 100, "edits.effects");
        config.vignetteFeather = number(fx, "vignette_feather", 50, 0, 100, "edits.effects");
        config.vignetteHighlights = number(fx, "vignette_highlights", 0, 0, 100, "edits.effects");
        config.grainAmount = number(fx, "grain_amount", 0, 0, 100, "edits.effects");
        config.grainSize = number(fx, "grain_size", 25, 0, 100, "edits.effects");
        config.grainRoughness = number(fx, "grain_roughness", 50, 0, 100, "edits.effects");
    }
    if (edits.contains("denoise")) {
        const auto& denoise = edits.at("denoise");
        fields(denoise, "edits.denoise", {"raw_level", "chroma_mode", "wavelet"});
        if (denoise.contains("raw_level"))
            parsed.rawNoiseReduction = static_cast<int32_t>(integer(denoise.at("raw_level"), 0, 2, "edits.denoise.raw_level"));
        if (denoise.contains("chroma_mode"))
            parsed.chromaDenoise = static_cast<int32_t>(integer(denoise.at("chroma_mode"), 0, 2, "edits.denoise.chroma_mode"));
        if (denoise.contains("wavelet")) {
            const auto& wavelet = denoise.at("wavelet");
            fields(wavelet, "edits.denoise.wavelet", {"enabled", "luma", "chroma", "coarse"});
            parsed.wavelet.enabled = boolean(wavelet, "enabled", "edits.denoise.wavelet") != 0;
            parsed.wavelet.luma = number(wavelet, "luma", 0, 0, 100, "edits.denoise.wavelet");
            parsed.wavelet.chroma = number(wavelet, "chroma", 46, 0, 100, "edits.denoise.wavelet");
            parsed.wavelet.coarse = number(wavelet, "coarse", 50, 0, 100, "edits.denoise.wavelet");
        }
    }
    if (edits.contains("lens_correction")) {
        const auto& lens = edits.at("lens_correction");
        fields(lens, "edits.lens_correction", {"distortion", "tca", "vignetting", "auto_crop", "profile_id"});
        parsed.lensDistortion = boolean(lens, "distortion", "edits.lens_correction") != 0;
        parsed.lensTca = boolean(lens, "tca", "edits.lens_correction") != 0;
        parsed.lensVignetting = boolean(lens, "vignetting", "edits.lens_correction") != 0;
        parsed.lensAutoCrop = !lens.contains("auto_crop") || boolean(lens, "auto_crop", "edits.lens_correction") != 0;
        if (lens.contains("profile_id") && !lens.at("profile_id").is_null()) {
            parsed.lensProfileId = text(lens.at("profile_id"), "edits.lens_correction.profile_id");
            if (!validProfileId(parsed.lensProfileId))
                throw std::invalid_argument("edits.lens_correction.profile_id must be a valid id");
        }
    }
}

bool isHdrSchemaVersion(uint32_t schema) {
    return schema == 6 || (schema >= 8 && schema <= 16);
}

} // namespace

bool validProfileId(const std::string& id) {
    return id.size() <= 1024 &&
        !std::any_of(id.begin(), id.end(), [](unsigned char c) { return (c < 32 && c != '\n') || c == 127; });
}

RenderParams CanonicalSdrRecipe::toRenderParams() const {
    const bool freeEndpoints = schemaVersion >= 17;
    RenderParams params{};
    params.inputType = rasterInput ? RenderInputType::DisplayBuffer : RenderInputType::Raw;
    params.inputPath = inputPath;
    params.lutPath = lookPath;
    params.lutStrength = lookStrength;
    params.wbMode = whiteBalanceMode;
    params.exposureEV = exposureEv;
    params.brightness = brightness;
    params.contrast = contrast;
    params.saturation = saturation;
    params.highlights = highlights;
    params.shadows = shadows;
    params.toneCurve = sCurve;
    params.sharpening = sharpening;
    params.temperature = temperatureKelvin;
    params.tint = tint;
    params.effects = effects;
    params.chromaDenoise = chromaDenoise;
    params.hsl = hsl;
    params.toneControls = toneControls;
    params.colorGrading = colorGrading;
    params.customCurve = ToneCurve(toneCurve, freeEndpoints);
    for (size_t i = 0; i < 3; ++i) {
        params.channelCurves[i] = ToneCurve(channelCurves[i], freeEndpoints);
    }
    params.curveApplyToLuminosity = curveApplyToLuminosity;
    params.parametricCurve = parametricCurve;
    params.outputSharpening = outputSharpening;
    params.sizeMode = outputLongEdge ? RenderSizeMode::LimitLongEdge : RenderSizeMode::Native;
    params.longEdge = outputLongEdge;
    params.intent = RenderIntent::Final;
    params.outputTarget = RenderOutputTarget::File;
    params.outputPath = outputPath;
    params.outputFormat = outputFormat;
    params.jpegQuality = jpegQuality;
    return params;
}

bool parseCanonicalSdrRecipe(
    const std::string& document,
    CanonicalSdrRecipe& out,
    std::string& error,
    bool allowRasterLensCorrection
) {
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
        const auto version = integer(required(root, "schema_version", "recipe"), 1,
                                     std::numeric_limits<uint32_t>::max(), "schema_version");
        if (isHdrSchemaVersion(version) || (version != 17 && (version < 1 || version > 7)))
            throw std::invalid_argument("Unsupported schema_version: " + std::to_string(version));
        if (version == 7 || version == 17) fields(root, "recipe", {"schema_version", "processing", "x3f_mode", "input", "edits", "output"});
        else if (version >= 5) fields(root, "recipe", {"schema_version", "processing", "input", "edits", "output"});
        else fields(root, "recipe", {"schema_version", "input", "edits", "output"});

        CanonicalSdrRecipe parsed;
        parsed.schemaVersion = version;
        if (version == 7) {
            const auto mode = text(required(root, "x3f_mode", "recipe"), "x3f_mode");
            if (mode == "normal-v1") parsed.x3fMode = X3fMode::Normal;
            else if (mode != "legacy") throw std::invalid_argument("Unsupported x3f_mode");
        } else if (version == 17 && root.contains("x3f_mode")) {
            const auto mode = text(root.at("x3f_mode"), "x3f_mode");
            if (mode == "normal-v1") parsed.x3fMode = X3fMode::Normal;
            else if (mode != "legacy") throw std::invalid_argument("Unsupported x3f_mode");
        }
        if (version >= 5) {
            const auto& processing = required(root, "processing", "recipe");
            fields(processing, "processing", {"family", "version", "quality"});
            if (text(required(processing, "family", "processing"), "processing.family") != "rawlab")
                throw std::invalid_argument("Unsupported processing.family");
            if (text(required(processing, "quality", "processing"), "processing.quality") != "standard")
                throw std::invalid_argument("Unsupported processing.quality");
            parsed.processingVersion = static_cast<ProcessingVersion>(
                integer(required(processing, "version", "processing"), 1, 3, "processing.version"));
            parsed.wavelet.processingVersion = parsed.processingVersion;
        }
        const auto& input = required(root, "input", "recipe");
        if (version >= 4) fields(input, "input", {"path", "type"});
        else fields(input, "input", {"path"});
        parsed.inputPath = text(required(input, "path", "input"), "input.path");
        if (input.contains("type")) {
            const auto type = text(input.at("type"), "input.type");
            if (type == "raster") parsed.rasterInput = true;
            else if (type != "raw") throw std::invalid_argument("input.type must be raw or raster");
        }
        if (version == 7 && parsed.rasterInput)
            throw std::invalid_argument("schema_version 7 requires an X3F raw input");
        if (version == 17 && parsed.rasterInput && root.contains("x3f_mode"))
            throw std::invalid_argument("x3f_mode requires a raw input");

        const auto& edits = required(root, "edits", "recipe");
        if (version == 1) fields(edits, "edits", {"exposure", "white_balance", "look"});
        else if (version < 4) fields(edits, "edits", {"exposure", "white_balance", "look", "geometry"});
        else if (version == 4) fields(edits, "edits", {"exposure", "white_balance", "look", "geometry", "tone", "detail", "hsl", "effects", "denoise", "lens_correction"});
        else fields(edits, "edits", {"exposure", "white_balance", "look", "geometry", "tone", "color", "color_grading", "detail", "hsl", "effects", "denoise", "lens_correction"});
        if (version >= 4) completeEdits(edits, parsed);
        const auto& exposure = required(edits, "exposure", "edits");
        fields(exposure, "edits.exposure", {"mode", "ev", "brightness"});
        const auto mode = text(required(exposure, "mode", "edits.exposure"), "edits.exposure.mode");
        if (mode == "scene") parsed.exposureMode = RawExposureMode::Scene;
        else if (mode == "preview") parsed.exposureMode = RawExposureMode::Preview;
        else if (mode == "sensor") parsed.exposureMode = RawExposureMode::Sensor;
        else throw std::invalid_argument("edits.exposure.mode must be scene, preview or sensor");
        parsed.exposureEv = number(exposure, "ev", 0, -20, 20, "edits.exposure");
        parsed.brightness = number(exposure, "brightness", 1, std::numeric_limits<float>::min(),
                                   std::numeric_limits<float>::max(), "edits.exposure");

        if (edits.contains("white_balance")) {
            const auto& wb = edits.at("white_balance");
            if (version >= 17)
                fields(wb, "edits.white_balance", {"mode", "temperature_kelvin", "tint", "relative_temperature", "relative_tint"});
            else
                fields(wb, "edits.white_balance", {"mode", "temperature_kelvin", "tint"});
            const auto wbMode = text(required(wb, "mode", "edits.white_balance"), "edits.white_balance.mode");
            if (parsed.rasterInput) {
                if (wbMode == "none") {
                    parsed.whiteBalanceMode = RenderWhiteBalanceMode::Camera;
                } else if (version >= 17 && wbMode == "relative") {
                    parsed.whiteBalanceMode = RenderWhiteBalanceMode::Relative;
                    parsed.temperatureKelvin = number(wb, "relative_temperature", 6500, 2000, 50000, "edits.white_balance");
                    parsed.tint = number(wb, "relative_tint", 0, -150, 150, "edits.white_balance");
                } else {
                    throw std::invalid_argument(version >= 17
                        ? "Raster edits.white_balance.mode must be none or relative"
                        : "Raster edits.white_balance.mode must be none");
                }
            } else {
                if (wbMode == "camera") parsed.whiteBalanceMode = RenderWhiteBalanceMode::Camera;
                else if (wbMode == "auto") parsed.whiteBalanceMode = RenderWhiteBalanceMode::Auto;
                else if (wbMode == "temperature") {
                    parsed.whiteBalanceMode = RenderWhiteBalanceMode::Temperature;
                    required(wb, "temperature_kelvin", "edits.white_balance");
                    parsed.temperatureKelvin = number(wb, "temperature_kelvin", 6500, 2000, 50000, "edits.white_balance");
                    parsed.tint = number(wb, "tint", 0, -150, 150, "edits.white_balance");
                } else throw std::invalid_argument("edits.white_balance.mode must be camera, auto or temperature");
            }
            if (wbMode != "temperature" && (wb.contains("temperature_kelvin") || wb.contains("tint")))
                throw std::invalid_argument("Kelvin/tint require edits.white_balance.mode=temperature");
            if (wbMode != "relative" && (wb.contains("relative_temperature") || wb.contains("relative_tint")))
                throw std::invalid_argument("relative_temperature/relative_tint require edits.white_balance.mode=relative");
        }

        if (parsed.rasterInput) {
            const bool badExposureOrRawNr = parsed.exposureMode != RawExposureMode::Sensor || parsed.rawNoiseReduction != 0;
            const bool activeLens = parsed.lensDistortion || parsed.lensTca || parsed.lensVignetting || !parsed.lensProfileId.empty();
            if (badExposureOrRawNr || (!allowRasterLensCorrection && activeLens))
                throw std::invalid_argument("Raster inputs require sensor exposure mode and disabled RAW denoise/lens correction");
        }

        if (edits.contains("look")) {
            const auto& look = edits.at("look");
            fields(look, "edits.look", {"path", "strength"});
            const auto& path = required(look, "path", "edits.look");
            if (!path.is_null()) parsed.lookPath = text(path, "edits.look.path");
            parsed.lookStrength = number(look, "strength", 1, 0, version >= 4 ? 2 : 1, "edits.look");
        }

        if (edits.contains("geometry")) {
            const auto& geometry = edits.at("geometry");
            const std::string geoPath = "edits.geometry";
            if (version == 2)
                fields(geometry, geoPath, {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten_degrees"});
            else
                fields(geometry, geoPath, {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten_degrees", "perspective"});
            auto& g = parsed.geometry;
            if (geometry.contains("quarter_turns"))
                g.quarter_turns = static_cast<int32_t>(integer(geometry.at("quarter_turns"), 0, 3, geoPath + ".quarter_turns"));
            g.flip_horizontal = boolean(geometry, "flip_horizontal", geoPath) != 0;
            g.flip_vertical = boolean(geometry, "flip_vertical", geoPath) != 0;
            g.straighten_degrees = number(geometry, "straighten_degrees", 0, -45, 45, geoPath);
            if (geometry.contains("perspective")) {
                const auto& perspective = geometry.at("perspective");
                const auto perspectivePath = geoPath + ".perspective";
                fields(perspective, perspectivePath, {"horizontal", "vertical"});
                g.perspective_horizontal = number(perspective, "horizontal", 0, -1, 1, perspectivePath);
                g.perspective_vertical = number(perspective, "vertical", 0, -1, 1, perspectivePath);
            }
            if (geometry.contains("crop")) {
                const auto& crop = geometry.at("crop");
                const std::string cropPath = geoPath + ".crop";
                fields(crop, cropPath, {"x", "y", "width", "height"});
                g.crop_x = number(crop, "x", 0, 0, 1, cropPath);
                g.crop_y = number(crop, "y", 0, 0, 1, cropPath);
                g.crop_width = number(crop, "width", 1, std::numeric_limits<float>::min(), 1, cropPath);
                g.crop_height = number(crop, "height", 1, std::numeric_limits<float>::min(), 1, cropPath);
                if (double(g.crop_x) + g.crop_width > 1 + 1e-6 ||
                    double(g.crop_y) + g.crop_height > 1 + 1e-6 ||
                    g.crop_x >= 1 || g.crop_y >= 1)
                    throw std::invalid_argument(cropPath + " must fit inside the normalized canvas");
                g.crop_width = std::min(g.crop_width, 1 - g.crop_x);
                g.crop_height = std::min(g.crop_height, 1 - g.crop_y);
            }
        }

        const auto& output = required(root, "output", "recipe");
        if (version >= 17)
            fields(output, "output", {"path", "format", "jpeg_quality", "size", "output_sharpening"});
        else
            fields(output, "output", {"path", "format", "jpeg_quality", "size"});
        parsed.outputPath = text(required(output, "path", "output"), "output.path");
        const auto format = text(required(output, "format", "output"), "output.format");
        if (format == "jpeg") parsed.outputFormat = RenderOutputFormat::JPEG;
        else if (format == "png") parsed.outputFormat = RenderOutputFormat::PNG;
        else if (format == "dng") parsed.outputFormat = RenderOutputFormat::DNG;
        else throw std::invalid_argument("output.format must be jpeg, png or dng");
        if (output.contains("jpeg_quality"))
            parsed.jpegQuality = integer(output.at("jpeg_quality"), 1, 100, "output.jpeg_quality");
        if (output.contains("output_sharpening")) {
            const auto os = text(output.at("output_sharpening"), "output.output_sharpening");
            if (os == "off") parsed.outputSharpening = OutputSharpening::Off;
            else if (os == "low") parsed.outputSharpening = OutputSharpening::Low;
            else if (os == "standard") parsed.outputSharpening = OutputSharpening::Standard;
            else if (os == "high") parsed.outputSharpening = OutputSharpening::High;
            else throw std::invalid_argument("output.output_sharpening must be off, low, standard or high");
        }
        if (output.contains("size")) {
            const auto& size = output.at("size");
            fields(size, "output.size", {"mode", "long_edge"});
            const auto sizeMode = text(required(size, "mode", "output.size"), "output.size.mode");
            if (sizeMode == "limit_long_edge")
                parsed.outputLongEdge = integer(required(size, "long_edge", "output.size"), 1,
                    std::numeric_limits<uint32_t>::max(), "output.size.long_edge");
            else if (sizeMode != "native")
                throw std::invalid_argument("output.size.mode must be native or limit_long_edge");
            else if (size.contains("long_edge"))
                throw std::invalid_argument("output.size.long_edge requires limit_long_edge mode");
        }

        out = std::move(parsed);
        error.clear();
        return true;
    } catch (const Json::exception& exception) {
        error = exception.what();
    } catch (const std::invalid_argument& exception) {
        error = exception.what();
    }
    return false;
}

} // namespace sony2fuji
