#pragma once

#include "sony2fuji/lut_applicator.h"
#include <memory>
#include <string>
#include <string_view>

namespace sony2fuji {

class HDRLook {
public:
    static std::shared_ptr<const HDRLook> load(const std::string& path, std::string_view expectedHash = {});

    const std::string& fingerprint() const { return fingerprint_; }
    const RGB& domainMin() const { return low_; }
    const RGB& domainMax() const { return high_; }
    int gridSize() const { return size_; }
    RGB apply(const RGB& pixel, float strength) const;

private:
    HDRLook(const std::shared_ptr<LUT3D>& table, std::string fingerprint);
    LUTApplicator sampler_;
    RGB low_, high_;
    int size_;
    std::string fingerprint_;
};

} // namespace sony2fuji
