#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <memory>
#include <string>
#include <vector>

namespace sony2fuji {

struct DcpTable {
    uint32_t hues = 0, saturations = 0, values = 0, encoding = 0;
    std::vector<RGB> entries;
};

struct DcpStages {
    std::array<double, 9> input{}, output{};
    double exposure = 1;
    DcpTable calibration, look;
    std::array<double, 4097> tone{};
};

// Compiled DCP stages consume finite scene-linear sRGB and return display-sRGB.
// Target RAW calibration/WB has already run; no F-Log2 or RGB-CUBE resampling occurs.
class DcpLook {
public:
    static std::shared_ptr<const DcpLook> loadCached(const std::string& path);
    RGB apply(const RGB& linearSrgb) const;
    const DcpStages& stages() const { return stages_; }

private:
    DcpLook() = default;
    bool load(const std::string& path, uintmax_t size);
    double tone(double value) const;

    DcpStages stages_;
};

} // namespace sony2fuji
