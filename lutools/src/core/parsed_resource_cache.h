#pragma once

#include <algorithm>
#include <list>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace sony2fuji {
template <typename Value, size_t Capacity = 8>
class ParsedResourceCache {
    struct Entry { std::string path, digest; Value value; };
    std::mutex mutex_;
    std::list<Entry> entries_;
public:
    std::optional<Value> find(std::string_view path, std::string_view digest) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto it = std::find_if(entries_.begin(), entries_.end(), [&](const Entry& e) { return e.path == path; });
        if (it == entries_.end()) return std::nullopt;
        if (it->digest != digest) { entries_.erase(it); return std::nullopt; }
        entries_.splice(entries_.begin(), entries_, it);
        return entries_.front().value;
    }
    void evict(std::string_view path) {
        std::lock_guard<std::mutex> lock(mutex_);
        entries_.remove_if([&](const Entry& e) { return e.path == path; });
    }
    Value put(std::string path, std::string digest, Value value) {
        std::lock_guard<std::mutex> lock(mutex_);
        entries_.remove_if([&](const Entry& e) { return e.path == path; });
        entries_.push_front({std::move(path), std::move(digest), std::move(value)});
        if (entries_.size() > Capacity) entries_.pop_back();
        return entries_.front().value;
    }
};
} // namespace sony2fuji
