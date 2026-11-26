#include "gpu/d3d11_photo.h"
#include "gpu/d3d11_photo_shader.h"
#include "core/photo_lut.h"
#include "core/chroma_denoise.h"
#include "core/processing_cancellation.h"
#include "gpu/denoise.h"
#include "gpu/d3d11_recovery.h"
#include "gpu/d3d11_shader_cache.h"
#include "gpu/photo_bands.h"
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <iostream>
#include <new>
#include <stdexcept>
#include <cstddef>
#include <vector>
#if defined(RAWLAB_D3D11_TESTING)
#include "d3d11_test_hooks.h"
#endif

namespace sony2fuji {
namespace {
using Microsoft::WRL::ComPtr;
void checked(HRESULT result) {
    if (FAILED(result)) throw D3D11Failure(result);
}
struct alignas(16) Parameters {
    uint32_t dimensions[4], control[4];
    float toSrgb[3][4], toFilm[3][4];
    float exposureStrength[4], tone[4], detail[4], domainLow[4], domainHigh[4];
    uint32_t logTransfer[4];
    float hslHue[2][4], hslSaturation[2][4], hslLightness[2][4];
    float toneControls[4];
    float colorGrading[3][4];
    float curveRanges[128][4], curveTangents[128][4];
    uint32_t curveCounts[4];
    uint32_t curveFlags[4];
    float parametricAmps[4];
    float parametricSplits[4];
    float colorGradingGlobal[4];
    float colorGradingMix[4];
    uint32_t band[4]; // source row, destination row, output rows, reserved
    uint32_t basicV3[4];
    float basicTone[4];
};
static_assert(sizeof(Parameters) == 4624);
static_assert(offsetof(Parameters, hslHue) == 224);
static_assert(offsetof(Parameters, colorGrading) == 336);
static_assert(offsetof(Parameters, curveRanges) == 384);
static_assert(offsetof(Parameters, curveTangents) == 2432);
static_assert(offsetof(Parameters, curveCounts) == 4480);
static_assert(offsetof(Parameters, curveFlags) == 4496);
static_assert(offsetof(Parameters, parametricAmps) == 4512);
static_assert(offsetof(Parameters, parametricSplits) == 4528);
static_assert(offsetof(Parameters, colorGradingGlobal) == 4544);
static_assert(offsetof(Parameters, colorGradingMix) == 4560);
static_assert(offsetof(Parameters, band) == 4576);
static_assert(offsetof(Parameters, basicV3) == 4592);
static_assert(offsetof(Parameters, basicTone) == 4608);
static_assert(sizeof(RGB) == 12);
struct Buffer {
    ComPtr<ID3D11Buffer> data;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11UnorderedAccessView> uav;
    size_t bytes = 0;
    size_t stride = 0;
};
}
struct D3D11PhotoRenderer::Impl {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11ComputeShader> shader;
    ComPtr<ID3D11Buffer> constants, staging;
    Buffer source, processing[2], resized, film, basicField;
    uint64_t revision = 0;
    int sourceWidth = 0, sourceHeight = 0;
    size_t stagingBytes = 0;
    std::shared_ptr<LUT3D> cachedLut;

    void initialize() {
#if defined(RAWLAB_D3D11_TESTING)
        d3d11_test::createDevice(device, context, false);
#else
        ComPtr<IDXGIFactory1> factory;
        checked(CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf())));
        std::vector<ComPtr<IDXGIAdapter1>> adapters;
        for (UINT i = 0;; ++i) {
            ComPtr<IDXGIAdapter1> adapter;
            if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_ADAPTER_DESC1 desc{};
            if (adapter && SUCCEEDED(adapter->GetDesc1(&desc)) && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE))
                adapters.push_back(adapter);
        }
        std::stable_sort(adapters.begin(), adapters.end(), [](const auto& a, const auto& b) {
            DXGI_ADAPTER_DESC1 x{}, y{}; a->GetDesc1(&x); b->GetDesc1(&y);
            return x.DedicatedVideoMemory > y.DedicatedVideoMemory;
        });
        const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
        for (const auto& adapter : adapters) {
            // Hardware adapters only. WARP is never reported as GPU acceleration.
            if (SUCCEEDED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                levels, 1, D3D11_SDK_VERSION, &device, nullptr, &context))) break;
        }
        if (!device) throw GpuUnavailableError("No Direct3D 11 hardware adapter");
#endif
        const auto bytecode = compileD3D11Shader(
            "RawLab photo shader", kD3DPhotoShader, "main", "cs_5_0",
            D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_IEEE_STRICTNESS, checked);
        checked(device->CreateComputeShader(bytecode.data(), bytecode.size(), nullptr, &shader));
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = sizeof(Parameters); desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        checked(device->CreateBuffer(&desc, nullptr, &constants));
    }
    void allocateTyped(Buffer& buffer, size_t count, size_t stride, bool writable) {
        if (!count || count > std::numeric_limits<UINT>::max() / stride) throw GpuCapabilityLimitError("GPU buffer too large");
        const auto bytes = count * stride;
        if (buffer.bytes >= bytes && buffer.stride == stride) return;
        buffer = {};
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = static_cast<UINT>(bytes); desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | (writable ? D3D11_BIND_UNORDERED_ACCESS : 0);
        desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED; desc.StructureByteStride = static_cast<UINT>(stride);
        checked(device->CreateBuffer(&desc, nullptr, &buffer.data));
#if defined(RAWLAB_D3D11_TESTING)
        d3d11_test::largestPhotoBuffer = std::max(d3d11_test::largestPhotoBuffer, bytes);
#endif
        checked(device->CreateShaderResourceView(buffer.data.Get(), nullptr, &buffer.srv));
        if (writable) checked(device->CreateUnorderedAccessView(buffer.data.Get(), nullptr, &buffer.uav));
        buffer.bytes = bytes;
        buffer.stride = stride;
    }
    void allocate(Buffer& buffer, size_t count, bool writable) {
        allocateTyped(buffer, count, sizeof(RGB), writable);
    }
    void writeBytes(Buffer& buffer, const void* data, size_t bytes) {
        D3D11_BOX box{};
        box.right = static_cast<UINT>(bytes);
        box.bottom = box.back = 1;
        context->UpdateSubresource(buffer.data.Get(), 0, &box, data, 0, 0);
    }
    void write(Buffer& buffer, const RGB* pixels, size_t count) {
        writeBytes(buffer, pixels, count * sizeof(RGB));
    }
    void setBasicToneField(const RenderParams& params) {
        if (params.basicV3 && params.basicTone.active() && params.basicToneField && !params.basicToneField->empty()) {
            const auto& f = *params.basicToneField;
            const size_t n = f.slope.size();
            std::vector<float> packed(n * 2);
            for (size_t i = 0; i < n; ++i) {
                packed[i * 2] = f.slope[i];
                packed[i * 2 + 1] = f.intercept[i];
            }
            allocateTyped(basicField, n, sizeof(float) * 2, false);
            writeBytes(basicField, packed.data(), packed.size() * sizeof(float));
        } else if (basicField.bytes == 0) {
            const float dummy[2]{0.0f, 0.0f};
            allocateTyped(basicField, 1, sizeof(float) * 2, false);
            writeBytes(basicField, dummy, sizeof(dummy));
        }
    }
    void setLut(const std::shared_ptr<LUT3D>& lut) {
        if (!lut || cachedLut == lut) return;
        const auto n = lut->getSize();
        std::vector<RGB> values;
        values.reserve(static_cast<size_t>(n)*n*n);
        for (int b=0;b<n;++b) for (int g=0;g<n;++g) for (int r=0;r<n;++r) values.push_back(lut->getValue(r,g,b));
        // 分配失败时设备仍可复用，但旧 LUT 缓冲可能已释放，缓存标识也必须失效。
        cachedLut.reset();
        allocate(film,values.size(),false);
        write(film, values.data(), values.size());
        cachedLut = lut;
    }
    void dispatch(Buffer& input, Buffer& output, Parameters params, uint32_t stage,
        uint32_t sw, uint32_t sh, uint32_t dw, uint32_t dh,
        uint32_t sourceRow = 0, uint32_t outputRow = 0, uint32_t rows = 0) {
        // 阶段边界即安全边界（对齐 gles_photo）：每次 GPU 提交前轮询一次，取消时上一阶段的
        // 结果仍在临时缓冲，output 直到末尾 read 才发布，重抛不会留下半成品。
        checkProcessingCancellation();
        if (!rows) rows = dh;
        allocate(output,static_cast<size_t>(dw)*rows,true);
        params.dimensions[0]=sw; params.dimensions[1]=sh; params.dimensions[2]=dw; params.dimensions[3]=dh;
        params.control[0]=stage;
        params.band[0]=sourceRow;params.band[1]=outputRow;params.band[2]=rows;
        context->UpdateSubresource(constants.Get(),0,nullptr,&params,0,0);
        context->CSSetShader(shader.Get(),nullptr,0);
        auto cb=constants.Get(); context->CSSetConstantBuffers(0,1,&cb);
        ID3D11ShaderResourceView* views[]={input.srv.Get(),params.control[2] ? film.srv.Get() : nullptr,basicField.srv.Get()};
        context->CSSetShaderResources(0,3,views);
        auto uav=output.uav.Get();context->CSSetUnorderedAccessViews(0,1,&uav,nullptr);
        context->Dispatch((dw+15)/16,(rows+15)/16,1);
        // Unbind before ping-pong: the next pass may read the previous UAV.
        ID3D11ShaderResourceView* emptyViews[3]{}; ID3D11UnorderedAccessView* emptyUav=nullptr;
        context->CSSetShaderResources(0,3,emptyViews);context->CSSetUnorderedAccessViews(0,1,&emptyUav,nullptr);
        checked(d3d11DeviceStatus(*device.Get()));
    }
    void read(Buffer& buffer, RGB* output, size_t count) {
        // 读回同样是阶段边界：取消时不启动这次 CPU 拷贝，output 保持未发布。
        checkProcessingCancellation();
        const auto bytes = count * sizeof(RGB);
        if (stagingBytes < bytes) {
            staging.Reset(); stagingBytes=0;
            D3D11_BUFFER_DESC desc{};desc.ByteWidth=static_cast<UINT>(bytes);
            desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
            checked(device->CreateBuffer(&desc,nullptr,&staging));stagingBytes=bytes;
        }
        D3D11_BOX box{};box.right=static_cast<UINT>(bytes);box.bottom=box.back=1;
        context->CopySubresourceRegion(staging.Get(),0,0,0,0,buffer.data.Get(),0,&box);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        checked(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
        std::memcpy(output,mapped.pData,bytes);
        context->Unmap(staging.Get(),0);
        checked(d3d11DeviceStatus(*device.Get()));
    }
    void read(Buffer& buffer, ImageData& output) {
        read(buffer, output.pixels.data(), output.pixels.size());
    }
    void bands(const ImageData& input, uint32_t width, uint32_t height, Parameters params,
               uint32_t stage, ImageData& output) {
        const size_t dispatchLimit = std::min<size_t>(UINT32_MAX, size_t(width) * (65535 * 16));
        const PhotoBands plan(input.width, input.height, width, height, kPhotoTileBytes, dispatchLimit);
        size_t sourceCapacity = 0, outputCapacity = 0;
        for (uint32_t row = 0; row < height;) {
            const auto band = plan.at(row);
            sourceCapacity = std::max(sourceCapacity, size_t(band.last - band.first + 1) * input.width);
            outputCapacity = std::max(outputCapacity, size_t(band.rows) * width);
            row += band.rows;
        }
        allocate(source, sourceCapacity, false);
        allocate(processing[0], outputCapacity, true);
        for (uint32_t row = 0; row < height;) {
            checkProcessingCancellation();
            const auto band = plan.at(row);
            const auto count = size_t(band.last - band.first + 1) * input.width;
            write(source, input.pixels.data() + size_t(band.first) * input.width, count);
            dispatch(source, processing[0], params, stage, input.width, input.height, width, height,
                band.first, row, band.rows);
            read(processing[0], output.pixels.data() + size_t(row) * width, size_t(band.rows) * width);
            row += band.rows;
        }
    }
};
D3D11PhotoRenderer::D3D11PhotoRenderer() = default;
D3D11PhotoRenderer::~D3D11PhotoRenderer() = default;
GpuRenderOutcome D3D11PhotoRenderer::renderWithOutcome(const ImageData& input, ColorSpace inputSpace,
    const RenderParams& params, uint32_t width, uint32_t height, uint64_t revision, ImageData& output) {
    GpuRenderOutcome outcome;
    try {
        (void)renderImpl(input, inputSpace, params, width, height, revision, output, outcome);
    } catch (const std::bad_alloc& error) {
        outcome = {GpuFailureKind::OutOfMemory, GpuBackendFault::DeviceError, error.what()};
        OutputDebugStringA(outcome.message.c_str());
    }
    return outcome;
}
bool D3D11PhotoRenderer::render(const ImageData& input, ColorSpace inputSpace,
    const RenderParams& params, uint32_t width, uint32_t height, uint64_t revision, ImageData& output) {
    GpuRenderOutcome outcome;
    return renderImpl(input, inputSpace, params, width, height, revision, output, outcome);
}

bool D3D11PhotoRenderer::disabledByEnvironment() noexcept {
    return GetEnvironmentVariableW(L"RAWLAB_DISABLE_D3D11", nullptr, 0) > 0;
}

bool D3D11PhotoRenderer::isReadyForQuery() const noexcept {
    if (disabledByEnvironment()) {
        return false;
    }
    return impl_ != nullptr || (!initUnavailable_ && retry_.ready(d3d11RetryNow()));
}
bool D3D11PhotoRenderer::renderImpl(const ImageData& input, ColorSpace inputSpace,
    const RenderParams& params, uint32_t width, uint32_t height, uint64_t revision, ImageData& output,
    GpuRenderOutcome& outcome) {
    outcome = {};
    if (params.lut && params.lut->requiresCPU()) {
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability, "LUT requires CPU evaluation"};
        return false;
    }
    const bool nativeFilters = params.effects.active() || params.filmOptics.active() || params.chromaDenoise != 0 ||
        params.noiseReduction > 0 || params.sharpening > 0 || params.preserveSourceResolution;
    if (input.width <= 0 || input.height <= 0 || width == 0 || height == 0 || width > 65535 || height > 65535 ||
        (nativeFilters && (input.width > 65535 || input.height > 65535)) ||
        input.pixels.size() != static_cast<size_t>(input.width) * input.height || !params.validForGpu()) {
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability,
            "Image dimensions or parameters exceed Direct3D 11 limits"};
        return false;
    }
    // Diagnostic switch also exercises Auto fallback and Force failure in regression tests.
    if (GetEnvironmentVariableW(L"RAWLAB_DISABLE_D3D11", nullptr, 0) > 0) {
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::GpuDisabled,
            "Direct3D 11 disabled by RAWLAB_DISABLE_D3D11"};
        OutputDebugStringA(outcome.message.c_str());
        return false;
    }
    if (!impl_ && !retry_.ready(d3d11RetryNow())) {
        if (initUnavailable_) {
            outcome = {GpuFailureKind::Unsupported, GpuBackendFault::Cooldown,
                lastInitError_.empty() ? "Direct3D 11 hardware adapter unavailable (retry cooldown)" : lastInitError_};
        } else {
            outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::Cooldown,
                lastInitError_.empty() ? "Direct3D 11 device recovery cooldown" : lastInitError_};
        }
        OutputDebugStringA(outcome.message.c_str());
        return false;
    }
    bool initializing = !impl_;
    try {
        if (!impl_) { impl_=std::make_unique<Impl>();impl_->initialize(); }
        initializing = false;
        auto& c=*impl_;
        Parameters p{};
        const auto toSrgb = params.hasCustomToSrgb
            ? params.customToSrgb
            : ColorConverter::getConversionMatrix(inputSpace,ColorSpace::sRGB);
        const auto toFilm=photoLUTInputMatrix(params.lut ? params.lut->inputTransfer() : LUTTransfer::FLog2);
        for (int row=0;row<3;++row) for (int col=0;col<3;++col) {
            p.toSrgb[row][col]=toSrgb[row][col];p.toFilm[row][col]=toFilm[row][col];
        }
        const float exposure=std::exp2(params.exposureEV)*params.brightness;
        p.exposureStrength[0]=params.relativeWB.r*exposure;
        p.exposureStrength[1]=params.relativeWB.g*exposure;
        p.exposureStrength[2]=params.relativeWB.b*exposure;
        p.exposureStrength[3]=std::clamp(params.lutStrength,0.f,2.f);
        p.tone[0]=std::clamp(params.contrast,0.f,2.f);p.tone[1]=std::clamp(params.saturation,0.f,2.f);
        p.tone[2]=std::clamp(params.highlights,-1.f,1.f);p.tone[3]=std::clamp(params.shadows,-1.f,1.f);
        p.detail[0]=params.toneCurve;p.detail[1]=params.noiseReduction;p.detail[2]=params.sharpening;
        const auto custom = toneCurveGpuParameters(params.customCurve);
        p.detail[3] = static_cast<float>(custom.count);
        p.curveCounts[0] = custom.count;
        if (custom.count) {
            std::memcpy(&p.curveRanges[0], custom.ranges, sizeof(custom.ranges));
            std::memcpy(&p.curveTangents[0], custom.tangents, sizeof(custom.tangents));
        }
        for (size_t ch = 0; ch < 3; ++ch) {
            const auto chParams = toneCurveGpuParameters(params.channelCurves[ch]);
            p.curveCounts[ch + 1] = chParams.count;
            if (chParams.count) {
                const size_t base = (ch + 1) * 32;
                std::memcpy(&p.curveRanges[base], chParams.ranges, sizeof(chParams.ranges));
                std::memcpy(&p.curveTangents[base], chParams.tangents, sizeof(chParams.tangents));
            }
        }
        p.curveFlags[0] = params.curveApplyToLuminosity ? 1u : 0u;
        const auto parametric = toneCurveParametricGpuParameters(params.parametricCurve);
        p.curveFlags[1] = parametric.active;
        std::memcpy(p.parametricAmps, parametric.amps, sizeof(parametric.amps));
        std::memcpy(p.parametricSplits, parametric.splits, sizeof(parametric.splits));
        p.control[1]=params.hsl.active();
        p.toneControls[0]=params.toneControls.blackPoint; p.toneControls[1]=params.toneControls.whitePoint;
        p.toneControls[2]=params.toneControls.vibrance;
        const bool bt = params.basicV3 && params.basicTone.active() &&
            params.basicToneField && !params.basicToneField->empty();
        p.basicV3[0] = params.basicV3 ? 1u : 0u;
        p.basicV3[1] = bt ? 1u : 0u;
        p.basicV3[2] = bt ? static_cast<uint32_t>(params.basicToneField->width) : 1u;
        p.basicV3[3] = bt ? static_cast<uint32_t>(params.basicToneField->height) : 1u;
        p.basicTone[0] = bt ? std::clamp(params.basicTone.highlights, -1.0f, 1.0f) : 0.0f;
        p.basicTone[1] = bt ? std::clamp(params.basicTone.shadows, -1.0f, 1.0f) : 0.0f;
        c.setBasicToneField(params);
        const auto grading=colorGradingParameters(params.colorGrading);
        for (size_t zone=0;zone<3;++zone) {
            p.colorGrading[zone][0]=grading.coefficients[zone].r;
            p.colorGrading[zone][1]=grading.coefficients[zone].g;
            p.colorGrading[zone][2]=grading.coefficients[zone].b;
            p.colorGrading[zone][3]=grading.luminance[zone];
        }
        p.colorGradingGlobal[0]=grading.coefficients[3].r;
        p.colorGradingGlobal[1]=grading.coefficients[3].g;
        p.colorGradingGlobal[2]=grading.coefficients[3].b;
        p.colorGradingGlobal[3]=grading.luminance[3];
        p.colorGradingMix[0]=grading.blending;
        p.colorGradingMix[1]=grading.balance;
        for (size_t index=0;index<8;++index) {
            p.hslHue[index/4][index%4]=params.hsl.hue[index];
            p.hslSaturation[index/4][index%4]=params.hsl.saturation[index];
            p.hslLightness[index/4][index%4]=params.hsl.lightness[index];
        }
        if (params.lut && params.lutStrength>0) {
            c.setLut(params.lut);p.control[2]=1;p.control[3]=params.lut->getSize();
            p.logTransfer[0]=params.lut->inputTransfer()==LUTTransfer::FLog;
            p.logTransfer[1]=params.lut->outputTransfer()!=LUTTransfer::Display;
            p.logTransfer[2]=params.lut->outputTransfer()==LUTTransfer::FLog;
            p.logTransfer[3]=params.lut->inputTransfer()==LUTTransfer::SRGB;
            auto low=params.lut->domainMin(),high=params.lut->domainMax();
            p.domainLow[0]=low.r;p.domainLow[1]=low.g;p.domainLow[2]=low.b;
            p.domainHigh[0]=high.r;p.domainHigh[1]=high.g;p.domainHigh[2]=high.b;
        }
        if (nativeFilters || input.pixels.size() > kPhotoTileBytes / sizeof(RGB) ||
            uint64_t(width) * height > kPhotoTileBytes / sizeof(RGB)) {
            if (nativeFilters && (input.width > 65535 || input.height > 65535)) {
                outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability,
                    "Source dimensions exceed Direct3D 11 65535 filter limit"};
                OutputDebugStringA(outcome.message.c_str());
                return false;
            }
            // 分带上传会覆盖 source，不能继续沿用上一张整图的 revision。
            c.revision = 0;
            const uint32_t pw = nativeFilters ? input.width : width, ph = nativeFilters ? input.height : height;
            ImageData native(static_cast<int>(pw), static_cast<int>(ph));
            c.bands(input, pw, ph, p, params.intent == RenderIntent::Preview ? 0 : 4, native);
            auto failFilter = [&](const char* fallbackMessage, ErrorCode err = ErrorCode::ProcessingError) {
                const auto filterOutcome = lastGpuFilterOutcome();
                if (err == ErrorCode::OutOfMemory || filterOutcome.failure == GpuFailureKind::OutOfMemory) {
                    outcome = {GpuFailureKind::OutOfMemory, GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? fallbackMessage : filterOutcome.message};
                } else if (err == ErrorCode::Unsupported || filterOutcome.failure == GpuFailureKind::Unsupported) {
                    outcome = {GpuFailureKind::Unsupported,
                        filterOutcome.fault != GpuBackendFault::None ? filterOutcome.fault : GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? fallbackMessage : filterOutcome.message};
                } else {
                    outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::FilterError,
                        filterOutcome.message.empty() ? fallbackMessage : filterOutcome.message};
                }
                OutputDebugStringA(outcome.message.c_str());
                return false;
            };
            if (params.chromaDenoise != 0) {
                lastGpuFilterOutcome() = {};
                const auto chromaErr = applyChromaDenoiseWorking(native, params.chromaDenoise, nullptr, GpuMode::Force);
                if (chromaErr != ErrorCode::Success) {
                    return failFilter("D3D11 chroma denoise failed", chromaErr);
                }
            }
            if (params.filmOptics.active()) {
                if (params.noiseReduction > 0) {
                    lastGpuFilterOutcome() = {};
                    if (!gpuDetailFilter(native, params.noiseReduction, 0.0f)) {
                        return failFilter("D3D11 noise reduction filter failed");
                    }
                }
                lastGpuFilterOutcome() = {};
                if (!gpuFilmOptics(native, params.filmOptics)) {
                    return failFilter("D3D11 film optics filter failed");
                }
                if (params.sharpening > 0) {
                    lastGpuFilterOutcome() = {};
                    if (!gpuDetailFilter(native, 0.0f, params.sharpening)) {
                        return failFilter("D3D11 sharpening filter failed");
                    }
                }
            } else if (params.noiseReduction > 0 || params.sharpening > 0) {
                lastGpuFilterOutcome() = {};
                if (!gpuDetailFilter(native, params.noiseReduction, params.sharpening)) {
                    return failFilter("D3D11 detail filter failed");
                }
            }
            if (params.effects.active()) {
                lastGpuFilterOutcome() = {};
                if (!gpuPhotoEffects(native, params.effects)) {
                    return failFilter("D3D11 photo effects failed");
                }
            }
            if (pw != width || ph != height) {
                ImageData resized(static_cast<int>(width), static_cast<int>(height));
                c.bands(native, width, height, p, 1, resized);
                output = std::move(resized);
            } else output = std::move(native);
            retry_.succeeded();
            initUnavailable_ = false;
            lastInitError_.clear();
            return true;
        }
        if (revision==0 || revision!=c.revision || input.width!=c.sourceWidth || input.height!=c.sourceHeight) {
            c.revision=0;c.allocate(c.source,input.pixels.size(),false);
            c.write(c.source, input.pixels.data(), input.pixels.size());
            c.revision=revision;c.sourceWidth=input.width;c.sourceHeight=input.height;
        }
        const bool early=params.intent==RenderIntent::Preview;
        const uint32_t pw=early ? width : input.width,ph=early ? height : input.height;
        c.dispatch(c.source,c.processing[0],p,0,input.width,input.height,pw,ph);
        auto* final=&c.processing[0];
        if (pw!=width || ph!=height) { c.dispatch(*final,c.resized,p,1,pw,ph,width,height);final=&c.resized; }
        ImageData result(static_cast<int>(width),static_cast<int>(height));c.read(*final,result);
        output=std::move(result);retry_.succeeded();initUnavailable_ = false;lastInitError_.clear();return true;
    } catch (const ProcessingCancelled&) {
        // 取消交还调用方，不丢弃健康设备，也不进入重建退避。
        throw;
    } catch (const std::bad_alloc&) {
        throw;
    } catch (const GpuUnavailableError& error) {
        OutputDebugStringA(error.what());
        initUnavailable_ = true;
        lastInitError_ = error.what();
        retry_.failed(d3d11RetryNow());
        impl_.reset();
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::NoAdapter, error.what()};
        return false;
    } catch (const GpuCapabilityLimitError& error) {
        OutputDebugStringA(error.what());
        outcome = {GpuFailureKind::Unsupported, GpuBackendFault::UnsupportedCapability, error.what()};
        return false;
    } catch (const std::exception& error) {
        OutputDebugStringA(error.what());
        if (initializing || d3d11LostDevice(error) ||
            (impl_ && impl_->device && FAILED(d3d11DeviceStatus(*impl_->device.Get())))) {
            initUnavailable_ = false;
            lastInitError_ = error.what();
            retry_.failed(d3d11RetryNow());
            impl_.reset();
        }
        outcome = {GpuFailureKind::ProcessingError, GpuBackendFault::DeviceError, error.what()};
        return false;
    }
}
}
