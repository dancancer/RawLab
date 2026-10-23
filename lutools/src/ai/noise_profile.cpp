#include "noise_profile.h"
#include "sony2fuji/raw_processor.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace sony2fuji::ai {
NoiseParameters selectNoiseProfile(const RAWBayerSource& source) {
    if (source.rawBits != 14 || source.sonyRawType != 4 || source.width != 7008 || source.height != 4672 ||
        source.white != 16383 || !std::all_of(source.black.begin(), source.black.end(), [](float value) { return value == 512; }))
        throw std::invalid_argument("DualDn calibration requires full-resolution 14-bit lossless RAW with matching black/white levels");
    return selectNoiseProfile(source.cameraModel, source.iso);
}

NoiseParameters selectNoiseProfile(const std::string& cameraModel, float iso) {
    if (cameraModel != "ILCE-7CM2" || !std::isfinite(iso) || iso < 100 || iso > 12800)
        throw std::invalid_argument("No DualDn noise profile for this camera/ISO");
    struct Anchor { int iso; double k, b; };
    static const Anchor anchors[] = {
        {100, 1.4017175356283488e-05, 4.012456627349693e-09},
        {800, 0.00011384917115434277, 2.2385292275415084e-08},
        {3200, 0.0004553081677833925, 3.6243917036353184e-07},
        {12800, 0.0018241977770013236, 5.150549402363373e-06}
    };
    NoiseParameters result;
    result.calibrationID = "sony-ilce-7cm2-20261022-bce08d93bc36";
    for (const auto& anchor : anchors) if (iso == anchor.iso) {
        result.k = float(anchor.k); result.b = float(anchor.b);
        result.lowerISO = result.upperISO = anchor.iso;
        return result;
    }
    for (size_t i = 1; i < 4; ++i) if (iso < anchors[i].iso) {
        const auto& a = anchors[i - 1]; const auto& b = anchors[i];
        const double t = std::log(double(iso) / a.iso) / std::log(double(b.iso) / a.iso);
        result.k = float(std::exp(std::log(a.k) + t * std::log(b.k / a.k)));
        result.b = float(std::exp(std::log(a.b) + t * std::log(b.b / a.b)));
        result.interpolated = true; result.lowerISO = a.iso; result.upperISO = b.iso;
        return result;
    }
    throw std::invalid_argument("No DualDn noise profile for this ISO");
}
} // namespace sony2fuji::ai
