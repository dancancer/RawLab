#include "gpu/gles_photo.h"
#include "gpu/gles_photo_shader.h"
#include "gpu/lut_gpu_internal.h"
#include "core/photo_lut.h"
#include <EGL/egl.h>
#include <GLES3/gl31.h>
#include <android/log.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>

namespace sony2fuji {
namespace {
constexpr size_t kTileBytes = 16 * 1024 * 1024;
constexpr size_t kCacheBytes = 64 * 1024 * 1024;
constexpr GLuint kWorkgroup = 128;
static_assert(sizeof(RGB) == 3 * sizeof(float));

EGLDisplay sharedDisplay() {
    // Android's display is shared with HWUI. Keep one process-level initialization;
    // session teardown must not terminate other clients' contexts on that display.
    static EGLDisplay display = EGL_NO_DISPLAY;
    static std::mutex mutex;
    std::lock_guard<std::mutex> lock(mutex);
    if (display == EGL_NO_DISPLAY) {
        auto candidate = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (candidate != EGL_NO_DISPLAY && eglInitialize(candidate, nullptr, nullptr)) display = candidate;
    }
    return display;
}

struct Binding {
    EGLDisplay previousDisplay = eglGetCurrentDisplay();
    EGLContext previousContext = eglGetCurrentContext();
    EGLSurface previousRead = eglGetCurrentSurface(EGL_READ);
    EGLSurface previousDraw = eglGetCurrentSurface(EGL_DRAW);
    EGLenum previousApi = eglQueryAPI();
    EGLDisplay display;
    bool bound;
    Binding(EGLDisplay d, EGLSurface s, EGLContext c) : display(d) {
        bound = eglBindAPI(EGL_OPENGL_ES_API) && eglMakeCurrent(d, s, s, c);
    }
    ~Binding() {
        if (bound) {
            if (previousContext != EGL_NO_CONTEXT)
                eglMakeCurrent(previousDisplay, previousDraw, previousRead, previousContext);
            else eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        eglBindAPI(previousApi);
    }
};

void checkGL() {
    const auto error = glGetError();
    if (error != GL_NO_ERROR) throw std::runtime_error("OpenGL error " + std::to_string(error));
}

GLuint makeProgram() {
    const auto shader = glCreateShader(GL_COMPUTE_SHADER);
    glShaderSource(shader, 1, &kPhotoComputeShader, nullptr);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048]{}; glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        glDeleteShader(shader);
        throw std::runtime_error(std::string("Compute shader: ") + log);
    }
    const auto program = glCreateProgram();
    glAttachShader(program, shader); glLinkProgram(program); glDeleteShader(shader);
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { glDeleteProgram(program); throw std::runtime_error("Compute program link failed"); }
    checkGL();
    return program;
}
}

struct GlesPhotoRenderer::Impl {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    GLuint program = 0, buffers[3]{}, texture = 0;
    size_t capacities[3]{}, blockLimit = 0, dispatchLimit = 0;
    GLint textureLimit = 0;
    uint64_t cachedRevision = 0;
    uint32_t cachedWidth = 0, cachedHeight = 0;
    std::shared_ptr<LUT3D> cachedLut;

    ~Impl() {
        if (context != EGL_NO_CONTEXT) {
            {
                Binding binding(display, surface, context);
                if (binding.bound) {
                    glDeleteBuffers(3, buffers);
                    if (texture) glDeleteTextures(1, &texture);
                    if (program) glDeleteProgram(program);
                }
            }
            eglDestroyContext(display, context);
        }
        if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
    }

    void initialize() {
        display = sharedDisplay();
        if (display == EGL_NO_DISPLAY) throw std::runtime_error("EGL display unavailable");
        const EGLint configAttributes[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
        EGLConfig config{}; EGLint count = 0;
        if (!eglChooseConfig(display, configAttributes, &config, 1, &count) || count == 0)
            throw std::runtime_error("EGL compute config unavailable");
        const EGLint surfaceAttributes[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
        const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
        if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT) throw std::runtime_error("EGL context creation failed");
        Binding binding(display, surface, context);
        if (!binding.bound) throw std::runtime_error("EGL binding failed");
        GLint major = 0, minor = 0, invocations = 0, groupSize = 0, groups = 0;
        GLint64 block = 0;
        glGetIntegerv(GL_MAJOR_VERSION, &major); glGetIntegerv(GL_MINOR_VERSION, &minor);
        if (major < 3 || (major == 3 && minor < 1)) throw std::runtime_error("OpenGL ES 3.1 required");
        glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &invocations);
        glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, 0, &groupSize);
        glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, &groups);
        glGetInteger64v(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &block);
        glGetIntegerv(GL_MAX_3D_TEXTURE_SIZE, &textureLimit);
        if (invocations < int(kWorkgroup) || groupSize < int(kWorkgroup) || groups < 1 || block <= 0)
            throw std::runtime_error("Insufficient compute limits");
        blockLimit = static_cast<size_t>(block);
        dispatchLimit = std::min<size_t>(static_cast<size_t>(groups) * kWorkgroup, UINT32_MAX);
        program = makeProgram();
        glGenBuffers(3, buffers);
        checkGL();
        __android_log_print(ANDROID_LOG_INFO, "RawLabGPU", "%s; %s; SSBO=%lld; groups=%d; texture3D=%d",
            glGetString(GL_RENDERER), glGetString(GL_VERSION), static_cast<long long>(block), groups, textureLimit);
    }

    GLint uniform(const char* name) const { return glGetUniformLocation(program, name); }
    void sizeUniform(const char* name, uint32_t width, uint32_t height) {
        glUniform2ui(uniform(name), width, height);
    }
    void matrixUniform(const char* name, const ColorConverter::Matrix3x3& matrix) {
        float values[9];
        for (int row = 0; row < 3; ++row) for (int col = 0; col < 3; ++col) values[col * 3 + row] = matrix[row][col];
        glUniformMatrix3fv(uniform(name), 1, GL_FALSE, values);
    }
    void allocate(int index, size_t bytes) {
        if (bytes == 0 || bytes > blockLimit) throw std::runtime_error("SSBO size exceeds device limit");
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[index]);
        if (capacities[index] != bytes) {
            glBufferData(GL_SHADER_STORAGE_BUFFER, static_cast<GLsizeiptr>(bytes), nullptr, GL_DYNAMIC_COPY);
            checkGL(); capacities[index] = bytes;
        }
    }
    void upload(const RGB* data, size_t bytes) {
        allocate(0, bytes);
        glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLsizeiptr>(bytes), data);
        checkGL();
    }
    void dispatch(int source, int destination, size_t count, uint32_t inputRow, uint32_t outputRow, uint32_t offset, int stage) {
        if (count > dispatchLimit) throw std::runtime_error("Dispatch exceeds device limit");
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[source]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[destination]);
        glUniform1ui(uniform("sourceStartRow"), inputRow);
        glUniform1ui(uniform("destinationStartRow"), outputRow);
        glUniform1ui(uniform("pixelCount"), static_cast<GLuint>(count));
        glUniform1ui(uniform("outputOffset"), offset);
        glUniform1i(uniform("stage"), stage);
        glDispatchCompute(static_cast<GLuint>((count + kWorkgroup - 1) / kWorkgroup), 1, 1);
        glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);
        checkGL();
    }
    void read(RGB* destination, size_t bytes) {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[2]);
        auto mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLsizeiptr>(bytes), GL_MAP_READ_BIT);
        if (!mapped) throw std::runtime_error("GPU readback failed");
        std::memcpy(destination, mapped, bytes);
        if (!glUnmapBuffer(GL_SHADER_STORAGE_BUFFER)) throw std::runtime_error("GPU buffer contents lost");
        checkGL();
    }
    void setLut(const std::shared_ptr<LUT3D>& lut) {
        glActiveTexture(GL_TEXTURE0);
        if (lut && cachedLut != lut) {
            if (lut->getSize() > textureLimit) throw std::runtime_error("LUT exceeds device texture limit");
            if (!texture) glGenTextures(1, &texture);
            glBindTexture(GL_TEXTURE_3D, texture);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
            const auto data = buildLutTextureDataRGBA(*lut);
            const int size = lut->getSize();
            glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA32F, size, size, size, 0, GL_RGBA, GL_FLOAT, data.data());
            checkGL(); cachedLut = lut;
        }
        glBindTexture(GL_TEXTURE_3D, texture);
        glUniform1i(uniform("useLut"), lut ? 1 : 0);
        if (lut) {
            glUniform1i(uniform("inputIsFLog"), lut->inputTransfer() == LUTTransfer::FLog);
            glUniform1i(uniform("outputIsLog"), lut->outputTransfer() != LUTTransfer::Display);
            glUniform1i(uniform("outputIsFLog"), lut->outputTransfer() == LUTTransfer::FLog);
            glUniform1i(uniform("lutSize"), lut->getSize());
            auto low = lut->domainMin(), high = lut->domainMax();
            glUniform3f(uniform("domainMin"), low.r, low.g, low.b);
            glUniform3f(uniform("domainMax"), high.r, high.g, high.b);
        }
    }

    void bands(const ImageData& input, uint32_t width, uint32_t height, int stage, ImageData* output) {
        const size_t limit = std::min(kTileBytes, blockLimit);
        const size_t sourceRowBytes = static_cast<size_t>(input.width) * sizeof(RGB);
        const size_t outputRowBytes = static_cast<size_t>(width) * sizeof(RGB);
        if (sourceRowBytes * 2 > limit || outputRowBytes > limit || width > dispatchLimit)
            throw std::runtime_error("Image row exceeds compute limits");
        const float scale = height == 1 ? 0.f : float(input.height - 1) / float(height - 1);
        const uint32_t maxRows = static_cast<uint32_t>(std::min(limit / outputRowBytes, dispatchLimit / width));
        sizeUniform("sourceSize", input.width, input.height);
        sizeUniform("destinationSize", width, height);
        for (uint32_t row = 0; row < height;) {
            uint32_t rows = std::min(maxRows, height - row);
            // One extra row on each side covers GPU/CPU float rounding at boundaries.
            const uint32_t first = uint32_t(float(row) * scale) > 0 ? uint32_t(float(row) * scale) - 1 : 0;
            auto lastRow = [&](uint32_t n) {
                return std::min<uint32_t>(input.height - 1, uint32_t(float(row + n - 1) * scale) + 2);
            };
            while (rows > 1 && size_t(lastRow(rows) - first + 1) * sourceRowBytes > limit) rows = (rows + 1) / 2;
            const auto last = lastRow(rows);
            if (size_t(last - first + 1) * sourceRowBytes > limit)
                throw std::runtime_error("Source halo exceeds the bounded upload budget");
            upload(input.pixels.data() + size_t(first) * input.width, size_t(last - first + 1) * sourceRowBytes);
            const auto bytes = size_t(rows) * outputRowBytes;
            if (output) allocate(2, bytes);
            dispatch(0, output ? 2 : 1, size_t(rows) * width, first, row, output ? 0 : row * width, stage);
            if (output) read(output->pixels.data() + size_t(row) * width, bytes);
            row += rows;
        }
    }
};

GlesPhotoRenderer::GlesPhotoRenderer() = default;
GlesPhotoRenderer::~GlesPhotoRenderer() = default;

bool GlesPhotoRenderer::render(const ImageData& input, ColorSpace inputSpace,
    const sony2fuji_request& request, const std::shared_ptr<LUT3D>& lut,
    const RGB& relativeWB, uint32_t width, uint32_t height, uint64_t revision, ImageData& output) {
    if (lut && lut->inputTransfer() == LUTTransfer::SRGB) return false;
    if (input.width <= 0 || input.height <= 0 || width == 0 || height == 0 ||
        width > INT32_MAX || height > INT32_MAX || uint64_t(width) * height > INT32_MAX ||
        input.pixels.size() != size_t(input.width) * input.height ||
        request.noise_reduction > 0 || request.sharpening > 0) return false;
    try {
        if (!impl_) { impl_ = std::make_unique<Impl>(); impl_->initialize(); }
        auto& context = *impl_;
        Binding binding(context.display, context.surface, context.context);
        if (!binding.bound) throw std::runtime_error("EGL context lost or owned by another thread");
        glUseProgram(context.program);
        context.matrixUniform("toSrgb", ColorConverter::getConversionMatrix(inputSpace, ColorSpace::sRGB));
        context.matrixUniform("toFGamut", photoLUTInputMatrix(lut ? lut->inputTransfer() : LUTTransfer::FLog2));
        const float exposure = std::exp2(request.exposure_ev) * request.brightness;
        glUniform3f(context.uniform("exposureWB"), exposure * relativeWB.r, exposure * relativeWB.g, exposure * relativeWB.b);
        glUniform1f(context.uniform("strength"), request.lut_strength);
        glUniform4f(context.uniform("tone"), std::clamp(request.contrast, 0.f, 2.f), std::clamp(request.saturation, 0.f, 2.f),
            std::clamp(request.highlights, -1.f, 1.f), std::clamp(request.shadows, -1.f, 1.f));
        glUniform1f(context.uniform("curve"), request.tone_curve);
        context.setLut(request.lut_strength > 0 ? lut : nullptr);
        ImageData result(static_cast<int>(width), static_cast<int>(height));
        const size_t bytes = result.pixels.size() * sizeof(RGB);
        const bool preview = request.intent == SONY2FUJI_INTENT_PREVIEW;
        const bool cache = preview && revision != 0 && bytes <= std::min(kCacheBytes, context.blockLimit) && result.pixels.size() <= context.dispatchLimit;
        if (cache) {
            if (context.cachedRevision != revision || context.cachedWidth != width || context.cachedHeight != height) {
                context.cachedRevision = 0;
                context.allocate(1, bytes);
                context.bands(input, width, height, 0, nullptr);
                context.cachedRevision = revision; context.cachedWidth = width; context.cachedHeight = height;
            }
            context.allocate(2, bytes);
            context.sizeUniform("sourceSize", width, height);
            context.sizeUniform("destinationSize", width, height);
            context.dispatch(1, 2, result.pixels.size(), 0, 0, 0, 1);
            context.read(result.pixels.data(), bytes);
        } else context.bands(input, width, height, preview ? 3 : 2, &result);
        output = std::move(result);
        return true;
    } catch (const std::exception& error) {
        __android_log_print(ANDROID_LOG_WARN, "RawLabGPU", "%s; falling back when Auto is selected", error.what());
        impl_.reset();
        return false;
    }
}

}
