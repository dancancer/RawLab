#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <exception>
#include <mutex>
#include "processing_cancellation.h"
#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
#include <opencv2/core/utility.hpp>
#endif

namespace sony2fuji {

namespace detail {

template <typename Index, typename Apply>
void runParallelStepRanges(Index count, Index block, Index cancelStep, bool parallelEligible, Apply& apply) {
    const auto cancellation = processingCancellation;
    cancellation.check();
    if (count <= 0) {
        return;
    }

    std::atomic<bool> failed{false};
    std::atomic<bool> localCancelled{false};
    std::exception_ptr workerError;
    std::mutex errorMutex;
    const bool hasCallback = cancellation.callback != nullptr;

    auto cancelOrStop = [&]() -> bool {
        if (failed.load(std::memory_order_acquire)) {
            return true;
        }
        if (cancellation.cancelled()) {
            localCancelled.store(true, std::memory_order_release);
            failed.store(true, std::memory_order_release);
            return true;
        }
        return false;
    };

    auto invokeBounded = [&](Index first, Index last) {
        try {
            if (!hasCallback) {
                if (!failed.load(std::memory_order_acquire)) {
                    apply(first, last);
                }
                return;
            }
            for (Index start = first; start < last;) {
                if (cancelOrStop()) {
                    return;
                }
                const Index step = static_cast<Index>(std::min<size_t>(size_t(last - start), size_t(cancelStep)));
                const Index end = static_cast<Index>(start + step);
                apply(start, end);
                start = end;
            }
        } catch (const ProcessingCancelled&) {
            localCancelled.store(true, std::memory_order_release);
            failed.store(true, std::memory_order_release);
        } catch (...) {
            std::lock_guard<std::mutex> lock(errorMutex);
            if (!workerError) {
                workerError = std::current_exception();
            }
            failed.store(true, std::memory_order_release);
        }
    };

#if defined(SONY2FUJI_ENABLE_CHROMA_DENOISE) || defined(SONY2FUJI_ENABLE_WAVELET_DENOISE)
    if (parallelEligible) {
        const int blockCount = static_cast<int>((size_t(count) + size_t(block) - 1) / size_t(block));
        cv::parallel_for_(cv::Range(0, blockCount), [&](const cv::Range& range) {
            const Index first = static_cast<Index>(size_t(range.start) * size_t(block));
            const Index last = static_cast<Index>(std::min<size_t>(size_t(count), size_t(range.end) * size_t(block)));
            invokeBounded(first, last);
        });
    } else {
        invokeBounded(Index(0), count);
    }
#else
    (void)block;
    (void)parallelEligible;
    invokeBounded(Index(0), count);
#endif

    if (workerError) {
        std::rethrow_exception(workerError);
    }
    if (localCancelled.load(std::memory_order_acquire)) {
        throw ProcessingCancelled();
    }
    cancellation.check();
}

} // namespace detail

// 只划分独立像素，不改变像素内部的运算或归约顺序；无 OpenCV 的核心仍可串行构建。
template <typename Apply>
void parallelPixelRanges(size_t count, Apply apply) {
    constexpr size_t block = 16384;
    constexpr size_t cancelStep = 4096;
    detail::runParallelStepRanges<size_t>(count, block, cancelStep, count >= 4 * block, apply);
}

// 按行划分独立二维扫描线，避免工作线程共享行缓冲，同时在带回调时保持按行取消响应度。
template <typename Apply>
void parallelRowRanges(int rows, int cols, Apply apply) {
    if (rows <= 0 || cols <= 0) {
        processingCancellation.check();
        return;
    }
    constexpr size_t targetBlockPixels = 16384;
    const int blockRows = std::max(1, static_cast<int>(targetBlockPixels / size_t(cols)));
    const size_t totalPixels = size_t(rows) * size_t(cols);
    const size_t blockCount = (size_t(rows) + size_t(blockRows) - 1) / size_t(blockRows);
    const bool parallelEligible = totalPixels >= 4 * targetBlockPixels && blockCount >= 4;
    detail::runParallelStepRanges<int>(rows, blockRows, 1, parallelEligible, apply);
}

} // namespace sony2fuji
