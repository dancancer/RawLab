// Test-only white-box probe: reuse the exact FFI decode/resize helpers without
// changing shared source or adding a diagnostic API to the production DLL.
#include "../../../lutools/src/ffi/sony2fuji_c.cpp"
#include <iostream>
#include <random>
#include <stdexcept>

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

static std::vector<uint8_t> render(sony2fuji_session& session, sony2fuji_request& request) {
    sony2fuji_buffer buffer{};
    require(sony2fuji_process(&session, &request, &buffer) == SONY2FUJI_STATUS_OK, "ABI render failed");
    const auto* bytes = static_cast<const uint8_t*>(buffer.data);
    std::vector<uint8_t> result(bytes, bytes + buffer.size_bytes);
    sony2fuji_release_buffer(&buffer);
    return result;
}

static void inspect(const char* name, sony2fuji::ImageData image) {
    const auto original = image.pixels;
    sony2fuji::WaveletDenoiseDiagnostics diagnostics;
    require(sony2fuji::applyWaveletDenoise(image, {true, 10, 72, 100}, &diagnostics) == sony2fuji::ErrorCode::Success,
        "Wavelet diagnostic failed");
    double maximum = 0;
    size_t changed = 0;
    for (size_t i = 0; i < original.size(); ++i) {
        for (const auto delta : {image.pixels[i].r-original[i].r, image.pixels[i].g-original[i].g, image.pixels[i].b-original[i].b}) {
            maximum = std::max(maximum, double(std::abs(delta)));
            changed += delta != 0;
        }
    }
    std::cout << name << " width=" << image.width << " height=" << image.height
        << " flatTiles=" << diagnostics.flatTiles << " applied=" << diagnostics.applied
        << " changedFloatChannels=" << changed << " maxAbsDelta=" << maximum << std::endl;
    if (std::string(name) == "synthetic") require(diagnostics.applied && diagnostics.flatTiles >= 8 && changed > 0,
        "Controlled noisy input must actually be filtered");
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    try {
        sony2fuji_session session;
        session.gpu_config.mode = sony2fuji::GpuMode::Off;
        session.raw_exposure_mode = SONY2FUJI_EXPOSURE_PREVIEW;
        session.viewport_preview = true;
        sony2fuji_request request{};
        request.version = SONY2FUJI_REQUEST_VERSION; request.struct_size = sizeof(request);
        request.input_type = SONY2FUJI_INPUT_RAW; request.input_path = argv[1];
        request.wb_mode = SONY2FUJI_WB_CAMERA; request.temperature = 6500;
        for (auto& multiplier : request.wb_mul) multiplier = 1;
        request.brightness = request.contrast = request.saturation = 1;
        request.intent = SONY2FUJI_INTENT_PREVIEW; request.preview_long_edge = 1600;
        request.size_mode = SONY2FUJI_SIZE_NATIVE; request.output_target = SONY2FUJI_TARGET_BUFFER;
        request.output_format = SONY2FUJI_OUTPUT_RGBA8;
        const auto off = render(session, request);
        sony2fuji_wavelet_denoise_config config{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(config), 1, 10, 72, 100};
        const auto accepted = sony2fuji_session_set_wavelet_denoise(&session, &config);
        require(accepted == SONY2FUJI_STATUS_OK, "Clean configuration rejected");
        const auto clean = render(session, request);
        size_t changed = 0;
        require(off.size() == clean.size(), "Output sizes differ");
        for (size_t i = 0; i < off.size(); ++i) changed += off[i] != clean[i];
        const auto cache = sony2fuji::waveletCacheDiagnostics(&session);
        std::cout << "ABI accepted=" << accepted << " changedBytes=" << changed << " filterRuns=" << cache.filterRuns
            << " outputHits=" << cache.outputHits << " analysisHits=" << cache.analysisHits << std::endl;
        uint32_t width = 0, height = 0;
        require(computeTargetSize(request, session.raw_cache.width, session.raw_cache.height, &width, &height) == SONY2FUJI_STATUS_OK,
            "Viewport size failed");
        const double scale=std::min({1.0, double(session.raw_cache.width)/width, double(session.raw_cache.height)/height});
        width=std::max(1u,static_cast<uint32_t>(std::lround(width*scale)));
        height=std::max(1u,static_cast<uint32_t>(std::lround(height*scale)));
        auto viewport = resizeBilinear(session.raw_cache, width, height);
        require(sony2fuji::ColorConverter().convertImage(viewport, sony2fuji::ColorSpace::AdobeRGB,
            sony2fuji::ColorSpace::sRGB) == sony2fuji::ErrorCode::Success, "Color conversion failed");
        inspect("raw-viewport", std::move(viewport));
        sony2fuji::ImageData synthetic(512, 512);
        std::mt19937 random(42); std::normal_distribution<float> noise(.18f, .016f);
        for (auto& pixel : synthetic.pixels) pixel = {noise(random), noise(random), noise(random)};
        inspect("synthetic", std::move(synthetic));
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        return 1;
    }
}
