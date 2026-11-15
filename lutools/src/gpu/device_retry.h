#pragma once

#include <algorithm>
#include <chrono>

namespace sony2fuji {

// 设备资源被释放后仍保留失败记忆；不 sleep，让 Auto 立即走既有 CPU 回退。
class DeviceRetry {
public:
    using Clock = std::chrono::steady_clock;
    bool ready(Clock::time_point now) const { return now >= nextAttempt_; }
    void failed(Clock::time_point now) {
        const auto delay = std::chrono::milliseconds(100 * (1 << failures_));
        failures_ = std::min(failures_ + 1, 6);
        nextAttempt_ = now + delay;
    }
    void succeeded() { failures_ = 0; nextAttempt_ = {}; }

private:
    int failures_ = 0;
    Clock::time_point nextAttempt_{};
};

} // namespace sony2fuji
