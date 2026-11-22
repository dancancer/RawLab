#include "gpu/gles_photo.h"
#include "gpu/gles_pixel_contract.h"
#include "gpu/gles_recovery.h"
#include "core/processing_cancellation.h"
#include "gpu/gles_photo_shader.h"
#include "gpu/lut_gpu_internal.h"
#include "core/photo_lut.h"
#include "core/chroma_denoise.h"
#include "gpu/denoise.h"
#include "gpu/photo_bands.h"
#include <EGL/egl.h>
#include <GLES3/gl31.h>
#include <android/log.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <stdexcept>

namespace sony2fuji {
namespace {
constexpr size_t kCacheBytes = 64 * 1024 * 1024;
constexpr GLuint kWorkgroup = GlesPhotoPixelContract::kWorkgroupSize;
static_assert(sizeof(RGB) == GlesPhotoPixelContract::kSsboPixelBytes);

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
    EGLint error = EGL_SUCCESS;
    Binding(EGLDisplay d, EGLSurface s, EGLContext c) : display(d) {
        bound = eglBindAPI(EGL_OPENGL_ES_API) && eglMakeCurrent(d, s, s, c);
        if (!bound) error = eglGetError();
    }
    ~Binding() {
        // EGL_NO_CONTEXT 按当前 API 解绑：先释放 ES，再恢复调用方 API 和非空 context。
        if (bound) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        if (previousApi != EGL_NONE) {
            eglBindAPI(previousApi);
        }
        if (bound && previousContext != EGL_NO_CONTEXT) {
            eglMakeCurrent(previousDisplay, previousDraw, previousRead, previousContext);
        }
    }
};

void checkGL() {
    const auto error = glGetError();
    if (error != GL_NO_ERROR) throw GlesFailure(error);
}

GLuint makeProgram() {
    const auto shader = glCreateShader(GL_COMPUTE_SHADER);
    const char* source = kPhotoComputeShader.c_str();
    glShaderSource(shader, 1, &source, nullptr);
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
    GLuint program = 0, buffers[4]{}, texture = 0;
    size_t capacities[4]{}, blockLimit = 0, dispatchLimit = 0;
    GLint textureLimit = 0;
    uint64_t cachedRevision = 0;
    uint32_t cachedWidth = 0, cachedHeight = 0;
    std::shared_ptr<LUT3D> cachedLut;

    ~Impl() {
        if (context != EGL_NO_CONTEXT) {
            {
                Binding binding(display, surface, context);
                if (binding.bound) {
                    glDeleteBuffers(4, buffers);
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
        if (display == EGL_NO_DISPLAY) throw GpuUnavailableError("EGL display unavailable");
        const EGLint configAttributes[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
        EGLConfig config{}; EGLint count = 0;
        if (!eglChooseConfig(display, configAttributes, &config, 1, &count) || count == 0)
            throw GpuUnavailableError("EGL compute config unavailable");
        const EGLint surfaceAttributes[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        surface = eglCreatePbufferSurface(display, config, surfaceAttributes);
        const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        const auto previousApi = eglQueryAPI();
        if (eglBindAPI(EGL_OPENGL_ES_API)) {
            context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
        }
        if (previousApi != EGL_NONE) eglBindAPI(previousApi);
        if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT) throw std::runtime_error("EGL context creation failed");
        Binding binding(display, surface, context);
        if (!binding.bound) throw std::runtime_error("EGL binding failed");
        GLint major = 0, minor = 0, invocations = 0, groupSize = 0, groups = 0;
        GLint64 block = 0;
        glGetIntegerv(GL_MAJOR_VERSION, &major); glGetIntegerv(GL_MINOR_VERSION, &minor);
        if (major < 3 || (major == 3 && minor < 1)) throw GpuUnavailableError("OpenGL ES 3.1 required");
        glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &invocations);
        glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_SIZE, 0, &groupSize);
        glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, &groups);
        glGetInteger64v(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, &block);
        glGetIntegerv(GL_MAX_3D_TEXTURE_SIZE, &textureLimit);
        if (invocations < int(kWorkgroup) || groupSize < int(kWorkgroup) || groups < 1 || block <= 0)
            throw GpuUnavailableError("Insufficient compute limits");
        blockLimit = static_cast<size_t>(block);
        dispatchLimit = std::min<size_t>(static_cast<size_t>(groups) * kWorkgroup, UINT32_MAX);
        program = makeProgram();
        glGenBuffers(4, buffers);
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
        if (bytes == 0 || bytes > blockLimit) throw GpuCapabilityLimitError("SSBO size exceeds device limit");
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[index]);
        if (capacities[index] != bytes) {
            capacities[index] = 0;
            glBufferData(GL_SHADER_STORAGE_BUFFER, static_cast<GLsizeiptr>(bytes), nullptr, GL_DYNAMIC_COPY);
            checkGL(); capacities[index] = bytes;
        }
    }
    void upload(const RGB* data, size_t bytes) {
        checkProcessingCancellation();
        allocate(0, bytes);
        glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLsizeiptr>(bytes), data);
        checkGL();
    }
    void setBasicToneField(const RenderParams& params) {
        if (params.basicV3 && params.basicTone.active() && params.basicToneField && !params.basicToneField->empty()) {
            const auto& f = *params.basicToneField;
            const size_t n = f.slope.size();
            std::vector<float> packed(n * 2);
            for (size_t i = 0; i < n; ++i) {
                packed[i * 2] = f.slope[i];
                packed[i * 2 + 1] = f.intercept[i];
            }
            const size_t bytes = packed.size() * sizeof(float);
            allocate(3, bytes);
            glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLsizeiptr>(bytes), packed.data());
            checkGL();
        } else if (capacities[3] == 0) {
            const float dummy[2]{0.0f, 0.0f};
            allocate(3, sizeof(dummy));
            glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, sizeof(dummy), dummy);
            checkGL();
        }
    }
    void dispatch(int source, int destination, size_t count, uint32_t inputRow, uint32_t outputRow, uint32_t offset, int stage) {
        checkProcessingCancellation();
        if (count > dispatchLimit) throw GpuCapabilityLimitError("Dispatch exceeds device limit");
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[source]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[destination]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, buffers[3]);
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
        checkProcessingCancellation();
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[2]);
        auto mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLsizeiptr>(bytes), GL_MAP_READ_BIT);
        if (!mapped) {
            checkGL();
            throw std::runtime_error("GPU readback failed");
        }
        std::memcpy(destination, mapped, bytes);
        if (!glUnmapBuffer(GL_SHADER_STORAGE_BUFFER)) {
            checkGL();
            throw std::runtime_error("GPU buffer contents lost");
        }
        checkProcessingCancellation();
        checkGL();
    }
    void clearStickyErrors() {
        Binding binding(display, surface, context);
        if (binding.bound) {
            while (glGetError() != GL_NO_ERROR) {}
        }
    }
    void setLut(const std::shared_ptr<LUT3D>& lut) {
        glActiveTexture(GL_TEXTURE0);
        if (lut && cachedLut != lut) {
            cachedLut.reset();
            if (lut->getSize() > textureLimit) throw GpuCapabilityLimitError("LUT exceeds device texture limit");
            if (!texture) glGenTextures(1, &texture);
            glBindTexture(GL_TEXTURE_3D, texture);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
            const auto data = buildLutTextureDataRGBA(*lut);
            const int size = lut->getSize();
            if (!validGlesLut3DContract(*lut, textureLimit, data.size())) {
                throw std::runtime_error("LUT texture contract invalid");
            }
            glPixelStorei(GL_UNPACK_ALIGNMENT, GlesPhotoPixelContract::kLutUnpackAlignment);
            glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA32F, size, size, size, 0, GL_RGBA, GL_FLOAT, data.data());
            checkGL(); cachedLut = lut;
        }
        glBindTexture(GL_TEXTURE_3D, texture);
        glUniform1i(uniform("useLut"), lut ? 1 : 0);
        if (lut) {
            glUniform1i(uniform("inputIsSRGB"), lut->inputTransfer() == LUTTransfer::SRGB);
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
        const PhotoBands plan(input.width, input.height, width, height, std::min(kPhotoTileBytes, blockLimit), dispatchLimit);
        const size_t sourceRowBytes = static_cast<size_t>(input.width) * sizeof(RGB);
        const size_t outputRowBytes = static_cast<size_t>(width) * sizeof(RGB);
        sizeUniform("sourceSize", input.width, input.height);
        sizeUniform("destinationSize", width, height);
        for (uint32_t row = 0; row < height;) {
            const auto band = plan.at(row);
            const auto rows = band.rows, first = band.first, last = band.last;
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

GpuRenderOutcome GlesPhotoRenderer::renderWithOutcome(const ImageData& input, ColorSpace inputSpace,
    const RenderParams& params, uint32_t width, uint32_t height, uint64_t revision, ImageData& output) {
    GpuRenderOutcome outcome;
    try {
        (void)renderImpl(input, inputSpace, params, width, height, revision, output, outcome);
    } catch (const std::bad_alloc& error) {
        outcome = {GpuFailureKind::OutOfMemory, GpuBackendFault::DeviceError, error.what()};
    }
    return outcome;
}

bool GlesPhotoRenderer::render(const ImageData& input, ColorSpace inputSpace,
    const RenderParams& params, uint32_t width, uint32_t height, uint64_t revision, ImageData& output) {
    GpuRenderOutcome outcome;
    return renderImpl(input, inputSpace, params, width, height, revision, output, outcome);
}

bool GlesPhotoRenderer::renderImpl(const ImageData& input, ColorSpace inputSpace,
    const RenderParams& params, uint32_t width, uint32_t height, uint64_t revision, ImageData& output,
    GpuRenderOutcome& outcome) {
    outcome = {};
    if (params.lut && params.lut->requiresCPU()) {
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability, "LUT requires CPU evaluation"};
        return false;
    }
    if (input.width <= 0 || input.height <= 0 || width == 0 || height == 0 ||
        width > INT32_MAX || height > INT32_MAX || uint64_t(width) * height > INT32_MAX ||
        input.pixels.size() != size_t(input.width) * input.height ||
        !params.validForGpu()) {
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability,
            "Image dimensions or parameters exceed OpenGL ES limits"};
        return false;
    }
    if (!impl_ && !retry_.ready(glesRetryNow())) {
        if (initUnavailable_) {
            outcome = {GpuFailureKind::Unsupported, GpuBackendFault::Cooldown,
                lastInitError_.empty() ? "OpenGL ES 3.1 unavailable (retry cooldown)" : lastInitError_};
        } else {
            outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::Cooldown,
                lastInitError_.empty() ? "OpenGL ES device recovery cooldown" : lastInitError_};
        }
        return false;
    }
    bool initializing = !impl_;
    try {
        if (!impl_) { impl_ = std::make_unique<Impl>(); impl_->initialize(); }
        initializing = false;
        auto& context = *impl_;
        Binding binding(context.display, context.surface, context.context);
        if (!binding.bound) throw EglFailure(binding.error);
        glUseProgram(context.program);
        context.matrixUniform("toSrgb", params.hasCustomToSrgb
            ? params.customToSrgb
            : ColorConverter::getConversionMatrix(inputSpace, ColorSpace::sRGB));
        context.matrixUniform("toFGamut", photoLUTInputMatrix(params.lut ? params.lut->inputTransfer() : LUTTransfer::FLog2));
        const float exposure = std::exp2(params.exposureEV) * params.brightness;
        glUniform3f(context.uniform("exposureWB"),
            exposure * params.relativeWB.r, exposure * params.relativeWB.g, exposure * params.relativeWB.b);
        glUniform1f(context.uniform("strength"), params.lutStrength);
        glUniform4f(context.uniform("tone"), std::clamp(params.contrast, 0.f, 2.f), std::clamp(params.saturation, 0.f, 2.f),
            std::clamp(params.highlights, -1.f, 1.f), std::clamp(params.shadows, -1.f, 1.f));
        glUniform1f(context.uniform("curve"), params.toneCurve);
        const auto custom = toneCurveGpuParameters(params.customCurve);
        glUniform1i(context.uniform("customCurveCount"), custom.count);
        glUniform4fv(context.uniform("curveRanges[0]"), 32, &custom.ranges[0][0]);
        glUniform4fv(context.uniform("curveTangents[0]"), 32, &custom.tangents[0][0]);
        glUniform1i(context.uniform("hslActive"), params.hsl.active());
        glUniform3f(context.uniform("toneControls"),
            params.toneControls.blackPoint, params.toneControls.whitePoint, params.toneControls.vibrance);
        const auto grading=colorGradingCoefficients(params.colorGrading);
        const float coefficients[]={grading[0].r,grading[0].g,grading[0].b,grading[1].r,grading[1].g,grading[1].b,grading[2].r,grading[2].g,grading[2].b};
        glUniform3fv(context.uniform("colorGrading[0]"),3,coefficients);
        glUniform4fv(context.uniform("hslHue[0]"), 2, params.hsl.hue.data());
        glUniform4fv(context.uniform("hslSaturation[0]"), 2, params.hsl.saturation.data());
        glUniform4fv(context.uniform("hslLightness[0]"), 2, params.hsl.lightness.data());
        const bool bt = params.basicV3 && params.basicTone.active() &&
            params.basicToneField && !params.basicToneField->empty();
        glUniform1i(context.uniform("basicV3"), params.basicV3 ? 1 : 0);
        glUniform1i(context.uniform("basicToneActive"), bt ? 1 : 0);
        glUniform2ui(context.uniform("basicFieldSize"),
            bt ? static_cast<GLuint>(params.basicToneField->width) : 1u,
            bt ? static_cast<GLuint>(params.basicToneField->height) : 1u);
        glUniform4f(context.uniform("basicTone"),
            bt ? std::clamp(params.basicTone.highlights, -1.0f, 1.0f) : 0.0f,
            bt ? std::clamp(params.basicTone.shadows, -1.0f, 1.0f) : 0.0f, 0.0f, 0.0f);
        context.setBasicToneField(params);
        context.setLut(params.lutStrength > 0 ? params.lut : nullptr);
        if (params.effects.active() || params.chromaDenoise != 0 || params.noiseReduction > 0 ||
            params.sharpening > 0 || params.preserveSourceResolution) {
            context.cachedRevision = 0;
            ImageData native(input.width, input.height);
            context.bands(input, input.width, input.height, 2, &native);
            auto failFilter = [&](const char* fallbackMessage, ErrorCode err = ErrorCode::ProcessingError) {
                const auto filterOutcome = lastGpuFilterOutcome();
                if (err == ErrorCode::OutOfMemory || filterOutcome.failure == GpuFailureKind::OutOfMemory) {
                    outcome = {GpuFailureKind::OutOfMemory, GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? fallbackMessage : filterOutcome.message};
                } else if (err == ErrorCode::Unsupported || filterOutcome.failure == GpuFailureKind::Unsupported) {
                    outcome = {GpuFailureKind::Unsupported,
                        filterOutcome.fault != GpuBackendFault::None ? filterOutcome.fault : GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? fallbackMessage : filterOutcome.message};
                } else {
                    outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? fallbackMessage : filterOutcome.message};
                }
                return false;
            };
            if (params.chromaDenoise != 0) {
                lastGpuFilterOutcome() = {};
                const auto chromaErr = applyChromaDenoiseWorking(native, params.chromaDenoise, nullptr, GpuMode::Force);
                if (chromaErr != ErrorCode::Success) {
                    return failFilter("GLES chroma denoise failed", chromaErr);
                }
            }
            if (params.noiseReduction > 0 || params.sharpening > 0) {
                lastGpuFilterOutcome() = {};
                if (!gpuDetailFilter(native, params.noiseReduction, params.sharpening)) {
                    return failFilter("GLES detail filter failed");
                }
            }
            if (params.effects.active()) {
                lastGpuFilterOutcome() = {};
                if (!gpuPhotoEffects(native, params.effects)) {
                    return failFilter("GLES photo effects failed");
                }
            }
            if (width != static_cast<uint32_t>(native.width) || height != static_cast<uint32_t>(native.height)) {
                ImageData resized(static_cast<int>(width), static_cast<int>(height));
                context.bands(native, width, height, 4, &resized);
                output = std::move(resized);
            } else output = std::move(native);
            retry_.succeeded();
            initUnavailable_ = false;
            lastInitError_.clear();
            return true;
        }
        ImageData result(static_cast<int>(width), static_cast<int>(height));
        const size_t bytes = result.pixels.size() * sizeof(RGB);
        const bool preview = params.intent == RenderIntent::Preview;
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
        retry_.succeeded();
        initUnavailable_ = false;
        lastInitError_.clear();
        return true;
    } catch (const ProcessingCancelled&) {
        if (impl_) impl_->clearStickyErrors();
        throw;
    } catch (const std::bad_alloc&) {
        if (impl_) impl_->clearStickyErrors();
        throw;
    } catch (const GpuUnavailableError& error) {
        __android_log_print(ANDROID_LOG_WARN, "RawLabGPU", "%s; falling back when Auto is selected", error.what());
        initUnavailable_ = true;
        lastInitError_ = error.what();
        retry_.failed(glesRetryNow());
        impl_.reset();
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::NoAdapter, error.what()};
        return false;
    } catch (const GpuCapabilityLimitError& error) {
        __android_log_print(ANDROID_LOG_WARN, "RawLabGPU", "%s; falling back when Auto is selected", error.what());
        if (impl_) impl_->clearStickyErrors();
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability, error.what()};
        return false;
    } catch (const std::exception& error) {
        __android_log_print(ANDROID_LOG_WARN, "RawLabGPU", "%s; falling back when Auto is selected", error.what());
        if (initializing || glesLostDevice(error)) {
            initUnavailable_ = false;
            lastInitError_ = error.what();
            retry_.failed(glesRetryNow());
            impl_.reset();
        } else if (impl_) {
            impl_->clearStickyErrors();
        }
        outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, error.what()};
        return false;
    }
}

}
