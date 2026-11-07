#include "sony2fuji/dcp_compiler.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <cstdlib>
#include <cstring>
#include <new>

namespace {

bool validUtf8Filename(const char* source) {
    if (!source || source[0] == '\0') return false;
    const std::size_t length = std::strlen(source);
    if (length == 0 || (length == 1 && source[0] == '.') || (length == 2 && source[0] == '.' && source[1] == '.'))
        return false;
    for (std::size_t index = 0; index < length; ++index) {
        const unsigned char first = static_cast<unsigned char>(source[index]);
        if (first < 0x20 || first == 0x7f || first == '/') return false;
        std::size_t width = 0;
        if (first < 0x80) width = 1;
        else if (first >= 0xc2 && first <= 0xdf) width = 2;
        else if (first >= 0xe0 && first <= 0xef) width = 3;
        else if (first >= 0xf0 && first <= 0xf4) width = 4;
        else return false;
        if (index + width > length) return false;
        for (std::size_t continuation = 1; continuation < width; ++continuation)
            if ((static_cast<unsigned char>(source[index + continuation]) & 0xc0) != 0x80) return false;
        if (width == 3 && ((first == 0xe0 && static_cast<unsigned char>(source[index + 1]) < 0xa0) ||
                           (first == 0xed && static_cast<unsigned char>(source[index + 1]) >= 0xa0))) return false;
        if (width == 4 && ((first == 0xf0 && static_cast<unsigned char>(source[index + 1]) < 0x90) ||
                           (first == 0xf4 && static_cast<unsigned char>(source[index + 1]) >= 0x90))) return false;
        index += width - 1;
    }
    return true;
}

sony2fuji_dcp_error toCError(sony2fuji::DcpCompilerError error) {
    return static_cast<sony2fuji_dcp_error>(static_cast<uint32_t>(error));
}

template<class Compile>
sony2fuji_status compileBlob(bool validArguments, sony2fuji_blob* out_blob, sony2fuji_dcp_error* out_reason,
                             Compile compile) {
    sony2fuji_release_blob(out_blob);
    if (out_reason) *out_reason = SONY2FUJI_DCP_ERROR_NONE;
    if (!out_blob || !out_reason || !validArguments)
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        sony2fuji::DcpCompilerError error = sony2fuji::DcpCompilerError::None;
        const auto result = compile(error);
        if (result.empty()) {
            *out_reason = toCError(error == sony2fuji::DcpCompilerError::None ?
                                   sony2fuji::DcpCompilerError::Malformed : error);
            return SONY2FUJI_STATUS_UNSUPPORTED;
        }
        void* allocation = std::malloc(result.size());
        if (!allocation) return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        std::memcpy(allocation, result.data(), result.size());
        out_blob->data = allocation;
        out_blob->size_bytes = result.size();
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        *out_reason = SONY2FUJI_DCP_ERROR_MALFORMED;
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
}

} // namespace

extern "C" sony2fuji_status sony2fuji_compile_dcp(
    const void* data, size_t size_bytes, const char* source_name,
    sony2fuji_blob* out_blob, sony2fuji_dcp_error* out_reason) {
    return compileBlob((data || !size_bytes) && validUtf8Filename(source_name), out_blob, out_reason,
        [&](sony2fuji::DcpCompilerError& error) { return sony2fuji::compileDcp(data, size_bytes, source_name, error); });
}

extern "C" sony2fuji_status sony2fuji_compile_hdr_camera_dcp(
    const void* data, size_t size_bytes, sony2fuji_blob* out_blob, sony2fuji_dcp_error* out_reason) {
    return compileBlob(data || !size_bytes, out_blob, out_reason,
        [&](sony2fuji::DcpCompilerError& error) { return sony2fuji::compileHDRCameraDcp(data, size_bytes, error); });
}

extern "C" void sony2fuji_release_blob(sony2fuji_blob* blob) {
    if (!blob) return;
    std::free(blob->data);
    blob->data = nullptr;
    blob->size_bytes = 0;
}
