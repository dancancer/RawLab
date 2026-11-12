#pragma once

namespace sony2fuji {

enum class ProcessingVersion {
    Legacy = 1,
    C5V2 = 2,
    BasicV3 = 3
};

inline bool validProcessingVersion(ProcessingVersion version) {
    return version == ProcessingVersion::Legacy || version == ProcessingVersion::C5V2 ||
        version == ProcessingVersion::BasicV3;
}

inline bool usesC5Denoise(ProcessingVersion version) {
    return version == ProcessingVersion::C5V2 || version == ProcessingVersion::BasicV3;
}

inline bool usesLegacySonyCrop(ProcessingVersion version) {
    return version == ProcessingVersion::Legacy || version == ProcessingVersion::C5V2;
}

} // namespace sony2fuji
