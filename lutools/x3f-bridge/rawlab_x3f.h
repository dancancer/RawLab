#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Pixels and error text remain owned by this handle until its next decode/free.
typedef struct rawlab_x3f_handle rawlab_x3f_handle;
typedef struct rawlab_x3f_cancel_token rawlab_x3f_cancel_token;
typedef struct rawlab_x3f_image {
    const float* pixels;
    size_t sample_count;
    uint32_t width, height;
    // 1: display-encoded sRGB; 2: extended-linear sRGB, never interchangeable.
    uint32_t encoding;
    // EXIF orientation. The C++ adapter applies it once.
    uint32_t orientation;
} rawlab_x3f_image;

rawlab_x3f_handle* rawlab_x3f_create(void);
void rawlab_x3f_free(rawlab_x3f_handle* handle);
const char* rawlab_x3f_error(const rawlab_x3f_handle* handle);
rawlab_x3f_cancel_token* rawlab_x3f_cancel_create(void);
void rawlab_x3f_cancel(const rawlab_x3f_cancel_token* token);
void rawlab_x3f_cancel_free(rawlab_x3f_cancel_token* token);
// pipeline: 0 = DP1S calibrated response, 1 = native AsShot, 2 = Merrill SPP.
// Returns 0 on success, 1 on invalid arguments, 3 on decode failure, 4 on cancellation.
int32_t rawlab_x3f_decode(rawlab_x3f_handle* handle, const char* path,
                         uint32_t pipeline, uint32_t orientation,
                         const rawlab_x3f_cancel_token* cancel, rawlab_x3f_image* output);

#ifdef __cplusplus
}
#endif
