#pragma once

#include "compute_denoise.h"
#include <cstddef>
#include <memory>
#include <utility>
#include <vector>

namespace sony2fuji {

// Pools GPU FilterBuffers by float capacity so repeated and multi-band filter
// passes reuse existing device allocations without buffer churn.
class FilterBufferPool {
public:
    explicit FilterBufferPool(size_t maxIdleFloats = 16 * 1024 * 1024)
        : maxIdleFloats_(maxIdleFloats) {}

    template <typename CreateFn, typename WriteFn>
    FilterBufferPtr acquire(size_t count, const float* input, CreateFn&& create, WriteFn&& write) {
        size_t bestIndex = entries_.size();
        for (size_t i = 0; i < entries_.size(); ++i) {
            const auto& entry = entries_[i];
            if (entry->inUse || entry->capacity < count) continue;
            if (bestIndex == entries_.size() || entry->capacity < entries_[bestIndex]->capacity) {
                bestIndex = i;
            }
        }
        if (bestIndex < entries_.size()) {
            // 值拷贝 shared_ptr，避免 trimIdleToBudget() erase 前置空闲项使 entries_[bestIndex] 引用悬垂或串用。
            auto entry = entries_[bestIndex];
            if (input) write(*entry->backing, count, input);
            entry->inUse = true;
            trimIdleToBudget();
            return std::make_unique<Lease>(std::move(entry));
        }

        trimIdleToBudget(count);
        auto entry = std::make_shared<Entry>();
        entry->backing = create(count, input);
        entry->capacity = count;
        entry->inUse = true;
        entries_.push_back(entry);
        return std::make_unique<Lease>(entry);
    }

    void trimIdleToBudget(size_t incomingFloats = 0) {
        const size_t keep = incomingFloats >= maxIdleFloats_ ? 0 : maxIdleFloats_ - incomingFloats;
        size_t idle = idleFloats();
        if (idle <= keep) return;
        for (size_t i = entries_.size(); i > 0 && idle > keep; --i) {
            if (!entries_[i - 1]->inUse) {
                idle -= entries_[i - 1]->capacity;
                entries_.erase(entries_.begin() + static_cast<ptrdiff_t>(i - 1));
            }
        }
    }

    size_t idleFloats() const {
        size_t total = 0;
        for (const auto& entry : entries_) {
            if (!entry->inUse) total += entry->capacity;
        }
        return total;
    }

    size_t entryCount() const { return entries_.size(); }

    void clear() { entries_.clear(); }

private:
    struct Entry {
        FilterBufferPtr backing;
        size_t capacity = 0;
        bool inUse = false;
    };

    class Lease final : public FilterBuffer {
    public:
        explicit Lease(std::shared_ptr<Entry> entry) : entry_(std::move(entry)) {}
        ~Lease() override {
            if (entry_) entry_->inUse = false;
        }
        FilterBuffer& underlying() override { return *entry_->backing; }
        const FilterBuffer& underlying() const override { return *entry_->backing; }

    private:
        std::shared_ptr<Entry> entry_;
    };

    size_t maxIdleFloats_;
    std::vector<std::shared_ptr<Entry>> entries_;
};

} // namespace sony2fuji
