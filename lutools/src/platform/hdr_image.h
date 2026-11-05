#pragma once

#include "core/hdr_rendering.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include <stdexcept>
#include <vector>

namespace sony2fuji::hdr {

class Error : public std::runtime_error {
public:
    sony2fuji_status status;
    uint32_t reason, field;
    Error(sony2fuji_status status, uint32_t reason, uint32_t field, const char* message)
        : std::runtime_error(message), status(status), reason(reason), field(field) {}
};

struct DecodedImage {
    HDRImagePair pixels;
    sony2fuji_hdr_source_info_v1 info{};
};

// 分阶段估算新增临时内存，当前工作图已计入进程占用；预算不足须在分配前返回。
void admitMemory(uint64_t additionalBytes);
// 流式导出按已释放解码器后的 codec 峰值估算，并保留进程/系统余量。
void admitStreamingMemory(uint64_t additionalBytes);

sony2fuji_hdr_source_info_v1 probeFile(const char* path);
DecodedImage decodeFile(const char* path, const sony2fuji_hdr_decode_options_v1& options);
void exportJPEG(const HDRImagePair& image, const sony2fuji_hdr_export_config_v1& config, const char* path);
void exportSDR(const HDRImagePair& image, const sony2fuji_hdr_sdr_export_config_v1& config, const char* path);
void validateStreamSource(const sony2fuji_hdr_export_config_v1& config, uint32_t width, uint32_t height, const char* path);
void publishStreamJPEG(std::vector<uint8_t> data, uint32_t width, uint32_t height,
    const sony2fuji_hdr_export_config_v1& config, bool hdr, const char* path);

} // namespace sony2fuji::hdr
