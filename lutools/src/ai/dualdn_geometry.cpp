#include "dualdn_geometry.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji::ai {
namespace {
size_t pixelCount(int width, int height) {
    if (width < 1 || height < 1 || uint64_t(width) * height > 128000000)
        throw std::invalid_argument("DualDn image exceeds the supported pixel budget");
    return size_t(width) * height;
}

void validatePackedGeometry(const PackedBayer& packed) {
    pixelCount(packed.sourceWidth, packed.sourceHeight);
    if (packed.offsetX < 0 || packed.offsetX > 1 || packed.offsetY < 0 || packed.offsetY > 1 ||
        packed.tensor.width != (packed.sourceWidth + packed.offsetX + 1) / 2 ||
        packed.tensor.height != (packed.sourceHeight + packed.offsetY + 1) / 2 || packed.tensor.channels != 4)
        throw std::invalid_argument("invalid DualDn packed Bayer geometry");
}
}

int reflectIndex(int position, int length) {
    if (length < 1 || length > 128000000) throw std::invalid_argument("invalid reflection extent");
    if (length == 1) return 0;
    const int64_t period = 2 * int64_t(length - 1);
    const int64_t folded = ((int64_t(position) % period) + period) % period;
    return int(folded < length ? folded : period - folded);
}

void validateTensor(const Tensor& tensor) {
    const size_t pixels = pixelCount(tensor.width, tensor.height);
    if (tensor.channels < 1 || tensor.channels > 8 || tensor.values.size() != pixels * tensor.channels ||
        !std::all_of(tensor.values.begin(), tensor.values.end(), [](float v) { return std::isfinite(v); }))
        throw std::invalid_argument("invalid DualDn tensor storage or nonfinite values");
}

PackedBayer packBayer(const BayerFrame& frame) {
    if (frame.width < 2 || frame.height < 2 ||
        frame.pixels.size() != pixelCount(frame.width, frame.height) || !std::isfinite(frame.white))
        throw std::invalid_argument("invalid DualDn Bayer source");
    auto sorted = frame.pattern;
    std::sort(sorted.begin(), sorted.end());
    const int red = int(std::find(frame.pattern.begin(), frame.pattern.end(), 0) - frame.pattern.begin());
    if (sorted != std::array<int, 4>{0, 1, 2, 3} || frame.pattern[red ^ 3] != 2)
        throw std::invalid_argument("DualDn requires ordinary Bayer with two distinct green phases");
    for (float black : frame.black)
        if (!std::isfinite(black) || black < 0 || black >= frame.white)
            throw std::invalid_argument("invalid DualDn black/white levels");
    PackedBayer result;
    result.sourceWidth = frame.width; result.sourceHeight = frame.height;
    result.offsetX = red % 2; result.offsetY = red / 2;
    result.identities = {0, frame.pattern[red ^ 1], frame.pattern[red ^ 2], 2};
    auto& packed = result.tensor;
    packed.width = (frame.width + result.offsetX + 1) / 2;
    packed.height = (frame.height + result.offsetY + 1) / 2;
    packed.channels = 4;
    const size_t plane = pixelCount(packed.width, packed.height);
    packed.values.resize(4 * plane);
    // 传感器坐标反射保持奇偶相位；输入下限沿用已验证协议，上限不裁切。
    for (int c = 0; c < 4; ++c) for (int y = 0; y < packed.height; ++y) {
        const int row = reflectIndex(2 * y + c / 2 - result.offsetY, frame.height);
        for (int x = 0; x < packed.width; ++x) {
            const int col = reflectIndex(2 * x + c % 2 - result.offsetX, frame.width);
            const float black = frame.black[frame.pattern[(row % 2) * 2 + col % 2]];
            const float value = (frame.pixels[size_t(row) * frame.width + col] - black) / (frame.white - black);
            packed.values[size_t(c) * plane + size_t(y) * packed.width + x] = std::max(value, 1e-8f);
        }
    }
    return result;
}

Tensor unpackBayer(const Tensor& predicted, const PackedBayer& geometry) {
    validateTensor(predicted);
    validatePackedGeometry(geometry);
    if (predicted.channels != 4 || predicted.width != geometry.tensor.width || predicted.height != geometry.tensor.height)
        throw std::invalid_argument("DualDn RAW output geometry mismatch");
    Tensor output{geometry.sourceWidth, geometry.sourceHeight, 1, {}};
    output.values.resize(pixelCount(output.width, output.height));
    const size_t plane = size_t(predicted.width) * predicted.height;
    for (int y = 0; y < output.height; ++y) for (int x = 0; x < output.width; ++x) {
        const int row = y + geometry.offsetY, col = x + geometry.offsetX;
        const int c = (row % 2) * 2 + col % 2;
        output.values[size_t(y) * output.width + x] = predicted.values[size_t(c) * plane +
            size_t(row / 2) * predicted.width + col / 2];
    }
    return output;
}

Tensor pairBayerMosaics(const PackedBayer& packed, const std::vector<float>& denoised) {
    validatePackedGeometry(packed);
    validateTensor(packed.tensor);
    if (denoised.size() != pixelCount(packed.sourceWidth, packed.sourceHeight) ||
        !std::all_of(denoised.begin(), denoised.end(), [](float x) { return std::isfinite(x); }))
        throw std::invalid_argument("invalid DualDn denoised mosaic");
    Tensor pair{packed.tensor.width * 2, packed.tensor.height * 2, 2, {}};
    const size_t plane = pixelCount(pair.width, pair.height), packedPlane = plane / 4;
    pair.values.resize(2 * plane);
    for (int y = 0; y < pair.height; ++y) for (int x = 0; x < pair.width; ++x) {
        const size_t index = size_t(y) * pair.width + x;
        const int row = reflectIndex(y - packed.offsetY, packed.sourceHeight);
        const int col = reflectIndex(x - packed.offsetX, packed.sourceWidth);
        pair.values[index] = denoised[size_t(row) * packed.sourceWidth + col];
        pair.values[plane + index] = packed.tensor.values[size_t((y % 2) * 2 + x % 2) * packedPlane +
            size_t(y / 2) * packed.tensor.width + x / 2];
    }
    return pair;
}

Tensor runTiles(const Tensor& input, TileGeometry geometry, int outputChannels,
                const PredictTile& predict, const Progress& progress) {
    validateTensor(input);
    if (!predict || geometry.size < 4 || geometry.size > 2048 || geometry.halo < 0 ||
        geometry.halo * 2 >= geometry.size || outputChannels < 1 || outputChannels > 8)
        throw std::invalid_argument("invalid DualDn tile geometry");
    const int side = geometry.size, core = side - 2 * geometry.halo;
    const size_t total = size_t((input.width + core - 1) / core) * ((input.height + core - 1) / core);
    size_t completed = 0;
    auto check = [&] { if (progress && !progress(completed, total)) throw Cancelled(); };
    check();
    Tensor output{input.width, input.height, outputChannels, {}};
    const size_t plane = size_t(input.width) * input.height;
    output.values.resize(plane * outputChannels);
    Tensor tile{side, side, input.channels, std::vector<float>(size_t(side) * side * input.channels)};
    for (int top = 0; top < input.height; top += core) for (int left = 0; left < input.width; left += core) {
        check();
        for (int c = 0; c < input.channels; ++c) for (int y = 0; y < side; ++y) {
            const int row = reflectIndex(top + y - geometry.halo, input.height);
            for (int x = 0; x < side; ++x) {
                const int col = reflectIndex(left + x - geometry.halo, input.width);
                tile.values[(size_t(c) * side + y) * side + x] =
                    input.values[size_t(c) * plane + size_t(row) * input.width + col];
            }
        }
        auto result = predict(tile);
        try { validateTensor(result); }
        catch (const std::invalid_argument& error) { throw ModelContractError(error.what()); }
        if (result.width != side || result.height != side || result.channels != outputChannels)
            throw ModelContractError("DualDn prediction changed tile geometry");
        ++completed; check();
        for (int c = 0; c < outputChannels; ++c) for (int y = 0; y < core && top + y < input.height; ++y) {
            const float* row = result.values.data() + (size_t(c) * side + y + geometry.halo) * side + geometry.halo;
            std::copy_n(row, std::min(core, input.width - left),
                        output.values.data() + size_t(c) * plane + size_t(top + y) * input.width + left);
        }
    }
    return output;
}

} // namespace sony2fuji::ai
