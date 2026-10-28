#pragma once

namespace sony2fuji {

enum class ProcessingVersion {
    Legacy = 1,
    C5V2 = 2
};

inline bool validProcessingVersion(ProcessingVersion version) {
    return version == ProcessingVersion::Legacy || version == ProcessingVersion::C5V2;
}

} // namespace sony2fuji
