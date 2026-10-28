#pragma once
#include <cstdint>
#include <string>

namespace sony2fuji::ai {
struct DirectMLAdapter { int index; std::string identity; };
bool isDirectMLHardware(uint32_t flags, uint32_t vendor, uint32_t device);
DirectMLAdapter findDirectMLAdapter();
std::string directMLRuntimeVersion();
}
