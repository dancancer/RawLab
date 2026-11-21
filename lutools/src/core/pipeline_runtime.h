#pragma once

#include <cstdint>
#include <memory>

#ifdef SONY2FUJI_ENABLE_AI_DENOISE
#include "ai/ai_session.h"
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
#include "gpu/gles_photo.h"
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
#include "gpu/d3d11_photo.h"
#endif

namespace sony2fuji {

struct PipelineRuntimeState {
#ifdef SONY2FUJI_ENABLE_AI_DENOISE
    std::unique_ptr<ai::AISession> ai;
#endif
#if defined(SONY2FUJI_ENABLE_GLES)
    std::unique_ptr<GlesPhotoRenderer> glesRenderer;
#endif
#if defined(SONY2FUJI_ENABLE_D3D11)
    std::unique_ptr<D3D11PhotoRenderer> d3dRenderer;
#endif
#if defined(SONY2FUJI_ENABLE_GLES) || defined(SONY2FUJI_ENABLE_D3D11)
    uint64_t rawRevision = 0;
#endif
};

} // namespace sony2fuji
