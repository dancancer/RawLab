#include "core/wavelet_cache.h"
#include "native_gpu_test_support.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <random>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

using Session = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;
using Probe = std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)>;

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

struct TempDir {
    std::filesystem::path path;
    TempDir() {
        path = std::filesystem::temp_directory_path() /
            ("rawtools-hsl-wavelet-" + std::to_string(
                std::chrono::steady_clock::now().time_since_epoch().count()));
        std::filesystem::create_directories(path);
    }
    ~TempDir() {
        std::error_code ignored;
        std::filesystem::remove_all(path, ignored);
    }
};

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
    std::vector<uint8_t> payload;
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

// Writes a 512x512 RGGB Bayer DNG with multiple flat noisy intensity zones so
// wavelet noise estimation finds >= 8 flat tiles and executes filtering (`applied == true`).
void writeNoisyBayerDng(const std::filesystem::path& path, int width = 512, int height = 512) {
    std::mt19937 rng(7419);
    std::normal_distribution<float> noise(0.0f, 38.0f);
    std::vector<uint8_t> rawBytes(static_cast<size_t>(width) * height * 2);
    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {
            const float zone = 420.0f + ((y >= height / 2) ? 320.0f : 0.0f) +
                ((x >= width / 2) ? 220.0f : 0.0f);
            const float sample = std::clamp(zone + noise(rng), 80.0f, 3900.0f);
            writeU16(rawBytes, (static_cast<size_t>(y) * width + x) * 2,
                static_cast<uint16_t>(std::lround(sample)));
        }
    }

    std::vector<TiffEntry> ifd0 = {
        entryU32(254, {0}),
        entryU32(256, {static_cast<uint32_t>(width)}),
        entryU32(257, {static_cast<uint32_t>(height)}),
        entryU16(258, {16}),
        entryU16(259, {1}),
        entryU16(262, {32803}),
        entryAscii(271, "RawLab"),
        entryAscii(272, "WaveletCacheTest"),
        entryU32(273, {0}),
        entryU16(274, {1}),
        entryU16(277, {1}),
        entryU32(278, {static_cast<uint32_t>(height)}),
        entryU32(279, {static_cast<uint32_t>(rawBytes.size())}),
        entryU16(284, {1}),
        entryU16(33421, {2, 2}),
        entryBytes(33422, 1, {0, 1, 1, 2}),
        entryBytes(50706, 1, {1, 4, 0, 0}),
        entryBytes(50707, 1, {1, 3, 0, 0}),
        entryAscii(50708, "RawLab WaveletCache"),
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

    size_t ifdSize = 2 + ifd0.size() * 12 + 4;
    for (const auto& e : ifd0) {
        if (e.payload.size() > 4) ifdSize += (e.payload.size() + 1) & ~size_t(1);
    }
    const uint32_t ifd0Offset = 8;
    const uint32_t rawOffset = static_cast<uint32_t>((ifd0Offset + ifdSize + 3) & ~size_t(3));
    for (auto& e : ifd0) {
        if (e.tag == 273) {
            writeU32(e.payload, 0, rawOffset);
            break;
        }
    }

    std::vector<uint8_t> file(rawOffset + rawBytes.size(), 0);
    file[0] = 'I'; file[1] = 'I';
    writeU16(file, 2, 42);
    writeU32(file, 4, ifd0Offset);
    writeU16(file, ifd0Offset, static_cast<uint16_t>(ifd0.size()));
    uint32_t entryOffset = ifd0Offset + 2;
    uint32_t dataOffset = entryOffset + static_cast<uint32_t>(ifd0.size()) * 12 + 4;
    for (const auto& e : ifd0) {
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
    std::copy(rawBytes.begin(), rawBytes.end(), file.begin() + rawOffset);

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(file.data()), static_cast<std::streamsize>(file.size()));
    require(bool(out), "failed writing noisy Bayer DNG " + path.string());
}

sony2fuji_request makeRawRequest(const char* path, bool viewportPreview) {
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
    if (viewportPreview) request.preview_long_edge = 512;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    return request;
}

std::vector<uint8_t> render(sony2fuji_session* session, const sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_process(session, &request, &buffer);
    require(status == SONY2FUJI_STATUS_OK, "sony2fuji_process failed with status " + std::to_string(status));
    const auto* bytes = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> pixels(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return pixels;
}

Probe createProbe(sony2fuji_session* session, const sony2fuji_request& request, uint64_t requestRevision) {
    sony2fuji_hsl_probe* probe = nullptr;
    const auto status = sony2fuji_session_create_hsl_probe(session, &request, 1, requestRevision, &probe);
    require(status == SONY2FUJI_STATUS_OK && probe != nullptr,
        "sony2fuji_session_create_hsl_probe failed with status " + std::to_string(status));
    return Probe(probe, sony2fuji_hsl_probe_destroy);
}

Session makeWaveletSession(
    sony2fuji_gpu_mode gpuMode, sony2fuji_processing_version version, bool viewportPreview
) {
    sony2fuji_session* handle = nullptr;
    require(sony2fuji_session_create(&handle) == SONY2FUJI_STATUS_OK, "session create");
    Session session(handle, sony2fuji_session_destroy);
    require(sony2fuji_session_set_processing_version(handle, version) == SONY2FUJI_STATUS_OK,
        "set processing version");
    require(sony2fuji_session_set_viewport_preview(handle, viewportPreview ? 1 : 0) == SONY2FUJI_STATUS_OK,
        "set viewport preview");
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), gpuMode};
    require(sony2fuji_session_set_gpu_config(handle, &gpu) == SONY2FUJI_STATUS_OK, "set gpu config");
    sony2fuji_wavelet_denoise_config wavelet{
        SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(wavelet), 1, 40, 46, 50
    };
    require(sony2fuji_session_set_wavelet_denoise(handle, &wavelet) == SONY2FUJI_STATUS_OK,
        "set wavelet denoise");
    return session;
}

void verifySamplingPreservesWaveletCache(
    const char* rawPath, bool viewportPreview, sony2fuji_gpu_mode gpuMode,
    sony2fuji_processing_version version, const std::string& label
) {
    const bool nativeGpu = rawlabtest::nativeGpuAvailable();
    const bool gpuCompiled = rawlabtest::nativeBackend != SONY2FUJI_BACKEND_CPU;
    const bool legacyGpu = version == SONY2FUJI_PROCESSING_LEGACY &&
        (gpuMode == SONY2FUJI_GPU_AUTO || gpuMode == SONY2FUJI_GPU_FORCE) && nativeGpu;
    const bool legacyAutoFallbackNoGpu = version == SONY2FUJI_PROCESSING_LEGACY &&
        gpuMode == SONY2FUJI_GPU_AUTO && gpuCompiled && !nativeGpu;

    auto session = makeWaveletSession(gpuMode, version, viewportPreview);
    const auto request = makeRawRequest(rawPath, viewportPreview);

    const auto firstPixels = render(session.get(), request);
    const auto afterFirstRender = sony2fuji::waveletCacheDiagnostics(session.get());
    const uint64_t expectedInitialRuns = legacyAutoFallbackNoGpu ? 2u : 1u;
    require(afterFirstRender.filterRuns == expectedInitialRuns,
        label + ": expected " + std::to_string(expectedInitialRuns) +
        " initial wavelet filterRun(s), got " + std::to_string(afterFirstRender.filterRuns));
    require(afterFirstRender.appliedRuns == 1,
        label + ": wavelet denoise did not actually apply (appliedRuns=" +
        std::to_string(afterFirstRender.appliedRuns) + ")");
    require(afterFirstRender.outputHits == 0,
        label + ": initial render unexpectedly hit output cache");
    const auto renderedBackend = sony2fuji_session_get_last_backend(session.get());
    if (legacyGpu) {
        require(renderedBackend == rawlabtest::nativeBackend,
            label + ": expected native GPU backend for initial Legacy GPU render");
    } else if (gpuMode == SONY2FUJI_GPU_OFF || !nativeGpu) {
        require(renderedBackend == SONY2FUJI_BACKEND_CPU,
            label + ": expected CPU backend for initial render");
    }

    if (legacyAutoFallbackNoGpu) {
        require(afterFirstRender.hasStoredMode && afterFirstRender.lastStoredMode == sony2fuji::GpuMode::Off,
            label + ": Auto fallback render must store Off entry");
    }

    const auto probe1 = createProbe(session.get(), request, 1);
    sony2fuji_hsl_probe_query query{SONY2FUJI_HSL_PROBE_VERSION, sizeof(query), 1, 1, 0.5f, 0.5f};
    sony2fuji_hsl_probe_result sample{};
    require(sony2fuji_hsl_probe_sample(probe1.get(), &query, &sample) == SONY2FUJI_STATUS_OK,
        label + ": hsl probe sample 1");
    require(sample.availability == SONY2FUJI_HSL_PROBE_AVAILABLE ||
            sample.availability == SONY2FUJI_HSL_PROBE_NEAR_GRAY,
        label + ": probe 1 unexpectedly unavailable");

    const auto afterProbe1 = sony2fuji::waveletCacheDiagnostics(session.get());
    if (legacyGpu) {
        // Legacy GPU cached GPU output; CPU HSL probe must run CPU wavelet once reusing analysis without overwriting GPU cache.
        require(afterProbe1.filterRuns == afterFirstRender.filterRuns + 1,
            label + ": Legacy GPU probe did not run CPU wavelet (filterRuns " +
            std::to_string(afterFirstRender.filterRuns) + " -> " + std::to_string(afterProbe1.filterRuns) + ")");
        require(afterProbe1.appliedRuns == afterFirstRender.appliedRuns + 1,
            label + ": Legacy GPU probe did not apply CPU wavelet");
        require(afterProbe1.analysisHits == 1,
            label + ": Legacy GPU probe expected analysisHits == 1, got " +
            std::to_string(afterProbe1.analysisHits));
        require(afterProbe1.outputHits == afterFirstRender.outputHits,
            label + ": Legacy GPU probe must not hit GPU wavelet output cache");
    } else {
        // Auto fallback stored (opts, Off, cpuExecuted=true), so CPU probes hit cache directly without recomputing.
        require(afterProbe1.filterRuns == afterFirstRender.filterRuns &&
                afterProbe1.appliedRuns == afterFirstRender.appliedRuns &&
                afterProbe1.outputHits == afterFirstRender.outputHits + 1,
            label + ": CPU wavelet probe did not hit wavelet output cache");
    }

    const auto secondPixels = render(session.get(), request);
    const auto afterSecondRender = sony2fuji::waveletCacheDiagnostics(session.get());

    require(secondPixels == firstPixels, label + ": post-sample render changed pixels");
    require(sony2fuji_session_get_last_backend(session.get()) == renderedBackend,
        label + ": post-sample render backend changed");
    if (legacyAutoFallbackNoGpu) {
        // Post-sample Auto render still misses the Off fallback entry so GPU recovery can be retried,
        // then re-stores (opts, Off, cpuExecuted=true) upon CPU fallback.
        require(afterSecondRender.filterRuns == afterProbe1.filterRuns + 2,
            label + ": Auto fallback post-sample render filterRuns mismatch");
        require(afterSecondRender.appliedRuns == afterProbe1.appliedRuns + 1,
            label + ": Auto fallback post-sample render appliedRuns mismatch");
        require(afterSecondRender.analysisHits == afterProbe1.analysisHits + 2,
            label + ": Auto fallback post-sample render analysisHits mismatch");
        require(afterSecondRender.outputHits == afterProbe1.outputHits,
            label + ": Auto fallback post-sample render unexpectedly hit output cache");
        require(afterSecondRender.hasStoredMode && afterSecondRender.lastStoredMode == sony2fuji::GpuMode::Off,
            label + ": Auto fallback post-sample render must store Off entry");
    } else {
        require(afterSecondRender.filterRuns == afterProbe1.filterRuns,
            label + ": post-sample render recomputed wavelet (filterRuns " +
            std::to_string(afterProbe1.filterRuns) + " -> " + std::to_string(afterSecondRender.filterRuns) + ")");
        require(afterSecondRender.appliedRuns == afterProbe1.appliedRuns,
            label + ": post-sample render re-applied wavelet");
        require(afterSecondRender.outputHits == afterProbe1.outputHits + 1,
            label + ": post-sample render missed wavelet output cache (outputHits " +
            std::to_string(afterProbe1.outputHits) + " -> " + std::to_string(afterSecondRender.outputHits) + ")");
    }

    // Second probe -> render cycle confirms cache remains intact across repeated sampling.
    const auto probe2 = createProbe(session.get(), request, 2);
    const auto afterProbe2 = sony2fuji::waveletCacheDiagnostics(session.get());
    const auto thirdPixels = render(session.get(), request);
    const auto afterThirdRender = sony2fuji::waveletCacheDiagnostics(session.get());
    require(thirdPixels == firstPixels, label + ": third render changed pixels");
    require(sony2fuji_session_get_last_backend(session.get()) == renderedBackend,
        label + ": third render backend changed");
    if (legacyGpu) {
        require(afterProbe2.filterRuns == afterSecondRender.filterRuns + 1 &&
                afterProbe2.appliedRuns == afterSecondRender.appliedRuns + 1 &&
                afterProbe2.analysisHits == afterSecondRender.analysisHits + 1 &&
                afterProbe2.outputHits == afterSecondRender.outputHits,
            label + ": second Legacy GPU probe diagnostics mismatch");
        require(afterThirdRender.filterRuns == afterProbe2.filterRuns &&
                afterThirdRender.appliedRuns == afterProbe2.appliedRuns &&
                afterThirdRender.outputHits == afterProbe2.outputHits + 1,
            label + ": second post-sample Legacy GPU render missed wavelet output cache");
    } else if (legacyAutoFallbackNoGpu) {
        require(afterProbe2.filterRuns == afterSecondRender.filterRuns &&
                afterProbe2.appliedRuns == afterSecondRender.appliedRuns &&
                afterProbe2.outputHits == afterSecondRender.outputHits + 1,
            label + ": second Auto fallback probe missed CPU fallback cache");
        require(afterThirdRender.filterRuns == afterProbe2.filterRuns + 2 &&
                afterThirdRender.appliedRuns == afterProbe2.appliedRuns + 1 &&
                afterThirdRender.analysisHits == afterProbe2.analysisHits + 2 &&
                afterThirdRender.outputHits == afterProbe2.outputHits,
            label + ": third Auto fallback render diagnostics mismatch");
    } else {
        require(afterProbe2.filterRuns == afterSecondRender.filterRuns &&
                afterProbe2.outputHits == afterSecondRender.outputHits + 1,
            label + ": second CPU probe missed wavelet output cache");
        require(afterThirdRender.filterRuns == afterProbe2.filterRuns &&
                afterThirdRender.outputHits == afterProbe2.outputHits + 1,
            label + ": second post-sample render missed wavelet output cache");
    }
}

void verifyProbeBeforeRenderReusesCpuWavelet(
    const char* rawPath, bool viewportPreview, sony2fuji_gpu_mode gpuMode,
    sony2fuji_processing_version version, const std::string& label
) {
    auto session = makeWaveletSession(gpuMode, version, viewportPreview);
    const auto request = makeRawRequest(rawPath, viewportPreview);

    const auto probe = createProbe(session.get(), request, 1);
    const auto afterProbe = sony2fuji::waveletCacheDiagnostics(session.get());
    require(afterProbe.filterRuns == 1 && afterProbe.appliedRuns == 1,
        label + ": expected 1 applied filterRun during initial probe, got filterRuns=" +
        std::to_string(afterProbe.filterRuns) + ", appliedRuns=" + std::to_string(afterProbe.appliedRuns));

    const auto pixels = render(session.get(), request);
    const auto afterRender = sony2fuji::waveletCacheDiagnostics(session.get());
    require(!pixels.empty(), label + ": empty render");
    require(afterRender.filterRuns == 1 && afterRender.appliedRuns == 1,
        label + ": render after CPU wavelet probe recomputed wavelet");
    require(afterRender.outputHits == afterProbe.outputHits + 1,
        label + ": render after CPU wavelet probe missed cache");
}

void verifyForceClarityProbeDoesNotSpoofForceCache(
    const char* rawPath, bool viewportPreview, const std::string& label
) {
    const bool nativeGpu = rawlabtest::nativeGpuAvailable();
    const bool gpuCompiled = rawlabtest::nativeBackend != SONY2FUJI_BACKEND_CPU;

    auto session = makeWaveletSession(SONY2FUJI_GPU_FORCE, SONY2FUJI_PROCESSING_LEGACY, viewportPreview);
    const auto request = makeRawRequest(rawPath, viewportPreview);

    sony2fuji_atmosphere_config atmo{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(atmo), 0.25f, 0.0f};
    require(sony2fuji_session_set_atmosphere(session.get(), &atmo) == SONY2FUJI_STATUS_OK,
        label + ": set clarity=0.25");

    const auto probe = createProbe(session.get(), request, 1);
    const auto afterProbe = sony2fuji::waveletCacheDiagnostics(session.get());
    require(afterProbe.filterRuns == 1 && afterProbe.appliedRuns == 1 && afterProbe.outputHits == 0,
        label + ": initial Force+clarity probe diagnostics mismatch");
    require(afterProbe.hasStoredMode && afterProbe.lastStoredMode == sony2fuji::GpuMode::Off,
        label + ": Force session CPU probe must store GpuMode::Off, not Force");

    atmo.clarity = 0.0f;
    require(sony2fuji_session_set_atmosphere(session.get(), &atmo) == SONY2FUJI_STATUS_OK,
        label + ": reset clarity=0");

    sony2fuji_buffer buffer{};
    const auto status = sony2fuji_process(session.get(), &request, &buffer);
    const auto afterRender = sony2fuji::waveletCacheDiagnostics(session.get());
    require(afterRender.outputHits == afterProbe.outputHits,
        label + ": clarity=0 Force render unexpectedly hit CPU probe cache");

    if (nativeGpu) {
        require(status == SONY2FUJI_STATUS_OK && buffer.data != nullptr && buffer.size_bytes > 0,
            label + ": Force render with native GPU failed with status " + std::to_string(status));
        require(sony2fuji_session_get_last_backend(session.get()) == rawlabtest::nativeBackend,
            label + ": Force render did not execute on native GPU backend");
        require(afterRender.filterRuns == afterProbe.filterRuns + 1 &&
                afterRender.appliedRuns == afterProbe.appliedRuns + 1 &&
                afterRender.analysisHits == afterProbe.analysisHits + 1,
            label + ": Force render did not recompute GPU wavelet reusing analysis");
        require(afterRender.hasStoredMode && afterRender.lastStoredMode == sony2fuji::GpuMode::Force,
            label + ": completed Force render did not record GpuMode::Force");
        sony2fuji_release_buffer(&buffer);

        const auto secondForce = render(session.get(), request);
        const auto afterSecond = sony2fuji::waveletCacheDiagnostics(session.get());
        require(!secondForce.empty() && afterSecond.outputHits == afterRender.outputHits + 1 &&
                afterSecond.filterRuns == afterRender.filterRuns,
            label + ": subsequent genuine Force render did not hit Force GPU cache");
    } else if (gpuCompiled) {
        sony2fuji_release_buffer(&buffer);
        require(status != SONY2FUJI_STATUS_OK,
            label + ": Force render without hardware GPU must fail instead of succeeding");
        require(afterRender.filterRuns == afterProbe.filterRuns + 1 &&
                afterRender.appliedRuns == afterProbe.appliedRuns,
            label + ": Force render without hardware GPU must attempt GPU wavelet and fail cleanly");
    } else {
        sony2fuji_release_buffer(&buffer);
        require(status == SONY2FUJI_STATUS_UNSUPPORTED && afterRender.filterRuns == afterProbe.filterRuns,
            label + ": CPU-only Force render mismatch");
    }
}

} // namespace

int main() {
    try {
        TempDir tmp;
        const auto noisySynthetic = tmp.path / "noisy-bayer-512.dng";
        writeNoisyBayerDng(noisySynthetic, 512, 512);
        const std::string synthPath = noisySynthetic.string();

        // Exact (non-viewport) native cache slot on noisy 512x512 Bayer DNG where applied == true.
        verifySamplingPreservesWaveletCache(synthPath.c_str(), false, SONY2FUJI_GPU_OFF,
            SONY2FUJI_PROCESSING_LEGACY, "Synth/Off/Legacy");
        verifySamplingPreservesWaveletCache(synthPath.c_str(), false, SONY2FUJI_GPU_AUTO,
            SONY2FUJI_PROCESSING_C5_V2, "Synth/Auto/C5_V2");
        verifySamplingPreservesWaveletCache(synthPath.c_str(), false, SONY2FUJI_GPU_AUTO,
            SONY2FUJI_PROCESSING_LEGACY, "Synth/Auto/Legacy");
        if (rawlabtest::nativeGpuAvailable()) {
            verifySamplingPreservesWaveletCache(synthPath.c_str(), false, SONY2FUJI_GPU_FORCE,
                SONY2FUJI_PROCESSING_LEGACY, "Synth/Force/Legacy");
        }
        verifyProbeBeforeRenderReusesCpuWavelet(synthPath.c_str(), false, SONY2FUJI_GPU_OFF,
            SONY2FUJI_PROCESSING_LEGACY, "Synth/ProbeFirst/Off/Legacy");
        verifyProbeBeforeRenderReusesCpuWavelet(synthPath.c_str(), false, SONY2FUJI_GPU_AUTO,
            SONY2FUJI_PROCESSING_C5_V2, "Synth/ProbeFirst/Auto/C5_V2");
        verifyForceClarityProbeDoesNotSpoofForceCache(synthPath.c_str(), false, "Synth/Force/ClarityProbe");

        // Real bundled photo (3072x3072 DJI DNG) via 512px viewport preview so wavelet applied == true.
        const std::filesystem::path djiDng = std::filesystem::path(TEST_EXAMPLES_DIR) / "DJI_20250602164503_0444_D.DNG";
        require(std::filesystem::is_regular_file(djiDng),
            "Missing bundled DJI DNG fixture: " + djiDng.string());
        const std::string djiPath = djiDng.string();
        verifySamplingPreservesWaveletCache(djiPath.c_str(), true, SONY2FUJI_GPU_OFF,
            SONY2FUJI_PROCESSING_LEGACY, "DJI/Off/Legacy");
        verifySamplingPreservesWaveletCache(djiPath.c_str(), true, SONY2FUJI_GPU_AUTO,
            SONY2FUJI_PROCESSING_C5_V2, "DJI/Auto/C5_V2");
        verifySamplingPreservesWaveletCache(djiPath.c_str(), true, SONY2FUJI_GPU_AUTO,
            SONY2FUJI_PROCESSING_LEGACY, "DJI/Auto/Legacy");
        if (rawlabtest::nativeGpuAvailable()) {
            verifySamplingPreservesWaveletCache(djiPath.c_str(), true, SONY2FUJI_GPU_FORCE,
                SONY2FUJI_PROCESSING_LEGACY, "DJI/Force/Legacy");
        }
        verifyForceClarityProbeDoesNotSpoofForceCache(djiPath.c_str(), true, "DJI/Force/ClarityProbe");

        std::cout << "PASS: HSL sampling preserves wavelet output cache across Off/Auto/Force and C5_V2/Legacy with applied wavelet denoising\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
