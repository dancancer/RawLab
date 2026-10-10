#include "render_request.h"
#include <cassert>
#include <cmath>
#include <initializer_list>

// Only status text is linked here; these tests exercise adapter validation.
extern "C" const char* sony2fuji_status_message(sony2fuji_status) { return "test status"; }

int main() {
    auto preview = rawlab::makeRequest("input.dng", "film.cube", nullptr, 0.8f, 1.5f, false, 4200, 10, 1600, false);
    assert(preview.version == SONY2FUJI_REQUEST_VERSION);
    assert(preview.struct_size == sizeof(sony2fuji_request));
    assert(preview.brightness == 1 && preview.contrast == 1 && preview.saturation == 1);
    assert(preview.wb_mode == SONY2FUJI_WB_CAMERA);
    assert(preview.temperature == 6500 && preview.tint == 0);
    assert(preview.wb_mul[1] == 1);
    assert(preview.intent == SONY2FUJI_INTENT_PREVIEW);
    assert(preview.preview_long_edge == 1600);
    assert(preview.output_format == SONY2FUJI_OUTPUT_RGBA8);
    assert(preview.exposure_ev == 1.5f);
    auto highlights = rawlab::makeRequest("input.dng", nullptr, nullptr, 1, 0, false, 6500, 0,
        0.25f, 0, 0, 0, 0, 0, 400, false);
    assert(highlights.highlights == -0.25f);
    auto tone = rawlab::makeRequest("input.dng", nullptr, nullptr, 1, 0, false, 6500, 0,
        0, 0, 0.2f, -0.3f, 0.4f, 1.5f, 400, false);
    assert(tone.contrast == 1.2f && tone.tone_curve == -0.3f && tone.saturation == 1.4f && tone.sharpening == 1.5f);
    auto exported = rawlab::makeRequest("input.dng", nullptr, "out.png", 1, 0, true, 4800, -10, 1000, true);
    assert(exported.intent == SONY2FUJI_INTENT_FINAL);
    assert(exported.size_mode == SONY2FUJI_SIZE_NATIVE);
    assert(exported.preview_long_edge == 0);
    assert(exported.output_target == SONY2FUJI_TARGET_FILE);
    assert(exported.output_format == SONY2FUJI_OUTPUT_PNG);
    assert(exported.wb_mode == SONY2FUJI_WB_TEMPERATURE);
    assert(exported.temperature == 4800 && exported.tint == -10);
    assert(exported.lut_strength == 0);
    for (const char* output : {static_cast<const char*>(nullptr), "out.jpg"}) {
        auto strong = rawlab::makeRequest("in", "film.cube", output, 2, 0, false, 6500, 0, 400, false);
        assert(strong.lut_strength == 2);
    }
    for (float strength : {-0.01f, 2.01f, NAN}) {
        bool invalidStrength = false;
        try { rawlab::makeRequest("in", "film.cube", nullptr, strength, 0, false, 6500, 0, 400, false); }
        catch (const std::invalid_argument&) { invalidStrength = true; }
        assert(invalidStrength);
    }
    bool rejected = false;
    try { rawlab::makeRequest("in", nullptr, nullptr, 1, NAN, false, 6500, 0, 1600, false); }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);
    bool outOfMemory = false;
    try { rawlab::checkStatus(SONY2FUJI_STATUS_OUT_OF_MEMORY); }
    catch (const std::bad_alloc&) { outOfMemory = true; }
    assert(outOfMemory);
    char pixel = 0;
    sony2fuji_buffer padded{&pixel, 19, 2, 2, 12, SONY2FUJI_PIXEL_RGBA8};
    bool truncated = false;
    try { rawlab::previewByteCount(padded); }
    catch (const std::runtime_error&) { truncated = true; }
    assert(truncated);
    padded.size_bytes = 20;
    assert(rawlab::previewByteCount(padded) == 16);
}
