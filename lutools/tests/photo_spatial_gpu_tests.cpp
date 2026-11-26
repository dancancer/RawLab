#include "test_harness.h"
#include "native_gpu_test_support.h"
#include "core/photo_atmosphere.h"
#include "core/photo_defringe.h"
#include "core/photo_sharpen_v2.h"
#include "nlohmann/json.hpp"
#include "sony2fuji/ffi/sony2fuji_c.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

namespace {

namespace fs = std::filesystem;
using Json = nlohmann::json;
using rawlab::test::checkPass;
using rawlab::test::requirePass;

struct SessionDeleter {
    void operator()(sony2fuji_session* s) const noexcept {
        if (s) sony2fuji_session_destroy(s);
    }
};
using SessionPtr = std::unique_ptr<sony2fuji_session, SessionDeleter>;

struct TempDir {
    fs::path path;
    TempDir() {
        const auto nonce = std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
        path = fs::temp_directory_path() / ("rawlab-spatial-gpu-tests-" + nonce);
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

void appendInt(std::vector<uint8_t>& bytes, uint64_t value, size_t count) {
    for (size_t i = 0; i < count; ++i) bytes.push_back(static_cast<uint8_t>(value >> (i * 8)));
}

template <class T>
void appendFloat(std::vector<uint8_t>& bytes, T value) {
    uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(T));
    appendInt(bytes, bits, sizeof(T));
}

fs::path writeNonTrivialRlook(const fs::path& dir) {
    std::vector<uint8_t> bytes{'R', 'L', 'O', 'O', 'K', 'D', 'C', 'P'};
    for (uint32_t value : {2u, 0u, 0u, 2u, 2u, 2u, 4097u, 2u}) appendInt(bytes, value, 4);
    for (uint32_t value : {1u, 2u, 2u, 2u}) appendInt(bytes, value, 4);
    for (int matrix = 0; matrix < 2; ++matrix) {
        for (int i = 0; i < 9; ++i) appendFloat(bytes, i % 4 == 0 ? 1.0 : 0.0);
    }
    appendFloat(bytes, 1.0);
    for (int v = 0; v < 2; ++v)
        for (int h = 0; h < 2; ++h)
            for (int s = 0; s < 2; ++s) {
                appendFloat(bytes, h ? 8.0f : 0.0f);
                appendFloat(bytes, s ? 1.05f : 1.0f);
                appendFloat(bytes, (s && v) ? 0.98f : 1.0f);
            }
    for (int v = 0; v < 2; ++v)
        for (int h = 0; h < 2; ++h)
            for (int s = 0; s < 2; ++s) {
                appendFloat(bytes, 0.0f);
                appendFloat(bytes, 1.0f);
                appendFloat(bytes, 1.0f);
            }
    for (int i = 0; i <= 4096; ++i) {
        const double x = i / 4096.0;
        const double sCurve = x * x * (3.0 - 2.0 * x);
        appendFloat(bytes, 0.85 * x + 0.15 * sCurve);
    }
    bytes.push_back('{');
    bytes.push_back('}');
    const fs::path file = dir / "spatial-test-look.rlook";
    std::ofstream stream(file, std::ios::binary);
    stream.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    return file;
}

SessionPtr makeSession(sony2fuji_gpu_mode mode) {
    sony2fuji_session* raw = nullptr;
    requirePass(sony2fuji_session_create(&raw) == SONY2FUJI_STATUS_OK && raw != nullptr, "session_create");
    SessionPtr s(raw);
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), mode};
    requirePass(sony2fuji_session_set_gpu_config(s.get(), &gpu) == SONY2FUJI_STATUS_OK, "set_gpu_config");
    return s;
}

sony2fuji_render_options_v1 makeRenderOpts(const uint8_t* data, uint32_t w, uint32_t h,
                                            sony2fuji_input_type inputType = SONY2FUJI_INPUT_BUFFER,
                                            int32_t linear = 1,
                                            sony2fuji_pixel_format fmt = SONY2FUJI_PIXEL_RGB8) {
    sony2fuji_render_options_v1 opts{};
    opts.version = SONY2FUJI_RENDER_OPTIONS_V1_VERSION;
    opts.struct_size = sizeof(opts);
    opts.input_type = inputType;
    opts.input_pixels = data;
    opts.input_width = w;
    opts.input_height = h;
    opts.input_pixel_format = fmt;
    opts.input_color_space = SONY2FUJI_COLOR_SRGB;
    opts.input_is_linear = linear;
    opts.output_target = SONY2FUJI_TARGET_BUFFER;
    opts.output_format = SONY2FUJI_OUTPUT_RGB8;
    opts.jpeg_quality = 90;
    opts.size_mode = SONY2FUJI_SIZE_NATIVE;
    opts.intent = SONY2FUJI_INTENT_FINAL;
    return opts;
}

std::vector<uint8_t> renderJson(sony2fuji_session* s, const sony2fuji_render_options_v1& opts, const std::string& json) {
    sony2fuji_buffer buf{};
    const auto status = sony2fuji_session_render(s, &opts, json.c_str(), &buf, nullptr);
    requirePass(status == SONY2FUJI_STATUS_OK,
                "sony2fuji_session_render status=" + std::to_string(static_cast<int>(status)) +
                " gpuErr=" + sony2fuji_session_get_gpu_error(s));
    const auto* ptr = static_cast<const uint8_t*>(buf.data);
    std::vector<uint8_t> out(ptr, ptr + buf.size_bytes);
    sony2fuji_release_buffer(&buf);
    return out;
}

std::vector<uint8_t> renderLegacy(sony2fuji_session* s, const sony2fuji_request& req) {
    sony2fuji_buffer buf{};
    requirePass(sony2fuji_process(s, &req, &buf) == SONY2FUJI_STATUS_OK, "sony2fuji_process");
    const auto* ptr = static_cast<const uint8_t*>(buf.data);
    std::vector<uint8_t> out(ptr, ptr + buf.size_bytes);
    sony2fuji_release_buffer(&buf);
    return out;
}

Json baseSchema20Json() {
    return Json{
        {"schema_version", 20},
        {"processing", {{"family", "rawlab"}, {"version", 3}, {"quality", "standard"}}},
        {"x3f_mode", "legacy"},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"tone", {{"contrast", 1.0}, {"saturation", 1.0}, {"highlights", 0.0}, {"shadows", 0.0}}}
        }}
    };
}

void testForceGpuFullStackParity(const fs::path& rlookPath) {
    const int w = 256, h = 192;
    std::vector<uint8_t> pixels(static_cast<size_t>(w) * h * 3u);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const float fx = float(x) / float(w - 1);
            const float fy = float(y) / float(h - 1);
            const float fineTex = 0.04f * std::sin(x * 1.1f) * std::cos(y * 1.1f);
            const float midBand = 0.14f * std::sin(fx * 18.0f + fy * 12.0f);
            const float step = (x > 96 && x < 160 && y > 48 && y < 144) ? 0.25f : 0.0f;
            float r = std::clamp(0.18f + 0.35f * fx + midBand + fineTex + step, 0.01f, 0.95f);
            float g = std::clamp(0.16f + 0.25f * fy + 0.7f * midBand - 0.5f * fineTex, 0.01f, 0.95f);
            float b = std::clamp(0.22f + 0.30f * (1.0f - fx) + 0.5f * midBand + step, 0.01f, 0.95f);
            // Inject purple/green fringe near step boundary
            if ((x == 96 || x == 97) && y > 48 && y < 144) { r = 0.80f; g = 0.12f; b = 0.85f; }
            if ((x == 160 || x == 161) && y > 48 && y < 144) { r = 0.12f; g = 0.82f; b = 0.14f; }
            const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
            pixels[idx + 0] = static_cast<uint8_t>(std::lround(r * 255.0f));
            pixels[idx + 1] = static_cast<uint8_t>(std::lround(g * 255.0f));
            pixels[idx + 2] = static_cast<uint8_t>(std::lround(b * 255.0f));
        }
    }

    Json doc = baseSchema20Json();
    doc["edits"]["effects"] = {{"clarity", 0.45}, {"dehaze", 0.30}, {"texture", 0.50}};
    doc["edits"]["detail"] = {
        {"sharpening", 0.65},
        {"luminance_v2", true},
        {"sharpening_radius", 1.2},
        {"sharpening_detail", 25.0},
        {"sharpening_masking", 55.0}
    };
    doc["edits"]["lens_correction"] = {
        {"defringe_purple_amount", 8.0},
        {"defringe_purple_hue", 50.0},
        {"defringe_green_amount", 6.0},
        {"defringe_green_hue", 50.0}
    };
    doc["edits"]["look"] = {{"path", rlookPath.u8string()}, {"strength", 0.85}};
    const std::string editJson = doc.dump();

    const auto opts = makeRenderOpts(pixels.data(), w, h);
    auto cpuSession = makeSession(SONY2FUJI_GPU_OFF);
    const auto cpuPixels = renderJson(cpuSession.get(), opts, editJson);

#if defined(SONY2FUJI_ENABLE_METAL) || defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    if (rawlabtest::nativeGpuAvailable()) {
        auto gpuSession = makeSession(SONY2FUJI_GPU_FORCE);
        sony2fuji_buffer gpuBuf{};
        const auto status = sony2fuji_session_render(gpuSession.get(), &opts, editJson.c_str(), &gpuBuf, nullptr);
        checkPass(status == SONY2FUJI_STATUS_OK, "Force GPU passes with clarity+dehaze+texture+sharpenV2+defringe+rlook");
        checkPass(sony2fuji_session_get_last_backend(gpuSession.get()) == rawlabtest::nativeBackend &&
                      sony2fuji_session_get_last_backend(gpuSession.get()) != SONY2FUJI_BACKEND_CPU,
                  "Force GPU executes on native GPU backend (lastBackend != Cpu)");
        checkPass(sony2fuji_session_get_gpu_fallback_reason(gpuSession.get()) == SONY2FUJI_GPU_FALLBACK_NONE,
                  "Force GPU produces no CPU fallback reason");
        if (status == SONY2FUJI_STATUS_OK && gpuBuf.data != nullptr) {
            const auto* gp = static_cast<const uint8_t*>(gpuBuf.data);
            checkPass(gpuBuf.size_bytes == cpuPixels.size(), "GPU spatial stack output byte count matches CPU");
            int maxDiff = 0;
            double sumAbs = 0.0;
            for (size_t i = 0; i < cpuPixels.size(); ++i) {
                const int d = std::abs(int(gp[i]) - int(cpuPixels[i]));
                maxDiff = std::max(maxDiff, d);
                sumAbs += d;
            }
            const double meanAbs = sumAbs / static_cast<double>(cpuPixels.size());
            checkPass(maxDiff <= 2, "Force GPU vs CPU parity <= 2 RGB8 (got max=" + std::to_string(maxDiff) +
                                        ", mean=" + std::to_string(meanAbs) + ")");
        }
        sony2fuji_release_buffer(&gpuBuf);
    } else {
        auto autoSession = makeSession(SONY2FUJI_GPU_AUTO);
        const auto autoPixels = renderJson(autoSession.get(), opts, editJson);
        checkPass(autoPixels == cpuPixels, "No hardware GPU adapter falls back cleanly to exact CPU");
    }
#else
    auto gpuSession = makeSession(SONY2FUJI_GPU_FORCE);
    sony2fuji_buffer gpuBuf{};
    checkPass(sony2fuji_session_render(gpuSession.get(), &opts, editJson.c_str(), &gpuBuf, nullptr) == SONY2FUJI_STATUS_UNSUPPORTED,
              "CPU-only build returns UNSUPPORTED under Force GPU");
    sony2fuji_release_buffer(&gpuBuf);
#endif
}

void testTextureIndependenceAndZeroBypass() {
    // 1. Zero-value bypass check on ImageData
    sony2fuji::ImageData base(96, 96);
    for (int y = 0; y < 96; ++y) {
        for (int x = 0; x < 96; ++x) {
            const float ramp = 0.1f + 0.5f * float(x) / 95.0f;
            const float fine = ((x + y) % 2 == 0) ? 0.05f : -0.05f;
            base.at(x, y) = sony2fuji::RGB(ramp + fine, ramp + 0.5f * fine, ramp);
        }
    }
    sony2fuji::ImageData copy = base;
    sony2fuji::applyTexture(copy, 0.0f);
    bool exactBypass = true;
    for (size_t i = 0; i < base.pixels.size(); ++i) {
        if (copy.pixels[i].r != base.pixels[i].r || copy.pixels[i].g != base.pixels[i].g ||
            copy.pixels[i].b != base.pixels[i].b) {
            exactBypass = false;
            break;
        }
    }
    checkPass(exactBypass, "applyTexture(0) performs exact bitwise bypass");

    // 2. Diagonal-normalized sigma is independent of Clarity and scales smoothly with resolution
    const float sigmaViewport = sony2fuji::textureBlurSigma(512, 384);
    const float sigmaFull = sony2fuji::textureBlurSigma(4096, 3072);
    checkPass(sigmaViewport >= 0.75f && sigmaViewport <= 4.0f && sigmaFull == 4.0f && sigmaFull > sigmaViewport,
              "textureBlurSigma scales proportionally with image diagonal within [0.75, 4.0]");

    sony2fuji::ImageData texPlus = base;
    sony2fuji::applyTexture(texPlus, 0.8f);
    double fineEnergyBefore = 0.0;
    double fineEnergyAfter = 0.0;
    for (int y = 8; y < 88; ++y) {
        for (int x = 8; x < 88; ++x) {
            fineEnergyBefore += std::abs(base.at(x, y).r - base.at(x - 1, y).r);
            fineEnergyAfter += std::abs(texPlus.at(x, y).r - texPlus.at(x - 1, y).r);
        }
    }
    checkPass(fineEnergyAfter > fineEnergyBefore * 1.15, "Positive Texture enhances fine high-frequency detail");

    // Smooth low-frequency ramp unchanged inside flat-ramp strip
    sony2fuji::ImageData smoothRamp(96, 96);
    for (int y = 0; y < 96; ++y)
        for (int x = 0; x < 96; ++x) {
            const float v = 0.2f + 0.4f * float(x) / 95.0f;
            smoothRamp.at(x, y) = sony2fuji::RGB(v, v, v);
        }
    sony2fuji::ImageData texSmooth = smoothRamp;
    sony2fuji::applyTexture(texSmooth, 1.0f);
    double smoothDiff = 0.0;
    for (int y = 10; y < 86; ++y)
        for (int x = 10; x < 86; ++x)
            smoothDiff = std::max<double>(smoothDiff, std::abs(texSmooth.at(x, y).r - smoothRamp.at(x, y).r));
    checkPass(smoothDiff < 1e-4, "Texture leaves smooth low-frequency gradient nearly untouched");
}

void testSkinVsEyelashMaskingAndPreview() {
    const int w = 128, h = 128;
    std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3u);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            float r = 0.0f, g = 0.0f, b = 0.0f;
            if (x < 56) {
                // Smooth linear skin gradient
                const float t = float(x) / 55.0f;
                r = 0.65f + 0.10f * t;
                g = 0.48f + 0.08f * t;
                b = 0.39f + 0.06f * t;
            } else if (x >= 72) {
                // Sharp eyelash step edge across y = 60..68
                const bool eyelash = (y >= 60 && y <= 68);
                r = g = b = eyelash ? 0.08f : 0.85f;
            } else {
                // Transition strip between halves
                const float u = float(x - 56) / 16.0f;
                r = (1.0f - u) * 0.75f + u * 0.85f;
                g = (1.0f - u) * 0.56f + u * 0.85f;
                b = (1.0f - u) * 0.45f + u * 0.85f;
            }
            const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
            rgb[idx + 0] = static_cast<uint8_t>(std::lround(r * 255.0f));
            rgb[idx + 1] = static_cast<uint8_t>(std::lround(g * 255.0f));
            rgb[idx + 2] = static_cast<uint8_t>(std::lround(b * 255.0f));
        }
    }

    Json neutralDoc = baseSchema20Json();
    Json maskedDoc = baseSchema20Json();
    maskedDoc["edits"]["detail"] = {
        {"sharpening", 0.85},
        {"luminance_v2", true},
        {"sharpening_radius", 1.2},
        {"sharpening_detail", 25.0},
        {"sharpening_masking", 65.0}
    };
    const std::string neutralJson = neutralDoc.dump();
    const std::string maskedJson = maskedDoc.dump();
    const auto opts = makeRenderOpts(rgb.data(), w, h);

    auto runBackendCheck = [&](sony2fuji_gpu_mode mode, const std::string& label) {
        auto sNeutral = makeSession(mode);
        const auto baseOut = renderJson(sNeutral.get(), opts, neutralJson);
        auto sSharp = makeSession(mode);
        const auto sharpOut = renderJson(sSharp.get(), opts, maskedJson);

        int smoothMaxDiff = 0;
        for (int y = 6; y < h - 6; ++y) {
            for (int x = 6; x < 48; ++x) {
                const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
                for (int c = 0; c < 3; ++c) {
                    smoothMaxDiff = std::max(smoothMaxDiff, std::abs(int(sharpOut[idx + c]) - int(baseOut[idx + c])));
                }
            }
        }
        checkPass(smoothMaxDiff == 0, label + ": Masking >= 50 produces exact 0 diff in smooth skin gradient (got " +
                                          std::to_string(smoothMaxDiff) + ")");

        int edgeMaxDelta = 0;
        for (int y = 57; y <= 71; ++y) {
            for (int x = 80; x < 120; ++x) {
                const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
                edgeMaxDelta = std::max(edgeMaxDelta, std::abs(int(sharpOut[idx]) - int(baseOut[idx])));
            }
        }
        checkPass(edgeMaxDelta >= 8, label + ": Sharp eyelash edge strengthens cleanly (maxDelta=" +
                                         std::to_string(edgeMaxDelta) + ")");
    };

    runBackendCheck(SONY2FUJI_GPU_OFF, "CPU");
    if (rawlabtest::nativeGpuAvailable()) {
        runBackendCheck(SONY2FUJI_GPU_FORCE, "ForceGPU");
    }

    // Sharpen mask preview C ABI matches exact edge mask behavior across RGB8 and BGRA8+stride
    sony2fuji_buffer srcRgb{};
    srcRgb.data = rgb.data();
    srcRgb.size_bytes = rgb.size();
    srcRgb.width = w;
    srcRgb.height = h;
    srcRgb.stride_bytes = w * 3;
    srcRgb.pixel_format = SONY2FUJI_PIXEL_RGB8;
    sony2fuji_buffer maskRgb{};
    requirePass(sony2fuji_render_sharpen_mask_preview(&srcRgb, 1.2f, 65.0f, &maskRgb) == SONY2FUJI_STATUS_OK,
                "sony2fuji_render_sharpen_mask_preview RGB8 succeeds");
    const auto* mBytes = static_cast<const uint8_t*>(maskRgb.data);
    uint8_t smoothMaxMask = 0;
    uint8_t edgeMaxMask = 0;
    for (int y = 6; y < h - 6; ++y) {
        for (int x = 6; x < 48; ++x) {
            smoothMaxMask = std::max(smoothMaxMask, mBytes[(static_cast<size_t>(y) * w + x) * 3u]);
        }
    }
    for (int y = 59; y <= 69; ++y) {
        for (int x = 80; x < 120; ++x) {
            edgeMaxMask = std::max(edgeMaxMask, mBytes[(static_cast<size_t>(y) * w + x) * 3u]);
        }
    }
    checkPass(smoothMaxMask == 0, "Sharpen mask preview outputs 0 in smooth skin gradient");
    checkPass(edgeMaxMask > 200, "Sharpen mask preview outputs > 200 on crisp eyelash edge (got " +
                                     std::to_string(edgeMaxMask) + ")");
    sony2fuji_release_buffer(&maskRgb);

    // Isoluminant chromatic edge check: no chromatic haloing
    sony2fuji::ImageData iso(64, 64);
    for (int y = 0; y < 64; ++y) {
        for (int x = 0; x < 64; ++x) {
            // Match Rec.709 luminance (0.2126*R + 0.7152*G + 0.0722*B ~= 0.28)
            iso.at(x, y) = (x < 32) ? sony2fuji::RGB(0.90f, 0.114f, 0.10f) : sony2fuji::RGB(0.05f, 0.366f, 0.10f);
        }
    }
    sony2fuji::ImageData isoOut = iso;
    sony2fuji::SharpenV2Options isoOpts{};
    isoOpts.luminanceV2 = true;
    isoOpts.radius = 1.2f;
    isoOpts.detail = 25.0f;
    isoOpts.masking = 0.0f;
    sony2fuji::applySharpenV2(isoOut, 0.8f, isoOpts);
    float maxIsoShift = 0.0f;
    for (size_t i = 0; i < iso.pixels.size(); ++i) {
        maxIsoShift = std::max(maxIsoShift, std::abs(isoOut.pixels[i].r - iso.pixels[i].r));
        maxIsoShift = std::max(maxIsoShift, std::abs(isoOut.pixels[i].g - iso.pixels[i].g));
    }
    checkPass(maxIsoShift < 0.01f, "Luminance USM v2 produces no chromatic haloing on isoluminant color edges");

    // Strided BGRA8 support in mask preview C ABI
    const int bgraStride = w * 4 + 16;
    std::vector<uint8_t> bgra(static_cast<size_t>(bgraStride) * h, 0);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const size_t sIdx = (static_cast<size_t>(y) * w + x) * 3u;
            const size_t dIdx = static_cast<size_t>(y) * bgraStride + static_cast<size_t>(x) * 4u;
            bgra[dIdx + 0] = rgb[sIdx + 2];
            bgra[dIdx + 1] = rgb[sIdx + 1];
            bgra[dIdx + 2] = rgb[sIdx + 0];
            bgra[dIdx + 3] = 255;
        }
    }
    sony2fuji_buffer srcBgra{bgra.data(), bgra.size(), w, h, bgraStride, SONY2FUJI_PIXEL_BGRA8};
    sony2fuji_buffer maskBgra{};
    checkPass(sony2fuji_render_sharpen_mask_preview(&srcBgra, 1.2f, 65.0f, &maskBgra) == SONY2FUJI_STATUS_OK &&
                  maskBgra.pixel_format == SONY2FUJI_PIXEL_BGRA8 && maskBgra.width == w && maskBgra.height == h,
              "Sharpen mask preview preserves strided BGRA8 layout");
    sony2fuji_release_buffer(&maskBgra);
}

void testDefringeEdgeVsFlatPatches() {
    const int w = 128, h = 128;
    std::vector<uint8_t> pixels(static_cast<size_t>(w) * h * 3u, 128);
    auto setPx = [&](int x, int y, uint8_t r, uint8_t g, uint8_t b) {
        const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
        pixels[idx + 0] = r;
        pixels[idx + 1] = g;
        pixels[idx + 2] = b;
    };
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            if (y < 64) {
                // Sharp white->black steps with purple and green CA fringes along x=32..33 and x=96..97
                if (x < 32) setPx(x, y, 240, 240, 240);
                else if (x == 32 || x == 33) setPx(x, y, 210, 45, 225);  // Purple CA fringe
                else if (x < 64) setPx(x, y, 16, 16, 16);
                else if (x < 96) setPx(x, y, 240, 240, 240);
                else if (x == 96 || x == 97) setPx(x, y, 45, 225, 55);   // Green CA fringe
                else setPx(x, y, 16, 16, 16);
            } else {
                // Solid non-edge purple patch (x < 64) and green patch (x >= 64)
                if (x < 64) setPx(x, y, 180, 50, 195);
                else setPx(x, y, 50, 195, 60);
            }
        }
    }

    Json neutralDoc = baseSchema20Json();
    Json defringeDoc = baseSchema20Json();
    defringeDoc["edits"]["lens_correction"] = {
        {"defringe_purple_amount", 14.0},
        {"defringe_purple_hue", 50.0},
        {"defringe_green_amount", 14.0},
        {"defringe_green_hue", 50.0}
    };
    const std::string neutralJson = neutralDoc.dump();
    const std::string defringeJson = defringeDoc.dump();

    auto checkMode = [&](sony2fuji_input_type inputType, int32_t linear, sony2fuji_gpu_mode mode, const std::string& label) {
        const auto opts = makeRenderOpts(pixels.data(), w, h, inputType, linear);
        auto s0 = makeSession(mode);
        const auto baseOut = renderJson(s0.get(), opts, neutralJson);
        auto s1 = makeSession(mode);
        const auto out = renderJson(s1.get(), opts, defringeJson);

        auto pxChroma = [&](const std::vector<uint8_t>& buf, int x, int y) {
            const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
            const int mn = std::min({int(buf[idx]), int(buf[idx + 1]), int(buf[idx + 2])});
            const int mx = std::max({int(buf[idx]), int(buf[idx + 1]), int(buf[idx + 2])});
            return mx - mn;
        };
        const int pChromaBefore = pxChroma(baseOut, 32, 24);
        const int pChromaAfter = pxChroma(out, 32, 24);
        const int gChromaBefore = pxChroma(baseOut, 96, 24);
        const int gChromaAfter = pxChroma(out, 96, 24);
        checkPass(pChromaBefore - pChromaAfter >= 20, label + ": purple CA fringe chroma suppressed (" +
                                                           std::to_string(pChromaBefore) + " -> " +
                                                           std::to_string(pChromaAfter) + ")");
        checkPass(gChromaBefore - gChromaAfter >= 20, label + ": green CA fringe chroma suppressed (" +
                                                           std::to_string(gChromaBefore) + " -> " +
                                                           std::to_string(gChromaAfter) + ")");

        int flatPatchDiff = 0;
        for (int y = 84; y < 116; ++y) {
            for (int x : {24, 32, 96, 104}) {
                const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
                for (int c = 0; c < 3; ++c) {
                    flatPatchDiff = std::max(flatPatchDiff, std::abs(int(out[idx + c]) - int(baseOut[idx + c])));
                }
            }
        }
        checkPass(flatPatchDiff <= (mode == SONY2FUJI_GPU_FORCE ? 1 : 0),
                  label + ": flat purple/green non-edge patches untouched (diff=" + std::to_string(flatPatchDiff) + ")");
    };

    checkMode(SONY2FUJI_INPUT_BUFFER, 1, SONY2FUJI_GPU_OFF, "LinearBuffer CPU");
    checkMode(SONY2FUJI_INPUT_DISPLAY_BUFFER, 0, SONY2FUJI_GPU_OFF, "DisplayBuffer Raster");
    if (rawlabtest::nativeGpuAvailable()) {
        checkMode(SONY2FUJI_INPUT_BUFFER, 1, SONY2FUJI_GPU_FORCE, "LinearBuffer ForceGPU");
    }
}

void testLegacySharpeningZeroDrift() {
    const int w = 64, h = 64;
    std::vector<uint8_t> pixels(static_cast<size_t>(w) * h * 3u);
    for (int y = 0; y < h; ++y)
        for (int x = 0; x < w; ++x) {
            const size_t idx = (static_cast<size_t>(y) * w + x) * 3u;
            pixels[idx + 0] = static_cast<uint8_t>((x * 4) % 240 + 8);
            pixels[idx + 1] = static_cast<uint8_t>((y * 4) % 240 + 8);
            pixels[idx + 2] = static_cast<uint8_t>(((x ^ y) * 3) % 220 + 16);
        }

    Json legacyDoc = {
        {"schema_version", 17},
        {"processing", {{"family", "rawlab"}, {"version", 2}, {"quality", "standard"}}},
        {"x3f_mode", "legacy"},
        {"edits", {
            {"exposure", {{"mode", "preview"}, {"ev", 0.0}, {"brightness", 1.0}}},
            {"white_balance", {{"mode", "camera"}}},
            {"tone", {{"contrast", 1.0}, {"saturation", 1.0}, {"highlights", 0.0}, {"shadows", 0.0}}},
            {"effects", {{"clarity", 0.25}}},
            {"detail", {{"sharpening", 0.65}}}
        }}
    };
    const std::string legacyJson = legacyDoc.dump();

    const auto opts = makeRenderOpts(pixels.data(), w, h);
    auto sJson = makeSession(SONY2FUJI_GPU_OFF);
    const auto outJson = renderJson(sJson.get(), opts, legacyJson);

    sony2fuji_request req{};
    req.version = SONY2FUJI_REQUEST_VERSION;
    req.struct_size = sizeof(req);
    req.input_type = SONY2FUJI_INPUT_BUFFER;
    req.input_pixels = pixels.data();
    req.input_width = w;
    req.input_height = h;
    req.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    req.input_color_space = SONY2FUJI_COLOR_SRGB;
    req.input_is_linear = 1;
    req.wb_mode = SONY2FUJI_WB_CAMERA;
    req.temperature = 6500.0f;
    req.brightness = 1.0f;
    req.contrast = 1.0f;
    req.saturation = 1.0f;
    req.output_target = SONY2FUJI_TARGET_BUFFER;
    req.output_format = SONY2FUJI_OUTPUT_RGB8;
    req.size_mode = SONY2FUJI_SIZE_NATIVE;
    req.intent = SONY2FUJI_INTENT_FINAL;
    auto sC = makeSession(SONY2FUJI_GPU_OFF);
    sony2fuji_atmosphere_config atmo{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(atmo), 0.25f, 0.0f};
    requirePass(sony2fuji_session_set_atmosphere(sC.get(), &atmo) == SONY2FUJI_STATUS_OK, "legacy atmo");
    req.sharpening = 0.65f;
    const auto outC = renderLegacy(sC.get(), req);
    checkPass(outJson == outC, "Legacy luminanceV2=false with sharpening>0 matches pre-v0.14 bytes exactly");
}

} // namespace

int main() {
    TempDir tmp;
    const fs::path rlookPath = writeNonTrivialRlook(tmp.path);
    testForceGpuFullStackParity(rlookPath);
    testTextureIndependenceAndZeroBypass();
    testSkinVsEyelashMaskingAndPreview();
    testDefringeEdgeVsFlatPatches();
    testLegacySharpeningZeroDrift();
    return rawlab::test::failureCount() == 0 ? 0 : 1;
}
