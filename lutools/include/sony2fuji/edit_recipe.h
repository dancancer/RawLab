#pragma once

#include "sony2fuji/ffi/sony2fuji_c.h"
#include <string>

namespace sony2fuji {

// JSON recipe versions are independent of the existing binary request v2.
// Paths are UTF-8; callers resolve relative paths against the recipe directory.
struct EditRecipe {
    uint32_t schemaVersion = 1;
    sony2fuji_processing_version processingVersion = SONY2FUJI_PROCESSING_LEGACY;
    std::string inputPath;
    bool rasterInput = false;
    std::string outputPath;
    std::string lookPath;
    // Required in JSON: never inherit a CLI, UI or session exposure default.
    sony2fuji_raw_exposure_mode exposureMode = SONY2FUJI_EXPOSURE_PREVIEW;
    float exposureEv = 0;
    float brightness = 1;
    sony2fuji_wb_mode whiteBalanceMode = SONY2FUJI_WB_CAMERA;
    float temperatureKelvin = 6500;
    float tint = 0;
    float lookStrength = 1;
    // v4 stores resolved core values, not UI percentages or preset deltas.
    float contrast = 1;
    float saturation = 1;
    float highlights = 0;
    float shadows = 0;
    float sCurve = 0;
    sony2fuji_tone_controls_config toneControls{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION,
        sizeof(sony2fuji_tone_controls_config), 0, 0, 0};
    sony2fuji_color_grading_config colorGrading{SONY2FUJI_COLOR_GRADING_CONFIG_VERSION,
        sizeof(sony2fuji_color_grading_config), 0, 0, 0, 0, 0, 0};
    float sharpening = 0;
    int32_t rawNoiseReduction = 0;
    int32_t chromaDenoise = 0;
    sony2fuji_wavelet_denoise_config wavelet{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,
        sizeof(sony2fuji_wavelet_denoise_config), 0, 0, 46, 50};
    sony2fuji_hsl_config hsl{SONY2FUJI_HSL_CONFIG_VERSION, sizeof(sony2fuji_hsl_config), {}, {}, {}};
    sony2fuji_photo_effects_config effects{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION,
        sizeof(sony2fuji_photo_effects_config), 0, 50, 0, 50, 0, 0, 25, 50};
    bool lensDistortion = false;
    bool lensTca = false;
    bool lensAutoCrop = true;
    std::string lensProfileId;
    sony2fuji_output_format outputFormat = SONY2FUJI_OUTPUT_JPEG;
    uint32_t jpegQuality = 95;
    // Zero preserves source dimensions; otherwise a no-upscale pixel ceiling.
    uint32_t outputLongEdge = 0;
    // v2: normalized crop after clockwise turns, flips and straightening.
    sony2fuji_geometry_config geometry{SONY2FUJI_GEOMETRY_CONFIG_VERSION,
        sizeof(sony2fuji_geometry_config), 0, 0, 1, 1, 0, 0, 0, 0};
    // v3: unitless centered projective coefficients, each -1..1.
    sony2fuji_perspective_config perspective{SONY2FUJI_PERSPECTIVE_CONFIG_VERSION,
        sizeof(sony2fuji_perspective_config), 0, 0};

    // String pointers borrow this recipe; keep it alive and unchanged while used.
    sony2fuji_request toRequest() const;
};

// Invalid documents leave the destination unchanged. Error includes the field.
bool parseEditRecipe(const std::string& document, EditRecipe& recipe, std::string& error);
// Emits every default, including exposure mode. Intended for validated recipes.
std::string serializeEditRecipe(const EditRecipe& recipe);

} // namespace sony2fuji
