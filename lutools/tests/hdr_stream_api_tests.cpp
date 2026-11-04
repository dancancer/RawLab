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

using namespace sony2fuji;
namespace fs = std::filesystem;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
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

int main() {
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
        auto run = [&](const fs::path& target, uint32_t hdr = 1) {
            return sony2fuji_hdr_export_stream(session, &source, &settings, &config, hdr, scratch.c_str(), target.u8string().c_str(), &result, &diagnostic);
        };
        check(run(output) == SONY2FUJI_STATUS_OK && result.width == 48 && result.height == 32 && result.decode_revision == 7,
            "Complete stream API export failed or lost provenance");
        check(hdr::probeFile(output.u8string().c_str()).width == 48, "Stream output does not contain a valid gain map");
        const auto existing = read(output);
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
