#include "gpu/gles_photo.h"
#include "gpu/gles_pixel_contract.h"
#include "gpu/gles_recovery.h"
#include "core/processing_cancellation.h"
#include "gpu/gles_photo_shader.h"
#include "gpu/photo_color_science_shader.h"
#include "gpu/lut_gpu_internal.h"
#include "core/photo_atmosphere.h"
#include "core/photo_defringe.h"
#include "core/photo_lut.h"
#include "core/photo_sharpen_v2.h"
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

struct alignas(16) CurveUbo {
    uint32_t curveCounts[4]{};     // master, R, G, B
    uint32_t curveFlags[4]{};      // applyToLuminosity, parametricActive, 0, 0
    float parametricAmps[4]{};     // shadows, darks, lights, highlights
    float parametricSplits[4]{};   // splitShadow, splitMidtone, splitHighlight, 0
    float curveRanges[128][4]{};   // 0..31 master, 32..63 R, 64..95 G, 96..127 B
    float curveTangents[128][4]{}; // 0..31 master, 32..63 R, 64..95 G, 96..127 B
};
static_assert(sizeof(CurveUbo) == 4160, "GLES CurveUbo std140 layout");

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

GLuint makeProgram(const std::string& sourceText) {
    const auto shader = glCreateShader(GL_COMPUTE_SHADER);
    const char* source = sourceText.c_str();
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
    GLuint program = 0, spatialProgram = 0;
    GLuint buffers[7]{}; // 0:src, 1:cache, 2:dst, 3:auxField, 4:dcpInvalid, 5:spAux1, 6:spAux2
    GLuint curveUbo = 0, dcpUbo = 0, colorScienceUbo = 0, spatialUbo = 0, texture = 0;
    size_t capacities[7]{}, blockLimit = 0, dispatchLimit = 0;
    GLint textureLimit = 0;
    uint64_t cachedRevision = 0;
    uint32_t cachedWidth = 0, cachedHeight = 0;
    std::shared_ptr<LUT3D> cachedLut;

    ~Impl() {
        if (context != EGL_NO_CONTEXT) {
            {
                Binding binding(display, surface, context);
                if (binding.bound) {
                    glDeleteBuffers(7, buffers);
                    if (curveUbo) glDeleteBuffers(1, &curveUbo);
                    if (dcpUbo) glDeleteBuffers(1, &dcpUbo);
                    if (colorScienceUbo) glDeleteBuffers(1, &colorScienceUbo);
                    if (spatialUbo) glDeleteBuffers(1, &spatialUbo);
                    if (texture) glDeleteTextures(1, &texture);
                    if (program) glDeleteProgram(program);
                    if (spatialProgram) glDeleteProgram(spatialProgram);
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
        program = makeProgram(kPhotoComputeShader);
        spatialProgram = makeProgram(kPhotoSpatialShader);
        glGenBuffers(7, buffers);
        glGenBuffers(1, &curveUbo);
        glBindBuffer(GL_UNIFORM_BUFFER, curveUbo);
        glBufferData(GL_UNIFORM_BUFFER, sizeof(CurveUbo), nullptr, GL_DYNAMIC_DRAW);
        glGenBuffers(1, &colorScienceUbo);
        glBindBuffer(GL_UNIFORM_BUFFER, colorScienceUbo);
        glBufferData(GL_UNIFORM_BUFFER, sizeof(ColorScienceGpuParams), nullptr, GL_DYNAMIC_DRAW);
        glGenBuffers(1, &dcpUbo);
        glBindBuffer(GL_UNIFORM_BUFFER, dcpUbo);
        glBufferData(GL_UNIFORM_BUFFER, sizeof(DcpGpuUniforms), nullptr, GL_DYNAMIC_DRAW);
        glGenBuffers(1, &spatialUbo);
        glBindBuffer(GL_UNIFORM_BUFFER, spatialUbo);
        glBufferData(GL_UNIFORM_BUFFER, sizeof(SpatialGpuParams), nullptr, GL_DYNAMIC_DRAW);
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
    void setAuxAndDcp(const RenderParams& params, bool useDcp) {
        checkProcessingCancellation();
        std::vector<float> packed;
        if (params.basicV3 && params.basicTone.active() && params.basicToneField && !params.basicToneField->empty()) {
            const auto& f = *params.basicToneField;
            const size_t n = f.slope.size();
            packed.resize(n * 2u);
            for (size_t i = 0; i < n; ++i) {
                packed[i * 2u] = f.slope[i];
                packed[i * 2u + 1u] = f.intercept[i];
            }
        } else {
            packed = {0.0f, 0.0f};
        }
        DcpGpuUniforms dcpUniforms{};
        if (useDcp && params.dcp) {
            std::vector<float> dcpData;
            if (!packDcpLookGpuData(*params.dcp, dcpUniforms, dcpData)) {
                throw std::runtime_error("Invalid DCP look data");
            }
            dcpUniforms.offsets[2] = static_cast<uint32_t>(packed.size());
            packed.insert(packed.end(), dcpData.begin(), dcpData.end());
        }
        const size_t bytes = packed.size() * sizeof(float);
        allocate(3, bytes);
        glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLsizeiptr>(bytes), packed.data());
        glBindBuffer(GL_UNIFORM_BUFFER, dcpUbo);
        glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(DcpGpuUniforms), &dcpUniforms);
        glBindBufferBase(GL_UNIFORM_BUFFER, 1, dcpUbo);

        const uint32_t zero = 0u;
        allocate(4, sizeof(uint32_t));
        glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, sizeof(uint32_t), &zero);
        checkGL();
    }
    bool hasDcpInvalid() {
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, buffers[4]);
        auto mapped = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, sizeof(uint32_t), GL_MAP_READ_BIT);
        if (!mapped) {
            checkGL();
            throw std::runtime_error("GPU DCP status readback failed");
        }
        uint32_t flag = 0u;
        std::memcpy(&flag, mapped, sizeof(uint32_t));
        if (!glUnmapBuffer(GL_SHADER_STORAGE_BUFFER)) {
            checkGL();
            throw std::runtime_error("GPU DCP status buffer lost");
        }
        checkGL();
        return flag != 0u;
    }
    void uploadField(const std::vector<float>* data) {
        if (data && !data->empty()) {
            const size_t bytes = data->size() * sizeof(float);
            allocate(3, bytes);
            glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, static_cast<GLsizeiptr>(bytes), data->data());
        } else {
            const float dummy[1]{0.0f};
            allocate(3, sizeof(dummy));
            glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, sizeof(dummy), dummy);
        }
        checkGL();
    }
    void ensureDummyAux() {
        if (capacities[5] == 0) {
            const float dummy[3]{0.0f, 0.0f, 0.0f};
            allocate(5, sizeof(dummy));
            glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, sizeof(dummy), dummy);
            checkGL();
        }
    }
    void dispatchSpatial(const SpatialGpuParams& sp, int srcIndex, int dstIndex, int auxIndex) {
        checkProcessingCancellation();
        const size_t count = static_cast<size_t>(sp.width) * static_cast<size_t>(sp.rows);
        if (count > dispatchLimit) throw GpuCapabilityLimitError("Dispatch exceeds device limit");
        glBindBuffer(GL_UNIFORM_BUFFER, spatialUbo);
        glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(SpatialGpuParams), &sp);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, spatialUbo);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[srcIndex]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[dstIndex]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, buffers[auxIndex]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, buffers[3]);
        glDispatchCompute(static_cast<GLuint>((count + kWorkgroup - 1) / kWorkgroup), 1, 1);
        glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);
        checkGL();
    }
    void dispatch(int source, int destination, size_t count, uint32_t inputRow, uint32_t outputRow, uint32_t offset, int stage, int evalPhase = 0) {
        checkProcessingCancellation();
        if (count > dispatchLimit) throw GpuCapabilityLimitError("Dispatch exceeds device limit");
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, buffers[source]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, buffers[destination]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, buffers[3]);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, buffers[4]);
        glUniform1ui(uniform("sourceStartRow"), inputRow);
        glUniform1ui(uniform("destinationStartRow"), outputRow);
        glUniform1ui(uniform("pixelCount"), static_cast<GLuint>(count));
        glUniform1ui(uniform("outputOffset"), offset);
        glUniform1i(uniform("stage"), stage);
        glUniform1i(uniform("evalPhase"), evalPhase);
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

    void bands(const ImageData& input, uint32_t width, uint32_t height, int stage, ImageData* output, int evalPhase = 0) {
        glUseProgram(program);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, curveUbo);
        glBindBufferBase(GL_UNIFORM_BUFFER, 1, dcpUbo);
        glBindBufferBase(GL_UNIFORM_BUFFER, 2, colorScienceUbo);
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
            dispatch(0, output ? 2 : 1, size_t(rows) * width, first, row, output ? 0 : row * width, stage, evalPhase);
            if (output) read(output->pixels.data() + size_t(row) * width, bytes);
            row += rows;
        }
    }

    void spatialBands(const ImageData& input, ImageData& output, SpatialGpuParams spTemplate, uint32_t halo,
                      const std::vector<float>* fieldData) {
        glUseProgram(spatialProgram);
        uploadField(fieldData);
        ensureDummyAux();
        const uint32_t w = static_cast<uint32_t>(input.width);
        const uint32_t h = static_cast<uint32_t>(input.height);
        const PhotoBands plan(w, h, w, h, std::min(kPhotoTileBytes, blockLimit), dispatchLimit);
        const size_t rowBytes = static_cast<size_t>(w) * sizeof(RGB);
        for (uint32_t row = 0; row < h;) {
            const auto band = plan.at(row, halo);
            const uint32_t bandRows = band.last - band.first + 1u;
            upload(input.pixels.data() + size_t(band.first) * w, size_t(bandRows) * rowBytes);
            const size_t dstBytes = size_t(band.rows) * rowBytes;
            allocate(2, dstBytes);
            auto sp = spTemplate;
            sp.width = w; sp.height = h;
            sp.rowOffset = row; sp.rows = band.rows;
            sp.srcRowOffset = band.first; sp.auxRowOffset = band.first;
            sp.bandDims[0] = bandRows; sp.bandDims[1] = bandRows;
            dispatchSpatial(sp, 0, 2, 5);
            read(output.pixels.data() + size_t(row) * w, dstBytes);
            row += band.rows;
        }
    }

    void spatialTextureBands(const ImageData& input, ImageData& output, float sigma, float strength) {
        glUseProgram(spatialProgram);
        uploadField(nullptr);
        const uint32_t w = static_cast<uint32_t>(input.width);
        const uint32_t h = static_cast<uint32_t>(input.height);
        SpatialGpuParams spBase{};
        spBase.strength = strength;
        fillSpatialGaussianWeights(sigma, 12, spBase);
        const PhotoBands plan(w, h, w, h, std::min(kPhotoTileBytes, blockLimit), dispatchLimit);
        const size_t rowBytes = static_cast<size_t>(w) * sizeof(RGB);
        for (uint32_t row = 0; row < h;) {
            const auto band = plan.at(row, spBase.radius);
            const uint32_t bandRows = band.last - band.first + 1u;
            const size_t bandBytes = size_t(bandRows) * rowBytes;
            upload(input.pixels.data() + size_t(band.first) * w, bandBytes);
            allocate(5, bandBytes);
            auto spH = spBase;
            spH.width = w; spH.height = h;
            spH.rowOffset = band.first; spH.rows = bandRows;
            spH.srcRowOffset = band.first; spH.auxRowOffset = band.first;
            spH.bandDims[0] = bandRows; spH.bandDims[1] = bandRows;
            spH.stage = static_cast<uint32_t>(SpatialKernel::TextureBlurH);
            dispatchSpatial(spH, 0, 5, 0);

            const size_t dstBytes = size_t(band.rows) * rowBytes;
            allocate(2, dstBytes);
            auto spV = spH;
            spV.rowOffset = row; spV.rows = band.rows;
            spV.stage = static_cast<uint32_t>(SpatialKernel::TextureApplyV);
            dispatchSpatial(spV, 0, 2, 5);
            read(output.pixels.data() + size_t(row) * w, dstBytes);
            row += band.rows;
        }
    }

    void spatialSharpenV2Bands(const ImageData& input, ImageData& output, float amount,
                               const SharpenV2Options& opts) {
        glUseProgram(spatialProgram);
        uploadField(nullptr);
        const uint32_t w = static_cast<uint32_t>(input.width);
        const uint32_t h = static_cast<uint32_t>(input.height);
        const float radius = std::clamp(opts.radius, 0.5f, 3.0f);
        SpatialGpuParams spSharp{};
        spSharp.strength = std::clamp(amount, 0.0f, 2.0f);
        spSharp.sharpenDetail = opts.detail;
        spSharp.sharpenMasking = opts.masking;
        spSharp.sharpenRadius = radius;
        fillSpatialGaussianWeights(radius, 9, spSharp);
        const uint32_t rMask = opts.masking > 0.0f
            ? static_cast<uint32_t>(std::clamp(static_cast<int>(std::ceil(3.0f * 0.5f * radius)), 1, 5))
            : 0u;
        const uint32_t halo = rMask + std::max(spSharp.radius, 1u) + 1u;
        const PhotoBands plan(w, h, w, h, std::min(kPhotoTileBytes, blockLimit), dispatchLimit);
        const size_t rowBytes = static_cast<size_t>(w) * sizeof(RGB);
        for (uint32_t row = 0; row < h;) {
            const auto band = plan.at(row, halo);
            const uint32_t bandRows = band.last - band.first + 1u;
            const size_t bandBytes = size_t(bandRows) * rowBytes;
            upload(input.pixels.data() + size_t(band.first) * w, bandBytes);
            allocate(5, bandBytes);
            allocate(6, bandBytes);
            auto sp = spSharp;
            sp.width = w; sp.height = h;
            sp.rowOffset = band.first; sp.rows = bandRows;
            sp.srcRowOffset = band.first; sp.auxRowOffset = band.first;
            sp.bandDims[0] = bandRows; sp.bandDims[1] = bandRows;

            sp.stage = static_cast<uint32_t>(SpatialKernel::SharpenPrepH);
            dispatchSpatial(sp, 0, 5, 0);
            sp.stage = static_cast<uint32_t>(SpatialKernel::SharpenPrepV);
            dispatchSpatial(sp, 5, 6, 5);
            int auxSlot = 6;
            auto spApply = sp;
            if (rMask > 0u) {
                auto spMask = sp;
                fillSpatialGaussianWeights(0.5f * radius, 5, spMask);
                spMask.stage = static_cast<uint32_t>(SpatialKernel::SharpenMaskH);
                dispatchSpatial(spMask, 6, 5, 6);
                auxSlot = 5;
                spApply = spMask;
            }
            const size_t dstBytes = size_t(band.rows) * rowBytes;
            allocate(2, dstBytes);
            spApply.rowOffset = row; spApply.rows = band.rows;
            spApply.stage = static_cast<uint32_t>(SpatialKernel::SharpenApply);
            dispatchSpatial(spApply, 0, 2, auxSlot);
            read(output.pixels.data() + size_t(row) * w, dstBytes);
            row += band.rows;
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

bool GlesPhotoRenderer::isReadyForQuery() const noexcept {
    return impl_ != nullptr || (!initUnavailable_ && retry_.ready(glesRetryNow()));
}

bool GlesPhotoRenderer::renderImpl(const ImageData& input, ColorSpace inputSpace,
    const RenderParams& params, uint32_t width, uint32_t height, uint64_t revision, ImageData& output,
    GpuRenderOutcome& outcome) {
    outcome = {};
    if (params.lut && params.lut->requiresCPU()) {
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability, "LUT requires CPU evaluation"};
        return false;
    }
    const bool useDcp = params.dcp && params.lutStrength > 0.0f;
    const bool useLut = params.lut && params.lutStrength > 0.0f;
    if (useDcp && useLut) {
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability,
            "Cannot combine DCP look and 3D LUT in GLES pass"};
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
        checkProcessingCancellation();
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
        CurveUbo ubo{};
        const auto custom = toneCurveGpuParameters(params.customCurve);
        ubo.curveCounts[0] = custom.count;
        if (custom.count) {
            std::memcpy(&ubo.curveRanges[0], custom.ranges, sizeof(custom.ranges));
            std::memcpy(&ubo.curveTangents[0], custom.tangents, sizeof(custom.tangents));
        }
        for (size_t ch = 0; ch < 3; ++ch) {
            const auto chParams = toneCurveGpuParameters(params.channelCurves[ch]);
            ubo.curveCounts[ch + 1] = chParams.count;
            if (chParams.count) {
                const size_t base = (ch + 1) * 32;
                std::memcpy(&ubo.curveRanges[base], chParams.ranges, sizeof(chParams.ranges));
                std::memcpy(&ubo.curveTangents[base], chParams.tangents, sizeof(chParams.tangents));
            }
        }
        ubo.curveFlags[0] = params.curveApplyToLuminosity ? 1u : 0u;
        const auto parametric = toneCurveParametricGpuParameters(params.parametricCurve);
        ubo.curveFlags[1] = parametric.active;
        std::memcpy(ubo.parametricAmps, parametric.amps, sizeof(parametric.amps));
        std::memcpy(ubo.parametricSplits, parametric.splits, sizeof(parametric.splits));
        glBindBuffer(GL_UNIFORM_BUFFER, context.curveUbo);
        const bool anyCurve = ubo.curveCounts[0] || ubo.curveCounts[1] || ubo.curveCounts[2] || ubo.curveCounts[3];
        glBufferSubData(GL_UNIFORM_BUFFER, 0, anyCurve ? sizeof(CurveUbo) : 64, &ubo);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, context.curveUbo);
        const ColorScienceGpuParams csUbo = colorScienceGpuParameters(params);
        glBindBuffer(GL_UNIFORM_BUFFER, context.colorScienceUbo);
        glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(ColorScienceGpuParams), &csUbo);
        glBindBufferBase(GL_UNIFORM_BUFFER, 2, context.colorScienceUbo);
        glUniform1i(context.uniform("hslActive"), params.hsl.active());
        glUniform3f(context.uniform("toneControls"),
            params.toneControls.blackPoint, params.toneControls.whitePoint, params.toneControls.vibrance);
        const auto grading = colorGradingParameters(params.colorGrading);
        const float coefficients[16] = {
            grading.coefficients[0].r, grading.coefficients[0].g, grading.coefficients[0].b, grading.luminance[0],
            grading.coefficients[1].r, grading.coefficients[1].g, grading.coefficients[1].b, grading.luminance[1],
            grading.coefficients[2].r, grading.coefficients[2].g, grading.coefficients[2].b, grading.luminance[2],
            grading.coefficients[3].r, grading.coefficients[3].g, grading.coefficients[3].b, grading.luminance[3]
        };
        glUniform4fv(context.uniform("colorGrading[0]"), 4, coefficients);
        glUniform4f(context.uniform("colorGradingMix"), grading.blending, grading.balance, 0.0f, 0.0f);
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
        context.setLut(useLut ? params.lut : nullptr);
        context.setAuxAndDcp(params, useDcp);
        const bool defringeActive = params.defringe.active();
        const bool dehazeActive = params.atmosphere.dehaze != 0.0f;
        const bool clarityActive = params.atmosphere.clarity != 0.0f;
        const bool textureActive = params.atmosphere.texture != 0.0f;
        const bool sharpenV2Active = params.sharpening > 0.0f && params.sharpenV2.luminanceV2;
        const bool nativeFilters = defringeActive || params.atmosphere.active() || sharpenV2Active ||
            params.effects.active() || params.filmOptics.active() || params.chromaDenoise != 0 ||
            params.noiseReduction > 0 || params.sharpening > 0 || params.preserveSourceResolution;
        if (nativeFilters) {
            context.cachedRevision = 0;
            const int pw = input.width;
            const int ph = input.height;
            const int diagSrcW = params.atmosphereSourceWidth > 0 ? params.atmosphereSourceWidth : pw;
            const int diagSrcH = params.atmosphereSourceHeight > 0 ? params.atmosphereSourceHeight : ph;
            ImageData native(pw, ph);
            if (defringeActive) {
                context.bands(input, pw, ph, 2, &native, 1);
                SpatialGpuParams spDefringe{};
                spDefringe.stage = static_cast<uint32_t>(SpatialKernel::Defringe);
                spDefringe.defringePurpleAmount = params.defringe.purpleAmount;
                spDefringe.defringePurpleHue = params.defringe.purpleHue;
                spDefringe.defringeGreenAmount = params.defringe.greenAmount;
                spDefringe.defringeGreenHue = params.defringe.greenHue;
                ImageData defringed(pw, ph);
                context.spatialBands(native, defringed, spDefringe, 3u, nullptr);
                context.setAuxAndDcp(params, useDcp);
                context.bands(defringed, pw, ph, 2, &native, dehazeActive ? 2 : 2);
                if (useDcp && context.hasDcpInvalid()) {
                    outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, "Non-finite DCP stage"};
                    return false;
                }
                if (dehazeActive) {
                    const auto dehazeState = buildDehazeAnalysis(native, diagSrcW, diagSrcH, params.processingVersion);
                    std::vector<float> dehazeData;
                    SpatialGpuParams spDehaze{};
                    spDehaze.stage = static_cast<uint32_t>(SpatialKernel::Dehaze);
                    spDehaze.strength = params.atmosphere.dehaze;
                    packDehazeAnalysisBuffer(dehazeState, dehazeData, spDehaze);
                    ImageData dehazed(pw, ph);
                    context.spatialBands(native, dehazed, spDehaze, 0u, &dehazeData);
                    native = std::move(dehazed);
                }
                ImageData toned(pw, ph);
                context.bands(native, pw, ph, 2, &toned, 3);
                native = std::move(toned);
            } else if (dehazeActive) {
                context.bands(input, pw, ph, 2, &native, 4);
                if (useDcp && context.hasDcpInvalid()) {
                    outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, "Non-finite DCP stage"};
                    return false;
                }
                const auto dehazeState = buildDehazeAnalysis(native, diagSrcW, diagSrcH, params.processingVersion);
                std::vector<float> dehazeData;
                SpatialGpuParams spDehaze{};
                spDehaze.stage = static_cast<uint32_t>(SpatialKernel::Dehaze);
                spDehaze.strength = params.atmosphere.dehaze;
                packDehazeAnalysisBuffer(dehazeState, dehazeData, spDehaze);
                ImageData dehazed(pw, ph);
                context.spatialBands(native, dehazed, spDehaze, 0u, &dehazeData);
                context.setAuxAndDcp(params, false);
                context.bands(dehazed, pw, ph, 2, &native, 3);
            } else {
                context.bands(input, pw, ph, 2, &native, 0);
                if (useDcp && context.hasDcpInvalid()) {
                    outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, "Non-finite DCP stage"};
                    return false;
                }
            }
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
            if (params.noiseReduction > 0) {
                lastGpuFilterOutcome() = {};
                if (!gpuDetailFilter(native, params.noiseReduction, 0.0f)) {
                    return failFilter("GLES detail filter failed");
                }
            }
            if (clarityActive) {
                const auto clarityState = buildClarityField(native, diagSrcW, diagSrcH, params.processingVersion);
                std::vector<float> clarityData;
                SpatialGpuParams spClarity{};
                spClarity.stage = static_cast<uint32_t>(SpatialKernel::Clarity);
                spClarity.strength = params.atmosphere.clarity;
                packClarityFieldBuffer(clarityState, clarityData, spClarity);
                ImageData clarified(pw, ph);
                context.spatialBands(native, clarified, spClarity, 0u, &clarityData);
                native = std::move(clarified);
            }
            if (textureActive) {
                const float texSigma = textureBlurSigma(pw, ph);
                ImageData textured(pw, ph);
                context.spatialTextureBands(native, textured, texSigma, params.atmosphere.texture);
                native = std::move(textured);
            }
            if (params.filmOptics.active()) {
                lastGpuFilterOutcome() = {};
                if (!gpuFilmOptics(native, params.filmOptics)) {
                    return failFilter("GLES film optics filter failed");
                }
            }
            if (sharpenV2Active) {
                ImageData sharpened(pw, ph);
                context.spatialSharpenV2Bands(native, sharpened, params.sharpening, params.sharpenV2);
                native = std::move(sharpened);
            } else if (params.sharpening > 0) {
                lastGpuFilterOutcome() = {};
                if (!gpuDetailFilter(native, 0.0f, params.sharpening)) {
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
                glUseProgram(context.program);
                glUniform1i(context.uniform("evalPhase"), 0);
                ImageData resized(static_cast<int>(width), static_cast<int>(height));
                context.bands(native, width, height, 4, &resized, 0);
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
        const bool cache = preview && !useDcp && revision != 0 &&
            bytes <= std::min(kCacheBytes, context.blockLimit) && result.pixels.size() <= context.dispatchLimit;
        if (cache) {
            if (context.cachedRevision != revision || context.cachedWidth != width || context.cachedHeight != height) {
                context.cachedRevision = 0;
                context.allocate(1, bytes);
                context.bands(input, width, height, 0, nullptr, 0);
                context.cachedRevision = revision; context.cachedWidth = width; context.cachedHeight = height;
            }
            context.allocate(2, bytes);
            context.sizeUniform("sourceSize", width, height);
            context.sizeUniform("destinationSize", width, height);
            context.dispatch(1, 2, result.pixels.size(), 0, 0, 0, 1, 0);
            context.read(result.pixels.data(), bytes);
        } else {
            context.bands(input, width, height, preview ? 3 : 2, &result, 0);
            if (useDcp && context.hasDcpInvalid()) {
                outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, "Non-finite DCP stage"};
                return false;
            }
        }
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
