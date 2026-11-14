#pragma once
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/processing_cancellation.h"
#include "sony2fuji/common.h"
#include "sony2fuji/lens_correction.h"
#include <memory>
#include <string>

namespace sony2fuji { struct RAWBayerSource; struct RAWBayerOverride; }

struct sony2fuji_session_slot;

// 单会话独占租约与生命周期校验；防止悬空句柄、ABA 复用与跨线程并发踩踏。
class SessionLease {
public:
    SessionLease() = default;
    ~SessionLease();
    SessionLease(const SessionLease&) = delete;
    SessionLease& operator=(const SessionLease&) = delete;

    static bool acquire(const sony2fuji_session* handle, SessionLease& out, bool allowNull = false);
    sony2fuji_session* raw() const { return session_; }
    const sony2fuji_session* constRaw() const { return session_; }
    explicit operator bool() const { return session_ != nullptr; }

private:
    sony2fuji_session* session_ = nullptr;
    std::shared_ptr<sony2fuji_session_slot> slot_;
};

// HDR 不继承旧会话的 RAW/外观状态；以下私有入口限定会话访问。
bool hdrSessionForcesGPU(const SessionLease& session);
bool hdrSessionUsesLegacySonyCrop(const SessionLease& session);
void hdrSessionDidRenderCPU(const SessionLease& session);
sony2fuji::ProcessingCancellation hdrSessionCancellation(const SessionLease& session);
std::shared_ptr<const sony2fuji::LensCorrectionDatabase> hdrSessionLensDatabase(const SessionLease& session);
void hdrSessionPrepareCameraAI(const SessionLease& session, const char* path, uint64_t fileBytes,
    sony2fuji_ai_progress_callback progress, void* context);
std::string hdrSessionCameraAIKey(const SessionLease& session, const char* path);
sony2fuji::RAWBayerOverride hdrSessionLoadCameraAI(const SessionLease& session, const std::string& key,
    const sony2fuji::RAWBayerSource& metadata);
sony2fuji_hsl_probe* makeHDRHslProbe(sony2fuji::ImageData image, uint64_t sourceRevision, uint64_t requestRevision, bool preview);
