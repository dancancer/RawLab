#include "sony2fuji/gpu/lut_gpu.h"
#include <GLES3/gl31.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>

using namespace sony2fuji;

namespace {
enum class Fault { None, Allocate, Upload, Dispatch, Map, Unmap };
Fault fault = Fault::None;
int faultCalls = 0;
GLint groupLimit = 0;
GLint64 blockLimit = 0;
size_t dispatches = 0;

bool fail(Fault operation) {
    // 上传/计算/读回的第二块失败，验证首块结果不会污染 CPU 回退输入。
    return fault == operation && ++faultCalls == (operation == Fault::Allocate ? 1 : 2);
}

void require(bool value, const std::string& label) {
    if (!value) {
        std::cerr << "FAIL " << label << std::endl;
        std::exit(1);
    }
    std::cout << "PASS " << label << std::endl;
}

ImageData input(size_t count) {
    ImageData image;
    image.width = static_cast<int>(count);
    image.height = 1;
    if (count == 2560 * 3840) { image.width = 2560; image.height = 3840; }
    if (count == 6000 * 4000) { image.width = 6000; image.height = 4000; }
    if (count == 61000000 || count == 100000000) {
        image.width = 10000; image.height = static_cast<int>(count / 10000);
    }
    image.pixels.resize(count);
    for (size_t i = 0; i < count; ++i) {
        image.pixels[i] = RGB{float(i % 97) / 80 - .1f,
            float(i % 89) / 70 + .1f, float(i % 83) / 60 + .2f};
    }
    return image;
}

void compare(const ImageData& expected, const ImageData& actual, float tolerance,
    const std::string& label) {
    require(expected.pixels.size() == actual.pixels.size(), label + " size");
    float maximum = 0;
    for (size_t i = 0; i < expected.pixels.size(); ++i) {
        const auto& a = expected.pixels[i];
        const auto& b = actual.pixels[i];
        if (!std::isfinite(b.r) || !std::isfinite(b.g) || !std::isfinite(b.b)) {
            require(false, label + " finite pixels");
        }
        maximum = std::max({maximum, std::abs(a.r - b.r), std::abs(a.g - b.g), std::abs(a.b - b.b)});
    }
    std::cout << "DIFF " << label << " max=" << maximum << std::endl;
    require(maximum <= tolerance, label);
}

void parity(const std::shared_ptr<LUT3D>& lut, size_t count) {
    auto expected = input(count);
    auto actual = expected;
    require(applyLUTWithConfig(lut, expected, {GpuMode::Off}) == ErrorCode::Success, "CPU LUT");
    dispatches = 0;
    require(applyLUTWithConfig(lut, actual, {GpuMode::Force}) == ErrorCode::Success, "Force LUT");
    require(dispatches > 0, "Force dispatched real GLES work");
    compare(expected, actual, 2e-5f, std::to_string(count) + " pixels CPU/GLES");
    actual = input(count);
    dispatches = 0;
    require(applyLUTWithConfig(lut, actual, {GpuMode::Auto}) == ErrorCode::Success, "Auto LUT");
    require(dispatches > 0, "Auto dispatched GLES work");
    compare(expected, actual, 2e-5f, std::to_string(count) + " pixels CPU/Auto");
}
}

// 仅测试二进制链接包装 GL 边界；正常路径仍由真机驱动执行。
extern "C" {
void __real_glGetIntegeri_v(GLenum, GLuint, GLint*);
void __wrap_glGetIntegeri_v(GLenum name, GLuint index, GLint* value) {
    __real_glGetIntegeri_v(name, index, value);
    if (name == GL_MAX_COMPUTE_WORK_GROUP_COUNT && index == 0 && groupLimit)
        *value = std::min(*value, groupLimit);
}
void __real_glGetInteger64v(GLenum, GLint64*);
void __wrap_glGetInteger64v(GLenum name, GLint64* value) {
    __real_glGetInteger64v(name, value);
    if (name == GL_MAX_SHADER_STORAGE_BLOCK_SIZE && blockLimit)
        *value = std::min(*value, blockLimit);
}
void __real_glBufferData(GLenum, GLsizeiptr, const void*, GLenum);
void __wrap_glBufferData(GLenum target, GLsizeiptr bytes, const void* data, GLenum usage) {
    if (fail(Fault::Allocate) || (blockLimit && bytes > blockLimit)) bytes = -1;
    __real_glBufferData(target, bytes, data, usage);
}
void __real_glBufferSubData(GLenum, GLintptr, GLsizeiptr, const void*);
void __wrap_glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr bytes, const void* data) {
    __real_glBufferSubData(target, fail(Fault::Upload) ? -1 : offset, bytes, data);
}
void __real_glDispatchCompute(GLuint, GLuint, GLuint);
void __wrap_glDispatchCompute(GLuint x, GLuint y, GLuint z) {
    ++dispatches;
    if (fail(Fault::Dispatch) || (groupLimit && x > GLuint(groupLimit))) {
        GLint maximum = 0;
        __real_glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, &maximum);
        x = static_cast<GLuint>(maximum) + 1;
    }
    __real_glDispatchCompute(x, y, z);
}
void* __real_glMapBufferRange(GLenum, GLintptr, GLsizeiptr, GLbitfield);
void* __wrap_glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr bytes, GLbitfield access) {
    return __real_glMapBufferRange(target, fail(Fault::Map) ? -1 : offset, bytes, access);
}
GLboolean __real_glUnmapBuffer(GLenum);
GLboolean __wrap_glUnmapBuffer(GLenum target) {
    const auto result = __real_glUnmapBuffer(target);
    return fail(Fault::Unmap) ? GL_FALSE : result;
}
}

int main(int argc, char** argv) {
    require(argc >= 2, "test mode supplied");
    const std::string mode = argv[1];
    if (mode == "groups" || mode == "failures") groupLimit = 3;
    if (mode == "block") blockLimit = 1031 * sizeof(RGB) + 7;
    const std::string fixture = "gles-lut-domain.cube";
    {
        std::ofstream file(fixture);
        file << "LUT_3D_SIZE 3\nDOMAIN_MIN -0.1 0.1 0.2\nDOMAIN_MAX 0.8 0.9 1.1\n";
        for (int b = 0; b < 3; ++b) for (int g = 0; g < 3; ++g) for (int r = 0; r < 3; ++r)
            file << .1f + b * .4f << ' ' << -.1f + r * .6f << ' ' << .2f + g * .3f << '\n';
    }
    auto lut = std::make_shared<LUT3D>();
    require(lut->loadFromFile(fixture) == ErrorCode::Success, "load nonidentity domain LUT");
    std::remove(fixture.c_str());
    if (mode == "large") {
        parity(lut, 2560 * 3840);
        parity(lut, 6000 * 4000);
        require(argc == 3 && lut->loadFromFile(argv[2]) == ErrorCode::Success, "load Samalive");
        parity(lut, 4000 * 6000);
    } else if (mode == "groups" || mode == "block") {
        const size_t limit = mode == "groups" ? 3 * 256 : 1031;
        for (size_t count : {size_t(1), size_t(255), size_t(256), size_t(257),
                            limit - 1, limit, limit + 1, limit * 3 + 17}) parity(lut, count);
    } else if (mode == "high-resolution") {
        require(argc == 3 && lut->loadFromFile(argv[2]) == ErrorCode::Success, "load Samalive");
        parity(lut, 61000000);
        parity(lut, 100000000);
    } else if (mode == "failures") {
        auto original = input(2500);
        auto expected = original;
        require(applyLUTWithConfig(lut, expected, {GpuMode::Off}) == ErrorCode::Success, "CPU fallback reference");
        parity(lut, original.pixels.size());
        for (Fault operation : {Fault::Allocate, Fault::Upload, Fault::Dispatch, Fault::Map, Fault::Unmap}) {
            const auto label = "fault " + std::to_string(static_cast<int>(operation));
            fault = operation;
            faultCalls = 0;
            auto actual = original;
            require(applyLUTWithConfig(lut, actual, {GpuMode::Force}) == ErrorCode::ProcessingError,
                label + " Force rejects GPU failure");
            require(faultCalls == (operation == Fault::Allocate ? 1 : 2), label + " Force reached fault");
            compare(original, actual, 0, label + " Force preserves source");
            faultCalls = 0;
            actual = original;
            require(applyLUTWithConfig(lut, actual, {GpuMode::Auto}) == ErrorCode::Success,
                label + " Auto falls back");
            require(faultCalls == (operation == Fault::Allocate ? 1 : 2), label + " Auto reached fault");
            compare(expected, actual, 0, label + " Auto uses untouched source");
            const auto error = glGetError();
            require(error == GL_NO_ERROR, label + " clears GL errors (" + std::to_string(error) + ")");
            fault = Fault::None;
            parity(lut, original.pixels.size());
        }
    } else {
        require(false, "unknown test mode");
    }
    std::cout << "PASS GLES LUT " << mode << std::endl;
}
