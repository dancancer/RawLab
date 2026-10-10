#include "compute_denoise.h"
#include "compute_denoise_shader.h"
#include <EGL/egl.h>
#include <GLES3/gl31.h>
#include <algorithm>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>

namespace sony2fuji {
namespace {
constexpr GLuint groupSize = 128;
void checked() {
    const auto error = glGetError();
    if (error != GL_NO_ERROR) throw std::runtime_error("GLES filter error " + std::to_string(error));
}
struct Binding final : FilterContext {
    EGLDisplay previousDisplay = eglGetCurrentDisplay();
    EGLContext previousContext = eglGetCurrentContext();
    EGLSurface previousRead = eglGetCurrentSurface(EGL_READ), previousDraw = eglGetCurrentSurface(EGL_DRAW);
    EGLenum previousApi = eglQueryAPI();
    EGLDisplay display;
    Binding(EGLDisplay d, EGLSurface surface, EGLContext context) : display(d) {
        if (!eglBindAPI(EGL_OPENGL_ES_API) || !eglMakeCurrent(d, surface, surface, context)) {
            eglBindAPI(previousApi);
            throw std::runtime_error("GLES filter context unavailable");
        }
    }
    ~Binding() override {
        if (previousContext != EGL_NO_CONTEXT) eglMakeCurrent(previousDisplay, previousDraw, previousRead, previousContext);
        else eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglBindAPI(previousApi);
    }
};
struct Buffer final : FilterBuffer {
    GLuint name = 0;
    ~Buffer() override { if (name) glDeleteBuffers(1, &name); }
};

const char* prefix = R"glsl(#version 310 es
precision highp float;
precision highp int;
#define V3 vec3
layout(local_size_x = 128) in;
layout(std430, binding = 0) readonly buffer SourceA { float sourceA[]; };
layout(std430, binding = 1) readonly buffer SourceB { float sourceB[]; };
layout(std430, binding = 2) writeonly buffer OutputA { float outputA[]; };
layout(std430, binding = 3) writeonly buffer OutputB { float outputB[]; };
layout(std140, binding = 0) uniform Parameters {
    uint width, height, step, level;
    uint channels, radius, stage, count;
    float sigma, strength, epsilon;
    uint direction;
    uint sourceRow, outputRow, baseIndex, reserved;
    vec4 vignette, grain;
};
float readA(uint i) { return sourceA[i]; }
float readB(uint i) { return sourceB[i]; }
void writeA(uint i, float value) { outputA[i] = value; }
void writeB(uint i, float value) { outputB[i] = value; }
)glsl";

class Device final : public FilterDevice {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    GLuint program = 0, constants = 0;
    FilterBufferPtr dummy;
    size_t blockLimit = 0;
    uint32_t dispatchLimit = 0;
public:
    ~Device() override {
        if (context != EGL_NO_CONTEXT) {
            try {
                auto scope = activate();
                dummy.reset();
                if (constants) glDeleteBuffers(1, &constants);
                if (program) glDeleteProgram(program);
            } catch (...) { }
            eglDestroyContext(display, context);
        }
        if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
        // Never terminate Android's process-wide display, shared with HWUI.
    }
    void initialize() {
        display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr)) throw std::runtime_error("EGL filter display unavailable");
        const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE};
        EGLConfig config{}; EGLint count = 0;
        if (!eglChooseConfig(display, attributes, &config, 1, &count) || count == 0) throw std::runtime_error("EGL filter config unavailable");
        const EGLint surfaceAttributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
        const EGLint contextAttributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        const auto previousApi = eglQueryAPI();
        eglBindAPI(EGL_OPENGL_ES_API);
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
        eglBindAPI(previousApi);
        auto scope = activate();
        GLint major = 0, minor = 0, invocations = 0, size = 0, groups = 0, blocks = 0;
        GLint64 bytes = 0;
        glGetIntegerv(GL_MAJOR_VERSION, &major); glGetIntegerv(GL_MINOR_VERSION, &minor);
        glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &invocations);
        glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, 0, &size);
        glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, &groups);
        glGetIntegerv(GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS, &blocks);
        glGetInteger64v(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &bytes);
        if (major < 3 || (major == 3 && minor < 1) || invocations < int(groupSize) || size < int(groupSize) ||
            groups <= 0 || blocks < 4 || bytes <= 0) throw std::runtime_error("GLES 3.1 filter limits unavailable");
        blockLimit = static_cast<size_t>(bytes);
        dispatchLimit = static_cast<uint32_t>(std::min<uint64_t>(uint64_t(groups) * groupSize, UINT32_MAX));
        const std::string source = std::string(prefix) + kFilterShaderBody +
            "\nvoid main() { filterPixel(baseIndex + gl_GlobalInvocationID.x); }\n";
        const char* text = source.c_str();
        const auto shader = glCreateShader(GL_COMPUTE_SHADER);
        glShaderSource(shader, 1, &text, nullptr); glCompileShader(shader);
        GLint ok = 0; glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
        if (!ok) {
            char log[4096]{}; glGetShaderInfoLog(shader, sizeof(log), nullptr, log); glDeleteShader(shader);
            throw std::runtime_error(std::string("GLES filter shader: ") + log);
        }
        program = glCreateProgram(); glAttachShader(program, shader); glLinkProgram(program); glDeleteShader(shader);
        glGetProgramiv(program, GL_LINK_STATUS, &ok);
        if (!ok) throw std::runtime_error("GLES filter shader link failed");
        glGenBuffers(1, &constants); glBindBuffer(GL_UNIFORM_BUFFER, constants);
        glBufferData(GL_UNIFORM_BUFFER, sizeof(FilterParams), nullptr, GL_DYNAMIC_DRAW);
        dummy = allocate(1);
        checked();
    }
    std::unique_ptr<FilterContext> activate() override {
        if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT) throw std::runtime_error("GLES filter initialization failed");
        return std::make_unique<Binding>(display, surface, context);
    }
    FilterBufferPtr allocate(size_t count, const float* input = nullptr) override {
        if (!count || count > blockLimit / sizeof(float)) throw std::runtime_error("GLES filter buffer exceeds device limit");
        auto buffer = std::make_unique<Buffer>();
        glGenBuffers(1, &buffer->name); glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffer->name);
        glBufferData(GL_SHADER_STORAGE_BUFFER, static_cast<GLsizeiptr>(count * sizeof(float)), input, GL_DYNAMIC_COPY);
        checked();
        return buffer;
    }
    void dispatch(FilterParams params, FilterBuffer& source, FilterBuffer* other,
                  FilterBuffer& output, FilterBuffer* second = nullptr) override {
        glUseProgram(program);
        FilterBuffer* buffers[] = {&source, other ? other : dummy.get(), &output, second ? second : dummy.get()};
        for (GLuint i = 0; i < 4; ++i) glBindBufferBase(GL_SHADER_STORAGE_BUFFER, i, static_cast<Buffer*>(buffers[i])->name);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, constants);
        for (uint32_t offset = 0; offset < params.count;) {
            const uint32_t chunk = std::min(dispatchLimit, params.count - offset);
            params.baseIndex = offset;
            glBindBuffer(GL_UNIFORM_BUFFER, constants);
            glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(params), &params);
            glDispatchCompute((chunk + groupSize - 1) / groupSize, 1, 1);
            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);
            checked(); offset += chunk;
        }
        for (GLuint i = 0; i < 4; ++i) glBindBufferBase(GL_SHADER_STORAGE_BUFFER, i, 0);
    }
    void read(FilterBuffer& buffer, size_t count, float* output) override {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, static_cast<Buffer&>(buffer).name);
        const auto bytes = static_cast<GLsizeiptr>(count * sizeof(float));
        const auto mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, bytes, GL_MAP_READ_BIT);
        if (!mapped) throw std::runtime_error("GLES filter readback failed");
        std::memcpy(output, mapped, static_cast<size_t>(bytes));
        if (!glUnmapBuffer(GL_SHADER_STORAGE_BUFFER)) throw std::runtime_error("GLES filter buffer contents lost");
        checked();
    }
};
} // namespace
std::unique_ptr<FilterDevice> createGlesFilterDevice() {
    auto device = std::make_unique<Device>(); device->initialize(); return device;
}
} // namespace sony2fuji
