#include "core/preview_exposure.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <csetjmp>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <jpeglib.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Session = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

struct TempDir {
    std::filesystem::path path;
    TempDir() {
        path = std::filesystem::temp_directory_path() /
            ("rawtools-preview-cache-" + std::to_string(
                std::chrono::steady_clock::now().time_since_epoch().count()));
        std::filesystem::create_directories(path);
    }
    ~TempDir() {
        std::error_code ignored;
        std::filesystem::remove_all(path, ignored);
    }
};

struct JpegErr {
    jpeg_error_mgr manager{};
    std::jmp_buf jump;
};

std::vector<uint8_t> encodeJpegRgb(int width, int height, uint8_t value, int quality) {
    unsigned char* rawBuffer = nullptr;
    unsigned long rawSize = 0;
    struct BufferGuard {
        unsigned char** ptr;
        ~BufferGuard() { std::free(*ptr); }
    } bufferGuard{&rawBuffer};

    struct CompressGuard {
        jpeg_compress_struct cinfo{};
        JpegErr err{};
        ~CompressGuard() { jpeg_destroy_compress(&cinfo); }
    } state;

    state.cinfo.err = jpeg_std_error(&state.err.manager);
    state.err.manager.error_exit = [](j_common_ptr p) {
        std::longjmp(reinterpret_cast<JpegErr*>(p->err)->jump, 1);
    };
    if (setjmp(state.err.jump)) throw std::runtime_error("libjpeg encode failed");

    jpeg_create_compress(&state.cinfo);
    jpeg_mem_dest(&state.cinfo, &rawBuffer, &rawSize);
    state.cinfo.image_width = static_cast<JDIMENSION>(width);
    state.cinfo.image_height = static_cast<JDIMENSION>(height);
    state.cinfo.input_components = 3;
    state.cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&state.cinfo);
    jpeg_set_quality(&state.cinfo, quality, TRUE);
    jpeg_start_compress(&state.cinfo, TRUE);

    std::vector<uint8_t> row(static_cast<size_t>(width) * 3, value);
    for (int y = 0; y < height; ++y) {
        JSAMPROW rowPtr = row.data();
        jpeg_write_scanlines(&state.cinfo, &rowPtr, 1);
    }
    jpeg_finish_compress(&state.cinfo);
    return std::vector<uint8_t>(rawBuffer, rawBuffer + rawSize);
}

void writeU16(std::vector<uint8_t>& dst, size_t offset, uint16_t v) {
    dst[offset] = static_cast<uint8_t>(v & 0xff);
    dst[offset + 1] = static_cast<uint8_t>((v >> 8) & 0xff);
}

void writeU32(std::vector<uint8_t>& dst, size_t offset, uint32_t v) {
    dst[offset] = static_cast<uint8_t>(v & 0xff);
    dst[offset + 1] = static_cast<uint8_t>((v >> 8) & 0xff);
    dst[offset + 2] = static_cast<uint8_t>((v >> 16) & 0xff);
    dst[offset + 3] = static_cast<uint8_t>((v >> 24) & 0xff);
}

struct TiffEntry {
    uint16_t tag;
    uint16_t type;
    uint32_t count;
    std::vector<uint8_t> payload; // inline <=4 bytes or out-of-line data
};

TiffEntry entryU16(uint16_t tag, std::initializer_list<uint16_t> values) {
    TiffEntry e{tag, 3, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values.size() * 2)};
    size_t i = 0;
    for (uint16_t v : values) { writeU16(e.payload, i, v); i += 2; }
    return e;
}

TiffEntry entryU32(uint16_t tag, std::initializer_list<uint32_t> values) {
    TiffEntry e{tag, 4, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values.size() * 4)};
    size_t i = 0;
    for (uint32_t v : values) { writeU32(e.payload, i, v); i += 4; }
    return e;
}

TiffEntry entryBytes(uint16_t tag, uint16_t type, std::initializer_list<uint8_t> values) {
    return TiffEntry{tag, type, static_cast<uint32_t>(values.size()), std::vector<uint8_t>(values)};
}

TiffEntry entryAscii(uint16_t tag, const std::string& text) {
    std::vector<uint8_t> bytes(text.begin(), text.end());
    bytes.push_back(0);
    return TiffEntry{tag, 2, static_cast<uint32_t>(bytes.size()), std::move(bytes)};
}

TiffEntry entryRationals(uint16_t tag, uint16_t type, const std::vector<std::pair<int32_t, int32_t>>& pairs) {
    TiffEntry e{tag, type, static_cast<uint32_t>(pairs.size()), std::vector<uint8_t>(pairs.size() * 8)};
    for (size_t i = 0; i < pairs.size(); ++i) {
        writeU32(e.payload, i * 8, static_cast<uint32_t>(pairs[i].first));
        writeU32(e.payload, i * 8 + 4, static_cast<uint32_t>(pairs[i].second));
    }
    return e;
}

// Writes a valid minimal Bayer DNG with IFD0 = 128x96 RGGB Bayer image (NewSubfileType=0)
// and SubIFD0 = JPEG thumbnail (NewSubfileType=1).
void writeSyntheticDngWithJpeg(
    const std::filesystem::path& path, int jpegWidth, int jpegHeight,
    uint8_t jpegGray, uint16_t rawSignal, int jpegQuality = 90
) {
    const int rawW = 128, rawH = 96;
    const auto jpegBytes = encodeJpegRgb(jpegWidth, jpegHeight, jpegGray, jpegQuality);
    std::vector<uint8_t> rawBytes(static_cast<size_t>(rawW) * rawH * 2);
    for (size_t i = 0; i < static_cast<size_t>(rawW) * rawH; ++i) {
        writeU16(rawBytes, i * 2, rawSignal);
    }

    // Keep tag IDs strictly ascending inside each IFD for LibRaw's TIFF parser.
    std::vector<TiffEntry> ifd0 = {
        entryU32(254, {0}),
        entryU32(256, {static_cast<uint32_t>(rawW)}),
        entryU32(257, {static_cast<uint32_t>(rawH)}),
        entryU16(258, {16}),
        entryU16(259, {1}),
        entryU16(262, {32803}),
        entryAscii(271, "RawLab"),
        entryAscii(272, "CacheTest"),
        entryU32(273, {0}), // RAW strip offset (patched)
        entryU16(274, {1}),
        entryU16(277, {1}),
        entryU32(278, {static_cast<uint32_t>(rawH)}),
        entryU32(279, {static_cast<uint32_t>(rawBytes.size())}),
        entryU16(284, {1}),
        entryU32(330, {0}), // SubIFD offset (patched)
        entryU16(33421, {2, 2}),
        entryBytes(33422, 1, {0, 1, 1, 2}),
        entryBytes(50706, 1, {1, 4, 0, 0}),
        entryBytes(50707, 1, {1, 3, 0, 0}),
        entryAscii(50708, "RawLab CacheTest"),
        entryBytes(50710, 1, {0, 1, 2}),
        entryU16(50711, {1}),
        entryU16(50713, {1, 1}),
        entryRationals(50714, 5, {{64, 1}}),
        entryU32(50717, {4095}),
        entryRationals(50721, 10, {
            {32406, 10000}, {-15372, 10000}, {-4986, 10000},
            {-9689, 10000}, {18758, 10000}, {415, 10000},
            {557, 10000}, {-2040, 10000}, {10570, 10000}
        }),
        entryRationals(50728, 5, {{1, 2}, {1, 1}, {2, 3}}),
        entryU16(50778, {21}),
    };
    std::vector<TiffEntry> subIfd = {
        entryU32(254, {1}),
        entryU32(256, {static_cast<uint32_t>(jpegWidth)}),
        entryU32(257, {static_cast<uint32_t>(jpegHeight)}),
        entryU16(258, {8, 8, 8}),
        entryU16(259, {7}),
        entryU16(262, {6}),
        entryU32(273, {0}), // JPEG strip offset (patched)
        entryU16(277, {3}),
        entryU32(278, {static_cast<uint32_t>(jpegHeight)}),
        entryU32(279, {static_cast<uint32_t>(jpegBytes.size())}),
        entryU16(284, {1}),
    };

    auto measureIfdBlock = [](const std::vector<TiffEntry>& entries) {
        size_t size = 2 + entries.size() * 12 + 4;
        for (const auto& e : entries) {
            if (e.payload.size() > 4) size += (e.payload.size() + 1) & ~size_t(1);
        }
        return size;
    };

    const uint32_t ifd0Offset = 8;
    const uint32_t subIfdOffset = static_cast<uint32_t>(ifd0Offset + measureIfdBlock(ifd0));
    const uint32_t jpegOffset = static_cast<uint32_t>((subIfdOffset + measureIfdBlock(subIfd) + 3) & ~size_t(3));
    const uint32_t rawOffset = static_cast<uint32_t>((jpegOffset + jpegBytes.size() + 3) & ~size_t(3));

    auto patchTag = [](std::vector<TiffEntry>& entries, uint16_t tag, uint32_t value) {
        for (auto& e : entries) {
            if (e.tag == tag) {
                writeU32(e.payload, 0, value);
                return;
            }
        }
    };
    patchTag(ifd0, 273, rawOffset);
    patchTag(ifd0, 330, subIfdOffset);
    patchTag(subIfd, 273, jpegOffset);

    std::vector<uint8_t> file(rawOffset + rawBytes.size(), 0);
    file[0] = 'I'; file[1] = 'I';
    writeU16(file, 2, 42);
    writeU32(file, 4, ifd0Offset);

    auto serializeIfd = [&](const std::vector<TiffEntry>& entries, uint32_t baseOffset) {
        writeU16(file, baseOffset, static_cast<uint16_t>(entries.size()));
        uint32_t entryOffset = baseOffset + 2;
        uint32_t dataOffset = entryOffset + static_cast<uint32_t>(entries.size()) * 12 + 4;
        for (const auto& e : entries) {
            writeU16(file, entryOffset, e.tag);
            writeU16(file, entryOffset + 2, e.type);
            writeU32(file, entryOffset + 4, e.count);
            if (e.payload.size() <= 4) {
                std::copy(e.payload.begin(), e.payload.end(), file.begin() + entryOffset + 8);
            } else {
                writeU32(file, entryOffset + 8, dataOffset);
                std::copy(e.payload.begin(), e.payload.end(), file.begin() + dataOffset);
                dataOffset += static_cast<uint32_t>((e.payload.size() + 1) & ~size_t(1));
            }
            entryOffset += 12;
        }
    };
    serializeIfd(ifd0, ifd0Offset);
    serializeIfd(subIfd, subIfdOffset);
    std::copy(jpegBytes.begin(), jpegBytes.end(), file.begin() + jpegOffset);
    std::copy(rawBytes.begin(), rawBytes.end(), file.begin() + rawOffset);

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(file.data()), static_cast<std::streamsize>(file.size()));
    require(bool(out), "failed writing synthetic DNG " + path.string());
}

Session makePreviewSession() {
    sony2fuji_session* handle = nullptr;
    require(sony2fuji_session_create(&handle) == SONY2FUJI_STATUS_OK, "session create");
    Session session(handle, sony2fuji_session_destroy);
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    require(sony2fuji_session_set_gpu_config(handle, &gpu) == SONY2FUJI_STATUS_OK, "set gpu off");
    require(sony2fuji_session_set_raw_exposure_mode(handle, SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK,
        "set preview exposure mode");
    return session;
}

sony2fuji_request makeRequest(const char* path) {
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = path;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    request.temperature = 6500;
    request.brightness = 1.0f;
    request.contrast = 1.0f;
    request.saturation = 1.0f;
    request.intent = SONY2FUJI_INTENT_PREVIEW;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    return request;
}

void renderPreview(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_process(session, &request, &buffer);
    require(status == SONY2FUJI_STATUS_OK && buffer.data && buffer.size_bytes > 0,
        "sony2fuji_process failed with status " + std::to_string(status));
    sony2fuji_release_buffer(&buffer);
}

} // namespace

int main() {
    try {
        TempDir tmp;
        const auto sampleA = tmp.path / "sample-a.dng";
        const auto sampleB = tmp.path / "sample-b.dng";
        // Raw midtone signal (~0.05 linear -> 265), 1024x1024 embedded JPEG gray (~110 sRGB).
        writeSyntheticDngWithJpeg(sampleA, 1024, 1024, 110, 265, 90);
        writeSyntheticDngWithJpeg(sampleB, 1024, 1024, 190, 265, 90);

        // 1. Direct loadPreviewLuminance must downscale embedded JPEG instead of full-size decode.
        const auto globalBefore = sony2fuji::previewExposureDiagnostics();
        const auto lum = sony2fuji::loadPreviewLuminance(sampleA.string());
        const auto globalAfter = sony2fuji::previewExposureDiagnostics();
        require(lum.size() == 128u * 128u, "loadPreviewLuminance failed to decode synthetic DNG JPEG");
        require(globalAfter.jpegDecodes == globalBefore.jpegDecodes + 1,
            "direct loadPreviewLuminance did not record JPEG decode");
        require(globalAfter.lastJpegSourcePixels == 1024ull * 1024ull,
            "unexpected source JPEG pixel count: " + std::to_string(globalAfter.lastJpegSourcePixels));
        require(globalAfter.lastJpegDecodedPixels > 0 &&
                globalAfter.lastJpegDecodedPixels < globalAfter.lastJpegSourcePixels,
            "embedded JPEG decoded at full size (" + std::to_string(globalAfter.lastJpegDecodedPixels) +
            " == " + std::to_string(globalAfter.lastJpegSourcePixels) + ")");

        // 2. Same-session repeated preview exposure matching must not re-open file or re-decode JPEG.
        auto session = makePreviewSession();
        const std::string pathA = sampleA.string();
        const std::string pathB = sampleB.string();
        const auto reqA = makeRequest(pathA.c_str());
        const auto reqB = makeRequest(pathB.c_str());

        renderPreview(session.get(), reqA);
        const auto diag1 = sony2fuji::previewExposureDiagnostics(session.get());
        require(diag1.thumbnailOpens == 1 && diag1.jpegDecodes == 1 && diag1.cacheMisses == 1,
            "initial session preview decode counts mismatch");
        require(diag1.lastJpegDecodedPixels > 0 && diag1.lastJpegDecodedPixels < diag1.lastJpegSourcePixels,
            "initial session preview decoded JPEG at full size");
        float ev1 = 0, metaEv1 = 0;
        require(sony2fuji_session_get_raw_exposure(session.get(), &ev1, &metaEv1) == SONY2FUJI_STATUS_OK,
            "get initial raw exposure");

        // Force RAW re-decode via FBDD noise reduction toggle (not a raw_cache hit).
        const uint64_t decodesBeforeFbdd = sony2fuji_session_get_raw_decode_count(session.get());
        require(sony2fuji_session_set_raw_noise_reduction(session.get(), 1) == SONY2FUJI_STATUS_OK, "set FBDD=1");
        renderPreview(session.get(), reqA);
        require(sony2fuji_session_get_raw_decode_count(session.get()) == decodesBeforeFbdd + 1,
            "FBDD change should trigger RAW re-decode");
        const auto diag2 = sony2fuji::previewExposureDiagnostics(session.get());
        require(diag2.thumbnailOpens == diag1.thumbnailOpens,
            "repeated preview match re-opened file on FBDD change (opens " +
            std::to_string(diag1.thumbnailOpens) + " -> " + std::to_string(diag2.thumbnailOpens) + ")");
        require(diag2.jpegDecodes == diag1.jpegDecodes,
            "repeated preview match re-decoded JPEG on FBDD change");
        require(diag2.cacheHits == diag1.cacheHits + 1,
            "repeated preview match did not hit session preview cache on FBDD change");

        // Switch processing_version (destroys RAWProcessor because legacySonyCrop flips!) -> still cache hit.
        require(sony2fuji_session_set_processing_version(session.get(), SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK,
            "set BASIC_V3");
        renderPreview(session.get(), reqA);
        const auto diag3 = sony2fuji::previewExposureDiagnostics(session.get());
        require(diag3.thumbnailOpens == diag2.thumbnailOpens && diag3.jpegDecodes == diag2.jpegDecodes &&
                diag3.cacheHits == diag2.cacheHits + 1,
            "processing_version switch re-opened file or re-decoded JPEG instead of hitting session cache");

        // Exposure mode round-trip (PREVIEW -> SENSOR -> PREVIEW) + back to LEGACY / FBDD=0.
        require(sony2fuji_session_set_raw_exposure_mode(session.get(), SONY2FUJI_EXPOSURE_SENSOR) == SONY2FUJI_STATUS_OK,
            "set SENSOR");
        renderPreview(session.get(), reqA);
        require(sony2fuji_session_set_processing_version(session.get(), SONY2FUJI_PROCESSING_LEGACY) == SONY2FUJI_STATUS_OK,
            "restore LEGACY");
        require(sony2fuji_session_set_raw_noise_reduction(session.get(), 0) == SONY2FUJI_STATUS_OK, "restore FBDD=0");
        require(sony2fuji_session_set_raw_exposure_mode(session.get(), SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK,
            "restore PREVIEW");
        renderPreview(session.get(), reqA);
        const auto diag4 = sony2fuji::previewExposureDiagnostics(session.get());
        require(diag4.thumbnailOpens == diag3.thumbnailOpens && diag4.jpegDecodes == diag3.jpegDecodes &&
                diag4.cacheHits == diag3.cacheHits + 1,
            "exposure mode round-trip missed session preview cache");
        float evRestored = 0;
        require(sony2fuji_session_get_raw_exposure(session.get(), &evRestored, &metaEv1) == SONY2FUJI_STATUS_OK &&
                std::abs(evRestored - ev1) < 1e-4f,
            "cached preview exposure EV drifted");

        // Photo A -> B -> A in the same session: B misses once, returning to A hits cache.
        renderPreview(session.get(), reqB);
        const auto diagAfterB = sony2fuji::previewExposureDiagnostics(session.get());
        require(diagAfterB.thumbnailOpens == diag4.thumbnailOpens + 1 &&
                diagAfterB.jpegDecodes == diag4.jpegDecodes + 1 &&
                diagAfterB.cacheMisses == diag4.cacheMisses + 1,
            "new photo B should open/decode its preview once");
        renderPreview(session.get(), reqA);
        const auto diagReturnA = sony2fuji::previewExposureDiagnostics(session.get());
        require(diagReturnA.thumbnailOpens == diagAfterB.thumbnailOpens &&
                diagReturnA.jpegDecodes == diagAfterB.jpegDecodes &&
                diagReturnA.cacheHits == diagAfterB.cacheHits + 1,
            "returning to photo A in same session re-opened file or missed cache");

        // 3. Fingerprint invalidation: replace sampleA on disk with brighter embedded JPEG & bumped mtime.
        const auto oldStamp = std::filesystem::last_write_time(sampleA);
        writeSyntheticDngWithJpeg(sampleA, 1024, 1024, 220, 265, 92);
        std::filesystem::last_write_time(sampleA, oldStamp + std::chrono::seconds(2));
        renderPreview(session.get(), reqA);
        const auto diagInvalidated = sony2fuji::previewExposureDiagnostics(session.get());
        require(diagInvalidated.thumbnailOpens == diagReturnA.thumbnailOpens + 1 &&
                diagInvalidated.jpegDecodes == diagReturnA.jpegDecodes + 1 &&
                diagInvalidated.cacheMisses == diagReturnA.cacheMisses + 1,
            "file fingerprint change did not invalidate preview exposure cache");
        require(diagInvalidated.lastJpegDecodedPixels < diagInvalidated.lastJpegSourcePixels,
            "post-invalidation decode used full-size JPEG");
        float evBrighter = 0;
        require(sony2fuji_session_get_raw_exposure(session.get(), &evBrighter, &metaEv1) == SONY2FUJI_STATUS_OK &&
                evBrighter > ev1 + 0.5f,
            "post-invalidation EV did not reflect brighter embedded JPEG (" +
            std::to_string(ev1) + " -> " + std::to_string(evBrighter) + ")");

        // 4. Real bundled DJI DNG verification (embedded 720x720 JPEG).
        const std::filesystem::path djiDng = std::filesystem::path(TEST_EXAMPLES_DIR) / "DJI_20250602164503_0444_D.DNG";
        if (std::filesystem::is_regular_file(djiDng)) {
            auto djiSession = makePreviewSession();
            const std::string djiPath = djiDng.string();
            auto djiReq = makeRequest(djiPath.c_str());
            djiReq.preview_long_edge = 512;
            renderPreview(djiSession.get(), djiReq);
            const auto dji1 = sony2fuji::previewExposureDiagnostics(djiSession.get());
            require(dji1.thumbnailOpens == 1 && dji1.jpegDecodes == 1 &&
                    dji1.lastJpegDecodedPixels > 0 && dji1.lastJpegDecodedPixels < dji1.lastJpegSourcePixels,
                "DJI DNG initial preview decode did not downscale JPEG");
            require(sony2fuji_session_set_raw_noise_reduction(djiSession.get(), 1) == SONY2FUJI_STATUS_OK, "DJI FBDD=1");
            renderPreview(djiSession.get(), djiReq);
            const auto dji2 = sony2fuji::previewExposureDiagnostics(djiSession.get());
            require(dji2.thumbnailOpens == 1 && dji2.jpegDecodes == 1 && dji2.cacheHits == 1,
                "DJI DNG repeated preview match re-opened file or re-decoded JPEG");
        }

        std::cout << "PASS: preview exposure caches embedded luminance per session, downscales JPEG decode, and invalidates on file fingerprint change\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
