#pragma once

#include <algorithm>
#include <cstdint>
#include <thread>

namespace sony2fuji {

struct HdrProgress {
    void (*callback)(void*, uint32_t, uint32_t) = nullptr;
    void* context = nullptr;
    uint32_t rangeStart = 0;
    uint32_t rangeEnd = 1000;
    uint32_t rangeTotal = 1000;
    uint32_t* highWater = nullptr;
    bool* emitted = nullptr;
    std::thread::id ownerThread{};
};

inline thread_local HdrProgress hdrProgress{};

// 仅在调用线程安装并向上游分发进度；并行工作线程与子作用域不得直接越级回退高水位。
class HdrProgressScope {
    HdrProgress previous_;
    uint32_t highWater_ = 0;
    bool emitted_ = false;

public:
    explicit HdrProgressScope(HdrProgress current) : previous_(hdrProgress) {
        if (current.callback) {
            current.rangeStart = 0;
            current.rangeEnd = 1000;
            current.rangeTotal = 1000;
            current.highWater = &highWater_;
            current.emitted = &emitted_;
            current.ownerThread = std::this_thread::get_id();
        } else {
            current = HdrProgress{};
        }
        hdrProgress = current;
    }

    ~HdrProgressScope() { hdrProgress = previous_; }

    HdrProgressScope(const HdrProgressScope&) = delete;
    HdrProgressScope& operator=(const HdrProgressScope&) = delete;
};

class HdrProgressSubrangeScope {
    HdrProgress previous_;

public:
    HdrProgressSubrangeScope(uint32_t start, uint32_t end, uint32_t parentTotal = 1000) : previous_(hdrProgress) {
        if (!previous_.callback || parentTotal == 0) {
            return;
        }
        const uint32_t clampedStart = std::min(start, parentTotal);
        const uint32_t clampedEnd = std::max(clampedStart, std::min(end, parentTotal));
        const uint64_t span = previous_.rangeEnd - previous_.rangeStart;
        HdrProgress mapped = previous_;
        mapped.rangeStart = previous_.rangeStart + static_cast<uint32_t>((span * clampedStart) / parentTotal);
        mapped.rangeEnd = previous_.rangeStart + static_cast<uint32_t>((span * clampedEnd) / parentTotal);
        if (mapped.rangeEnd < mapped.rangeStart) {
            mapped.rangeEnd = mapped.rangeStart;
        }
        hdrProgress = mapped;
    }

    ~HdrProgressSubrangeScope() { hdrProgress = previous_; }

    HdrProgressSubrangeScope(const HdrProgressSubrangeScope&) = delete;
    HdrProgressSubrangeScope& operator=(const HdrProgressSubrangeScope&) = delete;
};

inline void reportHdrProgress(uint32_t completed, uint32_t total) {
    if (!hdrProgress.callback || total == 0 || !hdrProgress.highWater ||
        std::this_thread::get_id() != hdrProgress.ownerThread) {
        return;
    }
    const uint32_t clamped = std::min(completed, total);
    const uint64_t span = hdrProgress.rangeEnd - hdrProgress.rangeStart;
    uint32_t mapped = hdrProgress.rangeStart + static_cast<uint32_t>((span * clamped) / total);
    mapped = std::max(mapped, *hdrProgress.highWater);
    mapped = std::min(mapped, hdrProgress.rangeTotal);
    const bool alreadyEmitted = hdrProgress.emitted && *hdrProgress.emitted;
    if (alreadyEmitted && mapped == *hdrProgress.highWater) {
        return;
    }
    *hdrProgress.highWater = mapped;
    if (hdrProgress.emitted) {
        *hdrProgress.emitted = true;
    }
    hdrProgress.callback(hdrProgress.context, mapped, hdrProgress.rangeTotal);
}

} // namespace sony2fuji
