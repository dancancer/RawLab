#include "directml_device.h"
#include <limits>
#include <stdexcept>
#include <tuple>

namespace sony2fuji::ai {
bool isDirectMLHardware(uint32_t flags, uint32_t vendor, uint32_t device) {
    return !(flags & 2) && !(vendor == 0x1414 && device == 0x8c);
}

DirectMLAdapter selectDirectMLAdapter(const std::vector<DirectMLAdapter>& adapters, const std::string& requestedID) {
    const DirectMLAdapter* selected = nullptr;
    auto rank = [](const DirectMLAdapter& adapter) {
        return std::make_tuple(adapter.integrated,
            adapter.preference < 0 ? std::numeric_limits<int>::max() : adapter.preference,
            std::numeric_limits<uint64_t>::max() - adapter.dedicatedMemory);
    };
    for (const auto& adapter : adapters) {
        if (!requestedID.empty()) {
            if (adapter.id != requestedID) continue;
            if (selected) throw std::runtime_error("The selected AI GPU identity is ambiguous; choose Auto in Settings");
            selected = &adapter;
        } else if (adapter.available && (!selected || rank(adapter) < rank(*selected))) selected = &adapter;
    }
    if (selected && selected->available) return *selected;
    if (!requestedID.empty())
        throw std::runtime_error("The selected AI GPU is unavailable; choose an available GPU or Auto in Settings");
    throw std::runtime_error("DirectML requires a hardware D3D12 adapter; software/WARP is not supported");
}

std::string directMLAdapterIdentity(const DirectMLAdapter& adapter) {
    return adapter.id + (adapter.id.rfind("hardware:",0) == 0 ? ":" + adapter.luid : "") + ":" + std::to_string(adapter.vendor) + ":" +
        std::to_string(adapter.device) + ":" + adapter.driverVersion;
}
}
