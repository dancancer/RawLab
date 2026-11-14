#include "sony2fuji/color_converter.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/gpu/lut_gpu.h"
#include "sony2fuji/lut_applicator.h"
#include "sony2fuji/lut_parser.h"
#include "sony2fuji/raw_processor.h"
#include "core/parallel_pixels.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_effects.h"
#include "core/photo_geometry.h"
#include "core/photo_lut.h"
#include "core/photo_tone_controls.h"
#include "core/processing_cancellation.h"
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core/utility.hpp>
#endif

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

uint64_t fnv1aBytes(const void* data, size_t size) {
    uint64_t hash = 14695981039346656037ULL;
    const auto* bytes = static_cast<const uint8_t*>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

uint64_t fnv1aImage(const sony2fuji::ImageData& image) {
    uint64_t hash = 14695981039346656037ULL;
    auto mix = [&](const void* ptr, size_t bytes) {
        const auto* data = static_cast<const uint8_t*>(ptr);
        for (size_t i = 0; i < bytes; ++i) {
            hash ^= data[i];
            hash *= 1099511628211ULL;
        }
    };
    mix(&image.width, sizeof(image.width));
    mix(&image.height, sizeof(image.height));
    if (!image.pixels.empty()) {
        mix(image.pixels.data(), image.pixels.size() * sizeof(sony2fuji::RGB));
    }
    return hash;
}

sony2fuji::ImageData makePatternImage(int width, int height) {
    sony2fuji::ImageData image(width, height);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const float u = width > 1 ? float(x) / float(width - 1) : 0.25f;
            const float v = height > 1 ? float(y) / float(height - 1) : 0.5f;
            const float r = 0.05f + 0.85f * u;
            const float g = 0.04f + 0.88f * v;
            const float b = 0.06f + 0.82f * ((x * 37 + y * 13) % 97) / 96.0f;
            image.at(x, y) = sony2fuji::RGB(r, g, b);
        }
    }
    return image;
}

struct ThreadCountGuard {
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    int previous = cv::getNumThreads();
    explicit ThreadCountGuard(int target) { cv::setNumThreads(target); }
    ~ThreadCountGuard() { cv::setNumThreads(previous); }
#else
    explicit ThreadCountGuard(int) {}
#endif
};

int multiThreadCount() {
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    return std::max(4, cv::getNumberOfCPUs());
#else
    return 1;
#endif
}

std::shared_ptr<sony2fuji::LUT3D> makeDomainLUT() {
    auto lut = std::make_shared<sony2fuji::LUT3D>();
    const std::string cube =
        "TITLE \"CustomDomain\"\n"
        "DOMAIN_MIN 0.1 0.15 0.2\n"
        "DOMAIN_MAX 0.9 0.85 0.95\n"
        "LUT_3D_SIZE 2\n"
        "0.02 0.01 0.03\n"
        "0.95 0.04 0.05\n"
        "0.03 0.92 0.06\n"
        "0.91 0.94 0.08\n"
        "0.04 0.05 0.93\n"
        "0.96 0.07 0.90\n"
        "0.06 0.93 0.94\n"
        "0.97 0.98 0.96\n";
    lut->loadFromData(cube);
    return lut;
}

bool imagesBitEqual(const sony2fuji::ImageData& a, const sony2fuji::ImageData& b) {
    if (a.width != b.width || a.height != b.height || a.pixels.size() != b.pixels.size()) {
        return false;
    }
    if (fnv1aImage(a) != fnv1aImage(b)) {
        return false;
    }
    return a.pixels.empty() ||
        std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(sony2fuji::RGB)) == 0;
}

struct ForeignWorkerException {};

} // namespace

int main(int argc, char** argv) {
    int failures = 0;
    auto check = [&](bool ok, const char* label) {
        std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
        if (!ok) ++failures;
    };

    const int mt = multiThreadCount();
    const auto lut = makeDomainLUT();
    const std::pair<int, int> sizes[] = {{1, 1}, {257, 257}, {512, 256}};

    auto compareStage = [&](const char* name, auto fn) {
        for (const auto& [w, h] : sizes) {
            sony2fuji::ImageData seq = makePatternImage(w, h);
            sony2fuji::ImageData par = makePatternImage(w, h);
            {
                ThreadCountGuard g(1);
                fn(seq);
            }
            {
                ThreadCountGuard g(mt);
                fn(par);
            }
            const bool equal = imagesBitEqual(seq, par);
            if (!equal) {
                std::cerr << "Parity mismatch stage=" << name << " size=" << w << "x" << h
                          << " seq_fnv=" << std::hex << fnv1aImage(seq)
                          << " par_fnv=" << fnv1aImage(par) << std::dec << '\n';
            }
            check(equal, name);
        }
    };

    compareStage("ColorConverter::convertImage", [](sony2fuji::ImageData& img) {
        sony2fuji::ColorConverter().convertImage(img, sony2fuji::ColorSpace::sRGB, sony2fuji::ColorSpace::FujiFilm_FGamut);
    });
    compareStage("GammaConverter::applyFLog2ToImage", [](sony2fuji::ImageData& img) {
        sony2fuji::GammaConverter::applyFLog2ToImage(img, {});
    });
    compareStage("encodePhotoLUTInput/renderPhotoLUTOutput", [](sony2fuji::ImageData& img) {
        sony2fuji::encodePhotoLUTInput(img, sony2fuji::LUTTransfer::FLog2C);
        sony2fuji::renderPhotoLUTOutput(img, sony2fuji::LUTTransfer::FLog2C);
    });
    compareStage("LUTApplicator::applyToImage(inplace)", [&](sony2fuji::ImageData& img) {
        sony2fuji::LUTApplicator(lut).applyToImage(img);
    });
    compareStage("LUTApplicator::applyToImage(copy)", [&](sony2fuji::ImageData& img) {
        sony2fuji::ImageData out;
        sony2fuji::LUTApplicator(lut).applyToImage(img, out);
        img = std::move(out);
    });
    compareStage("applyLUTWithConfig(custom_domain_cpu)", [&](sony2fuji::ImageData& img) {
        sony2fuji::GpuConfig cpu{sony2fuji::GpuMode::Off};
        sony2fuji::applyLUTWithConfig(lut, img, cpu);
    });
    compareStage("applyBlackWhite", [](sony2fuji::ImageData& img) {
        sony2fuji::ToneControlsOptions opts{15.0f, -12.0f, 25.0f};
        sony2fuji::applyBlackWhite(img, opts);
    });
    compareStage("applyHsl", [](sony2fuji::ImageData& img) {
        sony2fuji::HslOptions opts;
        opts.hue[0] = 20.0f;
        opts.saturation[1] = 35.0f;
        opts.lightness[2] = -25.0f;
        sony2fuji::applyHsl(img, opts);
    });
    compareStage("applyColorGrading", [](sony2fuji::ImageData& img) {
        sony2fuji::ColorGradingOptions opts;
        opts.wheels[0] = {35.0f, 30.0f};
        opts.wheels[1] = {140.0f, 15.0f};
        opts.wheels[2] = {225.0f, 40.0f};
        sony2fuji::applyColorGrading(img, opts);
    });
    compareStage("applyPhotoEffects(vignette+grain)", [](sony2fuji::ImageData& img) {
        sony2fuji::PhotoEffectsOptions opts;
        opts.vignetteAmount = -40.0f;
        opts.vignetteMidpoint = 45.0f;
        opts.grainAmount = 35.0f;
        sony2fuji::applyPhotoEffects(img, opts);
    });
    compareStage("applyGeometry(straighten+perspective)", [](sony2fuji::ImageData& img) {
        sony2fuji::GeometryOptions opts;
        opts.straighten_degrees = 3.5f;
        opts.perspective_horizontal = 0.2f;
        sony2fuji::applyGeometry(img, opts);
    });

    // C ABI GPU=OFF buffer pipeline parity (1 vs mt threads)
    {
        auto runCAbi = [&](int threads, int width, int height, sony2fuji_pixel_format inFmt,
                           sony2fuji_output_format outFmt, const std::string& lutPath,
                           std::vector<uint8_t>& outBytes, uint64_t& hash) {
            ThreadCountGuard g(threads);
            sony2fuji_session* session = nullptr;
            if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return false;
            sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
            sony2fuji_session_set_gpu_config(session, &gpu);
            sony2fuji_tone_controls_config tone{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tone), 0.15f, -0.1f, 0.25f};
            sony2fuji_session_set_tone_controls(session, &tone);
            sony2fuji_hsl_config hsl{};
            hsl.version = SONY2FUJI_HSL_CONFIG_VERSION;
            hsl.struct_size = sizeof(hsl);
            hsl.hue[0] = 15.0f;
            hsl.saturation[2] = 30.0f;
            sony2fuji_session_set_hsl(session, &hsl);
            sony2fuji_color_grading_config cg{SONY2FUJI_COLOR_GRADING_CONFIG_VERSION, sizeof(cg), 30.f, 20.f, 120.f, 10.f, 220.f, 25.f};
            sony2fuji_session_set_color_grading(session, &cg);
            sony2fuji_photo_effects_config fx{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION, sizeof(fx), -30.f, 50.f, 0.f, 50.f, 25.f, 30.f, 25.f, 50.f};
            sony2fuji_session_set_photo_effects(session, &fx);
            sony2fuji_geometry_config geom{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(geom), 0.f, 0.f, 1.f, 1.f, 0, 0, 0, 2.5f};
            sony2fuji_session_set_geometry(session, &geom);

            const size_t pxCount = size_t(width) * height;
            std::vector<uint8_t> inBuf;
            if (inFmt == SONY2FUJI_PIXEL_RGBA16) {
                inBuf.resize(pxCount * 8);
                for (size_t i = 0; i < pxCount; ++i) {
                    uint16_t r = uint16_t((i * 257) % 65536);
                    uint16_t gg = uint16_t((i * 521) % 65536);
                    uint16_t b = uint16_t((i * 997) % 65536);
                    inBuf[i * 8 + 0] = uint8_t(r & 0xFF); inBuf[i * 8 + 1] = uint8_t(r >> 8);
                    inBuf[i * 8 + 2] = uint8_t(gg & 0xFF); inBuf[i * 8 + 3] = uint8_t(gg >> 8);
                    inBuf[i * 8 + 4] = uint8_t(b & 0xFF); inBuf[i * 8 + 5] = uint8_t(b >> 8);
                    inBuf[i * 8 + 6] = 255; inBuf[i * 8 + 7] = 255;
                }
            } else {
                inBuf.resize(pxCount * 4);
                for (size_t i = 0; i < pxCount; ++i) {
                    inBuf[i * 4 + 0] = uint8_t((i * 17) % 256);
                    inBuf[i * 4 + 1] = uint8_t((i * 43) % 256);
                    inBuf[i * 4 + 2] = uint8_t((i * 89) % 256);
                    inBuf[i * 4 + 3] = 255;
                }
            }
            sony2fuji_request req{};
            req.version = SONY2FUJI_REQUEST_VERSION;
            req.struct_size = sizeof(req);
            req.input_type = SONY2FUJI_INPUT_DISPLAY_BUFFER;
            req.input_pixels = inBuf.data();
            req.input_width = uint32_t(width);
            req.input_height = uint32_t(height);
            req.input_pixel_format = inFmt;
            req.input_color_space = SONY2FUJI_COLOR_SRGB;
            req.input_is_linear = 0;
            req.lut_path = lutPath.empty() ? nullptr : lutPath.c_str();
            req.lut_strength = 0.85f;
            req.exposure_ev = 0.25f;
            req.brightness = 1.05f;
            req.contrast = 1.1f;
            req.saturation = 1.08f;
            req.temperature = 6500.0f;
            req.wb_mode = SONY2FUJI_WB_CAMERA;
            req.output_target = SONY2FUJI_TARGET_BUFFER;
            req.output_format = outFmt;
            req.intent = SONY2FUJI_INTENT_FINAL;
            req.size_mode = SONY2FUJI_SIZE_EXACT;
            req.target_width = uint32_t(std::max(1, width / 2));
            req.target_height = uint32_t(std::max(1, height / 2));

            sony2fuji_buffer out{};
            const auto st = sony2fuji_process(session, &req, &out);
            bool ok = (st == SONY2FUJI_STATUS_OK && out.data && out.size_bytes > 0);
            if (ok) {
                outBytes.assign(static_cast<const uint8_t*>(out.data),
                    static_cast<const uint8_t*>(out.data) + out.size_bytes);
                hash = fnv1aBytes(outBytes.data(), outBytes.size());
            }
            sony2fuji_release_buffer(&out);
            sony2fuji_session_destroy(session);
            return ok;
        };

        for (const auto& [w, h] : sizes) {
            std::vector<uint8_t> b1, bm;
            uint64_t h1 = 0, hm = 0;
            bool ok = runCAbi(1, w, h, SONY2FUJI_PIXEL_RGBA8, SONY2FUJI_OUTPUT_RGBA8, "", b1, h1) &&
                      runCAbi(mt, w, h, SONY2FUJI_PIXEL_RGBA8, SONY2FUJI_OUTPUT_RGBA8, "", bm, hm) &&
                      h1 == hm && b1 == bm;
            check(ok, "C ABI RGBA8 full CPU pipeline parity");

            std::vector<uint8_t> b1_16, bm_16;
            uint64_t h1_16 = 0, hm_16 = 0;
            bool ok16 = runCAbi(1, w, h, SONY2FUJI_PIXEL_RGBA16, SONY2FUJI_OUTPUT_RGBA8, "", b1_16, h1_16) &&
                        runCAbi(mt, w, h, SONY2FUJI_PIXEL_RGBA16, SONY2FUJI_OUTPUT_RGBA8, "", bm_16, hm_16) &&
                        h1_16 == hm_16 && b1_16 == bm_16;
            check(ok16, "C ABI RGBA16 input pipeline parity");
        }
    }

    // Worker-thread cancellation & one-shot bare processingCancellation check (multi-threaded)
    {
        ThreadCountGuard g(mt);
        {
            // One-shot callback WITHOUT ProcessingCancellationScope (latch == nullptr)
            struct OneShot {
                std::atomic<int> count{0};
            } state;
            auto oneShotCb = +[](void* ctx) -> int32_t {
                const int n = static_cast<OneShot*>(ctx)->count.fetch_add(1) + 1;
                return n == 5 ? 1 : 0; // returns 1 ONLY once, inside worker loop!
            };
            const auto prev = sony2fuji::processingCancellation;
            sony2fuji::processingCancellation = {oneShotCb, &state, nullptr};
            bool pixelCancelled = false;
            try {
                sony2fuji::parallelPixelRanges(512 * 256, [&](size_t, size_t) {});
            } catch (const sony2fuji::ProcessingCancelled&) {
                pixelCancelled = true;
            }
            sony2fuji::processingCancellation = prev;
            check(pixelCancelled, "Bare one-shot cancellation in parallelPixelRanges worker is not swallowed");

            state.count.store(0);
            sony2fuji::processingCancellation = {oneShotCb, &state, nullptr};
            bool rowCancelled = false;
            try {
                sony2fuji::parallelRowRanges(512, 256, [&](int, int) {});
            } catch (const sony2fuji::ProcessingCancelled&) {
                rowCancelled = true;
            }
            sony2fuji::processingCancellation = prev;
            check(rowCancelled, "Bare one-shot cancellation in parallelRowRanges worker is not swallowed");
        }

        // Foreign exception from worker callback must rethrow on calling thread, never std::terminate
        {
            std::atomic<int> count{0};
            auto throwAt5 = +[](void* ctx) -> int32_t {
                if (static_cast<std::atomic<int>*>(ctx)->fetch_add(1) + 1 == 5) {
                    throw ForeignWorkerException{};
                }
                return 0;
            };
            sony2fuji::ProcessingCancellationScope scope({throwAt5, &count});
            bool caughtPixel = false;
            try {
                sony2fuji::parallelPixelRanges(512 * 256, [&](size_t, size_t) {});
            } catch (const ForeignWorkerException&) {
                caughtPixel = true;
            }
            check(caughtPixel, "Foreign exception on parallelPixelRanges worker rethrows on calling thread");
        }
        {
            std::atomic<int> count{0};
            auto throwAt5 = +[](void* ctx) -> int32_t {
                if (static_cast<std::atomic<int>*>(ctx)->fetch_add(1) + 1 == 5) {
                    throw ForeignWorkerException{};
                }
                return 0;
            };
            sony2fuji::ProcessingCancellationScope scope({throwAt5, &count});
            bool caughtRow = false;
            try {
                sony2fuji::parallelRowRanges(512, 256, [&](int, int) {});
            } catch (const ForeignWorkerException&) {
                caughtRow = true;
            }
            check(caughtRow, "Foreign exception on parallelRowRanges worker rethrows on calling thread");
        }

        // Core parallelized stages interrupt cleanly when cancelled mid-worker
        auto checkStageCancel = [&](const char* label, auto fn) {
            sony2fuji::ImageData image = makePatternImage(512, 256);
            std::atomic<int> remaining{5};
            sony2fuji::ProcessingCancellationScope scope({+[](void* ctx) -> int32_t {
                return static_cast<std::atomic<int>*>(ctx)->fetch_sub(1) <= 1;
            }, &remaining});
            bool cancelled = false;
            try {
                fn(image);
            } catch (const sony2fuji::ProcessingCancelled&) {
                cancelled = true;
            }
            check(cancelled, label);
        };
        checkStageCancel("GammaConverter::applyFLog2ToImage worker cancellation", [](sony2fuji::ImageData& img) {
            sony2fuji::GammaConverter::applyFLog2ToImage(img, {});
        });
        checkStageCancel("applyPhotoEffects worker cancellation", [](sony2fuji::ImageData& img) {
            sony2fuji::PhotoEffectsOptions opts;
            opts.vignetteAmount = -35.0f;
            opts.grainAmount = 25.0f;
            sony2fuji::applyPhotoEffects(img, opts);
        });
        checkStageCancel("applyGeometry(resample) worker cancellation", [](sony2fuji::ImageData& img) {
            sony2fuji::GeometryOptions opts;
            opts.straighten_degrees = 3.0f;
            sony2fuji::applyGeometry(img, opts);
        });
    }

    // Optional real RAW determinism check when SONY2FUJI_TEST_RAW is provided as argv[1]
    if (argc > 1 && argv[1] && argv[1][0] != '\0') {
        const std::string rawPath = argv[1];
        if (!std::filesystem::exists(rawPath)) {
            std::cout << "SKIP raw parity: missing " << rawPath << '\n';
            return failures == 0 ? 77 : 1;
        }
        auto runRaw = [&](int threads, std::vector<uint8_t>& bytes, uint64_t& hash) {
            ThreadCountGuard g(threads);
            sony2fuji_session* session = nullptr;
            if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return false;
            sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
            sony2fuji_session_set_gpu_config(session, &gpu);
            sony2fuji_tone_controls_config tone{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(tone), 0.10f, -0.05f, 0.2f};
            sony2fuji_session_set_tone_controls(session, &tone);
            sony2fuji_hsl_config hsl{};
            hsl.version = SONY2FUJI_HSL_CONFIG_VERSION;
            hsl.struct_size = sizeof(hsl);
            hsl.hue[0] = 10.0f;
            hsl.saturation[2] = 15.0f;
            sony2fuji_session_set_hsl(session, &hsl);
            sony2fuji_color_grading_config cg{SONY2FUJI_COLOR_GRADING_CONFIG_VERSION, sizeof(cg), 30.f, 15.f, 120.f, 10.f, 220.f, 20.f};
            sony2fuji_session_set_color_grading(session, &cg);
            sony2fuji_photo_effects_config fx{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION, sizeof(fx), -25.f, 50.f, 0.f, 50.f, 20.f, 20.f, 25.f, 50.f};
            sony2fuji_session_set_photo_effects(session, &fx);
            sony2fuji_geometry_config geom{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(geom), 0.f, 0.f, 1.f, 1.f, 0, 0, 0, 2.0f};
            sony2fuji_session_set_geometry(session, &geom);
            sony2fuji_request req{};
            req.version = SONY2FUJI_REQUEST_VERSION;
            req.struct_size = sizeof(req);
            req.input_path = rawPath.c_str();
            req.input_type = SONY2FUJI_INPUT_RAW;
            req.output_target = SONY2FUJI_TARGET_BUFFER;
            req.output_format = SONY2FUJI_OUTPUT_RGB8;
            req.intent = SONY2FUJI_INTENT_PREVIEW;
            req.preview_long_edge = 1600;
            req.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
            req.long_edge = 1600;
            req.brightness = 1.0f;
            req.contrast = 1.0f;
            req.saturation = 1.0f;
            req.temperature = 6500.0f;
            req.wb_mode = SONY2FUJI_WB_CAMERA;
            sony2fuji_buffer out{};
            const auto st = sony2fuji_process(session, &req, &out);
            bool ok = (st == SONY2FUJI_STATUS_OK && out.data && out.size_bytes > 0);
            if (!ok) {
                std::cerr << "RAW parity request failed status=" << int(st) << '\n';
            }
            if (ok) {
                bytes.assign(static_cast<const uint8_t*>(out.data),
                    static_cast<const uint8_t*>(out.data) + out.size_bytes);
                hash = fnv1aBytes(bytes.data(), bytes.size());
            }
            sony2fuji_release_buffer(&out);
            sony2fuji_session_destroy(session);
            return ok;
        };
        std::vector<uint8_t> r1, rm;
        uint64_t h1 = 0, hm = 0;
        const bool okRaw = runRaw(1, r1, h1) && runRaw(mt, rm, hm) && h1 == hm && r1 == rm;
        check(okRaw, "C ABI RAW GPU=OFF preview pipeline parity");
    }

    return failures == 0 ? 0 : 1;
}
