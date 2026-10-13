#include "core/rendered_dng.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#ifdef TEST_LENS_WAVELET_DNG
#include "core/wavelet_cache.h"
#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_STATIC
#define STBI_ONLY_JPEG
#define STBI_ONLY_PNG
#include "core/stb_image.h"
#endif

#include <tiffio.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <fstream>
#include <filesystem>
#include <iostream>
#include <iterator>
#include <limits>
#include <string>
#include <memory>
#include <vector>

#ifndef _WIN32
#include <csignal>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

namespace {

constexpr uint16_t kLinearRaw = 34892;
constexpr const char* kStagingMarker = ".rawlab-rendered-dng-";

int failures = 0;

void check(bool condition, const std::string& name) {
    std::cout << (condition ? "PASS " : "FAIL ") << name << '\n';
    if (!condition) ++failures;
}

constexpr TIFFFieldInfo kCustomFields[] = {
    {TIFFTAG_COLORIMETRICREFERENCE, 1, 1, TIFF_SHORT, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("ColorimetricReference")},
    {TIFFTAG_PROFILENAME, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_ASCII, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("ProfileName")},
    {TIFFTAG_PROFILETONECURVE, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_FLOAT, FIELD_CUSTOM, 1, 1,
     const_cast<char*>("ProfileToneCurve")},
    {TIFFTAG_FORWARDMATRIX1, TIFF_VARIABLE, TIFF_VARIABLE, TIFF_SRATIONAL, FIELD_CUSTOM, 1, 1,
     const_cast<char*>("ForwardMatrix1")},
    {TIFFTAG_BASELINEEXPOSUREOFFSET, 1, 1, TIFF_SRATIONAL, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("BaselineExposureOffset")},
    {TIFFTAG_DEFAULTBLACKRENDER, 1, 1, TIFF_LONG, FIELD_CUSTOM, 1, 0,
     const_cast<char*>("DefaultBlackRender")},
};

bool registerCustomFields(TIFF* tif) {
    return TIFFMergeFieldInfo(tif, kCustomFields,
                              static_cast<uint32_t>(std::size(kCustomFields))) == 0;
}

TIFFExtendProc previousTagExtender = nullptr;

void registerCustomFieldsBeforeRead(TIFF* tif) {
    if (previousTagExtender) previousTagExtender(tif);
    TIFFMergeFieldInfo(tif, kCustomFields,
                       static_cast<uint32_t>(std::size(kCustomFields)));
}

float inverseSrgb(float encoded) {
    const double value = std::clamp(static_cast<double>(encoded), 0.0, 1.0);
    return static_cast<float>(value <= 0.04045
        ? value / 12.92
        : std::pow((value + 0.055) / 1.055, 2.4));
}

std::filesystem::path testDirectory() {
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    const auto directory = std::filesystem::temp_directory_path() /
        ("rawtools-rendered-dng-" + std::to_string(stamp));
    std::filesystem::create_directories(directory);
    return directory;
}

bool samePixels(const sony2fuji::ImageData& left, const sony2fuji::ImageData& right) {
    if (left.width != right.width || left.height != right.height ||
        left.pixels.size() != right.pixels.size()) return false;
    for (size_t i = 0; i < left.pixels.size(); ++i) {
        if (left.pixels[i].r != right.pixels[i].r ||
            left.pixels[i].g != right.pixels[i].g ||
            left.pixels[i].b != right.pixels[i].b) return false;
    }
    return true;
}

std::string readFile(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}

void writeFile(const std::filesystem::path& path, const std::string& contents) {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(contents.data(), static_cast<std::streamsize>(contents.size()));
}

bool hasStagingFile(const std::filesystem::path& directory) {
    for (const auto& entry : std::filesystem::directory_iterator(directory)) {
#ifdef _WIN32
        const auto filename = entry.path().filename().string();
        if (filename.rfind("rld", 0) == 0 && entry.path().extension() == ".tmp")
#else
        if (entry.path().filename().string().find(kStagingMarker) != std::string::npos)
#endif
            return true;
    }
    return false;
}

sony2fuji::ImageData smallImage() {
    using sony2fuji::ImageData;
    using sony2fuji::RGB;
    ImageData image(2, 2);
    image.pixels = {
        RGB(0.1f, 0.2f, 0.3f), RGB(0.4f, 0.5f, 0.6f),
        RGB(0.7f, 0.8f, 0.9f), RGB(1.0f, 0.0f, 0.5f),
    };
    return image;
}

void testRenderedDng(const std::filesystem::path& directory) {
    using sony2fuji::ErrorCode;
    using sony2fuji::ImageData;
    using sony2fuji::RGB;

    ImageData image(4, 2);
    image.pixels = {
        RGB(0, 0.5f, 1), RGB(-0.25f, 0.04045f, 1.25f),
        RGB(0.0031308f, 0.18f, 0.9f), RGB(0.25f, 0.75f, 0.5f),
        RGB(1, 0, 0.5f), RGB(0.1f, 0.2f, 0.3f),
        RGB(0.8f, 0.6f, 0.4f), RGB(0.01f, 0.02f, 0.03f),
    };
    const ImageData original = image;
    const auto output = directory / "rendered.dng";
    check(sony2fuji::saveRenderedDNG(image, output.string()) == ErrorCode::Success,
          "rendered DNG writes synthetic final sRGB image");
    check(samePixels(image, original), "rendered DNG does not mutate source pixels");

    previousTagExtender = TIFFSetTagExtender(registerCustomFieldsBeforeRead);
    TIFF* tif = TIFFOpen(output.string().c_str(), "r");
    TIFFSetTagExtender(previousTagExtender);
    previousTagExtender = nullptr;
    check(tif != nullptr, "libtiff independently opens rendered DNG");
    if (!tif) return;
    check(TIFFFindField(tif, TIFFTAG_COLORIMETRICREFERENCE, TIFF_ANY) != nullptr,
          "libtiff registers DNG 1.2/1.4 fields independently");

    uint32_t width = 0, height = 0;
    uint16_t bits = 0, samples = 0, photometric = 0, orientation = 0;
    uint16_t planar = 0, sampleFormat = 0;
    check(TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &width) && width == 4,
          "DNG width is exact");
    check(TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &height) && height == 2,
          "DNG height is exact");
    check(TIFFGetField(tif, TIFFTAG_BITSPERSAMPLE, &bits) && bits == 32,
          "DNG stores float32 samples");
    check(TIFFGetField(tif, TIFFTAG_SAMPLESPERPIXEL, &samples) && samples == 3,
          "DNG stores three channels");
    check(TIFFGetField(tif, TIFFTAG_PHOTOMETRIC, &photometric) && photometric == kLinearRaw,
          "DNG uses LinearRaw photometric interpretation");
    check(TIFFGetField(tif, TIFFTAG_ORIENTATION, &orientation) && orientation == ORIENTATION_TOPLEFT,
          "DNG orientation is top-left");
    check(TIFFGetField(tif, TIFFTAG_PLANARCONFIG, &planar) && planar == PLANARCONFIG_CONTIG,
          "DNG stores contiguous RGB samples");
    check(TIFFGetField(tif, TIFFTAG_SAMPLEFORMAT, &sampleFormat) && sampleFormat == SAMPLEFORMAT_IEEEFP,
          "DNG sample format is IEEE floating point");
    uint16_t extraCount = 0;
    uint16_t* extraTypes = nullptr;
    check(!TIFFGetField(tif, TIFFTAG_EXTRASAMPLES, &extraCount, &extraTypes),
          "DNG has no ExtraSamples tag");

    uint16_t colorimetricReference = 0;
    check(TIFFGetField(tif, TIFFTAG_COLORIMETRICREFERENCE, &colorimetricReference) &&
          colorimetricReference == 1, "DNG ColorimetricReference is ICC PCS");
    char* profileName = nullptr;
    check(TIFFGetField(tif, TIFFTAG_PROFILENAME, &profileName) && profileName &&
          std::string(profileName) == "RawLab Baked sRGB", "DNG profile name is neutral");
    uint16_t toneCount = 0;
    const float* toneCurve = nullptr;
    check(TIFFGetField(tif, TIFFTAG_PROFILETONECURVE, &toneCount, &toneCurve) &&
          toneCount == 4 && toneCurve && toneCurve[0] == 0 && toneCurve[1] == 0 &&
          toneCurve[2] == 1 && toneCurve[3] == 1, "DNG profile tone curve is identity");
    uint16_t forwardCount = 0;
    const float* forwardMatrix = nullptr;
    check(TIFFGetField(tif, TIFFTAG_FORWARDMATRIX1, &forwardCount, &forwardMatrix) &&
          forwardCount == 9 && forwardMatrix &&
          std::abs(forwardMatrix[0] - 0.43606575f) < 1e-5f &&
          std::abs(forwardMatrix[8] - 0.71409936f) < 1e-5f,
          "DNG forward matrix is the virtual linear-sRGB D50 matrix");
    float baselineOffset = 99;
    uint32_t defaultBlackRender = 0;
    check(TIFFGetField(tif, TIFFTAG_BASELINEEXPOSUREOFFSET, &baselineOffset) &&
          baselineOffset == 0, "DNG baseline exposure offset is zero");
    check(TIFFGetField(tif, TIFFTAG_DEFAULTBLACKRENDER, &defaultBlackRender) &&
          defaultBlackRender == 1, "DNG DefaultBlackRender is None");

    uint32_t xmpCount = 0;
    const void* xmpData = nullptr;
    check(TIFFGetField(tif, TIFFTAG_XMLPACKET, &xmpCount, &xmpData) && xmpData &&
          std::string(static_cast<const char*>(xmpData), xmpCount).find(
              "crs:Sharpness=\"0\"") != std::string::npos,
          "DNG contains neutral Adobe XMP");

    bool pixelsMatch = true;
    std::vector<float> row(static_cast<size_t>(width) * 3);
    for (uint32_t y = 0; y < height && pixelsMatch; ++y) {
        if (TIFFReadScanline(tif, row.data(), y, 0) < 0) {
            pixelsMatch = false;
            break;
        }
        for (uint32_t x = 0; x < width; ++x) {
            const auto& source = original.at(static_cast<int>(x), static_cast<int>(y));
            const size_t offset = static_cast<size_t>(x) * 3;
            pixelsMatch = std::abs(row[offset] - inverseSrgb(source.r)) < 1e-6f &&
                std::abs(row[offset + 1] - inverseSrgb(source.g)) < 1e-6f &&
                std::abs(row[offset + 2] - inverseSrgb(source.b)) < 1e-6f;
            if (!pixelsMatch) break;
        }
    }
    check(pixelsMatch, "DNG float pixels inverse-decode clamped sRGB exactly");
    TIFFClose(tif);
}

void testRejectsInvalidInput(const std::filesystem::path& directory) {
    using sony2fuji::ErrorCode;
    using sony2fuji::ImageData;
    using sony2fuji::RGB;
    const auto output = directory / "invalid.dng";

    ImageData empty;
    check(sony2fuji::saveRenderedDNG(empty, output.string()) == ErrorCode::ProcessingError,
          "DNG rejects empty dimensions");
    ImageData mismatched(2, 2);
    mismatched.pixels.pop_back();
    check(sony2fuji::saveRenderedDNG(mismatched, output.string()) == ErrorCode::ProcessingError,
          "DNG rejects mismatched pixel count");
    ImageData nonfinite(1, 1);
    nonfinite.pixels[0] = RGB(std::numeric_limits<float>::quiet_NaN(), 0, 0);
    check(sony2fuji::saveRenderedDNG(nonfinite, output.string()) == ErrorCode::ProcessingError,
          "DNG rejects NaN pixels");
    nonfinite.pixels[0] = RGB(0, std::numeric_limits<float>::infinity(), 0);
    check(sony2fuji::saveRenderedDNG(nonfinite, output.string()) == ErrorCode::ProcessingError,
          "DNG rejects infinite pixels");
    ImageData valid(1, 1);
    check(sony2fuji::saveRenderedDNG(valid, (directory / "missing" / "out.dng").string()) ==
              ErrorCode::IOError,
          "DNG reports an unwritable output path");
    check(!std::filesystem::exists(output), "invalid DNG inputs do not create output");
}

#ifdef TEST_LENS_SDK_DNG
void testLensSdkDng(const std::filesystem::path& directory) {
    const auto fixtures = std::filesystem::path(TEST_SOURCE_DIR) / "tests/fixtures";
    sony2fuji_session* session = nullptr;
    check(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK,
          "Lens/SDK/DNG combination creates a C session");
    if (!session) return;
    sony2fuji_lens_correction_config lens{
        SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION, sizeof(lens), 1, 1, 1, nullptr};
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    check(sony2fuji_session_set_lens_database(session, (fixtures / "lenses.xml").string().c_str()) == SONY2FUJI_STATUS_OK &&
          sony2fuji_session_set_lens_correction(session, &lens) == SONY2FUJI_STATUS_OK &&
          sony2fuji_session_set_gpu_config(session, &gpu) == SONY2FUJI_STATUS_OK,
          "Lens/SDK/DNG combination configures real profiles and CPU");

    for (const auto* name : {"linear-jxl-stage3-lens.dng", "linear-jxl-lens.dng"}) {
        const auto input = (fixtures / name).string();
        const auto output = (directory / name).string();
        const bool stage3 = std::string(name).find("stage3") != std::string::npos;
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = input.c_str();
        request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
        request.size_mode = SONY2FUJI_SIZE_NATIVE; request.intent = SONY2FUJI_INTENT_FINAL;
        request.brightness = request.contrast = request.saturation = 1;
        sony2fuji_buffer buffer{};
        bool valid = sony2fuji_process(session, &request, &buffer) == SONY2FUJI_STATUS_OK && buffer.data;
        request.output_target = SONY2FUJI_TARGET_FILE; request.output_format = SONY2FUJI_OUTPUT_DNG;
        request.output_path = output.c_str();
        valid = sony2fuji_process(session, &request, nullptr) == SONY2FUJI_STATUS_OK && valid;
        sony2fuji_lens_report report{};
        valid = sony2fuji_session_get_lens_report(session, &report) == SONY2FUJI_STATUS_OK && valid;
        valid = (stage3 ? report.state == SONY2FUJI_LENS_EMBEDDED_GEOMETRY && !report.applied_distortion && !report.applied_tca
                        : report.state == SONY2FUJI_LENS_MATCHED && report.applied_distortion && report.applied_tca) && valid;

        TIFF* tif = TIFFOpen(output.c_str(), "r");
        uint32_t width = 0, height = 0;
        uint16_t bits = 0, samples = 0, format = 0;
        valid = tif && valid;
        if (tif) {
            valid = TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &width) && width == buffer.width &&
                TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &height) && height == buffer.height &&
                TIFFGetField(tif, TIFFTAG_BITSPERSAMPLE, &bits) && bits == 32 &&
                TIFFGetField(tif, TIFFTAG_SAMPLESPERPIXEL, &samples) && samples == 3 &&
                TIFFGetField(tif, TIFFTAG_SAMPLEFORMAT, &format) && format == SAMPLEFORMAT_IEEEFP && valid;
            std::vector<float> row(static_cast<size_t>(width) * 3);
            double maximumError = 0;
            for (uint32_t y = 0; y < height && valid; ++y) {
                valid = TIFFReadScanline(tif, row.data(), y, 0) >= 0;
                if (!valid) break;
                const auto* expected = static_cast<const uint8_t*>(buffer.data) + y * buffer.stride_bytes;
                for (size_t x = 0; x < row.size(); ++x) {
                    const double linear = row[x];
                    if (!std::isfinite(linear) || linear < 0 || linear > 1) { valid = false; break; }
                    const double encoded = linear <= .0031308 ? 12.92 * linear : 1.055 * std::pow(linear, 1.0 / 2.4) - .055;
                    maximumError = std::max(maximumError, std::abs(encoded * 255 - expected[x]));
                }
            }
            valid = maximumError <= 1.0 && valid;
            std::cout << "Lens/SDK/DNG " << name << " maximum RGB8 error=" << maximumError << '\n';
            TIFFClose(tif);
        }
        check(valid, std::string(name) + ": FINAL DNG pixels and post-file Lens state match the buffer");
        sony2fuji_release_buffer(&buffer);
    }
    sony2fuji_session_destroy(session);
}
#endif

#ifdef TEST_LENS_WAVELET_DNG
bool sameFiles(const std::filesystem::path& left, const std::filesystem::path& right) {
    std::ifstream a(left, std::ios::binary), b(right, std::ios::binary);
    if (!a || !b || std::filesystem::file_size(left) != std::filesystem::file_size(right)) return false;
    std::array<char, 65536> x{}, y{};
    while (a) {
        a.read(x.data(), x.size()); b.read(y.data(), y.size());
        if (a.gcount() != b.gcount() || !std::equal(x.begin(), x.begin() + a.gcount(), y.begin())) return false;
    }
    return a.eof() && b.eof();
}

void testLensWaveletViewportDng(const std::filesystem::path& directory, const std::string& input) {
    const auto database = std::filesystem::path(TEST_SOURCE_DIR) / "third_party/lensfun/version_1";
    using Session = std::unique_ptr<sony2fuji_session, decltype(&sony2fuji_session_destroy)>;
    sony2fuji_lens_correction_config lens{
        SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION, sizeof(lens), 1, 1, 1, nullptr};
    sony2fuji_wavelet_denoise_config wavelet{
        SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(wavelet), 1, 40, 46, 50};
    auto makeSession = [&]() {
        sony2fuji_session* raw = nullptr;
        check(sony2fuji_session_create(&raw) == SONY2FUJI_STATUS_OK, "Combined render creates a session");
        Session session(raw, sony2fuji_session_destroy);
        if (raw) {
            sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
            check(sony2fuji_session_set_lens_database(raw, database.string().c_str()) == SONY2FUJI_STATUS_OK &&
                  sony2fuji_session_set_lens_correction(raw, &lens) == SONY2FUJI_STATUS_OK &&
                  sony2fuji_session_set_gpu_config(raw, &gpu) == SONY2FUJI_STATUS_OK &&
                  sony2fuji_session_set_raw_exposure_mode(raw, SONY2FUJI_EXPOSURE_PREVIEW) == SONY2FUJI_STATUS_OK &&
                  sony2fuji_session_set_wavelet_denoise(raw, &wavelet) == SONY2FUJI_STATUS_OK,
                  "Combined render configures Lens, NR and preview exposure");
        }
        return session;
    };
    auto history = makeSession();
    if (!history) return;
    sony2fuji_lens_report inspected{};
    uint32_t count = 0;
    check(sony2fuji_session_inspect_lens(history.get(), input.c_str(), &inspected, nullptr, 0, &count) == SONY2FUJI_STATUS_OK,
          "Combined fixture has a Lens catalog");
    std::vector<sony2fuji_lens_profile> profiles(count);
    check(sony2fuji_session_inspect_lens(history.get(), input.c_str(), &inspected, profiles.data(), count, &count) == SONY2FUJI_STATUS_OK,
          "Combined fixture loads its Lens profiles");
    const auto selected = std::find_if(profiles.begin(), profiles.end(), [](const auto& profile) {
        return profile.is_match && profile.has_distortion && profile.has_tca;
    });
    check(selected != profiles.end(), "Combined RAW has matching distortion and TCA calibration");
    if (selected == profiles.end()) return;
    const std::string profileID = selected->id;
    lens.profile_id = profileID.c_str();
    check(sony2fuji_session_set_lens_correction(history.get(), &lens) == SONY2FUJI_STATUS_OK, "Combined render selects the matched profile");
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = input.c_str();
    request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE; request.intent = SONY2FUJI_INTENT_FINAL;
    request.brightness = request.contrast = request.saturation = 1; request.temperature = 6500;
    request.wb_mode = SONY2FUJI_WB_CAMERA; request.jpeg_quality = 95;
    uint32_t width = 0, height = 0;
    auto render = [&](sony2fuji_session* session) {
        sony2fuji_buffer buffer{};
        const auto status = sony2fuji_process(session, &request, &buffer);
        check(status == SONY2FUJI_STATUS_OK && buffer.data, "Combined C ABI buffer renders");
        std::vector<uint8_t> pixels;
        if (buffer.data) {
            width = buffer.width; height = buffer.height;
            const auto* data = static_cast<const uint8_t*>(buffer.data);
            pixels.assign(data, data + buffer.size_bytes);
        }
        sony2fuji_release_buffer(&buffer);
        return pixels;
    };
    auto report = [&](sony2fuji_session* session) {
        sony2fuji_lens_report result{};
        check(sony2fuji_session_get_lens_report(session, &result) == SONY2FUJI_STATUS_OK, "Combined render returns Lens report");
        return result;
    };
    auto baseline = [&](sony2fuji_session* session) {
        float value = 0, metadata = 0;
        check(sony2fuji_session_get_raw_exposure(session, &value, &metadata) == SONY2FUJI_STATUS_OK, "Combined render returns exposure anchor");
        return value;
    };
    wavelet.enabled = 0;
    sony2fuji_session_set_wavelet_denoise(history.get(), &wavelet);
    auto off = render(history.get());
    const auto nativeWidth = width, nativeHeight = height;
    wavelet.enabled = 1;
    sony2fuji_session_set_wavelet_denoise(history.get(), &wavelet);
    auto exact = render(history.get());
    check(!exact.empty() && exact != off, "Combined real RAW actually applies wavelet denoising");
    off.clear(); off.shrink_to_fit(); exact.clear(); exact.shrink_to_fit();
    const auto applied = report(history.get());
    check(applied.state == SONY2FUJI_LENS_MATCHED && applied.applied_distortion && applied.applied_tca && applied.crop_scale > 1,
          "Combined real RAW applies Lens distortion/TCA and automatic crop");
    sony2fuji_session_set_viewport_preview(history.get(), 1);
    request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 1600;
    const auto a = render(history.get());
    check(std::max(width, height) == 1600, "Combined viewport A is bounded");
    request.preview_long_edge = 1024; render(history.get());
    check(std::max(width, height) == 1024, "Combined viewport B is bounded");
    auto before = sony2fuji::waveletCacheDiagnostics(history.get());
    request.preview_long_edge = 1600;
    check(render(history.get()) == a, "Combined A/B/A restores viewport pixels");
    auto after = sony2fuji::waveletCacheDiagnostics(history.get());
    check(after.filterRuns == before.filterRuns && after.outputHits == before.outputHits + 1,
          "Combined A/B/A reuses denoised output");
    request.exposure_ev = .25f; request.contrast = 1.1f;
    render(history.get());
    check(sony2fuji::waveletCacheDiagnostics(history.get()).filterRuns == after.filterRuns,
          "Combined downstream edits do not repeat NR");
    request.wb_mode = SONY2FUJI_WB_TEMPERATURE; request.temperature = 7800;
    render(history.get());
    for (int phase = 0; phase < 3; ++phase) {
        lens.auto_crop = phase != 0; lens.profile_id = phase == 1 ? nullptr : profileID.c_str();
        before = sony2fuji::waveletCacheDiagnostics(history.get());
        check(sony2fuji_session_set_lens_correction(history.get(), &lens) == SONY2FUJI_STATUS_OK,
              "Combined render updates Lens profile/crop");
        const auto changed = render(history.get());
        after = sony2fuji::waveletCacheDiagnostics(history.get());
        check(after.filterRuns == before.filterRuns + 1 && after.analysisHits == before.analysisHits,
              "Lens profile/crop changes invalidate NR output and source analysis");
        auto fresh = makeSession();
        check(sony2fuji_session_set_viewport_preview(fresh.get(), 1) == SONY2FUJI_STATUS_OK,
              "Independent viewport uses the same reduced-input mode");
        const auto direct = render(fresh.get());
        const auto actualReport = report(history.get()), freshReport = report(fresh.get());
        const auto actualBaseline = baseline(history.get()), freshBaseline = baseline(fresh.get());
        check(changed == direct, "Lens/NR viewport pixels are independent of profile/crop history");
        check(actualBaseline == freshBaseline, "Lens/NR exposure anchor is independent of profile/crop history");
        check(actualReport.state == freshReport.state && actualReport.applied_distortion == freshReport.applied_distortion &&
              actualReport.applied_tca == freshReport.applied_tca && actualReport.crop_scale == freshReport.crop_scale,
              "Lens/NR report is independent of profile/crop history");
        if (phase != 1)
            check(actualReport.state == SONY2FUJI_LENS_MATCHED && actualReport.applied_distortion && actualReport.applied_tca &&
                  (phase == 0 ? actualReport.crop_scale == 1 : actualReport.crop_scale > 1),
                  "Manual Lens profile retains calibration and requested crop");
    }
    before = sony2fuji::waveletCacheDiagnostics(history.get());
    sony2fuji_session_set_lens_database(history.get(), database.string().c_str());
    render(history.get());
    after = sony2fuji::waveletCacheDiagnostics(history.get());
    check(after.filterRuns == before.filterRuns + 1 && after.analysisHits == before.analysisHits,
          "Lens database revision invalidates NR source identity");
    request.intent = SONY2FUJI_INTENT_FINAL; request.preview_long_edge = 0;
    sony2fuji_session_set_interactive_preview(history.get(), 1);
    exact = render(history.get());
    check(width == nativeWidth && height == nativeHeight, "Combined FINAL ignores both preview flags");
    const auto finalReport = report(history.get()); const auto finalBaseline = baseline(history.get());
    before = sony2fuji::waveletCacheDiagnostics(history.get());
    const std::array<sony2fuji_output_format, 3> formats{SONY2FUJI_OUTPUT_JPEG, SONY2FUJI_OUTPUT_PNG, SONY2FUJI_OUTPUT_DNG};
    const std::array<const char*, 3> suffixes{"jpg", "png", "dng"};
    auto exportFiles = [&](sony2fuji_session* session, const char* stem) {
        request.output_target = SONY2FUJI_TARGET_FILE;
        for (size_t i = 0; i < formats.size(); ++i) {
            const auto file = (directory / (std::string(stem) + "." + suffixes[i])).string();
            request.output_format = formats[i]; request.output_path = file.c_str();
            check(sony2fuji_process(session, &request, nullptr) == SONY2FUJI_STATUS_OK, "Combined native file exports " + std::string(suffixes[i]));
        }
        request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8; request.output_path = nullptr;
    };
    exportFiles(history.get(), "history");
    after = sony2fuji::waveletCacheDiagnostics(history.get());
    check(after.filterRuns == before.filterRuns && after.outputHits == before.outputHits + 3,
          "JPEG/PNG/DNG use native exact cache, never viewport pixels");
    history.reset();
    auto fresh = makeSession();
    check(render(fresh.get()) == exact && baseline(fresh.get()) == finalBaseline,
          "Combined native FINAL pixels and exposure equal independent exact");
    const auto freshReport = report(fresh.get());
    check(freshReport.state == SONY2FUJI_LENS_MATCHED && freshReport.applied_distortion && freshReport.applied_tca &&
          freshReport.crop_scale == finalReport.crop_scale, "Combined FINAL retains exact Lens crop/report");
    exportFiles(fresh.get(), "fresh");
    for (const auto* suffix : suffixes)
        check(sameFiles(directory / (std::string("history.") + suffix), directory / (std::string("fresh.") + suffix)),
              std::string(suffix) + ": combined native file equals independent FINAL bytes");
    const auto pngPath = (directory / "history.png").string();
    int decodedWidth = 0, decodedHeight = 0, channels = 0;
    auto* png = stbi_load_16(pngPath.c_str(), &decodedWidth, &decodedHeight, &channels, 3);
    bool validPng = png && stbi_is_16_bit(pngPath.c_str()) &&
        decodedWidth == static_cast<int>(nativeWidth) && decodedHeight == static_cast<int>(nativeHeight);
    double pngError = 0;
    if (validPng) {
        for (size_t i = 0; i < exact.size(); ++i)
            pngError = std::max(pngError, std::abs(png[i] / 257.0 - exact[i]));
    }
    stbi_image_free(png);
    check(validPng && pngError <= 1, "Combined native PNG has sixteen-bit samples matching independent exact pixels");
    const auto jpegPath = (directory / "history.jpg").string();
    auto* jpeg = stbi_load(jpegPath.c_str(), &decodedWidth, &decodedHeight, &channels, 3);
    check(jpeg && decodedWidth == static_cast<int>(nativeWidth) && decodedHeight == static_cast<int>(nativeHeight),
          "Combined JPEG decodes at original geometry");
    stbi_image_free(jpeg);
    TIFF* tif = TIFFOpen((directory / "history.dng").string().c_str(), "r");
    uint32_t dngWidth = 0, dngHeight = 0; uint16_t bits = 0, samples = 0, sampleFormat = 0;
    bool validDng = tif && TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &dngWidth) && TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &dngHeight) &&
        TIFFGetField(tif, TIFFTAG_BITSPERSAMPLE, &bits) && bits == 32 && dngWidth == nativeWidth && dngHeight == nativeHeight &&
        TIFFGetField(tif, TIFFTAG_SAMPLESPERPIXEL, &samples) && samples == 3 &&
        TIFFGetField(tif, TIFFTAG_SAMPLEFORMAT, &sampleFormat) && sampleFormat == SAMPLEFORMAT_IEEEFP;
    double dngError = 0;
    if (validDng) {
        std::vector<float> row(static_cast<size_t>(dngWidth) * 3);
        for (uint32_t y = 0; y < dngHeight && validDng; ++y) {
            validDng = TIFFReadScanline(tif, row.data(), y, 0) >= 0;
            if (!validDng) break;
            for (size_t x = 0; x < row.size(); ++x) {
                const double linear = row[x];
                if (!std::isfinite(linear) || linear < 0 || linear > 1) { validDng = false; break; }
                const double encoded = linear <= .0031308 ? 12.92 * linear : 1.055 * std::pow(linear, 1.0 / 2.4) - .055;
                dngError = std::max(dngError, std::abs(encoded * 255 - exact[static_cast<size_t>(y) * row.size() + x]));
            }
        }
    }
    check(validDng && dngError <= 1, "Combined native float32 DNG pixels match independent exact");
    if (tif) TIFFClose(tif);
    std::cout << "Combined PNG/DNG maximum RGB8 error=" << pngError << "/" << dngError << '\n';
    if (std::getenv("SONY2FUJI_TEST_GPU")) {
        before = sony2fuji::waveletCacheDiagnostics(fresh.get());
        sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_FORCE};
        check(sony2fuji_session_set_gpu_config(fresh.get(), &gpu) == SONY2FUJI_STATUS_OK, "Combined FINAL selects GPU Force");
        const auto forced = render(fresh.get());
        int maximum = 0;
        if (forced.size() == exact.size())
            for (size_t i = 0; i < exact.size(); ++i)
                maximum = std::max(maximum, std::abs(static_cast<int>(forced[i]) - exact[i]));
        after = sony2fuji::waveletCacheDiagnostics(fresh.get());
        check(sony2fuji_session_get_last_backend(fresh.get()) != SONY2FUJI_BACKEND_CPU &&
              forced.size() == exact.size() && maximum <= 2 && after.filterRuns == before.filterRuns + 1,
              "Combined GPU FINAL applies its own NR and preserves CPU reference within two RGB8 values");
        std::cout << "Combined GPU FINAL maximum RGB8 error=" << maximum << '\n';
    }
}
#endif

void testAtomicStorage(const std::filesystem::path& directory) {
    using sony2fuji::ErrorCode;

#ifdef _WIN32
    const auto stagingProbe = directory / "rld-staging-probe.tmp";
    writeFile(stagingProbe, "staging probe");
    check(hasStagingFile(directory), "Windows staging scan detects native rld temporary files");
    std::filesystem::remove(stagingProbe);
#endif

    const auto target = directory / "replace-existing.dng";
    writeFile(target, "old target");
    check(sony2fuji::saveRenderedDNG(smallImage(), target.string()) == ErrorCode::Success,
          "DNG publishes a valid replacement");
    check(readFile(target) != "old target", "successful DNG export replaces existing target");
    check(!hasStagingFile(directory), "successful DNG export leaves no staging file");

    const auto blockedDirectory = directory / "publication-blocked";
    std::filesystem::create_directory(blockedDirectory);
    const auto marker = blockedDirectory / "keep.txt";
    writeFile(marker, "keep directory contents");
    check(sony2fuji::saveRenderedDNG(smallImage(), blockedDirectory.string()) ==
              ErrorCode::IOError,
          "DNG reports failed publication as an I/O error");
    check(std::filesystem::is_directory(blockedDirectory) && readFile(marker) ==
              "keep directory contents",
          "failed DNG publication preserves an existing directory and its contents");
    check(!hasStagingFile(directory), "failed DNG publication removes its staging file");

    const auto invalidTarget = directory / "invalid-preserves-target.dng";
    writeFile(invalidTarget, "preserve this target");
    auto invalid = smallImage();
    invalid.pixels.front().r = std::numeric_limits<float>::quiet_NaN();
    check(sony2fuji::saveRenderedDNG(invalid, invalidTarget.string()) ==
              ErrorCode::ProcessingError,
          "DNG rejects invalid pixels before opening a staging file");
    check(readFile(invalidTarget) == "preserve this target",
          "invalid DNG pixels preserve an existing target");
    check(!hasStagingFile(directory), "invalid DNG pixels leave no staging file");
}

#ifndef _WIN32
void testMidwriteFailure(const std::filesystem::path& directory) {
    using sony2fuji::ErrorCode;

    const auto target = directory / "midwrite-preserves-target.dng";
    writeFile(target, "preserve after write failure");
    sony2fuji::ImageData image(128, 128);
    for (size_t index = 0; index < image.pixels.size(); ++index) {
        const float value = static_cast<float>(index % 256) / 255.0f;
        image.pixels[index] = sony2fuji::RGB(value, 1.0f - value, 0.5f);
    }

    const pid_t child = fork();
    if (child < 0) {
        check(false, "POSIX mid-write failure test can fork");
        return;
    }
    if (child == 0) {
        std::signal(SIGXFSZ, SIG_IGN);
        const struct rlimit limit = {4096, 4096};
        if (setrlimit(RLIMIT_FSIZE, &limit) != 0) _exit(2);
        const ErrorCode result = sony2fuji::saveRenderedDNG(image, target.string());
        _exit(result == ErrorCode::IOError ? 0 : 1);
    }

    int status = 0;
    const bool waited = waitpid(child, &status, 0) == child;
    check(waited && WIFEXITED(status) && WEXITSTATUS(status) == 0,
          "mid-write DNG failure returns an I/O error");
    check(readFile(target) == "preserve after write failure",
          "mid-write DNG failure preserves an existing target");
    check(!hasStagingFile(directory), "mid-write DNG failure removes its staging file");
}
#endif

} // namespace

int main(int argc, char** argv) {
    const auto directory = testDirectory();
#ifdef TEST_LENS_WAVELET_DNG
    if (argc == 2) {
        testLensWaveletViewportDng(directory, argv[1]);
        std::filesystem::remove_all(directory);
        return failures == 0 ? 0 : 1;
    }
#endif
    testRenderedDng(directory);
    testRejectsInvalidInput(directory);
#ifdef TEST_LENS_SDK_DNG
    testLensSdkDng(directory);
#endif
    testAtomicStorage(directory);
#ifndef _WIN32
    testMidwriteFailure(directory);
#endif
    std::filesystem::remove_all(directory);
    return failures == 0 ? 0 : 1;
}
