#include <stdio.h>
#include "sony2fuji/ffi/sony2fuji_c.h"

int main(int argc, char **argv) {
    if (argc != 12) {
        fprintf(stderr, "Expected 11 display LUTs, found %d\n", argc - 1);
        return 1;
    }
    unsigned char pixels[12] = {120, 80, 40, 10, 220, 30, 180, 20, 190, 230, 230, 230};
    sony2fuji_session *session = NULL;
    if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return 1;
    sony2fuji_request request = {0};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_pixels = pixels;
    request.input_width = request.input_height = 2;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.temperature = 6500;
    request.brightness = request.contrast = request.saturation = 1;
    request.lut_strength = 1;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGBA8;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    int failures = 0;
    for (int i = 1; i < argc; i++) {
        request.lut_path = argv[i];
        sony2fuji_buffer output = {0};
        sony2fuji_status status = sony2fuji_process(session, &request, &output);
        int valid = status == SONY2FUJI_STATUS_OK && output.data != NULL &&
            output.width == 2 && output.height == 2 && output.pixel_format == SONY2FUJI_PIXEL_RGBA8;
        printf("%s: %s (%s)\n", valid ? "PASS" : "FAIL", argv[i], sony2fuji_status_message(status));
        if (!valid) failures++;
        sony2fuji_release_buffer(&output);
    }
    sony2fuji_session_destroy(session);
    return failures ? 1 : 0;
}
