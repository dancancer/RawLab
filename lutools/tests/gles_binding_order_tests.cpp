#include <EGL/egl.h>
#include "gpu/compute_denoise.h"

#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
const auto callerDisplay = reinterpret_cast<EGLDisplay>(1);
const auto callerContext = reinterpret_cast<EGLContext>(2);
const auto callerDraw = reinterpret_cast<EGLSurface>(3);
const auto callerRead = reinterpret_cast<EGLSurface>(4);
const auto lutDisplay = reinterpret_cast<EGLDisplay>(5);
const auto lutContext = reinterpret_cast<EGLContext>(6);
const auto lutSurface = reinterpret_cast<EGLSurface>(7);
EGLenum api;
struct Current {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface draw = EGL_NO_SURFACE, read = EGL_NO_SURFACE;
};
Current gl, vg, none;
EGLenum callerApi;
bool failBind, failMakeCurrent;
int invalidApiBinds;

Current& current(EGLenum selected) {
    if (selected == EGL_OPENVG_API) return vg;
    if (selected == EGL_OPENGL_API || selected == EGL_OPENGL_ES_API) return gl;
    return none;
}
std::vector<std::string> calls;

void require(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << std::endl;
        std::exit(1);
    }
}
}

extern "C" {
EGLDisplay eglGetCurrentDisplay() { return current(api).display; }
EGLContext eglGetCurrentContext() { return current(api).context; }
EGLSurface eglGetCurrentSurface(EGLint which) { return which == EGL_READ ? current(api).read : current(api).draw; }
EGLenum eglQueryAPI() { return api; }
EGLBoolean eglBindAPI(EGLenum value) {
    calls.emplace_back("api");
    if (value == EGL_NONE) {
        ++invalidApiBinds;
        return EGL_FALSE;
    }
    if (failBind) {
        failBind = false;
        return EGL_FALSE;
    }
    api = value;
    return EGL_TRUE;
}
EGLBoolean eglMakeCurrent(EGLDisplay value, EGLSurface newDraw, EGLSurface newRead, EGLContext newContext) {
    calls.emplace_back("context");
    if (failMakeCurrent) {
        failMakeCurrent = false;
        return EGL_FALSE;
    }
    // EGL 1.5 3.7.3：非空 ctx 决定 API；只有解绑才由当前 API 选择槽位。
    // GL/ES 共用一个槽位，OpenVG 使用独立槽位。
    auto& state = current(newContext == EGL_NO_CONTEXT ? api :
                          (newContext == callerContext ? callerApi : EGL_OPENGL_ES_API));
    state = {newContext == EGL_NO_CONTEXT ? EGL_NO_DISPLAY : value, newContext, newDraw, newRead};
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
    for (EGLenum selected : {EGL_OPENGL_API, EGL_OPENGL_ES_API, EGL_OPENVG_API, EGL_NONE}) {
        for (bool hasContext : {true, false}) {
            if (selected == EGL_NONE && hasContext) continue;
            for (int failure : {0, 1, 2}) {
                callerApi = api = selected;
                gl = vg = none = {};
                current(api) = {hasContext ? callerDisplay : EGL_NO_DISPLAY,
                                hasContext ? callerContext : EGL_NO_CONTEXT,
                                hasContext ? callerDraw : EGL_NO_SURFACE,
                                hasContext ? callerRead : EGL_NO_SURFACE};
                failBind = failure == 1;
                failMakeCurrent = failure == 2;
                invalidApiBinds = 0;
                bool threw = false;
                auto enterScope = [&] {
                    if (!failure) {
                        require(api == EGL_OPENGL_ES_API && gl.context == lutContext, "scope activates GLES context");
                    }
                    calls.clear();
                };
                try {
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
                } catch (const std::runtime_error&) {
                    threw = true;
                }
                require(threw == (kind == "denoise" && failure != 0), "only failed denoise construction throws");
                if (!failure) {
                    std::vector<std::string> expected{"context"};
                    if (selected != EGL_NONE) expected.emplace_back("api");
                    if (hasContext) expected.emplace_back("context");
                    require(calls == expected, "unbind GLES before restoring caller API and nonempty context");
                }
                require(invalidApiBinds == 0, "never pass EGL_NONE to eglBindAPI");
                // EGL_NONE 不是可恢复的 API；成功切到 ES 后保留 ES 选择，但不得残留 context。
                const EGLenum expectedApi = selected != EGL_NONE || failure == 1 ? selected : EGL_OPENGL_ES_API;
                require(api == expectedApi, "restore valid caller API");
                const auto& state = current(api);
                require(state.context == (hasContext ? callerContext : EGL_NO_CONTEXT), "caller context restored");
                require(state.display == (hasContext ? callerDisplay : EGL_NO_DISPLAY), "caller display restored");
                require(state.draw == (hasContext ? callerDraw : EGL_NO_SURFACE), "caller draw surface restored");
                require(state.read == (hasContext ? callerRead : EGL_NO_SURFACE), "caller read surface restored");
                require(gl.context != lutContext, "GLES context released for the next worker thread");
            }
        }
    }
    return 0;
}
