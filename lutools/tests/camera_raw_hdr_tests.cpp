#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "sony2fuji/raw_processor.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <numeric>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
template<class T> T init() {
    T value{};
    value.version = 1;
    value.struct_size = sizeof(T);
    return value;
}
void check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
struct Session {
    sony2fuji_session* value = nullptr;
    Session() { check(sony2fuji_session_create(&value) == SONY2FUJI_STATUS_OK, "session creation failed"); }
    ~Session() { sony2fuji_session_destroy(value); }
};
using Clock = std::chrono::steady_clock;
long long elapsed(Clock::time_point start) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
}
struct TemporaryDirectory {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
        ("rawlab-camera-hdr-" + std::to_string(Clock::now().time_since_epoch().count()));
    TemporaryDirectory() { check(std::filesystem::create_directory(path), "cannot create test output directory"); }
    ~TemporaryDirectory() { std::error_code error; std::filesystem::remove_all(path, error); }
};
struct Pair {
    sony2fuji_hdr_image_pair_v1 value = init<sony2fuji_hdr_image_pair_v1>();
    ~Pair() { sony2fuji_hdr_release_pair(&value); }
};

void unavailableTemperatureWB(const std::string& fixture) {
    TemporaryDirectory directory;
    std::ifstream input(fixture, std::ios::binary);
    std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(input), {}};
    const auto integer = [&](size_t offset, int count) {
        uint32_t value = 0;
        for (int i = 0; i < count; ++i) value |= uint32_t(bytes.at(offset + i)) << (i * 8);
        return value;
    };
    check(bytes.at(0) == 'I' && bytes.at(1) == 'I', "WB fixture must use little-endian TIFF");
    const size_t ifd = integer(4, 4);
    bool changed = false;
    for (uint32_t i = 0; i < integer(ifd, 2); ++i) {
        const size_t entry = ifd + 2 + i * 12;
        if (integer(entry, 2) != 50728) continue;
        check(integer(entry + 2, 2) == 5 && integer(entry + 4, 4) == 3, "Unexpected AsShotNeutral layout");
        const size_t offset = integer(entry + 8, 4);
        // 保留可显影的正增益，但让拍摄中性色落到相机色温模型之外。
        for (int c = 0; c < 3; ++c) for (int part = 0; part < 2; ++part) {
            const uint32_t value = c == 0 && part == 0 ? 1000 : 1;
            for (int byte = 0; byte < 4; ++byte) bytes.at(offset + c * 8 + part * 4 + byte) = uint8_t(value >> (byte * 8));
        }
        changed = true;
    }
    check(changed, "WB fixture has no AsShotNeutral");
    const auto path = (directory.path / "uncalibrated-wb.dng").u8string();
    std::ofstream output(path, std::ios::binary);
    output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    output.close();
    sony2fuji::RAWProcessor processor;
    int width = 0, height = 0;
    uint64_t pixels = 0;
    float temperature = 0, tint = 0;
    check(processor.inspectCameraHDR(path, width, height, pixels) == sony2fuji::ErrorCode::Success &&
        !processor.getAsShotWhiteBalance(temperature, tint), "WB fixture did not reproduce unavailable calibration");
    auto info = init<sony2fuji_hdr_source_info_v1>();
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    check(sony2fuji_hdr_probe_camera_raw(path.c_str(), &info, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Unavailable custom WB must not reject a source that supports as-shot development");
    auto options = init<sony2fuji_hdr_decode_options_v1>();
    options.intent = SONY2FUJI_INTENT_PREVIEW; options.long_edge = 32;
    Pair asShot;
    check(sony2fuji_hdr_decode_camera_raw(nullptr, path.c_str(), &options, &asShot.value, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Unavailable custom WB disabled as-shot HDR development");
    auto development = init<sony2fuji_hdr_camera_development_v1>();
    development.white_balance = SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE; development.temperature = 5000;
    Pair rejected;
    check(sony2fuji_hdr_decode_camera_raw_with_development(nullptr, path.c_str(), &options, &development,
        &rejected.value, &diagnostic) == SONY2FUJI_STATUS_UNSUPPORTED &&
        diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT &&
        diagnostic.field == SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT && !rejected.value.owner_token,
        "Unavailable custom WB was reported as an unsupported RAW instead of camera development");
    const std::string model = "RawLab synthetic Bayer";
    std::vector<uint8_t> profile{'R','L','O','O','K','H','D','R'};
    const auto append = [&](uint64_t value, int count) {
        for (int i = 0; i < count; ++i) profile.push_back(uint8_t(value >> (i * 8)));
    };
    append(1, 4); append(model.size(), 4);
    const double forward[]{.7976749, .1351917, .0313534, .2880402, .7118741, .0000857, 0, 0, .8252100};
    for (int matrix = 0; matrix < 2; ++matrix) for (int i = 0; i < 9; ++i) {
        const double value = matrix == 0 ? (i % 4 == 0 ? 1 : 0) : forward[i];
        uint64_t bits = 0; std::memcpy(&bits, &value, sizeof(bits)); append(bits, 8);
    }
    profile.insert(profile.end(), model.begin(), model.end());
    const auto profilePath = (directory.path / "identity.rlook").u8string();
    std::ofstream resource(profilePath, std::ios::binary);
    resource.write(reinterpret_cast<const char*>(profile.data()), profile.size()); resource.close();
    auto profileInfo = init<sony2fuji_hdr_camera_profile_info_v1>();
    check(sony2fuji_hdr_probe_camera_profile(profilePath.c_str(), &profileInfo, &diagnostic) == SONY2FUJI_STATUS_OK,
        "Synthetic D65 profile is invalid");
    sony2fuji_hdr_camera_development_v2 profiled{};
    profiled.base = development; profiled.base.version = 2; profiled.base.struct_size = sizeof(profiled);
    profiled.profile_path = profilePath.c_str(); std::copy_n(profileInfo.sha256, 65, profiled.profile_sha256);
    Pair calibrated;
    check(sony2fuji_hdr_decode_camera_raw_with_development(nullptr, path.c_str(), &options, &profiled.base,
        &calibrated.value, &diagnostic) == SONY2FUJI_STATUS_OK && calibrated.value.owner_token && calibrated.value.hdr.data,
        "A supplied D65 profile was blocked by the source's unavailable camera white balance");
}

void verifyHEIFRenditions(const sony2fuji_hdr_image_pair_v1& expected,
                         const sony2fuji_hdr_image_pair_v1& actual) {
    check(actual.orientation_applied == 1 && actual.hdr.width == expected.hdr.width &&
          actual.hdr.height == expected.hdr.height && actual.sdr.width == expected.sdr.width &&
          actual.sdr.height == expected.sdr.height, "HEIF readback changed the oriented canvas");
    auto pixel = [](const sony2fuji_hdr_buffer_v1& image, uint32_t x, uint32_t y) {
        const auto* row = static_cast<const uint8_t*>(image.data) + y * image.stride_bytes;
        return reinterpret_cast<const float*>(row) + x * 3;
    };
    auto luminance = [](const float* p) { return .2126*p[0] + .7152*p[1] + .0722*p[2]; };
    auto code = [](double linear) {
        linear = std::clamp(linear,0.0,1.0);
        return 255 * (linear <= .0031308 ? 12.92*linear : 1.055*std::pow(linear,1/2.4)-.055);
    };
    auto percentile = [](std::vector<double>& values,double fraction) {
        check(!values.empty(),"HEIF fixture has no comparison values");
        const auto position = values.begin() + size_t(std::ceil(fraction * values.size()) - 1);
        std::nth_element(values.begin(),position,values.end());
        return *position;
    };
    std::vector<double> ev, base;
    double peak = 0;
    for (uint32_t y = 0; y < expected.hdr.height; ++y) for (uint32_t x = 0; x < expected.hdr.width; ++x) {
        const double reference = luminance(pixel(expected.hdr,x,y));
        const double decoded = luminance(pixel(actual.hdr,x,y));
        peak = std::max(peak,decoded);
        if (reference >= .01) ev.push_back(std::abs(std::log2(std::max(1e-6,decoded)/reference)));
        const auto* expectedBase = pixel(expected.sdr,x,y);
        const auto* decodedBase = pixel(actual.sdr,x,y);
        for (int c = 0; c < 3; ++c) base.push_back(std::abs(code(decodedBase[c])-code(expectedBase[c])));
    }
    const double p95 = percentile(ev,.95), mae = std::accumulate(base.begin(),base.end(),0.0)/base.size(), p99 = percentile(base,.99);
    std::cout << "HEIF HDR P95 EV " << p95 << ", SDR MAE " << mae << ", SDR P99 " << p99 << ", peak " << peak << '\n';
    // 这张去马赛克夹具处处是纹理，没有 A08 要求的平坦色块；整图 SDR P99 反映的是系统 HEVC 编码器在纹理上的损失
    // （arm64 约 7.8、x86_64 约 8.2），只记录不设门槛。A08 的 P99 由 numeric_acceptance.h 的色块样本检查 HEIF。
    check(p95 <= .10 && mae <= 2,"HEIF readback exceeded HDR/SDR numeric tolerances");
    if (expected.hdr.content_headroom > 1.05f) check(peak > 1.05,"HEIF readback lost its super-white luminance");
}

void cameraDevelopment(const char* path, const sony2fuji_hdr_image_pair_v1& baseline) {
    auto options = init<sony2fuji_hdr_decode_options_v1>();
    options.intent = SONY2FUJI_INTENT_FINAL;
    auto config = init<sony2fuji_hdr_camera_development_v1>();
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    auto decode = [&](Pair& pair) {
        return sony2fuji_hdr_decode_camera_raw_with_development(nullptr,path,&options,&config,&pair.value,&diagnostic);
    };
    Pair unchanged;
    check(decode(unchanged) == SONY2FUJI_STATUS_OK &&
          unchanged.value.hdr.size_bytes == baseline.hdr.size_bytes &&
          std::memcmp(unchanged.value.hdr.data,baseline.hdr.data,baseline.hdr.size_bytes) == 0 &&
          std::memcmp(unchanged.value.sdr.data,baseline.sdr.data,baseline.sdr.size_bytes) == 0,
          "Explicit default camera development changed old HDR pixels");
    config.white_balance = SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE;
    config.temperature = 9000;
    config.tint = 28;
    Pair customWhiteBalance;
    check(decode(customWhiteBalance) == SONY2FUJI_STATUS_OK &&
          customWhiteBalance.value.hdr.size_bytes == baseline.hdr.size_bytes &&
          std::memcmp(customWhiteBalance.value.hdr.data,baseline.hdr.data,baseline.hdr.size_bytes) != 0 &&
          std::memcmp(customWhiteBalance.value.sdr.data,baseline.sdr.data,baseline.sdr.size_bytes) != 0,
          "Camera-space white balance did not reach both planes");
    config = init<sony2fuji_hdr_camera_development_v1>();
    config.fbdd_level = 2;
    Pair denoised;
    check(decode(denoised) == SONY2FUJI_STATUS_OK && denoised.value.hdr.size_bytes == baseline.hdr.size_bytes &&
          std::memcmp(denoised.value.hdr.data,baseline.hdr.data,baseline.hdr.size_bytes) != 0,
          "Full Bayer FBDD did not change the HDR decode");
    options.intent = SONY2FUJI_INTENT_PREVIEW;
    options.long_edge = 32;
    Pair preview;
    check(decode(preview) == SONY2FUJI_STATUS_OK && preview.value.is_proxy &&
          std::max(preview.value.hdr.width,preview.value.hdr.height) == 32 &&
          std::memcmp(preview.value.source_sha256,baseline.source_sha256,32) == 0,
          "Bayer FBDD preview lost its bounded size or source identity");
    config.fbdd_level = 3;
    Pair rejected;
    check(decode(rejected) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
          diagnostic.field == SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT && !rejected.value.owner_token,
          "Invalid camera development published pixels");
    config.fbdd_level = 0;
    config.lens_flags = SONY2FUJI_HDR_CAMERA_LENS_DISTORTION;
    check(decode(rejected) == SONY2FUJI_STATUS_UNSUPPORTED &&
          diagnostic.field == SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT && !rejected.value.owner_token,
          "Missing lens calibration was silently ignored");
}

void calibratedDevelopment(const char* path, const char* database, float baselineEV) {
    Session session;
    if (database) {
        check(sony2fuji_session_set_lens_database(session.value,database) == SONY2FUJI_STATUS_OK,
              "Could not load the reference Lensfun database");
    }
    auto options = init<sony2fuji_hdr_decode_options_v1>();
    options.intent = SONY2FUJI_INTENT_PREVIEW;
    options.long_edge = 768;
    auto config = init<sony2fuji_hdr_camera_development_v1>();
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    auto decode = [&](Pair& pair) {
        auto status = sony2fuji_hdr_decode_camera_raw_with_development(session.value,path,&options,&config,&pair.value,&diagnostic);
        if (status != SONY2FUJI_STATUS_OK)
            throw std::runtime_error("Calibrated RAW decode failed: " + std::to_string(status) + "/" + std::to_string(diagnostic.reason));
    };
    Pair metadata, sensor, corrected;
    decode(metadata);
    config.exposure_reference = SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR;
    decode(sensor);
    const auto* original = static_cast<const float*>(metadata.value.hdr.data);
    const auto* unadjusted = static_cast<const float*>(sensor.value.hdr.data);
    const float scale = std::exp2(baselineEV);
    check(metadata.value.hdr.size_bytes == sensor.value.hdr.size_bytes &&
          std::equal(original, original + metadata.value.hdr.size_bytes / sizeof(float), unadjusted,
                     [&](float a, float b) { return std::abs(a - b * scale) <= 4e-6f * std::max(1.0f,std::abs(a)); }),
          "Exposure reference did not apply exactly the DNG baseline EV");
    std::cout << "PASS camera RAW exposure reference " << baselineEV << " EV\n";
    if (!database) return;
    config.lens_flags = SONY2FUJI_HDR_CAMERA_LENS_DISTORTION | SONY2FUJI_HDR_CAMERA_LENS_TCA | SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP;
    decode(corrected);
    check(corrected.value.hdr.width == sensor.value.hdr.width && corrected.value.hdr.height == sensor.value.hdr.height &&
          std::memcmp(corrected.value.hdr.data,sensor.value.hdr.data,sensor.value.hdr.size_bytes) != 0 &&
          std::memcmp(corrected.value.sdr.data,sensor.value.sdr.data,sensor.value.sdr.size_bytes) != 0,
          "Matched RAW optics did not change both planes at the same dimensions");
    std::cout << "PASS camera RAW sensor baseline and applied lens calibration\n";
}
}

static void calibratedAI(const char* input, const char* model, const std::string& producer) {
    TemporaryDirectory cache;
    const auto cachePath = cache.path.u8string();
    Session preparation, renderer;
    auto config = init<sony2fuji_ai_denoise_config>();
    config.enabled = 1;
    config.backend = producer == "CoreML" ? SONY2FUJI_AI_COREML : SONY2FUJI_AI_DIRECTML;
    config.model_directory = model;
    config.cache_directory = cachePath.c_str();
    check(sony2fuji_hdr_camera_ai_available() == 1, "requested HDR AI GPU is unavailable");
    for (auto session : {preparation.value, renderer.value})
        check(sony2fuji_session_set_ai_denoise(session, &config) == SONY2FUJI_STATUS_OK, "HDR AI configuration failed");

    auto options = init<sony2fuji_hdr_decode_options_v1>();
    options.intent = SONY2FUJI_INTENT_PREVIEW;
    options.long_edge = 1536;
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    Pair absent;
    auto decodeAI = [&](const char* file, Pair& result, const sony2fuji_hdr_camera_development_v1* development = nullptr) {
        return sony2fuji_hdr_decode_camera_raw_with_ai(renderer.value, file, &options, development, &result.value, &diagnostic);
    };
    check(decodeAI(input, absent) == SONY2FUJI_STATUS_AI_NOT_READY && !absent.value.owner_token,
          "HDR AI decode started inference or returned ordinary pixels before preparation");
    const auto fixture = std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
    check(sony2fuji_hdr_prepare_camera_raw_ai(preparation.value, fixture.c_str(), nullptr, nullptr, &diagnostic)
              == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_AI,
          "uncalibrated DNG used the HDR Bayer AI model");
    auto fbdd = init<sony2fuji_hdr_camera_development_v1>();
    fbdd.fbdd_level = 1;
    check(decodeAI(input, absent, &fbdd) == SONY2FUJI_STATUS_INVALID_ARGUMENT && !absent.value.owner_token,
          "HDR AI accepted simultaneous FBDD");
    check(sony2fuji_hdr_prepare_camera_raw_ai(preparation.value, input,
              [](void*, int32_t phase, uint64_t, uint64_t) -> int32_t { return phase != 2; }, nullptr, &diagnostic)
              == SONY2FUJI_STATUS_CANCELLED && std::filesystem::is_empty(cache.path), "cancelled HDR AI published a cache");
    check(sony2fuji_hdr_prepare_camera_raw_ai(preparation.value, input,
              [](void*, int32_t phase, uint64_t done, uint64_t) -> int32_t { return phase != 4 || done == 0; },
              nullptr, &diagnostic) == SONY2FUJI_STATUS_CANCELLED && std::filesystem::is_empty(cache.path) &&
              decodeAI(input, absent) == SONY2FUJI_STATUS_AI_NOT_READY,
          "HDR AI cancelled at the save boundary published a cache");
    struct ForeignHDRProgressException {};
    check(sony2fuji_hdr_prepare_camera_raw_ai(preparation.value, input,
              [](void*, int32_t, uint64_t, uint64_t) -> int32_t { throw ForeignHDRProgressException{}; },
              nullptr, &diagnostic) == SONY2FUJI_STATUS_PROCESSING_ERROR &&
              diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_AI &&
              sony2fuji_session_get_ai_error(preparation.value)[0] != '\0',
          "non-std::exception in HDR AI progress callback bypassed CAMERA_AI diagnostics");

    Pair ordinaryPreview;
    check(sony2fuji_hdr_decode_camera_raw(renderer.value, input, &options, &ordinaryPreview.value, &diagnostic)
              == SONY2FUJI_STATUS_OK, "ordinary preview was unavailable with a configured AI session");
    const auto start = Clock::now();
    const auto status = sony2fuji_hdr_prepare_camera_raw_ai(preparation.value, input, nullptr, nullptr, &diagnostic);
    if (status != SONY2FUJI_STATUS_OK)
        throw std::runtime_error(std::string("HDR Bayer AI preparation failed: ") + sony2fuji_session_get_ai_error(preparation.value));
    check(producer == sony2fuji_session_get_ai_backend(preparation.value), "HDR AI did not report the requested hardware producer");
    std::cout << "HDR Bayer AI preparation " << producer << ", " << elapsed(start) << " ms\n";
    check(sony2fuji_hdr_prepare_camera_raw_ai(preparation.value, input,
              [](void*, int32_t phase, uint64_t, uint64_t total) -> int32_t { return phase != 2 || total == 1; },
              nullptr, &diagnostic) == SONY2FUJI_STATUS_OK, "HDR Bayer AI did not reuse its prepared cache");

    Pair plainAgain, aiPreview;
    check(sony2fuji_hdr_decode_camera_raw(renderer.value, input, &options, &plainAgain.value, &diagnostic)
              == SONY2FUJI_STATUS_OK && plainAgain.value.hdr.size_bytes == ordinaryPreview.value.hdr.size_bytes &&
              std::memcmp(plainAgain.value.hdr.data, ordinaryPreview.value.hdr.data, ordinaryPreview.value.hdr.size_bytes) == 0,
          "prepared HDR AI altered the original decode entry point");
    check(decodeAI(input, aiPreview) == SONY2FUJI_STATUS_OK && aiPreview.value.is_proxy &&
          aiPreview.value.hdr.width == ordinaryPreview.value.hdr.width &&
          aiPreview.value.native_width == ordinaryPreview.value.native_width &&
          std::memcmp(aiPreview.value.source_sha256, ordinaryPreview.value.source_sha256, 32) == 0 &&
          producer == sony2fuji_session_get_ai_backend(renderer.value), "HDR AI preview could not reuse a prepared result from another session");

    options.intent = SONY2FUJI_INTENT_FINAL;
    options.long_edge = 0;
    Pair ordinary, processed;
    check(sony2fuji_hdr_decode_camera_raw(renderer.value, input, &options, &ordinary.value, &diagnostic) == SONY2FUJI_STATUS_OK &&
          decodeAI(input, processed) == SONY2FUJI_STATUS_OK, "full-size HDR development failed");
    check(processed.value.hdr.width == ordinary.value.hdr.width && processed.value.hdr.height == ordinary.value.hdr.height &&
          processed.value.source_headroom > 1 && processed.value.source_headroom == ordinary.value.source_headroom,
          "HDR AI changed native geometry or clipped the measured highlight range");
    std::vector<double> highlightDelta;
    size_t changed = 0;
    for (uint32_t y = 0; y < ordinary.value.hdr.height; y += 7) {
        const auto* a = reinterpret_cast<const float*>(static_cast<const uint8_t*>(ordinary.value.hdr.data) + y * ordinary.value.hdr.stride_bytes);
        const auto* b = reinterpret_cast<const float*>(static_cast<const uint8_t*>(processed.value.hdr.data) + y * processed.value.hdr.stride_bytes);
        for (uint32_t x = 0; x < ordinary.value.hdr.width; x += 7) {
            const auto offset = x * 3;
            const double before = .2126 * a[offset] + .7152 * a[offset + 1] + .0722 * a[offset + 2];
            const double after = .2126 * b[offset] + .7152 * b[offset + 1] + .0722 * b[offset + 2];
            if (std::max({a[offset], a[offset + 1], a[offset + 2]}) >= 1)
                check(std::memcmp(a + offset, b + offset, 3 * sizeof(float)) == 0, "HDR Bayer AI changed a super-white pixel");
            changed += std::abs(after - before) > 1e-5;
            if (before >= 1) highlightDelta.push_back(std::abs(std::log2(std::max(1e-6, after) / before)));
        }
    }
    check(changed > 100 && highlightDelta.size() > 100, "sample did not exercise denoised pixels and HDR highlights");
    auto p95 = highlightDelta.begin() + highlightDelta.size() * 95 / 100;
    std::nth_element(highlightDelta.begin(), p95, highlightDelta.end());
    std::cout << "HDR Bayer highlight P95 delta " << *p95 << " EV, peaks "
              << ordinary.value.source_headroom << " / " << processed.value.source_headroom << ", changed " << changed << '\n';
    check(*p95 == 0, "HDR Bayer AI changed highlight luminance");

    auto output = cache.path / "HDR AI.jpg";
    auto exportConfig = init<sony2fuji_hdr_export_config_v1>();
    exportConfig.base_color = SONY2FUJI_HDR_COLOR_SRGB;
    exportConfig.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
    exportConfig.jpeg_quality = 90;
    const auto outputPath = output.u8string();
    sony2fuji_hdr_release_pair(&ordinary.value);
    check(sony2fuji_hdr_export_jpeg(&processed.value, &exportConfig, outputPath.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
          "HDR Bayer AI final output could not export gain-map JPEG");
    sony2fuji_hdr_release_pair(&processed.value);
    auto info = init<sony2fuji_hdr_source_info_v1>();
    check(sony2fuji_hdr_probe(outputPath.c_str(), &info, &diagnostic) == SONY2FUJI_STATUS_OK &&
          info.protocol == SONY2FUJI_HDR_PROTOCOL_ISO_XMP, "HDR Bayer AI export could not be read back as gain-map JPEG");

    const auto rawCache = std::filesystem::directory_iterator(cache.path);
    std::filesystem::path artifact;
    for (const auto& entry : rawCache)
        if (entry.path() != output) {
            check(artifact.empty(), "HDR AI emitted extra artifacts");
            artifact = entry.path();
        }
    check(!artifact.empty(), "HDR Bayer AI cache artifact was missing");
    const auto backup = cache.path / "backup";
    std::filesystem::rename(artifact, backup);
    { std::ofstream corrupted(artifact); corrupted << "corrupt"; }
    options.intent = SONY2FUJI_INTENT_PREVIEW;
    options.long_edge = 1536;
    check(decodeAI(input, absent) == SONY2FUJI_STATUS_AI_NOT_READY && !absent.value.owner_token,
          "HDR AI accepted a corrupt cache");
    std::filesystem::remove(artifact);
    std::filesystem::rename(backup, artifact);
    check(decodeAI(input, absent) == SONY2FUJI_STATUS_OK, "HDR AI failed to recover after restoring a valid result");
    std::cout << "PASS calibrated HDR Bayer GPU, cache recovery, native geometry, highlights and JPEG readback\n";
}

static void unavailableDirectML(const char* model) {
    const auto fixture = std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
    TemporaryDirectory cache;
    const auto cachePath = cache.path.u8string();
    Session session;
    auto config = init<sony2fuji_ai_denoise_config>();
    config.enabled = 1;
    config.backend = SONY2FUJI_AI_DIRECTML;
    config.model_directory = model;
    config.cache_directory = cachePath.c_str();
    check(sony2fuji_session_set_ai_denoise(session.value, &config) == SONY2FUJI_STATUS_OK,
          "could not configure the DirectML model");
    check(sony2fuji_hdr_camera_ai_available() == 0, "this check requires an environment without a hardware GPU");
    auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
    auto unavailable = [&](sony2fuji_status status) {
        return status == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_AI &&
            diagnostic.field == SONY2FUJI_HDR_FIELD_SESSION;
    };
    check(unavailable(sony2fuji_hdr_prepare_camera_raw_ai(session.value, fixture.c_str(), nullptr, nullptr, &diagnostic)),
          "HDR AI preparation failed to reject the unavailable GPU");
    auto options = init<sony2fuji_hdr_decode_options_v1>();
    options.intent = SONY2FUJI_INTENT_PREVIEW;
    options.long_edge = 64;
    Pair preview;
    check(unavailable(sony2fuji_hdr_decode_camera_raw_with_ai(session.value, fixture.c_str(), &options,
          nullptr, &preview.value, &diagnostic)) && !preview.value.owner_token && std::filesystem::is_empty(cache.path),
          "unavailable HDR AI published pixels or a cache");
    check(sony2fuji_hdr_decode_camera_raw(session.value, fixture.c_str(), &options, &preview.value, &diagnostic) ==
          SONY2FUJI_STATUS_OK && sony2fuji_session_get_last_backend(session.value) == SONY2FUJI_BACKEND_CPU,
          "ordinary HDR RAW failed after the DirectML rejection");
    std::cout << "PASS HDR DirectML unavailable, no HDR AI output/cache, ordinary CPU decode passed\n";
}

int main(int argc, char** argv) {
    try {
        if (argc == 5 && std::string(argv[1]) == "--calibrated") {
            calibratedDevelopment(argv[2],std::string(argv[3]) == "-" ? nullptr : argv[3],std::stof(argv[4]));
            return 0;
        }
        if (argc == 5 && std::string(argv[1]) == "--ai") {
            calibratedAI(argv[2], argv[3], argv[4]);
            return 0;
        }
        if (argc == 3 && std::string(argv[1]) == "--ai-unavailable") {
            unavailableDirectML(argv[2]);
            return 0;
        }
        const auto fixture = std::string(TEST_FIXTURE_DIR) + "/bayer-demosaic.dng";
        unavailableTemperatureWB(fixture);
        const auto* external = std::getenv("RAWLAB_TEST_CAMERA_HDR");
        const auto* input = external ? external : fixture.c_str();
        auto info = init<sony2fuji_hdr_source_info_v1>();
        auto diagnostic = init<sony2fuji_hdr_diagnostic_v1>();
        check(sony2fuji_hdr_probe_camera_raw(input, &info, &diagnostic) == SONY2FUJI_STATUS_OK,
              "validated Bayer RAW was rejected");
        check(info.container == SONY2FUJI_HDR_CONTAINER_CAMERA_RAW && info.width > 32 && info.height > 32,
              "RAW probe did not describe the native source");
        auto options = init<sony2fuji_hdr_decode_options_v1>();
        options.intent = SONY2FUJI_INTENT_PREVIEW;
        options.long_edge = external ? 1536 : 32;
        Session session;
        Pair preview;
        check(sony2fuji_hdr_prepare_camera_raw_ai(session.value, input, nullptr, nullptr, &diagnostic)
                  == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_AI,
              "unconfigured HDR AI preparation was accepted");
        check(sony2fuji_hdr_decode_camera_raw_with_ai(session.value, input, &options, nullptr, &preview.value, &diagnostic)
                  == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_AI &&
                  !preview.value.owner_token, "explicit HDR AI decoded without a configured GPU session");
        if (sony2fuji_hdr_camera_ai_available()) {
            Session aiSession;
            sony2fuji_ai_denoise_config aiConfig{};
            aiConfig.version = SONY2FUJI_AI_DENOISE_CONFIG_VERSION;
            aiConfig.struct_size = sizeof(aiConfig);
            aiConfig.enabled = 1;
#ifdef _WIN32
            aiConfig.backend = SONY2FUJI_AI_DIRECTML;
#else
            aiConfig.backend = SONY2FUJI_AI_COREML;
#endif
            aiConfig.model_directory = TEST_FIXTURE_DIR;
            aiConfig.cache_directory = TEST_FIXTURE_DIR;
            check(sony2fuji_session_set_ai_denoise(aiSession.value, &aiConfig) == SONY2FUJI_STATUS_OK,
                  "could not configure AI session for HDR callback exception check");
            struct ForeignHDRCallbackException {};
            check(sony2fuji_hdr_prepare_camera_raw_ai(aiSession.value, input,
                      [](void*, int32_t, uint64_t, uint64_t) -> int32_t { throw ForeignHDRCallbackException{}; },
                      nullptr, &diagnostic) == SONY2FUJI_STATUS_PROCESSING_ERROR &&
                      diagnostic.reason == SONY2FUJI_HDR_REASON_CAMERA_AI &&
                      sony2fuji_session_get_ai_error(aiSession.value)[0] != '\0',
                  "non-std::exception in HDR AI progress callback bypassed CAMERA_AI diagnostics");
        }
        sony2fuji_session_set_cancellation_callback(session.value, [](void*) -> int32_t { return 1; }, nullptr);
        check(sony2fuji_hdr_decode_camera_raw(session.value, input, &options, &preview.value, &diagnostic)
                  == SONY2FUJI_STATUS_CANCELLED && !preview.value.owner_token, "cancelled RAW decode published pixels");
        sony2fuji_session_set_cancellation_callback(session.value, nullptr, nullptr);
        auto gpu = init<sony2fuji_gpu_config>();
        gpu.mode = SONY2FUJI_GPU_FORCE;
        check(sony2fuji_session_set_gpu_config(session.value, &gpu) == SONY2FUJI_STATUS_OK,
              "could not configure GPU Force");
        check(sony2fuji_hdr_decode_camera_raw(session.value, input, &options, &preview.value, &diagnostic)
                  == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU,
              "camera RAW HDR silently fell back in GPU Force mode");
        gpu.mode = SONY2FUJI_GPU_AUTO;
        check(sony2fuji_session_set_gpu_config(session.value, &gpu) == SONY2FUJI_STATUS_OK,
              "could not configure GPU Auto");
        auto start = Clock::now();
        check(sony2fuji_hdr_decode_camera_raw(session.value, input, &options, &preview.value, &diagnostic)
                  == SONY2FUJI_STATUS_OK && sony2fuji_session_get_last_backend(session.value) == SONY2FUJI_BACKEND_CPU,
              "RAW preview failed to report its CPU fallback");
        check(std::max(preview.value.hdr.width, preview.value.hdr.height) == options.long_edge && preview.value.is_proxy &&
              preview.value.native_width == info.width && preview.value.native_height == info.height &&
              preview.value.source_headroom_kind == SONY2FUJI_HDR_HEADROOM_UNKNOWN,
              "RAW preview lost native dimensions or claimed full-source measurements");
        const auto previewMs = elapsed(start);
        if (external && std::getenv("RAWLAB_TEST_CAMERA_HDR_PREVIEW_ONLY")) {
            std::cout << "RAW preview " << preview.value.hdr.width << 'x' << preview.value.hdr.height
                      << ", " << previewMs << " ms\n";
            return 0;
        }
        auto request = init<sony2fuji_hdr_request_v1>();
        request.hdr_processing_version = 1;
        request.intent = SONY2FUJI_INTENT_FINAL;
        request.temperature = 6500;
        request.crop_width = request.crop_height = 1;
        Pair rendered;
        check(sony2fuji_hdr_render(session.value, &preview.value, &request, &rendered.value, &diagnostic)
                  == SONY2FUJI_STATUS_INVALID_ARGUMENT && diagnostic.reason == SONY2FUJI_HDR_REASON_PREVIEW_SOURCE,
              "RAW preview was accepted for FINAL rendering");
        std::array<uint8_t, 32> previewIdentity{};
        std::copy_n(preview.value.source_sha256, previewIdentity.size(), previewIdentity.begin());
        sony2fuji_hdr_release_pair(&preview.value);

        options.intent = SONY2FUJI_INTENT_FINAL;
        options.long_edge = 0;
        Pair source;
        start = Clock::now();
        check(sony2fuji_hdr_decode_camera_raw(nullptr, input, &options, &source.value, &diagnostic)
                  == SONY2FUJI_STATUS_OK, "full RAW HDR decode failed");
        check(source.value.hdr.width == info.width && source.value.hdr.height == info.height,
              "full RAW decode lost native dimensions");
        check(external || source.value.source_headroom > 1.05f, "full RAW decode lost the synthetic highlight steps");
        check(std::any_of(previewIdentity.begin(), previewIdentity.end(), [](uint8_t x) { return x != 0; }) &&
              std::equal(previewIdentity.begin(), previewIdentity.end(), source.value.source_sha256),
              "RAW preview and FINAL disagree on original source identity");
        const auto finalMs = elapsed(start);
        if (!external) cameraDevelopment(input, source.value);
        const auto* sdr = static_cast<const float*>(source.value.sdr.data);
        check(std::all_of(sdr, sdr + source.value.sdr.size_bytes / sizeof(float),
                          [](float x) { return x >= 0 && x <= 1; }), "SDR base exceeded its output gamut");
        const float headroom = source.value.source_headroom;
        request.exposure_ev = external ? 2 : -1;
        rendered.value = init<sony2fuji_hdr_image_pair_v1>();
        start = Clock::now();
        check(sony2fuji_hdr_render(session.value, &source.value, &request, &rendered.value, &diagnostic)
                  == SONY2FUJI_STATUS_OK, "RAW HDR edit failed");
        if (external) {
            const auto* before = static_cast<const float*>(source.value.hdr.data);
            const auto* after = static_cast<const float*>(rendered.value.hdr.data);
            check(std::equal(before, before + source.value.hdr.size_bytes / sizeof(float), after,
                             [](float a, float b) { return b == 4 * a; }),
                  "RAW edit changed the color ratios or clipped before export");
        } else {
            check(std::abs(rendered.value.hdr.content_headroom - std::max(1.0f, headroom / 2)) < 1e-5f,
                  "user exposure did not move recovered high values by one stop");
        }
        const auto renderMs = elapsed(start);
        auto& exportPair = external ? rendered.value : source.value;
        sony2fuji_hdr_release_pair(external ? &source.value : &rendered.value);
        TemporaryDirectory directory;
        const auto jpeg = (directory.path / "raw-hdr.jpg").u8string();
        auto config = init<sony2fuji_hdr_export_config_v1>();
        config.jpeg_quality = 92;
        config.base_color = SONY2FUJI_HDR_COLOR_SRGB;
        config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
        start = Clock::now();
        check(sony2fuji_hdr_export_jpeg(&exportPair, &config, jpeg.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
              "RAW HDR gain-map export failed");
        const auto exportMs = elapsed(start);
        if (!external) {
            const auto heif = (directory.path / "raw-hdr.heic").u8string();
            auto heifConfig = config;
            heifConfig.metadata_policy = SONY2FUJI_HDR_METADATA_ISO;
            if (sony2fuji_hdr_heif_export_available()) {
                const auto status = sony2fuji_hdr_export_heif(&exportPair,&heifConfig,heif.c_str(),&diagnostic);
                if (status != SONY2FUJI_STATUS_OK)
                    throw std::runtime_error("HDR HEIF export failed: " + std::to_string(status) + "/" + std::to_string(diagnostic.reason));
                auto heifInfo = init<sony2fuji_hdr_source_info_v1>();
                check(sony2fuji_hdr_probe(heif.c_str(),&heifInfo,&diagnostic) == SONY2FUJI_STATUS_OK &&
                    heifInfo.container == SONY2FUJI_HDR_CONTAINER_HEIF && heifInfo.protocol == SONY2FUJI_HDR_PROTOCOL_ISO &&
                    heifInfo.orientation == 1 && heifInfo.width == exportPair.hdr.width && heifInfo.height == exportPair.hdr.height &&
                    heifInfo.content_headroom > 1 && heifInfo.color_description == SONY2FUJI_HDR_COLOR_SRGB,
                    "HDR HEIF lost its color, orientation, headroom or ISO gain map");
                Pair decoded;
                check(sony2fuji_hdr_decode(heif.c_str(),&options,&decoded.value,&diagnostic) == SONY2FUJI_STATUS_OK &&
                    decoded.value.hdr.width == heifInfo.width && decoded.value.sdr.width == heifInfo.width,
                    "HDR HEIF did not decode into both renditions");
                verifyHEIFRenditions(exportPair,decoded.value);
                const auto bytes = [&] {
                    std::ifstream stream(heif,std::ios::binary);
                    return std::vector<char>(std::istreambuf_iterator<char>(stream),{});
                };
                const auto previous = bytes();
                check(sony2fuji_hdr_export_heif(&exportPair,&config,heif.c_str(),&diagnostic) == SONY2FUJI_STATUS_INVALID_ARGUMENT &&
                    !previous.empty() && bytes() == previous,
                    "Invalid HEIF metadata policy replaced an existing output");
                if (const auto* accepted = std::getenv("RAWLAB_TEST_HDR_HEIF_OUTPUT"))
                    std::filesystem::copy_file(std::filesystem::u8path(heif),std::filesystem::u8path(accepted));
                Pair dark;
                request.exposure_ev = -4;
                check(sony2fuji_hdr_render(session.value,&exportPair,&request,&dark.value,&diagnostic) == SONY2FUJI_STATUS_OK &&
                    dark.value.hdr.content_headroom == 1, "Could not construct a below-white HDR edit");
                const auto darkPath = (directory.path / "below-white.heic").u8string();
                auto borrowedDark = dark.value;
                borrowedDark.owner_token = 0;
                const auto darkStatus = sony2fuji_hdr_export_heif(&borrowedDark,&heifConfig,darkPath.c_str(),&diagnostic);
                if (darkStatus != SONY2FUJI_STATUS_OK)
                    throw std::runtime_error("Below-white HDR HEIF export failed: " + std::to_string(darkStatus) + "/" + std::to_string(diagnostic.reason));
                Pair darkDecoded;
                check(sony2fuji_hdr_decode(darkPath.c_str(),&options,&darkDecoded.value,&diagnostic) == SONY2FUJI_STATUS_OK,
                      "Below-white HEIF did not decode into both renditions");
                verifyHEIFRenditions(dark.value,darkDecoded.value);
            } else {
                check(sony2fuji_hdr_export_heif(&exportPair,&heifConfig,heif.c_str(),&diagnostic) == SONY2FUJI_STATUS_UNSUPPORTED &&
                    !std::filesystem::exists(heif), "An unavailable HEIF encoder wrote a file");
            }
            const auto sdrPath = (directory.path / "raw-sdr.jpg").u8string();
            auto sdrConfig = init<sony2fuji_hdr_sdr_export_config_v1>();
            sdrConfig.output_format = SONY2FUJI_OUTPUT_JPEG;
            sdrConfig.quality = 92;
            check(sony2fuji_hdr_export_sdr(&exportPair, &sdrConfig, sdrPath.c_str(), &diagnostic) == SONY2FUJI_STATUS_OK,
                  "RAW HDR SDR-compatible export failed");
            auto sdrInfo = init<sony2fuji_hdr_source_info_v1>();
            check(sony2fuji_hdr_probe_camera_raw(sdrPath.c_str(), &sdrInfo, &diagnostic) == SONY2FUJI_STATUS_UNSUPPORTED &&
                  diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW,
                  "ordinary JPEG was accepted as a camera RAW source");
        }
        sony2fuji_hdr_release_pair(&exportPair);
        Pair reimport;
        check(sony2fuji_hdr_decode(jpeg.c_str(), &options, &reimport.value, &diagnostic) == SONY2FUJI_STATUS_OK &&
              reimport.value.hdr.width == info.width && reimport.value.hdr.height == info.height &&
              reimport.value.hdr.content_headroom > 1.0f,
              "gain-map JPEG round trip lost native dimensions or HDR highlights");
        std::cout << "RAW " << info.width << "x" << info.height << ", source headroom " << headroom
                  << ", JPEG headroom " << reimport.value.hdr.content_headroom
                  << ", ms preview/final/edit/export " << previewMs << '/' << finalMs << '/'
                  << renderMs << '/' << exportMs << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
