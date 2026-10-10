#include "compute_denoise.h"
#include "compute_denoise_shader.h"
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace sony2fuji {
namespace {
using Microsoft::WRL::ComPtr;
void checked(HRESULT result) { if (FAILED(result)) throw std::runtime_error("D3D11 filter error " + std::to_string(result)); }
struct Buffer final : FilterBuffer {
    ComPtr<ID3D11Buffer> data;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11UnorderedAccessView> uav;
};
const char* prefix = R"hlsl(
#define V3 float3
cbuffer Parameters : register(b0) {
    uint width, height, step, level;
    uint channels, radius, stage, count;
    float sigma, strength, epsilon;
    uint direction;
    uint sourceRow, outputRow, baseIndex, reserved;
    float4 vignette, grain;
};
StructuredBuffer<float> sourceA : register(t0);
StructuredBuffer<float> sourceB : register(t1);
RWStructuredBuffer<float> outputA : register(u0);
RWStructuredBuffer<float> outputB : register(u1);
float readA(uint i) { return sourceA[i]; }
float readB(uint i) { return sourceB[i]; }
void writeA(uint i, float value) { outputA[i] = value; }
void writeB(uint i, float value) { outputB[i] = value; }
)hlsl";
class Device final : public FilterDevice {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11ComputeShader> shader;
    ComPtr<ID3D11Buffer> constants;
    FilterBufferPtr dummy;
public:
    void initialize() {
        if (GetEnvironmentVariableW(L"RAWLAB_DISABLE_D3D11", nullptr, 0) > 0) throw std::runtime_error("D3D11 filters disabled");
        ComPtr<IDXGIFactory1> factory; checked(CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf())));
        std::vector<ComPtr<IDXGIAdapter1>> adapters;
        for (UINT i = 0;; ++i) {
            ComPtr<IDXGIAdapter1> adapter;
            const auto result = factory->EnumAdapters1(i, &adapter);
            if (result == DXGI_ERROR_NOT_FOUND) break;
            checked(result);
            DXGI_ADAPTER_DESC1 desc{}; checked(adapter->GetDesc1(&desc));
            if (!(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) adapters.push_back(adapter);
        }
        std::stable_sort(adapters.begin(), adapters.end(), [](const auto& a, const auto& b) {
            DXGI_ADAPTER_DESC1 x{}, y{}; a->GetDesc1(&x); b->GetDesc1(&y);
            return x.DedicatedVideoMemory > y.DedicatedVideoMemory;
        });
        const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
        for (const auto& adapter : adapters) if (SUCCEEDED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN,
            nullptr, 0, &level, 1, D3D11_SDK_VERSION, &device, nullptr, &context))) break;
        if (!device) throw std::runtime_error("No D3D11 hardware filter adapter");
        const std::string source = std::string(prefix) + kFilterShaderBody +
            "\n[numthreads(128,1,1)] void main(uint3 id : SV_DispatchThreadID) { filterPixel(baseIndex + id.x); }\n";
        ComPtr<ID3DBlob> code, errors;
        const auto compiled = D3DCompile(source.c_str(), source.size(), "RawLab filters", nullptr, nullptr,
            "main", "cs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_IEEE_STRICTNESS, 0, &code, &errors);
        if (FAILED(compiled) && errors) throw std::runtime_error(std::string(static_cast<const char*>(errors->GetBufferPointer()), errors->GetBufferSize()));
        checked(compiled); checked(device->CreateComputeShader(code->GetBufferPointer(), code->GetBufferSize(), nullptr, &shader));
        D3D11_BUFFER_DESC desc{}; desc.ByteWidth = sizeof(FilterParams); desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER; checked(device->CreateBuffer(&desc, nullptr, &constants));
        dummy = allocate(1);
    }
    std::unique_ptr<FilterContext> activate() override { return {}; }
    FilterBufferPtr allocate(size_t count, const float* input = nullptr) override {
        if (!count || count > UINT32_MAX / sizeof(float)) throw std::runtime_error("D3D11 filter buffer too large");
        auto buffer = std::make_unique<Buffer>();
        D3D11_BUFFER_DESC desc{}; desc.ByteWidth = static_cast<UINT>(count * sizeof(float)); desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_UNORDERED_ACCESS;
        desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED; desc.StructureByteStride = sizeof(float);
        D3D11_SUBRESOURCE_DATA data{}; data.pSysMem = input;
        checked(device->CreateBuffer(&desc, input ? &data : nullptr, &buffer->data));
        checked(device->CreateShaderResourceView(buffer->data.Get(), nullptr, &buffer->srv));
        checked(device->CreateUnorderedAccessView(buffer->data.Get(), nullptr, &buffer->uav));
        return buffer;
    }
    void dispatch(FilterParams params, FilterBuffer& source, FilterBuffer* other,
                  FilterBuffer& output, FilterBuffer* second = nullptr) override {
        auto& a = static_cast<Buffer&>(source); auto& b = static_cast<Buffer&>(other ? *other : *dummy);
        auto& c = static_cast<Buffer&>(output); auto& d = static_cast<Buffer&>(second ? *second : *dummy);
        context->CSSetShader(shader.Get(), nullptr, 0);
        auto cb = constants.Get(); context->CSSetConstantBuffers(0, 1, &cb);
        ID3D11ShaderResourceView* views[] = {a.srv.Get(), b.srv.Get()};
        ID3D11UnorderedAccessView* outputs[] = {c.uav.Get(), second ? d.uav.Get() : nullptr};
        context->CSSetShaderResources(0, 2, views); context->CSSetUnorderedAccessViews(0, 2, outputs, nullptr);
        constexpr uint32_t dispatchLimit = 65535 * 128;
        for (uint32_t offset = 0; offset < params.count;) {
            const auto chunk = std::min(dispatchLimit, params.count - offset);
            params.baseIndex = offset; context->UpdateSubresource(constants.Get(), 0, nullptr, &params, 0, 0);
            context->Dispatch((chunk + 127) / 128, 1, 1); offset += chunk;
        }
        ID3D11ShaderResourceView* emptyViews[2]{}; ID3D11UnorderedAccessView* emptyOutputs[2]{};
        context->CSSetShaderResources(0, 2, emptyViews); context->CSSetUnorderedAccessViews(0, 2, emptyOutputs, nullptr);
        checked(device->GetDeviceRemovedReason());
    }
    void read(FilterBuffer& buffer, size_t count, float* output) override {
        ComPtr<ID3D11Buffer> staging;
        D3D11_BUFFER_DESC desc{}; desc.ByteWidth = static_cast<UINT>(count * sizeof(float));
        desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        checked(device->CreateBuffer(&desc, nullptr, &staging));
        D3D11_BOX box{}; box.right = desc.ByteWidth; box.bottom = box.back = 1;
        context->CopySubresourceRegion(staging.Get(), 0, 0, 0, 0, static_cast<Buffer&>(buffer).data.Get(), 0, &box);
        D3D11_MAPPED_SUBRESOURCE mapped{}; checked(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
        std::memcpy(output, mapped.pData, desc.ByteWidth); context->Unmap(staging.Get(), 0);
        checked(device->GetDeviceRemovedReason());
    }
};
} // namespace
std::unique_ptr<FilterDevice> createD3D11FilterDevice() {
    auto device = std::make_unique<Device>(); device->initialize(); return device;
}
} // namespace sony2fuji
