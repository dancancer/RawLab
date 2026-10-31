#include "ai/directml_device.h"
#include <algorithm>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji::ai;

void require(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}

DirectMLAdapter adapter(int index, const char* id, bool integrated, uint64_t memory, int preference) {
    DirectMLAdapter value;
    value.index = index; value.id = id; value.name = id; value.available = true;
    value.integrated = integrated; value.dedicatedMemory = memory; value.preference = preference;
    value.driverVersion = "31.0.15.0000";
    return value;
}

int main() {
    try {
        const auto intel = adapter(0, "pnp:intel", true, 128, 1);
        const auto nvidia = adapter(1, "pnp:nvidia", false, 8192, 0);
        require(selectDirectMLAdapter({intel, nvidia}, "").id == nvidia.id,
                "Auto chose the first integrated GPU instead of the discrete GPU");
        require(selectDirectMLAdapter({intel, nvidia}, intel.id).id == intel.id,
                "Explicit integrated GPU selection was ignored");
        auto reordered = nvidia; reordered.index = 0;
        require(selectDirectMLAdapter({reordered, intel}, nvidia.id).index == 0,
                "A saved device selection depended on enumeration order");
        auto unavailable = nvidia; unavailable.available = false;
        require(selectDirectMLAdapter({intel, unavailable}, "").id == intel.id,
                "Auto did not skip an unavailable discrete device");
        require(selectDirectMLAdapter({intel}, "").id == intel.id,
                "An integrated-only computer lost its hardware backend");
        for (const auto& devices : {std::vector<DirectMLAdapter>{intel},
                                   std::vector<DirectMLAdapter>{intel, unavailable}}) {
            bool rejected = false;
            try { selectDirectMLAdapter(devices, nvidia.id); }
            catch (const std::runtime_error&) { rejected = true; }
            require(rejected, "Unavailable explicit GPU silently changed to a different device");
        }
        auto external = adapter(2, "pnp:external", false, 4096, 0);
        auto internal = nvidia; internal.preference = 1;
        require(selectDirectMLAdapter({intel, internal, external}, "").id == external.id,
                "Auto ignored the operating system high-performance preference");
        auto noPreference = nvidia; noPreference.preference = -1;
        auto smaller = adapter(2, "pnp:smaller", false, 4096, -1);
        require(selectDirectMLAdapter({intel, smaller, noPreference}, "").id == nvidia.id,
                "The legacy preference fallback ignored dedicated memory");
        require(!isDirectMLHardware(2, 0x10de, 1) && !isDirectMLHardware(0, 0x1414, 0x8c),
                "Software/WARP adapter was accepted");
        require(directMLAdapterIdentity(intel) != directMLAdapterIdentity(nvidia),
                "Two devices shared a runtime cache identity");
        auto newDriver = nvidia; newDriver.driverVersion = "32.0.15.0000";
        require(directMLAdapterIdentity(nvidia) != directMLAdapterIdentity(newDriver),
                "Driver update did not invalidate the runtime identity");
        bool ambiguous = false;
        try { selectDirectMLAdapter({nvidia, nvidia}, nvidia.id); }
        catch (const std::runtime_error&) { ambiguous = true; }
        require(ambiguous, "Ambiguous hardware identity silently selected one device");
        std::cout << "PASS AI GPU auto/manual selection and stable device identity\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
