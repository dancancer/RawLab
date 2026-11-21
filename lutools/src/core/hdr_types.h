#pragma once

#include <cstdint>

namespace sony2fuji {

inline constexpr uint32_t kHdrProcessingVersion = 1u;
inline constexpr uint32_t kHdrProcessingToneVersion = 2u;
inline constexpr uint32_t kHdrProcessingColorVersion = 3u;
inline constexpr uint32_t kHdrProcessingRenditionVersion = 4u;
inline constexpr uint32_t kHdrProcessingEffectsVersion = 5u;
inline constexpr uint32_t kHdrProcessingDetailVersion = 6u;
inline constexpr uint32_t kHdrProcessingLookVersion = 7u;
inline constexpr uint32_t kHdrProcessingChannelCurvesVersion = 8u;

inline constexpr uint32_t kHdrHeadroomUnknown = 0u;
inline constexpr uint32_t kHdrHeadroomDeclared = 1u;
inline constexpr uint32_t kHdrHeadroomMeasured = 2u;

inline constexpr uint32_t kHdrContainerUnknown = 0u;
inline constexpr uint32_t kHdrContainerJpeg = 1u;
inline constexpr uint32_t kHdrContainerHeif = 2u;
inline constexpr uint32_t kHdrContainerCameraRaw = 3u;
inline constexpr uint32_t kHdrContainerProRaw = 4u;

inline constexpr uint32_t kHdrProtocolUnknown = 0u;
inline constexpr uint32_t kHdrProtocolApple = 1u;
inline constexpr uint32_t kHdrProtocolIso = 2u;
inline constexpr uint32_t kHdrProtocolXmp = 3u;
inline constexpr uint32_t kHdrProtocolIsoXmp = 4u;

inline constexpr uint32_t kHdrColorUnknown = 0u;
inline constexpr uint32_t kHdrColorSrgb = 1u;
inline constexpr uint32_t kHdrColorDisplayP3 = 2u;
inline constexpr uint32_t kHdrColorBt2020 = 3u;

inline constexpr uint32_t kHdrMetadataIsoXmp = 1u;
inline constexpr uint32_t kHdrMetadataIso = 2u;

inline constexpr uint32_t kHdrIntentPreview = 0u;
inline constexpr uint32_t kHdrIntentFinal = 1u;

inline constexpr uint32_t kHdrSdrOutputJpeg = 0u;
inline constexpr uint32_t kHdrSdrOutputPng = 1u;
inline constexpr uint32_t kHdrSdrOutputDng = 4u;

inline constexpr uint32_t kHdrReasonNone = 0u;
inline constexpr uint32_t kHdrReasonUnsupportedSystem = 1u;
inline constexpr uint32_t kHdrReasonUnsupportedProtocol = 2u;
inline constexpr uint32_t kHdrReasonUnsupportedColor = 3u;
inline constexpr uint32_t kHdrReasonUnsupportedVersion = 4u;
inline constexpr uint32_t kHdrReasonMalformedAux = 5u;
inline constexpr uint32_t kHdrReasonNonfinite = 6u;
inline constexpr uint32_t kHdrReasonInvalidBuffer = 7u;
inline constexpr uint32_t kHdrReasonPreviewSource = 8u;
inline constexpr uint32_t kHdrReasonSourceChanged = 9u;
inline constexpr uint32_t kHdrReasonOutOfMemory = 10u;
inline constexpr uint32_t kHdrReasonOutputIo = 11u;
inline constexpr uint32_t kHdrReasonInvalidArgument = 12u;
inline constexpr uint32_t kHdrReasonUnsupportedGpu = 13u;
inline constexpr uint32_t kHdrReasonInputIo = 14u;
inline constexpr uint32_t kHdrReasonSameFile = 15u;
inline constexpr uint32_t kHdrReasonNotHdr = 16u;
inline constexpr uint32_t kHdrReasonUnsupportedRaw = 17u;
inline constexpr uint32_t kHdrReasonLookResource = 18u;
inline constexpr uint32_t kHdrReasonCameraDevelopment = 19u;
inline constexpr uint32_t kHdrReasonCameraAi = 20u;
inline constexpr uint32_t kHdrReasonCameraProfile = 21u;

inline constexpr uint32_t kHdrFieldNone = 0u;
inline constexpr uint32_t kHdrFieldSource = 1u;
inline constexpr uint32_t kHdrFieldHdrBuffer = 2u;
inline constexpr uint32_t kHdrFieldSdrBuffer = 3u;
inline constexpr uint32_t kHdrFieldRequest = 4u;
inline constexpr uint32_t kHdrFieldResult = 5u;
inline constexpr uint32_t kHdrFieldSession = 6u;
inline constexpr uint32_t kHdrFieldPath = 7u;
inline constexpr uint32_t kHdrFieldExport = 8u;
inline constexpr uint32_t kHdrFieldDiagnostic = 9u;
inline constexpr uint32_t kHdrFieldLook = 10u;
inline constexpr uint32_t kHdrFieldCameraDevelopment = 11u;

struct HDRSourceInfo {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t orientation = 0;
    uint32_t container = 0;
    uint32_t protocol = 0;
    uint32_t colorDescription = 0;
    float contentHeadroom = 0.0f;
    uint32_t headroomKind = 0;
    uint8_t sourceSha256[32]{};
};

struct HDRDecodeOptions {
    uint32_t intent = kHdrIntentPreview;
    uint32_t longEdge = 0;
};

struct HDRExportConfig {
    uint32_t jpegQuality = 0;
    uint32_t baseColor = kHdrColorSrgb;
    uint32_t metadataPolicy = 0;
    const char* metadataSourcePath = nullptr;
    uint8_t sourceSha256[32]{};
};

struct HDRSdrExportConfig {
    uint32_t outputFormat = kHdrSdrOutputJpeg;
    uint32_t quality = 0;
    const char* metadataSourcePath = nullptr;
    uint8_t sourceSha256[32]{};
};

} // namespace sony2fuji
