#include "sony2fuji/gpu/lut_gpu.h"
#include "sony2fuji/lut_applicator.h"

#include <EGL/egl.h>
#include <GLES3/gl31.h>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <vector>

namespace sony2fuji {
bool applyLutGles(const LUT3D& lut, ImageData& image, size_t* completedPixels = nullptr);
}

namespace {

thread_local size_t failAllocationBytes = 0;
int injectedAllocations = 0;

} // namespace

// 仅在此独立测试可执行文件内按目标字节数注入分配异常，验证 RAII 异常路径恢复。
void* operator new(std::size_t size) {
    if (failAllocationBytes != 0 && size == failAllocationBytes) {
        failAllocationBytes = 0;
        ++injectedAllocations;
        throw std::bad_alloc();
    }
    if (void* result = std::malloc(size ? size : 1)) {
        return result;
    }
    throw std::bad_alloc();
}
void* operator new[](std::size_t size) { return ::operator new(size); }
void operator delete(void* value) noexcept { std::free(value); }
void operator delete[](void* value) noexcept { std::free(value); }
void operator delete(void* value, std::size_t) noexcept { std::free(value); }
void operator delete[](void* value, std::size_t) noexcept { std::free(value); }

#ifdef SONY2FUJI_FAKE_EGL_GLES
// 宿主机无 EGL/GLES 运行时时使用替身，仅验证上下文绑定/恢复与单线程归属约束，不代表真机 GLES 硬件验证。
namespace {

struct FakeContextData {
    GLenum error = GL_NO_ERROR;
    GLuint nextObject = 1;
    GLuint boundTexture = 0;
    GLuint boundBuffer = 0;
    GLuint ssboBinding0 = 0;
    GLint pixelCount = 0;
    GLint lutSize = 0;
    std::map<GLuint, std::vector<float>> textures;
    std::map<GLuint, int> textureSizes;
    std::map<GLuint, std::vector<unsigned char>> buffers;
};

struct FakeEglDriver {
    std::mutex mutex;
    uintptr_t nextHandle = 0x1000;
    std::map<EGLContext, std::thread::id> activeOwners;
    std::map<EGLContext, FakeContextData> contexts;
    GLint majorVersion = 3;
    GLint minorVersion = 1;
    bool failNextMakeCurrent = false;
    bool failTexImage3D = false;
    bool failUnmap = false;
    size_t dispatchCount = 0;
    // 非零时让第 N 次派发返回 GL 错误，用于瓦片级失败注入。
    size_t failDispatchAfter = 0;
    EGLContext lastDeletedResourceContext = EGL_NO_CONTEXT;
};

FakeEglDriver& driver() {
    static FakeEglDriver instance;
    return instance;
}

struct FakeThreadTls {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface draw = EGL_NO_SURFACE;
    EGLSurface read = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;
    EGLenum api = EGL_OPENGL_ES_API;
    EGLint error = EGL_SUCCESS;
};

FakeThreadTls& tls() {
    thread_local FakeThreadTls state;
    return state;
}

FakeContextData* activeContext() {
    auto& state = tls();
    if (state.context == EGL_NO_CONTEXT || state.api != EGL_OPENGL_ES_API) {
        return nullptr;
    }
    auto& drv = driver();
    std::lock_guard<std::mutex> lock(drv.mutex);
    auto it = drv.contexts.find(state.context);
    return it == drv.contexts.end() ? nullptr : &it->second;
}

} // namespace

extern "C" {

EGLDisplay eglGetDisplay(EGLNativeDisplayType) {
    return reinterpret_cast<EGLDisplay>(static_cast<uintptr_t>(1));
}

EGLBoolean eglInitialize(EGLDisplay dpy, EGLint* major, EGLint* minor) {
    if (dpy == EGL_NO_DISPLAY) return EGL_FALSE;
    if (major) *major = 1;
    if (minor) *minor = 5;
    return EGL_TRUE;
}

EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint*, EGLConfig* configs, EGLint config_size, EGLint* num_config) {
    if (dpy == EGL_NO_DISPLAY || !num_config) return EGL_FALSE;
    *num_config = 1;
    if (configs && config_size > 0) {
        configs[0] = reinterpret_cast<EGLConfig>(static_cast<uintptr_t>(0x10));
    }
    return EGL_TRUE;
}

EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config, const EGLint*) {
    if (dpy == EGL_NO_DISPLAY || !config) return EGL_NO_SURFACE;
    auto& drv = driver();
    std::lock_guard<std::mutex> lock(drv.mutex);
    return reinterpret_cast<EGLSurface>(drv.nextHandle++);
}

EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext, const EGLint*) {
    if (dpy == EGL_NO_DISPLAY || !config) return EGL_NO_CONTEXT;
    auto& drv = driver();
    std::lock_guard<std::mutex> lock(drv.mutex);
    EGLContext ctx = reinterpret_cast<EGLContext>(drv.nextHandle++);
    drv.contexts.emplace(ctx, FakeContextData{});
    return ctx;
}

EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx) {
    if (dpy == EGL_NO_DISPLAY || ctx == EGL_NO_CONTEXT) return EGL_FALSE;
    auto& drv = driver();
    std::lock_guard<std::mutex> lock(drv.mutex);
    drv.activeOwners.erase(ctx);
    drv.contexts.erase(ctx);
    return EGL_TRUE;
}

EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surface) {
    return (dpy != EGL_NO_DISPLAY && surface != EGL_NO_SURFACE) ? EGL_TRUE : EGL_FALSE;
}

EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx) {
    auto& state = tls();
    if (dpy == EGL_NO_DISPLAY) {
        state.error = EGL_BAD_PARAMETER;
        return EGL_FALSE;
    }
    auto& drv = driver();
    std::lock_guard<std::mutex> lock(drv.mutex);
    if (drv.failNextMakeCurrent) {
        drv.failNextMakeCurrent = false;
        state.error = EGL_BAD_ACCESS;
        return EGL_FALSE;
    }
    if (ctx == EGL_NO_CONTEXT) {
        if (draw != EGL_NO_SURFACE || read != EGL_NO_SURFACE) {
            state.error = EGL_BAD_MATCH;
            return EGL_FALSE;
        }
        if (state.context != EGL_NO_CONTEXT) {
            drv.activeOwners.erase(state.context);
        }
        state.display = EGL_NO_DISPLAY;
        state.draw = EGL_NO_SURFACE;
        state.read = EGL_NO_SURFACE;
        state.context = EGL_NO_CONTEXT;
        state.error = EGL_SUCCESS;
        return EGL_TRUE;
    }
    auto owner = drv.activeOwners.find(ctx);
    if (owner != drv.activeOwners.end() && owner->second != std::this_thread::get_id()) {
        state.error = EGL_BAD_ACCESS;
        return EGL_FALSE;
    }
    if (drv.contexts.find(ctx) == drv.contexts.end()) {
        state.error = EGL_BAD_PARAMETER;
        return EGL_FALSE;
    }
    if (state.context != EGL_NO_CONTEXT && state.context != ctx) {
        drv.activeOwners.erase(state.context);
    }
    drv.activeOwners[ctx] = std::this_thread::get_id();
    state.display = dpy;
    state.draw = draw;
    state.read = read;
    state.context = ctx;
    state.error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLDisplay eglGetCurrentDisplay(void) { return tls().display; }
EGLSurface eglGetCurrentSurface(EGLint readdraw) {
    if (readdraw == EGL_DRAW) return tls().draw;
    if (readdraw == EGL_READ) return tls().read;
    return EGL_NO_SURFACE;
}
EGLContext eglGetCurrentContext(void) { return tls().context; }

EGLBoolean eglBindAPI(EGLenum api) {
    if (api != EGL_OPENGL_ES_API && api != EGL_OPENGL_API) {
        tls().error = EGL_BAD_PARAMETER;
        return EGL_FALSE;
    }
    tls().api = api;
    tls().error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLenum eglQueryAPI(void) { return tls().api; }
EGLint eglGetError(void) {
    const EGLint err = tls().error;
    tls().error = EGL_SUCCESS;
    return err;
}

GLuint glCreateShader(GLenum) {
    auto* ctx = activeContext();
    return ctx ? ctx->nextObject++ : 0;
}
void glShaderSource(GLuint, GLsizei, const GLchar* const*, const GLint*) {}
void glCompileShader(GLuint) {}
void glGetShaderiv(GLuint shader, GLenum pname, GLint* params) {
    if (params && pname == GL_COMPILE_STATUS) *params = shader ? GL_TRUE : GL_FALSE;
}
void glDeleteShader(GLuint) {}

GLuint glCreateProgram(void) {
    auto* ctx = activeContext();
    return ctx ? ctx->nextObject++ : 0;
}
void glAttachShader(GLuint, GLuint) {}
void glLinkProgram(GLuint) {}
void glGetProgramiv(GLuint program, GLenum pname, GLint* params) {
    if (params && pname == GL_LINK_STATUS) *params = program ? GL_TRUE : GL_FALSE;
}
void glDeleteProgram(GLuint) {}
void glUseProgram(GLuint) {}

GLint glGetUniformLocation(GLuint, const GLchar* name) {
    if (!activeContext() || !name) return -1;
    if (std::strcmp(name, "pixel_count") == 0) return 0;
    if (std::strcmp(name, "lut_size") == 0) return 1;
    if (std::strcmp(name, "lut") == 0) return 2;
    return -1;
}

void glUniform1i(GLint location, GLint v0) {
    auto* ctx = activeContext();
    if (!ctx) return;
    if (location == 0) ctx->pixelCount = v0;
    if (location == 1) ctx->lutSize = v0;
}

void glGetIntegerv(GLenum pname, GLint* data) {
    auto* ctx = activeContext();
    if (!ctx || !data) return;
    auto& drv = driver();
    if (pname == GL_MAJOR_VERSION) *data = drv.majorVersion;
    else if (pname == GL_MINOR_VERSION) *data = drv.minorVersion;
    else if (pname == GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS) *data = 256;
    else if (pname == GL_MAX_3D_TEXTURE_SIZE) *data = 65;
}

void glGetIntegeri_v(GLenum target, GLuint, GLint* data) {
    if (!activeContext() || !data) return;
    if (target == GL_MAX_COMPUTE_WORK_GROUP_SIZE) *data = 256;
    else if (target == GL_MAX_COMPUTE_WORK_GROUP_COUNT) *data = 1024;
}

void glGetInteger64v(GLenum pname, GLint64* data) {
    if (!activeContext() || !data) return;
    if (pname == GL_MAX_SHADER_STORAGE_BLOCK_SIZE) *data = 16 * 1024 * 1024;
}

GLenum glGetError(void) {
    auto* ctx = activeContext();
    if (!ctx) return GL_NO_ERROR;
    const GLenum err = ctx->error;
    ctx->error = GL_NO_ERROR;
    return err;
}

void glGenTextures(GLsizei n, GLuint* textures) {
    auto* ctx = activeContext();
    if (!ctx || !textures) return;
    for (GLsizei i = 0; i < n; ++i) textures[i] = ctx->nextObject++;
}

void glBindTexture(GLenum, GLuint texture) {
    if (auto* ctx = activeContext()) ctx->boundTexture = texture;
}
void glTexParameteri(GLenum, GLenum, GLint) {}
void glPixelStorei(GLenum, GLint) {}

void glTexImage3D(GLenum, GLint, GLint, GLsizei width, GLsizei height, GLsizei depth, GLint, GLenum, GLenum, const void* pixels) {
    auto* ctx = activeContext();
    if (!ctx) return;
    if (driver().failTexImage3D || width <= 0 || width != height || width != depth || !pixels) {
        ctx->error = GL_INVALID_VALUE;
        return;
    }
    const size_t count = static_cast<size_t>(width) * height * depth * 4;
    const auto* src = static_cast<const float*>(pixels);
    ctx->textures[ctx->boundTexture].assign(src, src + count);
    ctx->textureSizes[ctx->boundTexture] = width;
}

void glActiveTexture(GLenum) {}

void glDeleteTextures(GLsizei n, const GLuint* textures) {
    auto* ctx = activeContext();
    if (!ctx || !textures) return;
    driver().lastDeletedResourceContext = tls().context;
    for (GLsizei i = 0; i < n; ++i) {
        ctx->textures.erase(textures[i]);
        ctx->textureSizes.erase(textures[i]);
    }
}

void glGenBuffers(GLsizei n, GLuint* buffers) {
    auto* ctx = activeContext();
    if (!ctx || !buffers) return;
    for (GLsizei i = 0; i < n; ++i) buffers[i] = ctx->nextObject++;
}

void glBindBuffer(GLenum, GLuint buffer) {
    if (auto* ctx = activeContext()) ctx->boundBuffer = buffer;
}

void glBindBufferBase(GLenum, GLuint index, GLuint buffer) {
    if (auto* ctx = activeContext(); ctx && index == 0) ctx->ssboBinding0 = buffer;
}

void glBufferData(GLenum, GLsizeiptr size, const void* data, GLenum) {
    auto* ctx = activeContext();
    if (!ctx) return;
    if (size < 0) {
        ctx->error = GL_INVALID_VALUE;
        return;
    }
    auto& buf = ctx->buffers[ctx->boundBuffer];
    buf.resize(static_cast<size_t>(size));
    if (data && size > 0) std::memcpy(buf.data(), data, static_cast<size_t>(size));
}

void glBufferSubData(GLenum, GLintptr offset, GLsizeiptr size, const void* data) {
    auto* ctx = activeContext();
    if (!ctx) return;
    auto& buf = ctx->buffers[ctx->boundBuffer];
    if (offset < 0 || size < 0 || static_cast<size_t>(offset + size) > buf.size() || !data) {
        ctx->error = GL_INVALID_VALUE;
        return;
    }
    std::memcpy(buf.data() + offset, data, static_cast<size_t>(size));
}

void* glMapBufferRange(GLenum, GLintptr offset, GLsizeiptr length, GLbitfield) {
    auto* ctx = activeContext();
    if (!ctx) return nullptr;
    auto& buf = ctx->buffers[ctx->boundBuffer];
    if (offset < 0 || length < 0 || static_cast<size_t>(offset + length) > buf.size()) {
        ctx->error = GL_INVALID_VALUE;
        return nullptr;
    }
    return buf.data() + offset;
}

GLboolean glUnmapBuffer(GLenum) {
    if (!activeContext()) return GL_FALSE;
    return driver().failUnmap ? GL_FALSE : GL_TRUE;
}

void glDeleteBuffers(GLsizei n, const GLuint* buffers) {
    auto* ctx = activeContext();
    if (!ctx || !buffers) return;
    driver().lastDeletedResourceContext = tls().context;
    for (GLsizei i = 0; i < n; ++i) ctx->buffers.erase(buffers[i]);
}

void glDispatchCompute(GLuint, GLuint, GLuint) {
    auto* ctx = activeContext();
    if (!ctx) return;
    ++driver().dispatchCount;
    if (driver().failDispatchAfter != 0 && driver().dispatchCount == driver().failDispatchAfter) {
        ctx->error = GL_INVALID_OPERATION;
        return;
    }
    auto bufIt = ctx->buffers.find(ctx->ssboBinding0);
    auto texIt = ctx->textures.find(ctx->boundTexture);
    if (bufIt == ctx->buffers.end() || texIt == ctx->textures.end() || ctx->lutSize <= 1) {
        ctx->error = GL_INVALID_OPERATION;
        return;
    }
    auto* data = reinterpret_cast<float*>(bufIt->second.data());
    const auto& tex = texIt->second;
    const int n = ctx->lutSize;
    auto fetch = [&](int r, int g, int b, int c) {
        return tex[(static_cast<size_t>(b * n + g) * n + r) * 4 + c];
    };
    for (int idx = 0; idx < ctx->pixelCount; ++idx) {
        float col[3] = {
            std::clamp(data[idx * 3], 0.0f, 1.0f) * float(n - 1),
            std::clamp(data[idx * 3 + 1], 0.0f, 1.0f) * float(n - 1),
            std::clamp(data[idx * 3 + 2], 0.0f, 1.0f) * float(n - 1),
        };
        int i0[3], i1[3];
        float f[3];
        for (int c = 0; c < 3; ++c) {
            i0[c] = static_cast<int>(std::floor(col[c]));
            i1[c] = std::min(i0[c] + 1, n - 1);
            f[c] = col[c] - float(i0[c]);
        }
        for (int c = 0; c < 3; ++c) {
            const float c000 = fetch(i0[0], i0[1], i0[2], c);
            const float c001 = fetch(i0[0], i0[1], i1[2], c);
            const float c010 = fetch(i0[0], i1[1], i0[2], c);
            const float c011 = fetch(i0[0], i1[1], i1[2], c);
            const float c100 = fetch(i1[0], i0[1], i0[2], c);
            const float c101 = fetch(i1[0], i0[1], i1[2], c);
            const float c110 = fetch(i1[0], i1[1], i0[2], c);
            const float c111 = fetch(i1[0], i1[1], i1[2], c);
            const float c00 = c000 + (c001 - c000) * f[2];
            const float c01 = c010 + (c011 - c010) * f[2];
            const float c10 = c100 + (c101 - c100) * f[2];
            const float c11 = c110 + (c111 - c110) * f[2];
            const float c0 = c00 + (c01 - c00) * f[1];
            const float c1 = c10 + (c11 - c10) * f[1];
            data[idx * 3 + c] = c0 + (c1 - c0) * f[0];
        }
    }
}

void glMemoryBarrier(GLbitfield) {}

} // extern "C"
#endif // SONY2FUJI_FAKE_EGL_GLES

namespace {

using namespace sony2fuji;

struct EglSnapshot {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface draw = EGL_NO_SURFACE;
    EGLSurface read = EGL_NO_SURFACE;
    EGLenum api = EGL_NONE;
};

EglSnapshot captureEglState() {
    return {
        eglGetCurrentDisplay(),
        eglGetCurrentContext(),
        eglGetCurrentSurface(EGL_DRAW),
        eglGetCurrentSurface(EGL_READ),
        eglQueryAPI(),
    };
}

void require(bool condition, const std::string& label) {
    if (!condition) {
        std::cerr << "FAIL " << label << std::endl;
        std::exit(1);
    }
    std::cout << "PASS " << label << std::endl;
}

void requireSameState(const EglSnapshot& expected, const EglSnapshot& actual, const std::string& label) {
    require(actual.context == expected.context &&
            actual.display == expected.display &&
            actual.draw == expected.draw &&
            actual.read == expected.read &&
            actual.api == expected.api,
            label);
}

struct CallerEglScope {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLSurface draw = EGL_NO_SURFACE;
    EGLSurface read = EGL_NO_SURFACE;
    EGLContext context = EGL_NO_CONTEXT;

    bool initialize() {
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY || eglInitialize(display, nullptr, nullptr) != EGL_TRUE) {
            return false;
        }
        const EGLint configAttribs[] = {
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8,
            EGL_GREEN_SIZE, 8,
            EGL_BLUE_SIZE, 8,
            EGL_ALPHA_SIZE, 8,
            EGL_NONE
        };
        EGLConfig config = nullptr;
        EGLint count = 0;
        if (eglChooseConfig(display, configAttribs, &config, 1, &count) != EGL_TRUE || count == 0) {
            return false;
        }
        const EGLint drawAttribs[] = {EGL_WIDTH, 2, EGL_HEIGHT, 2, EGL_NONE};
        const EGLint readAttribs[] = {EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE};
        draw = eglCreatePbufferSurface(display, config, drawAttribs);
        read = eglCreatePbufferSurface(display, config, readAttribs);
        const EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        eglBindAPI(EGL_OPENGL_ES_API);
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, ctxAttribs);
        if (draw == EGL_NO_SURFACE || read == EGL_NO_SURFACE || draw == read || context == EGL_NO_CONTEXT) {
            return false;
        }
        return eglMakeCurrent(display, draw, read, context) == EGL_TRUE;
    }

    ~CallerEglScope() {
        if (display != EGL_NO_DISPLAY) {
            if (eglGetCurrentContext() == context && context != EGL_NO_CONTEXT) {
                eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            }
            if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
            if (draw != EGL_NO_SURFACE) eglDestroySurface(display, draw);
            if (read != EGL_NO_SURFACE) eglDestroySurface(display, read);
        }
    }
};

std::shared_ptr<LUT3D> makeTestLut(int size, const std::string& header = "") {
    std::string cube = header + "LUT_3D_SIZE " + std::to_string(size) + "\n";
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                const float rf = float(r) / float(size - 1);
                const float gf = float(g) / float(size - 1);
                const float bf = float(b) / float(size - 1);
                cube += std::to_string(0.1f + 0.8f * bf) + ' ' +
                        std::to_string(0.05f + 0.9f * rf) + ' ' +
                        std::to_string(0.2f + 0.7f * gf) + '\n';
            }
        }
    }
    auto lut = std::make_shared<LUT3D>();
    require(lut->loadFromData(cube) == ErrorCode::Success, "load synthetic 3D LUT");
    return lut;
}

ImageData makeTestImage(int width, int height) {
    ImageData img(width, height);
    for (size_t i = 0; i < img.pixels.size(); ++i) {
        img.pixels[i] = RGB(
            float((i * 13) % 101) / 100.0f,
            float((i * 29) % 97) / 96.0f,
            float((i * 43) % 89) / 88.0f
        );
    }
    return img;
}

void requireImagesClose(const ImageData& a, const ImageData& b, float tol, const std::string& label) {
    require(a.pixels.size() == b.pixels.size(), label + " pixel count");
    float maxDiff = 0.0f;
    for (size_t i = 0; i < a.pixels.size(); ++i) {
        maxDiff = std::max({
            maxDiff,
            std::abs(a.pixels[i].r - b.pixels[i].r),
            std::abs(a.pixels[i].g - b.pixels[i].g),
            std::abs(a.pixels[i].b - b.pixels[i].b),
        });
    }
    require(maxDiff <= tol, label);
}

} // namespace

int main(int argc, char** argv) {
    using namespace sony2fuji;
    const bool initFailureMode = argc >= 2 && std::string(argv[1]) == "--init-failure";

    auto lut3 = makeTestLut(3);
    auto lut5 = makeTestLut(5);
    const ImageData source = makeTestImage(64, 8);
    ImageData cpuRef = source;
    require(applyLUTWithConfig(lut3, cpuRef, {GpuMode::Off}) == ErrorCode::Success, "CPU reference render");

    if (initFailureMode) {
#ifdef SONY2FUJI_FAKE_EGL_GLES
        driver().minorVersion = 0;
        CallerEglScope caller;
        require(caller.initialize(), "create caller EGL context before initContext failure");
        const auto before = captureEglState();
        require(before.context == caller.context, "caller context active before initContext failure");

        ImageData forced = source;
        require(applyLUTWithConfig(lut3, forced, {GpuMode::Force}) == ErrorCode::ProcessingError,
                "Force fails when GLES 3.1 initContext fails");
        requireSameState(before, captureEglState(),
                         "initContext failure restores caller EGL context/surfaces/display/API");

        ImageData automatic = source;
        require(applyLUTWithConfig(lut3, automatic, {GpuMode::Auto}) == ErrorCode::Success,
                "Auto falls back to CPU when initContext fails");
        requireImagesClose(cpuRef, automatic, 1e-6f, "Auto CPU fallback output matches reference");
        requireSameState(before, captureEglState(),
                         "subsequent failed getGlesContext preserves caller EGL state");
        return 0;
#else
        std::cout << "SKIP: --init-failure requires fake EGL fault injection\n";
        return 0;
#endif
    }

    // 1. 无当前上下文的调用线程：首次初始化 + 执行后必须解绑回 EGL_NO_CONTEXT。
    {
        const auto before = captureEglState();
        require(before.context == EGL_NO_CONTEXT, "initial thread has EGL_NO_CONTEXT");
        ImageData gpu = source;
        const auto status = applyLUTWithConfig(lut3, gpu, {GpuMode::Force});
#ifndef SONY2FUJI_FAKE_EGL_GLES
        if (status != ErrorCode::Success) {
            std::cout << "SKIP: GLES 3.1 runtime unavailable on this device\n";
            return 77;
        }
#endif
        require(status == ErrorCode::Success, "Force GLES LUT succeeds from unbound thread");
        requireImagesClose(cpuRef, gpu, 2e-5f, "GLES LUT output matches CPU reference");
        const auto after = captureEglState();
        require(after.context == EGL_NO_CONTEXT, "eglGetCurrentContext restored to EGL_NO_CONTEXT");
        requireSameState(before, after, "unbound thread EGL display/surfaces/API restored");
    }

    // 1a. 自定义输入域：归一化仍走暂存拷贝（CPU 回退可见原始像素），输出与 CPU 参考一致。
    {
        auto domainLut = makeTestLut(3, "DOMAIN_MIN 0.15 0.2 0.1\nDOMAIN_MAX 0.85 0.8 0.9\n");
        ImageData domainForced = source;
        require(applyLUTWithConfig(domainLut, domainForced, {GpuMode::Force}) == ErrorCode::Success,
                "Custom-domain LUT renders through GLES");
        ImageData domainCpu = source;
        require(applyLUTWithConfig(domainLut, domainCpu, {GpuMode::Off}) == ErrorCode::Success,
                "Custom-domain LUT CPU reference renders");
        requireImagesClose(domainCpu, domainForced, 2e-5f,
                           "Custom-domain GLES output matches CPU reference");
    }

    // 1b. 单位域多瓦片失败语义：瓦片只有在完整成功后才提交回写；Auto 回退只补未提交
    // 尾部（不二次套 LUT），未提交任何瓦片的 Force 失败不留痕（含越界源像素）。
    // fake 上限：1024 组 × 256 线程 = 262144 px/瓦片。
    {
        constexpr size_t kTilePixels = 262144;
        ImageData multi(static_cast<int>(kTilePixels + 5), 1);  // 不可整除的尾块
        for (size_t i = 0; i < multi.pixels.size(); ++i) {
            const float a = float((i * 37 + 11) % 100) / 100;
            multi.pixels[i] = RGB(i == 0 ? 1.7f : a, i == 1 ? -0.3f : 1 - a, a * 0.5f);
        }
        auto unitLut = makeTestLut(3);
        ImageData multiRef = multi;
        require(applyLUTWithConfig(unitLut, multiRef, {GpuMode::Off}) == ErrorCode::Success,
                "Unit-domain multi-tile CPU reference renders");

        // Force：第 2 块派发失败——首块已提交，尾部必须原样未写。
        driver().dispatchCount = 0;
        driver().failDispatchAfter = 2;
        ImageData multiForced = multi;
        require(applyLUTWithConfig(unitLut, multiForced, {GpuMode::Force}) == ErrorCode::ProcessingError,
                "Unit-domain Force rejects second-tile failure");
        driver().failDispatchAfter = 0;
        bool tailIntact = true;
        for (size_t i = kTilePixels; i < multiForced.pixels.size() && tailIntact; ++i) {
            tailIntact = multiForced.pixels[i].r == multi.pixels[i].r &&
                multiForced.pixels[i].g == multi.pixels[i].g &&
                multiForced.pixels[i].b == multi.pixels[i].b;
        }
        require(tailIntact, "Unit-domain Force failure leaves uncommitted tail untouched");
        bool headCommitted = true;
        for (size_t i = 0; i < kTilePixels && headCommitted; ++i) {
            headCommitted = std::abs(multiForced.pixels[i].r - multiRef.pixels[i].r) <= 2e-5f &&
                std::abs(multiForced.pixels[i].g - multiRef.pixels[i].g) <= 2e-5f &&
                std::abs(multiForced.pixels[i].b - multiRef.pixels[i].b) <= 2e-5f;
        }
        require(headCommitted, "Committed first tile matches CPU reference");

        // Auto：同一故障——已提交头部 + CPU 补齐尾部，整图仍等于 CPU 参考（无二次 LUT）。
        driver().dispatchCount = 0;
        driver().failDispatchAfter = 2;
        ImageData multiAuto = multi;
        require(applyLUTWithConfig(unitLut, multiAuto, {GpuMode::Auto}) == ErrorCode::Success,
                "Unit-domain Auto falls back after second-tile failure");
        driver().failDispatchAfter = 0;
        requireImagesClose(multiRef, multiAuto, 2e-5f,
                           "Unit-domain Auto fallback recomputes only the uncommitted tail");

        // Force：unmap 失败发生在提交之前——整图逐位原样，越界像素未被原地钳制。
        ImageData unmapped = multi;
        require(applyLUTWithConfig(unitLut, unmapped, {GpuMode::Force}) == ErrorCode::Success,
                "Unit-domain Force succeeds without faults");
        ImageData unmapFail = multi;
        driver().failUnmap = true;
        const auto unmapStatus = applyLUTWithConfig(unitLut, unmapFail, {GpuMode::Force});
        driver().failUnmap = false;
        require(unmapStatus == ErrorCode::ProcessingError, "Unit-domain Force rejects unmap failure");
        bool unmapUntouched = unmapFail.pixels[0].r == 1.7f && unmapFail.pixels[1].g == -0.3f;
        for (size_t i = 0; i < unmapFail.pixels.size() && unmapUntouched; ++i) {
            unmapUntouched = unmapFail.pixels[i].r == multi.pixels[i].r &&
                unmapFail.pixels[i].g == multi.pixels[i].g &&
                unmapFail.pixels[i].b == multi.pixels[i].b;
        }
        require(unmapUntouched, "Force failure before first commit leaves source pixels untouched");

        // 提交水位契约：第 2 块失败后 completedPixels 恰为首块整块像素数。
        ImageData marked = multi;
        driver().dispatchCount = 0;
        driver().failDispatchAfter = 2;
        size_t glesCompleted = 0;
        const bool glesFailed = !applyLutGles(*unitLut, marked, &glesCompleted);
        driver().failDispatchAfter = 0;
        require(glesFailed && glesCompleted == kTilePixels,
                "applyLutGles reports the committed watermark on mid-tile failure");
    }

    // 2. 调用线程已有独立 draw/read surface 的 EGLContext：正常路径与提前失败路径都恢复原上下文。
    {
        CallerEglScope caller;
        require(caller.initialize(), "create caller EGL context with distinct draw/read surfaces");
        const auto before = captureEglState();
        require(before.context == caller.context && before.draw == caller.draw && before.read == caller.read,
                "caller context and distinct draw/read surfaces bound");

        ImageData forced = source;
        require(applyLUTWithConfig(lut3, forced, {GpuMode::Force}) == ErrorCode::Success,
                "Force GLES LUT succeeds while caller context is current");
        requireImagesClose(cpuRef, forced, 2e-5f, "GLES LUT matches CPU with caller context active");
        requireSameState(before, captureEglState(),
                         "eglGetCurrentContext and draw/read surfaces restored after Force success");
#ifdef SONY2FUJI_FAKE_EGL_GLES
        require(driver().lastDeletedResourceContext != EGL_NO_CONTEXT &&
                driver().lastDeletedResourceContext != caller.context,
                "GL temporaries deleted on GlesContext before restoring caller context");
#endif

        ImageData automatic = source;
        require(applyLUTWithConfig(lut3, automatic, {GpuMode::Auto}) == ErrorCode::Success,
                "Auto GLES LUT succeeds while caller context is current");
        requireSameState(before, captureEglState(),
                         "eglGetCurrentContext restored after Auto success");

        // 提前返回失败路径（空像素输入直接走 applyLutGles 内部 pixel_count == 0 分支）。
        ImageData empty;
        require(!applyLutGles(*lut3, empty), "applyLutGles rejects empty image");
        requireSameState(before, captureEglState(),
                         "eglGetCurrentContext restored on early return inside applyLutGles");

        // 异常路径：在 Binding 已切到 GlesContext 后，createLutTexture 分配抛出 std::bad_alloc。
        ImageData throwing = source;
        injectedAllocations = 0;
        failAllocationBytes = static_cast<size_t>(5 * 5 * 5) * 4 * sizeof(float);
        bool caughtBadAlloc = false;
        try {
            (void)applyLutGles(*lut5, throwing);
        } catch (const std::bad_alloc&) {
            caughtBadAlloc = true;
        }
        failAllocationBytes = 0;
        require(caughtBadAlloc && injectedAllocations == 1,
                "injected std::bad_alloc inside createLutTexture while GlesContext bound");
        requireSameState(before, captureEglState(),
                         "RAII Binding restores caller EGL context on exception unwind");

#ifdef SONY2FUJI_FAKE_EGL_GLES
        // eglMakeCurrent 失败路径（bound == false）：不得破坏调用方原本已绑定的上下文。
        driver().failNextMakeCurrent = true;
        ImageData bindFail = source;
        require(applyLUTWithConfig(lut3, bindFail, {GpuMode::Force}) == ErrorCode::ProcessingError,
                "Force returns ProcessingError when eglMakeCurrent fails");
        requireSameState(before, captureEglState(),
                         "failed Binding leaves caller EGL context untouched");

        // 纹理创建 GL 错误与 unmap 失败路径：保持原有错误码并恢复调用方上下文。
        driver().failTexImage3D = true;
        ImageData texFail = source;
        require(applyLUTWithConfig(lut3, texFail, {GpuMode::Force}) == ErrorCode::ProcessingError,
                "Force returns ProcessingError on texture failure");
        requireSameState(before, captureEglState(),
                         "caller EGL context restored after texture creation failure");
        require(applyLUTWithConfig(lut3, texFail, {GpuMode::Auto}) == ErrorCode::Success,
                "Auto falls back to CPU on texture failure");
        requireSameState(before, captureEglState(),
                         "caller EGL context restored after Auto fallback on texture failure");
        driver().failTexImage3D = false;

        driver().failUnmap = true;
        ImageData unmapFail = source;
        require(applyLUTWithConfig(lut3, unmapFail, {GpuMode::Force}) == ErrorCode::ProcessingError,
                "Force returns ProcessingError on buffer unmap failure");
        requireSameState(before, captureEglState(),
                         "caller EGL context restored after unmap failure");
        driver().failUnmap = false;
#endif
    }

    // 3. 无上下文线程上的异常路径，以及跨线程复用单例 GlesContext（若前序线程未解绑则会触发 EGL_BAD_ACCESS）。
    {
        require(eglGetCurrentContext() == EGL_NO_CONTEXT, "caller scope cleaned up to EGL_NO_CONTEXT");
        ImageData throwing = source;
        injectedAllocations = 0;
        failAllocationBytes = static_cast<size_t>(5 * 5 * 5) * 4 * sizeof(float);
        bool caughtBadAlloc = false;
        try {
            (void)applyLutGles(*lut5, throwing);
        } catch (const std::bad_alloc&) {
            caughtBadAlloc = true;
        }
        failAllocationBytes = 0;
        require(caughtBadAlloc && injectedAllocations == 1, "unbound thread caught std::bad_alloc");
        require(eglGetCurrentContext() == EGL_NO_CONTEXT,
                "unbound thread restored to EGL_NO_CONTEXT after exception");

        bool workerOk = false;
        std::thread worker([&]() {
            CallerEglScope workerCaller;
            if (!workerCaller.initialize()) return;
            const auto workerBefore = captureEglState();
            ImageData workerImg = source;
            if (applyLUTWithConfig(lut3, workerImg, {GpuMode::Force}) != ErrorCode::Success) return;
            const auto workerAfter = captureEglState();
            workerOk = workerAfter.context == workerBefore.context &&
                       workerAfter.display == workerBefore.display &&
                       workerAfter.draw == workerBefore.draw &&
                       workerAfter.read == workerBefore.read &&
                       workerAfter.api == workerBefore.api;
        });
        worker.join();
        require(workerOk, "second thread acquires GlesContext without EGL_BAD_ACCESS and restores its own context");
    }

    return 0;
}
