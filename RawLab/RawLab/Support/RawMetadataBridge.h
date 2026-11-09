#ifndef RawMetadataBridge_h
#define RawMetadataBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RawDimensions {
    uint32_t width;
    uint32_t height;
} RawDimensions;

RawDimensions rawlab_get_raw_dimensions(const char *path);

typedef enum RawFileKind {
    RAWLAB_FILE_NOT_RAW,
    RAWLAB_FILE_RAW,
    RAWLAB_FILE_SONY_RAW,
} RawFileKind;

RawFileKind rawlab_probe_raw_file(const char *path);

#ifdef __cplusplus
}
#endif

#endif
