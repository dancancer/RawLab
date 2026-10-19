#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace sony2fuji {

enum class DcpCompilerError : uint32_t {
    None = 0,
    Malformed = 1,
    TooLarge = 2,
    InvalidCalibration = 3,
    MissingToneCurve = 4,
    AutomaticBlack = 5,
    TripleIlluminant = 6,
    UnsupportedStages = 7,
    InvalidTable = 8,
    InvalidToneCurve = 9,
    InvalidExposure = 10,
};

// Compile a DCP byte buffer to the native RLOOK payload. Errors are reported
// through the enum and no output is produced on failure.
std::vector<uint8_t> compileDcp(const void* data, std::size_t size,
                                const std::string& sourceName,
                                DcpCompilerError& error);

} // namespace sony2fuji
