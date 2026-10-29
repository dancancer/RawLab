#include "directml_device.h"
#include "model_package.h"
#include <nlohmann/json.hpp>
#include <array>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#ifdef SONY2FUJI_ENABLE_DIRECTML
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <d3dkmthk.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#endif

namespace sony2fuji::ai {
namespace {
using Json = nlohmann::json;
Json adapterJSON(const DirectMLAdapter& value) {
    return {{"id",value.id}, {"name",value.name}, {"index",value.index}, {"luid",value.luid},
        {"vendor_id",value.vendor}, {"device_id",value.device}, {"driver_version",value.driverVersion},
        {"dedicated_memory_bytes",value.dedicatedMemory}, {"shared_memory_bytes",value.sharedMemory},
        {"memory_budget_bytes",value.memoryBudget}, {"memory_usage_bytes",value.memoryUsage},
        {"integrated",value.integrated}, {"available",value.available}, {"error",value.error}};
}
#ifdef SONY2FUJI_ENABLE_DIRECTML
using Microsoft::WRL::ComPtr;
std::string utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const auto length = WideCharToMultiByte(CP_UTF8,0,value.data(),static_cast<int>(value.size()),nullptr,0,nullptr,nullptr);
    if (length <= 0) return {};
    std::string result(length, '\0');
    WideCharToMultiByte(CP_UTF8,0,value.data(),static_cast<int>(value.size()),result.data(),length,nullptr,nullptr);
    return result;
}
std::string hex(uint64_t value) {
    std::ostringstream out; out << std::hex << value; return out.str();
}
std::wstring pnpKey(LUID luid, D3DKMT_PNP_KEY_TYPE type) {
    D3DKMT_OPENADAPTERFROMLUID opened{}; opened.AdapterLuid = luid;
    if (D3DKMTOpenAdapterFromLuid(&opened) != 0) return {};
    std::array<wchar_t,1024> buffer{}; UINT length = static_cast<UINT>(buffer.size());
    D3DKMT_QUERY_PHYSICAL_ADAPTER_PNP_KEY data{};
    data.PnPKeyType = type; data.pDest = buffer.data(); data.pCchDest = &length;
    D3DKMT_QUERYADAPTERINFO query{};
    query.hAdapter = opened.hAdapter; query.Type = KMTQAITYPE_PHYSICALADAPTERPNPKEY;
    query.pPrivateDriverData = &data; query.PrivateDriverDataSize = sizeof(data);
    const auto status = D3DKMTQueryAdapterInfo(&query);
    D3DKMT_CLOSEADAPTER close{}; close.hAdapter = opened.hAdapter; D3DKMTCloseAdapter(&close);
    return status == 0 && length > 0 && length <= buffer.size() ? std::wstring(buffer.data()) : std::wstring();
}
std::string driverVersion(IDXGIAdapter1* adapter, LUID luid) {
    auto key = pnpKey(luid,D3DKMT_PNP_KEY_SOFTWARE);
    const std::wstring prefix = L"\\Registry\\Machine\\";
    if (_wcsnicmp(key.c_str(),prefix.c_str(),prefix.size()) == 0) key.erase(0,prefix.size());
    std::array<wchar_t,256> value{}; DWORD bytes = sizeof(value);
    if (!key.empty() && RegGetValueW(HKEY_LOCAL_MACHINE,key.c_str(),L"DriverVersion",RRF_RT_REG_SZ,
        nullptr,value.data(),&bytes) == ERROR_SUCCESS) return utf8(value.data());
    LARGE_INTEGER version{};
    if (FAILED(adapter->CheckInterfaceSupport(__uuidof(IDXGIDevice),&version))) return {};
    const auto packed = static_cast<uint64_t>(version.QuadPart);
    return std::to_string((packed >> 48) & 65535) + "." + std::to_string((packed >> 32) & 65535) + "." +
        std::to_string((packed >> 16) & 65535) + "." + std::to_string(packed & 65535);
}
#endif
}

std::vector<DirectMLAdapter> enumerateDirectMLAdapters() {
    std::vector<DirectMLAdapter> result;
#ifdef SONY2FUJI_ENABLE_DIRECTML
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) throw std::runtime_error("Cannot enumerate DirectML adapters");
    for (UINT index = 0; ; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        const auto status = factory->EnumAdapters1(index,&adapter);
        if (status == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(status)) throw std::runtime_error("Cannot read DirectML adapter");
        DXGI_ADAPTER_DESC1 description{};
        if (FAILED(adapter->GetDesc1(&description)) ||
            !isDirectMLHardware(description.Flags,description.VendorId,description.DeviceId)) continue;
        DirectMLAdapter value;
        value.index = static_cast<int>(index); value.name = utf8(description.Description);
        value.vendor = description.VendorId; value.device = description.DeviceId;
        value.luid = hex(static_cast<uint64_t>(static_cast<uint32_t>(description.AdapterLuid.HighPart)) << 32 |
                         description.AdapterLuid.LowPart);
        value.dedicatedMemory = description.DedicatedVideoMemory; value.sharedMemory = description.SharedSystemMemory;
        const auto key = utf8(pnpKey(description.AdapterLuid,D3DKMT_PNP_KEY_HARDWARE));
        // LUID 和枚举序号不能跨重启持久化；重复的硬件后备标识不允许用于手动选择。
        value.id = key.empty() ? "hardware:" + hex(value.vendor) + ":" + hex(value.device) + ":" +
            hex(description.SubSysId) + ":" + hex(description.Revision) : "pnp:" + sha256Bytes(key.data(),key.size());
        value.driverVersion = driverVersion(adapter.Get(),description.AdapterLuid);
        ComPtr<ID3D12Device> device;
        const auto created = D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device));
        value.available = SUCCEEDED(created);
        if (!value.available) value.error = "D3D12CreateDevice failed: 0x" + hex(static_cast<uint32_t>(created));
        D3D12_FEATURE_DATA_ARCHITECTURE architecture{};
        value.integrated = value.dedicatedMemory <= 256ull * 1024 * 1024;
        if (device && SUCCEEDED(device->CheckFeatureSupport(D3D12_FEATURE_ARCHITECTURE,&architecture,sizeof(architecture))))
            value.integrated = architecture.UMA != FALSE;
        ComPtr<IDXGIAdapter3> memoryAdapter;
        DXGI_QUERY_VIDEO_MEMORY_INFO memory{};
        if (SUCCEEDED(adapter.As(&memoryAdapter)) &&
            SUCCEEDED(memoryAdapter->QueryVideoMemoryInfo(0,DXGI_MEMORY_SEGMENT_GROUP_LOCAL,&memory))) {
            value.memoryBudget = memory.Budget; value.memoryUsage = memory.CurrentUsage;
        }
        value.identity = directMLAdapterIdentity(value);
        result.push_back(std::move(value));
    }
    ComPtr<IDXGIFactory6> preferred;
    if (SUCCEEDED(factory.As(&preferred))) {
        for (UINT rank = 0; ; ++rank) {
            ComPtr<IDXGIAdapter1> adapter;
            if (FAILED(preferred->EnumAdapterByGpuPreference(rank,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&adapter)))) break;
            DXGI_ADAPTER_DESC1 description{};
            if (FAILED(adapter->GetDesc1(&description))) continue;
            const auto luid = hex(static_cast<uint64_t>(static_cast<uint32_t>(description.AdapterLuid.HighPart)) << 32 |
                                  description.AdapterLuid.LowPart);
            for (auto& value : result) if (value.luid == luid) value.preference = static_cast<int>(rank);
        }
    }
#endif
    return result;
}

DirectMLAdapter findDirectMLAdapter(const std::string& requestedID) {
    return selectDirectMLAdapter(enumerateDirectMLAdapters(),requestedID);
}

std::string directMLDevicesJSON() {
    Json result = {{"version",1}, {"devices",Json::array()}, {"recommended_id",""}, {"error",""}};
    try {
        const auto adapters = enumerateDirectMLAdapters();
        for (const auto& adapter : adapters) result["devices"].push_back(adapterJSON(adapter));
        result["recommended_id"] = selectDirectMLAdapter(adapters,{}).id;
    } catch (const std::exception& error) { result["error"] = error.what(); }
    return result.dump(-1,' ',false,Json::error_handler_t::replace);
}

std::string directMLRuntimeVersion(const DirectMLAdapter* adapter) {
    std::string identity = "directml-fp32-v2";
#ifdef SONY2FUJI_ENABLE_DIRECTML
    wchar_t path[32768]{};
    const auto module = GetModuleHandleW(L"onnxruntime.dll");
    if (module && GetModuleFileNameW(module,path,32768)) {
        const auto library = std::filesystem::path(path).parent_path() / L"DirectML.dll";
        DWORD ignored = 0;
        const auto length = GetFileVersionInfoSizeW(library.c_str(),&ignored);
        std::vector<unsigned char> bytes(length);
        VS_FIXEDFILEINFO* info = nullptr; UINT size = 0;
        if (length && GetFileVersionInfoW(library.c_str(),0,length,bytes.data()) &&
            VerQueryValueW(bytes.data(),L"\\",reinterpret_cast<void**>(&info),&size) && size >= sizeof(*info))
            identity += ":" + std::to_string(info->dwFileVersionMS) + ":" + std::to_string(info->dwFileVersionLS);
    }
#endif
    if (adapter) return identity + ":" + directMLAdapterIdentity(*adapter);
    try { return identity + ":" + findDirectMLAdapter().identity; }
    catch (const std::runtime_error&) { return identity + ":unavailable"; }
}
}
