#pragma once
#include "wavelet_denoise.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <array>
#include <cstdint>

namespace sony2fuji {

struct WaveletCacheDiagnostics {
    uint64_t filterRuns = 0, outputHits = 0, analysisHits = 0;
    size_t previewBytes = 0;
};

class WaveletRenderCache {
public:
    static constexpr size_t defaultPreviewBudget = 128u * 1024 * 1024;
    struct Entry {
        std::string key;
        ImageData image;
        WaveletDenoiseAnalysisCache analysis;
        WaveletDenoiseOptions options;
        GpuMode mode = GpuMode::Off;
        uint64_t used = 0;
        bool completed = false;
        bool matches(const WaveletDenoiseOptions& value, GpuMode backend) const {
            return completed && options == value && mode == backend;
        }
    };

    explicit WaveletRenderCache(size_t budget = defaultPreviewBudget) : previewBudget(budget) {}
    WaveletCacheDiagnostics diagnostics;

    Entry& select(const std::string& key, bool viewport) {
        Entry* entry = &exact;
        if (viewport) {
            entry = previews[0].used <= previews[1].used ? &previews[0] : &previews[1];
            for (auto& candidate : previews) if (candidate.key == key) { entry = &candidate; break; }
        }
        if (entry->key != key) { *entry = Entry(); entry->key = key; }
        entry->used = ++clock;
        return *entry;
    }

    size_t previewBytes() const {
        size_t bytes = 0;
        for (const auto& entry : previews) bytes += entry.image.pixels.size() * sizeof(RGB);
        return bytes;
    }

    void store(Entry& entry, const ImageData& image, const WaveletDenoiseOptions& options, GpuMode mode) {
        ImageData replacement = image;
        entry.image = std::move(replacement);
        entry.options = options; entry.mode = mode; entry.completed = true;
        // 优先淘汰较旧的预览图像；小型分析模型和精确槽不受预览预算影响。
        while (previewBytes() > previewBudget) {
            Entry* oldest = nullptr;
            for (auto& preview : previews)
                if (!preview.image.pixels.empty() && (!oldest || preview.used < oldest->used)) oldest = &preview;
            if (!oldest) break;
            oldest->image = {}; oldest->completed = false;
        }
    }

private:
    Entry exact;
    std::array<Entry,2> previews;
    size_t previewBudget;
    uint64_t clock = 0;
};

// 内部性能诊断，供原生基准和回归测试读取，不扩展公共 C ABI。
WaveletCacheDiagnostics waveletCacheDiagnostics(const sony2fuji_session* session);

} // namespace sony2fuji
