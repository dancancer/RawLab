#pragma once

#include "sony2fuji/ffi/sony2fuji_c.h"
#include "ffi/hdr_session.h"
#include "core/pipeline.h"
#include "core/pixel_buffer.h"
#include <memory>

namespace sony2fuji::hdr { struct RoiSessionCache; }

struct sony2fuji_session {
    sony2fuji::Pipeline pipeline;
    std::shared_ptr<sony2fuji::hdr::RoiSessionCache> hdrRoiCache;
};

inline sony2fuji_status toFfiStatus(sony2fuji::RenderStatus status) noexcept {
    return static_cast<sony2fuji_status>(status);
}

inline sony2fuji_buffer toFfiBuffer(sony2fuji::OwnedPixelBuffer& owned) noexcept {
    sony2fuji_buffer out{};
    out.size_bytes = owned.sizeBytes;
    out.width = owned.width;
    out.height = owned.height;
    out.stride_bytes = owned.strideBytes;
    out.pixel_format = static_cast<sony2fuji_pixel_format>(owned.format);
    out.data = owned.releaseData();
    return out;
}
