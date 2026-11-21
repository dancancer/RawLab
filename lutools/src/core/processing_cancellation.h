#pragma once

#include <atomic>
#include <cstdint>
#include <exception>

namespace sony2fuji {

class ProcessingCancelled : public std::exception {
public:
    const char* what() const noexcept override { return "Processing cancelled"; }
};

// 取消回调可能非粘性：仅单次返回非零，后续轮询返回 0。latch 指向所属
// ProcessingCancellationScope 持有的单向原子锁存，首次观测到非零后，所有线程的
// cancelled()/check() 先读锁存短路，跳块/早退后的二次轮询不会把取消吞掉。
struct ProcessingCancellation {
    int32_t (*callback)(void*) = nullptr;
    void* context = nullptr;
    std::atomic<bool>* latch = nullptr;
    bool cancelled() const {
        if (latch && latch->load(std::memory_order_acquire)) return true;
        if (!callback) return false;
        if (callback(context) != 0) {
            if (latch) latch->store(true, std::memory_order_release);
            return true;
        }
        return false;
    }
    void check() const { if (cancelled()) throw ProcessingCancelled(); }
};

inline thread_local ProcessingCancellation processingCancellation;

// 只在调用线程安装；并行像素任务显式捕获副本，避免工作线程继承过期上下文。
// scope 拥有本次操作生命周期的单向锁存并按指针传给所安装的 ProcessingCancellation
// 副本（含其在线程间被复制的副本）；嵌套 scope 以已锁存状态为初值，防止外层已锁存的
// 取消在内层用同一回调重新轮询时被 one-shot 语义冲掉。
class ProcessingCancellationScope {
    ProcessingCancellation previous_;
    std::atomic<bool> latched_;
public:
    explicit ProcessingCancellationScope(ProcessingCancellation current)
        : previous_(processingCancellation),
          latched_(previous_.latch != nullptr && previous_.latch->load(std::memory_order_acquire)) {
        current.latch = &latched_;
        processingCancellation = current;
    }
    ~ProcessingCancellationScope() { processingCancellation = previous_; }
};

inline void checkProcessingCancellation() { processingCancellation.check(); }

} // namespace sony2fuji
