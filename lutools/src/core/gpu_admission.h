#pragma once

#include "core/pipeline.h"
#include "sony2fuji/gpu/lut_gpu.h"

namespace sony2fuji {

// 本次渲染开启的算子集合。processImpl 只在一处填写，GPU 准入和查找表执行位置都从这里读取；
// 新算子需补一个字段，若它必须与查找表同在 CPU 串行执行，再接入 stagedOperatorActive()。
struct ActiveFeatures {
    bool wavelet = false;
    bool chromaDenoise = false;
    bool effects = false;
    bool filmOptics = false;
    bool hsl = false;
    bool toneControls = false;
    bool atmosphere = false;
    bool basicTone = false;
    bool basicControls = false;
    bool colorGrading = false;
    bool calibration = false;
    bool bwMixer = false;
    bool pointColor = false;
    bool selectiveColor = false;
    bool geometry = false;
    bool masterCurve = false;
    bool channelCurves = false;
    bool defringe = false;
    bool sharpenV2Luminance = false;

    bool neighborhood() const noexcept { return atmosphere || basicTone; }
    // 无 GPU 后端时这些算子把整条链留在 CPU；有后端时它们开启也会让查找表改在 CPU 上执行。
    bool stagedOperatorActive() const noexcept {
        return neighborhood() || basicControls || hsl || toneControls || colorGrading || calibration ||
            bwMixer || pointColor || selectiveColor || chromaDenoise || wavelet || effects || filmOptics;
    }
};

// GPU 准入需要的全部事实；不读取 Pipeline 成员，便于单测穷举。
struct GpuAdmissionFacts {
    GpuMode gpuMode = GpuMode::Off;     // 会话配置，不因 CPU 分析渲染改写
    bool cpuAnalysis = false;           // HSL 取样等 CPU 分析渲染，按 GpuMode::Off 判定
    bool gpuBackendCompiled = false;    // Metal / GLES / D3D11 任一编译进来
    bool displayInput = false;          // 显示参考输入：DisplayBuffer 或普通 X3F
    bool normalX3f = false;
    bool rawNoiseReduction = false;
    bool unsupportedDisplayLens = false;
    ActiveFeatures features;
    bool masterCurveGpuSupported = true;
    bool channelCurvesGpuSupported = true;
    bool c5Wavelet = false;
    bool roiActive = false;
};

// 加载查找表 / DCP 之后才知道的特性。
struct GpuLookTraits {
    bool dcpLook = false;
    bool lutRequiresCpu = false;
};

enum class X3fAdmissionError : int32_t {
    None = 0,
    RawNoiseReduction = 1,
    LensCorrection = 2,
    ForceGpu = 3
};

struct GpuAdmission {
    bool unsupported = false;           // processImpl 直接返回 RenderStatus::Unsupported
    // 显示输入检查拒绝：发生在 processImpl 把 lastBackend_ 置为 CPU 之前，需保留上一次的后端。
    bool rejectedAtInput = false;
    UnsupportedReason unsupportedReason = UnsupportedReason::None;
    GpuFallbackReason fallbackReason = GpuFallbackReason::None;
    X3fAdmissionError x3fError = X3fAdmissionError::None;
    bool cpuOnlyStages = false;
    bool sessionGpuPipeline = false;    // 仅在 admitGpuAfterLook 之后有效
    bool gpuPipeline = false;           // 仅在 admitGpuAfterLook 之后有效
};

// 第一阶段：在源尺寸预检和查找表加载之前判定，顺序与原 processImpl 一致。
GpuAdmission admitGpuBeforeLook(const GpuAdmissionFacts& facts) noexcept;
// 第二阶段：查找表 / DCP 加载成功后判定；回退原因沿用第一阶段结果，只在仍为 None 时写入。
GpuAdmission admitGpuAfterLook(const GpuAdmissionFacts& facts, GpuAdmission admission,
    const GpuLookTraits& look) noexcept;

const char* x3fAdmissionErrorText(X3fAdmissionError error) noexcept;

} // namespace sony2fuji
