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
    float curveRanges[32][4], curveTangents[32][4];
    uint32_t band[4]; // source row, destination row, output rows, reserved
};
static_assert(sizeof(Parameters) == 1424);
static_assert(offsetof(Parameters, hslHue) == 224);
static_assert(offsetof(Parameters, colorGrading) == 336);
static_assert(offsetof(Parameters, curveRanges) == 384);
static_assert(sizeof(RGB) == 12);
struct Buffer {
    ComPtr<ID3D11Buffer> data;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11UnorderedAccessView> uav;
    size_t bytes = 0;
};
}
struct D3D11PhotoRenderer::Impl {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11ComputeShader> shader;
    ComPtr<ID3D11Buffer> constants, staging;
    Buffer source, processing[2], resized, film;
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
        if (!device) throw std::runtime_error("No Direct3D 11 hardware adapter");
#endif
        const auto bytecode = compileD3D11Shader(
            "RawLab photo shader", kD3DPhotoShader, "main", "cs_5_0",
            D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_IEEE_STRICTNESS, checked);
        checked(device->CreateComputeShader(bytecode.data(), bytecode.size(), nullptr, &shader));
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = sizeof(Parameters); desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        checked(device->CreateBuffer(&desc, nullptr, &constants));
    }
    void allocate(Buffer& buffer, size_t count, bool writable) {
        if (!count || count > std::numeric_limits<UINT>::max() / sizeof(RGB)) throw std::runtime_error("GPU buffer too large");
        const auto bytes = count * sizeof(RGB);
        if (buffer.bytes >= bytes) return;
        buffer = {};
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = static_cast<UINT>(bytes); desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | (writable ? D3D11_BIND_UNORDERED_ACCESS : 0);
        desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED; desc.StructureByteStride = sizeof(RGB);
        checked(device->CreateBuffer(&desc, nullptr, &buffer.data));
#if defined(RAWLAB_D3D11_TESTING)
        d3d11_test::largestPhotoBuffer = std::max(d3d11_test::largestPhotoBuffer, bytes);
#endif
        checked(device->CreateShaderResourceView(buffer.data.Get(), nullptr, &buffer.srv));
        if (writable) checked(device->CreateUnorderedAccessView(buffer.data.Get(), nullptr, &buffer.uav));
        buffer.bytes = bytes;
    }
    void write(Buffer& buffer, const RGB* pixels, size_t count) {
        D3D11_BOX box{};
        box.right = static_cast<UINT>(count * sizeof(RGB));
        box.bottom = box.back = 1;
        context->UpdateSubresource(buffer.data.Get(), 0, &box, pixels, 0, 0);
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
        ID3D11ShaderResourceView* views[]={input.srv.Get(),params.control[2] ? film.srv.Get() : nullptr};
        context->CSSetShaderResources(0,2,views);
        auto uav=output.uav.Get();context->CSSetUnorderedAccessViews(0,1,&uav,nullptr);
        context->Dispatch((dw+15)/16,(rows+15)/16,1);
        // Unbind before ping-pong: the next pass may read the previous UAV.
        ID3D11ShaderResourceView* emptyViews[2]{}; ID3D11UnorderedAccessView* emptyUav=nullptr;
        context->CSSetShaderResources(0,2,emptyViews);context->CSSetUnorderedAccessViews(0,1,&emptyUav,nullptr);
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
bool D3D11PhotoRenderer::render(const ImageData& input, ColorSpace inputSpace,
    const sony2fuji_request& request, const std::shared_ptr<LUT3D>& lut,
    const RGB& wb, uint32_t width, uint32_t height, uint64_t revision, ImageData& output,
    const PhotoEffectsOptions& effects, int chromaDenoise, bool preserveSourceResolution, const HslOptions& hsl, const ToneControlsOptions& toneControls,
    const ColorGradingOptions& colorGrading, const ToneCurve& customCurve) {
    if (lut && lut->requiresCPU()) return false;
    if (input.width<=0 || input.height<=0 || width==0 || height==0 || width>65535 || height>65535 ||
        input.pixels.size()!=static_cast<size_t>(input.width)*input.height || !effects.valid() || !hsl.valid() || !toneControls.valid() || !colorGrading.valid() || !customCurve.gpuSupported() || (customCurve.custom() && request.tone_curve != 0) ||
        chromaDenoise < 0 || chromaDenoise > 2) return false;
    // Diagnostic switch also exercises Auto fallback and Force failure in regression tests.
    if (GetEnvironmentVariableW(L"RAWLAB_DISABLE_D3D11",nullptr,0)>0) return false;
    if (!impl_ && !retry_.ready(d3d11RetryNow())) return false;
    bool initializing = !impl_;
    try {
        if (!impl_) { impl_=std::make_unique<Impl>();impl_->initialize(); }
        initializing = false;
        auto& c=*impl_;
        Parameters p{};
        const auto toSrgb=ColorConverter::getConversionMatrix(inputSpace,ColorSpace::sRGB);
        const auto toFilm=photoLUTInputMatrix(lut ? lut->inputTransfer() : LUTTransfer::FLog2);
        for (int row=0;row<3;++row) for (int col=0;col<3;++col) {
            p.toSrgb[row][col]=toSrgb[row][col];p.toFilm[row][col]=toFilm[row][col];
        }
        const float exposure=std::exp2(request.exposure_ev)*request.brightness;
        p.exposureStrength[0]=wb.r*exposure;p.exposureStrength[1]=wb.g*exposure;p.exposureStrength[2]=wb.b*exposure;
        p.exposureStrength[3]=std::clamp(request.lut_strength,0.f,2.f);
        p.tone[0]=std::clamp(request.contrast,0.f,2.f);p.tone[1]=std::clamp(request.saturation,0.f,2.f);
        p.tone[2]=std::clamp(request.highlights,-1.f,1.f);p.tone[3]=std::clamp(request.shadows,-1.f,1.f);
        p.detail[0]=request.tone_curve;p.detail[1]=request.noise_reduction;p.detail[2]=request.sharpening;
        const auto custom = toneCurveGpuParameters(customCurve);
        p.detail[3] = static_cast<float>(custom.count);
        std::memcpy(p.curveRanges, custom.ranges, sizeof(custom.ranges));
        std::memcpy(p.curveTangents, custom.tangents, sizeof(custom.tangents));
        p.control[1]=hsl.active();
        p.toneControls[0]=toneControls.blackPoint; p.toneControls[1]=toneControls.whitePoint;
        p.toneControls[2]=toneControls.vibrance;
        const auto grading=colorGradingCoefficients(colorGrading);
        for (size_t zone=0;zone<3;++zone) {
            p.colorGrading[zone][0]=grading[zone].r;p.colorGrading[zone][1]=grading[zone].g;p.colorGrading[zone][2]=grading[zone].b;
        }
        for (size_t index=0;index<8;++index) {
            p.hslHue[index/4][index%4]=hsl.hue[index];
            p.hslSaturation[index/4][index%4]=hsl.saturation[index];
            p.hslLightness[index/4][index%4]=hsl.lightness[index];
        }
        if (lut && request.lut_strength>0) {
            c.setLut(lut);p.control[2]=1;p.control[3]=lut->getSize();
            p.logTransfer[0]=lut->inputTransfer()==LUTTransfer::FLog;
            p.logTransfer[1]=lut->outputTransfer()!=LUTTransfer::Display;
            p.logTransfer[2]=lut->outputTransfer()==LUTTransfer::FLog;
            p.logTransfer[3]=lut->inputTransfer()==LUTTransfer::SRGB;
            auto low=lut->domainMin(),high=lut->domainMax();
            p.domainLow[0]=low.r;p.domainLow[1]=low.g;p.domainLow[2]=low.b;
            p.domainHigh[0]=high.r;p.domainHigh[1]=high.g;p.domainHigh[2]=high.b;
        }
        const bool nativeFilters = effects.active() || chromaDenoise != 0 || request.noise_reduction > 0 ||
            request.sharpening > 0 || preserveSourceResolution;
        if (nativeFilters || input.pixels.size() > kPhotoTileBytes / sizeof(RGB) ||
            uint64_t(width) * height > kPhotoTileBytes / sizeof(RGB)) {
            // 分带上传会覆盖 source，不能继续沿用上一张整图的 revision。
            c.revision = 0;
            const uint32_t pw = nativeFilters ? input.width : width, ph = nativeFilters ? input.height : height;
            ImageData native(static_cast<int>(pw), static_cast<int>(ph));
            c.bands(input, pw, ph, p, request.intent == SONY2FUJI_INTENT_PREVIEW ? 0 : 4, native);
            if (applyChromaDenoiseWorking(native, chromaDenoise, nullptr, GpuMode::Force) != ErrorCode::Success ||
                ((request.noise_reduction > 0 || request.sharpening > 0) &&
                 !gpuDetailFilter(native, request.noise_reduction, request.sharpening)) ||
                (effects.active() && !gpuPhotoEffects(native, effects))) return false;
            if (pw != width || ph != height) {
                ImageData resized(static_cast<int>(width), static_cast<int>(height));
                c.bands(native, width, height, p, 1, resized);
                output = std::move(resized);
            } else output = std::move(native);
            retry_.succeeded();
            return true;
        }
        if (revision==0 || revision!=c.revision || input.width!=c.sourceWidth || input.height!=c.sourceHeight) {
            c.revision=0;c.allocate(c.source,input.pixels.size(),false);
            c.write(c.source, input.pixels.data(), input.pixels.size());
            c.revision=revision;c.sourceWidth=input.width;c.sourceHeight=input.height;
        }
        const bool early=request.intent==SONY2FUJI_INTENT_PREVIEW;
        const uint32_t pw=early ? width : input.width,ph=early ? height : input.height;
        c.dispatch(c.source,c.processing[0],p,0,input.width,input.height,pw,ph);
        auto* final=&c.processing[0];
        if (pw!=width || ph!=height) { c.dispatch(*final,c.resized,p,1,pw,ph,width,height);final=&c.resized; }
        ImageData result(static_cast<int>(width),static_cast<int>(height));c.read(*final,result);
        output=std::move(result);retry_.succeeded();return true;
    } catch (const ProcessingCancelled&) {
        // 取消交还调用方，不丢弃健康设备，也不进入重建退避。
        throw;
    } catch (const std::exception& error) {
        OutputDebugStringA(error.what());
        if (initializing || d3d11LostDevice(error) ||
            (impl_ && impl_->device && FAILED(d3d11DeviceStatus(*impl_->device.Get())))) {
            retry_.failed(d3d11RetryNow());
            impl_.reset();
        }
        return false;
    }
}
}
