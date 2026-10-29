#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/processing_cancellation.h"
#include "core/photo_color.h"
#include "core/photo_color_grading.h"
#include "core/photo_tone_controls.h"
#include "core/photo_effects.h"
#include "core/photo_geometry.h"
#include "core/photo_lut.h"
#include <atomic>
#include <iostream>
#include <vector>

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
    sony2fuji_session_destroy(session);
    return failures ? 1 : 0;
}
