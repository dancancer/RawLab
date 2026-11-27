#include "core/gpu_admission.h"

namespace sony2fuji {
namespace {

GpuAdmission rejectForceGpu(GpuAdmission admission) noexcept {
    admission.unsupported = true;
    admission.unsupportedReason = UnsupportedReason::ForceGpu;
    return admission;
}

} // namespace

GpuAdmission admitGpuBeforeLook(const GpuAdmissionFacts& facts) noexcept {
    const auto& f = facts.features;
    const auto effectiveMode = facts.cpuAnalysis ? GpuMode::Off : facts.gpuMode;
    const bool force = effectiveMode == GpuMode::Force;
    // 回退原因只描述真正会尝试 GPU 的渲染：CPU 分析渲染和 Off 都不记录。
    const bool reportsFallback = !facts.cpuAnalysis && facts.gpuMode != GpuMode::Off;
    GpuAdmission admission;

    if (facts.displayInput && (facts.rawNoiseReduction || facts.unsupportedDisplayLens || force)) {
        if (facts.normalX3f) {
            admission.x3fError = facts.rawNoiseReduction ? X3fAdmissionError::RawNoiseReduction
                : facts.unsupportedDisplayLens ? X3fAdmissionError::LensCorrection
                : X3fAdmissionError::ForceGpu;
        }
        admission.unsupported = true;
        admission.rejectedAtInput = true;
        if (!facts.rawNoiseReduction && !facts.unsupportedDisplayLens && force) {
            admission.unsupportedReason = UnsupportedReason::ForceGpu;
            admission.fallbackReason = GpuFallbackReason::DisplayInput;
        }
        return admission;
    }
    if (facts.displayInput && reportsFallback) {
        admission.fallbackReason = GpuFallbackReason::DisplayInput;
    }
    if (f.geometry && force) {
        admission.fallbackReason = GpuFallbackReason::Geometry;
        return rejectForceGpu(admission);
    }
    if (facts.roiActive && force) {
        admission.fallbackReason = GpuFallbackReason::UnsupportedCapability;
        return rejectForceGpu(admission);
    }

    bool curvesGpuUnsupported = false;
    if (facts.gpuBackendCompiled) {
        curvesGpuUnsupported = !facts.masterCurveGpuSupported || !facts.channelCurvesGpuSupported;
        admission.cpuOnlyStages = curvesGpuUnsupported;
    } else {
        curvesGpuUnsupported = f.channelCurves || !facts.masterCurveGpuSupported;
        admission.cpuOnlyStages = f.stagedOperatorActive() || curvesGpuUnsupported || f.masterCurve;
    }
    const auto cpuStageFallbackReason = [&]() {
        if (!facts.gpuBackendCompiled) {
            if (f.atmosphere) return GpuFallbackReason::Atmosphere;
            if (f.basicControls) return GpuFallbackReason::BasicV3Controls;
        }
        if (curvesGpuUnsupported) return GpuFallbackReason::Curves;
        if (facts.c5Wavelet) return GpuFallbackReason::C5Wavelet;
        return GpuFallbackReason::GpuDisabled;
    };
    if ((admission.cpuOnlyStages || facts.c5Wavelet) && force) {
        admission.fallbackReason = cpuStageFallbackReason();
        return rejectForceGpu(admission);
    }
    if (admission.cpuOnlyStages && reportsFallback && admission.fallbackReason == GpuFallbackReason::None) {
        admission.fallbackReason = cpuStageFallbackReason();
    }
    return admission;
}

GpuAdmission admitGpuAfterLook(const GpuAdmissionFacts& facts, GpuAdmission admission,
    const GpuLookTraits& look) noexcept {
    const auto effectiveMode = facts.cpuAnalysis ? GpuMode::Off : facts.gpuMode;
    const bool force = effectiveMode == GpuMode::Force;
    const bool reportsFallback = !facts.cpuAnalysis && facts.gpuMode != GpuMode::Off;
    auto reportIfFirst = [&](GpuFallbackReason reason) {
        if (reportsFallback && admission.fallbackReason == GpuFallbackReason::None) {
            admission.fallbackReason = reason;
        }
    };

    if (!facts.gpuBackendCompiled) {
        if (look.dcpLook) {
            reportIfFirst(GpuFallbackReason::DcpLook);
            if (force) {
                admission.fallbackReason = GpuFallbackReason::DcpLook;
                return rejectForceGpu(admission);
            }
        }
        admission.sessionGpuPipeline = false;
        reportIfFirst(GpuFallbackReason::GpuDisabled);
        if (force) {
            if (admission.fallbackReason == GpuFallbackReason::None) {
                admission.fallbackReason = GpuFallbackReason::GpuDisabled;
            }
            return rejectForceGpu(admission);
        }
    } else {
        admission.sessionGpuPipeline = !admission.cpuOnlyStages && facts.gpuMode != GpuMode::Off;
    }
    // 显示参考输入沿用参考 CPU 阶段；场景参考的 GPU 着色器契约不变。
    if (facts.displayInput) admission.sessionGpuPipeline = false;
    if (look.lutRequiresCpu) {
        reportIfFirst(GpuFallbackReason::LutContract);
        if (force) {
            admission.fallbackReason = GpuFallbackReason::LutContract;
            return rejectForceGpu(admission);
        }
        admission.sessionGpuPipeline = false;
    }
    admission.gpuPipeline = !facts.cpuAnalysis && admission.sessionGpuPipeline && !facts.roiActive;
    return admission;
}

const char* x3fAdmissionErrorText(X3fAdmissionError error) noexcept {
    switch (error) {
    case X3fAdmissionError::RawNoiseReduction:
        return "Normal X3F rendering does not support FBDD RAW denoise";
    case X3fAdmissionError::LensCorrection:
        return "Normal X3F rendering does not support additional lens correction";
    case X3fAdmissionError::ForceGpu:
        return "Normal X3F rendering uses CPU filtering; GPU Force is not supported";
    case X3fAdmissionError::None:
        break;
    }
    return "";
}

} // namespace sony2fuji
