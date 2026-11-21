#include "core/hdr_pipeline.h"

#include "core/hdr_look.h"
#include "core/hdr_progress.h"
#include "core/hdr_resample.h"
#include "core/hdr_srgb_lut.h"
#include "core/hdr_storage.h"
#include "core/parallel_pixels.h"
#include "core/parsed_resource_cache.h"
#include "core/photo_color.h"
#include "core/photo_rendering.h"
#include "core/processing_cancellation.h"
#include "core/proraw_source.h"
#include "core/rendered_dng.h"
#include "core/sha256.h"
#include "platform/hdr_image.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <limits>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <unordered_map>

namespace sony2fuji::hdr {
namespace {

std::atomic<uint64_t> nextCameraRevision{1};
std::mutex ownersMutex;
std::unordered_map<uint64_t, std::shared_ptr<OwnedPairRecord>> owners;
std::atomic<uint64_t> nextOwnerToken{1};

[[noreturn]] void fail(uint32_t reason, uint32_t field, const char* message,
                       RenderStatus status = RenderStatus::InvalidArgument) {
    throw Error(status, reason, field, message);
}

bool isLowerHex64(const char* hex) {
    return hex && hex[64] == '\0' && std::all_of(hex, hex + 64, [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    });
}

float decodeSRGB(uint8_t component) {
    const float x = component / 255.0f;
    return x <= 0.04045f ? x / 12.92f : std::pow((x + 0.055f) / 1.055f, 2.4f);
}

void linearToDisplaySRGB(RGB* pixels, size_t count) {
    parallelPixelRanges(count, [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            auto& pixel = pixels[i];
            pixel.r = linearToSrgbUnit(pixel.r);
            pixel.g = linearToSrgbUnit(pixel.g);
            pixel.b = linearToSrgbUnit(pixel.b);
        }
    });
}

void cameraRawStatus(ErrorCode code) {
    switch (code) {
        case ErrorCode::Success:
            return;
        case ErrorCode::OutOfMemory:
            throw std::bad_alloc();
        case ErrorCode::FileNotFound:
            fail(kHdrReasonInputIo, kHdrFieldPath, "Cannot read camera RAW", RenderStatus::IoError);
        case ErrorCode::InvalidFormat:
            fail(kHdrReasonUnsupportedRaw, kHdrFieldSource, "Unsupported camera RAW for HDR",
                 RenderStatus::Unsupported);
        default:
            fail(kHdrReasonInvalidBuffer, kHdrFieldSource, "Camera RAW development failed",
                 RenderStatus::ProcessingError);
    }
}

float cameraLuminance(const RGB& pixel) {
    return 0.2126f * pixel.r + 0.7152f * pixel.g + 0.0722f * pixel.b;
}

void protectCameraAIHighlights(const ImageData& reference, ImageData& denoised) {
    if (denoised.width != reference.width || denoised.height != reference.height) {
        cameraRawStatus(ErrorCode::InvalidFormat);
    }
    parallelPixelRanges(reference.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const auto& original = reference.pixels[i];
            auto& pixel = denoised.pixels[i];
            const float peak = std::max({original.r, original.g, original.b});
            if (peak >= 1.0f) {
                pixel = original;
                continue;
            }
            // 白平衡、基准曝光和矩阵转换都可能将像素推过参考白。
            const float t = std::clamp((peak - 0.5f) * 2.0f, 0.0f, 1.0f);
            float amount = 1.0f - t * t * (3.0f - 2.0f * t);
            const float denoisedPeak = std::max({pixel.r, pixel.g, pixel.b});
            if (denoisedPeak > 1.0f) {
                amount = std::min(amount, (1.0f - peak) / (denoisedPeak - peak));
            }
            pixel = {
                original.r + (pixel.r - original.r) * amount,
                original.g + (pixel.g - original.g) * amount,
                original.b + (pixel.b - original.b) * amount,
            };
        }
    });
}

RGB cameraSDR(const RGB& pixel) {
    const float y = cameraLuminance(pixel);
    if (y <= 0.0f) {
        return {0.0f, 0.0f, 0.0f};
    }
    const float mapped = neutralDisplayLinear(y);
    const float highest = std::max({pixel.r, pixel.g, pixel.b});
    const float lowest = std::min({pixel.r, pixel.g, pixel.b});
    // Reduce chroma about mapped luminance only as far as sRGB requires.
    float chroma = mapped / y;
    if (highest > y) {
        chroma = std::min(chroma, (1.0f - mapped) / (highest - y));
    }
    if (lowest < y) {
        chroma = std::min(chroma, mapped / (y - lowest));
    }
    auto component = [&](float value) { return std::clamp(mapped + (value - y) * chroma, 0.0f, 1.0f); };
    return {component(pixel.r), component(pixel.g), component(pixel.b)};
}

void requireFinalSource(const HDRImagePair& image) {
    if (image.isProxy || image.sourceQuality != HDRQuality::Final || image.renderQuality != HDRQuality::Final) {
        fail(kHdrReasonPreviewSource, kHdrFieldSource, "FINAL requires a full source and render");
    }
}

void ensureExportTargetsSafe(const ExportSourceMetadata& meta, const char* target) {
    ensureDifferentFile(meta.sourcePath, target);
    ensureDifferentFile(meta.lookPath, target);
    ensureDifferentFile(meta.cameraProfilePath, target);
}

void validateMetadataSourceMatch(const ExportSourceMetadata& meta, const char* file, const uint8_t sha[32]) {
    if (!file) {
        return;
    }
    if (!*file) {
        fail(kHdrReasonInvalidArgument, kHdrFieldPath, "Missing HDR file path");
    }
    if (std::memcmp(meta.sourceSha256.data(), sha, 32) != 0) {
        fail(kHdrReasonSourceChanged, kHdrFieldExport,
             "Metadata source identity differs from the decoded image");
    }
}

void exportSDRDNG(const HDRImagePair& pixels, uint32_t quality, const char* metadataSourcePath,
                  const uint8_t sourceSha256[32], const char* file) {
    if (quality > 100) {
        fail(kHdrReasonInvalidArgument, kHdrFieldExport, "Invalid SDR quality");
    }
    if (metadataSourcePath) {
        ensureDifferentFile(std::string(metadataSourcePath), file);
        const auto info = probeFile(metadataSourcePath);
        if (std::memcmp(info.sourceSha256, sourceSha256, 32) != 0) {
            fail(kHdrReasonSourceChanged, kHdrFieldExport, "HDR metadata source changed");
        }
    }
    // 既有 DNG writer 消费显示编码 sRGB，并自行转成中性的 16 位整数 LinearRaw。
    // 只烘焙 SDR 呈现，不给成片复制来源相机的 RAW 白平衡/校准标签。
    ImageData display = pixels.sdr;
    linearToDisplaySRGB(display.pixels.data(), display.pixels.size());
    const auto status = saveRenderedDNG(display, file);
    if (status == ErrorCode::OutOfMemory) {
        throw std::bad_alloc();
    }
    if (status != ErrorCode::Success) {
        fail(kHdrReasonOutputIo, kHdrFieldExport, "Cannot write SDR DNG", RenderStatus::OutputIoError);
    }
}

} // namespace

void validateHeadroomIdentity(float value, uint32_t kind, uint32_t field) {
    if (!std::isfinite(value) || kind > kHdrHeadroomMeasured || (kind == 0 ? value != 0.0f : value < 1.0f)) {
        fail(kHdrReasonInvalidBuffer, field, "Invalid HDR headroom identity");
    }
}

void validateBufferDescriptor(const BufferViewDescriptor& b, bool isHDR) {
    const uint32_t field = isHDR ? kHdrFieldHdrBuffer : kHdrFieldSdrBuffer;
    validateHeadroomIdentity(b.contentHeadroom, b.headroomKind, field);
    const bool linear = b.isLinearFloat;
    const bool srgb8 = !isHDR && b.isDisplaySrgb8;
    const uint64_t row = uint64_t(b.width) * (linear ? 12 : 3);
    if ((!linear && !srgb8) || !b.data || !b.width || !b.height ||
        uint64_t(b.width) * b.height > 128000000 || b.strideBytes < row ||
        (b.height > 1 && b.strideBytes > (std::numeric_limits<uint64_t>::max() - row) / (b.height - 1))) {
        fail(kHdrReasonInvalidBuffer, field, "Invalid HDR pixels, dimensions, format or stride");
    }
    const uint64_t required = uint64_t(b.height - 1) * b.strideBytes + row;
    if (required > b.sizeBytes || b.sizeBytes > std::numeric_limits<size_t>::max() ||
        required > std::numeric_limits<uintptr_t>::max() - reinterpret_cast<uintptr_t>(b.data)) {
        fail(kHdrReasonInvalidBuffer, field, "HDR buffer size overflows or is truncated");
    }
    if (linear) {
        const auto* data = static_cast<const uint8_t*>(b.data);
        std::atomic<bool> nonfinite{false};
        parallelRowRanges(int(b.height), int(b.width), [&](int firstRow, int lastRow) {
            for (int y = firstRow; y < lastRow; ++y) {
                if (nonfinite.load(std::memory_order_relaxed)) return;
                const uint8_t* rowPtr = data + uint64_t(y) * b.strideBytes;
                for (uint32_t x = 0; x < b.width; ++x) {
                    float values[3];
                    std::memcpy(values, rowPtr + x * 12, 12);
                    if (!std::isfinite(values[0]) || !std::isfinite(values[1]) || !std::isfinite(values[2])) {
                        nonfinite.store(true, std::memory_order_relaxed);
                        return;
                    }
                }
            }
        });
        if (nonfinite.load(std::memory_order_relaxed)) {
            fail(kHdrReasonNonfinite, field, "Nonfinite HDR input");
        }
    }
}

ImageData readPixelBuffer(const BufferViewDescriptor& buffer) {
    ImageData result(int(buffer.width), int(buffer.height));
    const auto* bytes = static_cast<const uint8_t*>(buffer.data);
    parallelRowRanges(int(buffer.height), int(buffer.width), [&](int firstRow, int lastRow) {
        for (int y = firstRow; y < lastRow; ++y) {
            const uint8_t* rowSrc = bytes + uint64_t(y) * buffer.strideBytes;
            RGB* rowDst = result.pixels.data() + size_t(y) * buffer.width;
            if (buffer.isLinearFloat) {
                std::memcpy(rowDst, rowSrc, size_t(buffer.width) * 12);
            } else {
                for (uint32_t x = 0; x < buffer.width; ++x) {
                    const auto* c = rowSrc + x * 3;
                    rowDst[x] = {decodeSRGB(c[0]), decodeSRGB(c[1]), decodeSRGB(c[2])};
                }
            }
        }
    });
    return result;
}

void validateDecodeSize(uint32_t intent, uint32_t longEdge, bool requirePositivePreviewEdge) {
    const bool preview = intent == kHdrIntentPreview;
    if (intent > 1 || longEdge > 65535 || (preview ? (requirePositivePreviewEdge && !longEdge) : longEdge != 0)) {
        fail(kHdrReasonInvalidArgument, kHdrFieldRequest,
             requirePositivePreviewEdge ? "Invalid camera RAW HDR decode size" : "FINAL decode cannot use a proxy size");
    }
}

void validatePairInputs(const BufferViewDescriptor& hdrBuffer, const BufferViewDescriptor& sdrBuffer,
                        const PairIdentitySpec& identity) {
    validateBufferDescriptor(hdrBuffer, true);
    validateBufferDescriptor(sdrBuffer, false);
    validateHeadroomIdentity(identity.sourceHeadroom, identity.sourceHeadroomKind, kHdrFieldSource);
    if (hdrBuffer.width != sdrBuffer.width || hdrBuffer.height != sdrBuffer.height ||
        identity.orientationApplied != 1 || !identity.nativeWidth || !identity.nativeHeight ||
        uint64_t(identity.nativeWidth) * identity.nativeHeight > 128000000 ||
        identity.sourceIntent > 1 || identity.renderIntent > 1 || identity.isProxy > 1) {
        fail(kHdrReasonInvalidBuffer, kHdrFieldSource, "Invalid HDR pair identity or canvases");
    }
}

bool sameBufferSnapshot(const BufferViewDescriptor& a, const BufferViewDescriptor& b) {
    return a.version == b.version && a.structSize == b.structSize && a.data == b.data &&
        a.sizeBytes == b.sizeBytes && a.width == b.width && a.height == b.height &&
        a.strideBytes == b.strideBytes && a.pixelFormat == b.pixelFormat &&
        a.colorEncoding == b.colorEncoding && a.contentHeadroom == b.contentHeadroom &&
        a.headroomKind == b.headroomKind;
}

bool samePairIdentity(const PairIdentitySpec& a, const PairIdentitySpec& b) {
    return a.nativeWidth == b.nativeWidth && a.nativeHeight == b.nativeHeight &&
        a.outputNativeWidth == b.outputNativeWidth && a.outputNativeHeight == b.outputNativeHeight &&
        a.orientationApplied == b.orientationApplied && a.sourceIntent == b.sourceIntent &&
        a.renderIntent == b.renderIntent && a.isProxy == b.isProxy &&
        a.decodeRevision == b.decodeRevision && a.sourceHeadroom == b.sourceHeadroom &&
        a.sourceHeadroomKind == b.sourceHeadroomKind;
}

std::shared_ptr<OwnedPairRecord> acquirePairRecord(const PairSnapshot& snapshot) {
    std::shared_ptr<OwnedPairRecord> owned;
    if (snapshot.ownerToken) {
        std::lock_guard<std::mutex> lock(ownersMutex);
        const auto found = owners.find(snapshot.ownerToken);
        if (found == owners.end()) {
            fail(kHdrReasonInvalidBuffer, kHdrFieldSource, "Released HDR owner");
        }
        owned = found->second;
        const auto& exp = owned->published;
        if (!sameBufferSnapshot(exp.hdr, snapshot.hdr) || !sameBufferSnapshot(exp.sdr, snapshot.sdr) ||
            !samePairIdentity(exp.identity, snapshot.identity) ||
            exp.sourceSha256 != snapshot.sourceSha256) {
            fail(kHdrReasonInvalidBuffer, kHdrFieldSource, "Owned HDR pair was modified");
        }
        // 已发布的不可变 owned pair 在构造与渲染时已完成全像素有限性及规格校验，免去重复 288M float 扫描。
        return owned;
    }
    validatePairInputs(snapshot.hdr, snapshot.sdr, snapshot.identity);
    auto record = std::make_shared<OwnedPairRecord>();
    record->pixels.hdr = readPixelBuffer(snapshot.hdr);
    record->pixels.sdr = readPixelBuffer(snapshot.sdr);
    record->pixels.nativeWidth = snapshot.identity.nativeWidth;
    record->pixels.nativeHeight = snapshot.identity.nativeHeight;
    record->pixels.outputNativeWidth = snapshot.identity.outputNativeWidth;
    record->pixels.outputNativeHeight = snapshot.identity.outputNativeHeight;
    record->pixels.sourceQuality = static_cast<HDRQuality>(snapshot.identity.sourceIntent);
    record->pixels.renderQuality = static_cast<HDRQuality>(snapshot.identity.renderIntent);
    record->pixels.isProxy = snapshot.identity.isProxy != 0;
    record->pixels.decodeRevision = snapshot.identity.decodeRevision;
    record->pixels.sourceHeadroom = snapshot.identity.sourceHeadroom;
    record->sourceHeadroomKind = snapshot.identity.sourceHeadroomKind;
    record->meta.sourceSha256 = snapshot.sourceSha256;
    return record;
}

uint64_t registerPairRecord(std::shared_ptr<OwnedPairRecord> record, const PairSnapshot& published) {
    const uint64_t token = nextOwnerToken.fetch_add(1);
    record->published = published;
    record->published.ownerToken = token;
    std::lock_guard<std::mutex> lock(ownersMutex);
    owners.emplace(token, std::move(record));
    return token;
}

void releasePairRecord(uint64_t ownerToken) {
    std::lock_guard<std::mutex> lock(ownersMutex);
    owners.erase(ownerToken);
}

float measureContentHeadroom(const ImageData& image, float measuredContentHeadroom) {
    if (measuredContentHeadroom >= 1.0f) {
        return measuredContentHeadroom;
    }
    float peak = 1.0f;
    std::mutex peakMutex;
    parallelPixelRanges(image.pixels.size(), [&](size_t first, size_t last) {
        float localPeak = 1.0f;
        for (size_t i = first; i < last; ++i) {
            localPeak = std::max(localPeak, cameraLuminance(image.pixels[i]));
        }
        std::lock_guard<std::mutex> lock(peakMutex);
        peak = std::max(peak, localPeak);
    });
    return peak;
}

std::shared_ptr<const HDRLook> loadLookResource(const char* file, std::string_view expected) {
    if (!file || !*file) {
        fail(kHdrReasonLookResource, kHdrFieldLook, "Missing HDR look path");
    }
    try {
        return HDRLook::load(file, expected);
    } catch (const std::invalid_argument& error) {
        fail(kHdrReasonLookResource, kHdrFieldLook, error.what());
    }
}

std::shared_ptr<const HDRLook> loadLookForRequest(const char* lookPath, float lookStrength,
                                                  const char sha256[65], std::string* outLookPath) {
    if (lookPath) {
        if (!isLowerHex64(sha256)) {
            fail(kHdrReasonLookResource, kHdrFieldLook, "Invalid HDR look fingerprint");
        }
        auto look = loadLookResource(lookPath, {sha256, 64});
        if (outLookPath) {
            *outLookPath = lookPath;
        }
        return look;
    }
    if (lookStrength != 0.0f || !std::all_of(sha256, sha256 + 65, [](char c) { return c == '\0'; })) {
        fail(kHdrReasonLookResource, kHdrFieldLook, "Missing HDR look resource");
    }
    return nullptr;
}

CameraProfileResource loadCameraProfileResource(const char* file, std::string_view expected) {
    if (!file || !*file) {
        fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment, "Missing HDR camera profile");
    }
    const auto profilePath = std::filesystem::u8path(file);
    std::error_code error;
    if (!std::filesystem::is_regular_file(profilePath, error)) {
        fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment, "HDR camera profile is unavailable");
    }
    std::ifstream stream(profilePath, std::ios::binary | std::ios::ate);
    const auto length = stream.tellg();
    if (length <= 0 || length > std::streamoff(maxDcpSourceBytes)) {
        fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment, "Invalid HDR camera profile size");
    }
    admitMemory(static_cast<uint64_t>(length));
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    stream.seekg(0);
    checkProcessingCancellation();
    if (!stream.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())) ||
        stream.peek() != std::char_traits<char>::eof() || stream.bad()) {
        fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment, "HDR camera profile changed during reading");
    }
    auto digest = hash::sha256Bytes(bytes.data(), bytes.size());
    static ParsedResourceCache<CameraProfileResource> cache;
    if (!expected.empty() && expected != digest) {
        cache.evict(file);
        fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment, "HDR camera profile fingerprint changed");
    }
    checkProcessingCancellation();
    if (auto cached = cache.find(file, digest)) {
        return *cached;
    }
    auto profile = readHDRCameraProfile(bytes.data(), bytes.size());
    checkProcessingCancellation();
    if (!profile) {
        fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment,
             "Unsupported HDR camera calibration", RenderStatus::Unsupported);
    }
    return cache.put(file, digest, {std::move(*profile), digest});
}

CameraRawStamp stampCameraRawFile(const std::filesystem::path& file) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(file, error)) {
        cameraRawStatus(ErrorCode::FileNotFound);
    }
    const auto size = std::filesystem::file_size(file, error);
    if (error || !size) {
        cameraRawStatus(ErrorCode::FileNotFound);
    }
    if (size > 512ull * 1024 * 1024) {
        fail(kHdrReasonUnsupportedRaw, kHdrFieldPath, "Camera RAW exceeds the source file limit",
             RenderStatus::Unsupported);
    }
    const auto modified = std::filesystem::last_write_time(file, error);
    if (error) {
        cameraRawStatus(ErrorCode::FileNotFound);
    }
    return {size, modified};
}

CameraRawProbeResult probeCameraRaw(const char* file, ProcessingVersion version) {
    if (!validProcessingVersion(version)) {
        fail(kHdrReasonInvalidArgument, kHdrFieldRequest, "Invalid camera RAW processing version");
    }
    stampCameraRawFile(std::filesystem::u8path(file));
    RAWProcessor processor(usesLegacySonyCrop(version));
    CameraRawProbeResult result;
    uint64_t sensorPixels = 0;
    cameraRawStatus(processor.inspectCameraHDR(file, result.width, result.height, sensorPixels));
    result.supportsNoiseReduction = processor.supportsNoiseReduction();
    return result;
}

CameraRawDecodedPair decodeCameraRaw(const char* file, const CameraRawDevelopmentSpec& spec) {
    RAWProcessOptions raw;
    raw.outputLinear = true;
    raw.applyBaselineExposure = false;
    bool useMetadataExposure = true;
    std::optional<CameraProfileResource> profile;
    if (spec.hasDevelopment) {
        const uint32_t flags = spec.lensFlags;
        const bool temperatureWB = spec.whiteBalance == 1;
        const bool validWB = temperatureWB
            ? spec.temperature >= 2000.0f && spec.temperature <= 50000.0f &&
              spec.tint >= -150.0f && spec.tint <= 150.0f
            : spec.whiteBalance == 0 && spec.temperature == 0.0f && spec.tint == 0.0f;
        raw.lensCorrection.distortion = (flags & 1u) != 0;
        raw.lensCorrection.tca = (flags & 2u) != 0;
        raw.lensCorrection.autoCrop = (flags & 4u) != 0;
        raw.lensCorrection.vignetting = (flags & 8u) != 0;
        if (!validWB || spec.exposureReference > 1 || spec.fbddLevel > 2 || (flags & ~15u) ||
            (!raw.lensCorrection.active() && (flags || spec.lensProfileId))) {
            fail(kHdrReasonInvalidArgument, kHdrFieldCameraDevelopment,
                 "Invalid camera RAW HDR development parameters");
        }
        if (raw.lensCorrection.active()) {
            raw.lensDatabase = spec.getLensDatabase ? spec.getLensDatabase() : nullptr;
            if (!raw.lensDatabase) {
                fail(kHdrReasonCameraDevelopment, kHdrFieldCameraDevelopment,
                     "Camera RAW HDR lens database is unavailable", RenderStatus::Unsupported);
            }
            if (spec.lensProfileId) {
                raw.lensCorrection.profileID = spec.lensProfileId;
            }
        }
        raw.useCameraWhiteBalance = !temperatureWB;
        raw.useTemperatureWhiteBalance = temperatureWB;
        if (temperatureWB) {
            raw.temperature = spec.temperature;
            raw.tint = spec.tint;
        }
        raw.rawNoiseReduction = static_cast<int>(spec.fbddLevel);
        useMetadataExposure = spec.exposureReference == 0;
        if (spec.hasCameraProfile) {
            if (!isLowerHex64(spec.cameraProfileSha256)) {
                fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment,
                     "Invalid HDR camera profile fingerprint");
            }
            profile = loadCameraProfileResource(spec.cameraProfilePath, {spec.cameraProfileSha256, 64});
            raw.hdrCameraProfile = &profile->profile;
        }
    }
    if (spec.useAi && raw.rawNoiseReduction != 0) {
        fail(kHdrReasonCameraAi, kHdrFieldCameraDevelopment, "FBDD and HDR AI cannot be combined");
    }
    raw.halfSize = spec.preview && raw.rawNoiseReduction == 0 && !spec.useAi;

    const auto filePath = std::filesystem::u8path(file);
    const auto before = stampCameraRawFile(filePath);
    const auto aiKey = spec.useAi ? spec.aiKeyForFile(file) : std::string{};

    CameraRawDecodedPair result;
    auto& pair = result.pixels;
    {
        RAWProcessor processor(spec.legacySonyCrop);
        int width = 0;
        int height = 0;
        uint64_t sensorPixels = 0;
        cameraRawStatus(processor.inspectCameraHDR(file, width, height, sensorPixels));
        if (profile && !processor.supportsHDRCameraProfile(profile->profile)) {
            fail(kHdrReasonCameraProfile, kHdrFieldCameraDevelopment,
                 "HDR profile does not match the camera calibration", RenderStatus::Unsupported);
        }
        const uint64_t developedPixels = raw.halfSize
            ? uint64_t((width + 1) / 2) * ((height + 1) / 2)
            : uint64_t(width) * height;
        // The mosaic still unpacks at sensor size. LibRaw's working RGBA16
        // and the float RGB development are smaller in half-size mode.
        // HDR AI also holds the reference development, mosaic and sensor backup.
        const uint64_t xTransSourceCopy = !raw.halfSize && !processor.supportsNoiseReduction()
            ? developedPixels * 8 : 0;
        admitMemory(before.size + sensorPixels * 4 + developedPixels * (spec.useAi ? 42 : 24) + xTransSourceCopy);
        cameraRawStatus(processor.unpackInspectedCameraHDR());
        if (raw.useTemperatureWhiteBalance && !profile) {
            float temperature = 0.0f;
            float tint = 0.0f;
            if (!processor.getAsShotWhiteBalance(temperature, tint)) {
                fail(kHdrReasonCameraDevelopment, kHdrFieldCameraDevelopment,
                     "Camera RAW HDR custom white balance calibration is unavailable", RenderStatus::Unsupported);
            }
        }
        pair.nativeWidth = static_cast<uint32_t>(width);
        pair.nativeHeight = static_cast<uint32_t>(height);
        // Camera RAW HDR v1 anchors reference white at one quarter of the
        // baseline-adjusted scene scale, with two stops above diffuse white.
        raw.exposure = (useMetadataExposure ? processor.getMetadataExposureEV() : 0.0f) + 2.0f;
        if (spec.useAi) {
            RAWBayerSource bayer;
            if (!processor.getBayerMetadata(bayer)) {
                cameraRawStatus(ErrorCode::InvalidFormat);
            }
            const auto replacement = spec.loadAiOverride(aiKey, bayer);
            ImageData reference;
            cameraRawStatus(processor.process(raw, reference));
            raw.bayerOverride = &replacement;
            cameraRawStatus(processor.process(raw, pair.hdr));
            protectCameraAIHighlights(reference, pair.hdr);
        } else {
            cameraRawStatus(processor.process(raw, pair.hdr));
        }
        if (raw.lensCorrection.active()) {
            const auto report = processor.getLensCorrectionReport();
            if ((raw.lensCorrection.distortion && !report.appliedDistortion) ||
                (raw.lensCorrection.tca && !report.appliedTCA) ||
                (raw.lensCorrection.vignetting && !report.appliedVignetting)) {
                fail(kHdrReasonCameraDevelopment, kHdrFieldCameraDevelopment,
                     "Requested camera RAW HDR lens calibration is unavailable", RenderStatus::Unsupported);
            }
        }
    }

    if (spec.preview) {
        const auto longest = std::max(pair.hdr.width, pair.hdr.height);
        if (uint32_t(longest) > spec.longEdge) {
            const double scale = double(spec.longEdge) / longest;
            const auto width = std::max(1l, std::lround(pair.hdr.width * scale));
            const auto height = std::max(1l, std::lround(pair.hdr.height * scale));
            admitMemory(uint64_t(width) * height * sizeof(RGB));
            pair.hdr = resample(pair.hdr, uint32_t(width), uint32_t(height));
        }
    } else if (uint32_t(pair.hdr.width) != pair.nativeWidth || uint32_t(pair.hdr.height) != pair.nativeHeight) {
        cameraRawStatus(ErrorCode::InvalidFormat);
    }

    admitMemory(pair.hdr.pixels.size() * sizeof(RGB));
    pair.sdr = ImageData(pair.hdr.width, pair.hdr.height);
    std::atomic<bool> nonfinite{false};
    float fusedHeadroom = 1.0f;
    std::mutex headroomMutex;
    parallelPixelRanges(pair.hdr.pixels.size(), [&](size_t first, size_t last) {
        float localHeadroom = 1.0f;
        for (size_t i = first; i < last; ++i) {
            const auto& pixel = pair.hdr.pixels[i];
            if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b)) {
                nonfinite.store(true, std::memory_order_relaxed);
                return;
            }
            if (!spec.preview) {
                localHeadroom = std::max(localHeadroom, cameraLuminance(pixel));
            }
            pair.sdr.pixels[i] = cameraSDR(pixel);
        }
        if (!spec.preview) {
            std::lock_guard<std::mutex> lock(headroomMutex);
            fusedHeadroom = std::max(fusedHeadroom, localHeadroom);
        }
    });
    if (nonfinite.load(std::memory_order_relaxed)) {
        fail(kHdrReasonNonfinite, kHdrFieldSource, "Nonfinite camera RAW pixel", RenderStatus::ProcessingError);
    }
    if (!spec.preview) {
        pair.sourceHeadroom = fusedHeadroom;
        result.sourceHeadroomKind = kHdrHeadroomMeasured;
    }

    const auto after = stampCameraRawFile(filePath);
    if (before.size != after.size || before.modified != after.modified ||
        (spec.useAi && aiKey != spec.aiKeyForFile(file))) {
        fail(kHdrReasonSourceChanged, kHdrFieldSource, "Camera RAW source changed during decode");
    }
    checkProcessingCancellation();
    pair.sourceQuality = pair.renderQuality = spec.preview ? HDRQuality::Preview : HDRQuality::Final;
    pair.isProxy = spec.preview;
    pair.decodeRevision = nextCameraRevision.fetch_add(1);
    result.usedCameraProfile = profile.has_value();
    return result;
}

float estimateAutoExposureEV(const ImageData& hdrImage, float temperature, float tint) {
    HDRRenderOptions options;
    options.temperature = temperature;
    options.tint = tint;
    validateHDRRenderOptions(options);
    const RGB gain = hdrRelativeWhiteBalance(temperature, tint);
    float ev = 0.0f;
    if (!estimateAutoExposure(hdrImage, ColorSpace::sRGB, gain, ev, true)) {
        fail(kHdrReasonInvalidArgument, kHdrFieldSource,
             "HDR metering requires measurable light", RenderStatus::Unsupported);
    }
    return std::abs(ev) < 1e-6f ? 0.0f : ev;
}

std::pair<uint32_t, uint32_t> computeGeometryOutputSize(uint32_t nativeWidth, uint32_t nativeHeight,
                                                        const GeometryOptions& geometry) {
    const auto size = geometryOutputSize(int(nativeWidth), int(nativeHeight), geometry);
    if (size.first <= 0 || size.second <= 0) {
        fail(kHdrReasonInvalidArgument, kHdrFieldRequest, "Invalid HDR geometry");
    }
    return {uint32_t(size.first), uint32_t(size.second)};
}

void requireCompleteFinalSource(const HDRImagePair& source, const char* message) {
    requireFinalSource(source);
    if (source.hdr.width != int(source.nativeWidth) || source.hdr.height != int(source.nativeHeight)) {
        fail(kHdrReasonPreviewSource, kHdrFieldSource, message);
    }
}

HDRImagePair renderPair(HDRImagePair& source, bool ownedSource, const HDRRenderOptions& options) {
    if (options.intent == HDRQuality::Final) {
        requireCompleteFinalSource(source, "FINAL render requires the complete decoded source canvas");
    }
    const uint64_t pixels = uint64_t(source.hdr.width) * source.hdr.height;
    uint64_t extra = 0;
    if (options.hasDetail()) {
        const auto native = geometryOutputSize(source.hdr.width, source.hdr.height, options.geometry);
        const auto size = hdrResizeSize(native.first, native.second, options.longEdge);
        const auto halo = options.detail.halo(size.first, size.second);
        extra = uint64_t(size.first) * size.second * sizeof(RGB) +
            uint64_t(size.first) * std::min(size.second, hdrDetailBandHeight + 2 * halo) * sizeof(float);
    }
    admitMemory(pixels * (ownedSource ? 48 : 24) + extra);
    return ownedSource ? renderHDRPair(source, options) : renderHDRPair(std::move(source), options);
}

ImageData createHslProbeImage(HDRImagePair& source, bool ownedSource, const HDRRenderOptions& options) {
    if (options.intent == HDRQuality::Final) {
        requireCompleteFinalSource(source, "FINAL probe requires the complete decoded source canvas");
    }
    admitMemory(uint64_t(source.hdr.width) * source.hdr.height * (ownedSource ? 12 : 24));
    auto image = ownedSource ? source.hdr : std::move(source.hdr);
    auto probe = renderHDRHslProbe(std::move(image), options);
    checkProcessingCancellation();
    return probe;
}

void prepareHEIFExport(const HDRExportConfig& config,
                       const BufferViewDescriptor* borrowedHdr,
                       const BufferViewDescriptor* borrowedSdr) {
    if (!heifExportAvailable()) {
        fail(kHdrReasonUnsupportedProtocol, kHdrFieldExport,
             "HDR HEIF encoding is unavailable", RenderStatus::Unsupported);
    }
    if (config.metadataPolicy != kHdrMetadataIso || config.jpegQuality > 100 ||
        (config.baseColor != kHdrColorSrgb && config.baseColor != kHdrColorDisplayP3)) {
        fail(kHdrReasonInvalidArgument, kHdrFieldExport, "Invalid HDR HEIF export configuration");
    }
    if (borrowedHdr && borrowedSdr) {
        validateBufferDescriptor(*borrowedHdr, true);
        validateBufferDescriptor(*borrowedSdr, false);
        const uint64_t hdrPixels = uint64_t(borrowedHdr->width) * borrowedHdr->height;
        const uint64_t sdrPixels = uint64_t(borrowedSdr->width) * borrowedSdr->height;
        admitMemory((hdrPixels + sdrPixels) * sizeof(RGB) + hdrPixels * 64);
    }
}

void ensureDifferentFile(const std::string& sourcePath, const char* target) {
    if (sourcePath.empty()) {
        return;
    }
    std::error_code aError;
    std::error_code bError;
    std::error_code equivalentError;
    const auto a = std::filesystem::weakly_canonical(std::filesystem::u8path(sourcePath), aError);
    const auto b = std::filesystem::weakly_canonical(std::filesystem::u8path(target), bError);
    if ((!aError && !bError && a == b) || std::filesystem::equivalent(a, b, equivalentError)) {
        fail(kHdrReasonSameFile, kHdrFieldPath, "HDR export cannot replace its source");
    }
}

void exportImagePairJPEG(const HDRImagePair& pixels, const ExportSourceMetadata& meta,
                         const HDRExportConfig& config, const char* targetFile) {
    requireFinalSource(pixels);
    ensureExportTargetsSafe(meta, targetFile);
    validateMetadataSourceMatch(meta, config.metadataSourcePath, config.sourceSha256);
    admitMemory(uint64_t(pixels.hdr.width) * pixels.hdr.height * 64);
    reportHdrProgress(50, 1000);
    {
        HdrProgressSubrangeScope sub(50, 950);
        exportJPEG(pixels, config, targetFile);
    }
    reportHdrProgress(1000, 1000);
}

void exportImagePairHEIF(const HDRImagePair& pixels, const ExportSourceMetadata& meta,
                         const HDRExportConfig& config, const char* targetFile, bool preAdmitted) {
    requireFinalSource(pixels);
    ensureExportTargetsSafe(meta, targetFile);
    validateMetadataSourceMatch(meta, config.metadataSourcePath, config.sourceSha256);
    if (!preAdmitted) {
        admitMemory(uint64_t(pixels.hdr.width) * pixels.hdr.height * 64);
    }
    reportHdrProgress(50, 1000);
    {
        HdrProgressSubrangeScope sub(50, 950);
        exportHEIF(pixels, config, targetFile);
    }
    reportHdrProgress(1000, 1000);
}

void exportImagePairSDR(const HDRImagePair& pixels, const ExportSourceMetadata& meta,
                        const HDRSdrExportConfig& config, const char* targetFile) {
    requireFinalSource(pixels);
    ensureExportTargetsSafe(meta, targetFile);
    validateMetadataSourceMatch(meta, config.metadataSourcePath, config.sourceSha256);
    admitMemory(uint64_t(pixels.sdr.width) * pixels.sdr.height * 24);
    reportHdrProgress(50, 1000);
    if (config.outputFormat == kHdrSdrOutputDng) {
        exportSDRDNG(pixels, config.quality, config.metadataSourcePath, config.sourceSha256, targetFile);
    } else {
        HdrProgressSubrangeScope sub(50, 950);
        exportSDR(pixels, config, targetFile);
    }
    reportHdrProgress(1000, 1000);
}

ProRAWStreamExportResult exportProRAWStream(const char* sourceFile, const HDRRenderOptions& options,
                                            const std::string& lookPath, const HDRExportConfig& config,
                                            bool keepHDR, const char* temporaryRoot, const char* targetFile) {
    if (options.intent != HDRQuality::Final || config.metadataPolicy != kHdrMetadataIsoXmp) {
        fail(kHdrReasonInvalidArgument, kHdrFieldExport, "Invalid ProRAW export configuration");
    }
    if (std::filesystem::weakly_canonical(std::filesystem::u8path(sourceFile)) !=
        std::filesystem::weakly_canonical(std::filesystem::u8path(config.metadataSourcePath))) {
        fail(kHdrReasonSourceChanged, kHdrFieldSource, "ProRAW export requires a frozen source");
    }
    ensureDifferentFile(std::string(sourceFile), targetFile);
    ensureDifferentFile(lookPath, targetFile);
    checkProcessingCancellation();
    const bool internalDigest = std::all_of(config.sourceSha256, config.sourceSha256 + 32,
                                            [](uint8_t value) { return value == 0; });
    const auto info = probeProRAW(sourceFile);
    StreamSourcePin pin;
    reportHdrProgress(20, 1000);
    validateStreamSource(config, info.width, info.height, targetFile, pin);
    const uint8_t* frozen = internalDigest ? pin.digest : config.sourceSha256;
    const auto streamBytes = streamScratchBytes(info.width, info.height, options, keepHDR);
    storage::requireSpace(std::filesystem::u8path(temporaryRoot),
                          proRAWStageBytes(uint64_t(info.width) * info.height) + streamBytes);
    reportHdrProgress(50, 1000);
    HDRRowSource source;
    {
        HdrProgressSubrangeScope sub(50, 350);
        source = openProRAW(sourceFile, std::filesystem::u8path(temporaryRoot), frozen);
    }
    HDRStreamResult encoded;
    {
        HdrProgressSubrangeScope sub(350, 950);
        auto makeTransform = [&](uint32_t w, uint32_t h) {
            return keepHDR ? makeStreamBaseTransform(config, w, h, targetFile, pin) : JPEGTransformBase{};
        };
        encoded = encodeStream(source, options, keepHDR, config.jpegQuality ? config.jpegQuality : 95,
                               config.baseColor, std::filesystem::u8path(temporaryRoot), makeTransform);
    }
    reportHdrProgress(950, 1000);
    publishStreamJPEG(std::move(encoded.jpeg), encoded.width, encoded.height, config, keepHDR, targetFile, pin, keepHDR);
    reportHdrProgress(1000, 1000);
    return {std::move(encoded), info.width, info.height};
}

HDRStreamResult exportRowStream(const StreamSourceSpec& source, const HDRRenderOptions& options,
                                const std::string& lookPath, const HDRExportConfig& config,
                                bool keepHDR, const char* temporaryRoot, const char* targetFile) {
    ensureDifferentFile(lookPath, targetFile);
    if (source.sourceIntent != kHdrIntentFinal || source.orientationApplied != 1 ||
        options.intent != HDRQuality::Final) {
        fail(kHdrReasonPreviewSource, kHdrFieldSource, "Stream export requires a complete oriented FINAL source");
    }
    if (!source.nativeWidth || !source.nativeHeight ||
        uint64_t(source.nativeWidth) * source.nativeHeight > 128000000 ||
        !source.decodeRevision || !source.decoderIdentifier || !*source.decoderIdentifier ||
        !source.rows.read || !source.rows.finish || config.metadataPolicy != kHdrMetadataIsoXmp) {
        fail(kHdrReasonInvalidArgument, kHdrFieldSource, "Incomplete stream source or export configuration");
    }
    if (std::memcmp(source.sourceSha256.data(), config.sourceSha256, 32) != 0 ||
        std::all_of(source.sourceSha256.begin(), source.sourceSha256.end(), [](uint8_t value) { return value == 0; })) {
        fail(kHdrReasonSourceChanged, kHdrFieldSource, "Stream source digest does not match the frozen file");
    }
    ensureDifferentFile(std::string(config.metadataSourcePath), targetFile);
    checkProcessingCancellation();
    StreamSourcePin pin;
    reportHdrProgress(20, 1000);
    validateStreamSource(config, source.nativeWidth, source.nativeHeight, targetFile, pin);
    reportHdrProgress(50, 1000);
    HDRStreamResult encoded;
    {
        HdrProgressSubrangeScope sub(50, 950);
        auto makeTransform = [&](uint32_t w, uint32_t h) {
            return keepHDR ? makeStreamBaseTransform(config, w, h, targetFile, pin) : JPEGTransformBase{};
        };
        encoded = encodeStream(source.rows, options, keepHDR, config.jpegQuality ? config.jpegQuality : 95,
                               config.baseColor, std::filesystem::u8path(temporaryRoot), makeTransform);
    }
    reportHdrProgress(950, 1000);
    publishStreamJPEG(std::move(encoded.jpeg), encoded.width, encoded.height, config, keepHDR, targetFile, pin, keepHDR);
    reportHdrProgress(1000, 1000);
    return encoded;
}

#if defined(__APPLE__)
TiledExportOutput exportTiledStream(const TiledSourceInput& input, const char* sourceFile,
                                    const HDRRenderOptions& options, const std::string& lookPath,
                                    const HDRExportConfig& config, bool encodeHeif,
                                    const char* temporaryRoot, const char* targetFile) {
    if (options.intent != HDRQuality::Final) {
        fail(kHdrReasonPreviewSource, kHdrFieldRequest, "Tiled export requires FINAL processing");
    }
    if (config.metadataPolicy != kHdrMetadataIso || config.jpegQuality > 100 ||
        (config.baseColor != kHdrColorSrgb && config.baseColor != kHdrColorDisplayP3)) {
        fail(kHdrReasonInvalidArgument, kHdrFieldExport, "Invalid tiled export configuration");
    }
    if (encodeHeif && !heifExportAvailable()) {
        fail(kHdrReasonUnsupportedProtocol, kHdrFieldExport,
             "HDR HEIF encoding is unavailable", RenderStatus::Unsupported);
    }
    ensureDifferentFile(std::string(sourceFile), targetFile);
    ensureDifferentFile(lookPath, targetFile);
    checkProcessingCancellation();

    StreamSourcePin pin;
    HDRRowSource rows;
    uint64_t decodeRevision = 0;
    if (input.ownedCameraPixels) {
        const auto& pixels = *input.ownedCameraPixels;
        const auto& meta = *input.ownedCameraMeta;
        if (config.metadataSourcePath) {
            fail(kHdrReasonInvalidArgument, kHdrFieldSource,
                 "Tiled RAW export requires an owned camera source without copied metadata");
        }
        requireFinalSource(pixels);
        if (pixels.hdr.width != int(pixels.nativeWidth) || pixels.hdr.height != int(pixels.nativeHeight)) {
            fail(kHdrReasonPreviewSource, kHdrFieldSource, "Tiled export requires the complete decoded source canvas");
        }
        if (meta.sourcePath.empty() ||
            !std::all_of(meta.sourceSha256.begin(), meta.sourceSha256.end(), [](uint8_t value) { return value == 0; }) ||
            std::filesystem::weakly_canonical(std::filesystem::u8path(sourceFile)) !=
                std::filesystem::weakly_canonical(std::filesystem::u8path(meta.sourcePath))) {
            fail(kHdrReasonSourceChanged, kHdrFieldSource, "Tiled camera source does not match its original file");
        }
        ensureExportTargetsSafe(meta, targetFile);
        freezeStreamSourceFile(sourceFile, pin);
        rows.width = pixels.nativeWidth;
        rows.height = pixels.nativeHeight;
        rows.read = [&pixels](bool isHdr, uint32_t first, uint32_t count, RGB* output) {
            const auto& plane = isHdr ? pixels.hdr : pixels.sdr;
            if (!output || !count || first > uint32_t(plane.height) || count > uint32_t(plane.height) - first) {
                throw std::invalid_argument("Invalid decoded camera row range");
            }
            std::copy_n(plane.pixels.data() + size_t(first) * plane.width, size_t(count) * plane.width, output);
        };
        rows.finish = [&pin] { verifyStreamSource(pin); };
        decodeRevision = pixels.decodeRevision;
    } else {
        if (!config.metadataSourcePath || !*config.metadataSourcePath) {
            fail(kHdrReasonInvalidArgument, kHdrFieldPath, "Missing HDR file path");
        }
        if (std::filesystem::weakly_canonical(std::filesystem::u8path(sourceFile)) !=
                std::filesystem::weakly_canonical(std::filesystem::u8path(config.metadataSourcePath)) ||
            std::all_of(config.sourceSha256, config.sourceSha256 + 32, [](uint8_t value) { return value == 0; })) {
            fail(kHdrReasonSourceChanged, kHdrFieldSource, "Tiled raster export requires its frozen original");
        }
        if (input.stream) {
            const auto& stream = *input.stream;
            if (stream.sourceIntent != kHdrIntentFinal || stream.orientationApplied != 1) {
                fail(kHdrReasonPreviewSource, kHdrFieldSource, "Tiled export requires complete oriented FINAL rows");
            }
            if (!stream.nativeWidth || !stream.nativeHeight || !stream.decodeRevision ||
                !stream.decoderIdentifier || !*stream.decoderIdentifier ||
                !stream.rows.read || !stream.rows.finish) {
                fail(kHdrReasonInvalidArgument, kHdrFieldSource, "Incomplete tiled row source");
            }
            if (std::memcmp(stream.sourceSha256.data(), config.sourceSha256, 32) != 0) {
                fail(kHdrReasonSourceChanged, kHdrFieldSource, "Tiled row source digest differs from the frozen file");
            }
            validateStreamSource(config, stream.nativeWidth, stream.nativeHeight, targetFile, pin);
            rows = stream.rows;
            decodeRevision = stream.decodeRevision;
        } else {
            rows = openRasterRows(sourceFile, config.sourceSha256, pin, decodeRevision);
        }
    }

    HDRStreamFiles rendered;
    reportHdrProgress(50, 1000);
    {
        HdrProgressSubrangeScope sub(50, 750);
        rendered = renderStreamFiles(rows, options, encodeHeif, std::filesystem::u8path(temporaryRoot));
    }
    reportHdrProgress(750, 1000);
    if (encodeHeif) {
        publishTiledHEIF(rendered, config, targetFile, pin);
    } else {
        storage::File pixels(rendered.sdr);
        std::vector<RGB> row(rendered.result.width);
        const uint32_t dngHeight = rendered.result.height;
        RenderedDNGRows image{rendered.result.width, dngHeight, [&](uint32_t y) {
            pixels.read(uint64_t(y) * row.size() * sizeof(RGB), row.data(), row.size() * sizeof(RGB));
            for (auto& px : row) {
                px.r = linearToSrgbUnit(px.r);
                px.g = linearToSrgbUnit(px.g);
                px.b = linearToSrgbUnit(px.b);
            }
            if ((y & 63u) == 0 || y + 1 == dngHeight) {
                reportHdrProgress(750 + uint32_t((uint64_t(y + 1) * 240) / std::max(1u, dngHeight)), 1000);
            }
            return row.data();
        }};
        const auto status = saveRenderedDNGRows(image, targetFile, [&] {
            verifyStreamSource(pin);
            ensureDifferentFile(std::string(sourceFile), targetFile);
            checkProcessingCancellation();
        });
        if (status == ErrorCode::OutOfMemory) {
            throw std::bad_alloc();
        }
        if (status != ErrorCode::Success) {
            fail(kHdrReasonOutputIo, kHdrFieldExport, "Cannot write tiled SDR DNG", RenderStatus::OutputIoError);
        }
    }
    reportHdrProgress(1000, 1000);
    return {std::move(rendered.result), rows.width, rows.height, decodeRevision};
}
#endif

} // namespace sony2fuji::hdr
