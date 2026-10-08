#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/file_path.h"
#include <cstdlib>
#include <cstring>
#include <memory>

// Windows-only helper. Extracts embedded data without unpacking/demosaicing RAW.
// kind=1: JPEG bytes, kind=2: RGB8 pixels. flip is LibRaw's orientation.
extern "C" __declspec(dllexport) int rawlab_preview(
    const char* path, sony2fuji_buffer* output, int* kind, int* flip, int* width, int* height) {
    if (!path || !output || !kind || !flip) return 1;
    *output = {};
    if (width) *width=0;
    if (height) *height=0;
    try {
        auto raw = std::make_unique<LibRaw>();
        if (sony2fuji::openRawFile(*raw,path)) return 3;
        raw->adjust_to_raw_inset_crop(3);
        const auto& sizes=raw->imgdata.sizes;
        if (width) *width=(sizes.flip & 4) ? sizes.height : sizes.width;
        if (height) *height=(sizes.flip & 4) ? sizes.width : sizes.height;
        if (raw->unpack_thumb()) return 3;
        std::unique_ptr<libraw_processed_image_t, decltype(&LibRaw::dcraw_clear_mem)>
            thumbnail(raw->dcraw_make_mem_thumb(), LibRaw::dcraw_clear_mem);
        if (!thumbnail) return 2;
        *kind = thumbnail->type == LIBRAW_IMAGE_JPEG ? 1 : 2;
        if (*kind == 2 && (thumbnail->type != LIBRAW_IMAGE_BITMAP ||
            thumbnail->bits != 8 || thumbnail->colors != 3)) return 2;
        if (thumbnail->data_size > 64 * 1024 * 1024) return 2;
        output->data = std::malloc(thumbnail->data_size);
        if (!output->data) return 5;
        std::memcpy(output->data, thumbnail->data, thumbnail->data_size);
        output->size_bytes = thumbnail->data_size;
        output->width = thumbnail->width; output->height = thumbnail->height;
        output->stride_bytes = thumbnail->width * 3;
        output->pixel_format = SONY2FUJI_PIXEL_RGB8;
        *flip = raw->imgdata.sizes.flip;
        return 0;
    } catch (...) { sony2fuji_release_buffer(output); return 4; }
}

extern "C" __declspec(dllexport) int rawlab_thumbnail(
    const char* path, sony2fuji_buffer* output, int* kind, int* flip) {
    return rawlab_preview(path, output, kind, flip, nullptr, nullptr);
}
