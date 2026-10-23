#pragma once
#include "dualdn_geometry.h"
#include "model_package.h"
#include "noise_profile.h"
#include "network_graph.h"
#include "sony2fuji/raw_processor.h"

namespace sony2fuji::ai {
enum class RGBOutput { CameraCorrection, OfficialLinear, BothForValidation };
struct RuntimeReport {
    std::string backend, fallbackReason;
    double seconds = 0;
};

RAWBayerOverride denoiseRaw(const RAWBayerSource& source, const ModelPackage& package,
                            const NoiseParameters& noise, Backend backend, RuntimeReport& report,
                            const Progress& progress = {});
Tensor denoiseRgb(const RAWBayerSource& source, const RAWBayerOverride& denoised,
                   const ModelPackage& package, const NoiseParameters& noise, Backend backend,
                   RGBOutput output, RuntimeReport& report, const Progress& progress = {});
} // namespace sony2fuji::ai
