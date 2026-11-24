#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "../src/core/edit_recipe_params.h"
#include "../src/core/pipeline.h"
#include <chrono>
#include <cstring>
#include <iostream>
#include <string>

namespace {

int runJsonOverheadBenchmark() {
    const std::string sdrJson = R"({
      "schema_version": 17,
      "processing": { "family": "rawlab", "version": 3, "quality": "standard" },
      "edits": {
        "exposure": { "mode": "preview", "ev": 0.25, "brightness": 1.0 },
        "white_balance": { "mode": "temperature", "temperature_kelvin": 6200, "tint": 8 },
        "tone": {
          "contrast": 1.12, "saturation": 1.08, "highlights": 0.2, "shadows": 0.15, "s_curve": 0.0,
          "black_point": 0.04, "white_point": -0.04,
          "curve": {
            "mode": "custom",
            "points": [[0.0, 0.03], [0.5, 0.55], [1.0, 0.97]],
            "apply_to_luminosity": true,
            "parametric": { "highlights": -10, "lights": 6, "darks": -4, "shadows": 8,
                            "split_shadow": 0.25, "split_midtone": 0.5, "split_highlight": 0.75 }
          }
        },
        "color": { "vibrance": 0.15 },
        "color_grading": {
          "shadows": { "hue": 215, "saturation": 20, "luminance": -5 },
          "midtones": { "hue": 40, "saturation": 12, "luminance": 4 },
          "highlights": { "hue": 55, "saturation": 15, "luminance": 6 },
          "global": { "hue": 10, "saturation": 5, "luminance": 2 },
          "blending": 65, "balance": -15
        },
        "hsl": {
          "hue": [5, 0, -4, 0, 0, 8, 0, 0],
          "saturation": [10, -5, 0, 12, 0, 0, 0, 0],
          "lightness": [0, 0, 6, 0, -8, 0, 0, 0]
        },
        "effects": { "vignette_amount": -15, "clarity": 0.12, "dehaze": 0.08 },
        "detail": { "sharpening": 0.35 },
        "ai_denoise_blend": 0.5,
        "master_recipe": { "active": true, "strength": 0.8, "custom_wb": false, "temperature_kelvin": 6500, "tint": 12, "uncalibrated_fallback": "error" },
        "geometry": { "crop": { "x": 0.05, "y": 0.05, "width": 0.9, "height": 0.9 }, "quarter_turns": 1, "straighten_degrees": 1.5 }
      }
    })";

    const std::string hdrJson = R"({
      "schema_version": 16,
      "processing": { "family": "rawlab_hdr", "version": 9, "quality": "standard" },
      "camera_development": { "wb_mode": "temperature", "temperature": 5400, "tint": 10, "sensor_exposure": true, "fbdd_level": 1, "processing_version": 3 },
      "edits": {
        "exposure": { "ev": 0.4 },
        "white_balance": { "mode": "relative", "relative_temperature": 6800, "relative_tint": 8 },
        "tone": {
          "contrast": 1.1, "saturation": 1.15, "highlights": 0.25, "shadows": 0.2, "s_curve": 0.0,
          "black_point": 0.05, "white_point": -0.05,
          "curve": { "mode": "custom", "points": [[0.0, 0.03], [0.5, 0.55], [1.0, 0.97]], "apply_to_luminosity": true }
        },
        "color": { "vibrance": 0.12 },
        "color_grading": { "shadows": { "hue": 210, "saturation": 15, "luminance": -3 }, "blending": 60, "balance": 10 },
        "rendition": { "peak_limit_ev": 3.0, "sdr_exposure_ev": 0.1, "sdr_contrast": 0.05, "sdr_saturation": -0.04 },
        "detail": { "sharpening": 0.4, "clarity": 0.1, "dehaze": 0.05, "denoise": 0.0 },
        "geometry": { "crop": { "x": 0.05, "y": 0.05, "width": 0.9, "height": 0.85 }, "quarter_turns": 1 }
      }
    })";

    constexpr int kIterations = 2000;
    sony2fuji::Pipeline pipeline;
    sony2fuji::CanonicalEditState parsed;
    std::string err;

    // Warmup
    if (!sony2fuji::parseCanonicalEditState(sdrJson, parsed, err, {sony2fuji::RecipeParseMode::SessionState, true})) return 1;
    if (pipeline.applyEditState(parsed) != sony2fuji::RenderStatus::Ok) return 1;

    const auto sdrStart = std::chrono::steady_clock::now();
    for (int i = 0; i < kIterations; ++i) {
        if (!sony2fuji::parseCanonicalEditState(sdrJson, parsed, err, {sony2fuji::RecipeParseMode::SessionState, true})) return 1;
        if (pipeline.applyEditState(parsed) != sony2fuji::RenderStatus::Ok) return 1;
    }
    const double sdrTotalMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - sdrStart).count();
    const double sdrUs = (sdrTotalMs * 1000.0) / kIterations;

    const auto hdrStart = std::chrono::steady_clock::now();
    for (int i = 0; i < kIterations; ++i) {
        if (!sony2fuji::parseCanonicalEditState(hdrJson, parsed, err, {sony2fuji::RecipeParseMode::SessionState, true})) return 1;
        volatile auto opts = parsed.toHdrRenderOptions(sony2fuji::HDRQuality::Preview, 1024, false);
        (void)opts;
    }
    const double hdrTotalMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - hdrStart).count();
    const double hdrUs = (hdrTotalMs * 1000.0) / kIterations;

    // Baseline legacy C struct marshalling
    const auto structStart = std::chrono::steady_clock::now();
    volatile float sink = 0.0f;
    for (int i = 0; i < kIterations; ++i) {
        sony2fuji_request r{};
        r.version = SONY2FUJI_REQUEST_VERSION;
        r.struct_size = sizeof(r);
        r.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
        r.exposure_ev = 0.25f;
        r.brightness = 1.0f;
        r.contrast = 1.12f;
        r.saturation = 1.08f;
        sink = sink + r.exposure_ev;
    }
    const double structTotalMs = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - structStart).count();
    const double structUs = (structTotalMs * 1000.0) / kIterations;
    (void)sink;

    std::cout << "ADR D3 CanonicalEditState JSON overhead (" << kIterations << " iters):\n"
              << "  SDR parse+apply: " << sdrUs << " us/call (" << sdrTotalMs << " ms total)\n"
              << "  HDR parse+opts:  " << hdrUs << " us/call (" << hdrTotalMs << " ms total)\n"
              << "  Legacy struct:   " << structUs << " us/call (" << structTotalMs << " ms total)\n";
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    if (argc == 1 || (argc == 2 && std::strcmp(argv[1], "--json-overhead") == 0)) {
        return runJsonOverheadBenchmark();
    }
    if (argc != 3) return 2;
    for (auto mode : {SONY2FUJI_GPU_OFF, SONY2FUJI_GPU_FORCE}) {
        sony2fuji_session* session = nullptr;
        if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return 1;
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), mode};
        sony2fuji_session_set_gpu_config(session, &config);
        sony2fuji_request r{};
        r.version = SONY2FUJI_REQUEST_VERSION; r.struct_size = sizeof(r);
        r.input_type = SONY2FUJI_INPUT_RAW; r.input_path = argv[1];
        r.wb_mode = SONY2FUJI_WB_CAMERA; r.temperature = 6500;
        r.brightness = r.contrast = r.saturation = r.lut_strength = 1;
        r.intent = SONY2FUJI_INTENT_PREVIEW; r.preview_long_edge = 2000;
        r.size_mode = SONY2FUJI_SIZE_NATIVE;
        r.output_target = SONY2FUJI_TARGET_BUFFER; r.output_format = SONY2FUJI_OUTPUT_RGBA8;
        auto run = [&](const char* label, bool film) {
            r.lut_path = film ? argv[2] : nullptr;
            sony2fuji_buffer buffer{};
            const auto start = std::chrono::steady_clock::now();
            const auto status = sony2fuji_process(session, &r, &buffer);
            const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-start).count();
            std::cout << (mode == SONY2FUJI_GPU_OFF ? "CPU " : "Metal ") << label << ' '
                      << ms << " ms status=" << status << " backend="
                      << sony2fuji_session_get_last_backend(session) << std::endl;
            sony2fuji_release_buffer(&buffer);
            if (status != SONY2FUJI_STATUS_OK) std::exit(1);
        };
        run("cold-neutral", false); run("first-film", true);
        for (int i=0; i<3; ++i) {
            r.exposure_ev = .1f*i;
            run("cached-neutral", false); run("cached-film", true);
        }
        r.wb_mode = SONY2FUJI_WB_TEMPERATURE;
        r.temperature = 6000; run("exact-6000-neutral", false); run("exact-6000-film", true);
        r.temperature = 8000; run("exact-8000-neutral", false); run("exact-8000-film", true);
        sony2fuji_session_set_interactive_preview(session, 1);
        r.preview_long_edge = 1000;
        for (float kelvin : {5000.f, 7000.f, 9000.f}) {
            r.temperature = kelvin;
            run("interactive-WB-neutral", false); run("interactive-WB-film", true);
        }
        sony2fuji_session_set_interactive_preview(session, 0);
        r.preview_long_edge = 2000;
        run("release-exact-neutral", false); run("release-exact-film", true);
        sony2fuji_session_destroy(session);
    }
}
