#define SONY2FUJI_GLES_VM_IMPLEMENT
#include "gles_spirv_vm.h"
#include "gles_test_hooks.h"

#include "core/processing_cancellation.h"
#include "gpu/compute_denoise.h"
#include "gpu/gles_photo.h"
#include "sony2fuji/lut_parser.h"

#include <chrono>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>

using namespace sony2fuji;

namespace {

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

sony2fuji_request makeRequest() {
    sony2fuji_request r{};
    r.version = SONY2FUJI_REQUEST_VERSION;
    r.struct_size = sizeof(r);
    r.input_type = SONY2FUJI_INPUT_BUFFER;
    r.brightness = 1.f;
    r.contrast = 1.f;
    r.saturation = 1.f;
    return r;
}

bool renderPhotoSize(GlesPhotoRenderer& renderer, int w, int h, ImageData& output,
                     const std::shared_ptr<LUT3D>& lut = {}) {
    ImageData input(w, h);
    for (auto& p : input.pixels) p = RGB(.2f, .3f, .4f);
    auto req = makeRequest();
    req.lut_strength = lut ? 1.0f : 0.0f;
    return renderer.render(input, ColorSpace::sRGB, req, lut, RGB(1, 1, 1),
                           static_cast<uint32_t>(w), static_cast<uint32_t>(h), 0, output);
}

bool renderPhoto(GlesPhotoRenderer& renderer, ImageData& output) {
    return renderPhotoSize(renderer, 17, 19, output);
}

std::shared_ptr<LUT3D> makeSimpleLut() {
    std::ostringstream ss;
    ss << "#Gamma:FLog2\n#Gamut:FGamut\nLUT_3D_SIZE 2\n";
    for (int b = 0; b < 2; ++b)
        for (int g = 0; g < 2; ++g)
            for (int r = 0; r < 2; ++r)
                ss << (r * 0.9f) << ' ' << (g * 0.9f) << ' ' << (b * 0.9f) << '\n';
    auto lut = std::make_shared<LUT3D>();
    require(lut->loadFromData(ss.str()) == ErrorCode::Success, "failed to load test LUT");
    return lut;
}

void photoInitBackoff() {
    rawlabtest::resetGlesVmState();
    rawlabtest::glesVmConfig() = {};
    gles_test::now = {};

    GlesPhotoRenderer renderer;
    ImageData output(1, 1);
    output.pixels[0] = RGB(7, 8, 9);

    rawlabtest::glesVmConfig().failCreateContextRemaining = 2;
    require(!renderPhoto(renderer, output), "injected initialization failure must return false");
    require(rawlabtest::glesVmStats().createContextCalls == 1, "first attempt should try eglCreateContext once");
    require(!renderPhoto(renderer, output), "cooldown must skip immediate rebuild");
    require(rawlabtest::glesVmStats().createContextCalls == 1, "immediate retry rebuilt failed GLES renderer");
    require(output.width == 1 && output.pixels[0].r == 7, "failed render must not overwrite output");

    gles_test::now += std::chrono::milliseconds(100);
    require(!renderPhoto(renderer, output), "second initialization failure must return false");
    require(rawlabtest::glesVmStats().createContextCalls == 2, "100ms elapsed should allow second attempt");

    gles_test::now += std::chrono::milliseconds(100);
    require(!renderPhoto(renderer, output), "second cooldown must double to 200ms");
    require(rawlabtest::glesVmStats().createContextCalls == 2, "exponential cooldown was not retained");

    gles_test::now += std::chrono::milliseconds(100);
    require(renderPhoto(renderer, output), "GLES renderer did not recover after 200ms cooldown");
    require(rawlabtest::glesVmStats().createContextCalls == 3, "recovery did not rebuild exactly once");
    require(output.width == 17 && output.height == 19, "recovered render did not produce output");
}

void photoTransientGlErrorPreservesContext() {
    rawlabtest::resetGlesVmState();
    rawlabtest::glesVmConfig() = {};
    gles_test::now = {};

    GlesPhotoRenderer renderer;
    ImageData output;
    require(renderPhoto(renderer, output), "initial healthy GLES render must succeed");
    const size_t createdBefore = rawlabtest::glesVmStats().createContextCalls;
    const size_t destroyedBefore = rawlabtest::glesVmStats().destroyContextCalls;

    // 瞬态 GL_OUT_OF_MEMORY 不应销毁健康 EGL 上下文，也不应触发重建退避。
    rawlabtest::glesVmConfig().injectNextGlError = GL_OUT_OF_MEMORY;
    require(!renderPhoto(renderer, output), "injected GL_OUT_OF_MEMORY must fail the render");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroyedBefore,
        "transient GL_OUT_OF_MEMORY destroyed a healthy GLES context");
    require(renderPhoto(renderer, output),
        "next render after transient GL_OUT_OF_MEMORY should succeed without cooldown or rebuild");
    require(rawlabtest::glesVmStats().createContextCalls == createdBefore,
        "transient GL_OUT_OF_MEMORY triggered unnecessary context rebuild");

    // 取消同样不应销毁健康设备或进入退避。
    try {
        ProcessingCancellationScope scope({[](void*) -> int32_t { return 1; }, nullptr});
        renderPhoto(renderer, output);
        require(false, "cancellation was swallowed");
    } catch (const ProcessingCancelled&) {}
    require(rawlabtest::glesVmStats().destroyContextCalls == destroyedBefore,
        "cancellation destroyed a healthy GLES context");
    require(renderPhoto(renderer, output), "cancellation incorrectly entered cooldown");
    require(rawlabtest::glesVmStats().createContextCalls == createdBefore,
        "cancellation triggered unnecessary context rebuild");
}

void photoContextLostTriggersBackoff() {
    rawlabtest::resetGlesVmState();
    rawlabtest::glesVmConfig() = {};
    gles_test::now = {};

    GlesPhotoRenderer renderer;
    ImageData output;
    require(renderPhoto(renderer, output), "initial healthy GLES render must succeed");
    const size_t createdBefore = rawlabtest::glesVmStats().createContextCalls;
    const size_t destroyedBefore = rawlabtest::glesVmStats().destroyContextCalls;

    rawlabtest::glesVmConfig().injectNextMakeCurrentError = EGL_CONTEXT_LOST;
    require(!renderPhoto(renderer, output), "EGL_CONTEXT_LOST must fail the render");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroyedBefore + 1,
        "EGL_CONTEXT_LOST must destroy the lost GLES context");
    require(!renderPhoto(renderer, output), "lost GLES context must enter cooldown");
    require(rawlabtest::glesVmStats().createContextCalls == createdBefore,
        "lost GLES context rebuilt immediately without cooldown");

    gles_test::now += std::chrono::milliseconds(100);
    require(renderPhoto(renderer, output), "lost GLES context did not recover after cooldown");
    require(rawlabtest::glesVmStats().createContextCalls == createdBefore + 1,
        "lost GLES context did not rebuild exactly once after cooldown");
}

void filterTransientErrorAndContextLoss() {
    rawlabtest::resetGlesVmState();
    rawlabtest::glesVmConfig() = {};
    gles_test::now = {};

    ImageData input(17, 19);
    for (auto& p : input.pixels) p = RGB(.25f, .35f, .45f);
    require(gpuDetailFilter(input, .2f, 0.f), "initial healthy GLES filter must succeed");
    const size_t createdBefore = rawlabtest::glesVmStats().createContextCalls;
    const size_t destroyedBefore = rawlabtest::glesVmStats().destroyContextCalls;

    // 瞬态 GL_OUT_OF_MEMORY 不应销毁共享滤镜上下文。
    rawlabtest::glesVmConfig().injectNextGlError = GL_OUT_OF_MEMORY;
    require(!gpuDetailFilter(input, .2f, 0.f), "injected GL_OUT_OF_MEMORY must fail filter");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroyedBefore,
        "transient GL_OUT_OF_MEMORY destroyed healthy GLES filter context");
    require(gpuDetailFilter(input, .2f, 0.f),
        "GLES filter should recover immediately after transient GL_OUT_OF_MEMORY");
    require(rawlabtest::glesVmStats().createContextCalls == createdBefore,
        "transient GL_OUT_OF_MEMORY rebuilt healthy GLES filter context");

    // 不可恢复 EGL_CONTEXT_LOST 应销毁上下文并进入指数退避。
    rawlabtest::glesVmConfig().injectNextMakeCurrentError = EGL_CONTEXT_LOST;
    require(!gpuDetailFilter(input, .2f, 0.f), "EGL_CONTEXT_LOST must fail filter");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroyedBefore + 1,
        "EGL_CONTEXT_LOST must destroy lost GLES filter context");
    require(!gpuDetailFilter(input, .2f, 0.f), "lost GLES filter context must enter cooldown");
    require(rawlabtest::glesVmStats().createContextCalls == createdBefore,
        "lost GLES filter context rebuilt immediately");

    gles_test::now += std::chrono::milliseconds(100);
    require(gpuDetailFilter(input, .2f, 0.f), "lost GLES filter context did not recover after cooldown");
    require(rawlabtest::glesVmStats().createContextCalls == createdBefore + 1,
        "lost GLES filter context did not rebuild once after cooldown");
}

void photoResizeOomAndLutOomResetState() {
    rawlabtest::glesVmConfig() = {};
    gles_test::now = {};

    GlesPhotoRenderer renderer;
    ImageData output;
    require(renderPhotoSize(renderer, 17, 19, output), "initial 17x19 render must succeed");
    const size_t destroysBefore = rawlabtest::glesVmStats().destroyContextCalls;

    // 17x19 -> 33x35 glBufferData OOM 后，capacities[index] 必须归零，否则后续 17x19 误以为缓冲仍有效。
    rawlabtest::glesVmConfig().failNextBufferDataOom = true;
    require(!renderPhotoSize(renderer, 33, 35, output), "33x35 glBufferData OOM must fail");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroysBefore,
        "33x35 glBufferData OOM must preserve healthy context");

    require(renderPhotoSize(renderer, 17, 19, output), "first 17x19 after OOM must succeed");
    require(renderPhotoSize(renderer, 17, 19, output), "second 17x19 after OOM must succeed");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroysBefore,
        "17x19 recovery after OOM must not destroy context");

    // setLut 的 glTexImage3D OOM 后，cachedLut 必须清零，后续同 LUT 渲染需重新上传 3D 纹理。
    auto lut = makeSimpleLut();
    const size_t texUploadsBefore = rawlabtest::glesVmStats().texImage3DCalls;
    rawlabtest::glesVmConfig().failNextTexImage3DOom = true;
    require(!renderPhotoSize(renderer, 17, 19, output, lut), "glTexImage3D OOM must fail");
    require(rawlabtest::glesVmStats().texImage3DCalls == texUploadsBefore + 1,
        "failed glTexImage3D should have attempted upload");
    require(renderPhotoSize(renderer, 17, 19, output, lut), "same LUT after OOM must re-upload and succeed");
    require(rawlabtest::glesVmStats().texImage3DCalls == texUploadsBefore + 2,
        "cachedLut was not reset before glTexImage3D, skipping re-upload");
}

void readbackMapUnmapErrorsAndStickyDrain() {
    rawlabtest::glesVmConfig() = {};
    gles_test::now = {};

    GlesPhotoRenderer renderer;
    ImageData output;
    require(renderPhoto(renderer, output), "initial render must succeed");
    const size_t destroysBefore = rawlabtest::glesVmStats().destroyContextCalls;

    // glMapBufferRange 失败且 GL 错误为 GL_CONTEXT_LOST 时，必须识别为设备丢失并销毁上下文。
    rawlabtest::glesVmConfig().failNextMapBufferError = GL_CONTEXT_LOST;
    require(!renderPhoto(renderer, output), "glMapBufferRange GL_CONTEXT_LOST must fail");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroysBefore + 1,
        "glMapBufferRange GL_CONTEXT_LOST must destroy lost context");
    require(!renderPhoto(renderer, output), "lost context from map failure must enter cooldown");

    gles_test::now += std::chrono::milliseconds(100);
    require(renderPhoto(renderer, output), "recovered after map GL_CONTEXT_LOST cooldown");

    // glUnmapBuffer 失败但为瞬态 GL_OUT_OF_MEMORY 时，保留上下文并排空粘滞错误，下一次应健康成功。
    const size_t destroysMid = rawlabtest::glesVmStats().destroyContextCalls;
    rawlabtest::glesVmConfig().failNextUnmapBufferError = GL_OUT_OF_MEMORY;
    require(!renderPhoto(renderer, output), "glUnmapBuffer OOM must fail");
    require(rawlabtest::glesVmStats().destroyContextCalls == destroysMid,
        "transient glUnmapBuffer OOM must preserve context");
    require(renderPhoto(renderer, output), "healthy render after glUnmapBuffer OOM must succeed");

    // gles_denoise 同理：glMapBufferRange GL_CONTEXT_LOST 销毁并退避，glUnmapBuffer OOM 保留并恢复。
    ImageData filterImg(17, 19);
    for (auto& p : filterImg.pixels) p = RGB(.3f, .4f, .5f);
    require(gpuDetailFilter(filterImg, .2f, 0.f), "initial filter must succeed");
    const size_t filterDestroys = rawlabtest::glesVmStats().destroyContextCalls;
    rawlabtest::glesVmConfig().failNextUnmapBufferError = GL_OUT_OF_MEMORY;
    require(!gpuDetailFilter(filterImg, .2f, 0.f), "filter unmap OOM must fail");
    require(rawlabtest::glesVmStats().destroyContextCalls == filterDestroys,
        "filter unmap OOM must preserve context");
    require(gpuDetailFilter(filterImg, .2f, 0.f), "filter after unmap OOM must succeed");

    rawlabtest::glesVmConfig().failNextMapBufferError = GL_CONTEXT_LOST;
    require(!gpuDetailFilter(filterImg, .2f, 0.f), "filter map GL_CONTEXT_LOST must fail");
    require(rawlabtest::glesVmStats().destroyContextCalls == filterDestroys + 1,
        "filter map GL_CONTEXT_LOST must destroy context");
    gles_test::now += std::chrono::milliseconds(100);
    require(gpuDetailFilter(filterImg, .2f, 0.f), "filter must recover after cooldown");
}

} // namespace

int main() {
    try {
        photoInitBackoff();
        photoTransientGlErrorPreservesContext();
        photoContextLostTriggersBackoff();
        filterTransientErrorAndContextLoss();
        photoResizeOomAndLutOomResetState();
        readbackMapUnmapErrorsAndStickyDrain();
        std::cout << "PASS: gpu_gles_renderer_retry\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
