#pragma once

// Metal shader validation 在虚拟化 GPU（GitHub 托管 macOS 虚拟机里的 "Apple Paravirtual device" /
// "Apple Paravirtualized Graphics Device"）上会对任何纹理读取报 "Texture usage flags mismatch"，
// 连 usage 为 MTLTextureUsageUnknown 的纹理也不例外（#695 的 15 组描述符探针）。真实 GPU 上不报。
// 这类设备上去掉 shader validation 环境变量后重新执行本进程，像素与行为断言照常全部运行；
// 真实 GPU 上什么都不改。设备判断看 Metal 设备本身，不看是否在 CI。

#if defined(__APPLE__) && defined(SONY2FUJI_ENABLE_METAL)  // gpu-portability: metal-only shader validation is a Metal facility; D3D11/GLES builds have nothing to waive
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#if defined(__OBJC__)
#import <Metal/Metal.h>
#else
extern "C" void* MTLCreateSystemDefaultDevice(void);
#endif

namespace rawlabtest {

#if defined(__OBJC__)
inline std::string metalDeviceName() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        return device ? std::string(device.name.UTF8String) : std::string();
    }
}
#else
inline std::string metalDeviceName() {
    void* device = MTLCreateSystemDefaultDevice();
    if (!device) return {};
    auto sendObject = reinterpret_cast<void* (*)(void*, SEL)>(objc_msgSend);
    auto sendString = reinterpret_cast<const char* (*)(void*, SEL)>(objc_msgSend);
    void* name = sendObject(device, sel_registerName("name"));
    const char* utf8 = name ? sendString(name, sel_registerName("UTF8String")) : nullptr;
    std::string result = utf8 ? utf8 : "";
    sendObject(device, sel_registerName("release"));
    return result;
}
#endif

// 在 main 开头、任何其他 Metal 调用之前调用。
inline void waiveShaderValidationOnParavirtualDevice(char** argv) {
    if (const char* waived = std::getenv("RAWLAB_SHADER_VALIDATION_WAIVED")) {
        std::printf("NOTE: Metal shader validation NOT exercised on \"%s\": it reports a false "
                    "\"Texture usage flags mismatch\" for every texture read on paravirtual GPUs "
                    "(see #695); all pixel and behaviour assertions still run.\n", waived);
        std::fflush(stdout);
        return;
    }
    if (!std::getenv("MTL_SHADER_VALIDATION")) return;
    const std::string name = metalDeviceName();
    if (name.find("Paravirtual") == std::string::npos) return;
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::vector<char> path(size + 1, '\0');
    if (_NSGetExecutablePath(path.data(), &size) != 0) return;
    // 绿色的托管运行不会显示测试输出（ctest --output-on-failure），所以把降级写进 job summary。
    if (const char* summary = std::getenv("GITHUB_STEP_SUMMARY")) {
        if (FILE* file = std::fopen(summary, "a")) {
            std::fprintf(file, "- :warning: `%s`: Metal shader validation not exercised on \"%s\" "
                               "(paravirtual GPU false positive, #695); pixel and behaviour assertions still ran.\n",
                         std::strrchr(path.data(), '/') ? std::strrchr(path.data(), '/') + 1 : path.data(), name.c_str());
            std::fclose(file);
        }
    }
    unsetenv("MTL_SHADER_VALIDATION");
    unsetenv("MTL_SHADER_VALIDATION_REPORT_TO_STDERR");
    unsetenv("MTL_SHADER_VALIDATION_ABORT_ON_FAULT");
    setenv("RAWLAB_SHADER_VALIDATION_WAIVED", name.c_str(), 1);
    std::fflush(stdout);
    std::fflush(stderr);
    execv(path.data(), argv);
    std::perror("execv without shader validation");
    std::exit(1);
}

} // namespace rawlabtest
#else
namespace rawlabtest {
inline void waiveShaderValidationOnParavirtualDevice(char**) {}
} // namespace rawlabtest
#endif
