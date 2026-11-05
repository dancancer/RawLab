#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/processing_cancellation.h"

// HDR 不继承旧会话的 RAW/外观状态；以下私有入口限定会话访问。
bool hdrSessionForcesGPU(const sony2fuji_session* session);
void hdrSessionDidRenderCPU(sony2fuji_session* session);
sony2fuji::ProcessingCancellation hdrSessionCancellation(const sony2fuji_session* session);
