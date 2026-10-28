#include "sony2fuji/gpu/lut_gpu.h"

#include "gpu/lut_gpu_internal.h"

#include <EGL/egl.h>
#include <GLES3/gl31.h>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <vector>

namespace {

constexpr size_t kTileBytes = 16 * 1024 * 1024;
constexpr GLuint kWorkgroup = 256;
static_assert(sizeof(sony2fuji::RGB) == 3 * sizeof(float));

struct GlesContext {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    GLuint program = 0;
    GLint pixel_count_loc = -1;
    GLint lut_size_loc = -1;
    GLint lut_loc = -1;
    size_t tile_pixels = 0;
    GLint texture_limit = 0;
    bool ready = false;
};

std::mutex gles_mutex;

const char* kComputeShaderSource =
    "#version 310 es\n"
    "layout(local_size_x = 256) in;\n"
    "layout(std430, binding = 0) buffer Pixels { float data[]; };\n"
    "layout(binding = 1) uniform highp sampler3D lut;\n"
    "uniform int pixel_count;\n"
    "uniform int lut_size;\n"
    "void main() {\n"
    "    uint idx = gl_GlobalInvocationID.x;\n"
    "    if (idx >= uint(pixel_count)) return;\n"
    "    uint base = idx * 3u;\n"
    "    vec3 color = vec3(data[base], data[base + 1u], data[base + 2u]);\n"
    "    color = clamp(color, 0.0, 1.0);\n"
    "    float max_index = float(lut_size - 1);\n"
    "    vec3 scaled = color * max_index;\n"
    "    ivec3 i0 = ivec3(floor(scaled));\n"
    "    ivec3 i1 = min(i0 + ivec3(1), ivec3(lut_size - 1));\n"
    "    vec3 f = scaled - vec3(i0);\n"
    "    vec3 c000 = texelFetch(lut, i0, 0).rgb;\n"
    "    vec3 c001 = texelFetch(lut, ivec3(i0.x, i0.y, i1.z), 0).rgb;\n"
    "    vec3 c010 = texelFetch(lut, ivec3(i0.x, i1.y, i0.z), 0).rgb;\n"
    "    vec3 c011 = texelFetch(lut, ivec3(i0.x, i1.y, i1.z), 0).rgb;\n"
    "    vec3 c100 = texelFetch(lut, ivec3(i1.x, i0.y, i0.z), 0).rgb;\n"
    "    vec3 c101 = texelFetch(lut, ivec3(i1.x, i0.y, i1.z), 0).rgb;\n"
    "    vec3 c110 = texelFetch(lut, ivec3(i1.x, i1.y, i0.z), 0).rgb;\n"
    "    vec3 c111 = texelFetch(lut, i1, 0).rgb;\n"
    "    vec3 c00 = mix(c000, c001, f.z);\n"
    "    vec3 c01 = mix(c010, c011, f.z);\n"
    "    vec3 c10 = mix(c100, c101, f.z);\n"
    "    vec3 c11 = mix(c110, c111, f.z);\n"
    "    vec3 c0 = mix(c00, c01, f.y);\n"
    "    vec3 c1 = mix(c10, c11, f.y);\n"
    "    vec3 outc = mix(c0, c1, f.x);\n"
    "    data[base] = outc.r;\n"
    "    data[base + 1u] = outc.g;\n"
    "    data[base + 2u] = outc.b;\n"
    "}\n";

GLuint compileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    if (shader == 0) {
        return 0;
    }
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled == GL_FALSE) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint createProgram() {
    GLuint shader = compileShader(GL_COMPUTE_SHADER, kComputeShaderSource);
    if (!shader) {
        return 0;
    }
    GLuint program = glCreateProgram();
    if (program == 0) {
        glDeleteShader(shader);
        return 0;
    }
    glAttachShader(program, shader);
    glLinkProgram(program);
    glDeleteShader(shader);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked == GL_FALSE) {
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

bool ensureContextCurrent(const GlesContext& context) {
    return eglMakeCurrent(context.display, context.surface, context.surface, context.context) == EGL_TRUE;
}

bool initContext(GlesContext& context) {
    context.display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (context.display == EGL_NO_DISPLAY) {
        return false;
    }
    if (!eglInitialize(context.display, nullptr, nullptr)) {
        return false;
    }
    const EGLint config_attribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint num_configs = 0;
    if (!eglChooseConfig(context.display, config_attribs, &config, 1, &num_configs) ||
        num_configs == 0) {
        return false;
    }
    const EGLint pbuffer_attribs[] = {
        EGL_WIDTH, 1,
        EGL_HEIGHT, 1,
        EGL_NONE
    };
    context.surface = eglCreatePbufferSurface(context.display, config, pbuffer_attribs);
    if (context.surface == EGL_NO_SURFACE) {
        return false;
    }
    const EGLint context_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    context.context = eglCreateContext(context.display, config, EGL_NO_CONTEXT, context_attribs);
    if (context.context == EGL_NO_CONTEXT) {
        return false;
    }
    if (!ensureContextCurrent(context)) {
        return false;
    }
    GLint major = 0;
    GLint minor = 0;
    glGetIntegerv(GL_MAJOR_VERSION, &major);
    glGetIntegerv(GL_MINOR_VERSION, &minor);
    if (major < 3 || (major == 3 && minor < 1)) {
        return false;
    }
    GLint invocations = 0, group_size = 0, groups = 0;
    GLint64 block_size = 0;
    glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &invocations);
    glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, 0, &group_size);
    glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, &groups);
    glGetInteger64v(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &block_size);
    glGetIntegerv(GL_MAX_3D_TEXTURE_SIZE, &context.texture_limit);
    if (glGetError() != GL_NO_ERROR || invocations < GLint(kWorkgroup) ||
        group_size < GLint(kWorkgroup) || groups <= 0 || block_size < GLint64(sizeof(sony2fuji::RGB))) {
        return false;
    }
    // 先限制字节数，避免整张大图超过 SSBO 上限，也避免窄平台上的乘法溢出。
    const size_t tile_bytes = static_cast<size_t>(std::min<GLint64>(block_size, kTileBytes));
    context.tile_pixels = static_cast<size_t>(std::min<uint64_t>(
        tile_bytes / sizeof(sony2fuji::RGB), uint64_t(groups) * kWorkgroup));
    context.program = createProgram();
    if (context.program == 0) {
        return false;
    }
    context.pixel_count_loc = glGetUniformLocation(context.program, "pixel_count");
    context.lut_size_loc = glGetUniformLocation(context.program, "lut_size");
    context.lut_loc = glGetUniformLocation(context.program, "lut");
    context.ready = context.pixel_count_loc >= 0 && context.lut_size_loc >= 0 && context.lut_loc >= 0 &&
        glGetError() == GL_NO_ERROR;
    return context.ready;
}

GlesContext* getGlesContext() {
    static GlesContext context;
    static std::once_flag once;
    std::call_once(once, [&]() { context.ready = initContext(context); });
    return context.ready ? &context : nullptr;
}

GLuint createLutTexture(const sony2fuji::LUT3D& lut) {
    const int size = lut.getSize();
    if (size <= 1) {
        return 0;
    }
    std::vector<float> data = sony2fuji::buildLutTextureDataRGBA(lut);
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_3D, texture);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage3D(GL_TEXTURE_3D,
                 0,
                 GL_RGBA32F,
                 size,
                 size,
                 size,
                 0,
                 GL_RGBA,
                 GL_FLOAT,
                 data.data());
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) {
        glDeleteTextures(1, &texture);
        return 0;
    }
    return texture;
}

bool dispatchCompute(
    GlesContext& context,
    GLuint ssbo,
    GLuint lut_texture,
    uint32_t pixel_count,
    int lut_size,
    sony2fuji::RGB* pixels
) {
    glUseProgram(context.program);
    glUniform1i(context.pixel_count_loc, static_cast<GLint>(pixel_count));
    glUniform1i(context.lut_size_loc, lut_size);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_3D, lut_texture);
    glUniform1i(context.lut_loc, 0);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);

    if (glGetError() != GL_NO_ERROR) {
        return false;
    }
    const GLuint group_count = (pixel_count + kWorkgroup - 1u) / kWorkgroup;
    glDispatchCompute(group_count, 1, 1);
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);
    if (glGetError() != GL_NO_ERROR) {
        return false;
    }

    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    const auto bytes = static_cast<GLsizeiptr>(pixel_count * sizeof(sony2fuji::RGB));
    void* mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER,
                                    0,
                                    bytes,
                                    GL_MAP_READ_BIT);
    const auto map_error = glGetError();
    if (!mapped || map_error != GL_NO_ERROR) {
        if (mapped) glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
        return false;
    }
    std::memcpy(pixels, mapped, static_cast<size_t>(bytes));
    const auto unmapped = glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
    return glGetError() == GL_NO_ERROR && unmapped == GL_TRUE;
}

} 

namespace sony2fuji {

bool applyLutGles(const LUT3D& lut, ImageData& image) {
    std::lock_guard<std::mutex> lock(gles_mutex);
    GlesContext* context = getGlesContext();
    if (!context) {
        return false;
    }
    if (!ensureContextCurrent(*context)) {
        return false;
    }
    const size_t pixel_count = image.pixels.size();
    if (pixel_count == 0 || lut.getSize() > context->texture_limit || glGetError() != GL_NO_ERROR) {
        return false;
    }

    GLuint lut_texture = createLutTexture(lut);
    if (!lut_texture) {
        return false;
    }
    GLuint ssbo = 0;
    const size_t tile_pixels = std::min(pixel_count, context->tile_pixels);
    glGenBuffers(1, &ssbo);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    glBufferData(GL_SHADER_STORAGE_BUFFER,
                 static_cast<GLsizeiptr>(tile_pixels * sizeof(sony2fuji::RGB)),
                 nullptr,
                 GL_DYNAMIC_DRAW);

    bool ok = glGetError() == GL_NO_ERROR && ssbo != 0;
    for (size_t offset = 0; ok && offset < pixel_count; offset += tile_pixels) {
        const auto count = static_cast<uint32_t>(std::min(tile_pixels, pixel_count - offset));
        auto* pixels = image.pixels.data() + offset;
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
        glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
            static_cast<GLsizeiptr>(count * sizeof(sony2fuji::RGB)), pixels);
        ok = glGetError() == GL_NO_ERROR &&
            dispatchCompute(*context, ssbo, lut_texture, count, lut.getSize(), pixels);
    }

    glDeleteTextures(1, &lut_texture);
    glDeleteBuffers(1, &ssbo);
    return ok;
}

}
