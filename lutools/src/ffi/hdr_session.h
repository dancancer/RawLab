#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"

// HDR 不继承旧会话的 RAW/外观状态；这两个私有入口限定唯一的会话访问。
bool hdrSessionForcesGPU(const sony2fuji_session* session);
void hdrSessionDidRenderCPU(sony2fuji_session* session);
