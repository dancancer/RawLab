#pragma once

namespace sony2fuji {

enum class ProcessingVersion {
    Legacy = 1,
    SwtV2 = 2
};

inline bool validProcessingVersion(ProcessingVersion version) {
    return version == ProcessingVersion::Legacy || version == ProcessingVersion::SwtV2;
}

} // namespace sony2fuji
