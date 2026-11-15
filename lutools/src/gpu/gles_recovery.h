#pragma once

#include "device_retry.h"
#include <EGL/egl.h>
#include <GLES3/gl31.h>
#include <stdexcept>
#include <string>
#if defined(RAWLAB_GLES_TESTING)
#include "gles_test_hooks.h"
#endif

#ifndef GL_CONTEXT_LOST
#define GL_CONTEXT_LOST 0x0507
#endif

namespace sony2fuji {

class GlesFailure : public std::runtime_error {
public:
    explicit GlesFailure(GLenum code)
        : std::runtime_error("OpenGL error " + std::to_string(code)), code_(code) {}
    bool deviceLost() const { return code_ == GL_CONTEXT_LOST; }
    GLenum code() const { return code_; }
private:
    GLenum code_;
};

class EglFailure : public std::runtime_error {
public:
    explicit EglFailure(EGLint code)
        : std::runtime_error("EGL operation failed: " + std::to_string(code)), code_(code) {}
    // EGL_BAD_ACCESS indicates transient thread contention rather than a lost context.
    bool deviceLost() const { return code_ != EGL_BAD_ACCESS; }
    EGLint code() const { return code_; }
private:
    EGLint code_;
};

inline DeviceRetry::Clock::time_point glesRetryNow() {
#if defined(RAWLAB_GLES_TESTING)
    return gles_test::now;
#else
    return DeviceRetry::Clock::now();
#endif
}

inline bool glesLostDevice(const std::exception& error) {
    if (const auto* gl = dynamic_cast<const GlesFailure*>(&error)) return gl->deviceLost();
    if (const auto* egl = dynamic_cast<const EglFailure*>(&error)) return egl->deviceLost();
    return false;
}

} // namespace sony2fuji
