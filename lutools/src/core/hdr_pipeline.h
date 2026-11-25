#pragma once

#include "core/hdr_rendering.h"
#include "core/hdr_stream.h"
#include "core/hdr_types.h"
#include "core/pixel_buffer.h"
#include "sony2fuji/common.h"
#include "sony2fuji/dcp_compiler.h"
#include "sony2fuji/lens_correction.h"
#include "sony2fuji/processing_version.h"
#include "sony2fuji/raw_processor.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

namespace sony2fuji {
class HDRLook;
struct RAWBayerOverride;
struct RAWBayerSource;
} // namespace sony2fuji

namespace sony2fuji::hdr {

struct StreamSourcePin;

struct CameraProfileResource {
    HDRCameraProfile profile;
    std::string digest;
};

struct CameraRawStamp {
    uintmax_t size = 0;
    std::filesystem::file_time_type modified{};
};

struct CameraRawProbeResult {
    int width = 0;
    int height = 0;
    bool supportsNoiseReduction = false;
};

struct CameraRawDevelopmentSpec {
    bool hasDevelopment = false;
    bool preview = false;
    uint32_t longEdge = 0;
    bool legacySonyCrop = true;
    uint32_t whiteBalance = 0;
    uint32_t exposureReference = 0;
    float temperature = 0.0f;
    float tint = 0.0f;
    uint32_t fbddLevel = 0;
    uint32_t lensFlags = 0;
    const char* lensProfileId = nullptr;
    std::function<std::shared_ptr<const LensCorrectionDatabase>()> getLensDatabase;
    bool hasCameraProfile = false;
    const char* cameraProfilePath = nullptr;
    const char* cameraProfileSha256 = nullptr;
    bool useAi = false;
    std::function<std::string(const char*)> aiKeyForFile;
    std::function<RAWBayerOverride(const std::string&, const RAWBayerSource&)> loadAiOverride;
};

struct CameraRawDecodedPair {
    HDRImagePair pixels;
    uint32_t sourceHeadroomKind = kHdrHeadroomUnknown;
    bool usedCameraProfile = false;
};

struct ExportSourceMetadata {
    std::array<uint8_t, 32> sourceSha256{};
    std::string sourcePath;
    std::string lookPath;
    std::string cameraProfilePath;
};

struct BufferViewDescriptor {
    uint32_t version = 0;
    uint32_t structSize = 0;
    const void* data = nullptr;
    uint64_t sizeBytes = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint64_t strideBytes = 0;
    uint32_t pixelFormat = 0;
    uint32_t colorEncoding = 0;
    bool isLinearFloat = false;
    bool isDisplaySrgb8 = false;
    float contentHeadroom = 0.0f;
    uint32_t headroomKind = kHdrHeadroomUnknown;
};

struct PairIdentitySpec {
    uint32_t nativeWidth = 0;
    uint32_t nativeHeight = 0;
    uint32_t outputNativeWidth = 0;
    uint32_t outputNativeHeight = 0;
    uint32_t orientationApplied = 0;
    uint32_t sourceIntent = 0;
    uint32_t renderIntent = 0;
    uint32_t isProxy = 0;
    uint64_t decodeRevision = 0;
    float sourceHeadroom = 0.0f;
    uint32_t sourceHeadroomKind = kHdrHeadroomUnknown;
};

struct PairSnapshot {
    uint64_t ownerToken = 0;
    BufferViewDescriptor hdr;
    BufferViewDescriptor sdr;
    PairIdentitySpec identity;
    std::array<uint8_t, 32> sourceSha256{};
};

struct OwnedPairRecord {
    HDRImagePair pixels;
    float hdrContentHeadroom = 0.0f;
    float sdrContentHeadroom = 0.0f;
    uint32_t sourceHeadroomKind = kHdrHeadroomUnknown;
    ExportSourceMetadata meta;
    PairSnapshot published;
};

struct StreamSourceSpec {
    uint32_t nativeWidth = 0;
    uint32_t nativeHeight = 0;
    uint32_t orientationApplied = 0;
    uint32_t sourceIntent = 0;
    uint64_t decodeRevision = 0;
    const char* decoderIdentifier = nullptr;
    std::array<uint8_t, 32> sourceSha256{};
    HDRRowSource rows;
};

struct ProRAWStreamExportResult {
    HDRStreamResult stream;
    uint32_t nativeWidth = 0;
    uint32_t nativeHeight = 0;
};

void validateHeadroomIdentity(float value, uint32_t kind, uint32_t field);
void validateBufferDescriptor(const BufferViewDescriptor& buffer, bool isHDR);
void validateDecodeSize(uint32_t intent, uint32_t longEdge, bool requirePositivePreviewEdge);
void validatePairInputs(const BufferViewDescriptor& hdrBuffer, const BufferViewDescriptor& sdrBuffer,
                        const PairIdentitySpec& identity);
std::shared_ptr<OwnedPairRecord> acquirePairRecord(const PairSnapshot& snapshot);
uint64_t registerPairRecord(std::shared_ptr<OwnedPairRecord> record, const PairSnapshot& published);
void releasePairRecord(uint64_t ownerToken);
float measureContentHeadroom(const ImageData& image, float measuredContentHeadroom);

std::shared_ptr<const HDRLook> loadLookResource(const char* file, std::string_view expected = {});
std::shared_ptr<const HDRLook> loadLookForRequest(const char* lookPath, float lookStrength,
                                                  const char sha256[65], std::string* outLookPath);
CameraProfileResource loadCameraProfileResource(const char* file, std::string_view expected = {});

CameraRawStamp stampCameraRawFile(const std::filesystem::path& file);
CameraRawProbeResult probeCameraRaw(const char* file, ProcessingVersion version);
CameraRawDecodedPair decodeCameraRaw(const char* file, const CameraRawDevelopmentSpec& spec);

float estimateAutoExposureEV(const ImageData& hdrImage, float temperature, float tint);
std::pair<uint32_t, uint32_t> computeGeometryOutputSize(uint32_t nativeWidth, uint32_t nativeHeight,
                                                        const GeometryOptions& geometry);

HDRImagePair renderPair(HDRImagePair& source, bool ownedSource, const HDRRenderOptions& options);
ImageData createHslProbeImage(HDRImagePair& source, bool ownedSource, const HDRRenderOptions& options);

void ensureDifferentFile(const std::string& sourcePath, const char* target);
void prepareHEIFExport(const HDRExportConfig& config,
                       const BufferViewDescriptor* borrowedHdr,
                       const BufferViewDescriptor* borrowedSdr);
void exportImagePairJPEG(const HDRImagePair& pixels, const ExportSourceMetadata& meta,
                         const HDRExportConfig& config, const char* targetFile);
void exportImagePairHEIF(const HDRImagePair& pixels, const ExportSourceMetadata& meta,
                         const HDRExportConfig& config, const char* targetFile, bool preAdmitted);
void exportImagePairSDR(const HDRImagePair& pixels, const ExportSourceMetadata& meta,
                        const HDRSdrExportConfig& config, const char* targetFile);

ProRAWStreamExportResult exportProRAWStream(const char* sourceFile, const HDRRenderOptions& options,
                                            const std::string& lookPath, const HDRExportConfig& config,
                                            bool keepHDR, const char* temporaryRoot, const char* targetFile);
#if defined(__APPLE__)
ProRAWStreamExportResult exportAppleProRAWStream(const char* sourceFile, const HDRRenderOptions& options,
                                                 const std::string& lookPath, const HDRExportConfig& config,
                                                 bool keepHDR, const char* temporaryRoot, const char* targetFile);
#endif
HDRStreamResult exportRowStream(const StreamSourceSpec& source, const HDRRenderOptions& options,
                                const std::string& lookPath, const HDRExportConfig& config,
                                bool keepHDR, const char* temporaryRoot, const char* targetFile);

struct RoiCameraRawCacheEntry {
    std::string file;
    uintmax_t fileSize = 0;
    std::filesystem::file_time_type modified{};
    bool hasDevelopment = false;
    bool legacySonyCrop = true;
    uint32_t whiteBalance = 0;
    uint32_t exposureReference = 0;
    float temperature = 0.0f;
    float tint = 0.0f;
    uint32_t fbddLevel = 0;
    uint32_t lensFlags = 0;
    std::string lensProfileId;
    bool hasCameraProfile = false;
    std::string cameraProfilePath;
    std::string cameraProfileSha256;
    bool useAi = false;
    std::string aiKey;

    ImageData hdr;
    uint32_t nativeWidth = 0;
    uint32_t nativeHeight = 0;
    uint32_t sourceHeadroomKind = kHdrHeadroomUnknown;
    float sourceHeadroom = 0.0f;
    uint64_t decodeRevision = 0;
    bool isProxy = false;
    bool usedCameraProfile = false;
};

struct RoiFileCacheEntry {
    std::string file;
    uintmax_t fileSize = 0;
    std::filesystem::file_time_type modified{};
    HDRImagePair pixels;
    ExportSourceMetadata meta;
    uint32_t sourceHeadroomKind = kHdrHeadroomUnknown;
};

struct RoiSessionCache {
    RoiCameraRawCacheEntry cameraRaw;
    RoiFileCacheEntry file;
};

struct RoiRenderOutput {
    HDRImagePair pixels;
    float hdrHeadroom = 0.0f;
    float sdrHeadroom = 0.0f;
    uint32_t sourceHeadroomKind = kHdrHeadroomUnknown;
    ExportSourceMetadata meta;
    HDRRoiSourceBounds bounds;
    bool isProxy = false;
};

RoiRenderOutput renderPairROI(HDRImagePair& source, const std::string& lookPath,
    const ExportSourceMetadata& sourceMeta, uint32_t headroomKind,
    const HDRRenderOptions& options, const HDRRoiSpec& roi);
RoiRenderOutput renderCameraRawROI(RoiSessionCache& cache, const char* file,
    const CameraRawDevelopmentSpec& devSpec, const std::string& lookPath,
    const HDRRenderOptions& options, const HDRRoiSpec& roi);
RoiRenderOutput renderFileROI(RoiSessionCache& cache, const char* file,
    const std::string& lookPath, const HDRRenderOptions& options, const HDRRoiSpec& roi);

#if defined(__APPLE__)
struct TiledSourceInput {
    const HDRImagePair* ownedCameraPixels = nullptr;
    const ExportSourceMetadata* ownedCameraMeta = nullptr;
    const StreamSourceSpec* stream = nullptr;
};

struct TiledExportOutput {
    HDRStreamResult stream;
    uint32_t sourceWidth = 0;
    uint32_t sourceHeight = 0;
    uint64_t decodeRevision = 0;
};

TiledExportOutput exportTiledStream(const TiledSourceInput& input, const char* sourceFile,
                                    const HDRRenderOptions& options, const std::string& lookPath,
                                    const HDRExportConfig& config, bool encodeHeif,
                                    const char* temporaryRoot, const char* targetFile);
#endif

} // namespace sony2fuji::hdr
