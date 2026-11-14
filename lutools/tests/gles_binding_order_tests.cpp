#include <EGL/egl.h>
#include "gpu/compute_denoise.h"

#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr EGLenum callerApi = EGL_OPENGL_API;
const auto callerDisplay = reinterpret_cast<EGLDisplay>(1);
const auto callerContext = reinterpret_cast<EGLContext>(2);
const auto callerDraw = reinterpret_cast<EGLSurface>(3);
const auto callerRead = reinterpret_cast<EGLSurface>(4);
const auto lutDisplay = reinterpret_cast<EGLDisplay>(5);
const auto lutContext = reinterpret_cast<EGLContext>(6);
const auto lutSurface = reinterpret_cast<EGLSurface>(7);
EGLenum api;
EGLDisplay display;
EGLContext context;
EGLSurface draw, read;
std::vector<std::string> calls;

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << std::endl;
        std::exit(1);
    }
}
}

extern "C" {
EGLDisplay eglGetCurrentDisplay() { return display; }
EGLContext eglGetCurrentContext() { return context; }
EGLSurface eglGetCurrentSurface(EGLint which) { return which == EGL_READ ? read : draw; }
EGLenum eglQueryAPI() { return api; }
EGLBoolean eglBindAPI(EGLenum value) {
    calls.emplace_back("api");
    api = value;
    return EGL_TRUE;
}
EGLBoolean eglMakeCurrent(EGLDisplay value, EGLSurface newDraw, EGLSurface newRead, EGLContext newContext) {
    calls.emplace_back("context");
    // 调用方的 OpenGL context 只有在恢复其 client API 后才能重新绑定。
    if (newContext == callerContext && api != callerApi) return EGL_FALSE;
    display = newContext == EGL_NO_CONTEXT ? EGL_NO_DISPLAY : value;
    context = newContext;
    draw = newDraw;
    read = newRead;
    return EGL_TRUE;
}
}

// 仅提供 Binding 所依赖的类型；RAII 实现由构建步骤从三个生产文件原样提取。
using sony2fuji::FilterContext;
struct GlesContext {
    EGLDisplay display;
    EGLSurface surface;
    EGLContext context;
};
#include "gles_binding_order_bindings.h"

int main(int argc, char** argv) {
    require(argc == 2, "select LUT, photo or denoise Binding");
    const std::string kind = argv[1];
    for (bool hasContext : {true, false}) {
        api = callerApi;
        display = hasContext ? callerDisplay : EGL_NO_DISPLAY;
        context = hasContext ? callerContext : EGL_NO_CONTEXT;
        draw = hasContext ? callerDraw : EGL_NO_SURFACE;
        read = hasContext ? callerRead : EGL_NO_SURFACE;
        auto enterScope = [&] {
            require(api == EGL_OPENGL_ES_API && context == lutContext, "scope activates GLES context");
            calls.clear();
        };
        if (kind == "lut") {
            lut_binding::Binding binding(GlesContext{lutDisplay, lutSurface, lutContext});
            enterScope();
        } else if (kind == "photo") {
            photo_binding::Binding binding(lutDisplay, lutSurface, lutContext);
            enterScope();
        } else if (kind == "denoise") {
            denoise_binding::Binding binding(lutDisplay, lutSurface, lutContext);
            enterScope();
        } else {
            require(false, "unknown Binding");
        }
        require(calls == std::vector<std::string>{"api", "context"},
                "Binding destructor restores client API before context");
        require(api == callerApi, "caller API restored");
        require(context == (hasContext ? callerContext : EGL_NO_CONTEXT), "caller context restored");
        require(display == (hasContext ? callerDisplay : EGL_NO_DISPLAY), "caller display restored");
        require(draw == (hasContext ? callerDraw : EGL_NO_SURFACE), "caller draw surface restored");
        require(read == (hasContext ? callerRead : EGL_NO_SURFACE), "caller read surface restored");
    }
    return 0;
}
