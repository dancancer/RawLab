#include "test_harness.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "nlohmann/json.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <set>
#include <string>
#include <tuple>
#include <vector>

namespace {

using Json = nlohmann::json;
using rawlab::test::checkPass;
using rawlab::test::requirePass;

struct SessionDeleter {
    void operator()(sony2fuji_session* s) const noexcept {
        if (s) sony2fuji_session_destroy(s);
    }
};
using SessionPtr = std::unique_ptr<sony2fuji_session, SessionDeleter>;

SessionPtr makeSession(sony2fuji_gpu_mode gpuMode = SONY2FUJI_GPU_AUTO) {
    sony2fuji_session* raw = nullptr;
    requirePass(sony2fuji_session_create(&raw) == SONY2FUJI_STATUS_OK && raw != nullptr, "session_create");
    SessionPtr session(raw);
    sony2fuji_gpu_config gpu{};
    gpu.version = SONY2FUJI_GPU_CONFIG_VERSION;
    gpu.struct_size = sizeof(gpu);
    gpu.mode = gpuMode;
    requirePass(sony2fuji_session_set_gpu_config(session.get(), &gpu) == SONY2FUJI_STATUS_OK, "set_gpu_config");
    return session;
}

sony2fuji_fast_gpu_query_v1 makeFastQuery(
    const std::string& inputPath,
    sony2fuji_input_type inputType = SONY2FUJI_INPUT_RAW,
    uint32_t width = 6000,
    uint32_t height = 4000,
    uint32_t maxPixels = 28000000
) {
    sony2fuji_fast_gpu_query_v1 q{};
    q.version = SONY2FUJI_FAST_GPU_QUERY_V1_VERSION;
    q.struct_size = sizeof(q);
    q.input_type = inputType;
    q.input_width = width;
    q.input_height = height;
    q.max_pixels = maxPixels;
    q.input_path = inputPath.empty() ? nullptr : inputPath.c_str();
    return q;
}

sony2fuji_render_options_v1 makeRenderOptions(
    const std::string& inputPath
) {
    sony2fuji_render_options_v1 opts{};
    opts.version = SONY2FUJI_RENDER_OPTIONS_V1_VERSION;
    opts.struct_size = sizeof(opts);
    opts.input_type = SONY2FUJI_INPUT_RAW;
    opts.input_path = inputPath.c_str();
    opts.intent = SONY2FUJI_INTENT_PREVIEW;
    opts.size_mode = SONY2FUJI_SIZE_NATIVE;
    opts.output_target = SONY2FUJI_TARGET_BUFFER;
    opts.output_format = SONY2FUJI_OUTPUT_RGB8;
    opts.jpeg_quality = 90;
    return opts;
}

Json baseSdrStateJson(int processingVersion = 2) {
    return Json{
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", processingVersion}, {"quality", "standard"}}},
        {"x3f_mode", "legacy"},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"tone", {{"contrast", 1.0}, {"saturation", 1.0}, {"highlights", 0.0}, {"shadows", 0.0}}}
        }}
    };
}

int32_t queryFastGpu(
    sony2fuji_session* session,
    const sony2fuji_fast_gpu_query_v1& query,
    const std::string* editStateJson = nullptr
) {
    int32_t supported = -1;
    const sony2fuji_status st = sony2fuji_session_supports_fast_full_res_gpu(
        session, &query, editStateJson ? editStateJson->c_str() : nullptr, &supported);
    requirePass(st == SONY2FUJI_STATUS_OK, "supports_fast_full_res_gpu returned OK");
    return supported;
}

sony2fuji_render_backend renderAndGetBackend(
    sony2fuji_session* session,
    const std::string& rawPath,
    const std::string* editStateJson
) {
    const auto opts = makeRenderOptions(rawPath);
    sony2fuji_buffer buf{};
    const sony2fuji_status st = sony2fuji_session_render(
        session, &opts, editStateJson ? editStateJson->c_str() : nullptr, &buf, nullptr);
    sony2fuji_release_buffer(&buf);
    requirePass(st == SONY2FUJI_STATUS_OK,
                std::string("session_render succeeded (") + sony2fuji_status_message(st) + ")");
    return sony2fuji_session_get_last_backend(session);
}

void testPyramidMathAndCoverage() {
    const double baseScale = 1280.0 / 6000.0;
    int32_t level = 99;
    requirePass(sony2fuji_pyramid_level(baseScale * 1.04, baseScale, &level) == SONY2FUJI_STATUS_OK && level == -1,
                "level returns -1 below threshold");
    requirePass(sony2fuji_pyramid_level(0.25, baseScale, &level) == SONY2FUJI_STATUS_OK && level == 2,
                "level 2 at 0.25");
    requirePass(sony2fuji_pyramid_level(0.45, baseScale, &level) == SONY2FUJI_STATUS_OK && level == 1,
                "level 1 at 0.45");
    requirePass(sony2fuji_pyramid_level(1.0, baseScale, &level) == SONY2FUJI_STATUS_OK && level == 0,
                "level 0 at 1.0");
    requirePass(sony2fuji_pyramid_level(0.5, 3072.0 / 8064.0, &level) == SONY2FUJI_STATUS_OK && level == 0,
                "48MP with 3072px backing jumps to level 0 at 0.5");
    requirePass(sony2fuji_pyramid_level(0.0, baseScale, &level) == SONY2FUJI_STATUS_OK && level == -1,
                "non-positive zoom returns -1");

    // Invalid args for pyramid_level
    requirePass(sony2fuji_pyramid_level(1.0, baseScale, nullptr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "null out_level rejected");
    requirePass(sony2fuji_pyramid_level(std::numeric_limits<double>::quiet_NaN(), baseScale, &level) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "NaN zoom_scale rejected");

    // 2-call query + center distance ordering
    sony2fuji_pyramid_config_v1 cfg{};
    cfg.version = SONY2FUJI_PYRAMID_CONFIG_V1_VERSION;
    cfg.struct_size = sizeof(cfg);
    cfg.full_width = 6000;
    cfg.full_height = 4000;
    cfg.tile_size = 1024;
    cfg.overscan_ring = 0;
    cfg.zoom_scale = 1.0;
    cfg.base_scale = baseScale;
    cfg.visible_x0 = 0.40;
    cfg.visible_y0 = 0.35;
    cfg.visible_x1 = 0.60;
    cfg.visible_y1 = 0.65;

    uint32_t count = 0;
    requirePass(sony2fuji_pyramid_tiles(&cfg, nullptr, 0, &count) == SONY2FUJI_STATUS_OK && count > 0,
                "pyramid_tiles 2-call capacity query");
    std::vector<sony2fuji_pyramid_tile_v1> visibleOnly(count);
    requirePass(sony2fuji_pyramid_tiles(&cfg, visibleOnly.data(), 0, &count) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "pyramid_tiles insufficient capacity fails");
    requirePass(sony2fuji_pyramid_tiles(&cfg, nullptr, 1, &count) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "pyramid_tiles null buffer with nonzero capacity fails");
    requirePass(sony2fuji_pyramid_tiles(&cfg, visibleOnly.data(), count, &count) == SONY2FUJI_STATUS_OK,
                "pyramid_tiles fills output buffer");

    for (const auto& t : visibleOnly) {
        checkPass(t.level == 0 && t.max_output_long_edge == 1024, "center tile is level 0, 1024px");
    }
    const double visMidX = 0.5 * (cfg.visible_x0 + cfg.visible_x1);
    const double visMidY = 0.5 * (cfg.visible_y0 + cfg.visible_y1);
    const auto dist = [&](const sony2fuji_pyramid_tile_v1& t) {
        const double dx = 0.5 * (t.norm_x0 + t.norm_x1) - visMidX;
        const double dy = 0.5 * (t.norm_y0 + t.norm_y1) - visMidY;
        return std::hypot(dx, dy);
    };
    checkPass(dist(visibleOnly.front()) <= dist(visibleOnly.back()) + 1e-6, "tiles sorted by distance from visible center");

    // Trailing edge tile uses actual native edge (4000 - 3072 = 928)
    cfg.visible_x0 = 0.90;
    cfg.visible_y0 = 0.85;
    cfg.visible_x1 = 1.00;
    cfg.visible_y1 = 1.00;
    requirePass(sony2fuji_pyramid_tiles(&cfg, nullptr, 0, &count) == SONY2FUJI_STATUS_OK && count == 1,
                "trailing edge single tile count");
    sony2fuji_pyramid_tile_v1 edgeTile{};
    requirePass(sony2fuji_pyramid_tiles(&cfg, &edgeTile, 1, &count) == SONY2FUJI_STATUS_OK,
                "trailing edge fetch");
    checkPass(edgeTile.level == 0 && edgeTile.col == 5 && edgeTile.row == 3 && edgeTile.max_output_long_edge == 928,
              "trailing edge tile is (0, 5, 3) with max_output_long_edge == 928");

    // Overscan ring appends unique surrounding tiles strictly after visible tiles
    cfg.visible_x0 = 0.40;
    cfg.visible_y0 = 0.35;
    cfg.visible_x1 = 0.60;
    cfg.visible_y1 = 0.65;
    cfg.overscan_ring = 1;
    requirePass(sony2fuji_pyramid_tiles(&cfg, nullptr, 0, &count) == SONY2FUJI_STATUS_OK && count > visibleOnly.size(),
                "overscan ring increases tile count");
    std::vector<sony2fuji_pyramid_tile_v1> withRing(count);
    requirePass(sony2fuji_pyramid_tiles(&cfg, withRing.data(), count, &count) == SONY2FUJI_STATUS_OK,
                "overscan ring fetch");
    std::set<std::tuple<int32_t, int32_t, int32_t>> keys;
    for (size_t i = 0; i < withRing.size(); ++i) {
        keys.emplace(withRing[i].level, withRing[i].col, withRing[i].row);
        if (i < visibleOnly.size()) {
            checkPass(withRing[i].level == visibleOnly[i].level &&
                      withRing[i].col == visibleOnly[i].col &&
                      withRing[i].row == visibleOnly[i].row,
                      "overscan prefix matches visibleOnly");
        }
    }
    checkPass(keys.size() == withRing.size(), "overscan ring tiles are unique");

    // Level0 grid covers 6000x4000 in 6x4 = 24 tiles
    uint32_t gridCount = 0;
    requirePass(sony2fuji_pyramid_level0_grid(6000, 4000, 1024, nullptr, 0, &gridCount) == SONY2FUJI_STATUS_OK &&
                gridCount == 24,
                "level0_grid 2-call count == 24");
    std::vector<sony2fuji_pyramid_tile_v1> grid(gridCount);
    requirePass(sony2fuji_pyramid_level0_grid(6000, 4000, 1024, grid.data(), gridCount, &gridCount) == SONY2FUJI_STATUS_OK,
                "level0_grid fetch");
    for (const auto& t : grid) {
        checkPass(t.level == 0, "level0_grid level == 0");
    }

    // detail_overlay_covers: capped at 1280px, tolerance 0.0005, 0.9 density
    sony2fuji_detail_coverage_query_v1 cov{};
    cov.version = SONY2FUJI_DETAIL_COVERAGE_QUERY_V1_VERSION;
    cov.struct_size = sizeof(cov);
    cov.tile_pixel_width = 1280;
    cov.tile_pixel_height = 853;
    cov.full_width = 6000;
    cov.full_height = 4000;
    cov.max_output_long_edge = 1280;
    cov.tile_norm_x0 = 0.2;
    cov.tile_norm_y0 = 0.2;
    cov.tile_norm_x1 = 0.6;
    cov.tile_norm_y1 = 0.6;
    cov.visible_norm_x0 = 0.25;
    cov.visible_norm_y0 = 0.25;
    cov.visible_norm_x1 = 0.55;
    cov.visible_norm_y1 = 0.55;
    cov.required_zoom_scale = 1.0;

    int32_t covers = 0;
    requirePass(sony2fuji_detail_overlay_covers(&cov, &covers) == SONY2FUJI_STATUS_OK && covers == 1,
                "capped 1280px HDR overlay reports covered");

    cov.visible_norm_x0 = 0.1996; // within 0.0005 tolerance
    requirePass(sony2fuji_detail_overlay_covers(&cov, &covers) == SONY2FUJI_STATUS_OK && covers == 1,
                "coverage within 0.0005 tolerance");
    cov.visible_norm_x0 = 0.1990; // outside 0.0005 tolerance
    requirePass(sony2fuji_detail_overlay_covers(&cov, &covers) == SONY2FUJI_STATUS_OK && covers == 0,
                "coverage outside 0.0005 tolerance rejected");

    // Uncapped low-density tile fails 0.9 density check
    cov.visible_norm_x0 = 0.25;
    cov.max_output_long_edge = 0;
    cov.tile_pixel_width = 1000; // 1000 / 2400 = 0.416 < 0.9 * 1.0
    requirePass(sony2fuji_detail_overlay_covers(&cov, &covers) == SONY2FUJI_STATUS_OK && covers == 0,
                "low density overlay fails 0.9 check");

    // Invalid args
    cov.reserved = 1;
    requirePass(sony2fuji_detail_overlay_covers(&cov, &covers) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "nonzero reserved rejected");
    cov.reserved = 0;
    cov.struct_size = 4;
    requirePass(sony2fuji_detail_overlay_covers(&cov, &covers) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
                "small struct_size rejected");
}

void testFastFullResGpuAndParity() {
    const std::filesystem::path fixtureDir(TEST_FIXTURE_DIR);
    const std::string rawPath = (fixtureDir / "bayer-demosaic.dng").u8string();
    const std::string flog2LutPath = (fixtureDir / "golden-flog2-look.cube").u8string();
    const std::string hdrLinearLutPath = (fixtureDir / "hdr-look-linear.cube").u8string();
    const std::string rlookPath = (fixtureDir / "golden-dcp-look.rlook").u8string();

    const std::filesystem::path tempVltPath =
        std::filesystem::temp_directory_path() / "rawlab_viewport_pyramid_cpu_only.vlt";
    {
        std::ofstream vltOut(tempVltPath);
        vltOut << "# panasonic vlt file version 1.0\n# source vlt file \"\"\nLUT_3D_SIZE 2\n";
        for (int b = 0; b < 2; ++b)
            for (int g = 0; g < 2; ++g)
                for (int r = 0; r < 2; ++r)
                    vltOut << (r * 4095) << ' ' << (g * 4095) << ' ' << (b * 4095) << '\n';
    }
    struct TempFileGuard {
        std::filesystem::path path;
        ~TempFileGuard() {
            std::error_code ec;
            std::filesystem::remove(path, ec);
        }
    } tempVltGuard{tempVltPath};

    const auto q = makeFastQuery(rawPath, SONY2FUJI_INPUT_RAW, 6000, 4000, 28000000);
    const std::string baseJson = baseSdrStateJson().dump();

    // Baseline session
    {
        auto session = makeSession(SONY2FUJI_GPU_AUTO);
        const int32_t supported = queryFastGpu(session.get(), q, &baseJson);
        const auto backend = renderAndGetBackend(session.get(), rawPath, &baseJson);
#ifdef SONY2FUJI_ENABLE_METAL
        checkPass(supported == 1, "baseline SDR RAW supports fast full-res Metal GPU");
        checkPass(backend == SONY2FUJI_BACKEND_METAL, "baseline render used Metal backend");
#else
        checkPass(supported == 0, "baseline returns 0 without GPU backend");
        (void)backend;
#endif
    }

    // Non-mutation invariant: passing edit_state_json must NOT mutate committed session state
    {
        auto session = makeSession(SONY2FUJI_GPU_AUTO);
        const int32_t baselineSupported = queryFastGpu(session.get(), q, &baseJson);
        // Commit baseline state via render
        const auto initialBackend = renderAndGetBackend(session.get(), rawPath, &baseJson);
        checkPass(queryFastGpu(session.get(), q, nullptr) == baselineSupported,
                  "committed state matches baseline query");

        Json atmJson = baseSdrStateJson();
        atmJson["edits"]["effects"] = {{"clarity", 0.5}, {"dehaze", 0.0}};
        const std::string atmStr = atmJson.dump();
        checkPass(queryFastGpu(session.get(), q, &atmStr) == 0,
                  "atmosphere clarity rejects fast full-res GPU");

        // Now pass edit_state_json = nullptr -> MUST still equal baselineSupported and render on same backend!
        checkPass(queryFastGpu(session.get(), q, nullptr) == baselineSupported,
                  "supports_fast_full_res_gpu did not mutate committed session state");
        const auto afterBackend = renderAndGetBackend(session.get(), rawPath, nullptr);
        checkPass(afterBackend == initialBackend,
                  "post-query render backend unchanged");
    }

    // Positive parity checks: features falsely blocked by Swift's old heuristic
    {
        auto checkPositiveParity = [&](const std::string& label, const Json& doc) {
            auto session = makeSession(SONY2FUJI_GPU_AUTO);
            const std::string s = doc.dump();
            const int32_t supported = queryFastGpu(session.get(), q, &s);
            const auto backend = renderAndGetBackend(session.get(), rawPath, &s);
#ifdef SONY2FUJI_ENABLE_METAL
            checkPass(supported == 1, label + " supported on fast full-res GPU");
            checkPass(backend == SONY2FUJI_BACKEND_METAL, label + " rendered on Metal");
#else
            checkPass(supported == 0, label + " CPU build parity");
            (void)backend;
#endif
        };

        // 1. curveApplyToLuminosity == true
        {
            Json j = baseSdrStateJson();
            j["edits"]["tone"]["curve"] = {
                {"mode", "custom"},
                {"apply_to_luminosity", true},
                {"points", Json::array({Json::array({0.0, 0.0}), Json::array({0.5, 0.65}), Json::array({1.0, 1.0})})}
            };
            checkPositiveParity("curveApplyToLuminosity", j);
        }

        // 2. channelCurves (gpuSupported)
        {
            Json j = baseSdrStateJson();
            j["edits"]["tone"]["curve"] = {
                {"mode", "legacy"},
                {"points", Json::array()},
                {"channels", {
                    {"red", {{"mode", "custom"}, {"points", Json::array({Json::array({0.0, 0.0}), Json::array({0.5, 0.6}), Json::array({1.0, 1.0})})}}}
                }}
            };
            checkPositiveParity("channelCurves", j);
        }

        // 3. parametricCurve
        {
            Json j = baseSdrStateJson();
            j["edits"]["tone"]["curve"] = {
                {"mode", "legacy"},
                {"points", Json::array()},
                {"parametric", {{"shadows", 25.0}, {"lights", -10.0}}}
            };
            checkPositiveParity("parametricCurve", j);
        }

        // 4. basicTone (BasicV3 highlights/shadows)
        {
            Json j = baseSdrStateJson(/*processingVersion=*/3);
            j["edits"]["tone"]["highlights"] = 0.35;
            j["edits"]["tone"]["shadows"] = 0.40;
            checkPositiveParity("basicV3 basicTone", j);
        }

        // 5. F-Log2 .cube LUT
        {
            Json j = baseSdrStateJson();
            j["edits"]["look"] = {{"path", flog2LutPath}, {"strength", 1.0}};
            checkPositiveParity("FLog2 cube LUT", j);
        }

        // 6. schema_version 18 free-endpoint X tone curves (PR #647 parity)
        {
            Json j = baseSdrStateJson();
            j["schema_version"] = 18;
            j["edits"]["tone"]["curve"] = {
                {"mode", "custom"},
                {"points", Json::array({Json::array({0.15, 0.05}), Json::array({0.5, 0.55}), Json::array({0.85, 0.95})})},
                {"channels", {
                    {"red", {{"mode", "custom"}, {"points", Json::array({Json::array({0.1, 0.02}), Json::array({0.5, 0.52}), Json::array({0.9, 0.96})})}}}
                }}
            };
            checkPositiveParity("schema18 free endpoint X curve", j);
        }
    }

    // DCP .rlook parity: must match actual Metal backend execution
    {
        auto session = makeSession(SONY2FUJI_GPU_AUTO);
        Json j = baseSdrStateJson();
        j["edits"]["look"] = {{"path", rlookPath}, {"strength", 1.0}};
        const std::string s = j.dump();
        const int32_t supported = queryFastGpu(session.get(), q, &s);
        const auto backend = renderAndGetBackend(session.get(), rawPath, &s);
#ifdef SONY2FUJI_ENABLE_METAL
        checkPass(supported == (backend == SONY2FUJI_BACKEND_METAL ? 1 : 0),
                  "DCP rlook capability matches Metal DCP pipeline availability");
#else
        checkPass(supported == 0 && backend == SONY2FUJI_BACKEND_CPU, "DCP rlook non-Metal is 0");
#endif
    }

    // Negative gate checks (all must return *out_supported == 0)
    {
        auto offSession = makeSession(SONY2FUJI_GPU_OFF);
        checkPass(queryFastGpu(offSession.get(), q, &baseJson) == 0, "GPU_OFF -> 0");

        auto session = makeSession(SONY2FUJI_GPU_AUTO);
        checkPass(queryFastGpu(session.get(), makeFastQuery("", SONY2FUJI_INPUT_DISPLAY_BUFFER, 1000, 1000, 28000000), &baseJson) == 0,
                  "INPUT_DISPLAY_BUFFER -> 0");
        checkPass(queryFastGpu(session.get(), makeFastQuery("", SONY2FUJI_INPUT_BUFFER, 1000, 1000, 28000000), &baseJson) == 0,
                  "INPUT_BUFFER -> 0");
        checkPass(queryFastGpu(session.get(), makeFastQuery(rawPath, SONY2FUJI_INPUT_RAW, 7000, 5000, 28000000), &baseJson) == 0,
                  "exceeds max_pixels -> 0");

        // wavelet enabled
        {
            Json j = baseSdrStateJson();
            j["edits"]["denoise"] = {{"wavelet", {{"enabled", true}, {"luma", 40.0}}}};
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "wavelet.enabled -> 0");
        }
        // chroma denoise
        {
            Json j = baseSdrStateJson();
            j["edits"]["denoise"] = {{"chroma_mode", 1}};
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "chroma_mode != 0 -> 0");
        }
        // geometry (straighten & crop)
        {
            Json j = baseSdrStateJson();
            j["edits"]["geometry"] = {{"straighten_degrees", 3.0}};
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "geometry straighten -> 0");
        }
        {
            Json j = baseSdrStateJson();
            j["edits"]["geometry"] = {{"crop", {{"x", 0.1}, {"y", 0.1}, {"width", 0.8}, {"height", 0.8}}}};
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "geometry crop -> 0");
        }
        // atmosphere dehaze
        {
            Json j = baseSdrStateJson();
            j["edits"]["effects"] = {{"dehaze", 0.25}};
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "atmosphere dehaze -> 0");
        }
        // non-GPU-supported steep custom curve (3 * dy / dx > 16)
        {
            Json j = baseSdrStateJson();
            j["edits"]["tone"]["curve"] = {
                {"mode", "custom"},
                {"points", Json::array({Json::array({0.0, 0.0}), Json::array({0.01, 0.5}), Json::array({1.0, 1.0})})}
            };
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "steep customCurve (!gpuSupported) -> 0");
        }
        // non-GPU-supported steep channel curve
        {
            Json j = baseSdrStateJson();
            j["edits"]["tone"]["curve"] = {
                {"mode", "legacy"},
                {"points", Json::array()},
                {"channels", {
                    {"red", {{"mode", "custom"}, {"points", Json::array({Json::array({0.0, 0.0}), Json::array({0.01, 0.5}), Json::array({1.0, 1.0})})}}}
                }}
            };
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "steep channelCurve (!gpuSupported) -> 0");
        }
        // HDR state JSON -> OK, 0
        {
            Json j = {
                {"schema_version", 16},
                {"processing", {{"family", "rawlab_hdr"}, {"version", 9}, {"quality", "standard"}}},
                {"edits", {{"exposure", {{"ev", 0.0}}}, {"white_balance", {{"mode", "relative"}}}}}
            };
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "HDR edit_state_json -> OK & 0");
        }
        // CPU-only LUT (.vlt requiresCPU()) and non-photo LUT
        {
            Json j = baseSdrStateJson();
            j["edits"]["look"] = {{"path", tempVltPath.u8string()}, {"strength", 1.0}};
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "CPU-only VLT LUT -> 0");
        }
        {
            Json j = baseSdrStateJson();
            j["edits"]["look"] = {{"path", hdrLinearLutPath}, {"strength", 1.0}};
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "non-photo HDR linear LUT -> 0");
        }

        // steep free-endpoint X curve on schema 18 falls back to CPU
        {
            Json j = baseSdrStateJson();
            j["schema_version"] = 18;
            j["edits"]["tone"]["curve"] = {
                {"mode", "custom"},
                {"points", Json::array({Json::array({0.15, 0.0}), Json::array({0.16, 0.5}), Json::array({0.85, 1.0})})}
            };
            const std::string s = j.dump();
            checkPass(queryFastGpu(session.get(), q, &s) == 0, "steep schema18 free X curve (!gpuSupported) -> 0");
            checkPass(renderAndGetBackend(session.get(), rawPath, &s) == SONY2FUJI_BACKEND_CPU,
                      "steep schema18 free X curve falls back to CPU");
        }

        // Invalid argument checks
        int32_t out = 0;
        {
            Json j = baseSdrStateJson();
            j["edits"]["tone"]["curve"] = {
                {"mode", "custom"},
                {"points", Json::array({Json::array({0.15, 0.05}), Json::array({0.5, 0.55}), Json::array({0.85, 0.95})})}
            };
            const std::string s = j.dump();
            checkPass(sony2fuji_session_supports_fast_full_res_gpu(session.get(), &q, s.c_str(), &out) ==
                      SONY2FUJI_STATUS_INVALID_ARGUMENT,
                      "schema17 rejects free-endpoint X curve");
        }
        checkPass(sony2fuji_session_supports_fast_full_res_gpu(nullptr, &q, baseJson.c_str(), &out) ==
                  SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "null session rejected");
        checkPass(sony2fuji_session_supports_fast_full_res_gpu(session.get(), nullptr, baseJson.c_str(), &out) ==
                  SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "null query rejected");
        checkPass(sony2fuji_session_supports_fast_full_res_gpu(session.get(), &q, baseJson.c_str(), nullptr) ==
                  SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "null out_supported rejected");
        checkPass(sony2fuji_session_supports_fast_full_res_gpu(session.get(), &q, "", &out) ==
                  SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "empty edit_state_json rejected");
        checkPass(sony2fuji_session_supports_fast_full_res_gpu(session.get(), &q, "{bad", &out) ==
                  SONY2FUJI_STATUS_INVALID_ARGUMENT,
                  "malformed edit_state_json rejected");
    }
}

} // namespace

TEST_MAIN(
    testPyramidMathAndCoverage();
    testFastFullResGpuAndParity();
)
