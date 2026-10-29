#pragma once

#include <cstdint>
#include <exception>

namespace sony2fuji {

class ProcessingCancelled : public std::exception {
public:
    const char* what() const noexcept override { return "Processing cancelled"; }
};

struct ProcessingCancellation {
    int32_t (*callback)(void*) = nullptr;
    void* context = nullptr;
    bool cancelled() const { return callback && callback(context) != 0; }
    void check() const { if (cancelled()) throw ProcessingCancelled(); }
};

inline thread_local ProcessingCancellation processingCancellation;

// 只在调用线程安装；并行像素任务显式捕获副本，避免工作线程继承过期上下文。
class ProcessingCancellationScope {
    ProcessingCancellation previous_;
public:
    explicit ProcessingCancellationScope(ProcessingCancellation current)
        : previous_(processingCancellation) { processingCancellation = current; }
    ~ProcessingCancellationScope() { processingCancellation = previous_; }
};

inline void checkProcessingCancellation() { processingCancellation.check(); }

} // namespace sony2fuji
