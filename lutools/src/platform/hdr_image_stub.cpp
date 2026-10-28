#include "platform/hdr_image.h"

namespace sony2fuji::hdr {
namespace {
[[noreturn]] void unsupported() {
    throw Error(SONY2FUJI_STATUS_UNSUPPORTED, SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM,
        SONY2FUJI_HDR_FIELD_PATH, "HDR file codecs are not available on this platform");
}
}
void admitMemory(uint64_t) {}
sony2fuji_hdr_source_info_v1 probeFile(const char*) { unsupported(); }
DecodedImage decodeFile(const char*, const sony2fuji_hdr_decode_options_v1&) { unsupported(); }
void exportJPEG(const HDRImagePair&, const sony2fuji_hdr_export_config_v1&, const char*) { unsupported(); }
void exportSDR(const HDRImagePair&, const sony2fuji_hdr_sdr_export_config_v1&, const char*) { unsupported(); }
} // namespace sony2fuji::hdr
