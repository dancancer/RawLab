#include "sony2fuji/edit_recipe.h"
#include "core/edit_recipe_params.h"
#include "core/photo_tone_curve.h"
#include "nlohmann/json.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace sony2fuji {
namespace {

using Json = nlohmann::json;

ToneCurveParametricConfig toCoreParametricCurve(const sony2fuji_tone_curve_parametric_config& src) {
    ToneCurveParametricConfig out;
    out.highlights = src.highlights;
    out.lights = src.lights;
    out.darks = src.darks;
    out.shadows = src.shadows;
    out.splitShadow = src.split_shadow;
    out.splitMidtone = src.split_midtone;
    out.splitHighlight = src.split_highlight;
    return out;
}

sony2fuji_tone_curve_parametric_config toAbiParametricCurve(const ToneCurveParametricConfig& src) {
    sony2fuji_tone_curve_parametric_config out{};
    out.version = SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION;
    out.struct_size = sizeof(out);
    out.highlights = src.highlights;
    out.lights = src.lights;
    out.darks = src.darks;
    out.shadows = src.shadows;
    out.split_shadow = src.splitShadow;
    out.split_midtone = src.splitMidtone;
    out.split_highlight = src.splitHighlight;
    out.reserved = 0;
    return out;
}

bool isDefaultParametricCurve(const sony2fuji_tone_curve_parametric_config& p) {
    return p.highlights == 0.0f && p.lights == 0.0f && p.darks == 0.0f && p.shadows == 0.0f &&
           p.split_shadow == 0.25f && p.split_midtone == 0.50f && p.split_highlight == 0.75f;
}

bool validAbiParametricCurve(const sony2fuji_tone_curve_parametric_config& p) {
    return p.version == SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION &&
           p.struct_size == sizeof(p) &&
           p.reserved == 0 &&
           toCoreParametricCurve(p).valid();
}

sony2fuji_tone_curve_config toAbiToneCurve(const ToneCurveConfig& src) {
    sony2fuji_tone_curve_config out{};
    out.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
    out.struct_size = sizeof(out);
    out.mode = src.mode == ToneCurveMode::Custom ? SONY2FUJI_CURVE_CUSTOM : SONY2FUJI_CURVE_LEGACY;
    out.count = src.count;
    for (uint32_t i = 0; i < std::min(src.count, kToneCurveMaxPoints); ++i) {
        out.points[i] = {src.points[i].x, src.points[i].y};
    }
    return out;
}

ToneCurveConfig toCoreToneCurve(const sony2fuji_tone_curve_config& src) {
    ToneCurveConfig out;
    out.mode = src.mode == SONY2FUJI_CURVE_CUSTOM ? ToneCurveMode::Custom : ToneCurveMode::Legacy;
    out.count = src.count;
    for (uint32_t i = 0; i < std::min(src.count, kToneCurveMaxPoints); ++i) {
        out.points[i] = {src.points[i].x, src.points[i].y};
    }
    return out;
}

bool validAbiToneCurve(const sony2fuji_tone_curve_config& config, bool allowFreeEndpoints = false) {
    if (config.version != SONY2FUJI_TONE_CURVE_CONFIG_VERSION || config.struct_size != sizeof(config)) return false;
    if (config.mode != SONY2FUJI_CURVE_LEGACY && config.mode != SONY2FUJI_CURVE_CUSTOM) return false;
    return validToneCurve(toCoreToneCurve(config), allowFreeEndpoints);
}

Json writeToneCurve(const sony2fuji_tone_curve_config& curve) {
    Json points = Json::array();
    for (uint32_t i = 0; i < curve.count; ++i) points.push_back({curve.points[i].x, curve.points[i].y});
    return {{"mode", curve.mode == SONY2FUJI_CURVE_CUSTOM ? "custom" : "legacy"}, {"points", points}};
}

bool hasChannelCurves(const EditRecipe& recipe) {
    return std::any_of(recipe.channelCurves.begin(), recipe.channelCurves.end(),
        [](const auto& value) { return value.mode == SONY2FUJI_CURVE_CUSTOM; });
}

Json writeToneCurves(const EditRecipe& recipe, bool allowV12) {
    auto curve = writeToneCurve(recipe.toneCurve);
    if (hasChannelCurves(recipe)) {
        curve["channels"] = {{"red", writeToneCurve(recipe.channelCurves[0])},
            {"green", writeToneCurve(recipe.channelCurves[1])}, {"blue", writeToneCurve(recipe.channelCurves[2])}};
    }
    if (allowV12) {
        if (recipe.curveApplyToLuminosity) {
            curve["apply_to_luminosity"] = true;
        }
        if (!isDefaultParametricCurve(recipe.parametricCurve)) {
            const auto& p = recipe.parametricCurve;
            curve["parametric"] = {
                {"highlights", p.highlights},
                {"lights", p.lights},
                {"darks", p.darks},
                {"shadows", p.shadows},
                {"split_shadow", p.split_shadow},
                {"split_midtone", p.split_midtone},
                {"split_highlight", p.split_highlight}
            };
        }
    }
    return curve;
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

uint32_t hdrSchemaProcessingVersion(uint32_t schema) {
    return hdrProcessingVersionForSchema(schema);
}

sony2fuji_color_grading_v2_config effectiveGradingV2(const EditRecipe& recipe) {
    const auto& v1 = recipe.colorGrading;
    auto v2 = recipe.colorGradingV2;
    const bool v2ZonePopulated = v2.shadows_hue != 0 || v2.shadows_saturation != 0 ||
        v2.midtones_hue != 0 || v2.midtones_saturation != 0 ||
        v2.highlights_hue != 0 || v2.highlights_saturation != 0;
    const bool v1ZonePopulated = v1.shadows_hue != 0 || v1.shadows_saturation != 0 ||
        v1.midtones_hue != 0 || v1.midtones_saturation != 0 ||
        v1.highlights_hue != 0 || v1.highlights_saturation != 0;
    if (!v2ZonePopulated && v1ZonePopulated) {
        v2.shadows_hue = v1.shadows_hue;
        v2.shadows_saturation = v1.shadows_saturation;
        v2.midtones_hue = v1.midtones_hue;
        v2.midtones_saturation = v1.midtones_saturation;
        v2.highlights_hue = v1.highlights_hue;
        v2.highlights_saturation = v1.highlights_saturation;
    }
    return v2;
}

bool hasV2GradingFeatures(const sony2fuji_color_grading_v2_config& v2) {
    return v2.shadows_luminance != 0.0f || v2.midtones_luminance != 0.0f ||
           v2.highlights_luminance != 0.0f || v2.global_hue != 0.0f ||
           v2.global_saturation != 0.0f || v2.global_luminance != 0.0f ||
           v2.blending != 50.0f || v2.balance != 0.0f;
}

bool validAbiGradingV1(const sony2fuji_color_grading_config& v1) {
    if (v1.version != SONY2FUJI_COLOR_GRADING_CONFIG_VERSION || v1.struct_size != sizeof(v1)) return false;
    auto validWheel = [](float h, float s) {
        return std::isfinite(h) && h >= 0 && h < 360 &&
               std::isfinite(s) && s >= 0 && s <= 100;
    };
    return validWheel(v1.shadows_hue, v1.shadows_saturation) &&
           validWheel(v1.midtones_hue, v1.midtones_saturation) &&
           validWheel(v1.highlights_hue, v1.highlights_saturation);
}

bool validAbiGradingV2(const sony2fuji_color_grading_v2_config& v2) {
    if (v2.version != SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION || v2.struct_size != sizeof(v2)) return false;
    auto validWheel = [](float h, float s, float l) {
        return std::isfinite(h) && h >= 0 && h < 360 &&
               std::isfinite(s) && s >= 0 && s <= 100 &&
               std::isfinite(l) && l >= -100 && l <= 100;
    };
    return validWheel(v2.shadows_hue, v2.shadows_saturation, v2.shadows_luminance) &&
           validWheel(v2.midtones_hue, v2.midtones_saturation, v2.midtones_luminance) &&
           validWheel(v2.highlights_hue, v2.highlights_saturation, v2.highlights_luminance) &&
           validWheel(v2.global_hue, v2.global_saturation, v2.global_luminance) &&
           std::isfinite(v2.blending) && v2.blending >= 0 && v2.blending <= 100 &&
           std::isfinite(v2.balance) && v2.balance >= -100 && v2.balance <= 100;
}

const char* outputSharpeningName(sony2fuji_output_sharpening s) {
    switch (s) {
        case SONY2FUJI_OUTPUT_SHARPENING_OFF: return "off";
        case SONY2FUJI_OUTPUT_SHARPENING_LOW: return "low";
        case SONY2FUJI_OUTPUT_SHARPENING_STANDARD: return "standard";
        case SONY2FUJI_OUTPUT_SHARPENING_HIGH: return "high";
        default: throw std::invalid_argument("Invalid output_sharpening");
    }
}

Json writeWheel(float hue, float sat, float lum, bool allowV12) {
    Json w = {{"hue", hue}, {"saturation", sat}};
    if (allowV12 && lum != 0.0f) {
        w["luminance"] = lum;
    }
    return w;
}

Json writeGrading(const sony2fuji_color_grading_v2_config& grading, bool allowV12) {
    Json out = {
        {"shadows", writeWheel(grading.shadows_hue, grading.shadows_saturation, grading.shadows_luminance, allowV12)},
        {"midtones", writeWheel(grading.midtones_hue, grading.midtones_saturation, grading.midtones_luminance, allowV12)},
        {"highlights", writeWheel(grading.highlights_hue, grading.highlights_saturation, grading.highlights_luminance, allowV12)}
    };
    if (allowV12) {
        if (grading.global_hue != 0.0f || grading.global_saturation != 0.0f || grading.global_luminance != 0.0f) {
            out["global"] = writeWheel(grading.global_hue, grading.global_saturation, grading.global_luminance, true);
        }
        if (grading.blending != 50.0f) {
            out["blending"] = grading.blending;
        }
        if (grading.balance != 0.0f) {
            out["balance"] = grading.balance;
        }
    }
    return out;
}

Json writeEffects(const sony2fuji_photo_effects_config& fx) {
    return {{"vignette_amount", fx.vignette_amount}, {"vignette_midpoint", fx.vignette_midpoint},
        {"vignette_roundness", fx.vignette_roundness}, {"vignette_feather", fx.vignette_feather},
        {"vignette_highlights", fx.vignette_highlights}, {"grain_amount", fx.grain_amount},
        {"grain_size", fx.grain_size}, {"grain_roughness", fx.grain_roughness}};
}

std::string serializeHDR(const EditRecipe& recipe) {
    if (!recipe.hdr) throw std::invalid_argument("HDR recipe requires HDR settings");
    const auto& h = *recipe.hdr;
    const auto& g = recipe.geometry;
    const bool allowV12 = recipe.schemaVersion >= 16;
    if (!validAbiToneCurve(recipe.toneCurve, allowV12) ||
        !std::all_of(recipe.channelCurves.begin(), recipe.channelCurves.end(),
            [allowV12](const auto& c) { return validAbiToneCurve(c, allowV12); }))
        throw std::invalid_argument("Invalid HDR tone curve configuration");
    if (!validAbiParametricCurve(recipe.parametricCurve))
        throw std::invalid_argument("Invalid HDR parametric curve configuration");
    const auto gradingV2 = effectiveGradingV2(recipe);
    if (!validAbiGradingV1(recipe.colorGrading) || !validAbiGradingV2(gradingV2))
        throw std::invalid_argument("Invalid HDR color grading configuration");
    if (!allowV12 && (recipe.curveApplyToLuminosity || !isDefaultParametricCurve(recipe.parametricCurve) ||
        hasV2GradingFeatures(gradingV2) || recipe.outputSharpening != SONY2FUJI_OUTPUT_SHARPENING_OFF))
        throw std::invalid_argument("HDR v0.12 fields require schema_version 16");
    if (recipe.schemaVersion == 6 && (recipe.toneControls.black_point != 0 || recipe.toneControls.white_point != 0 ||
        recipe.sCurve != 0 || recipe.toneCurve.mode == SONY2FUJI_CURVE_CUSTOM))
        throw std::invalid_argument("HDR tone fields require schema_version 8");
    if (hasChannelCurves(recipe) && recipe.schemaVersion < 15)
        throw std::invalid_argument("HDR channel curves require schema_version 15");
    if (h.baseColor != SONY2FUJI_HDR_COLOR_SRGB && h.baseColor != SONY2FUJI_HDR_COLOR_DISPLAY_P3)
        throw std::invalid_argument("Unsupported output.base_color");
    Json size = {{"mode", "native"}};
    if (recipe.outputLongEdge) size = {{"mode", "limit_long_edge"}, {"long_edge", recipe.outputLongEdge}};
    Json result = {
        {"schema_version", recipe.schemaVersion},
        {"processing", {{"family", "rawlab_hdr"}, {"version", h.processingVersion}, {"quality", "standard"}}},
        {"input", {{"path", recipe.inputPath}, {"type", h.inputType}}},
        {"edits", {
            {"exposure", {{"ev", recipe.exposureEv}}},
            {"white_balance", {{"mode", "relative"}, {"relative_temperature", h.relativeTemperature}, {"relative_tint", h.relativeTint}}},
            {"tone", {{"contrast", recipe.contrast}, {"saturation", recipe.saturation}, {"highlights", recipe.highlights}, {"shadows", recipe.shadows}}},
            {"geometry", {
                {"crop", {{"x", g.crop_x}, {"y", g.crop_y}, {"width", g.crop_width}, {"height", g.crop_height}}},
                {"quarter_turns", g.quarter_turns},
                {"flip_horizontal", g.flip_horizontal != 0},
                {"flip_vertical", g.flip_vertical != 0},
                {"straighten_degrees", g.straighten_degrees},
                {"perspective", {{"horizontal", recipe.perspective.horizontal}, {"vertical", recipe.perspective.vertical}}}
            }}
        }},
        {"output", {
            {"path", recipe.outputPath},
            {"format", h.hdrOutput ? "hdr_jpeg"
                : recipe.outputFormat == SONY2FUJI_OUTPUT_PNG ? "png"
                : recipe.outputFormat == SONY2FUJI_OUTPUT_DNG ? "dng" : "jpeg"},
            {"base_color", h.baseColor == SONY2FUJI_HDR_COLOR_SRGB ? "srgb" : "display_p3"},
            {"jpeg_quality", recipe.jpegQuality},
            {"size", size}
        }}
    };
    if (recipe.schemaVersion >= 14 && h.inputType == "raw") {
        const auto& c = h.cameraDevelopment;
        Json camera = {
            {"version", 1},
            {"white_balance_mode", c.white_balance == SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE ? "temperature" : "as_shot"},
            {"temperature", c.temperature},
            {"tint", c.tint},
            {"exposure_reference", c.exposure_reference == SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR ? "sensor" : "metadata"},
            {"fbdd_level", c.fbdd_level},
            {"lens_distortion", (c.lens_flags & SONY2FUJI_HDR_CAMERA_LENS_DISTORTION) != 0},
            {"lens_tca", (c.lens_flags & SONY2FUJI_HDR_CAMERA_LENS_TCA) != 0},
            {"lens_auto_crop", h.lensAutoCrop}
        };
        if (c.lens_flags & SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING) camera["lens_vignetting"] = true;
        if (!h.lensProfile.empty()) camera["lens_profile"] = h.lensProfile;
        if (!h.cameraProfilePath.empty()) camera["camera_profile"] = {{"path", h.cameraProfilePath}, {"sha256", h.cameraProfileSHA256}};
        result["input"]["camera_development"] = camera;
    }
    if (recipe.schemaVersion >= 8) {
        auto& tone = result["edits"]["tone"];
        tone["black_point"] = recipe.toneControls.black_point;
        tone["white_point"] = recipe.toneControls.white_point;
        tone["s_curve"] = recipe.sCurve;
        tone["curve"] = writeToneCurves(recipe, allowV12);
    }
    if (recipe.schemaVersion >= 9) {
        auto& edits = result["edits"];
        edits["color"] = {{"vibrance", recipe.toneControls.vibrance}};
        edits["hsl"] = {{"hue", recipe.hsl.hue}, {"saturation", recipe.hsl.saturation}, {"lightness", recipe.hsl.lightness}};
        edits["color_grading"] = writeGrading(gradingV2, allowV12);
    }
    if (allowV12 && recipe.outputSharpening != SONY2FUJI_OUTPUT_SHARPENING_OFF) {
        result["output"]["output_sharpening"] = outputSharpeningName(recipe.outputSharpening);
    }
    if (recipe.schemaVersion >= 10)
        result["edits"]["rendition"] = {{"peak_limit_ev", h.peakLimitEV}, {"sdr_exposure_ev", h.sdrExposureEV},
            {"sdr_contrast", h.sdrContrast}, {"sdr_saturation", h.sdrSaturation}};
    if (recipe.schemaVersion >= 11) result["edits"]["effects"] = writeEffects(recipe.effects);
    if (recipe.schemaVersion >= 12)
        result["edits"]["detail"] = {{"sharpening", h.sharpening}, {"clarity", h.clarity},
            {"dehaze", h.dehaze}, {"denoise", h.denoise}};
    if (recipe.schemaVersion >= 13 && !recipe.lookPath.empty())
        result["edits"]["look"] = {{"path", recipe.lookPath}, {"sha256", h.lookSHA256}, {"strength", recipe.lookStrength}};
    // Validate through the canonical single-source-of-truth parser.
    CanonicalEditState validated;
    std::string error;
    const std::string dumped = result.dump(2) + "\n";
    if (!parseCanonicalEditState(dumped, validated, error, {RecipeParseMode::FileRecipe, false})) {
        throw std::invalid_argument(error);
    }
    return dumped;
}

CanonicalSdrRecipe toCoreSdrRecipe(const EditRecipe& recipe) {
    CanonicalSdrRecipe core;
    core.schemaVersion = recipe.schemaVersion;
    core.processingVersion = static_cast<ProcessingVersion>(recipe.processingVersion);
    core.x3fMode = static_cast<X3fMode>(recipe.x3fMode);
    core.inputPath = recipe.inputPath;
    core.rasterInput = recipe.rasterInput;
    core.outputPath = recipe.outputPath;
    core.lookPath = recipe.lookPath;
    core.exposureMode = static_cast<RawExposureMode>(recipe.exposureMode);
    core.exposureEv = recipe.exposureEv;
    core.brightness = recipe.brightness;
    core.whiteBalanceMode = recipe.rasterRelativeWb
        ? RenderWhiteBalanceMode::Relative
        : static_cast<RenderWhiteBalanceMode>(recipe.whiteBalanceMode);
    core.temperatureKelvin = recipe.temperatureKelvin;
    core.tint = recipe.tint;
    core.lookStrength = recipe.lookStrength;
    core.contrast = recipe.contrast;
    core.saturation = recipe.saturation;
    core.highlights = recipe.highlights;
    core.shadows = recipe.shadows;
    core.sCurve = recipe.sCurve;
    core.toneCurve = toCoreToneCurve(recipe.toneCurve);
    for (size_t i = 0; i < 3; ++i) core.channelCurves[i] = toCoreToneCurve(recipe.channelCurves[i]);
    core.curveApplyToLuminosity = recipe.curveApplyToLuminosity;
    core.parametricCurve = toCoreParametricCurve(recipe.parametricCurve);
    core.toneControls = {recipe.toneControls.black_point, recipe.toneControls.white_point, recipe.toneControls.vibrance};
    core.atmosphere = {recipe.atmosphere.clarity, recipe.atmosphere.dehaze};
    const auto gradingV2 = effectiveGradingV2(recipe);
    core.colorGrading.wheels = {
        ColorGradingWheel{gradingV2.shadows_hue, gradingV2.shadows_saturation, gradingV2.shadows_luminance},
        ColorGradingWheel{gradingV2.midtones_hue, gradingV2.midtones_saturation, gradingV2.midtones_luminance},
        ColorGradingWheel{gradingV2.highlights_hue, gradingV2.highlights_saturation, gradingV2.highlights_luminance}
    };
    core.colorGrading.global = ColorGradingWheel{gradingV2.global_hue, gradingV2.global_saturation, gradingV2.global_luminance};
    core.colorGrading.blending = gradingV2.blending;
    core.colorGrading.balance = gradingV2.balance;
    core.sharpening = recipe.sharpening;
    core.rawNoiseReduction = recipe.rawNoiseReduction;
    core.chromaDenoise = recipe.chromaDenoise;
    core.wavelet = {recipe.wavelet.enabled != 0, recipe.wavelet.luma, recipe.wavelet.chroma, recipe.wavelet.coarse, core.processingVersion};
    std::copy(std::begin(recipe.hsl.hue), std::end(recipe.hsl.hue), core.hsl.hue.begin());
    std::copy(std::begin(recipe.hsl.saturation), std::end(recipe.hsl.saturation), core.hsl.saturation.begin());
    std::copy(std::begin(recipe.hsl.lightness), std::end(recipe.hsl.lightness), core.hsl.lightness.begin());
    core.effects = {
        recipe.effects.vignette_amount, recipe.effects.vignette_midpoint, recipe.effects.vignette_roundness,
        recipe.effects.vignette_feather, recipe.effects.vignette_highlights,
        recipe.effects.grain_amount, recipe.effects.grain_size, recipe.effects.grain_roughness
    };
    core.lensDistortion = recipe.lensDistortion;
    core.lensTca = recipe.lensTca;
    core.lensVignetting = recipe.lensVignetting;
    core.lensAutoCrop = recipe.lensAutoCrop;
    core.lensProfileId = recipe.lensProfileId;
    core.outputFormat = static_cast<RenderOutputFormat>(recipe.outputFormat);
    core.jpegQuality = recipe.jpegQuality;
    core.outputLongEdge = recipe.outputLongEdge;
    core.outputSharpening = static_cast<OutputSharpening>(recipe.outputSharpening);
    core.geometry = {
        recipe.geometry.crop_x, recipe.geometry.crop_y, recipe.geometry.crop_width, recipe.geometry.crop_height,
        recipe.geometry.quarter_turns, recipe.geometry.flip_horizontal != 0, recipe.geometry.flip_vertical != 0,
        recipe.geometry.straighten_degrees, recipe.perspective.horizontal, recipe.perspective.vertical
    };
    return core;
}

EditRecipe fromCoreEditState(const CanonicalEditState& core) {
    EditRecipe parsed;
    parsed.schemaVersion = core.schemaVersion;
    parsed.processingVersion = static_cast<sony2fuji_processing_version>(core.processingVersion);
    parsed.x3fMode = static_cast<sony2fuji_x3f_mode>(core.x3fMode);
    parsed.inputPath = core.inputPath;
    parsed.rasterInput = core.rasterInput;
    parsed.outputPath = core.outputPath;
    parsed.lookPath = core.lookPath;
    parsed.exposureMode = static_cast<sony2fuji_raw_exposure_mode>(core.exposureMode);
    parsed.exposureEv = core.exposureEv;
    parsed.brightness = core.brightness;
    parsed.rasterRelativeWb = core.whiteBalanceMode == RenderWhiteBalanceMode::Relative;
    parsed.whiteBalanceMode = parsed.rasterRelativeWb ? SONY2FUJI_WB_CAMERA : static_cast<sony2fuji_wb_mode>(core.whiteBalanceMode);
    parsed.temperatureKelvin = core.temperatureKelvin;
    parsed.tint = core.tint;
    parsed.lookStrength = core.lookStrength;
    parsed.contrast = core.contrast;
    parsed.saturation = core.saturation;
    parsed.highlights = core.highlights;
    parsed.shadows = core.shadows;
    parsed.sCurve = core.sCurve;
    parsed.toneCurve = toAbiToneCurve(core.toneCurve);
    for (size_t i = 0; i < 3; ++i) parsed.channelCurves[i] = toAbiToneCurve(core.channelCurves[i]);
    parsed.curveApplyToLuminosity = core.curveApplyToLuminosity;
    parsed.parametricCurve = toAbiParametricCurve(core.parametricCurve);
    parsed.toneControls = {SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(sony2fuji_tone_controls_config),
        core.toneControls.blackPoint, core.toneControls.whitePoint, core.toneControls.vibrance};
    parsed.atmosphere = {SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(sony2fuji_atmosphere_config),
        core.atmosphere.clarity, core.atmosphere.dehaze};
    parsed.colorGrading = {SONY2FUJI_COLOR_GRADING_CONFIG_VERSION, sizeof(sony2fuji_color_grading_config),
        core.colorGrading.wheels[0].hue, core.colorGrading.wheels[0].saturation,
        core.colorGrading.wheels[1].hue, core.colorGrading.wheels[1].saturation,
        core.colorGrading.wheels[2].hue, core.colorGrading.wheels[2].saturation};
    parsed.colorGradingV2 = {SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION, sizeof(sony2fuji_color_grading_v2_config),
        core.colorGrading.wheels[0].hue, core.colorGrading.wheels[0].saturation, core.colorGrading.wheels[0].luminance,
        core.colorGrading.wheels[1].hue, core.colorGrading.wheels[1].saturation, core.colorGrading.wheels[1].luminance,
        core.colorGrading.wheels[2].hue, core.colorGrading.wheels[2].saturation, core.colorGrading.wheels[2].luminance,
        core.colorGrading.global.hue, core.colorGrading.global.saturation, core.colorGrading.global.luminance,
        core.colorGrading.blending, core.colorGrading.balance};
    parsed.sharpening = core.sharpening;
    parsed.rawNoiseReduction = core.rawNoiseReduction;
    parsed.chromaDenoise = core.chromaDenoise;
    parsed.wavelet = {SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(sony2fuji_wavelet_denoise_config),
        core.wavelet.enabled ? 1 : 0, core.wavelet.luma, core.wavelet.chroma, core.wavelet.coarse};
    std::copy(core.hsl.hue.begin(), core.hsl.hue.end(), std::begin(parsed.hsl.hue));
    std::copy(core.hsl.saturation.begin(), core.hsl.saturation.end(), std::begin(parsed.hsl.saturation));
    std::copy(core.hsl.lightness.begin(), core.hsl.lightness.end(), std::begin(parsed.hsl.lightness));
    parsed.effects = {SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION, sizeof(sony2fuji_photo_effects_config),
        core.effects.vignetteAmount, core.effects.vignetteMidpoint, core.effects.vignetteRoundness,
        core.effects.vignetteFeather, core.effects.vignetteHighlights,
        core.effects.grainAmount, core.effects.grainSize, core.effects.grainRoughness};
    parsed.lensDistortion = core.lensDistortion;
    parsed.lensTca = core.lensTca;
    parsed.lensVignetting = core.lensVignetting;
    parsed.lensAutoCrop = core.lensAutoCrop;
    parsed.lensProfileId = core.lensProfileId;
    parsed.outputFormat = static_cast<sony2fuji_output_format>(core.outputFormat);
    parsed.jpegQuality = core.jpegQuality;
    parsed.outputLongEdge = core.outputLongEdge;
    parsed.outputSharpening = static_cast<sony2fuji_output_sharpening>(core.outputSharpening);
    parsed.geometry = {SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(sony2fuji_geometry_config),
        core.geometry.crop_x, core.geometry.crop_y, core.geometry.crop_width, core.geometry.crop_height,
        core.geometry.quarter_turns, core.geometry.flip_horizontal ? 1 : 0, core.geometry.flip_vertical ? 1 : 0,
        core.geometry.straighten_degrees};
    parsed.perspective = {SONY2FUJI_PERSPECTIVE_CONFIG_VERSION, sizeof(sony2fuji_perspective_config),
        core.geometry.perspective_horizontal, core.geometry.perspective_vertical};

    if (core.isHdr) {
        parsed.hdr.emplace();
        auto& h = *parsed.hdr;
        h.processingVersion = core.hdr.processingVersion;
        h.inputType = core.hdr.inputType;
        h.relativeTemperature = core.hdr.relativeTemperature;
        h.relativeTint = core.hdr.relativeTint;
        h.peakLimitEV = core.hdr.peakLimitEV;
        h.sdrExposureEV = core.hdr.sdrExposureEV;
        h.sdrContrast = core.hdr.sdrContrast;
        h.sdrSaturation = core.hdr.sdrSaturation;
        h.sharpening = core.hdr.sharpening;
        h.clarity = core.hdr.clarity;
        h.dehaze = core.hdr.dehaze;
        h.denoise = core.hdr.denoise;
        h.lookSHA256 = core.hdr.lookSha256;
        h.hdrOutput = core.hdr.hdrOutput;
        h.baseColor = static_cast<uint32_t>(core.hdr.baseColor);
        const auto& dev = core.hdr.cameraDevelopment;
        h.cameraDevelopment.version = 1;
        h.cameraDevelopment.struct_size = sizeof(h.cameraDevelopment);
        h.cameraDevelopment.white_balance = dev.whiteBalance == CameraDevelopmentWbMode::Temperature
            ? SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE
            : SONY2FUJI_HDR_CAMERA_WB_AS_SHOT;
        h.cameraDevelopment.exposure_reference = dev.exposureReference == CameraDevelopmentExposureRef::Sensor
            ? SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR
            : SONY2FUJI_HDR_CAMERA_EXPOSURE_METADATA;
        h.cameraDevelopment.temperature = dev.temperature;
        h.cameraDevelopment.tint = dev.tint;
        h.cameraDevelopment.fbdd_level = dev.fbddLevel;
        h.cameraDevelopment.lens_flags =
            (dev.lensDistortion ? SONY2FUJI_HDR_CAMERA_LENS_DISTORTION : 0u) |
            (dev.lensTca ? SONY2FUJI_HDR_CAMERA_LENS_TCA : 0u) |
            (dev.lensVignetting ? SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING : 0u);
        h.lensAutoCrop = dev.lensAutoCrop;
        if (h.cameraDevelopment.lens_flags && h.lensAutoCrop) {
            h.cameraDevelopment.lens_flags |= SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP;
        }
        h.lensProfile = dev.lensProfileId;
        h.cameraProfilePath = dev.cameraProfilePath;
        h.cameraProfileSHA256 = dev.cameraProfileSha256;
    }
    return parsed;
}

} // namespace

bool parseEditRecipe(const std::string& document, EditRecipe& recipe, std::string& error) {
    CanonicalEditState state;
    if (!parseCanonicalEditState(document, state, error, {RecipeParseMode::FileRecipe, /*allowRasterLensCorrection=*/false})) {
        return false;
    }
    recipe = fromCoreEditState(state);
    return true;
}

std::string serializeEditRecipe(const EditRecipe& recipe) {
    if (hdrSchemaProcessingVersion(recipe.schemaVersion)) return serializeHDR(recipe);
    if (recipe.hdr) throw std::invalid_argument("HDR settings require an HDR recipe schema");
    const bool allowV12 = recipe.schemaVersion >= 17;
    if (!validAbiToneCurve(recipe.toneCurve, allowV12) ||
        !std::all_of(recipe.channelCurves.begin(), recipe.channelCurves.end(),
            [allowV12](const auto& c) { return validAbiToneCurve(c, allowV12); }))
        throw std::invalid_argument("Invalid tone curve configuration");
    if (!validAbiParametricCurve(recipe.parametricCurve))
        throw std::invalid_argument("Invalid parametric curve configuration");
    if (recipe.outputSharpening < SONY2FUJI_OUTPUT_SHARPENING_OFF ||
        recipe.outputSharpening > SONY2FUJI_OUTPUT_SHARPENING_HIGH)
        throw std::invalid_argument("Invalid output_sharpening configuration");
    if (recipe.toneCurve.mode == SONY2FUJI_CURVE_CUSTOM && (recipe.schemaVersion < 5 || recipe.sCurve != 0))
        throw std::invalid_argument("Custom tone curve requires schema_version 5 and zero s_curve");
    if (hasChannelCurves(recipe) && recipe.schemaVersion < 5)
        throw std::invalid_argument("Channel curves require schema_version 5");
    if (recipe.schemaVersion != 17 && (recipe.schemaVersion < 1 || recipe.schemaVersion > 7))
        throw std::invalid_argument("Unsupported schema_version");
    if (recipe.x3fMode != SONY2FUJI_X3F_LEGACY && recipe.x3fMode != SONY2FUJI_X3F_NORMAL)
        throw std::invalid_argument("Unsupported x3f_mode");
    if (recipe.schemaVersion < 7 && recipe.x3fMode != SONY2FUJI_X3F_LEGACY)
        throw std::invalid_argument("Normal X3F rendering requires schema_version 7");
    if ((recipe.schemaVersion == 7 || recipe.schemaVersion == 17) && recipe.rasterInput &&
        recipe.x3fMode != SONY2FUJI_X3F_LEGACY)
        throw std::invalid_argument("Normal X3F rendering requires a raw input");
    if (recipe.schemaVersion == 7 && recipe.rasterInput)
        throw std::invalid_argument("schema_version 7 requires an X3F raw input");
    if (recipe.rasterRelativeWb && (!allowV12 || !recipe.rasterInput))
        throw std::invalid_argument("Raster relative white balance requires schema_version 17 and raster input");
    if (!allowV12 && (recipe.curveApplyToLuminosity || !isDefaultParametricCurve(recipe.parametricCurve) ||
        recipe.outputSharpening != SONY2FUJI_OUTPUT_SHARPENING_OFF))
        throw std::invalid_argument("SDR v0.12 fields require schema_version 17");
    if (recipe.processingVersion != SONY2FUJI_PROCESSING_LEGACY &&
        recipe.processingVersion != SONY2FUJI_PROCESSING_C5_V2 &&
        recipe.processingVersion != SONY2FUJI_PROCESSING_BASIC_V3)
        throw std::invalid_argument("Unsupported processing.version");
    if (recipe.schemaVersion < 5 && recipe.processingVersion != SONY2FUJI_PROCESSING_LEGACY)
        throw std::invalid_argument("processing.version requires schema_version 5");
    const auto& controls = recipe.toneControls;
    if (controls.version != SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION || controls.struct_size != sizeof(controls))
        throw std::invalid_argument("Invalid tone controls configuration");
    for (float value : {controls.black_point, controls.white_point, controls.vibrance})
        if (!std::isfinite(value) || std::abs(value) > 1)
            throw std::invalid_argument("Tone controls must be finite and within [-1,1]");
    if (recipe.schemaVersion < 5 && (controls.black_point != 0 || controls.white_point != 0 || controls.vibrance != 0))
        throw std::invalid_argument("Tone controls require schema_version 5");
    const auto& atmosphere = recipe.atmosphere;
    if (atmosphere.version != SONY2FUJI_ATMOSPHERE_CONFIG_VERSION || atmosphere.struct_size != sizeof(atmosphere))
        throw std::invalid_argument("Invalid atmosphere configuration");
    for (float value : {atmosphere.clarity, atmosphere.dehaze})
        if (!std::isfinite(value) || std::abs(value) > 1)
            throw std::invalid_argument("Atmosphere controls must be finite and within [-1,1]");
    if (recipe.schemaVersion < 5 && (atmosphere.clarity != 0 || atmosphere.dehaze != 0))
        throw std::invalid_argument("Atmosphere controls require schema_version 5");
    const auto& grading = recipe.colorGrading;
    if (grading.version != SONY2FUJI_COLOR_GRADING_CONFIG_VERSION || grading.struct_size != sizeof(grading))
        throw std::invalid_argument("Invalid color grading configuration");
    const auto gradingV2 = effectiveGradingV2(recipe);
    if (!validAbiGradingV1(grading) || !validAbiGradingV2(gradingV2))
        throw std::invalid_argument("Invalid color grading v2 configuration");
    if (!allowV12 && hasV2GradingFeatures(gradingV2))
        throw std::invalid_argument("Color grading v2 fields require schema_version 17");
    bool storedGrading = false;
    for (const auto wheel : {std::pair{gradingV2.shadows_hue, gradingV2.shadows_saturation},
             std::pair{gradingV2.midtones_hue, gradingV2.midtones_saturation},
             std::pair{gradingV2.highlights_hue, gradingV2.highlights_saturation},
             std::pair{gradingV2.global_hue, gradingV2.global_saturation}}) {
        storedGrading = storedGrading || wheel.first != 0 || wheel.second != 0;
    }
    storedGrading = storedGrading || (allowV12 && hasV2GradingFeatures(gradingV2));
    if (recipe.schemaVersion < 5 && storedGrading)
        throw std::invalid_argument("Color grading requires schema_version 5");
    const char* wbMode = nullptr;
    switch (recipe.whiteBalanceMode) {
        case SONY2FUJI_WB_CAMERA: wbMode = "camera"; break;
        case SONY2FUJI_WB_AUTO: wbMode = "auto"; break;
        case SONY2FUJI_WB_TEMPERATURE: wbMode = "temperature"; break;
        default: throw std::invalid_argument("Invalid white balance mode");
    }
    Json wb = {{"mode", wbMode}};
    if (recipe.rasterInput) {
        if (recipe.rasterRelativeWb) {
            if (!std::isfinite(recipe.temperatureKelvin) || recipe.temperatureKelvin < 2000 || recipe.temperatureKelvin > 50000 ||
                !std::isfinite(recipe.tint) || std::abs(recipe.tint) > 150) {
                throw std::invalid_argument("Invalid raster relative white balance");
            }
            wb = {{"mode", "relative"}, {"relative_temperature", recipe.temperatureKelvin}, {"relative_tint", recipe.tint}};
        } else {
            wb = {{"mode", "none"}};
        }
    } else if (recipe.whiteBalanceMode == SONY2FUJI_WB_TEMPERATURE) {
        wb["temperature_kelvin"] = recipe.temperatureKelvin;
        wb["tint"] = recipe.tint;
    }
    Json size = {{"mode", "native"}};
    if (recipe.outputLongEdge) size = {{"mode", "limit_long_edge"}, {"long_edge", recipe.outputLongEdge}};
    Json document = {
        {"schema_version", recipe.schemaVersion},
        {"input", {{"path", recipe.inputPath}}},
        {"edits", {
            {"exposure", {{"mode", exposureName(recipe.exposureMode)}, {"ev", recipe.exposureEv},
                          {"brightness", recipe.brightness}}},
            {"white_balance", wb},
            {"look", {{"path", recipe.lookPath.empty() ? Json(nullptr) : Json(recipe.lookPath)},
                      {"strength", recipe.lookStrength}}}
        }},
        {"output", {
            {"path", recipe.outputPath},
            {"format", formatName(recipe.outputFormat)},
            {"jpeg_quality", recipe.jpegQuality},
            {"size", size}
        }}
    };
    if (allowV12 && recipe.outputSharpening != SONY2FUJI_OUTPUT_SHARPENING_OFF) {
        document["output"]["output_sharpening"] = outputSharpeningName(recipe.outputSharpening);
    }
    if (recipe.schemaVersion >= 5)
        document["processing"] = {{"family", "rawlab"}, {"version", static_cast<int>(recipe.processingVersion)},
            {"quality", "standard"}};
    if (recipe.schemaVersion == 7 || (recipe.schemaVersion == 17 && !recipe.rasterInput && recipe.x3fMode == SONY2FUJI_X3F_NORMAL))
        document["x3f_mode"] = recipe.x3fMode == SONY2FUJI_X3F_NORMAL ? "normal-v1" : "legacy";
    if (recipe.schemaVersion >= 2) {
        const auto& geo = recipe.geometry;
        document["edits"]["geometry"] = {
            {"crop", {{"x", geo.crop_x}, {"y", geo.crop_y}, {"width", geo.crop_width}, {"height", geo.crop_height}}},
            {"quarter_turns", geo.quarter_turns},
            {"flip_horizontal", geo.flip_horizontal != 0},
            {"flip_vertical", geo.flip_vertical != 0},
            {"straighten_degrees", geo.straighten_degrees}
        };
        if (recipe.schemaVersion >= 3)
            document["edits"]["geometry"]["perspective"] = {
                {"horizontal", recipe.perspective.horizontal},
                {"vertical", recipe.perspective.vertical}
            };
    }
    if (recipe.schemaVersion >= 4) {
        document["input"]["type"] = recipe.rasterInput ? "raster" : "raw";
        auto& edits = document["edits"];
        edits["tone"] = {
            {"contrast", recipe.contrast},
            {"saturation", recipe.saturation},
            {"highlights", recipe.highlights},
            {"shadows", recipe.shadows},
            {"s_curve", recipe.sCurve}
        };
        if (recipe.schemaVersion >= 5) {
            edits["tone"]["curve"] = writeToneCurves(recipe, allowV12);
        }
        // Identity omits additive keys so existing normalized recipes stay byte-identical.
        if (controls.black_point != 0) edits["tone"]["black_point"] = controls.black_point;
        if (controls.white_point != 0) edits["tone"]["white_point"] = controls.white_point;
        if (controls.vibrance != 0) edits["color"]["vibrance"] = controls.vibrance;
        if (storedGrading) edits["color_grading"] = writeGrading(gradingV2, allowV12);
        edits["detail"] = {{"sharpening", recipe.sharpening}};
        edits["hsl"] = {{"hue", recipe.hsl.hue}, {"saturation", recipe.hsl.saturation}, {"lightness", recipe.hsl.lightness}};
        edits["effects"] = writeEffects(recipe.effects);
        if (atmosphere.clarity != 0) edits["effects"]["clarity"] = atmosphere.clarity;
        if (atmosphere.dehaze != 0) edits["effects"]["dehaze"] = atmosphere.dehaze;
        edits["denoise"] = {
            {"raw_level", recipe.rawNoiseReduction},
            {"chroma_mode", recipe.chromaDenoise},
            {"wavelet", {
                {"enabled", recipe.wavelet.enabled != 0},
                {"luma", recipe.wavelet.luma},
                {"chroma", recipe.wavelet.chroma},
                {"coarse", recipe.wavelet.coarse}
            }}
        };
        edits["lens_correction"] = {
            {"distortion", recipe.lensDistortion},
            {"tca", recipe.lensTca},
            {"auto_crop", recipe.lensAutoCrop},
            {"profile_id", recipe.lensProfileId.empty() ? Json(nullptr) : Json(recipe.lensProfileId)}
        };
        if (recipe.lensVignetting) edits["lens_correction"]["vignetting"] = true;
    }
    return document.dump(2) + "\n";
}

sony2fuji_request EditRecipe::toRequest() const {
    if (hdr || hdrSchemaProcessingVersion(schemaVersion)) throw std::invalid_argument("HDR recipes require the typed HDR request");
    const RenderParams params = toCoreSdrRecipe(*this).toRenderParams();
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = static_cast<sony2fuji_input_type>(params.inputType);
    request.input_path = inputPath.c_str();
    request.lut_path = lookPath.empty() ? nullptr : lookPath.c_str();
    request.lut_strength = params.lutStrength;
    request.wb_mode = params.wbMode == RenderWhiteBalanceMode::Relative
        ? SONY2FUJI_WB_CAMERA
        : static_cast<sony2fuji_wb_mode>(params.wbMode);
    request.exposure_ev = params.exposureEV;
    request.brightness = params.brightness;
    request.contrast = params.contrast;
    request.saturation = params.saturation;
    request.highlights = params.highlights;
    request.shadows = params.shadows;
    request.tone_curve = params.toneCurve;
    request.sharpening = params.sharpening;
    request.temperature = params.wbMode == RenderWhiteBalanceMode::Relative
        ? 6500.0f
        : params.temperature;
    request.tint = params.wbMode == RenderWhiteBalanceMode::Relative
        ? 0.0f
        : params.tint;
    request.size_mode = static_cast<sony2fuji_size_mode>(params.sizeMode);
    request.long_edge = params.longEdge;
    request.intent = static_cast<sony2fuji_intent>(params.intent);
    request.output_target = static_cast<sony2fuji_output_target>(params.outputTarget);
    request.output_path = outputPath.c_str();
    request.output_format = static_cast<sony2fuji_output_format>(params.outputFormat);
    request.jpeg_quality = params.jpegQuality;
    return request;
}

sony2fuji_hdr_request_v1 EditRecipe::toHDRRequest() const {
    if (schemaVersion != 6) throw std::invalid_argument("HDR request v1 requires schema_version 6");
    return toHDRRenderRequest().base.base.base.base.base.base.base;
}

sony2fuji_hdr_request_v8 EditRecipe::toHDRRenderRequest() const {
    const auto version = hdrSchemaProcessingVersion(schemaVersion);
    if (!version || !hdr) throw std::invalid_argument("Typed HDR request requires an HDR recipe schema");
    if (hdr->processingVersion != version) throw std::invalid_argument("HDR processing.version does not match schema_version");
    if (hasChannelCurves(*this) && version < SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION)
        throw std::invalid_argument("HDR channel curves require schema_version 15");
    sony2fuji_hdr_request_v8 extended{};
    auto& look = extended.base;
    auto& detail = look.base;
    auto& effectsRequest = detail.base;
    auto& rendition = effectsRequest.base;
    auto& color = rendition.base;
    auto& tone = color.base;
    auto& request = tone.base;
    request.version = 1;
    request.struct_size = sizeof(request);
    request.hdr_processing_version = hdr->processingVersion;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.long_edge = outputLongEdge;
    request.exposure_ev = exposureEv;
    request.temperature = hdr->relativeTemperature;
    request.tint = hdr->relativeTint;
    request.contrast = (contrast - 1) * 100;
    request.saturation = (saturation - 1) * 100;
    request.highlights = -highlights * 100;
    request.shadows = shadows * 100;
    request.crop_x = geometry.crop_x;
    request.crop_y = geometry.crop_y;
    request.crop_width = geometry.crop_width;
    request.crop_height = geometry.crop_height;
    request.quarter_turns = geometry.quarter_turns;
    request.flip_horizontal = geometry.flip_horizontal;
    request.flip_vertical = geometry.flip_vertical;
    request.straighten_degrees = geometry.straighten_degrees;
    request.perspective_horizontal = perspective.horizontal;
    request.perspective_vertical = perspective.vertical;
    if (version >= SONY2FUJI_HDR_PROCESSING_TONE_VERSION) {
        request.struct_size = sizeof(tone);
        tone.black_point = toneControls.black_point * 100;
        tone.white_point = toneControls.white_point * 100;
        tone.curve_strength = sCurve * 100;
        tone.curve = toneCurve;
    }
    if (version >= SONY2FUJI_HDR_PROCESSING_COLOR_VERSION) {
        request.struct_size = sizeof(color);
        color.vibrance = toneControls.vibrance * 100;
        color.hsl = hsl;
        color.grading = colorGrading;
    }
    if (version >= SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION) {
        request.struct_size = sizeof(rendition);
        rendition.peak_limit_ev = hdr->peakLimitEV;
        rendition.sdr_exposure_ev = hdr->sdrExposureEV;
        rendition.sdr_contrast = hdr->sdrContrast * 100;
        rendition.sdr_saturation = hdr->sdrSaturation * 100;
    }
    if (version >= SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION) {
        request.struct_size = sizeof(effectsRequest);
        effectsRequest.effects = effects;
    }
    if (version >= SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION) {
        request.struct_size = sizeof(detail);
        detail.sharpening = hdr->sharpening;
        detail.clarity = hdr->clarity;
        detail.dehaze = hdr->dehaze;
        detail.denoise = hdr->denoise;
    }
    if (version >= SONY2FUJI_HDR_PROCESSING_LOOK_VERSION) {
        request.struct_size = sizeof(look);
        if (!lookPath.empty()) {
            if (hdr->lookSHA256.size() != 64) throw std::invalid_argument("Invalid HDR look fingerprint");
            look.look_path = lookPath.c_str();
            look.look_strength = lookStrength;
            std::copy(hdr->lookSHA256.begin(), hdr->lookSHA256.end(), look.look_sha256);
        }
    }
    if (version >= SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION) {
        request.struct_size = sizeof(extended);
        std::copy(channelCurves.begin(), channelCurves.end(), extended.channels);
    }
    return extended;
}

sony2fuji_hdr_request_v9 EditRecipe::toHDRRenderRequestV9() const {
    const auto version = hdrSchemaProcessingVersion(schemaVersion);
    if (version < SONY2FUJI_HDR_PROCESSING_V2_GRADING_CURVE_VERSION || !hdr)
        throw std::invalid_argument("Typed HDR request v9 requires schema_version 16");
    sony2fuji_hdr_request_v9 v9{};
    v9.base = toHDRRenderRequest();
    auto& baseV1 = v9.base.base.base.base.base.base.base.base;
    baseV1.struct_size = sizeof(v9);
    v9.curve_apply_to_luminosity = curveApplyToLuminosity ? 1 : 0;
    v9.output_sharpening = static_cast<uint32_t>(outputSharpening);
    v9.parametric_curve = parametricCurve;
    v9.grading_v2 = effectiveGradingV2(*this);
    return v9;
}

} // namespace sony2fuji
