#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/processing_cancellation.h"
#include "sony2fuji/common.h"
#include "sony2fuji/lens_correction.h"
#include <string>

namespace sony2fuji { struct RAWBayerSource; struct RAWBayerOverride; }

// HDR 不继承旧会话的 RAW/外观状态；以下私有入口限定会话访问。
bool hdrSessionForcesGPU(const sony2fuji_session* session);
void hdrSessionDidRenderCPU(sony2fuji_session* session);
sony2fuji::ProcessingCancellation hdrSessionCancellation(const sony2fuji_session* session);
std::shared_ptr<const sony2fuji::LensCorrectionDatabase> hdrSessionLensDatabase(sony2fuji_session* session);
void hdrSessionPrepareCameraAI(sony2fuji_session* session, const char* path, uint64_t fileBytes,
    sony2fuji_ai_progress_callback progress, void* context);
std::string hdrSessionCameraAIKey(sony2fuji_session* session, const char* path);
sony2fuji::RAWBayerOverride hdrSessionLoadCameraAI(sony2fuji_session* session, const std::string& key,
    const sony2fuji::RAWBayerSource& metadata);
sony2fuji_hsl_probe* makeHDRHslProbe(sony2fuji::ImageData image, uint64_t sourceRevision, uint64_t requestRevision, bool preview);
