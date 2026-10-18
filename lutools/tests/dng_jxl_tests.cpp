#include "sony2fuji/raw_processor.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <cmath>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>
#ifdef SONY2FUJI_ENABLE_DNGSDK
#include <dng_memory.h>
#endif

using namespace sony2fuji;

#ifdef SONY2FUJI_ENABLE_DNGSDK
bool rejectSDKOutOfMemory(const std::string& path) {
    struct SimulateMemoryFull {
        SimulateMemoryFull() { DNG_SetSimulateMemoryFull(true); }
        ~SimulateMemoryFull() { DNG_SetSimulateMemoryFull(false); }
    };
    RAWProcessor raw;
    bool valid = false;
    {
        SimulateMemoryFull failure;
        std::cerr << "[EXPECTED RAW FAILURE] dng_jxl.sdkOOM.load: injected SDK allocation failure for "
                  << path << "; require OutOfMemory, not runner memory exhaustion.\n";
        valid = raw.loadFile(path) == ErrorCode::OutOfMemory;
    }
    std::cerr << "[RAW SUCCESS REQUIRED] dng_jxl.sdkOOM.recovery: allocation injection is disabled; "
              << path << " must load successfully.\n";
    if (raw.loadFile(path) != ErrorCode::Success) return false;
    RAWProcessOptions options;
    options.useCameraWhiteBalance = false;
    options.useCustomWhiteBalance = true;
    options.customWhiteBalance[0] = 1.2f;
    ImageData image;
    {
        SimulateMemoryFull failure;
        std::cerr << "[EXPECTED RAW FAILURE] dng_jxl.sdkOOM.reload: injected SDK allocation failure; "
                  << "white-balance reload must return OutOfMemory.\n";
        valid = raw.process(options, image) == ErrorCode::OutOfMemory && valid;
    }
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return false;
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = path.c_str();
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.brightness = request.contrast = request.saturation = 1;
    sony2fuji_buffer output{};
    {
        SimulateMemoryFull failure;
        std::cerr << "[EXPECTED RAW FAILURE] dng_jxl.sdkOOM.cABI: injected SDK allocation failure; "
                  << "require OUT_OF_MEMORY and an empty output buffer.\n";
        valid = sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OUT_OF_MEMORY &&
            !output.data && valid;
    }
    sony2fuji_release_buffer(&output);
    sony2fuji_session_destroy(session);
    std::cout << (valid ? "PASS" : "FAIL") << " SDK OOM survives load, WB reload and C ABI\n";
    return valid;
}
#endif

bool comparePixels(const ImageData& actual, const ImageData& expected,
                   float tolerance = 1e-5f, int width = 24, int height = 32) {
    if (actual.width != width || actual.height != height ||
        expected.width != actual.width || expected.height != actual.height) return false;
    float maximumError = 0, maximumSignal = 0;
    for (size_t i = 0; i < actual.pixels.size(); ++i) {
        const auto a = actual.pixels[i], b = expected.pixels[i];
        for (float value : {a.r, a.g, a.b}) if (!std::isfinite(value)) return false;
        maximumError = std::max(maximumError, std::max({std::abs(a.r-b.r), std::abs(a.g-b.g), std::abs(a.b-b.b)}));
        maximumSignal = std::max(maximumSignal, std::max({a.r, a.g, a.b}));
    }
    std::cout << "Lossless JXL linear " << actual.width << 'x' << actual.height
              << " maximum error=" << maximumError << '\n';
    return maximumError < tolerance && maximumSignal > .01f;
}

bool compareLinear(RAWProcessor& compressed, RAWProcessor& reference, RAWProcessOptions options,
                   float tolerance = 1e-5f, int width = 24, int height = 32) {
    ImageData actual, expected;
    return compressed.process(options, actual) == ErrorCode::Success &&
        reference.process(options, expected) == ErrorCode::Success &&
        comparePixels(actual, expected, tolerance, width, height);
}

bool checkChannelLevels(const std::string& directory) {
    RAWProcessor reused, normalized, ordinary;
    const auto jxl = directory + "/linear-jxl-channel-levels.dng";
    const auto plain = directory + "/linear-channel-levels.dng";
    if (reused.loadFile(jxl) != ErrorCode::Success ||
        normalized.loadFile(directory + "/linear-normalized.dng") != ErrorCode::Success ||
        ordinary.loadFile(plain) != ErrorCode::Success) return false;
    RAWProcessOptions camera;
    camera.applyBaselineExposure = false;
    ImageData first, expected, restored, custom;
    if (reused.process(camera, first) != ErrorCode::Success ||
        normalized.process(camera, expected) != ErrorCode::Success) return false;
    std::cout << "Channel levels: first camera WB vs independent normalized samples\n";
    bool valid = comparePixels(first, expected, 2e-4f);
    RAWProcessOptions customOptions = camera;
    customOptions.useCameraWhiteBalance = false;
    customOptions.useCustomWhiteBalance = true;
    customOptions.customWhiteBalance[0] = 1.2f;
    customOptions.customWhiteBalance[2] = .8f;
    if (reused.process(customOptions, custom) != ErrorCode::Success ||
        reused.process(camera, restored) != ErrorCode::Success) return false;
    std::cout << "Channel levels: camera -> custom -> camera\n";
    valid = comparePixels(restored, first, 1e-7f) && valid;
    std::cout << "Channel levels: restored camera WB vs independent normalized samples\n";
    valid = comparePixels(restored, expected, 2e-4f) && valid;
    if (reused.loadFile(plain) != ErrorCode::Success) return false;
    std::cout << "Channel levels: JXL -> ordinary DNG vs fresh ordinary decoder\n";
    valid = compareLinear(reused, ordinary, camera, 1e-7f) && valid;
    std::cout << (valid ? "PASS" : "FAIL") << " Unequal channel levels preserve camera WB and decoder reuse\n";
    return valid;
}

#if defined(SONY2FUJI_ENABLE_DNGSDK) && defined(SONY2FUJI_ENABLE_LENSFUN)
bool checkLensStage3(const std::string& directory) {
    RAWProcessOptions on;
    on.applyBaselineExposure = false;
    on.lensDatabase = LensCorrectionDatabase::load(directory + "/lenses.xml");
    on.lensCorrection.distortion = on.lensCorrection.tca = true;
    auto off = on;
    off.lensCorrection.distortion = off.lensCorrection.tca = false;
    const auto stage3 = directory + "/linear-jxl-stage3-lens.dng";
    const auto jxl = directory + "/linear-jxl-lens.dng";
    const auto plain = directory + "/linear-lens.dng";
    RAWProcessor reused;
    ImageData baseline, corrected, restored, customBaseline, customCorrected;
    auto same = [](const ImageData& a, const ImageData& b) {
        return comparePixels(a, b, 1e-7f, a.width, a.height);
    };
    auto embedded = [&]() {
        const auto report = reused.getLensCorrectionReport();
        return report.state == LensCorrectionState::EmbeddedGeometry &&
            !report.appliedDistortion && !report.appliedTCA;
    };
    if (reused.loadFile(stage3) != ErrorCode::Success ||
        reused.process(off, baseline) != ErrorCode::Success ||
        reused.process(on, corrected) != ErrorCode::Success || !embedded() ||
        !same(corrected, baseline)) return false;
    const auto warpedBaseline = baseline;
    auto custom = on;
    custom.useCameraWhiteBalance = false;
    custom.useCustomWhiteBalance = true;
    custom.customWhiteBalance[0] = 1.2f;
    custom.customWhiteBalance[2] = .8f;
    auto customOff = custom;
    customOff.lensCorrection = off.lensCorrection;
    if (reused.process(customOff, customBaseline) != ErrorCode::Success ||
        reused.process(custom, customCorrected) != ErrorCode::Success || !embedded() ||
        !same(customCorrected, customBaseline) ||
        reused.process(on, restored) != ErrorCode::Success || !embedded() ||
        !same(restored, baseline)) return false;
    std::cout << "PASS Actual SDK Stage3 warp skips Lens through WB reload\n";
    if (reused.loadFile(jxl) != ErrorCode::Success ||
        reused.process(off, baseline) != ErrorCode::Success ||
        reused.process(on, corrected) != ErrorCode::Success) return false;
    if (warpedBaseline.width == baseline.width && warpedBaseline.height == baseline.height) {
        float warpDifference = 0;
        for (size_t i = 0; i < baseline.pixels.size(); ++i)
            warpDifference = std::max(warpDifference, std::abs(warpedBaseline.pixels[i].r - baseline.pixels[i].r));
        if (warpDifference <= 1e-6f) return false;
        std::cout << "PASS SDK Stage3 changes actual geometry, maximum difference=" << warpDifference << '\n';
    }
    const auto report = reused.getLensCorrectionReport();
    if (report.state != LensCorrectionState::Matched || !report.appliedDistortion ||
        !report.appliedTCA || report.metadata.embeddedGeometry) {
        std::cerr << "Lens fixture state=" << int(report.state) << " camera=" << report.metadata.cameraModel
                  << " lens=" << report.metadata.lensModel << " focal=" << report.metadata.focalLength << '\n';
        return false;
    }
    if (corrected.width != baseline.width || corrected.height != baseline.height) return false;
    float difference = 0;
    for (size_t i = 0; i < corrected.pixels.size(); ++i)
        difference = std::max(difference, std::abs(corrected.pixels[i].r - baseline.pixels[i].r));
    if (difference <= 1e-6f || reused.loadFile(plain) != ErrorCode::Success ||
        reused.process(on, restored) != ErrorCode::Success ||
        reused.getLensCorrectionReport().state != LensCorrectionState::Matched ||
        !same(restored, corrected)) return false;
    std::cout << "PASS Stage3 -> JXL/plain reuse retains actual distortion and TCA\n";
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return false;
    sony2fuji_lens_correction_config lens{SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION, sizeof(lens), 1, 1, 1, nullptr};
    bool valid = sony2fuji_session_set_lens_database(session, (directory + "/lenses.xml").c_str()) == SONY2FUJI_STATUS_OK &&
        sony2fuji_session_set_lens_correction(session, &lens) == SONY2FUJI_STATUS_OK;
    for (const auto& path : {stage3, jxl, plain, stage3}) {
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = path.c_str();
        request.output_target = SONY2FUJI_TARGET_BUFFER; request.output_format = SONY2FUJI_OUTPUT_RGB8;
        request.size_mode = SONY2FUJI_SIZE_NATIVE;
        request.brightness = request.contrast = request.saturation = 1;
        sony2fuji_buffer output{};
        sony2fuji_lens_report state{};
        valid = sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OK &&
            sony2fuji_session_get_lens_report(session, &state) == SONY2FUJI_STATUS_OK && valid;
        valid = (path == stage3 ? state.state == SONY2FUJI_LENS_EMBEDDED_GEOMETRY && !state.applied_distortion && !state.applied_tca
                               : state.state == SONY2FUJI_LENS_MATCHED && state.applied_distortion && state.applied_tca) && valid;
        sony2fuji_release_buffer(&output);
    }
    sony2fuji_session_destroy(session);
    std::cout << (valid ? "PASS" : "FAIL") << " C ABI Lens/SDK Stage3 state remains input-specific\n";
    return valid;
}
#endif

bool checkCameraWBRoundTrip(const std::string& path) {
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return false;
    sony2fuji_gpu_config gpu{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(gpu), SONY2FUJI_GPU_OFF};
    sony2fuji_session_set_gpu_config(session, &gpu);
    sony2fuji_session_set_raw_exposure_mode(session, SONY2FUJI_EXPOSURE_SENSOR);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = path.c_str();
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.brightness = request.contrast = request.saturation = 1;
    request.temperature = 6500;
    request.wb_mul[0] = 1.2f;
    request.wb_mul[1] = request.wb_mul[3] = 1;
    request.wb_mul[2] = .8f;
    std::vector<unsigned char> first, custom;
    bool valid = true;
    size_t maximumError = 0;
    for (auto mode : {SONY2FUJI_WB_CAMERA, SONY2FUJI_WB_CUSTOM, SONY2FUJI_WB_CAMERA}) {
        request.wb_mode = mode;
        sony2fuji_buffer output{};
        const auto status = sony2fuji_process(session, &request, &output);
        if (status != SONY2FUJI_STATUS_OK || !output.data || output.width != 24 || output.height != 32) {
            valid = false;
        } else {
            const auto* bytes = static_cast<const unsigned char*>(output.data);
            const size_t size = static_cast<size_t>(output.stride_bytes) * output.height;
            if (first.empty()) first.assign(bytes, bytes + size);
            else if (mode == SONY2FUJI_WB_CUSTOM) custom.assign(bytes, bytes + size);
            else if (size != first.size()) valid = false;
            else for (size_t i = 0; i < size; ++i)
                maximumError = std::max(maximumError, static_cast<size_t>(std::abs(int(bytes[i]) - int(first[i]))));
        }
        sony2fuji_release_buffer(&output);
    }
    valid = valid && !custom.empty() && custom != first && maximumError == 0;
    sony2fuji_session_destroy(session);
    std::cout << (valid ? "PASS" : "FAIL") << " C ABI camera -> custom -> camera maximum byte error=" << maximumError << '\n';
    return valid;
}

bool rejectDecodeError(const std::string& name) {
    RAWProcessor raw;
    bool valid = raw.loadFile(name) == ErrorCode::ProcessingError;
    sony2fuji_session* session = nullptr;
    sony2fuji_session_create(&session);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = name.c_str();
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.brightness = request.contrast = request.saturation = 1;
    sony2fuji_buffer output{};
    const auto status = sony2fuji_process(session, &request, &output);
    valid = valid && status == SONY2FUJI_STATUS_PROCESSING_ERROR && !output.data;
    sony2fuji_release_buffer(&output);
    sony2fuji_session_destroy(session);
    return valid;
}

bool rejectCorruptJXL(const std::string& source) {
    std::ifstream input(std::filesystem::u8path(source), std::ios::binary);
    std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(input)), {});
    const unsigned char signature[] = {0, 0, 0, 12, 'J', 'X', 'L', ' ', 13, 10, 135, 10};
    auto marker = std::search(bytes.begin(), bytes.end(), std::begin(signature), std::end(signature));
    if (marker == bytes.end()) return false;
    *marker = 255;
    auto path = std::filesystem::temp_directory_path() / ("rawlab-corrupt-jxl-" +
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + ".dng");
    {
        std::ofstream output(path, std::ios::binary);
        output.write(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    }
    std::cerr << "[EXPECTED RAW FAILURE] dng_jxl.corruptJXL: deliberately corrupted JXL bytes in "
              << path.u8string() << "; core and C ABI must report processing errors, not success or I/O errors.\n";
    const bool valid = rejectDecodeError(path.u8string());
    std::filesystem::remove(path);
    std::cout << (valid ? "PASS" : "FAIL") << " Corrupt JXL is a decoding error, not a path error\n";
    return valid;
}

bool compareRender(const char* path) {
    sony2fuji_session* session = nullptr;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return false;
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = path;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.size_mode = SONY2FUJI_SIZE_FIT_LONG_EDGE;
    request.long_edge = 256;
    request.brightness = request.contrast = request.saturation = 1;
    request.wb_mode = SONY2FUJI_WB_CAMERA;
    std::vector<unsigned char> cpu;
    bool valid = true;
    int width = 0, height = 0;
    for (auto mode : {SONY2FUJI_GPU_OFF, SONY2FUJI_GPU_AUTO}) {
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), mode};
        sony2fuji_session_set_gpu_config(session, &config);
        sony2fuji_buffer output{};
        const auto status = sony2fuji_process(session, &request, &output);
        if (status != SONY2FUJI_STATUS_OK) std::cerr << sony2fuji_status_message(status) << '\n';
        valid = valid && status == SONY2FUJI_STATUS_OK && output.data && output.width > 0 && output.height > 0;
        if (valid) {
            const auto* bytes = static_cast<const unsigned char*>(output.data);
            const size_t size = static_cast<size_t>(output.stride_bytes) * output.height;
            if (cpu.empty()) {
                cpu.assign(bytes, bytes + size);
                width = output.width; height = output.height;
                valid = std::any_of(cpu.begin(), cpu.end(), [](unsigned char value) { return value > 0; });
            } else {
                valid = size == cpu.size() && width == output.width && height == output.height;
                if (valid) for (size_t i = 0; i < size; ++i)
                    valid = valid && std::abs(int(bytes[i]) - int(cpu[i])) <= 1;
            }
        }
        sony2fuji_release_buffer(&output);
    }
    sony2fuji_session_destroy(session);
    std::cout << "JXL C ABI CPU/Auto render " << width << 'x' << height << '\n';
    return valid;
}

int main(int argc, char** argv) {
    std::string directory = TEST_FIXTURE_DIR;
    const char* external = argc > 1 ? argv[1] : nullptr;
    if (argc >= 3 && std::strcmp(argv[1], "--fixtures") == 0) {
        directory = argv[2];
        external = argc > 3 ? argv[3] : nullptr;
    }
    const std::string jxl = directory + "/linear-jxl.dng";
    const std::string plain = directory + "/linear-uncompressed.dng";
    const bool channelLevels = checkChannelLevels(directory);
    const bool cameraRoundTrip = checkCameraWBRoundTrip(directory + "/linear-jxl-channel-levels.dng");
    if (!channelLevels || !cameraRoundTrip) return 1;
#if defined(SONY2FUJI_ENABLE_DNGSDK) && defined(SONY2FUJI_ENABLE_LENSFUN)
    if (!checkLensStage3(directory)) return 1;
#endif
#ifdef SONY2FUJI_ENABLE_DNGSDK
    if (!rejectSDKOutOfMemory(jxl)) return 1;
#endif
    if (!rejectCorruptJXL(jxl)) return 1;
    std::cerr << "[EXPECTED RAW FAILURE] dng_jxl.unsupportedOpcode: required unknown Stage1 opcode in "
              << directory << "/linear-jxl-required-unknown.dng; require processing errors, not success or I/O errors.\n";
    if (!rejectDecodeError(directory + "/linear-jxl-required-unknown.dng")) return 1;
    std::cout << "PASS Unsupported required Stage1 opcode is rejected\n";
    std::cerr << "[RAW SUCCESS REQUIRED] dng_jxl.validFixtures: expected-failure checks are complete; "
              << "the unmodified RAW fixtures must now load and render successfully.\n";
    RAWProcessor compressed, reference;
    if (compressed.loadFile(jxl) != ErrorCode::Success || reference.loadFile(plain) != ErrorCode::Success) return 1;
    RAWProcessOptions options;
    options.applyBaselineExposure = false;
    if (!compareLinear(compressed, reference, options)) return 1;
    options.useCameraWhiteBalance = false;
    options.useCustomWhiteBalance = true;
    options.customWhiteBalance[0] = 1.2f;
    options.customWhiteBalance[2] = .8f;
    options.exposure = 1;
    if (!compareLinear(compressed, reference, options)) return 1;
    if (compressed.loadFile(plain) != ErrorCode::Success || !compareLinear(compressed, reference, options)) return 1;
    options = RAWProcessOptions();
    options.applyBaselineExposure = false;
    if (compressed.loadFile(directory + "/linear-jxl-gain.dng") != ErrorCode::Success ||
        reference.loadFile(directory + "/linear-doubled.dng") != ErrorCode::Success ||
        !compareLinear(compressed, reference, options, 2e-4f)) return 1;
    if (compressed.loadFile(directory + "/linear-jxl-stage1.dng") != ErrorCode::Success ||
        reference.loadFile(directory + "/linear-halved.dng") != ErrorCode::Success ||
        !compareLinear(compressed, reference, options, 2e-4f)) return 1;
    if (compressed.loadFile(directory + "/linear-jxl-crop-gain.dng") != ErrorCode::Success ||
        reference.loadFile(directory + "/linear-crop-doubled.dng") != ErrorCode::Success ||
        !compareLinear(compressed, reference, options, 2e-4f, 22, 30)) return 1;
    if (compressed.loadFile(directory + "/linear-jxl-default-crop-gain.dng") != ErrorCode::Success ||
        reference.loadFile(directory + "/linear-default-crop-doubled.dng") != ErrorCode::Success ||
        !compareLinear(compressed, reference, options, 2e-4f, 20, 28)) return 1;
    if (!compareRender(jxl.c_str()) || (external && !compareRender(external))) return 1;
    std::cout << "PASS JPEG XL DNG opcodes, ActiveArea crop, WB reload, decoder reuse and C ABI rendering\n";
    return 0;
}
