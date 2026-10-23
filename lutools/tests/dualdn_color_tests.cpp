#include "ai/dualdn_bridge.h"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;
using namespace sony2fuji::ai;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }

int main() {
    try {
        const Matrix identity{{{1,0,0}, {0,1,0}, {0,0,1}}};
        const std::array<float, 4> wb{2, 1, 1.5, 1};
        Tensor raw{32, 32, 1, std::vector<float>(1024, .1f)};
        Tensor skip{32, 32, 3, std::vector<float>(3072, .3f)};
        auto noisy = raw;
        auto zero = rgbCameraCorrection(raw, noisy, skip, skip, wb, identity);
        require(std::all_of(zero.values.begin(), zero.values.end(), [](float x) { return x == 0; }), "zero residual is not identity");
        auto changed = skip;
        for (auto& value : changed.values) value += .03f;
        auto correction = rgbCameraCorrection(raw, noisy, skip, changed, wb, identity);
        require(std::any_of(correction.values.begin(), correction.values.end(), [](float x) { return x != 0; }), "RGB residual discarded");
        // 一个传感器红色样点经 WB 超白；保护邻域严格为零，不影响远处。
        raw.values[16 * 32 + 16] = .6f;
        auto protectedResult = rgbCameraCorrection(raw, noisy, skip, changed, wb, identity);
        for (int c = 0; c < 3; ++c) for (int y = 8; y <= 24; ++y) for (int x = 8; x <= 24; ++x)
            require(protectedResult.values[size_t(c) * 1024 + y * 32 + x] == 0, "clipped highlight received RGB correction");
        require(protectedResult.values[0] == correction.values[0], "highlight protection changed distant pixels");
        noisy.values[16 * 32 + 16] = .6f;
        raw.values[16 * 32 + 16] = .1f;
        auto originalProtected = rgbCameraCorrection(raw, noisy, skip, changed, wb, identity);
        require(originalProtected.values == protectedResult.values,
                "RAW network lowering a saturated input removed highlight protection");
        require(std::abs(inverseRec709(-.45f) + .1f) < 1e-7f && inverseRec709(2.f) > 1,
                "inverse transfer clipped scene-linear values");
        RAWBayerSource source;
        source.cameraCalibration = {{{.7f,.2f,.1f}, {.15f,.75f,.1f}, {.04f,.2f,.76f}}};
        const auto matrix = officialCameraToXYZ(source);
        source.whiteBalance = wb;
        require(supportsDualDnBridge(source), "valid DualDn bridge rejected");
        source.whiteBalance[3] = 1.2f;
        require(!supportsDualDnBridge(source), "unequal green WB did not select generic RGB");
        source.whiteBalance = wb;
        source.cameraCalibration = {{{1,1,1},{1,1,1},{1,1,1}}};
        require(!supportsDualDnBridge(source), "singular matrix did not select generic RGB");
        source.cameraCalibration = {{{.7f,.2f,.1f}, {.15f,.75f,.1f}, {.04f,.2f,.76f}}};
        const auto roundtrip = ColorConverter::multiplyMatrices(source.cameraCalibration, matrix);
        for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j)
            require(std::abs(roundtrip[i][j] - identity[i][j]) < 1e-5, "camera matrix inverse parity");
        bool rejected = false;
        try { rgbCameraCorrection(raw, noisy, skip, changed, {2,1,1.5f,1.2f}, identity); }
        catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "unequal green WB accepted by three-channel bridge");
        std::cout << "PASS DualDn inverse transfer, matrix, zero residual and highlight protection\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
