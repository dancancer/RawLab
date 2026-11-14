#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/raw_processor.h"
#include "core/output_file_mode.h"
#include "core/processing_cancellation.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_tone_controls.h"
#include "core/photo_effects.h"
#include "core/photo_geometry.h"
#include "core/photo_lut.h"
#include "core/chroma_denoise.h"
#include "core/wavelet_denoise.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <random>
#include <string>
#include <vector>
#ifdef _WIN32
#include <process.h>
#define RAWLAB_TEST_GETPID _getpid
#else
#include <sys/stat.h>
#include <unistd.h>
#define RAWLAB_TEST_GETPID getpid
#endif
#include <cctype>

namespace {

// Matches every staging name the encoders can leave behind: the POSIX mkstemp
// patterns contain ".rawlab-", and GetTempFileNameW emits "<prefix>####.tmp".
#ifndef _WIN32
unsigned fileMode(const std::filesystem::path& path) {
    struct stat info{};
    return ::stat(path.c_str(), &info) == 0 ? static_cast<unsigned>(info.st_mode & 0777) : 0u;
}
#endif

bool isStagingFile(const std::filesystem::path& path) {
    const std::string name = path.filename().string();
    if (name.find(".rawlab-") != std::string::npos) return true;
#ifdef _WIN32
    std::string lower = path.extension().string();
    for (auto& ch : lower) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    if (lower == ".tmp" &&
        (name.rfind("rlj", 0) == 0 || name.rfind("rlp", 0) == 0 || name.rfind("rld", 0) == 0))
        return true;
#endif
    return false;
}

} // namespace

int main() {
    int failures = 0;
    auto check = [&](bool ok, const char* label) {
        std::cout << (ok ? "PASS " : "FAIL ") << label << '\n';
        if (!ok) ++failures;
    };
    sony2fuji_session* session = nullptr;
    check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Create a render session");
    std::vector<unsigned char> pixels(512 * 512 * 3, 64);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER; request.input_pixels = pixels.data();
    request.input_width = request.input_height = 512;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8; request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1; request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8; request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.size_mode = SONY2FUJI_SIZE_EXACT; request.target_width = request.target_height = 128;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500; request.wb_mode = SONY2FUJI_WB_CAMERA;
    sony2fuji_gpu_config cpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(cpu), SONY2FUJI_GPU_OFF};
    sony2fuji_session_set_gpu_config(session, &cpu);
    for (int checkpoint : {1, 12, 80}) {
        std::atomic<int> remaining{checkpoint};
        auto callback = +[](void* context) -> int32_t {
            return static_cast<std::atomic<int>*>(context)->fetch_sub(1) <= 1;
        };
        sony2fuji_session_set_cancellation_callback(session, callback, &remaining);
        sony2fuji_buffer output{};
        check(sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_CANCELLED,
            "Cancellation interrupts a preview before and during pixel processing");
        check(output.data == nullptr && output.size_bytes == 0, "Cancelled preview does not publish partial pixels");
        sony2fuji_release_buffer(&output);
        sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
        check(sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OK && output.width == 128,
            "The same session renders successfully after cancellation");
        sony2fuji_release_buffer(&output);
    }
    sony2fuji_session_set_cancellation_callback(session, +[](void*) -> int32_t { return 1; }, nullptr);
    sony2fuji_hsl_probe* probe = nullptr;
    check(sony2fuji_session_create_hsl_probe(session, &request, 1, 1, &probe) == SONY2FUJI_STATUS_CANCELLED && !probe,
        "Superseded HSL analysis is cancellable and never publishes a partial probe");
    sony2fuji_hsl_probe_destroy(probe);
    {
        struct UnknownForeignException {};
        sony2fuji_request smallRequest = request;
        smallRequest.input_width = smallRequest.input_height = 64;
        smallRequest.target_width = smallRequest.target_height = 32;
        for (int checkpoint : {1, 4}) {
            std::atomic<int> remaining{checkpoint};
            auto foreignThrow = +[](void* context) -> int32_t {
                if (static_cast<std::atomic<int>*>(context)->fetch_sub(1) <= 1)
                    throw UnknownForeignException{};
                return 0;
            };
            sony2fuji_session_set_cancellation_callback(session, foreignThrow, &remaining);
            sony2fuji_buffer output{};
            check(sony2fuji_process(session, &smallRequest, &output) == SONY2FUJI_STATUS_PROCESSING_ERROR,
                "Non-std::exception inside sony2fuji_process maps to PROCESSING_ERROR instead of escaping");
            check(output.data == nullptr && output.size_bytes == 0,
                "Foreign exception does not publish partial output buffer");
            sony2fuji_release_buffer(&output);
            sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
            check(sony2fuji_process(session, &smallRequest, &output) == SONY2FUJI_STATUS_OK && output.width == 32,
                "Session remains valid after catching a non-std::exception");
            sony2fuji_release_buffer(&output);
        }
        const auto lutPath = std::filesystem::temp_directory_path() /
            ("rawlab-cancel-foreign-" + std::to_string(RAWLAB_TEST_GETPID()) + ".cube");
        {
            std::ofstream cubeFile(lutPath, std::ios::binary);
            cubeFile << "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
        }
        const std::string lutPathUtf8 = lutPath.u8string();
        sony2fuji_blob compatInfo{};
        check(sony2fuji_inspect_lut_compatibility(lutPathUtf8.c_str(), &compatInfo) == SONY2FUJI_STATUS_OK && compatInfo.data,
            "Inspect temporary LUT compatibility draft");
        if (compatInfo.data) {
            const std::string draft(static_cast<const char*>(compatInfo.data), compatInfo.size_bytes);
            const auto shaPos = draft.find("\"source_sha256\":\"");
            const std::string sha = shaPos != std::string::npos ? draft.substr(shaPos + 17, 64) : "";
            const std::string previewConfig =
                "{\"source_sha256\":\"" + sha + "\",\"contract\":{\"version\":1,"
                "\"input\":{\"space\":\"rec709-gamma24\",\"reference\":\"display\",\"range\":\"full\"},"
                "\"output\":{\"space\":\"rec709-gamma24\",\"reference\":\"display\",\"range\":\"full\"},"
                "\"interpolation\":\"linear\",\"base_rendering\":\"rawlab-neutral-v1\"}}";
            sony2fuji_request compatRequest = smallRequest;
            compatRequest.lut_path = lutPathUtf8.c_str();
            compatRequest.lut_strength = 1.0f;
            compatRequest.preview_long_edge = 16;
            sony2fuji::ProcessingCancellationScope foreignScope({+[](void*) -> int32_t {
                throw UnknownForeignException{};
            }, nullptr});
            sony2fuji_buffer previewOut{};
            check(sony2fuji_preview_lut_compatibility(session, &compatRequest, previewConfig.c_str(), &previewOut) ==
                    SONY2FUJI_STATUS_PROCESSING_ERROR && !previewOut.data,
                "Non-std::exception inside sony2fuji_preview_lut_compatibility maps to PROCESSING_ERROR instead of escaping");
            sony2fuji_x3f_mode x3fMode = SONY2FUJI_X3F_NORMAL;
            check(sony2fuji_x3f_default_mode(lutPathUtf8.c_str(), &x3fMode) == SONY2FUJI_STATUS_PROCESSING_ERROR &&
                    x3fMode == SONY2FUJI_X3F_NORMAL,
                "Non-std::exception inside sony2fuji_x3f_default_mode maps to PROCESSING_ERROR instead of escaping");
        }
        sony2fuji_release_blob(&compatInfo);
        std::error_code removeError;
        std::filesystem::remove(lutPath, removeError);
    }
    auto cancelsStage = [&](const char* label, auto apply) {
        sony2fuji::ImageData image(512, 512);
        std::fill(image.pixels.begin(), image.pixels.end(), sony2fuji::RGB(.2f, .3f, .4f));
        std::atomic<int> remaining{3};
        sony2fuji::ProcessingCancellationScope cancellation({+[](void* context) -> int32_t {
            return static_cast<std::atomic<int>*>(context)->fetch_sub(1) <= 1;
        }, &remaining});
        bool interrupted = false;
        try { apply(image); }
        catch (const sony2fuji::ProcessingCancelled&) { interrupted = true; }
        check(interrupted, label);
    };
    cancelsStage("HSL stops inside the active CPU stage", [](auto& image) {
        sony2fuji::HslOptions options; options.hue[0] = 20; sony2fuji::applyHsl(image, options);
    });
    cancelsStage("Color grading stops inside the active CPU stage", [](auto& image) {
        sony2fuji::ColorGradingOptions options; options.wheels[0].saturation = 40; sony2fuji::applyColorGrading(image, options);
    });
    cancelsStage("Black point stops inside the active CPU stage", [](auto& image) {
        sony2fuji::ToneControlsOptions options; options.blackPoint = 20; sony2fuji::applyBlackWhite(image, options);
    });
    cancelsStage("Grain stops inside the active CPU stage", [](auto& image) {
        sony2fuji::PhotoEffectsOptions options; options.grainAmount = 20; sony2fuji::applyPhotoEffects(image, options);
    });
    cancelsStage("Integer crop stops inside its row copy", [](auto& image) {
        sony2fuji::GeometryOptions options; options.crop_width = .5; sony2fuji::applyGeometry(image, options);
    });
    cancelsStage("F-Log input transfer stops inside its pixel loop", [](auto& image) {
        sony2fuji::encodePhotoLUTInput(image, sony2fuji::LUTTransfer::FLog);
    });
    cancelsStage("F-Log output transfer stops inside its pixel loop", [](auto& image) {
        sony2fuji::renderPhotoLUTOutput(image, sony2fuji::LUTTransfer::FLog);
    });
    cancelsStage("F-Log2 encoding stops inside its pixel loop", [](auto& image) {
        sony2fuji::GammaConverter::FLog2Options options;
        sony2fuji::GammaConverter::applyFLog2ToImage(image, options);
    });
#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE) || defined(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    // Denoise tile loops honour the callback at the next tile boundary and never
    // publish a half-denoised image. Flat fixtures would exit early (LowNoise or
    // confidence==0), so these use the same noisy-synth recipes as the denoise tests.
    std::mt19937 denoiseRng(20261114u);
    auto countdown = +[](void* context) -> int32_t {
        return static_cast<std::atomic<int>*>(context)->fetch_sub(1) <= 1;
    };
    auto unchanged = [](const sony2fuji::ImageData& image, const std::vector<sony2fuji::RGB>& pristine) {
        return std::memcmp(image.pixels.data(), pristine.data(), pristine.size() * sizeof(sony2fuji::RGB)) == 0;
    };
#endif
#if defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    {
        // The C5 path analyses and filters in 512px tiles on the calling thread;
        // polling must stop the run mid-image (3rd tile) instead of after it.
        sony2fuji::ImageData image(800, 600);
        std::normal_distribution<float> noise(0.f, .014f);
        for (auto& p : image.pixels) p = {.18f + noise(denoiseRng), .18f + noise(denoiseRng), .18f + noise(denoiseRng)};
        const auto pristine = image.pixels;
        std::atomic<int> remaining{3};
        bool interrupted = false;
        {
            sony2fuji::ProcessingCancellationScope cancellation({countdown, &remaining});
            try {
                const sony2fuji::WaveletDenoiseOptions options{true, 40, 46, 50};
                sony2fuji::applyWaveletDenoise(image, options);
            }
            catch (const sony2fuji::ProcessingCancelled&) { interrupted = true; }
        }
        check(interrupted, "Wavelet denoise stops inside its tile loop");
        check(unchanged(image, pristine), "Cancelled wavelet denoise publishes no partial pixels");
        // The Legacy path filters through cv::parallel_for_ tiles; workers must exit
        // at their next tile and only the calling thread may throw.
        sony2fuji::ImageData legacy(1280, 720);
        for (auto& p : legacy.pixels) p = {.18f + noise(denoiseRng), .18f + noise(denoiseRng), .18f + noise(denoiseRng)};
        const auto legacyPristine = legacy.pixels;
        std::atomic<int> legacyRemaining{3};
        interrupted = false;
        {
            sony2fuji::ProcessingCancellationScope cancellation({countdown, &legacyRemaining});
            try {
                sony2fuji::WaveletDenoiseOptions options{true, 10, 72, 100};
                options.processingVersion = sony2fuji::ProcessingVersion::Legacy;
                sony2fuji::applyWaveletDenoise(legacy, options);
            }
            catch (const sony2fuji::ProcessingCancelled&) { interrupted = true; }
        }
        check(interrupted, "Legacy wavelet denoise stops inside its parallel tile loop");
        check(unchanged(legacy, legacyPristine), "Cancelled legacy wavelet denoise publishes no partial pixels");
    }
#endif
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE)
    {
        // Guided chroma runs in independent 768px tiles; cancelling on the third
        // tile must throw before the Lab image is converted back to the RGB view.
        sony2fuji::ImageData image(1600, 800);
        std::normal_distribution<float> noise(0.f, .025f);
        for (auto& p : image.pixels) p = {.45f + noise(denoiseRng), .45f + noise(denoiseRng), .45f + noise(denoiseRng)};
        const auto pristine = image.pixels;
        std::atomic<int> remaining{3};
        bool interrupted = false;
        {
            sony2fuji::ProcessingCancellationScope cancellation({countdown, &remaining});
            try { sony2fuji::applyChromaDenoise(image, 1); }
            catch (const sony2fuji::ProcessingCancelled&) { interrupted = true; }
        }
        check(interrupted, "Chroma denoise stops inside its guided tile loop");
        check(unchanged(image, pristine), "Cancelled chroma denoise publishes no partial pixels");
        // The working-graph entry (Metal band pipeline) keeps its partial bands;
        // the contract there is that the caller discards the image on failure.
        sony2fuji::ImageData working(1600, 800);
        working.pixels = pristine;
        std::atomic<int> workingRemaining{3};
        interrupted = false;
        {
            sony2fuji::ProcessingCancellationScope cancellation({countdown, &workingRemaining});
            try { sony2fuji::applyChromaDenoiseWorking(working, 1); }
            catch (const sony2fuji::ProcessingCancelled&) { interrupted = true; }
        }
        check(interrupted, "Working chroma denoise stops at a band boundary for the caller to discard");
    }
#endif
    // FINAL exports honour the callback and never publish a partial file. The destination is
    // pre-populated so "cancelled" can be distinguished from "wrote a fresh file".
    {
        const auto root = std::filesystem::temp_directory_path() /
            ("rawlab-cancel-final-" + std::to_string(RAWLAB_TEST_GETPID()));
        std::error_code cleanupError;
        std::filesystem::remove_all(root, cleanupError);
        std::filesystem::create_directories(root);
        const std::vector<unsigned char> existing = {0x6f, 0x6c, 0x64};
        auto writeFile = [](const std::filesystem::path& path, const std::vector<unsigned char>& bytes) {
            std::ofstream out(path, std::ios::binary | std::ios::trunc);
            out.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        };
        auto readFile = [](const std::filesystem::path& path) {
            std::ifstream in(path, std::ios::binary);
            return std::vector<unsigned char>(std::istreambuf_iterator<char>(in),
                std::istreambuf_iterator<char>());
        };
        auto stagingResidue = [](const std::filesystem::path& dir) {
            int count = 0;
            for (const auto& entry : std::filesystem::directory_iterator(dir))
                if (isStagingFile(entry.path())) ++count;
            return count;
        };

        std::vector<unsigned char> exportPixels(256 * 256 * 3, 96);
        sony2fuji_request exportRequest = request;
        exportRequest.input_pixels = exportPixels.data();
        exportRequest.input_width = exportRequest.input_height = 256;
        exportRequest.intent = SONY2FUJI_INTENT_FINAL;
        exportRequest.output_target = SONY2FUJI_TARGET_FILE;
        exportRequest.size_mode = SONY2FUJI_SIZE_EXACT;
        exportRequest.target_width = exportRequest.target_height = 128;
        exportRequest.jpeg_quality = 90;

        struct ExportCase { sony2fuji_output_format format; const char* name; const char* label; std::vector<unsigned char> magic; };
        for (const auto& exportCase : {ExportCase{SONY2FUJI_OUTPUT_JPEG, "export.jpg", "JPEG", {0xff, 0xd8}},
                                       ExportCase{SONY2FUJI_OUTPUT_PNG, "export.png", "PNG", {0x89, 'P', 'N', 'G'}},
                                       ExportCase{SONY2FUJI_OUTPUT_DNG, "export.dng", "DNG", {'I', 'I'}}}) {
            const auto target = root / exportCase.name;
            const std::string okLabel = std::string("FINAL ") + exportCase.label +
                " export succeeds and polls the cancellation callback";
            const std::string targetPath = target.u8string();
            exportRequest.output_format = exportCase.format;
            exportRequest.output_path = targetPath.c_str();
            writeFile(target, existing);

            std::atomic<int> polls{0};
            sony2fuji_session_set_cancellation_callback(session, +[](void* context) -> int32_t {
                static_cast<std::atomic<int>*>(context)->fetch_add(1);
                return 0;
            }, &polls);
            sony2fuji_buffer exported{};
            const auto exportStatus = sony2fuji_process(session, &exportRequest, &exported);
            sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
            sony2fuji_release_buffer(&exported);
            check(exportStatus == SONY2FUJI_STATUS_OK && polls.load() > 0, okLabel.c_str());
            if (exportStatus != SONY2FUJI_STATUS_OK || polls.load() <= 0) continue;
            const std::string earlyLabel = std::string("FINAL ") + exportCase.label +
                " export cancels early and leaves the target untouched";
            {
                writeFile(target, existing);
                std::atomic<int> remaining{1};
                sony2fuji_session_set_cancellation_callback(session, +[](void* context) -> int32_t {
                    return static_cast<std::atomic<int>*>(context)->fetch_sub(1) <= 1;
                }, &remaining);
                sony2fuji_buffer cancelled{};
                const auto cancelStatus = sony2fuji_process(session, &exportRequest, &cancelled);
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                sony2fuji_release_buffer(&cancelled);
                check(cancelStatus == SONY2FUJI_STATUS_CANCELLED, earlyLabel.c_str());
                check(readFile(target) == existing, "Cancelled FINAL export keeps the existing target byte-identical");
                check(stagingResidue(root) == 0, "Cancelled FINAL export removes its staging file");
            }

            // Cancel as soon as the encoder has staged bytes but has not replaced the target yet. This
            // is the commit point: it holds for every format without depending on a poll count, and it
            // fails (export completes, target replaced) when the encoder skips its final check.
            {
                writeFile(target, existing);
                struct StagingWatch { std::filesystem::path directory; };
                StagingWatch watch{root};
                sony2fuji_session_set_cancellation_callback(session, +[](void* context) -> int32_t {
                    const auto& watch = *static_cast<StagingWatch*>(context);
                    std::error_code error;
                    for (std::filesystem::directory_iterator it(watch.directory, error), last;
                         !error && it != last; it.increment(error)) {
                        if (isStagingFile(it->path())) return 1;
                    }
                    return 0;
                }, &watch);
                sony2fuji_buffer cancelled{};
                const auto cancelStatus = sony2fuji_process(session, &exportRequest, &cancelled);
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                sony2fuji_release_buffer(&cancelled);
                const std::string commitLabel = std::string("FINAL ") + exportCase.label +
                    " export cancels at the commit point instead of publishing staged bytes";
                check(cancelStatus == SONY2FUJI_STATUS_CANCELLED, commitLabel.c_str());
                check(readFile(target) == existing,
                    "Cancelling at the commit point keeps the existing target byte-identical");
                check(stagingResidue(root) == 0,
                    "Cancelling at the commit point removes the staging file");
            }

#ifndef _WIN32
            // Overwriting must keep the destination's permissions instead of resetting them.
            // Fix the umask so a regression cannot coincidentally produce 0640.
            const auto overwriteUmask = ::umask(022);
            (void)::chmod(target.c_str(), 0640);
#endif
            sony2fuji_buffer published{};
            const auto publishStatus = sony2fuji_process(session, &exportRequest, &published);
#ifndef _WIN32
            ::umask(overwriteUmask);
#endif
            check(publishStatus == SONY2FUJI_STATUS_OK,
                "The session exports the same FINAL request successfully after a cancellation");
            sony2fuji_release_buffer(&published);
            const auto written = readFile(target);
            check(written.size() > existing.size() && written.size() >= exportCase.magic.size() &&
                  std::equal(exportCase.magic.begin(), exportCase.magic.end(), written.begin()),
                "A completed FINAL export replaces the target with the encoded file");
            {
                // Flip cancellation to true right as execution passes the pre-rename commit point:
                // once committed, late cancellation must neither delete the file nor alter OK status.
                struct PostCommitFlip {
                    std::filesystem::path directory;
                    std::atomic<bool> armed{false};
                } flip{root};
                sony2fuji_session_set_cancellation_callback(session, +[](void* context) -> int32_t {
                    auto& state = *static_cast<PostCommitFlip*>(context);
                    if (state.armed.load(std::memory_order_acquire)) return 1;
                    std::error_code error;
                    for (std::filesystem::directory_iterator it(state.directory, error), last;
                         !error && it != last; it.increment(error)) {
                        if (isStagingFile(it->path())) {
                            state.armed.store(true, std::memory_order_release);
                            return 0;
                        }
                    }
                    return 0;
                }, &flip);
                sony2fuji_buffer postCommitOut{};
                const auto postCommitStatus = sony2fuji_process(session, &exportRequest, &postCommitOut);
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                sony2fuji_release_buffer(&postCommitOut);
                const auto committedBytes = readFile(target);
                const std::string postCommitLabel = std::string("FINAL ") + exportCase.label +
                    " cancellation after the commit point preserves OK status and published bytes";
                check(flip.armed.load() && postCommitStatus == SONY2FUJI_STATUS_OK &&
                      committedBytes == written && stagingResidue(root) == 0,
                    postCommitLabel.c_str());
            }
#ifndef _WIN32
            check(fileMode(target) == 0640u,
                "Replacing an existing file keeps its permissions");
            const auto fresh = root / (std::string("fresh-") + exportCase.name);
            const std::string freshPath = fresh.u8string();
            exportRequest.output_path = freshPath.c_str();
            const auto previousUmask = ::umask(022);
            sony2fuji_buffer freshOut{};
            const auto freshStatus = sony2fuji_process(session, &exportRequest, &freshOut);
            ::umask(previousUmask);
            sony2fuji_release_buffer(&freshOut);
            check(freshStatus == SONY2FUJI_STATUS_OK && fileMode(fresh) == 0644u,
                "A new export honours umask like a plain write");
            exportRequest.output_path = targetPath.c_str();
            std::filesystem::remove(fresh);
            // The mode copy must not read through a destination symbolic link: the published
            // regular file receives the default `0666 & ~umask` mode, and the linked file
            // keeps its own permissions and contents.
            const auto anchor = root / (std::string("link-anchor-") + exportCase.name);
            writeFile(anchor, existing);
            check(::chmod(anchor.c_str(), 0600) == 0, "Cannot set symlink anchor permissions");
            const auto linked = root / (std::string("linked-") + exportCase.name);
            std::filesystem::remove(linked, cleanupError);
            std::filesystem::create_symlink(anchor, linked);
            const std::string linkedPath = linked.u8string();
            exportRequest.output_path = linkedPath.c_str();
            const auto symlinkUmask = ::umask(022);
            sony2fuji_buffer symlinkOut{};
            const auto symlinkStatus = sony2fuji_process(session, &exportRequest, &symlinkOut);
            ::umask(symlinkUmask);
            sony2fuji_release_buffer(&symlinkOut);
            exportRequest.output_path = targetPath.c_str();
            const std::string symlinkLabel = std::string("Export onto a symlink destination replaces the link ") +
                "without copying the link target's mode (" + exportCase.label + ")";
            check(symlinkStatus == SONY2FUJI_STATUS_OK &&
                  !std::filesystem::is_symlink(linked) && std::filesystem::is_regular_file(linked) &&
                  fileMode(linked) == 0644u,
                symlinkLabel.c_str());
            check(fileMode(anchor) == 0600u && readFile(anchor) == existing,
                "Exporting through a symlink destination leaves the linked file's permissions and contents untouched");
            std::filesystem::remove(linked, cleanupError);
            std::filesystem::remove(anchor, cleanupError);
#endif
        }
        // Foreign-name protection (P3-02): stagingSuffix() is deterministic
        // ("<pid>-<counter>"), so the test can pre-create exactly the names the next
        // create() will try. The encoder must retry past every collision and must never
        // truncate or delete a file it did not create. The same assertions hold on the
        // Windows gate, where CREATE_NEW replaces the O_EXCL loop.
        {
            const std::string pidPart = [] {
                const std::string probe = sony2fuji::stagingSuffix();
                return probe.substr(0, probe.find('-'));
            }();
            const auto foreign = std::vector<unsigned char>{'F', 'O', 'R', 'E', 'I', 'G', 'N'};
            struct ForeignCase {
                sony2fuji_output_format ffiFormat;
                const char* directory;
                const char* targetName;
                const char* label;
            };
            for (const auto& foreignCase : {ForeignCase{SONY2FUJI_OUTPUT_JPEG, "foreign-jpeg", "foreign-out.jpg", "JPEG"},
                                            ForeignCase{SONY2FUJI_OUTPUT_PNG, "foreign-png", "foreign-out.png", "PNG"},
                                            ForeignCase{SONY2FUJI_OUTPUT_DNG, "foreign-dng", "foreign-out.dng", "DNG"}}) {
                const auto dir = root / foreignCase.directory;
                std::filesystem::create_directories(dir, cleanupError);
                const auto target = dir / foreignCase.targetName;
                const std::string targetPath = target.u8string();
                exportRequest.output_format = foreignCase.ffiFormat;
                exportRequest.output_path = targetPath.c_str();
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                long plantedNext = 0;
                auto plantForeign = [&]() {
                    // Consume one suffix with the probe, then plant the next three names.
                    const std::string probe = sony2fuji::stagingSuffix();
                    const long next = std::stol(probe.substr(probe.find('-') + 1)) + 1;
                    plantedNext = next;
                    const std::string base = foreignCase.ffiFormat == SONY2FUJI_OUTPUT_DNG ?
                        std::string(foreignCase.targetName) + ".rawlab-rendered-dng-" :
                        foreignCase.ffiFormat == SONY2FUJI_OUTPUT_JPEG ? ".rawlab-jpeg-" : ".rawlab-png-";
                    std::vector<std::filesystem::path> planted;
                    for (int i = 0; i < 3; ++i) {
                        const auto path = dir / (base + pidPart + "-" + std::to_string(next + i) + ".tmp");
                        writeFile(path, foreign);
                        planted.push_back(path);
                    }
                    return planted;
                };
                auto foreignIntact = [&](const std::vector<std::filesystem::path>& planted) {
                    for (const auto& path : planted) {
                        if (!std::filesystem::exists(path) || readFile(path) != foreign) return false;
                    }
                    return true;
                };
                // 1) Success path: three collisions, the fourth candidate is created, and
                // the published file is ours while the foreign trio keeps its bytes.
                auto planted = plantForeign();
                writeFile(target, existing);
                sony2fuji_buffer exportedOk{};
                const auto okStatus = sony2fuji_process(session, &exportRequest, &exportedOk);
                sony2fuji_release_buffer(&exportedOk);
                // The publish is real (not a vacuous green): create() consumed exactly
                // four suffixes — three planted collisions plus its own name — so the
                // counter advanced from `plantedNext` by 4. A probe now reports the next
                // available number, which must be plantedNext + 4.
                const long afterOk = [] {
                    const std::string probe = sony2fuji::stagingSuffix();
                    return std::stol(probe.substr(probe.find('-') + 1));
                }();
                check(okStatus == SONY2FUJI_STATUS_OK && foreignIntact(planted) &&
                          stagingResidue(dir) == 3 && afterOk == plantedNext + 4,
                      (std::string("Export retries past planted foreign staging names (") + foreignCase.label + ")").c_str());
                // 2) Cancelled export: the staging file it did create is removed, while the
                // foreign trio is left completely untouched. Cancellation must fire only
                // after create() has retried past the planted trio and built its OWN
                // staging file, otherwise this anchor is vacuous — a poll that returns 1
                // from the first checkpoint would cancel before the encoder ever stages,
                // so there would be nothing of its own to remove (fake green).
                planted = plantForeign();
                writeFile(target, existing);
                // With both planted generations present the directory holds exactly this
                // many staging-pattern foreign files; the export's own staging is number
                // baseline + 1 and is what makes the watch fire.
                struct StagingWatch {
                    std::filesystem::path directory;
                    int baseline;
                    std::atomic<bool> stagedOwn{false};
                } watch{dir, stagingResidue(dir), {false}};
                sony2fuji_session_set_cancellation_callback(session, +[](void* context) -> int32_t {
                    auto& watch = *static_cast<StagingWatch*>(context);
                    int staged = 0;
                    std::error_code error;
                    for (std::filesystem::directory_iterator it(watch.directory, error), last;
                         !error && it != last; it.increment(error)) {
                        if (isStagingFile(it->path())) ++staged;
                    }
                    if (staged > watch.baseline) {
                        watch.stagedOwn.store(true, std::memory_order_release);
                        return 1; // cancel at the commit point, with the own staging present
                    }
                    return 0;
                }, &watch);
                sony2fuji_buffer exportedCancelled{};
                const auto cancelledStatus = sony2fuji_process(session, &exportRequest, &exportedCancelled);
                sony2fuji_release_buffer(&exportedCancelled);
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                check(cancelledStatus == SONY2FUJI_STATUS_CANCELLED &&
                          watch.stagedOwn.load(std::memory_order_acquire) &&
                          readFile(target) == existing && foreignIntact(planted) &&
                          // Both planted generations remain and the export's own staging
                          // file is gone: residue is back to the pre-export baseline.
                          stagingResidue(dir) == watch.baseline,
                    (std::string("Cancelled export removes only its own staging file among foreign names (") + foreignCase.label + ")").c_str());
                std::filesystem::remove_all(dir, cleanupError);
            }
        }
        // Large (>= 30 MP) FINAL PNG and JPEG exports must check cancellation inside the encoding
        // loop so mid-encode cancellation returns CANCELLED promptly without publishing any output.
        {
            constexpr uint32_t kSourceSide = 256;
            constexpr uint32_t kLargeWidth = 6200;
            constexpr uint32_t kLargeHeight = 5000; // 31.0 MP
            std::vector<unsigned char> texturedPixels(kSourceSide * kSourceSide * 3);
            for (uint32_t y = 0; y < kSourceSide; ++y) {
                for (uint32_t x = 0; x < kSourceSide; ++x) {
                    const size_t base = (static_cast<size_t>(y) * kSourceSide + x) * 3;
                    texturedPixels[base + 0] = static_cast<unsigned char>((x * 73u + y * 151u + ((x ^ y) * 19u)) & 0xffu);
                    texturedPixels[base + 1] = static_cast<unsigned char>((x * 197u + y * 53u + ((x + y) * 29u)) & 0xffu);
                    texturedPixels[base + 2] = static_cast<unsigned char>((x * 41u + y * 211u + ((x * 3u ^ y) * 37u)) & 0xffu);
                }
            }

            sony2fuji_request largeRequest = exportRequest;
            largeRequest.input_pixels = texturedPixels.data();
            largeRequest.input_width = kSourceSide;
            largeRequest.input_height = kSourceSide;
            largeRequest.size_mode = SONY2FUJI_SIZE_EXACT;
            largeRequest.target_width = kLargeWidth;
            largeRequest.target_height = kLargeHeight;
            largeRequest.jpeg_quality = 92;

            struct MidEncodeCancel {
                std::filesystem::path directory;
                std::atomic<int> stagingPolls{0};
                std::chrono::steady_clock::time_point cancelIssued{};
            };

            struct LargeFormatCase {
                sony2fuji_output_format format;
                const char* filename;
                const char* label;
            };
            for (const auto& largeCase : {
                     LargeFormatCase{SONY2FUJI_OUTPUT_JPEG, "large-31mp.jpg", "JPEG"},
                     LargeFormatCase{SONY2FUJI_OUTPUT_PNG, "large-31mp.png", "PNG"}}) {
                const auto freshTarget = root / largeCase.filename;
                std::filesystem::remove(freshTarget, cleanupError);
                const std::string freshPath = freshTarget.u8string();
                largeRequest.output_format = largeCase.format;
                largeRequest.output_path = freshPath.c_str();

                MidEncodeCancel state{root};
                sony2fuji_session_set_cancellation_callback(session, +[](void* context) -> int32_t {
                    auto& watch = *static_cast<MidEncodeCancel*>(context);
                    const int prior = watch.stagingPolls.load(std::memory_order_acquire);
                    if (prior >= 1) {
                        watch.stagingPolls.fetch_add(1, std::memory_order_acq_rel);
                        return 1;
                    }
                    std::error_code error;
                    for (std::filesystem::directory_iterator it(watch.directory, error), last;
                         !error && it != last; it.increment(error)) {
                        if (isStagingFile(it->path())) {
                            if (watch.stagingPolls.fetch_add(1, std::memory_order_acq_rel) == 0) {
                                watch.cancelIssued = std::chrono::steady_clock::now();
                                return 0;
                            }
                            return 1;
                        }
                    }
                    return 0;
                }, &state);

                sony2fuji_buffer out{};
                const auto status = sony2fuji_process(session, &largeRequest, &out);
                const auto returnedAt = std::chrono::steady_clock::now();
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                sony2fuji_release_buffer(&out);

                const bool triggeredMidEncode = state.stagingPolls.load() >= 2;
                const double cancelLatencyMs = triggeredMidEncode ?
                    std::chrono::duration<double, std::milli>(returnedAt - state.cancelIssued).count() :
                    -1.0;
                std::cout << "INFO 31MP FINAL " << largeCase.label
                          << " mid-encode cancelpolls=" << state.stagingPolls.load()
                          << " cancel_to_return_ms=" << cancelLatencyMs << '\n';

                const std::string statusLabel = std::string("Large 31MP FINAL ") + largeCase.label +
                    " export cancels during encoding and returns CANCELLED";
                const std::string cleanLabel = std::string("Large 31MP FINAL ") + largeCase.label +
                    " export cancelled during encoding removes staging and publishes no output file";
                const std::string latencyLabel = std::string("Large 31MP FINAL ") + largeCase.label +
                    " export returns within 1s after mid-encode cancellation";
                check(status == SONY2FUJI_STATUS_CANCELLED && triggeredMidEncode, statusLabel.c_str());
                check(!std::filesystem::exists(freshTarget) && stagingResidue(root) == 0, cleanLabel.c_str());
                check(triggeredMidEncode && cancelLatencyMs >= 0.0 && cancelLatencyMs < 1000.0, latencyLabel.c_str());

                // Verify intra-encode checkpoints do not alter encoded SDR output bytes.
                sony2fuji_request parityRequest = largeRequest;
                parityRequest.target_width = 640;
                parityRequest.target_height = 512; // 327,680 px: exercises multiple intra-encode checkpoints
                sony2fuji_buffer baseOut{};
                const auto baseStatus = sony2fuji_process(session, &parityRequest, &baseOut);
                sony2fuji_release_buffer(&baseOut);
                const auto baselineBytes = readFile(freshTarget);

                std::atomic<int> parityPolls{0};
                sony2fuji_session_set_cancellation_callback(session, +[](void* context) -> int32_t {
                    static_cast<std::atomic<int>*>(context)->fetch_add(1, std::memory_order_relaxed);
                    return 0;
                }, &parityPolls);
                sony2fuji_buffer polledOut{};
                const auto polledStatus = sony2fuji_process(session, &parityRequest, &polledOut);
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                sony2fuji_release_buffer(&polledOut);
                const auto polledBytes = readFile(freshTarget);
                std::filesystem::remove(freshTarget, cleanupError);

                const std::string parityLabel = std::string("Intra-encode cancellation checkpoints preserve exact ") +
                    largeCase.label + " output bytes";
                check(baseStatus == SONY2FUJI_STATUS_OK && polledStatus == SONY2FUJI_STATUS_OK &&
                      parityPolls.load() > 4 && !baselineBytes.empty() && baselineBytes == polledBytes,
                    parityLabel.c_str());
            }
        }
        // Non-sticky (one-shot) cancellation callback: returning non-zero once and 0 on all subsequent
        // polls must latch into CANCELLED across JPEG, PNG, and DNG encoders without publishing a file.
        {
            constexpr uint32_t kLatchW = 320;
            constexpr uint32_t kLatchH = 256; // 81,920 px: 5 JPEG quantize blocks (16384 px) and >=65536 px for PNG/DNG
            std::vector<unsigned char> latchInput(static_cast<size_t>(kLatchW) * kLatchH * 3u);
            sony2fuji::ImageData latchImage(static_cast<int>(kLatchW), static_cast<int>(kLatchH));
            for (uint32_t y = 0; y < kLatchH; ++y) {
                for (uint32_t x = 0; x < kLatchW; ++x) {
                    const size_t idx = static_cast<size_t>(y) * kLatchW + x;
                    const unsigned char r = static_cast<unsigned char>((x * 73u + y * 151u + ((x ^ y) * 31u)) & 0xffu);
                    const unsigned char g = static_cast<unsigned char>((x * 197u + y * 53u + ((x + y) * 43u)) & 0xffu);
                    const unsigned char b = static_cast<unsigned char>((x * 41u + y * 211u + ((x * 5u ^ y) * 61u)) & 0xffu);
                    latchInput[idx * 3u + 0u] = r;
                    latchInput[idx * 3u + 1u] = g;
                    latchInput[idx * 3u + 2u] = b;
                    latchImage.pixels[idx] = sony2fuji::RGB(r / 255.0f, g / 255.0f, b / 255.0f);
                }
            }

            sony2fuji_request latchReq = exportRequest;
            latchReq.input_pixels = latchInput.data();
            latchReq.input_width = kLatchW;
            latchReq.input_height = kLatchH;
            latchReq.size_mode = SONY2FUJI_SIZE_EXACT;
            latchReq.target_width = kLatchW;
            latchReq.target_height = kLatchH;
            latchReq.jpeg_quality = 98;

            struct LatchFormatCase {
                sony2fuji_output_format ffiFormat;
                sony2fuji::OutputFormat coreFormat;
                const char* filename;
                const char* label;
            };
            for (const auto& fmt : {
                     LatchFormatCase{SONY2FUJI_OUTPUT_JPEG, sony2fuji::OutputFormat::JPEG, "oneshot-latch.jpg", "JPEG"},
                     LatchFormatCase{SONY2FUJI_OUTPUT_PNG, sony2fuji::OutputFormat::PNG, "oneshot-latch.png", "PNG"},
                     LatchFormatCase{SONY2FUJI_OUTPUT_DNG, sony2fuji::OutputFormat::DNG, "oneshot-latch.dng", "DNG"}}) {
                const auto latchTarget = root / fmt.filename;
                const std::string latchPath = latchTarget.u8string();
                latchReq.output_format = fmt.ffiFormat;
                latchReq.output_path = latchPath.c_str();

                // 1) Direct encoder: measure total encoder checkpoints, then fire a single non-zero pulse at poll #1 and every checkpoint.
                std::filesystem::remove(latchTarget, cleanupError);
                std::atomic<int> directCount{0};
                {
                    sony2fuji::ProcessingCancellationScope countScope({+[](void* ctx) -> int32_t {
                        static_cast<std::atomic<int>*>(ctx)->fetch_add(1, std::memory_order_relaxed);
                        return 0;
                    }, &directCount});
                    check(sony2fuji::ImageEncoder::saveImage(latchImage, latchPath, fmt.coreFormat, 98) ==
                              sony2fuji::ErrorCode::Success && directCount.load() >= 2,
                        (std::string("Baseline ") + fmt.label + " encoder run records multiple cancellation checkpoints").c_str());
                }
                std::filesystem::remove(latchTarget, cleanupError);

                bool allDirectLatched = directCount.load() >= 2;
                for (int targetPoll = 1; targetPoll <= directCount.load(); ++targetPoll) {
                    struct OneShot {
                        std::atomic<int> calls{0};
                        int fireAt = 1;
                    } oneShot{{0}, targetPoll};
                    bool threwCancelled = false;
                    sony2fuji::ProcessingCancellationScope oneShotScope({+[](void* ctx) -> int32_t {
                        auto& st = *static_cast<OneShot*>(ctx);
                        return st.calls.fetch_add(1, std::memory_order_acq_rel) + 1 == st.fireAt ? 1 : 0;
                    }, &oneShot});
                    try {
                        (void)sony2fuji::ImageEncoder::saveImage(latchImage, latchPath, fmt.coreFormat, 98);
                    } catch (const sony2fuji::ProcessingCancelled&) {
                        threwCancelled = true;
                    }
                    if (!threwCancelled || std::filesystem::exists(latchTarget) || stagingResidue(root) != 0) {
                        allDirectLatched = false;
                        std::filesystem::remove(latchTarget, cleanupError);
                    }
                }
                const std::string directLatchLabel = std::string("One-shot non-sticky cancellation latches at every ") +
                    fmt.label + " encoder checkpoint and leaves no output file";
                check(allDirectLatched, directLatchLabel.c_str());

                // The return-value encoder API has no Cancelled value, so cancellation must
                // leave through the ProcessingCancelled type itself: a direct C++ caller
                // observes the cancellation semantics unchanged, never a generic
                // ErrorCode (P3-03, C-N10).
                {
                    const auto typeTarget = root / fmt.filename;
                    const std::string typePath = typeTarget.u8string();
                    std::filesystem::remove(typeTarget, cleanupError);
                    sony2fuji::ProcessingCancellationScope alwaysCancelled(
                        {+[](void*) -> int32_t { return 1; }, nullptr});
                    bool cancelledTypePreserved = false;
                    bool returnedWithoutCancellation = false;
                    try {
                        (void)sony2fuji::ImageEncoder::saveImage(latchImage, typePath, fmt.coreFormat, 98);
                        returnedWithoutCancellation = true; // cancellation came back as a code
                    } catch (const sony2fuji::ProcessingCancelled&) {
                        cancelledTypePreserved = true;
                    } catch (const std::exception&) {
                        returnedWithoutCancellation = true; // a wrapped exception loses the type too
                    }
                    check(cancelledTypePreserved && !returnedWithoutCancellation &&
                              !std::filesystem::exists(typeTarget) && stagingResidue(root) == 0,
                          (std::string("Cancelled ImageEncoder::saveImage preserves the ProcessingCancelled type (") + fmt.label + ")").c_str());
                    std::filesystem::remove(typeTarget, cleanupError);
                }

                // 2) C ABI sony2fuji_process: fire one non-zero pulse at every poll 1..total,
                // including the pre-encoder parallel pixel stages.
                struct TracePolls {
                    std::filesystem::path directory;
                    std::atomic<int> calls{0};
                    std::atomic<int> firstStagingPoll{0};
                } trace{root};
                sony2fuji_session_set_cancellation_callback(session, +[](void* ctx) -> int32_t {
                    auto& st = *static_cast<TracePolls*>(ctx);
                    const int poll = st.calls.fetch_add(1, std::memory_order_acq_rel) + 1;
                    if (st.firstStagingPoll.load(std::memory_order_acquire) == 0) {
                        std::error_code ec;
                        for (std::filesystem::directory_iterator it(st.directory, ec), last;
                             !ec && it != last; it.increment(ec)) {
                            if (isStagingFile(it->path())) {
                                int expected = 0;
                                st.firstStagingPoll.compare_exchange_strong(expected, poll, std::memory_order_acq_rel);
                                break;
                            }
                        }
                    }
                    return 0;
                }, &trace);
                sony2fuji_buffer traceOut{};
                const auto traceSt = sony2fuji_process(session, &latchReq, &traceOut);
                sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                sony2fuji_release_buffer(&traceOut);
                std::filesystem::remove(latchTarget, cleanupError);

                const int totalFfiPolls = trace.calls.load();
                const int stagingStart = trace.firstStagingPoll.load();

                // 覆盖全部中间轮询点（含编码器窗口之前的并行像素阶段，如 applyPhotoLook 的
                // parallelPixelRanges）：非粘性 one-shot 脉冲在这些点必须被锁存成 CANCELLED，
                // 否则被跳过的像素块会被静默落盘成坏文件并返回 OK。
                std::vector<int> targetPolls;
                targetPolls.reserve(static_cast<size_t>(totalFfiPolls));
                for (int p = 1; p <= totalFfiPolls; ++p) targetPolls.push_back(p);

                bool allFfiLatched = traceSt == SONY2FUJI_STATUS_OK && stagingStart > 0 && totalFfiPolls >= stagingStart;
                for (int targetPoll : targetPolls) {
                    struct FfiOneShot {
                        std::atomic<int> calls{0};
                        int fireAt = 1;
                    } oneShot{{0}, targetPoll};
                    sony2fuji_session_set_cancellation_callback(session, +[](void* ctx) -> int32_t {
                        auto& st = *static_cast<FfiOneShot*>(ctx);
                        return st.calls.fetch_add(1, std::memory_order_acq_rel) + 1 == st.fireAt ? 1 : 0;
                    }, &oneShot);
                    sony2fuji_buffer out{};
                    const auto st = sony2fuji_process(session, &latchReq, &out);
                    sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
                    sony2fuji_release_buffer(&out);
                    if (st != SONY2FUJI_STATUS_CANCELLED || std::filesystem::exists(latchTarget) || stagingResidue(root) != 0) {
                        allFfiLatched = false;
                        std::filesystem::remove(latchTarget, cleanupError);
                    }
                }
                const std::string ffiLatchLabel = std::string("FINAL ") + fmt.label +
                    " C ABI export returns CANCELLED and leaves no file under one-shot non-sticky callback";
                check(allFfiLatched, ffiLatchLabel.c_str());
            }
        }
        // A PREVIEW request that writes a file keeps ignoring the callback: the gate covers
        // buffer targets and FINAL renders, not preview exports.
        {
            const auto previewTarget = root / "preview-target.jpg";
            const std::string previewPath = previewTarget.u8string();
            sony2fuji_request previewRequest = exportRequest;
            previewRequest.intent = SONY2FUJI_INTENT_PREVIEW;
            previewRequest.output_format = SONY2FUJI_OUTPUT_JPEG;
            previewRequest.output_path = previewPath.c_str();
            sony2fuji_session_set_cancellation_callback(session, +[](void*) -> int32_t { return 1; }, nullptr);
            sony2fuji_buffer previewOut{};
            const auto previewStatus = sony2fuji_process(session, &previewRequest, &previewOut);
            sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
            sony2fuji_release_buffer(&previewOut);
            check(previewStatus == SONY2FUJI_STATUS_OK && std::filesystem::exists(previewTarget),
                "A PREVIEW file export still ignores the cancellation callback");
        }
        // FINAL into a buffer is cancellable and never publishes partial pixels.
        {
            sony2fuji_request bufferRequest = request;
            bufferRequest.intent = SONY2FUJI_INTENT_FINAL;
            bufferRequest.output_target = SONY2FUJI_TARGET_BUFFER;
            bufferRequest.output_format = SONY2FUJI_OUTPUT_RGB8;
            bufferRequest.size_mode = SONY2FUJI_SIZE_EXACT;
            bufferRequest.target_width = bufferRequest.target_height = 64;
            sony2fuji_session_set_cancellation_callback(session, +[](void*) -> int32_t { return 1; }, nullptr);
            sony2fuji_buffer bufferOut{};
            const auto bufferStatus = sony2fuji_process(session, &bufferRequest, &bufferOut);
            sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr);
            const bool empty = bufferOut.data == nullptr && bufferOut.size_bytes == 0;
            sony2fuji_release_buffer(&bufferOut);
            check(bufferStatus == SONY2FUJI_STATUS_CANCELLED && empty,
                "FINAL into a buffer is cancellable and publishes no partial pixels");
        }
        std::filesystem::remove_all(root, cleanupError);
    }
    sony2fuji_session_destroy(session);
    return failures ? 1 : 0;
}
