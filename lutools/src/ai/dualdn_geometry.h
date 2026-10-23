#pragma once

#include <array>
#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

namespace sony2fuji::ai {

struct Tensor {
    int width = 0, height = 0, channels = 0;
    std::vector<float> values; // 连续 CHW，batch 固定为 1。
};

struct BayerFrame {
    int width = 0, height = 0;
    std::vector<uint16_t> pixels;
    std::array<int, 4> pattern{}; // active 区域行优先；R=0、G1=1、B=2、G2=3。
    std::array<float, 4> black{};
    float white = 0;
};

struct PackedBayer {
    Tensor tensor;
    int sourceWidth = 0, sourceHeight = 0;
    int offsetX = 0, offsetY = 0;
    std::array<int, 4> identities{}; // canonical 四相位对应的原始颜色身份。
};

struct TileGeometry { int size = 640, halo = 128; };
struct InferenceReport { bool fallbackUsed = false; std::string fallbackReason; };
class Cancelled : public std::runtime_error {
public:
    Cancelled() : std::runtime_error("AI denoise cancelled") {}
};
using Progress = std::function<bool(size_t completed, size_t total)>;
// 后端运行失败用 runtime_error；参数/契约错误用 invalid_argument，不做无意义的 CPU 重试。
using PredictTile = std::function<Tensor(const Tensor&)>;

void validateTensor(const Tensor& tensor);
int reflectIndex(int position, int length);
PackedBayer packBayer(const BayerFrame& frame);
Tensor unpackBayer(const Tensor& predicted, const PackedBayer& geometry);
// 把 sensor 坐标的降噪结果和原始输入都放回 canonical RGGB，分别占两个 CHW plane。
Tensor pairBayerMosaics(const PackedBayer& source, const std::vector<float>& denoisedMosaic);
Tensor runTiles(const Tensor& input, TileGeometry geometry, int outputChannels,
                const PredictTile& predict, const Progress& progress = {});
Tensor runTilesWithFallback(const Tensor& input, TileGeometry geometry, int outputChannels,
                            const PredictTile& primary, const PredictTile& cpu,
                            InferenceReport& report, const Progress& progress = {});

} // namespace sony2fuji::ai
