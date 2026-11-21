#pragma once

#include "core/hdr_rendering.h"
#include "core/hdr_stream.h"
#include "core/pixel_buffer.h"
#include <stdexcept>
#include <vector>

#include "core/hdr_jpeg.h"

namespace sony2fuji::hdr {

class Error : public std::runtime_error {
public:
    RenderStatus status;
    uint32_t reason, field;
    Error(RenderStatus status, uint32_t reason, uint32_t field, const char* message)
        : std::runtime_error(message), status(status), reason(reason), field(field) {}
};

struct DecodedImage {
    HDRImagePair pixels;
    HDRSourceInfo info{};
};

// 分阶段估算新增临时内存，当前工作图已计入进程占用；预算不足须在分配前返回。
void admitMemory(uint64_t additionalBytes);
// 流式导出按已释放解码器后的 codec 峰值估算，并保留进程/系统余量。
void admitStreamingMemory(uint64_t additionalBytes);

HDRSourceInfo probeFile(const char* path);
DecodedImage decodeFile(const char* path, const HDRDecodeOptions& options);
void exportJPEG(const HDRImagePair& image, const HDRExportConfig& config, const char* path);
bool heifExportAvailable();
void exportHEIF(const HDRImagePair& image, const HDRExportConfig& config, const char* path);
void exportSDR(const HDRImagePair& image, const HDRSdrExportConfig& config, const char* path);
// 流式导出在 validate 冻结一次源（单次整文件摘要），publish 阶段复用同一快照/摘要，
// 不再按路径重开重算。Apple 实现以 impl 持有源快照；digest 为冻结时实际计算的摘要，
// 供调用方在 config.source_sha256 全零（内部自采）时取用；可移植实现忽略快照。
struct StreamSourcePin {
    void* impl = nullptr;
    uint8_t digest[32]{};
    StreamSourcePin() = default;
    StreamSourcePin(const StreamSourcePin&) = delete;
    StreamSourcePin& operator=(const StreamSourcePin&) = delete;
    ~StreamSourcePin();
};
void validateStreamSource(const HDRExportConfig& config, uint32_t width, uint32_t height,
    const char* path, StreamSourcePin& pin);
JPEGTransformBase makeStreamBaseTransform(const HDRExportConfig& config, uint32_t width, uint32_t height,
    const char* path, const StreamSourcePin& pin);
void publishStreamJPEG(std::vector<uint8_t> data, uint32_t width, uint32_t height,
    const HDRExportConfig& config, bool hdr, const char* path, const StreamSourcePin& pin,
    bool baseMetadataApplied = false);

#if defined(__APPLE__)
HDRRowSource openRasterRows(const char* path, const uint8_t expectedSHA[32], StreamSourcePin& pin, uint64_t& decodeRevision);
void freezeStreamSourceFile(const char* path, StreamSourcePin& pin);
void verifyStreamSource(const StreamSourcePin& pin);
void publishTiledHEIF(const HDRStreamFiles& image, const HDRExportConfig& config,
    const char* path, const StreamSourcePin& pin);
#endif

// 平台适配器对元数据源执行整文件摘要的累计次数（测试注入计数，进程级）。
uint64_t sourceHashPassCount();
void resetSourceHashPassCount();

// 测试注入缝：非空时，元数据源首块数据读取完成后恰好触发一次并置空，
// 用于模拟「读后、快照夹逼前」路径被原子替换（B1 红锚）。生产恒为空。
extern void (*sourceReadTestHook)();

} // namespace sony2fuji::hdr
