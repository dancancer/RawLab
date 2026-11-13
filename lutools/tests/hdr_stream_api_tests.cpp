#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "core/hdr_jpeg.h"
#include "platform/hdr_image.h"
#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <chrono>
#ifndef _WIN32
#include <sys/stat.h>
#endif

using namespace sony2fuji;
namespace fs = std::filesystem;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
#ifndef _WIN32
unsigned fileMode(const fs::path& path) {
    struct stat info{};
    return ::stat(path.c_str(), &info) == 0 ? static_cast<unsigned>(info.st_mode & 0777) : 0u;
}
#endif
template<class T> T initialized() { T value{}; value.version = 1; value.struct_size = sizeof(value); return value; }
void write(const fs::path& path, const std::vector<uint8_t>& bytes) {
    std::ofstream file(path, std::ios::binary); file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}
std::vector<uint8_t> read(const fs::path& path) {
    std::ifstream file(path, std::ios::binary); return {std::istreambuf_iterator<char>(file), {}};
}
void fillDisk(const fs::path& path) {
    std::ofstream file(path, std::ios::binary);
    check(file.good(), "Cannot create isolated disk-pressure fixture");
    std::array<char, 4096> bytes{};
    while (file.write(bytes.data(), bytes.size())) { }
}
struct Context {
    HDRImagePair pair;
    bool cancelled = false, cancelAtFinish = false;
    fs::path changeSource;
    fs::path fillDiskDuringRead;
    int reads = 0;
};
}

int main(int argc, char* argv[]) {
    if (argc != 2) return 2;
    const auto directory = fs::temp_directory_path() / ("rawlab-stream-api-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    sony2fuji_session* session = nullptr;
    try {
        fs::create_directory(directory); fs::create_directory(directory / "scratch");
        const auto original = directory / "original.jpg", output = directory / "result.jpg";
        Context context;
        context.pair.hdr = ImageData(48, 32); context.pair.sdr = ImageData(48, 32);
        context.pair.nativeWidth = 48; context.pair.nativeHeight = 32;
        for (size_t i = 0; i < context.pair.hdr.pixels.size(); ++i) {
            const float value = float(i % 257) / 257;
            context.pair.hdr.pixels[i] = {value * 4, value * 2, value};
            context.pair.sdr.pixels[i] = {value * .8f, value * .6f, value * .4f};
        }
        const auto originalBytes = hdr::encodeJPEG(context.pair, 95, SONY2FUJI_HDR_COLOR_SRGB);
        write(original, originalBytes);
        const auto info = hdr::probeFile(original.u8string().c_str());
        auto source = initialized<sony2fuji_hdr_stream_source_v1>();
        source.native_width = 48; source.native_height = 32; source.orientation_applied = 1;
        source.source_intent = SONY2FUJI_INTENT_FINAL; source.decode_revision = 7;
        source.decoder_identifier = "test-complete-source";
        std::copy_n(info.source_sha256, 32, source.source_sha256);
        source.context = &context;
        source.read_rows = [](void* opaque, uint32_t high, uint32_t row, uint32_t count, float* data) {
            auto& state = *static_cast<Context*>(opaque); ++state.reads;
            if (!state.fillDiskDuringRead.empty()) {
                fillDisk(state.fillDiskDuringRead); state.fillDiskDuringRead.clear();
            }
            const auto& image = high ? state.pair.hdr : state.pair.sdr;
            std::memcpy(data, image.pixels.data() + size_t(row) * image.width, size_t(count) * image.width * sizeof(RGB));
            return SONY2FUJI_STATUS_OK;
        };
        source.finish_decode = [](void* opaque) {
            auto& state = *static_cast<Context*>(opaque);
            if (state.cancelAtFinish) state.cancelled = true;
            if (!state.changeSource.empty()) write(state.changeSource, {1, 2, 3, 4});
            return SONY2FUJI_STATUS_OK;
        };
        auto settings = initialized<sony2fuji_hdr_request_v1>();
        settings.hdr_processing_version = 1; settings.intent = SONY2FUJI_INTENT_FINAL;
        settings.temperature = 6500; settings.crop_width = settings.crop_height = 1;
        auto config = initialized<sony2fuji_hdr_export_config_v1>();
        config.jpeg_quality = 95; config.base_color = SONY2FUJI_HDR_COLOR_DISPLAY_P3;
        config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
        const auto originalPath = original.u8string();
        auto scratch = (directory / "scratch").u8string();
        config.metadata_source_path = originalPath.c_str();
        std::copy_n(info.source_sha256, 32, config.source_sha256);
        auto result = initialized<sony2fuji_hdr_stream_result_v1>();
        auto diagnostic = initialized<sony2fuji_hdr_diagnostic_v1>();
        check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK, "Cannot create test session");
        sony2fuji_session_set_cancellation_callback(session, [](void* value) { return static_cast<Context*>(value)->cancelled ? 1 : 0; }, &context);
        auto run = [&](const fs::path& target, uint32_t hdr = 1, const sony2fuji_hdr_request_v1* override = nullptr) {
            return sony2fuji_hdr_export_stream(session, &source, override ? override : &settings, &config,
                hdr, scratch.c_str(), target.u8string().c_str(), &result, &diagnostic);
        };
        check(run(output) == SONY2FUJI_STATUS_OK && result.width == 48 && result.height == 32 && result.decode_revision == 7,
            "Complete stream API export failed or lost provenance");
        check(hdr::probeFile(output.u8string().c_str()).width == 48, "Stream output does not contain a valid gain map");
        const auto existing = read(output);
#ifndef _WIN32
        {
            const auto permTarget = directory / "perm-target.jpg";
            write(permTarget, {0});
            check(::chmod(permTarget.c_str(), 0640) == 0, "Cannot set fixture permissions");
            check(run(permTarget) == SONY2FUJI_STATUS_OK && fileMode(permTarget) == 0640u,
                "Replacing an existing HDR export keeps its permissions");
            fs::remove(permTarget);
            const auto previousUmask = ::umask(022);
            const auto freshStatus = run(permTarget);
            ::umask(previousUmask);
            check(freshStatus == SONY2FUJI_STATUS_OK && fileMode(permTarget) == 0644u,
                "A new HDR export honours umask like a plain write");
            fs::remove(permTarget);
        }
#endif
        source.source_intent = SONY2FUJI_INTENT_PREVIEW;
        check(run(output) == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_PREVIEW_SOURCE && read(output) == existing,
            "Proxy source overwrote existing output");
        source.source_intent = SONY2FUJI_INTENT_FINAL;
        check(run(original) == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_SAME_FILE && read(original) == originalBytes,
            "Stream overwrote the original source");
        fs::create_hard_link(original, directory / "hardlink.jpg");
        check(run(directory / "hardlink.jpg") == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_SAME_FILE,
            "Stream accepted source hardlink as destination");
        source.source_sha256[0] ^= 1;
        check(run(output) == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_SOURCE_CHANGED && read(output) == existing,
            "Mismatched source digest was published");
        source.source_sha256[0] ^= 1;
        context.cancelAtFinish = true;
        check(run(output) == SONY2FUJI_STATUS_CANCELLED && read(output) == existing && fs::is_empty(directory / "scratch"),
            "Cancellation published output or leaked scratch");
        context.cancelled = false; context.cancelAtFinish = false;
        fs::create_directory(directory / "rename-target"); write(directory / "rename-target" / "keep", {9});
        const auto beforeCount = std::distance(fs::directory_iterator(directory), fs::directory_iterator{});
        check(run(directory / "rename-target") == SONY2FUJI_STATUS_OUTPUT_IO_ERROR &&
            read(directory / "rename-target" / "keep") == std::vector<uint8_t>{9} && fs::is_empty(directory / "scratch") &&
            std::distance(fs::directory_iterator(directory), fs::directory_iterator{}) == beforeCount,
            "Final rename failure changed destination or leaked adjacent temporary file");
        context.changeSource = original;
        check(run(output) == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_SOURCE_CHANGED && read(output) == existing,
            "Changed source was published");
        context.changeSource.clear(); write(original, originalBytes);
        check(run(output, 0) == SONY2FUJI_STATUS_OK && read(output) != existing && fs::is_empty(directory / "scratch"),
            "SDR stream did not recover after failures");
        auto sdrInfo = initialized<sony2fuji_hdr_source_info_v1>();
        check(sony2fuji_hdr_probe(output.u8string().c_str(), &sdrInfo, &diagnostic) == SONY2FUJI_STATUS_UNSUPPORTED &&
            diagnostic.reason == SONY2FUJI_HDR_REASON_NOT_HDR, "SDR stream retained a gain map");
        sony2fuji_hdr_request_v2 tone{};
        tone.base = settings;
        tone.base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_TONE_VERSION;
        tone.base.struct_size = sizeof(tone);
        tone.curve = initialized<sony2fuji_tone_curve_config>();
        tone.white_point = 70;
        check(run(output, 1, &tone.base) == SONY2FUJI_STATUS_OK && read(output) != existing &&
            hdr::probeFile(output.u8string().c_str()).width == 48, "HDR tone did not reach stream export");
        const auto edited = read(output);
        const auto beforeToneReads = context.reads;
        tone.base.struct_size = sizeof(tone.base);
        check(run(output, 1, &tone.base) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            context.reads == beforeToneReads && read(output) == edited, "Truncated HDR tone request touched the stream");
        sony2fuji_hdr_request_v3 color{};
        color.base = tone;
        color.base.base.struct_size = sizeof(color);
        color.base.base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_COLOR_VERSION;
        color.hsl.version = SONY2FUJI_HSL_CONFIG_VERSION; color.hsl.struct_size = sizeof(color.hsl);
        color.grading.version = SONY2FUJI_COLOR_GRADING_CONFIG_VERSION; color.grading.struct_size = sizeof(color.grading);
        color.grading.highlights_hue = 210; color.grading.highlights_saturation = 80;
        check(run(output, 1, &color.base.base) == SONY2FUJI_STATUS_OK && read(output) != edited &&
            hdr::probeFile(output.u8string().c_str()).width == 48, "HDR color did not reach stream export");
        const auto colored = read(output);
        sony2fuji_hdr_request_v4 rendition{};
        rendition.base = color;
        auto& base = rendition.base.base.base;
        base.struct_size = sizeof(rendition);
        base.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION;
        rendition.peak_limit_ev = 1;
        rendition.sdr_exposure_ev = -1.5f;
        check(run(output, 1, &base) == SONY2FUJI_STATUS_OK && read(output) != colored &&
            hdr::probeFile(output.u8string().c_str()).width == 48, "HDR rendition settings did not reach stream export");
        const auto trimmed = read(output);
        const auto beforeTrimReads = context.reads;
        rendition.sdr_saturation = 101;
        check(run(output, 1, &base) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            context.reads == beforeTrimReads && read(output) == trimmed, "Invalid SDR trim modified the stream");
        sony2fuji_hdr_request_v5 effects{};
        effects.base = rendition; effects.base.sdr_saturation = 0;
        auto& effectsBase = effects.base.base.base.base;
        effectsBase.struct_size = sizeof(effects);
        effectsBase.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION;
        effects.effects = initialized<sony2fuji_photo_effects_config>();
        effects.effects.vignette_amount = -80; effects.effects.vignette_midpoint = 50;
        effects.effects.vignette_feather = 50; effects.effects.grain_amount = 65;
        effects.effects.grain_size = 25; effects.effects.grain_roughness = 50;
        check(run(output, 1, &effectsBase) == SONY2FUJI_STATUS_OK && read(output) != trimmed &&
            hdr::probeFile(output.u8string().c_str()).width == 48, "HDR effects did not reach stream export");
        const auto finished = read(output);
        check(run(output, 1, &effectsBase) == SONY2FUJI_STATUS_OK && read(output) == finished,
            "HDR grain changed across stream retries");
        const auto beforeEffectsReads = context.reads;
        effects.effects.struct_size = 8;
        check(run(output, 1, &effectsBase) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            context.reads == beforeEffectsReads && read(output) == finished, "Truncated HDR effects touched the stream");
        sony2fuji_hdr_request_v6 detail{};
        detail.base = effects; detail.base.effects.struct_size = sizeof(effects.effects);
        auto& detailBase = detail.base.base.base.base.base;
        detailBase.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION;
        detailBase.struct_size = sizeof(effects);
        detail.sharpening = 1.2f; detail.clarity = .8f; detail.dehaze = -.35f; detail.denoise = .65f;
        check(run(output, 1, &detailBase) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            context.reads == beforeEffectsReads && read(output) == finished, "Truncated HDR detail touched the stream");
        detailBase.struct_size = sizeof(detail);
        check(run(output, 1, &detailBase) == SONY2FUJI_STATUS_OK && read(output) != finished &&
            hdr::probeFile(output.u8string().c_str()).width == 48, "HDR detail did not reach stream export");
        const auto beforeLook = read(output);
        const auto asset = directory / "look.cube";
        fs::copy_file(fs::u8path(argv[1]), asset);
        const auto assetPath = asset.u8string();
        auto lookInfo = initialized<sony2fuji_hdr_look_info_v1>();
        check(sony2fuji_hdr_probe_look(assetPath.c_str(), &lookInfo, &diagnostic) == SONY2FUJI_STATUS_OK &&
            lookInfo.grid_size == 2 && lookInfo.domain_max[2] == 4 && std::strlen(lookInfo.sha256) == 64,
            "HDR look probe did not validate the declaration");
        sony2fuji_hdr_request_v7 look{};
        look.base = detail;
        auto& lookBase = look.base.base.base.base.base.base;
        lookBase.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_LOOK_VERSION;
        lookBase.struct_size = sizeof(look);
        look.look_path = assetPath.c_str(); look.look_strength = .75f;
        std::copy_n(lookInfo.sha256, 65, look.look_sha256);
        const auto originalLook = read(asset);
        check(run(asset, 1, &lookBase) != SONY2FUJI_STATUS_OK && read(asset) == originalLook,
            "Stream export overwrote the HDR look asset");
        check(run(output, 1, &lookBase) == SONY2FUJI_STATUS_OK && read(output) != beforeLook,
            "HDR look did not reach stream export");
        const auto afterLook = read(output);
        const auto beforeLookReads = context.reads;
        const auto stamp = fs::last_write_time(asset);
        auto changed = originalLook;
        changed[2] = 'r';
        write(asset, changed); fs::last_write_time(asset, stamp);
        check(run(output, 1, &lookBase) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
            diagnostic.reason == SONY2FUJI_HDR_REASON_LOOK_RESOURCE && context.reads == beforeLookReads && read(output) == afterLook,
            "Changing a look in place passed a cached fingerprint or replaced output");
        check(read(original) == originalBytes, "Original source changed after successful retry");
        // 仅使用显式提供、专属于测试的小卷，不对日常磁盘制造空间压力。
        if (const char* volume = std::getenv("RAWLAB_TEST_LOW_SPACE")) {
            const fs::path limited(volume);
            check(fs::is_empty(limited) && fs::space(limited).capacity < (256ull << 20),
                "Disk-pressure test requires an empty isolated volume smaller than 256 MiB");
            scratch = limited.u8string();
            const auto filler = limited / "filler";
            const auto saved = read(output);
            const int beforeReads = context.reads;
            fillDisk(filler);
            check(run(output) == SONY2FUJI_STATUS_OUTPUT_IO_ERROR && context.reads == beforeReads && read(output) == saved,
                "Low-space preflight decoded pixels or replaced output");
            fs::remove(filler);
            context.fillDiskDuringRead = filler;
            check(run(output) == SONY2FUJI_STATUS_OUTPUT_IO_ERROR && read(output) == saved,
                "Mid-write disk exhaustion replaced output");
            fs::remove(filler);
            check(fs::is_empty(limited) && run(output, 0) == SONY2FUJI_STATUS_OK && fs::is_empty(limited),
                "Disk exhaustion leaked scratch or prevented recovery");
            std::cout << "PASS isolated disk preflight, mid-write ENOSPC and retry\n";
        }
        sony2fuji_session_destroy(session); session = nullptr;
        fs::remove_all(directory);
        std::cout << "PASS stream C ABI: provenance, source changes, cancel, atomic rename failure, SDR and retry\n";
    } catch (const std::exception& error) {
        if (session) sony2fuji_session_destroy(session);
        fs::remove_all(directory); std::cerr << error.what() << '\n'; return 1;
    }
}
