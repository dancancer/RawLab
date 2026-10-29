#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/lut_compatibility.h"
#include "core/lut_preview_comparison.h"
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <stdexcept>

namespace {
sony2fuji_status compatibility(const char* path, const char* request, sony2fuji_blob* output) {
    if (!output) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji_release_blob(output);
    if (!path || !*path) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        auto bytes=request ? sony2fuji::prepareLUTCompatibility(path,request) : sony2fuji::inspectLUTCompatibility(path);
        output->data=std::malloc(bytes.size());
        if(!output->data) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        std::memcpy(output->data,bytes.data(),bytes.size());output->size_bytes=bytes.size();
        return SONY2FUJI_STATUS_OK;
    } catch(const std::bad_alloc&) { return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch(const std::filesystem::filesystem_error&) { return SONY2FUJI_STATUS_IO_ERROR;
    } catch(const std::exception&) { return SONY2FUJI_STATUS_UNSUPPORTED; }
}
}
extern "C" sony2fuji_status sony2fuji_inspect_lut_compatibility(const char* path, sony2fuji_blob* output) {
    return compatibility(path,nullptr,output);
}
extern "C" sony2fuji_status sony2fuji_prepare_lut_compatibility(const char* path, const char* request, sony2fuji_blob* output) {
    if(!request) { if(output) sony2fuji_release_blob(output); return SONY2FUJI_STATUS_INVALID_ARGUMENT; }
    return compatibility(path,request,output);
}
extern "C" sony2fuji_status sony2fuji_compare_lut_previews(const sony2fuji_buffer* candidate,const sony2fuji_buffer* reference,
    const char* conditions,sony2fuji_blob* output) {
    if(!output) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji_release_blob(output);
    if(!candidate || !reference || !conditions) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        const auto text=sony2fuji::compareLUTPreviews(*candidate,*reference,conditions);
        output->data=std::malloc(text.size());
        if(!output->data) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        std::memcpy(output->data,text.data(),text.size());output->size_bytes=text.size();
        return SONY2FUJI_STATUS_OK;
    } catch(const std::bad_alloc&) {return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch(const std::exception&) {return SONY2FUJI_STATUS_INVALID_ARGUMENT;}
}
