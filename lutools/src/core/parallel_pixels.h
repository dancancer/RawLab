#pragma once

#include <algorithm>
#include <cstddef>
#include "processing_cancellation.h"
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core/utility.hpp>
#endif

namespace sony2fuji {

// 只划分独立像素，不改变像素内部的运算或归约顺序；无 OpenCV 的核心仍可串行构建。
template <typename Apply>
void parallelPixelRanges(size_t count, Apply apply) {
    const auto cancellation = processingCancellation;
    cancellation.check();
    auto bounded = [&](size_t first, size_t last) {
        if (!cancellation.callback) { apply(first, last); return; }
        for (size_t start = first; start < last && !cancellation.cancelled(); start += 16384)
            apply(start, std::min(last, start + 16384));
    };
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    constexpr size_t block = 16384;
    if (count >= 4 * block) {
        cv::parallel_for_(cv::Range(0, static_cast<int>((count + block - 1) / block)),
            [&](const cv::Range& range) {
                bounded(size_t(range.start) * block, std::min(count, size_t(range.end) * block));
            });
        cancellation.check();
        return;
    }
#endif
    bounded(size_t(0), count);
    cancellation.check();
}

} // namespace sony2fuji
