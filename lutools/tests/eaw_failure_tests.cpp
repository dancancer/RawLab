#include "core/wavelet_denoise.h"
#include "processing_reference_fixture.h"
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <new>

// 在任何缓存或样本分析成功之前注入分配失败，覆盖公共入口的异常边界。
static std::atomic<bool> failNextAllocation{false};
void* operator new(std::size_t size) {
    if (failNextAllocation.exchange(false)) throw std::bad_alloc();
    if (void* memory=std::malloc(size ? size : 1)) return memory;
    throw std::bad_alloc();
}
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete(void* memory,std::size_t) noexcept { std::free(memory); }

int main() {
    using namespace sony2fuji;
    auto image=processingReferenceFixture();
    const auto original=image;
    WaveletDenoiseAnalysisCache cache;
    WaveletDenoiseDiagnostics diagnostics;
    const std::string key="oom-input";
    failNextAllocation=true;
    const auto code=applyWaveletDenoise(image,{true,10,72,100},&diagnostics,GpuMode::Off,&cache,key);
    if (code!=ErrorCode::OutOfMemory || diagnostics.applied ||
        diagnostics.outcome!=WaveletDenoiseOutcome::ProcessingFailure ||
        std::memcmp(image.pixels.data(),original.pixels.data(),image.pixels.size()*sizeof(RGB))!=0) return 1;
    if (applyWaveletDenoise(image,{true,10,72,100},&diagnostics,GpuMode::Off,&cache,key)!=ErrorCode::Success ||
        !diagnostics.applied) return 2;
    std::cout<<"PASS: analysis allocation failure preserves input and a later call recovers\n";
}
