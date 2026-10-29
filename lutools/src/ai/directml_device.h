#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace sony2fuji::ai {
struct DirectMLAdapter {
    int index = -1, preference = -1;
    std::string id, name, driverVersion, luid, identity, error;
    uint32_t vendor = 0, device = 0;
    uint64_t dedicatedMemory = 0, sharedMemory = 0, memoryBudget = 0, memoryUsage = 0;
    bool available = false, integrated = false;
};
bool isDirectMLHardware(uint32_t flags, uint32_t vendor, uint32_t device);
DirectMLAdapter selectDirectMLAdapter(const std::vector<DirectMLAdapter>& adapters, const std::string& requestedID);
std::string directMLAdapterIdentity(const DirectMLAdapter& adapter);
std::vector<DirectMLAdapter> enumerateDirectMLAdapters();
DirectMLAdapter findDirectMLAdapter(const std::string& requestedID = {});
std::string directMLRuntimeVersion(const DirectMLAdapter* adapter = nullptr);
std::string directMLDevicesJSON();
}
