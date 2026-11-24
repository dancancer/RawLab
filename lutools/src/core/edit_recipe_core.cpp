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

std::string optionalText(const Json& value, const std::string& path, bool allowEmpty) {
    if (value.is_null()) return {};
    if (!value.is_string()) throw std::invalid_argument(path + " must be a string");
    auto result = value.get<std::string>();
    if (result.find('\0') != std::string::npos)
        throw std::invalid_argument(path + " must contain no NUL");
    if (!allowEmpty && result.empty())
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

bool isLowerHex64(const std::string& value) {
    return value.size() == 64 &&
        std::all_of(value.begin(), value.end(), [](char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        });
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

void readGeometry(const Json& geometry, CanonicalEditState& parsed, bool allowPerspective) {
    const std::string geoPath = "edits.geometry";
    if (allowPerspective)
        fields(geometry, geoPath, {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten_degrees", "perspective"});
    else
        fields(geometry, geoPath, {"crop", "quarter_turns", "flip_horizontal", "flip_vertical", "straighten_degrees"});
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

void readColorGrading(const Json& grading, CanonicalEditState& parsed, bool allowV12) {
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

void readCommonEdits(const Json& edits, CanonicalEditState& parsed, bool allowV12, bool sessionMode) {
    if (edits.contains("color_grading")) {
        readColorGrading(edits.at("color_grading"), parsed, allowV12);
    }
    if (edits.contains("tone")) {
        const auto& tone = edits.at("tone");
        if (parsed.isHdr || parsed.schemaVersion >= 5)
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
    if (!parsed.isHdr && edits.contains("detail")) {
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
        if (parsed.schemaVersion >= 5 && !parsed.isHdr)
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
        if (sessionMode)
            fields(denoise, "edits.denoise", {"raw_level", "chroma_mode", "wavelet", "ai_denoise_blend"});
        else
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
        if (sessionMode && denoise.contains("ai_denoise_blend")) {
            parsed.aiDenoiseBlend = number(denoise, "ai_denoise_blend", 1.0f, 0.0, 1.0, "edits.denoise");
            parsed.hasAiDenoiseBlend = true;
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

void readMasterRecipeWb(const Json& master, const std::string& path, MasterRecipeWbConfig& out) {
    fields(master, path, {"active", "strength", "custom_wb", "temperature_kelvin", "tint", "uncalibrated_fallback"});
    out.active = boolean(master, "active", path) != 0;
    out.strength = number(master, "strength", 1.0f, 0.0, 2.0, path);
    out.customWb = boolean(master, "custom_wb", path) != 0;
    out.temperatureKelvin = number(master, "temperature_kelvin", 6500.0f, 2000.0, 50000.0, path);
    out.tint = number(master, "tint", 0.0f, -150.0, 150.0, path);
    if (master.contains("uncalibrated_fallback")) {
        const auto policy = text(master.at("uncalibrated_fallback"), path + ".uncalibrated_fallback");
        if (policy == "camera") {
            out.uncalibratedFallback = UncalibratedWbPolicy::FallbackCamera;
        } else if (policy == "error") {
            out.uncalibratedFallback = UncalibratedWbPolicy::Error;
        } else {
            throw std::invalid_argument(path + ".uncalibrated_fallback must be error or camera");
        }
    }
}

void readCameraDevelopment(const Json& camera, const std::string& path, bool sessionMode, CanonicalHdrSettings& hdr) {
    if (sessionMode) {
        fields(camera, path, {
            "version", "white_balance_mode", "wb_mode", "temperature", "tint",
            "exposure_reference", "sensor_exposure", "fbdd_level",
            "lens_flags", "lens_distortion", "lens_tca", "lens_vignetting", "lens_auto_crop",
            "lens_profile", "lens_profile_id",
            "camera_profile", "camera_profile_path", "camera_profile_sha256",
            "use_ai", "processing_version"
        });
    } else {
        fields(camera, path, {
            "version", "white_balance_mode", "temperature", "tint", "exposure_reference", "fbdd_level",
            "lens_distortion", "lens_tca", "lens_vignetting", "lens_auto_crop", "lens_profile", "camera_profile"
        });
    }

    auto& config = hdr.cameraDevelopment;
    if (camera.contains("version")) {
        integer(camera.at("version"), 1, 1, path + ".version");
    }

    if (camera.contains("white_balance_mode") || (sessionMode && camera.contains("wb_mode"))) {
        if (camera.contains("white_balance_mode") && camera.contains("wb_mode")) {
            throw std::invalid_argument(path + " cannot specify both white_balance_mode and wb_mode");
        }
        const auto& modeVal = camera.contains("wb_mode") ? camera.at("wb_mode") : camera.at("white_balance_mode");
        const auto modeKey = camera.contains("wb_mode") ? ".wb_mode" : ".white_balance_mode";
        const auto mode = text(modeVal, path + modeKey);
        if (mode == "temperature") config.whiteBalance = CameraDevelopmentWbMode::Temperature;
        else if (mode == "as_shot" || (sessionMode && mode == "camera")) config.whiteBalance = CameraDevelopmentWbMode::AsShot;
        else throw std::invalid_argument(path + modeKey + " must be as_shot or temperature");
    }

    const bool temperatureWb = config.whiteBalance == CameraDevelopmentWbMode::Temperature;
    if (sessionMode && !temperatureWb) {
        config.temperature = number(camera, "temperature", 0.0f, 0.0, 50000.0, path);
        if (config.temperature > 0.0f && config.temperature < 2000.0f) {
            throw std::invalid_argument(path + ".temperature is out of range");
        }
        config.tint = number(camera, "tint", 0.0f, -150.0, 150.0, path);
    } else {
        config.temperature = number(camera, "temperature", temperatureWb ? 6500.0f : 0.0f,
                                    temperatureWb ? 2000.0 : 0.0, temperatureWb ? 50000.0 : 0.0, path);
        config.tint = number(camera, "tint", 0.0f, temperatureWb ? -150.0 : 0.0, temperatureWb ? 150.0 : 0.0, path);
    }

    if (camera.contains("exposure_reference") || (sessionMode && camera.contains("sensor_exposure"))) {
        if (camera.contains("exposure_reference") && camera.contains("sensor_exposure")) {
            throw std::invalid_argument(path + " cannot specify both exposure_reference and sensor_exposure");
        }
        if (camera.contains("exposure_reference")) {
            const auto reference = text(camera.at("exposure_reference"), path + ".exposure_reference");
            if (reference == "sensor") config.exposureReference = CameraDevelopmentExposureRef::Sensor;
            else if (reference == "metadata") config.exposureReference = CameraDevelopmentExposureRef::Metadata;
            else throw std::invalid_argument(path + ".exposure_reference must be metadata or sensor");
        } else {
            config.exposureReference = boolean(camera, "sensor_exposure", path) != 0
                ? CameraDevelopmentExposureRef::Sensor
                : CameraDevelopmentExposureRef::Metadata;
        }
    }

    if (camera.contains("fbdd_level")) {
        config.fbddLevel = integer(camera.at("fbdd_level"), 0, 2, path + ".fbdd_level");
    }

    const bool hasIndividualLensFlags = camera.contains("lens_distortion") || camera.contains("lens_tca") ||
                                        camera.contains("lens_vignetting") || camera.contains("lens_auto_crop");
    if (sessionMode && camera.contains("lens_flags")) {
        if (hasIndividualLensFlags) {
            throw std::invalid_argument(path + " cannot mix lens_flags with boolean lens_* keys");
        }
        const uint32_t flags = integer(camera.at("lens_flags"), 0, 15, path + ".lens_flags");
        config.lensDistortion = (flags & kHdrCameraLensDistortion) != 0;
        config.lensTca = (flags & kHdrCameraLensTca) != 0;
        config.lensAutoCrop = (flags & kHdrCameraLensAutoCrop) != 0;
        config.lensVignetting = (flags & kHdrCameraLensVignetting) != 0;
    } else {
        config.lensDistortion = boolean(camera, "lens_distortion", path) != 0;
        config.lensTca = boolean(camera, "lens_tca", path) != 0;
        config.lensVignetting = boolean(camera, "lens_vignetting", path) != 0;
        config.lensAutoCrop = !camera.contains("lens_auto_crop") || boolean(camera, "lens_auto_crop", path) != 0;
    }

    if (camera.contains("lens_profile") || (sessionMode && camera.contains("lens_profile_id"))) {
        if (camera.contains("lens_profile") && camera.contains("lens_profile_id")) {
            throw std::invalid_argument(path + " cannot specify both lens_profile and lens_profile_id");
        }
        const auto& lpVal = camera.contains("lens_profile_id") ? camera.at("lens_profile_id") : camera.at("lens_profile");
        const auto lpKey = camera.contains("lens_profile_id") ? ".lens_profile_id" : ".lens_profile";
        if (!lpVal.is_null()) {
            config.lensProfileId = optionalText(lpVal, path + lpKey, sessionMode);
            if (!config.lensProfileId.empty()) {
                if ((!sessionMode && config.lensFlags() == 0) || !validProfileId(config.lensProfileId)) {
                    throw std::invalid_argument(path + lpKey + " requires active lens correction and a valid id");
                }
            }
        }
    }

    const bool hasNestedProfile = camera.contains("camera_profile") && !camera.at("camera_profile").is_null();
    const bool hasFlatProfile = sessionMode &&
        (camera.contains("camera_profile_path") || camera.contains("camera_profile_sha256"));
    if (hasNestedProfile && hasFlatProfile) {
        throw std::invalid_argument(path + " cannot mix camera_profile with camera_profile_path/sha256");
    }
    if (hasNestedProfile) {
        const auto& profile = camera.at("camera_profile");
        fields(profile, path + ".camera_profile", {"path", "sha256"});
        config.cameraProfilePath = text(required(profile, "path", path + ".camera_profile"), path + ".camera_profile.path");
        config.cameraProfileSha256 = text(required(profile, "sha256", path + ".camera_profile"), path + ".camera_profile.sha256");
        if (!isLowerHex64(config.cameraProfileSha256)) {
            throw std::invalid_argument(path + ".camera_profile.sha256 must be a lowercase SHA-256 digest");
        }
    } else if (hasFlatProfile) {
        if (camera.contains("camera_profile_path")) {
            config.cameraProfilePath = optionalText(camera.at("camera_profile_path"), path + ".camera_profile_path", true);
        }
        if (camera.contains("camera_profile_sha256")) {
            config.cameraProfileSha256 = optionalText(camera.at("camera_profile_sha256"), path + ".camera_profile_sha256", true);
        }
        if (!config.cameraProfilePath.empty()) {
            if (!isLowerHex64(config.cameraProfileSha256)) {
                throw std::invalid_argument(path + ".camera_profile_sha256 must be a lowercase SHA-256 digest");
            }
        } else if (!config.cameraProfileSha256.empty()) {
            throw std::invalid_argument(path + ".camera_profile_sha256 requires camera_profile_path");
        }
    }

    if (sessionMode) {
        config.useAi = boolean(camera, "use_ai", path) != 0;
        if (camera.contains("processing_version")) {
            config.hasProcessingVersion = true;
            config.processingVersion = static_cast<ProcessingVersion>(
                integer(camera.at("processing_version"), 1, 3, path + ".processing_version"));
        }
    }

    hdr.hasCameraDevelopment = true;
}

CanonicalEditState parseHdrState(
    const Json& root,
    uint32_t schema,
    bool explicitSchema,
    bool sessionMode
) {
    if (sessionMode) {
        fields(root, "recipe", {"schema_version", "processing", "input", "edits", "output", "camera_development"});
    } else {
        fields(root, "recipe", {"schema_version", "processing", "input", "edits", "output"});
    }

    CanonicalEditState parsed;
    parsed.isHdr = true;
    parsed.schemaVersion = schema;
    parsed.hdr.processingVersion = hdrProcessingVersionForSchema(schema);

    if (!sessionMode || root.contains("processing")) {
        const auto& processing = required(root, "processing", "recipe");
        fields(processing, "processing", {"family", "version", "quality"});
        if (text(required(processing, "family", "processing"), "processing.family") != "rawlab_hdr")
            throw std::invalid_argument("Unsupported processing.family for HDR");
        if (!sessionMode || processing.contains("quality")) {
            if (text(required(processing, "quality", "processing"), "processing.quality") != "standard")
                throw std::invalid_argument("Unsupported processing.quality for HDR");
        }
        const uint32_t expectedMin = explicitSchema ? parsed.hdr.processingVersion : 1u;
        const uint32_t expectedMax = explicitSchema ? parsed.hdr.processingVersion : kHdrProcessingV2GradingCurveVersion;
        parsed.hdr.processingVersion = integer(
            required(processing, "version", "processing"), expectedMin, expectedMax, "processing.version");
        if (!explicitSchema) {
            parsed.schemaVersion = schemaVersionForHdrProcessing(parsed.hdr.processingVersion);
        }
    }

    const uint32_t processingVersion = parsed.hdr.processingVersion;
    const uint32_t effectiveSchema = parsed.schemaVersion;

    if (!sessionMode || root.contains("input")) {
        const auto& input = required(root, "input", "recipe");
        if (effectiveSchema >= 14 || sessionMode)
            fields(input, "input", {"path", "type", "camera_development"});
        else
            fields(input, "input", {"path", "type"});

        if (!sessionMode) {
            parsed.inputPath = text(required(input, "path", "input"), "input.path");
            parsed.hdr.inputType = text(required(input, "type", "input"), "input.type");
        } else {
            if (input.contains("path")) {
                parsed.inputPath = optionalText(input.at("path"), "input.path", true);
            }
            if (input.contains("type")) {
                parsed.hdr.inputType = text(input.at("type"), "input.type");
            } else if (input.contains("camera_development") || root.contains("camera_development")) {
                parsed.hdr.inputType = "raw";
            }
        }
        if (parsed.hdr.inputType != "hdr_raster" &&
            !((effectiveSchema >= 14 || sessionMode) &&
              (parsed.hdr.inputType == "raw" || parsed.hdr.inputType == "proraw"))) {
            throw std::invalid_argument(effectiveSchema >= 14
                ? "input.type must be hdr_raster, raw or proraw for HDR recipes"
                : "input.type must be hdr_raster for HDR recipes");
        }
        if (input.contains("camera_development")) {
            if (parsed.hdr.inputType != "raw")
                throw std::invalid_argument("input.camera_development requires input.type raw");
            readCameraDevelopment(input.at("camera_development"), "input.camera_development", sessionMode, parsed.hdr);
        }
    }

    if (sessionMode && root.contains("camera_development")) {
        if (parsed.hdr.hasCameraDevelopment) {
            throw std::invalid_argument("Cannot specify both input.camera_development and top-level camera_development");
        }
        if (!root.contains("input") || !root.at("input").contains("type")) {
            parsed.hdr.inputType = "raw";
        } else if (parsed.hdr.inputType != "raw") {
            throw std::invalid_argument("camera_development requires input.type raw");
        }
        readCameraDevelopment(root.at("camera_development"), "camera_development", true, parsed.hdr);
    }

    if (!sessionMode || root.contains("edits")) {
        const auto& edits = required(root, "edits", "recipe");
        if (effectiveSchema >= 13)
            fields(edits, "edits", {"exposure", "white_balance", "tone", "geometry", "color", "hsl", "color_grading", "rendition", "effects", "detail", "look"});
        else if (effectiveSchema == 12)
            fields(edits, "edits", {"exposure", "white_balance", "tone", "geometry", "color", "hsl", "color_grading", "rendition", "effects", "detail"});
        else if (effectiveSchema == 11)
            fields(edits, "edits", {"exposure", "white_balance", "tone", "geometry", "color", "hsl", "color_grading", "rendition", "effects"});
        else if (effectiveSchema == 10)
            fields(edits, "edits", {"exposure", "white_balance", "tone", "geometry", "color", "hsl", "color_grading", "rendition"});
        else if (effectiveSchema == 9)
            fields(edits, "edits", {"exposure", "white_balance", "tone", "geometry", "color", "hsl", "color_grading"});
        else
            fields(edits, "edits", {"exposure", "white_balance", "tone", "geometry"});

        if (!sessionMode || edits.contains("exposure")) {
            const auto& exposure = required(edits, "exposure", "edits");
            fields(exposure, "edits.exposure", {"ev"});
            parsed.exposureEv = number(exposure, "ev", 0, -4, 4, "edits.exposure");
        }
        if (!sessionMode || edits.contains("white_balance")) {
            const auto& wb = required(edits, "white_balance", "edits");
            fields(wb, "edits.white_balance", {"mode", "relative_temperature", "relative_tint"});
            if (!sessionMode || wb.contains("mode")) {
                if (text(required(wb, "mode", "edits.white_balance"), "edits.white_balance.mode") != "relative")
                    throw std::invalid_argument("edits.white_balance.mode must be relative for HDR");
            }
            parsed.hdr.relativeTemperature = number(wb, "relative_temperature", 6500, 2000, 50000, "edits.white_balance");
            parsed.hdr.relativeTint = number(wb, "relative_tint", 0, -150, 150, "edits.white_balance");
        }
        if (effectiveSchema == 6 && edits.contains("tone")) {
            fields(edits.at("tone"), "edits.tone", {"contrast", "saturation", "highlights", "shadows"});
        }
        const bool allowV12 = effectiveSchema >= 16;
        readCommonEdits(edits, parsed, allowV12, sessionMode);
        if (edits.contains("geometry")) {
            readGeometry(edits.at("geometry"), parsed, true);
        }
        if (processingVersion < kHdrProcessingChannelCurvesVersion &&
            std::any_of(parsed.channelCurves.begin(), parsed.channelCurves.end(),
                [](const auto& curve) { return curve.mode == ToneCurveMode::Custom; })) {
            throw std::invalid_argument("HDR channel curves require schema_version 15");
        }
        if (edits.contains("look")) {
            const auto& look = edits.at("look");
            const std::string path = "edits.look";
            fields(look, path, {"path", "sha256", "strength"});
            if (!sessionMode) {
                parsed.lookPath = text(required(look, "path", path), path + ".path");
                parsed.hdr.lookSha256 = text(required(look, "sha256", path), path + ".sha256");
                if (!isLowerHex64(parsed.hdr.lookSha256)) {
                    throw std::invalid_argument(path + ".sha256 must be a lowercase SHA-256 digest");
                }
            } else {
                if (look.contains("path")) {
                    parsed.lookPath = optionalText(look.at("path"), path + ".path", true);
                }
                if (look.contains("sha256") && !look.at("sha256").is_null()) {
                    parsed.hdr.lookSha256 = optionalText(look.at("sha256"), path + ".sha256", true);
                    if (!parsed.hdr.lookSha256.empty() && !isLowerHex64(parsed.hdr.lookSha256)) {
                        throw std::invalid_argument(path + ".sha256 must be a lowercase SHA-256 digest");
                    }
                }
            }
            parsed.lookStrength = number(look, "strength", 1, 0, 2, path);
        }
        if (edits.contains("detail")) {
            const auto& detail = edits.at("detail");
            const std::string path = "edits.detail";
            fields(detail, path, {"sharpening", "clarity", "dehaze", "denoise"});
            parsed.hdr.sharpening = number(detail, "sharpening", 0, 0, 2, path);
            parsed.hdr.clarity = number(detail, "clarity", 0, -1, 1, path);
            parsed.hdr.dehaze = number(detail, "dehaze", 0, -1, 1, path);
            parsed.hdr.denoise = number(detail, "denoise", 0, 0, 1, path);
        }
        if (edits.contains("rendition")) {
            const auto& rendition = edits.at("rendition");
            const std::string path = "edits.rendition";
            fields(rendition, path, {"peak_limit_ev", "sdr_exposure_ev", "sdr_contrast", "sdr_saturation"});
            parsed.hdr.peakLimitEV = number(rendition, "peak_limit_ev", 0, 0, 6, path);
            parsed.hdr.sdrExposureEV = number(rendition, "sdr_exposure_ev", 0, -4, 4, path);
            parsed.hdr.sdrContrast = number(rendition, "sdr_contrast", 0, -1, 1, path);
            parsed.hdr.sdrSaturation = number(rendition, "sdr_saturation", 0, -1, 1, path);
        }
    }

    if (!sessionMode || root.contains("output")) {
        const auto& output = required(root, "output", "recipe");
        if (effectiveSchema >= 16)
            fields(output, "output", {"path", "format", "base_color", "jpeg_quality", "size", "output_sharpening"});
        else
            fields(output, "output", {"path", "format", "base_color", "jpeg_quality", "size"});

        if (!sessionMode) {
            parsed.outputPath = text(required(output, "path", "output"), "output.path");
        } else if (output.contains("path")) {
            parsed.outputPath = optionalText(output.at("path"), "output.path", true);
        }

        if (!sessionMode || output.contains("format")) {
            const auto format = text(required(output, "format", "output"), "output.format");
            parsed.hdr.hdrOutput = format == "hdr_jpeg";
            if (!parsed.hdr.hdrOutput && (effectiveSchema >= 14 || sessionMode)) {
                if (format == "jpeg") parsed.outputFormat = RenderOutputFormat::JPEG;
                else if (format == "png") parsed.outputFormat = RenderOutputFormat::PNG;
                else if (format == "dng") parsed.outputFormat = RenderOutputFormat::DNG;
                else throw std::invalid_argument("output.format must be hdr_jpeg, jpeg, png or dng");
            } else if (!parsed.hdr.hdrOutput) {
                throw std::invalid_argument("output.format must be hdr_jpeg for HDR recipes");
            }
        }

        if (!sessionMode || output.contains("base_color")) {
            const auto color = !parsed.hdr.hdrOutput && !output.contains("base_color") ? "srgb"
                : text(required(output, "base_color", "output"), "output.base_color");
            if (color == "srgb") parsed.hdr.baseColor = HdrBaseColor::Srgb;
            else if (color == "display_p3") parsed.hdr.baseColor = HdrBaseColor::DisplayP3;
            else throw std::invalid_argument("output.base_color must be srgb or display_p3");
        }
        if (output.contains("jpeg_quality"))
            parsed.jpegQuality = integer(output.at("jpeg_quality"), 1, 100, "output.jpeg_quality");
        if (effectiveSchema >= 16 && output.contains("output_sharpening")) {
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
            const auto mode = text(required(size, "mode", "output.size"), "output.size.mode");
            if (mode == "limit_long_edge")
                parsed.outputLongEdge = integer(required(size, "long_edge", "output.size"), 1, 65535, "output.size.long_edge");
            else if (mode != "native")
                throw std::invalid_argument("output.size.mode must be native or limit_long_edge");
            else if (size.contains("long_edge"))
                throw std::invalid_argument("output.size.long_edge requires limit_long_edge mode");
        }
    }

    return parsed;
}

CanonicalEditState parseSdrState(
    const Json& root,
    uint32_t version,
    const EditStateParseOptions& options
) {
    const bool sessionMode = options.mode == RecipeParseMode::SessionState;
    if (sessionMode) {
        fields(root, "recipe", {"schema_version", "processing", "x3f_mode", "input", "edits", "output", "master_recipe", "ai_denoise_blend"});
    } else if (version == 7 || version == 17) {
        fields(root, "recipe", {"schema_version", "processing", "x3f_mode", "input", "edits", "output"});
    } else if (version >= 5) {
        fields(root, "recipe", {"schema_version", "processing", "input", "edits", "output"});
    } else {
        fields(root, "recipe", {"schema_version", "input", "edits", "output"});
    }

    CanonicalEditState parsed;
    parsed.isHdr = false;
    parsed.schemaVersion = version;

    if ((version == 7 && !sessionMode) || (root.contains("x3f_mode") && (sessionMode || version == 7 || version == 17))) {
        const auto mode = sessionMode
            ? text(root.at("x3f_mode"), "x3f_mode")
            : text(required(root, "x3f_mode", "recipe"), "x3f_mode");
        if (mode == "normal-v1") parsed.x3fMode = X3fMode::Normal;
        else if (mode != "legacy") throw std::invalid_argument("Unsupported x3f_mode");
    }

    if (root.contains("processing") || (!sessionMode && version >= 5)) {
        const auto& processing = required(root, "processing", "recipe");
        fields(processing, "processing", {"family", "version", "quality"});
        if (text(required(processing, "family", "processing"), "processing.family") != "rawlab")
            throw std::invalid_argument("Unsupported processing.family");
        if (!sessionMode || processing.contains("quality")) {
            if (text(required(processing, "quality", "processing"), "processing.quality") != "standard")
                throw std::invalid_argument("Unsupported processing.quality");
        }
        parsed.processingVersion = static_cast<ProcessingVersion>(
            integer(required(processing, "version", "processing"), 1, 3, "processing.version"));
        parsed.wavelet.processingVersion = parsed.processingVersion;
    }

    if (!sessionMode || root.contains("input")) {
        const auto& input = required(root, "input", "recipe");
        if (version >= 4 || sessionMode) fields(input, "input", {"path", "type"});
        else fields(input, "input", {"path"});
        if (!sessionMode) {
            parsed.inputPath = text(required(input, "path", "input"), "input.path");
        } else if (input.contains("path")) {
            parsed.inputPath = optionalText(input.at("path"), "input.path", true);
        }
        if (input.contains("type")) {
            const auto type = text(input.at("type"), "input.type");
            if (type == "raster") parsed.rasterInput = true;
            else if (type != "raw") throw std::invalid_argument("input.type must be raw or raster");
        }
    }

    if (!sessionMode && version == 7 && parsed.rasterInput)
        throw std::invalid_argument("schema_version 7 requires an X3F raw input");
    if ((version == 17 || sessionMode) && parsed.rasterInput && root.contains("x3f_mode"))
        throw std::invalid_argument("x3f_mode requires a raw input");

    if (parsed.rasterInput && sessionMode) {
        parsed.exposureMode = RawExposureMode::Sensor;
    }

    const bool allowV12 = version >= 17 || sessionMode;
    if (!sessionMode || root.contains("edits")) {
        const auto& edits = required(root, "edits", "recipe");
        if (sessionMode) {
            fields(edits, "edits", {
                "exposure", "white_balance", "look", "geometry", "tone", "color",
                "color_grading", "detail", "hsl", "effects", "denoise", "lens_correction",
                "ai_denoise_blend", "master_recipe"
            });
        } else if (version == 1) {
            fields(edits, "edits", {"exposure", "white_balance", "look"});
        } else if (version < 4) {
            fields(edits, "edits", {"exposure", "white_balance", "look", "geometry"});
        } else if (version == 4) {
            fields(edits, "edits", {"exposure", "white_balance", "look", "geometry", "tone", "detail", "hsl", "effects", "denoise", "lens_correction"});
        } else {
            fields(edits, "edits", {"exposure", "white_balance", "look", "geometry", "tone", "color", "color_grading", "detail", "hsl", "effects", "denoise", "lens_correction"});
        }

        if (version >= 4 || sessionMode) {
            readCommonEdits(edits, parsed, allowV12, sessionMode);
        }

        if (!sessionMode || edits.contains("exposure")) {
            const auto& exposure = required(edits, "exposure", "edits");
            fields(exposure, "edits.exposure", {"mode", "ev", "brightness"});
            if (!sessionMode || exposure.contains("mode")) {
                const auto mode = text(required(exposure, "mode", "edits.exposure"), "edits.exposure.mode");
                if (mode == "scene") parsed.exposureMode = RawExposureMode::Scene;
                else if (mode == "preview") parsed.exposureMode = RawExposureMode::Preview;
                else if (mode == "sensor") parsed.exposureMode = RawExposureMode::Sensor;
                else throw std::invalid_argument("edits.exposure.mode must be scene, preview or sensor");
            }
            parsed.exposureEv = number(exposure, "ev", 0, -20, 20, "edits.exposure");
            parsed.brightness = number(exposure, "brightness", 1, std::numeric_limits<float>::min(),
                                       std::numeric_limits<float>::max(), "edits.exposure");
        }

        if (edits.contains("white_balance")) {
            const auto& wb = edits.at("white_balance");
            if (allowV12)
                fields(wb, "edits.white_balance", {"mode", "temperature_kelvin", "tint", "relative_temperature", "relative_tint"});
            else
                fields(wb, "edits.white_balance", {"mode", "temperature_kelvin", "tint"});
            const auto wbMode = text(required(wb, "mode", "edits.white_balance"), "edits.white_balance.mode");
            if (parsed.rasterInput) {
                if (wbMode == "none") {
                    parsed.whiteBalanceMode = RenderWhiteBalanceMode::Camera;
                } else if (allowV12 && wbMode == "relative") {
                    parsed.whiteBalanceMode = RenderWhiteBalanceMode::Relative;
                    parsed.temperatureKelvin = number(wb, "relative_temperature", 6500, 2000, 50000, "edits.white_balance");
                    parsed.tint = number(wb, "relative_tint", 0, -150, 150, "edits.white_balance");
                } else {
                    throw std::invalid_argument(allowV12
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
                } else {
                    throw std::invalid_argument("edits.white_balance.mode must be camera, auto or temperature");
                }
            }
            if (wbMode != "temperature" && (wb.contains("temperature_kelvin") || wb.contains("tint")))
                throw std::invalid_argument("Kelvin/tint require edits.white_balance.mode=temperature");
            if (wbMode != "relative" && (wb.contains("relative_temperature") || wb.contains("relative_tint")))
                throw std::invalid_argument("relative_temperature/relative_tint require edits.white_balance.mode=relative");
        }

        if (edits.contains("look")) {
            const auto& look = edits.at("look");
            fields(look, "edits.look", {"path", "strength"});
            if (!sessionMode) {
                const auto& path = required(look, "path", "edits.look");
                if (!path.is_null()) parsed.lookPath = text(path, "edits.look.path");
            } else if (look.contains("path")) {
                parsed.lookPath = optionalText(look.at("path"), "edits.look.path", true);
            }
            parsed.lookStrength = number(look, "strength", 1, 0, version >= 4 || sessionMode ? 2 : 1, "edits.look");
        }

        if (edits.contains("geometry")) {
            readGeometry(edits.at("geometry"), parsed, version != 2);
        }

        if (sessionMode && edits.contains("ai_denoise_blend")) {
            parsed.aiDenoiseBlend = number(edits, "ai_denoise_blend", 1.0f, 0.0, 1.0, "edits");
            parsed.hasAiDenoiseBlend = true;
        }
        if (sessionMode && edits.contains("master_recipe")) {
            readMasterRecipeWb(edits.at("master_recipe"), "edits.master_recipe", parsed.masterRecipe);
        }
    }

    if (sessionMode && root.contains("ai_denoise_blend")) {
        if (parsed.hasAiDenoiseBlend) {
            throw std::invalid_argument("Cannot specify both edits.ai_denoise_blend and top-level ai_denoise_blend");
        }
        parsed.aiDenoiseBlend = number(root, "ai_denoise_blend", 1.0f, 0.0, 1.0, "recipe");
        parsed.hasAiDenoiseBlend = true;
    }
    if (sessionMode && root.contains("master_recipe")) {
        if (root.contains("edits") && root.at("edits").contains("master_recipe")) {
            throw std::invalid_argument("Cannot specify both edits.master_recipe and top-level master_recipe");
        }
        readMasterRecipeWb(root.at("master_recipe"), "master_recipe", parsed.masterRecipe);
    }

    if (parsed.rasterInput) {
        const bool badExposureOrRawNr = parsed.exposureMode != RawExposureMode::Sensor || parsed.rawNoiseReduction != 0;
        const bool activeLens = parsed.lensDistortion || parsed.lensTca || parsed.lensVignetting || !parsed.lensProfileId.empty();
        if (badExposureOrRawNr || (!options.allowRasterLensCorrection && activeLens))
            throw std::invalid_argument("Raster inputs require sensor exposure mode and disabled RAW denoise/lens correction");
    }

    if (!sessionMode || root.contains("output")) {
        const auto& output = required(root, "output", "recipe");
        if (allowV12)
            fields(output, "output", {"path", "format", "jpeg_quality", "size", "output_sharpening"});
        else
            fields(output, "output", {"path", "format", "jpeg_quality", "size"});

        if (!sessionMode) {
            parsed.outputPath = text(required(output, "path", "output"), "output.path");
        } else if (output.contains("path")) {
            parsed.outputPath = optionalText(output.at("path"), "output.path", true);
        }
        if (!sessionMode || output.contains("format")) {
            const auto format = text(required(output, "format", "output"), "output.format");
            if (format == "jpeg") parsed.outputFormat = RenderOutputFormat::JPEG;
            else if (format == "png") parsed.outputFormat = RenderOutputFormat::PNG;
            else if (format == "dng") parsed.outputFormat = RenderOutputFormat::DNG;
            else throw std::invalid_argument("output.format must be jpeg, png or dng");
        }
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
    }

    return parsed;
}

} // namespace

uint32_t hdrProcessingVersionForSchema(uint32_t schema) noexcept {
    if (schema == 6) return kHdrProcessingVersion;
    if (schema >= 8 && schema <= 13) return schema - 6u;
    if (schema == 14) return kHdrProcessingLookVersion;
    if (schema == 15) return kHdrProcessingChannelCurvesVersion;
    if (schema == 16) return kHdrProcessingV2GradingCurveVersion;
    return 0;
}

uint32_t schemaVersionForHdrProcessing(uint32_t processingVersion) noexcept {
    if (processingVersion == kHdrProcessingVersion) return 6u;
    if (processingVersion >= 2u && processingVersion <= 7u) return processingVersion + 6u;
    if (processingVersion == kHdrProcessingChannelCurvesVersion) return 15u;
    if (processingVersion == kHdrProcessingV2GradingCurveVersion) return 16u;
    return 0;
}

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
    params.temperature = whiteBalanceMode == RenderWhiteBalanceMode::Camera ? 6500.0f : temperatureKelvin;
    params.tint = whiteBalanceMode == RenderWhiteBalanceMode::Camera ? 0.0f : tint;
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
    params.aiDenoiseBlend = aiDenoiseBlend;
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

CanonicalSdrRecipe CanonicalEditState::toCanonicalSdrRecipe() const {
    CanonicalSdrRecipe sdr{};
    sdr.schemaVersion = schemaVersion;
    sdr.processingVersion = processingVersion;
    sdr.x3fMode = x3fMode;
    sdr.inputPath = inputPath;
    sdr.rasterInput = rasterInput;
    sdr.outputPath = outputPath;
    sdr.lookPath = lookPath;
    sdr.exposureMode = exposureMode;
    sdr.exposureEv = exposureEv;
    sdr.brightness = brightness;
    sdr.whiteBalanceMode = whiteBalanceMode;
    sdr.temperatureKelvin = temperatureKelvin;
    sdr.tint = tint;
    sdr.lookStrength = lookStrength;
    sdr.contrast = contrast;
    sdr.saturation = saturation;
    sdr.highlights = highlights;
    sdr.shadows = shadows;
    sdr.sCurve = sCurve;
    sdr.toneCurve = toneCurve;
    sdr.channelCurves = channelCurves;
    sdr.curveApplyToLuminosity = curveApplyToLuminosity;
    sdr.parametricCurve = parametricCurve;
    sdr.toneControls = toneControls;
    sdr.atmosphere = atmosphere;
    sdr.colorGrading = colorGrading;
    sdr.sharpening = sharpening;
    sdr.rawNoiseReduction = rawNoiseReduction;
    sdr.chromaDenoise = chromaDenoise;
    sdr.wavelet = wavelet;
    sdr.hsl = hsl;
    sdr.effects = effects;
    sdr.lensDistortion = lensDistortion;
    sdr.lensTca = lensTca;
    sdr.lensVignetting = lensVignetting;
    sdr.lensAutoCrop = lensAutoCrop;
    sdr.lensProfileId = lensProfileId;
    sdr.hasAiDenoiseBlend = hasAiDenoiseBlend;
    sdr.aiDenoiseBlend = aiDenoiseBlend;
    sdr.masterRecipe = masterRecipe;
    sdr.outputFormat = outputFormat;
    sdr.jpegQuality = jpegQuality;
    sdr.outputLongEdge = outputLongEdge;
    sdr.outputSharpening = outputSharpening;
    sdr.geometry = geometry;
    return sdr;
}

RenderParams CanonicalEditState::toRenderParams() const {
    return toCanonicalSdrRecipe().toRenderParams();
}

HDRRenderOptions CanonicalEditState::toHdrRenderOptions(
    HDRQuality intent,
    uint32_t longEdge,
    bool loadLook
) const {
    if (!isHdr) {
        throw std::invalid_argument("HDR render options require an HDR CanonicalEditState");
    }
    const uint32_t ver = hdr.processingVersion;
    HDRRenderOptions o{};
    o.processingVersion = ver;
    o.exposureEV = exposureEv;
    o.temperature = hdr.relativeTemperature;
    o.tint = hdr.relativeTint;
    o.contrast = (contrast - 1.0f) * 100.0f;
    o.highlights = -highlights * 100.0f;
    o.shadows = shadows * 100.0f;
    o.saturation = (saturation - 1.0f) * 100.0f;
    o.geometry = geometry;
    o.intent = intent;
    o.longEdge = longEdge != 0 ? longEdge : outputLongEdge;
    if (ver >= kHdrProcessingToneVersion) {
        o.tone.blackPoint = toneControls.blackPoint * 100.0f;
        o.tone.whitePoint = toneControls.whitePoint * 100.0f;
        o.tone.curveStrength = sCurve * 100.0f;
        o.tone.curve = toneCurve;
    }
    if (ver >= kHdrProcessingColorVersion) {
        o.color.vibrance = toneControls.vibrance * 100.0f;
        o.color.hsl = hsl;
        o.color.grading.wheels = {{
            ColorGradingWheel{colorGrading.wheels[0].hue, colorGrading.wheels[0].saturation, 0.0f},
            ColorGradingWheel{colorGrading.wheels[1].hue, colorGrading.wheels[1].saturation, 0.0f},
            ColorGradingWheel{colorGrading.wheels[2].hue, colorGrading.wheels[2].saturation, 0.0f}
        }};
    }
    if (ver >= kHdrProcessingRenditionVersion) {
        o.rendition = {
            hdr.peakLimitEV,
            hdr.sdrExposureEV,
            hdr.sdrContrast * 100.0f,
            hdr.sdrSaturation * 100.0f
        };
    }
    if (ver >= kHdrProcessingEffectsVersion) {
        o.effects = effects;
    }
    if (ver >= kHdrProcessingDetailVersion) {
        o.detail = {hdr.sharpening, hdr.clarity, hdr.dehaze, hdr.denoise};
    }
    if (ver >= kHdrProcessingLookVersion && loadLook && !lookPath.empty()) {
        o.look = hdr::loadLookResource(lookPath.c_str(), hdr.lookSha256);
        if (o.look) {
            o.lookStrength = lookStrength;
        }
    }
    if (ver >= kHdrProcessingChannelCurvesVersion) {
        o.tone.channels = channelCurves;
    }
    if (ver >= kHdrProcessingV2GradingCurveVersion) {
        o.tone.applyToLuminosity = curveApplyToLuminosity;
        o.tone.parametric = parametricCurve;
        o.outputSharpening = outputSharpening;
        o.color.grading = colorGrading;
    }
    validateHDRRenderOptions(o);
    return o;
}

hdr::CameraRawDevelopmentSpec CanonicalEditState::toCameraRawDevSpec(
    bool preview,
    uint32_t longEdge,
    bool defaultLegacySonyCrop
) const {
    hdr::CameraRawDevelopmentSpec spec{};
    spec.preview = preview;
    spec.longEdge = longEdge;
    if (isHdr && hdr.hasCameraDevelopment) {
        const auto& dev = hdr.cameraDevelopment;
        spec.legacySonyCrop = dev.hasProcessingVersion
            ? sony2fuji::usesLegacySonyCrop(dev.processingVersion)
            : defaultLegacySonyCrop;
        spec.hasDevelopment = true;
        spec.whiteBalance = static_cast<uint32_t>(dev.whiteBalance);
        spec.exposureReference = static_cast<uint32_t>(dev.exposureReference);
        if (dev.whiteBalance == CameraDevelopmentWbMode::AsShot) {
            spec.temperature = 0.0f;
            spec.tint = 0.0f;
        } else {
            spec.temperature = dev.temperature;
            spec.tint = dev.tint;
        }
        spec.fbddLevel = dev.fbddLevel;
        spec.lensFlags = dev.lensFlags();
        spec.lensProfileId = (spec.lensFlags != 0u && !dev.lensProfileId.empty())
            ? dev.lensProfileId.c_str()
            : nullptr;
        spec.hasCameraProfile = !dev.cameraProfilePath.empty();
        spec.cameraProfilePath = spec.hasCameraProfile ? dev.cameraProfilePath.c_str() : nullptr;
        spec.cameraProfileSha256 = spec.hasCameraProfile ? dev.cameraProfileSha256.c_str() : nullptr;
        spec.useAi = dev.useAi;
    } else if (!isHdr) {
        spec.legacySonyCrop = sony2fuji::usesLegacySonyCrop(processingVersion);
    } else {
        spec.legacySonyCrop = defaultLegacySonyCrop;
    }
    return spec;
}

bool parseCanonicalEditState(
    const std::string& document,
    CanonicalEditState& out,
    std::string& error,
    const EditStateParseOptions& options
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
        if (!root.is_object()) throw std::invalid_argument("recipe must be an object");

        const bool sessionMode = options.mode == RecipeParseMode::SessionState;
        const bool explicitSchema = root.contains("schema_version");
        if (!sessionMode && !explicitSchema) {
            required(root, "schema_version", "recipe");
        }

        bool isHdrFamily = false;
        uint32_t version = 0;
        if (explicitSchema) {
            version = integer(root.at("schema_version"), 1, std::numeric_limits<uint32_t>::max(), "schema_version");
            const uint32_t hdrVer = hdrProcessingVersionForSchema(version);
            if (hdrVer != 0) {
                isHdrFamily = true;
            } else if (version != 17 && (version < 1 || version > 7)) {
                throw std::invalid_argument("Unsupported schema_version: " + std::to_string(version));
            }
        } else {
            if (root.contains("processing") && root.at("processing").is_object() &&
                root.at("processing").contains("family") && root.at("processing").at("family").is_string()) {
                const auto fam = root.at("processing").at("family").get<std::string>();
                if (fam == "rawlab_hdr") isHdrFamily = true;
                else if (fam != "rawlab") throw std::invalid_argument("Unsupported processing.family");
            } else if (sessionMode && (root.contains("camera_development") ||
                       (root.contains("input") && root.at("input").is_object() &&
                        ((root.at("input").contains("camera_development") &&
                          root.at("input").at("camera_development").is_object()) ||
                         (root.at("input").contains("type") && root.at("input").at("type") == "hdr_raster"))))) {
                isHdrFamily = true;
            }
            version = isHdrFamily ? 16u : 17u;
        }

        CanonicalEditState parsed = isHdrFamily
            ? parseHdrState(root, version, explicitSchema, sessionMode)
            : parseSdrState(root, version, options);
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

bool parseCanonicalSdrRecipe(
    const std::string& document,
    CanonicalSdrRecipe& out,
    std::string& error,
    bool allowRasterLensCorrection
) {
    CanonicalEditState state;
    if (!parseCanonicalEditState(document, state, error, {RecipeParseMode::FileRecipe, allowRasterLensCorrection})) {
        return false;
    }
    if (state.isHdr) {
        error = "Unsupported schema_version: " + std::to_string(state.schemaVersion);
        return false;
    }
    out = state.toCanonicalSdrRecipe();
    return true;
}

} // namespace sony2fuji
