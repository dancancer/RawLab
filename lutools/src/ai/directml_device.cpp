#include "directml_device.h"
#include <filesystem>
#include <stdexcept>
#include <vector>
#ifdef SONY2FUJI_ENABLE_DIRECTML
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#endif

namespace sony2fuji::ai {
bool isDirectMLHardware(uint32_t flags, uint32_t vendor, uint32_t device) {
    // DXGI_ADAPTER_FLAG_SOFTWARE；部分 Basic Render Driver 未设置该位。
    return !(flags & 2) && !(vendor == 0x1414 && device == 0x8c);
}

DirectMLAdapter findDirectMLAdapter() {
#ifdef SONY2FUJI_ENABLE_DIRECTML
    using Microsoft::WRL::ComPtr;
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) throw std::runtime_error("Cannot enumerate DirectML adapters");
    for (UINT index = 0; ; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        const auto status = factory->EnumAdapters1(index, &adapter);
        if (status == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(status)) throw std::runtime_error("Cannot read DirectML adapter");
        DXGI_ADAPTER_DESC1 description{};
        if (FAILED(adapter->GetDesc1(&description)) ||
            !isDirectMLHardware(description.Flags, description.VendorId, description.DeviceId)) continue;
        ComPtr<ID3D12Device> device;
        if (FAILED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)))) continue;
        LARGE_INTEGER driver{};
        adapter->CheckInterfaceSupport(__uuidof(IDXGIDevice), &driver);
        char name[512]{};
        if (!WideCharToMultiByte(CP_UTF8, 0, description.Description, -1, name, sizeof(name), nullptr, nullptr))
            throw std::runtime_error("Cannot read DirectML adapter name");
        return {static_cast<int>(index), std::string(name) + ":" + std::to_string(description.VendorId) + ":" +
            std::to_string(description.DeviceId) + ":" + std::to_string(driver.QuadPart)};
    }
    throw std::runtime_error("DirectML requires a hardware D3D12 adapter; software/WARP is not supported");
#else
    throw std::runtime_error("This build has no DirectML backend");
#endif
}

std::string directMLRuntimeVersion() {
    std::string identity = "directml-fp32-v1";
#ifdef SONY2FUJI_ENABLE_DIRECTML
    // 随应用打包的 DirectML DLL 版本与显卡驱动共同参与加速缓存身份。
    wchar_t path[32768]{};
    const auto module = GetModuleHandleW(L"onnxruntime.dll");
    if (module && GetModuleFileNameW(module, path, 32768)) {
        const auto library = std::filesystem::path(path).parent_path() / L"DirectML.dll";
        DWORD ignored = 0;
        const auto length = GetFileVersionInfoSizeW(library.c_str(), &ignored);
        std::vector<unsigned char> bytes(length);
        VS_FIXEDFILEINFO* info = nullptr; UINT size = 0;
        if (length && GetFileVersionInfoW(library.c_str(), 0, length, bytes.data()) &&
            VerQueryValueW(bytes.data(), L"\\", reinterpret_cast<void**>(&info), &size) && size >= sizeof(*info))
            identity += ":" + std::to_string(info->dwFileVersionMS) + ":" + std::to_string(info->dwFileVersionLS);
    }
#endif
    try { identity += ":" + findDirectMLAdapter().identity; }
    catch (const std::runtime_error&) { identity += ":unavailable"; }
    return identity;
}
}
