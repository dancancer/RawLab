#include "test_harness.h"
#include "core/gpu_admission.h"

#include <string>

using namespace sony2fuji;

namespace {

GpuAdmissionFacts facts(GpuMode mode, bool backend) {
    GpuAdmissionFacts f;
    f.gpuMode = mode;
    f.gpuBackendCompiled = backend;
    return f;
}

// 与 processImpl 相同的两段调用：第一阶段拒绝时不进入查找表阶段。
GpuAdmission admit(const GpuAdmissionFacts& f, GpuLookTraits look = {}) {
    const auto before = admitGpuBeforeLook(f);
    if (before.unsupported) return before;
    return admitGpuAfterLook(f, before, look);
}

bool rejectedForce(const GpuAdmission& a, GpuFallbackReason reason) {
    return a.unsupported && a.unsupportedReason == UnsupportedReason::ForceGpu && a.fallbackReason == reason;
}

bool cpuFallback(const GpuAdmission& a, GpuFallbackReason reason) {
    return !a.unsupported && a.fallbackReason == reason && !a.gpuPipeline;
}

void forceGeometryIsUnsupported() {
    auto f = facts(GpuMode::Force, true);
    f.features.geometry = true;
    const auto a = admit(f);
    RAWLAB_CHECK(rejectedForce(a, GpuFallbackReason::Geometry) && !a.rejectedAtInput,
        "Force + geometry -> Unsupported(ForceGpu, Geometry) after the backend reset");
}

void displayInputRules() {
    auto f = facts(GpuMode::Auto, true);
    f.displayInput = true;
    RAWLAB_CHECK(cpuFallback(admit(f), GpuFallbackReason::DisplayInput) && !admit(f).sessionGpuPipeline,
        "Auto + display input -> CPU with fallback DisplayInput");

    f.gpuMode = GpuMode::Force;
    auto a = admit(f);
    RAWLAB_CHECK(rejectedForce(a, GpuFallbackReason::DisplayInput) && a.rejectedAtInput &&
            a.x3fError == X3fAdmissionError::None,
        "Force + display buffer -> Unsupported(ForceGpu, DisplayInput) before the backend reset, no X3F text");

    f.cpuAnalysis = true;
    a = admit(f);
    RAWLAB_CHECK(!a.unsupported && a.fallbackReason == GpuFallbackReason::None && !a.gpuPipeline,
        "CPU analysis render ignores Force for display input and reports no fallback");

    f = facts(GpuMode::Off, true);
    f.displayInput = true;
    f.unsupportedDisplayLens = true;
    a = admit(f);
    RAWLAB_CHECK(a.unsupported && a.rejectedAtInput && a.unsupportedReason == UnsupportedReason::None &&
            a.fallbackReason == GpuFallbackReason::None,
        "display input with unsupported lens correction is Unsupported even with GPU Off, without a GPU reason");
}

void normalX3fErrors() {
    auto f = facts(GpuMode::Auto, true);
    f.displayInput = true;
    f.normalX3f = true;
    f.rawNoiseReduction = true;
    f.unsupportedDisplayLens = true;
    auto a = admit(f);
    RAWLAB_CHECK(a.unsupported && a.x3fError == X3fAdmissionError::RawNoiseReduction &&
            a.unsupportedReason == UnsupportedReason::None,
        "normal X3F: raw noise reduction wins the error text over lens correction");
    RAWLAB_CHECK(std::string(x3fAdmissionErrorText(a.x3fError)) ==
            "Normal X3F rendering does not support FBDD RAW denoise",
        "normal X3F raw denoise text is unchanged");

    f.rawNoiseReduction = false;
    a = admit(f);
    RAWLAB_CHECK(a.x3fError == X3fAdmissionError::LensCorrection &&
            std::string(x3fAdmissionErrorText(a.x3fError)) ==
                "Normal X3F rendering does not support additional lens correction",
        "normal X3F: lens correction text");

    f.unsupportedDisplayLens = false;
    f.gpuMode = GpuMode::Force;
    a = admit(f);
    RAWLAB_CHECK(rejectedForce(a, GpuFallbackReason::DisplayInput) && a.x3fError == X3fAdmissionError::ForceGpu &&
            std::string(x3fAdmissionErrorText(a.x3fError)) ==
                "Normal X3F rendering uses CPU filtering; GPU Force is not supported",
        "normal X3F + Force -> Unsupported(ForceGpu, DisplayInput) with the Force text");
    RAWLAB_CHECK(std::string(x3fAdmissionErrorText(X3fAdmissionError::None)).empty(), "no X3F error -> empty text");
}

void c5WaveletRules() {
    auto f = facts(GpuMode::Force, true);
    f.features.wavelet = true;
    f.c5Wavelet = true;
    RAWLAB_CHECK(rejectedForce(admit(f), GpuFallbackReason::C5Wavelet), "Force + C5 wavelet -> Unsupported(C5Wavelet)");

    f.gpuMode = GpuMode::Auto;
    const auto a = admit(f);
    RAWLAB_CHECK(!a.unsupported && a.fallbackReason == GpuFallbackReason::None && a.gpuPipeline,
        "Auto + C5 wavelet keeps the GPU photo pipeline (the wavelet itself runs on CPU)");
}

void lutContractRules() {
    auto f = facts(GpuMode::Auto, true);
    GpuLookTraits look;
    look.lutRequiresCpu = true;
    auto a = admit(f, look);
    RAWLAB_CHECK(cpuFallback(a, GpuFallbackReason::LutContract) && !a.sessionGpuPipeline,
        "Auto + CPU-only LUT contract -> CPU with fallback LutContract");

    f.gpuMode = GpuMode::Force;
    RAWLAB_CHECK(rejectedForce(admit(f, look), GpuFallbackReason::LutContract),
        "Force + CPU-only LUT contract -> Unsupported(LutContract)");

    f.gpuMode = GpuMode::Off;
    a = admit(f, look);
    RAWLAB_CHECK(cpuFallback(a, GpuFallbackReason::None), "GPU Off never reports a fallback reason");
}

void firstReasonWins() {
    auto f = facts(GpuMode::Auto, true);
    f.displayInput = true;
    f.masterCurveGpuSupported = false;
    GpuLookTraits look;
    look.lutRequiresCpu = true;
    RAWLAB_CHECK(cpuFallback(admit(f, look), GpuFallbackReason::DisplayInput),
        "Auto: display input reason is kept over later curve and LUT-contract reasons");

    f.displayInput = false;
    RAWLAB_CHECK(cpuFallback(admit(f, look), GpuFallbackReason::Curves),
        "Auto: unsupported curves reason is kept over the later LUT-contract reason");

    f.gpuMode = GpuMode::Force;
    RAWLAB_CHECK(rejectedForce(admit(f, look), GpuFallbackReason::Curves),
        "Force rejects at the first CPU-only stage (curves) before the LUT contract");

    auto roi = facts(GpuMode::Force, true);
    roi.roiActive = true;
    RAWLAB_CHECK(rejectedForce(admit(roi), GpuFallbackReason::UnsupportedCapability),
        "Force + viewport ROI -> Unsupported(UnsupportedCapability)");
    roi.gpuMode = GpuMode::Auto;
    const auto a = admit(roi);
    RAWLAB_CHECK(!a.unsupported && a.fallbackReason == GpuFallbackReason::None && a.sessionGpuPipeline &&
            !a.gpuPipeline,
        "Auto + viewport ROI keeps the session GPU pipeline but renders this ROI on CPU without a reason");
}

void backendRules() {
    auto f = facts(GpuMode::Auto, true);
    f.features.atmosphere = true;
    f.features.hsl = true;
    auto a = admit(f);
    RAWLAB_CHECK(!a.unsupported && a.fallbackReason == GpuFallbackReason::None && a.gpuPipeline,
        "with a GPU backend, staged operators run on the GPU pipeline");

    f = facts(GpuMode::Auto, false);
    a = admit(f);
    RAWLAB_CHECK(cpuFallback(a, GpuFallbackReason::GpuDisabled) && !a.sessionGpuPipeline,
        "no backend + Auto -> CPU with fallback GpuDisabled");
    f.gpuMode = GpuMode::Force;
    RAWLAB_CHECK(rejectedForce(admit(f), GpuFallbackReason::GpuDisabled), "no backend + Force -> Unsupported(GpuDisabled)");

    f = facts(GpuMode::Auto, false);
    f.features.atmosphere = true;
    f.features.basicControls = true;
    RAWLAB_CHECK(cpuFallback(admit(f), GpuFallbackReason::Atmosphere),
        "no backend: atmosphere reason precedes BasicV3 controls");
    f.features.atmosphere = false;
    RAWLAB_CHECK(cpuFallback(admit(f), GpuFallbackReason::BasicV3Controls), "no backend: BasicV3 controls reason");

    f = facts(GpuMode::Auto, false);
    GpuLookTraits dcp;
    dcp.dcpLook = true;
    RAWLAB_CHECK(cpuFallback(admit(f, dcp), GpuFallbackReason::DcpLook), "no backend + DCP look -> fallback DcpLook");
    f.gpuMode = GpuMode::Force;
    RAWLAB_CHECK(rejectedForce(admit(f, dcp), GpuFallbackReason::DcpLook), "no backend + Force + DCP -> Unsupported(DcpLook)");

    f = facts(GpuMode::Auto, true);
    a = admit(f, dcp);
    RAWLAB_CHECK(!a.unsupported && a.fallbackReason == GpuFallbackReason::None && a.gpuPipeline,
        "with a GPU backend a DCP look stays on the GPU pipeline");
}

// 无 GPU 后端时，任一逐阶段算子都必须把整条链留在 CPU；漏接一个算子会让 Force 静默放行。
void everyStagedOperatorForcesCpuWithoutBackend() {
    bool ActiveFeatures::* const staged[] = {
        &ActiveFeatures::wavelet, &ActiveFeatures::chromaDenoise, &ActiveFeatures::effects,
        &ActiveFeatures::filmOptics, &ActiveFeatures::hsl, &ActiveFeatures::toneControls,
        &ActiveFeatures::atmosphere, &ActiveFeatures::basicTone, &ActiveFeatures::basicControls,
        &ActiveFeatures::colorGrading, &ActiveFeatures::calibration, &ActiveFeatures::bwMixer,
        &ActiveFeatures::pointColor, &ActiveFeatures::selectiveColor, &ActiveFeatures::masterCurve,
        &ActiveFeatures::channelCurves};
    int index = 0;
    for (auto member : staged) {
        auto f = facts(GpuMode::Force, false);
        f.features.*member = true;
        const auto a = admitGpuBeforeLook(f);
        RAWLAB_CHECK(a.unsupported && a.cpuOnlyStages,
            "no backend + Force rejects before the look when staged operator #" + std::to_string(index) + " is active");
        ++index;
    }
    auto f = facts(GpuMode::Force, false);
    RAWLAB_CHECK(!admitGpuBeforeLook(f).cpuOnlyStages, "no backend: no staged operator -> not cpuOnlyStages");
}

} // namespace

TEST_MAIN({
    forceGeometryIsUnsupported();
    displayInputRules();
    normalX3fErrors();
    c5WaveletRules();
    lutContractRules();
    firstReasonWins();
    backendRules();
    everyStagedOperatorForcesCpuWithoutBackend();
})
