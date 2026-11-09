#include "RawMetadataBridge.h"

#include <string>

#include "sony2fuji/raw_processor.h"

RawDimensions rawlab_get_raw_dimensions(const char *path) {
    RawDimensions dims = {0, 0};
    if (!path || path[0] == '\0') {
        return dims;
    }

    sony2fuji::RAWProcessor processor;
    sony2fuji::ErrorCode result = processor.loadFile(std::string(path));
    if (result != sony2fuji::ErrorCode::Success) {
        return dims;
    }

    dims.width = static_cast<uint32_t>(processor.getWidth());
    dims.height = static_cast<uint32_t>(processor.getHeight());
    return dims;
}

RawFileKind rawlab_probe_raw_file(const char *path) {
    if (!path || path[0] == '\0') {
        return RAWLAB_FILE_NOT_RAW;
    }

    // readLensMetadata uses LibRaw identification without unpacking pixels.
    sony2fuji::LensMetadata metadata;
    if (sony2fuji::RAWProcessor::readLensMetadata(path, metadata) != sony2fuji::ErrorCode::Success) {
        return RAWLAB_FILE_NOT_RAW;
    }
    return metadata.cameraMake == "Sony" || metadata.cameraMake == "SONY"
        ? RAWLAB_FILE_SONY_RAW : RAWLAB_FILE_RAW;
}
