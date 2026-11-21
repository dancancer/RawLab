#include "test_harness.h"
#include "sony2fuji/edit_recipe.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Json = nlohmann::json;
using rawlab::test::checkPass;
using rawlab::test::requirePass;

struct RenderedImage {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> rgb;
    sony2fuji_render_backend backend = SONY2FUJI_BACKEND_CPU;
    sony2fuji_lens_report_v2 lensReport{};
    bool hasLensReport = false;
};

struct ImageMetrics {
    uint32_t width = 0;
    uint32_t height = 0;
    std::string fnv1a64;
    std::array<double, 3> meanDn{};
    std::array<double, 3> rmsDn{};
    std::array<std::array<double, 3>, 16> blockMeanDn{};
    std::vector<std::array<uint32_t, 2>> sampleCoords;
    std::vector<std::array<int, 3>> sampleRgb;
};

std::string fnv1aHex(const std::vector<uint8_t>& bytes) {
    uint64_t hash = 14695981039346656037ULL;
    for (uint8_t byte : bytes) {
        hash ^= byte;
        hash *= 1099511628211ULL;
    }
    std::ostringstream out;
    out << "0x" << std::hex << std::setw(16) << std::setfill('0') << hash;
    return out.str();
}

std::vector<std::array<uint32_t, 2>> buildSampleCoords(uint32_t width, uint32_t height) {
    std::vector<std::array<uint32_t, 2>> coords;
    coords.reserve(16);
    for (uint32_t gy = 0; gy < 4; ++gy) {
        for (uint32_t gx = 0; gx < 4; ++gx) {
            const uint32_t x = std::min(width - 1, (gx * 2 + 1) * width / 8);
            const uint32_t y = std::min(height - 1, (gy * 2 + 1) * height / 8);
            coords.push_back({x, y});
        }
    }
    return coords;
}

ImageMetrics computeMetrics(const RenderedImage& image) {
    ImageMetrics metrics;
    metrics.width = image.width;
    metrics.height = image.height;
    metrics.fnv1a64 = fnv1aHex(image.rgb);

    const size_t pixelCount = static_cast<size_t>(image.width) * image.height;
    std::array<double, 3> sum{};
    std::array<double, 3> sumSq{};
    std::array<std::array<double, 3>, 16> blockSum{};
    std::array<size_t, 16> blockCount{};

    for (uint32_t y = 0; y < image.height; ++y) {
        const uint32_t by = std::min<uint32_t>(3, (y * 4) / image.height);
        for (uint32_t x = 0; x < image.width; ++x) {
            const uint32_t bx = std::min<uint32_t>(3, (x * 4) / image.width);
            const size_t blockIdx = static_cast<size_t>(by) * 4 + bx;
            const size_t idx = (static_cast<size_t>(y) * image.width + x) * 3;
            ++blockCount[blockIdx];
            for (size_t c = 0; c < 3; ++c) {
                const double val = static_cast<double>(image.rgb[idx + c]);
                sum[c] += val;
                sumSq[c] += val * val;
                blockSum[blockIdx][c] += val;
            }
        }
    }

    for (size_t c = 0; c < 3; ++c) {
        metrics.meanDn[c] = sum[c] / static_cast<double>(pixelCount);
        metrics.rmsDn[c] = std::sqrt(sumSq[c] / static_cast<double>(pixelCount));
    }
    for (size_t b = 0; b < 16; ++b) {
        const double denom = static_cast<double>(std::max<size_t>(1, blockCount[b]));
        for (size_t c = 0; c < 3; ++c) {
            metrics.blockMeanDn[b][c] = blockSum[b][c] / denom;
        }
    }

    metrics.sampleCoords = buildSampleCoords(image.width, image.height);
    metrics.sampleRgb.reserve(metrics.sampleCoords.size());
    for (const auto& coord : metrics.sampleCoords) {
        const size_t idx = (static_cast<size_t>(coord[1]) * image.width + coord[0]) * 3;
        metrics.sampleRgb.push_back({
            static_cast<int>(image.rgb[idx]),
            static_cast<int>(image.rgb[idx + 1]),
            static_cast<int>(image.rgb[idx + 2]),
        });
    }
    return metrics;
}

bool requirementsSatisfied(const Json& reqs) {
    for (const auto& item : reqs) {
        const auto name = item.get<std::string>();
        if (name == "lensfun") {
#ifndef SONY2FUJI_ENABLE_LENSFUN
            return false;
#endif
        } else if (name == "chroma") {
#ifndef SONY2FUJI_ENABLE_CHROMA_DENOISE
            return false;
#endif
        } else if (name == "wavelet") {
#ifndef SONY2FUJI_ENABLE_WAVELET_DENOISE
            return false;
#endif
        } else {
            throw std::runtime_error("Unknown fixture requirement: " + name);
        }
    }
    return true;
}

bool hasBackend(const Json& backends, const std::string& target) {
    for (const auto& item : backends) {
        if (item.get<std::string>() == target) return true;
    }
    return false;
}

sony2fuji::EditRecipe parseAndResolveRecipe(
    const Json& caseEntry,
    const std::filesystem::path& fixtureDir
) {
    const std::string doc = caseEntry.at("recipe").dump();
    sony2fuji::EditRecipe recipe;
    std::string error;
    requirePass(sony2fuji::parseEditRecipe(doc, recipe, error),
        caseEntry.at("name").get<std::string>() + " parseEditRecipe (" + error + ")");

    // Verify serialization round-trip preserves recipe semantics.
    const std::string normalized = sony2fuji::serializeEditRecipe(recipe);
    sony2fuji::EditRecipe roundTripped;
    std::string rtError;
    requirePass(sony2fuji::parseEditRecipe(normalized, roundTripped, rtError),
        caseEntry.at("name").get<std::string>() + " serialize/parse round-trip");
    requirePass(sony2fuji::serializeEditRecipe(roundTripped) == normalized,
        caseEntry.at("name").get<std::string>() + " canonical normalization stable");

    const std::filesystem::path baseDir = std::filesystem::absolute(fixtureDir).lexically_normal();
    auto resolve = [&](std::string& value) {
        if (!value.empty()) {
            value = (baseDir / std::filesystem::u8path(value)).lexically_normal().u8string();
            requirePass(std::filesystem::u8path(value).is_absolute(),
                caseEntry.at("name").get<std::string>() + " resolved absolute path");
        }
    };
    resolve(recipe.inputPath);
    resolve(recipe.outputPath);
    resolve(recipe.lookPath);
    return recipe;
}

sony2fuji_status applyLegacySessionSetters(
    sony2fuji_session* session,
    const sony2fuji::EditRecipe& recipe
) {
    sony2fuji_status status = sony2fuji_session_set_processing_version(session, recipe.processingVersion);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_x3f_mode(session, recipe.x3fMode);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_raw_exposure_mode(session, recipe.exposureMode);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_hsl(session, &recipe.hsl);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_tone_controls(session, &recipe.toneControls);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_atmosphere(session, &recipe.atmosphere);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_color_grading(session, &recipe.colorGrading);
    if (status == SONY2FUJI_STATUS_OK) {
        const sony2fuji_tone_curve_set_config curves{
            SONY2FUJI_TONE_CURVE_SET_CONFIG_VERSION,
            sizeof(curves),
            {recipe.toneCurve, recipe.channelCurves[0], recipe.channelCurves[1], recipe.channelCurves[2]}
        };
        status = sony2fuji_session_set_tone_curves(session, &curves);
    }
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_photo_effects(session, &recipe.effects);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_wavelet_denoise(session, &recipe.wavelet);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_chroma_denoise(session, recipe.chromaDenoise);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_raw_noise_reduction(session, recipe.rawNoiseReduction);

    sony2fuji_lens_correction_config_v2 lens{
        {SONY2FUJI_LENS_CORRECTION_CONFIG_V2_VERSION, sizeof(sony2fuji_lens_correction_config_v2),
         recipe.lensDistortion, recipe.lensTca, recipe.lensAutoCrop,
         recipe.lensProfileId.empty() ? nullptr : recipe.lensProfileId.c_str()},
        recipe.lensVignetting
    };
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_lens_correction_v2(session, &lens);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_geometry(session, &recipe.geometry);
    if (status == SONY2FUJI_STATUS_OK)
        status = sony2fuji_session_set_perspective(session, &recipe.perspective);
    return status;
}

sony2fuji_status executeRecipeRenderImpl(
    const sony2fuji::EditRecipe& recipe,
    const std::string& lensDbPath,
    sony2fuji_gpu_mode gpuMode,
    bool useLegacySetters,
    RenderedImage& out
) {
    sony2fuji_session* rawSession = nullptr;
    sony2fuji_status status = sony2fuji_session_create(&rawSession);
    if (status != SONY2FUJI_STATUS_OK) return status;
    const auto destroy = [](sony2fuji_session* s) { sony2fuji_session_destroy(s); };
    std::unique_ptr<sony2fuji_session, decltype(destroy)> session(rawSession, destroy);

    const sony2fuji_gpu_config gpuConfig{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpuConfig), gpuMode};
    status = sony2fuji_session_set_gpu_config(session.get(), &gpuConfig);
    if (status == SONY2FUJI_STATUS_OK && !lensDbPath.empty())
        status = sony2fuji_session_set_lens_database(session.get(), lensDbPath.c_str());
    if (status == SONY2FUJI_STATUS_OK) {
        if (useLegacySetters) {
            status = applyLegacySessionSetters(session.get(), recipe);
        } else {
            const std::string canonicalJson = sony2fuji::serializeEditRecipe(recipe);
            status = sony2fuji_apply_params(session.get(), canonicalJson.c_str());
        }
    }
    if (status != SONY2FUJI_STATUS_OK) return status;

    auto request = recipe.toRequest();
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.output_path = nullptr;

    sony2fuji_buffer displayImage{};
    const auto releaseBuf = [](sony2fuji_buffer* b) { sony2fuji_release_buffer(b); };
    std::unique_ptr<sony2fuji_buffer, decltype(releaseBuf)> displayGuard(&displayImage, releaseBuf);
    if (recipe.rasterInput) {
        status = sony2fuji_load_display_image(recipe.inputPath.c_str(), &displayImage);
        if (status != SONY2FUJI_STATUS_OK) return status;
        request.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
        request.input_path = nullptr;
        request.input_pixels = displayImage.data;
        request.input_width = displayImage.width;
        request.input_height = displayImage.height;
        request.input_pixel_format = displayImage.pixel_format;
        request.input_color_space = SONY2FUJI_COLOR_SRGB;
        request.input_is_linear = 0;
    }

    sony2fuji_buffer outBuffer{};
    std::unique_ptr<sony2fuji_buffer, decltype(releaseBuf)> outGuard(&outBuffer, releaseBuf);
    status = sony2fuji_process(session.get(), &request, &outBuffer);
    if (status != SONY2FUJI_STATUS_OK) return status;
    if (!outBuffer.data || outBuffer.width == 0 || outBuffer.height == 0 ||
        outBuffer.pixel_format != SONY2FUJI_PIXEL_RGB8 ||
        outBuffer.size_bytes != static_cast<size_t>(outBuffer.width) * outBuffer.height * 3) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }

    out.width = outBuffer.width;
    out.height = outBuffer.height;
    const auto* bytes = static_cast<const uint8_t*>(outBuffer.data);
    out.rgb.assign(bytes, bytes + outBuffer.size_bytes);
    out.backend = sony2fuji_session_get_last_backend(session.get());
    if (recipe.lensDistortion || recipe.lensTca || recipe.lensVignetting) {
        out.hasLensReport =
            sony2fuji_session_get_lens_report_v2(session.get(), &out.lensReport) == SONY2FUJI_STATUS_OK;
    }
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status executeRecipeRender(
    const sony2fuji::EditRecipe& recipe,
    const std::string& lensDbPath,
    sony2fuji_gpu_mode gpuMode,
    RenderedImage& out
) {
    return executeRecipeRenderImpl(recipe, lensDbPath, gpuMode, false, out);
}

sony2fuji_status executeRecipeRenderLegacySetters(
    const sony2fuji::EditRecipe& recipe,
    const std::string& lensDbPath,
    sony2fuji_gpu_mode gpuMode,
    RenderedImage& out
) {
    return executeRecipeRenderImpl(recipe, lensDbPath, gpuMode, true, out);
}

void verifyAgainstGolden(
    const std::string& label,
    const ImageMetrics& actual,
    const Json& expected,
    double meanTolerance,
    double blockTolerance,
    int sampleTolerance
) {
    checkPass(actual.width == expected.at("width").get<uint32_t>() &&
              actual.height == expected.at("height").get<uint32_t>(),
        label + " output dimensions (" + std::to_string(actual.width) + "x" + std::to_string(actual.height) + ")");

    double maxMeanDiff = 0.0;
    double maxRmsDiff = 0.0;
    for (size_t c = 0; c < 3; ++c) {
        maxMeanDiff = std::max(maxMeanDiff, std::abs(actual.meanDn[c] - expected.at("mean_dn")[c].get<double>()));
        maxRmsDiff = std::max(maxRmsDiff, std::abs(actual.rmsDn[c] - expected.at("rms_dn")[c].get<double>()));
    }
    checkPass(maxMeanDiff <= meanTolerance,
        label + " whole-image mean_dn within " + std::to_string(meanTolerance) +
        " (max diff=" + std::to_string(maxMeanDiff) + ")");
    checkPass(maxRmsDiff <= meanTolerance,
        label + " whole-image rms_dn within " + std::to_string(meanTolerance) +
        " (max diff=" + std::to_string(maxRmsDiff) + ")");

    double maxBlockDiff = 0.0;
    const auto& expBlocks = expected.at("block_mean_dn");
    requirePass(expBlocks.size() == 16, label + " golden has 16 spatial blocks");
    for (size_t b = 0; b < 16; ++b) {
        for (size_t c = 0; c < 3; ++c) {
            maxBlockDiff = std::max(maxBlockDiff,
                std::abs(actual.blockMeanDn[b][c] - expBlocks[b][c].get<double>()));
        }
    }
    checkPass(maxBlockDiff <= blockTolerance,
        label + " 4x4 block_mean_dn within " + std::to_string(blockTolerance) +
        " (max diff=" + std::to_string(maxBlockDiff) + ")");

    const auto& expCoords = expected.at("sample_coords");
    const auto& expSamples = expected.at("sample_rgb");
    requirePass(expCoords.size() == actual.sampleCoords.size() && expSamples.size() == actual.sampleRgb.size(),
        label + " sample count matches");
    int maxSampleDiff = 0;
    for (size_t i = 0; i < actual.sampleCoords.size(); ++i) {
        requirePass(actual.sampleCoords[i][0] == expCoords[i][0].get<uint32_t>() &&
                    actual.sampleCoords[i][1] == expCoords[i][1].get<uint32_t>(),
            label + " sample coord match");
        for (size_t c = 0; c < 3; ++c) {
            maxSampleDiff = std::max(maxSampleDiff,
                std::abs(actual.sampleRgb[i][c] - expSamples[i][c].get<int>()));
        }
    }
    checkPass(maxSampleDiff <= sampleTolerance,
        label + " 16 sample pixels within " + std::to_string(sampleTolerance) +
        " DN (max diff=" + std::to_string(maxSampleDiff) + ")");
}

int runCpuTests(const std::filesystem::path& fixtureDir) {
    const auto manifestPath = fixtureDir / "edit-pixel-goldens-v1.json";
    std::ifstream in(manifestPath);
    requirePass(static_cast<bool>(in), "open edit-pixel-goldens-v1.json");
    const Json doc = Json::parse(in);

    size_t executedCases = 0;
    for (const auto& entry : doc.at("cases")) {
        const auto name = entry.at("name").get<std::string>();
        if (!requirementsSatisfied(entry.at("requires"))) {
            std::cout << "INFO skipping optional-feature case " << name << '\n';
            continue;
        }
        if (!hasBackend(entry.at("backends"), "cpu")) continue;
        ++executedCases;

        const auto recipe = parseAndResolveRecipe(entry, fixtureDir);
        const std::string lensDb = entry.contains("lens_database")
            ? (fixtureDir / std::filesystem::u8path(entry.at("lens_database").get<std::string>())).lexically_normal().u8string()
            : std::string();

        RenderedImage run1, run2;
        requirePass(executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_OFF, run1) == SONY2FUJI_STATUS_OK,
            name + " CPU render 1 succeeds");
        requirePass(run1.backend == SONY2FUJI_BACKEND_CPU, name + " reports CPU backend");
        requirePass(executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_OFF, run2) == SONY2FUJI_STATUS_OK,
            name + " CPU render 2 succeeds");
        const auto m1 = computeMetrics(run1);
        const auto m2 = computeMetrics(run2);
        checkPass(m1.fnv1a64 == m2.fnv1a64 && run1.rgb == run2.rgb,
            name + " CPU run-to-run bit-exact reproducibility (" + m1.fnv1a64 + ")");

        // Keep one-for-one parity between production sony2fuji_apply_params and frozen legacy setters
        // so both the canonical JSON apply path and the W2-2 compatibility wrappers stay guarded.
        RenderedImage legacyRun;
        requirePass(executeRecipeRenderLegacySetters(recipe, lensDb, SONY2FUJI_GPU_OFF, legacyRun) == SONY2FUJI_STATUS_OK,
            name + " CPU legacy setter parity render succeeds");
        requirePass(legacyRun.backend == SONY2FUJI_BACKEND_CPU,
            name + " CPU legacy setter parity reports CPU backend");
        checkPass(legacyRun.width == run1.width && legacyRun.height == run1.height && legacyRun.rgb == run1.rgb,
            name + " sony2fuji_apply_params matches legacy setter path byte-for-byte (" + m1.fnv1a64 + ")");

        if (name == "raw_v4_lens_correction") {
            checkPass(run1.hasLensReport && run1.lensReport.base.state == SONY2FUJI_LENS_MATCHED &&
                      run1.lensReport.base.applied_distortion == 1,
                name + " applied matched Lensfun profile");
        }

        // On CPU-only recipes (no "metal" backend), verify GPU_AUTO falls back to identical CPU pixels
        // and GPU_FORCE explicitly rejects instead of silently succeeding on CPU.
        if (!hasBackend(entry.at("backends"), "metal")) {
            RenderedImage autoRun;
            requirePass(executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_AUTO, autoRun) == SONY2FUJI_STATUS_OK,
                name + " GPU Auto fallback succeeds");
            checkPass(autoRun.backend == SONY2FUJI_BACKEND_CPU && autoRun.rgb == run1.rgb,
                name + " GPU Auto falls back to bit-identical CPU output");

            RenderedImage forceRun;
            const auto forceStatus = executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_FORCE, forceRun);
            checkPass(forceStatus == SONY2FUJI_STATUS_UNSUPPORTED,
                name + " GPU Force rejects CPU-only stage with UNSUPPORTED");
        }

        verifyAgainstGolden(name + " [CPU]", m1, entry.at("cpu"), 0.05, 0.15, 1);
    }
    checkPass(executedCases >= 6, "executed core CPU Edit-JSON golden cases");
    return rawlab::test::exitCode();
}

int runMetalTests(const std::filesystem::path& fixtureDir) {
#ifndef SONY2FUJI_ENABLE_METAL
    std::cerr << "FAIL metal_edit_pixel_golden requires SONY2FUJI_ENABLE_METAL\n";
    return 1;
#else
    const auto manifestPath = fixtureDir / "edit-pixel-goldens-v1.json";
    std::ifstream in(manifestPath);
    requirePass(static_cast<bool>(in), "open edit-pixel-goldens-v1.json");
    const Json doc = Json::parse(in);

    size_t executedMetalCases = 0;
    for (const auto& entry : doc.at("cases")) {
        const auto name = entry.at("name").get<std::string>();
        if (!requirementsSatisfied(entry.at("requires"))) {
            std::cout << "INFO skipping optional-feature case " << name << '\n';
            continue;
        }
        const auto recipe = parseAndResolveRecipe(entry, fixtureDir);
        const std::string lensDb = entry.contains("lens_database")
            ? (fixtureDir / std::filesystem::u8path(entry.at("lens_database").get<std::string>())).lexically_normal().u8string()
            : std::string();

        if (!hasBackend(entry.at("backends"), "metal")) {
            RenderedImage forceRun;
            const auto forceStatus = executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_FORCE, forceRun);
            checkPass(forceStatus == SONY2FUJI_STATUS_UNSUPPORTED,
                name + " [Metal] Force rejects CPU-only recipe with UNSUPPORTED");
            continue;
        }

        ++executedMetalCases;
        RenderedImage metal1, metal2, cpuRef;
        requirePass(executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_FORCE, metal1) == SONY2FUJI_STATUS_OK,
            name + " [Metal] Force render 1 succeeds");
        requirePass(metal1.backend == SONY2FUJI_BACKEND_METAL,
            name + " [Metal] reports actual SONY2FUJI_BACKEND_METAL (never CPU fallback)");
        requirePass(executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_FORCE, metal2) == SONY2FUJI_STATUS_OK,
            name + " [Metal] Force render 2 succeeds");

        const auto m1 = computeMetrics(metal1);
        const auto m2 = computeMetrics(metal2);
        checkPass(m1.fnv1a64 == m2.fnv1a64 && metal1.rgb == metal2.rgb,
            name + " [Metal] run-to-run bit-exact reproducibility (" + m1.fnv1a64 + ")");

        verifyAgainstGolden(name + " [Metal]", m1, entry.at("metal"), 0.05, 0.35, 2);

        // Also verify full-image per-pixel parity against live CPU render within color-contract <= 2 DN.
        requirePass(executeRecipeRender(recipe, lensDb, SONY2FUJI_GPU_OFF, cpuRef) == SONY2FUJI_STATUS_OK,
            name + " [Metal->CPU parity] CPU reference succeeds");
        requirePass(cpuRef.rgb.size() == metal1.rgb.size(), name + " [Metal->CPU parity] buffer size matches");
        int maxPixelDiff = 0;
        for (size_t i = 0; i < metal1.rgb.size(); ++i) {
            maxPixelDiff = std::max(maxPixelDiff,
                std::abs(static_cast<int>(metal1.rgb[i]) - static_cast<int>(cpuRef.rgb[i])));
        }
        checkPass(maxPixelDiff <= 2,
            name + " [Metal->CPU parity] max per-channel diff <= 2 DN (observed=" + std::to_string(maxPixelDiff) + ")");
    }
    checkPass(executedMetalCases >= 3, "executed Metal Edit-JSON golden cases");
    return rawlab::test::exitCode();
#endif
}

} // namespace

int main(int argc, char** argv) {
    try {
        const std::filesystem::path fixtureDir(TEST_FIXTURE_DIR);
        if (argc == 2 && std::string(argv[1]) == "--metal") {
            return runMetalTests(fixtureDir);
        }
        if (argc == 1) {
            return runCpuTests(fixtureDir);
        }
        std::cerr << "Usage: edit_pixel_golden_tests [--metal]\n";
        return 2;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
