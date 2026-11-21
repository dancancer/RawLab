#pragma once

#include "core/hdr_rendering.h"
#include <filesystem>
#include <functional>
#include <memory>
#include <vector>

namespace sony2fuji {

struct HDRRowSource {
    uint32_t width = 0, height = 0;
    // 完整已定向画布，按 HDR、SDR 顺序读取，每个呈现从第 0 行开始。
    std::function<void(bool hdr, uint32_t row, uint32_t count, RGB* output)> read;
    // 完成两份呈现后释放解码器并确认原片仍为冻结的来源；失败可抛异常。
    std::function<void()> finish;
};

struct HDRStreamResult {
    uint32_t width = 0, height = 0;
    uint32_t outputNativeWidth = 0, outputNativeHeight = 0;
    float sourceHeadroom = 1, editedHeadroom = 0;
    std::vector<uint8_t> jpeg;
};

namespace hdr {
namespace storage { class Directory; }

// 完整渲染结果保存在任务私有文件中；析构后删除，消费者只按行或块读取。
struct HDRStreamFiles {
    std::shared_ptr<storage::Directory> directory;
    HDRStreamResult result;
    std::filesystem::path hdr, sdr;
    float rgbHeadroom = 1.001f;
};

HDRStreamFiles renderStreamFiles(const HDRRowSource& source, const HDRRenderOptions& options,
    bool includeHDR, const std::filesystem::path& temporaryRoot);
uint64_t streamScratchBytes(uint32_t width, uint32_t height, const HDRRenderOptions& options, bool hdr);
HDRStreamResult encodeStream(const HDRRowSource& source, const HDRRenderOptions& options,
    bool hdr, uint32_t quality, uint32_t baseColor, const std::filesystem::path& temporaryRoot);
}
}
