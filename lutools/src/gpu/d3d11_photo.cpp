#include "gpu/d3d11_photo.h"
#include "gpu/d3d11_photo_shader.h"
#include "core/photo_lut.h"
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
#include <vector>

namespace sony2fuji {
namespace {
using Microsoft::WRL::ComPtr;
void checked(HRESULT result) {
    if (FAILED(result)) throw std::runtime_error("Direct3D 11 operation failed: " + std::to_string(result));
}
struct alignas(16) Parameters {
    uint32_t dimensions[4], control[4];
    float toSrgb[3][4], toFilm[3][4];
    float exposureStrength[4], tone[4], detail[4], domainLow[4], domainHigh[4];
    uint32_t logTransfer[4];
};
static_assert(sizeof(Parameters) == 224);
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
        ComPtr<ID3DBlob> code, errors;
        const auto compiled = D3DCompile(kD3DPhotoShader, std::strlen(kD3DPhotoShader), "RawLab photo shader",
            nullptr, nullptr, "main", "cs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_IEEE_STRICTNESS, 0, &code, &errors);
        if (FAILED(compiled) && errors) {
            OutputDebugStringA(static_cast<const char*>(errors->GetBufferPointer()));
            std::cerr << static_cast<const char*>(errors->GetBufferPointer()) << '\n';
        }
        checked(compiled);
        checked(device->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &shader));
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = sizeof(Parameters); desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        checked(device->CreateBuffer(&desc, nullptr, &constants));
    }
    void allocate(Buffer& buffer, size_t count, bool writable) {
        if (!count || count > std::numeric_limits<UINT>::max() / sizeof(RGB)) throw std::runtime_error("GPU buffer too large");
        const auto bytes = count * sizeof(RGB);
        if (buffer.bytes == bytes) return;
        buffer = {};
        D3D11_BUFFER_DESC desc{};
        desc.ByteWidth = static_cast<UINT>(bytes); desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | (writable ? D3D11_BIND_UNORDERED_ACCESS : 0);
        desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED; desc.StructureByteStride = sizeof(RGB);
        checked(device->CreateBuffer(&desc, nullptr, &buffer.data));
        checked(device->CreateShaderResourceView(buffer.data.Get(), nullptr, &buffer.srv));
        if (writable) checked(device->CreateUnorderedAccessView(buffer.data.Get(), nullptr, &buffer.uav));
        buffer.bytes = bytes;
    }
    void setLut(const std::shared_ptr<LUT3D>& lut) {
        if (!lut || cachedLut == lut) return;
        const auto n = lut->getSize();
        std::vector<RGB> values;
        values.reserve(static_cast<size_t>(n)*n*n);
        for (int b=0;b<n;++b) for (int g=0;g<n;++g) for (int r=0;r<n;++r) values.push_back(lut->getValue(r,g,b));
        allocate(film,values.size(),false);
        context->UpdateSubresource(film.data.Get(),0,nullptr,values.data(),0,0);
        cachedLut = lut;
    }
    void dispatch(Buffer& input, Buffer& output, Parameters params, uint32_t stage,
        uint32_t sw, uint32_t sh, uint32_t dw, uint32_t dh) {
        allocate(output,static_cast<size_t>(dw)*dh,true);
        params.dimensions[0]=sw; params.dimensions[1]=sh; params.dimensions[2]=dw; params.dimensions[3]=dh;
        params.control[0]=stage;
        context->UpdateSubresource(constants.Get(),0,nullptr,&params,0,0);
        context->CSSetShader(shader.Get(),nullptr,0);
        auto cb=constants.Get(); context->CSSetConstantBuffers(0,1,&cb);
        ID3D11ShaderResourceView* views[]={input.srv.Get(),params.control[2] ? film.srv.Get() : nullptr};
        context->CSSetShaderResources(0,2,views);
        auto uav=output.uav.Get();context->CSSetUnorderedAccessViews(0,1,&uav,nullptr);
        context->Dispatch((dw+15)/16,(dh+15)/16,1);
        // Unbind before ping-pong: the next pass may read the previous UAV.
        ID3D11ShaderResourceView* emptyViews[2]{}; ID3D11UnorderedAccessView* emptyUav=nullptr;
        context->CSSetShaderResources(0,2,emptyViews);context->CSSetUnorderedAccessViews(0,1,&emptyUav,nullptr);
        checked(device->GetDeviceRemovedReason());
    }
    void read(Buffer& buffer, ImageData& output) {
        if (stagingBytes != buffer.bytes) {
            staging.Reset(); stagingBytes=0;
            D3D11_BUFFER_DESC desc{};desc.ByteWidth=static_cast<UINT>(buffer.bytes);
            desc.Usage=D3D11_USAGE_STAGING;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
            checked(device->CreateBuffer(&desc,nullptr,&staging));stagingBytes=buffer.bytes;
        }
        context->CopyResource(staging.Get(),buffer.data.Get());
        D3D11_MAPPED_SUBRESOURCE mapped{};
        checked(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
        std::memcpy(output.pixels.data(),mapped.pData,buffer.bytes);
        context->Unmap(staging.Get(),0);
        checked(device->GetDeviceRemovedReason());
    }
};
D3D11PhotoRenderer::D3D11PhotoRenderer() = default;
D3D11PhotoRenderer::~D3D11PhotoRenderer() = default;
bool D3D11PhotoRenderer::render(const ImageData& input, ColorSpace inputSpace,
    const sony2fuji_request& request, const std::shared_ptr<LUT3D>& lut,
    const RGB& wb, uint32_t width, uint32_t height, uint64_t revision, ImageData& output) {
    if (input.width<=0 || input.height<=0 || width==0 || height==0 || width>65535 || height>65535 ||
        input.pixels.size()!=static_cast<size_t>(input.width)*input.height) return false;
    // Diagnostic switch also exercises Auto fallback and Force failure in regression tests.
    if (GetEnvironmentVariableW(L"RAWLAB_DISABLE_D3D11",nullptr,0)>0) return false;
    try {
        if (!impl_) { impl_=std::make_unique<Impl>();impl_->initialize(); }
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
        if (lut && request.lut_strength>0) {
            c.setLut(lut);p.control[2]=1;p.control[3]=lut->getSize();
            p.logTransfer[0]=lut->inputTransfer()==LUTTransfer::FLog;
            p.logTransfer[1]=lut->outputTransfer()!=LUTTransfer::Display;
            p.logTransfer[2]=lut->outputTransfer()==LUTTransfer::FLog;
            auto low=lut->domainMin(),high=lut->domainMax();
            p.domainLow[0]=low.r;p.domainLow[1]=low.g;p.domainLow[2]=low.b;
            p.domainHigh[0]=high.r;p.domainHigh[1]=high.g;p.domainHigh[2]=high.b;
        }
        if (revision==0 || revision!=c.revision || input.width!=c.sourceWidth || input.height!=c.sourceHeight) {
            c.revision=0;c.allocate(c.source,input.pixels.size(),false);
            c.context->UpdateSubresource(c.source.data.Get(),0,nullptr,input.pixels.data(),0,0);
            c.revision=revision;c.sourceWidth=input.width;c.sourceHeight=input.height;
        }
        const bool early=request.intent==SONY2FUJI_INTENT_PREVIEW && request.sharpening<=0;
        const uint32_t pw=early ? width : input.width,ph=early ? height : input.height;
        c.dispatch(c.source,c.processing[0],p,0,input.width,input.height,pw,ph);
        int current=0;
        if (request.noise_reduction>0) { c.dispatch(c.processing[current],c.processing[1-current],p,2,pw,ph,pw,ph);current=1-current; }
        if (request.sharpening>0) { c.dispatch(c.processing[current],c.processing[1-current],p,3,pw,ph,pw,ph);current=1-current; }
        auto* final=&c.processing[current];
        if (pw!=width || ph!=height) { c.dispatch(*final,c.resized,p,1,pw,ph,width,height);final=&c.resized; }
        ImageData result(static_cast<int>(width),static_cast<int>(height));c.read(*final,result);
        output=std::move(result);return true;
    } catch (const std::exception& error) {
        OutputDebugStringA(error.what());impl_.reset();return false;
    }
}
}
