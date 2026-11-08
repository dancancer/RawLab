#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "ffi/hdr_session.h"
#include "platform/hdr_image.h"
#include "core/rendered_dng.h"
#include "core/hdr_resample.h"
#include "core/parallel_pixels.h"
#include "core/photo_color.h"
#include "core/photo_rendering.h"
#include "core/sha256.h"
#include "core/hdr_stream.h"
#include "core/hdr_storage.h"
#include "core/hdr_look.h"
#include "core/proraw_source.h"
#include "sony2fuji/dcp_compiler.h"
#include "sony2fuji/raw_processor.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <utility>

namespace {
using namespace sony2fuji;
using sony2fuji::hdr::Error;

struct Owner {
    HDRImagePair pixels;
    std::array<uint8_t, 32> sha{};
    uint32_t sourceHeadroomKind = SONY2FUJI_HDR_HEADROOM_UNKNOWN;
    sony2fuji_hdr_image_pair_v1 published{};
    std::string sourcePath;
    std::string lookPath;
    std::string cameraProfilePath;
};
std::mutex ownersMutex;
std::unordered_map<uint64_t, std::shared_ptr<Owner>> owners;
std::atomic<uint64_t> nextToken{1};
std::atomic<uint64_t> nextCameraRevision{1};

[[noreturn]] void fail(uint32_t reason, uint32_t field, const char* message,
    sony2fuji_status status = SONY2FUJI_STATUS_INVALID_ARGUMENT) {
    throw Error(status, reason, field, message);
}

template<class T> T initialized() { T value{}; value.version = 1; value.struct_size = sizeof(T); return value; }
template<class T> void header(const T* value, uint32_t field) {
    if (!value) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, field, "Missing HDR structure");
    if (value->version != 1) fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION, field, "Unsupported HDR structure version",
        SONY2FUJI_STATUS_UNSUPPORTED);
    if (value->struct_size < sizeof(T)) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, field, "Truncated HDR structure");
}
template<class T> void clearOutput(T* value) {
    const uint32_t size = value->struct_size;
    *value = initialized<T>(); value->struct_size = size;
}
void prepareOutput(sony2fuji_hdr_image_pair_v1* value) {
    header(value, SONY2FUJI_HDR_FIELD_RESULT);
    if (value->owner_token || value->hdr.data || value->sdr.data)
        fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "Release the previous HDR result first");
    clearOutput(value);
}

template<class Function> sony2fuji_status boundary(sony2fuji_hdr_diagnostic_v1* diagnostic, Function function) noexcept {
    if (diagnostic && (diagnostic->version != 1 || diagnostic->struct_size < sizeof(*diagnostic)))
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    auto report = [&](uint32_t reason, uint32_t field) {
        if (diagnostic) { diagnostic->reason = reason; diagnostic->field = field; }
    };
    try { function(); report(0, 0); return SONY2FUJI_STATUS_OK; }
    catch (const ProcessingCancelled&) {
        report(0, 0); return SONY2FUJI_STATUS_CANCELLED;
    }
    catch (const Error& error) { report(error.reason, error.field); return error.status; }
    catch (const std::bad_alloc&) {
        report(SONY2FUJI_HDR_REASON_OUT_OF_MEMORY, SONY2FUJI_HDR_FIELD_RESULT); return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (const std::invalid_argument&) {
        report(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST); return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    } catch (...) {
        report(SONY2FUJI_HDR_REASON_NONFINITE, SONY2FUJI_HDR_FIELD_RESULT); return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

void headroom(float value, uint32_t kind, uint32_t field) {
    if (!std::isfinite(value) || kind > SONY2FUJI_HDR_HEADROOM_MEASURED ||
        (kind == 0 ? value != 0 : value < 1))
        fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, field, "Invalid HDR headroom identity");
}
void buffer(const sony2fuji_hdr_buffer_v1& b, bool isHDR) {
    const uint32_t field = isHDR ? SONY2FUJI_HDR_FIELD_HDR_BUFFER : SONY2FUJI_HDR_FIELD_SDR_BUFFER;
    header(&b, field); headroom(b.content_headroom, b.headroom_kind, field);
    const bool linear = b.pixel_format == SONY2FUJI_HDR_RGB32F_LINEAR && b.color_encoding == SONY2FUJI_HDR_LINEAR_SRGB;
    const bool srgb8 = !isHDR && b.pixel_format == SONY2FUJI_HDR_RGB8_SRGB && b.color_encoding == SONY2FUJI_HDR_DISPLAY_SRGB;
    const uint64_t row = uint64_t(b.width) * (linear ? 12 : 3);
    if ((!linear && !srgb8) || !b.data || !b.width || !b.height ||
        uint64_t(b.width) * b.height > 128000000 || b.stride_bytes < row ||
        (b.height > 1 && b.stride_bytes > (UINT64_MAX - row) / (b.height - 1)))
        fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, field, "Invalid HDR pixels, dimensions, format or stride");
    const uint64_t required = uint64_t(b.height - 1) * b.stride_bytes + row;
    if (required > b.size_bytes || b.size_bytes > SIZE_MAX ||
        required > UINTPTR_MAX - reinterpret_cast<uintptr_t>(b.data))
        fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, field, "HDR buffer size overflows or is truncated");
    if (linear) {
        const auto* data = static_cast<const uint8_t*>(b.data);
        for (uint32_t y = 0; y < b.height; ++y) for (uint32_t x = 0; x < b.width; ++x) {
            float values[3]; std::memcpy(values, data + y * b.stride_bytes + x * 12, 12);
            for (float value : values) if (!std::isfinite(value))
                fail(SONY2FUJI_HDR_REASON_NONFINITE, field, "Nonfinite HDR input");
        }
    }
}

float decodeSRGB(uint8_t component) {
    const float x = component / 255.0f;
    return x <= .04045f ? x / 12.92f : std::pow((x + .055f) / 1.055f, 2.4f);
}
ImageData readBuffer(const sony2fuji_hdr_buffer_v1& b) {
    ImageData result(int(b.width), int(b.height));
    const auto* data = static_cast<const uint8_t*>(b.data);
    for (uint32_t y = 0; y < b.height; ++y) for (uint32_t x = 0; x < b.width; ++x) {
        auto& p = result.at(x, y);
        if (b.pixel_format == SONY2FUJI_HDR_RGB32F_LINEAR)
            std::memcpy(&p, data + y * b.stride_bytes + x * 12, 12);
        else {
            const auto* c = data + y * b.stride_bytes + x * 3;
            p = {decodeSRGB(c[0]), decodeSRGB(c[1]), decodeSRGB(c[2])};
        }
    }
    return result;
}

std::shared_ptr<Owner> readPair(const sony2fuji_hdr_image_pair_v1* p) {
    header(p, SONY2FUJI_HDR_FIELD_SOURCE);
    std::shared_ptr<Owner> owned;
    if (p->owner_token) {
        std::lock_guard<std::mutex> lock(ownersMutex);
        const auto found = owners.find(p->owner_token);
        if (found == owners.end()) fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_SOURCE, "Released HDR owner");
        owned = found->second;
        const auto& expected = owned->published;
        auto sameBuffer = [](const sony2fuji_hdr_buffer_v1& a, const sony2fuji_hdr_buffer_v1& b) {
            return a.version == b.version && a.struct_size == b.struct_size && a.data == b.data &&
                a.size_bytes == b.size_bytes && a.width == b.width && a.height == b.height &&
                a.stride_bytes == b.stride_bytes && a.pixel_format == b.pixel_format &&
                a.color_encoding == b.color_encoding && a.content_headroom == b.content_headroom && a.headroom_kind == b.headroom_kind;
        };
        // C/Swift 调用方的结构 padding 没有约定，不能 memcmp 整个公开结构。
        if (!sameBuffer(expected.hdr, p->hdr) || !sameBuffer(expected.sdr, p->sdr) ||
            expected.native_width != p->native_width || expected.native_height != p->native_height ||
            expected.output_native_width != p->output_native_width || expected.output_native_height != p->output_native_height ||
            expected.orientation_applied != p->orientation_applied || expected.source_intent != p->source_intent ||
            expected.render_intent != p->render_intent || expected.is_proxy != p->is_proxy ||
            expected.decode_revision != p->decode_revision || expected.source_headroom != p->source_headroom ||
            expected.source_headroom_kind != p->source_headroom_kind ||
            std::memcmp(expected.source_sha256, p->source_sha256, 32) != 0)
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_SOURCE, "Owned HDR pair was modified");
    }
    buffer(p->hdr, true); buffer(p->sdr, false);
    headroom(p->source_headroom, p->source_headroom_kind, SONY2FUJI_HDR_FIELD_SOURCE);
    if (p->hdr.width != p->sdr.width || p->hdr.height != p->sdr.height || p->orientation_applied != 1 ||
        !p->native_width || !p->native_height || uint64_t(p->native_width) * p->native_height > 128000000 ||
        p->source_intent > 1 || p->render_intent > 1 || p->is_proxy > 1)
        fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_SOURCE, "Invalid HDR pair identity or canvases");
    if (owned) return owned;
    auto result = std::make_shared<Owner>();
    result->pixels.hdr = readBuffer(p->hdr); result->pixels.sdr = readBuffer(p->sdr);
    result->pixels.nativeWidth = p->native_width; result->pixels.nativeHeight = p->native_height;
    result->pixels.outputNativeWidth = p->output_native_width; result->pixels.outputNativeHeight = p->output_native_height;
    result->pixels.sourceQuality = static_cast<HDRQuality>(p->source_intent);
    result->pixels.renderQuality = static_cast<HDRQuality>(p->render_intent);
    result->pixels.isProxy = p->is_proxy != 0;
    result->pixels.decodeRevision = p->decode_revision;
    result->pixels.sourceHeadroom = p->source_headroom;
    result->sourceHeadroomKind = p->source_headroom_kind;
    std::copy_n(p->source_sha256, 32, result->sha.begin());
    return result;
}

sony2fuji_hdr_buffer_v1 view(ImageData& image) {
    static_assert(sizeof(RGB) == 12);
    auto result = initialized<sony2fuji_hdr_buffer_v1>();
    result.data = image.pixels.data(); result.width = image.width; result.height = image.height;
    result.stride_bytes = uint64_t(image.width) * 12; result.size_bytes = image.pixels.size() * sizeof(RGB);
    result.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR; result.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
    result.content_headroom = 1; result.headroom_kind = SONY2FUJI_HDR_HEADROOM_MEASURED;
    for (const auto& pixel : image.pixels)
        result.content_headroom = std::max(result.content_headroom, .2126f * pixel.r + .7152f * pixel.g + .0722f * pixel.b);
    return result;
}
void publish(std::shared_ptr<Owner> owner, sony2fuji_hdr_image_pair_v1* result) {
    auto value = initialized<sony2fuji_hdr_image_pair_v1>(); value.struct_size = result->struct_size;
    value.hdr = view(owner->pixels.hdr); value.sdr = view(owner->pixels.sdr);
    value.native_width = owner->pixels.nativeWidth; value.native_height = owner->pixels.nativeHeight;
    value.output_native_width = owner->pixels.outputNativeWidth ? owner->pixels.outputNativeWidth : value.native_width;
    value.output_native_height = owner->pixels.outputNativeHeight ? owner->pixels.outputNativeHeight : value.native_height;
    value.orientation_applied = 1;
    value.source_intent = static_cast<uint32_t>(owner->pixels.sourceQuality);
    value.render_intent = static_cast<uint32_t>(owner->pixels.renderQuality);
    value.is_proxy = owner->pixels.isProxy; value.decode_revision = owner->pixels.decodeRevision;
    value.source_headroom = owner->pixels.sourceHeadroom; value.source_headroom_kind = owner->sourceHeadroomKind;
    std::copy(owner->sha.begin(), owner->sha.end(), value.source_sha256);
    value.owner_token = nextToken.fetch_add(1);
    owner->published = value;
    { std::lock_guard<std::mutex> lock(ownersMutex); owners.emplace(value.owner_token, std::move(owner)); }
    *result = value;
}
void finalSource(const HDRImagePair& image) {
    if (image.isProxy || image.sourceQuality != HDRQuality::Final || image.renderQuality != HDRQuality::Final)
        fail(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE, SONY2FUJI_HDR_FIELD_SOURCE, "FINAL requires a full source and render");
}
void path(const char* value) {
    if (!value || !*value) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_PATH, "Missing HDR file path");
}

size_t requestSize(uint32_t processingVersion) {
    switch (processingVersion) {
        case SONY2FUJI_HDR_PROCESSING_VERSION: return sizeof(sony2fuji_hdr_request_v1);
        case SONY2FUJI_HDR_PROCESSING_TONE_VERSION: return sizeof(sony2fuji_hdr_request_v2);
        case SONY2FUJI_HDR_PROCESSING_COLOR_VERSION: return sizeof(sony2fuji_hdr_request_v3);
        case SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION: return sizeof(sony2fuji_hdr_request_v4);
        case SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION: return sizeof(sony2fuji_hdr_request_v5);
        case SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION: return sizeof(sony2fuji_hdr_request_v6);
        case SONY2FUJI_HDR_PROCESSING_LOOK_VERSION: return sizeof(sony2fuji_hdr_request_v7);
        default: return 0;
    }
}

void validateRequestVersion(const sony2fuji_hdr_request_v1* request) {
    header(request, SONY2FUJI_HDR_FIELD_REQUEST);
    const size_t size = requestSize(request->hdr_processing_version);
    if (size == 0)
        fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION, SONY2FUJI_HDR_FIELD_REQUEST,
            "Unsupported HDR processing version", SONY2FUJI_STATUS_UNSUPPORTED);
    if (request->struct_size < size)
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Truncated HDR processing request");
}

std::shared_ptr<const HDRLook> loadLook(const char* file, std::string_view expected = {}) {
    if (!file || !*file)
        fail(SONY2FUJI_HDR_REASON_LOOK_RESOURCE, SONY2FUJI_HDR_FIELD_LOOK, "Missing HDR look path");
    try { return HDRLook::load(file, expected); }
    catch (const std::invalid_argument& error) {
        fail(SONY2FUJI_HDR_REASON_LOOK_RESOURCE, SONY2FUJI_HDR_FIELD_LOOK, error.what());
    }
}

HDRRenderOptions renderOptions(const sony2fuji_hdr_request_v1* request, sony2fuji_session* session,
    std::string* lookPath = nullptr) {
    validateRequestVersion(request);
    if (request->flip_horizontal > 1 || request->flip_vertical > 1)
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR flip");
    HDRRenderOptions options;
    options.processingVersion = request->hdr_processing_version;
    options.intent = static_cast<HDRQuality>(request->intent); options.longEdge = request->long_edge;
    options.exposureEV = request->exposure_ev; options.temperature = request->temperature; options.tint = request->tint;
    options.contrast = request->contrast; options.highlights = request->highlights; options.shadows = request->shadows;
    options.saturation = request->saturation;
    options.geometry = {request->crop_x, request->crop_y, request->crop_width, request->crop_height,
        request->quarter_turns, request->flip_horizontal != 0, request->flip_vertical != 0,
        request->straighten_degrees, request->perspective_horizontal, request->perspective_vertical};
    if (options.processingVersion >= SONY2FUJI_HDR_PROCESSING_TONE_VERSION) {
        sony2fuji_hdr_request_v2 extended;
        std::memcpy(&extended, request, sizeof(extended));
        if (extended.reserved != 0)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR tone request padding");
        options.tone = {extended.black_point, extended.white_point, extended.curve_strength, extended.curve};
    }
    if (options.processingVersion >= SONY2FUJI_HDR_PROCESSING_COLOR_VERSION) {
        sony2fuji_hdr_request_v3 extended;
        std::memcpy(&extended, request, sizeof(extended));
        if (extended.reserved != 0)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR color request padding");
        header(&extended.hsl, SONY2FUJI_HDR_FIELD_REQUEST);
        header(&extended.grading, SONY2FUJI_HDR_FIELD_REQUEST);
        options.color.vibrance = extended.vibrance;
        std::copy_n(extended.hsl.hue, SONY2FUJI_HSL_CHANNELS, options.color.hsl.hue.begin());
        std::copy_n(extended.hsl.saturation, SONY2FUJI_HSL_CHANNELS, options.color.hsl.saturation.begin());
        std::copy_n(extended.hsl.lightness, SONY2FUJI_HSL_CHANNELS, options.color.hsl.lightness.begin());
        const auto& g = extended.grading;
        options.color.grading.wheels = {{{g.shadows_hue, g.shadows_saturation},
            {g.midtones_hue, g.midtones_saturation}, {g.highlights_hue, g.highlights_saturation}}};
    }
    if (options.processingVersion >= SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION) {
        sony2fuji_hdr_request_v4 extended;
        std::memcpy(&extended, request, sizeof(extended));
        options.rendition = {extended.peak_limit_ev, extended.sdr_exposure_ev, extended.sdr_contrast, extended.sdr_saturation};
    }
    if (options.processingVersion >= SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION) {
        sony2fuji_hdr_request_v5 extended;
        std::memcpy(&extended, request, sizeof(extended));
        const auto& effects = extended.effects;
        header(&effects, SONY2FUJI_HDR_FIELD_REQUEST);
        options.effects = {effects.vignette_amount, effects.vignette_midpoint, effects.vignette_roundness,
            effects.vignette_feather, effects.vignette_highlights, effects.grain_amount, effects.grain_size, effects.grain_roughness};
    }
    if (options.processingVersion >= SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION) {
        sony2fuji_hdr_request_v6 extended;
        std::memcpy(&extended, request, sizeof(extended));
        options.detail = {extended.sharpening, extended.clarity, extended.dehaze, extended.denoise};
    }
    if (options.processingVersion >= SONY2FUJI_HDR_PROCESSING_LOOK_VERSION) {
        sony2fuji_hdr_request_v7 extended;
        std::memcpy(&extended, request, sizeof(extended));
        if (extended.reserved != 0 || !(extended.look_strength >= 0 && extended.look_strength <= 2))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_LOOK, "Invalid HDR look settings");
        const auto* sha = extended.look_sha256;
        if (extended.look_path) {
            if (sha[64] != '\0' || !std::all_of(sha, sha + 64, [](char c) {
                    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                }))
                fail(SONY2FUJI_HDR_REASON_LOOK_RESOURCE, SONY2FUJI_HDR_FIELD_LOOK, "Invalid HDR look fingerprint");
            const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
            options.look = loadLook(extended.look_path, {sha, 64});
            options.lookStrength = extended.look_strength;
            if (lookPath) *lookPath = extended.look_path;
        } else if (extended.look_strength != 0 || !std::all_of(sha, sha + 65, [](char c) { return c == '\0'; })) {
            fail(SONY2FUJI_HDR_REASON_LOOK_RESOURCE, SONY2FUJI_HDR_FIELD_LOOK, "Missing HDR look resource");
        }
    }
    validateHDRRenderOptions(options);
    return options;
}
struct CameraProfileResource {
    HDRCameraProfile profile;
    std::string digest;
};

CameraProfileResource loadCameraProfile(const char* file, std::string_view expected = {}) {
    if (!file || !*file)
        fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "Missing HDR camera profile");
    const auto profilePath = std::filesystem::u8path(file);
    std::error_code error;
    if (!std::filesystem::is_regular_file(profilePath, error))
        fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "HDR camera profile is unavailable");
    std::ifstream stream(profilePath, std::ios::binary | std::ios::ate);
    const auto length = stream.tellg();
    if (length <= 0 || length > std::streamoff(maxDcpSourceBytes))
        fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "Invalid HDR camera profile size");
    hdr::admitMemory(static_cast<uint64_t>(length));
    std::vector<uint8_t> bytes(static_cast<size_t>(length));
    stream.seekg(0);
    checkProcessingCancellation();
    if (!stream.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())) ||
        stream.peek() != std::char_traits<char>::eof() || stream.bad())
        fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "HDR camera profile changed during reading");
    auto digest = hash::sha256Bytes(bytes.data(), bytes.size());
    if (!expected.empty() && expected != digest)
        fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "HDR camera profile fingerprint changed");
    auto profile = readHDRCameraProfile(bytes.data(), bytes.size());
    checkProcessingCancellation();
    if (!profile)
        fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
            "Unsupported HDR camera calibration", SONY2FUJI_STATUS_UNSUPPORTED);
    return {std::move(*profile), std::move(digest)};
}

void cameraRawStatus(ErrorCode code) {
    switch (code) {
        case ErrorCode::Success: return;
        case ErrorCode::OutOfMemory: throw std::bad_alloc();
        case ErrorCode::FileNotFound:
            fail(SONY2FUJI_HDR_REASON_INPUT_IO, SONY2FUJI_HDR_FIELD_PATH,
                "Cannot read camera RAW", SONY2FUJI_STATUS_IO_ERROR);
        case ErrorCode::InvalidFormat:
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW, SONY2FUJI_HDR_FIELD_SOURCE,
                "Unsupported camera RAW for HDR", SONY2FUJI_STATUS_UNSUPPORTED);
        default:
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_SOURCE,
                "Camera RAW development failed", SONY2FUJI_STATUS_PROCESSING_ERROR);
    }
}

struct CameraRawStamp {
    uintmax_t size;
    std::filesystem::file_time_type modified;
};

CameraRawStamp cameraRawStamp(const std::filesystem::path& file) {
    std::error_code error;
    if (!std::filesystem::is_regular_file(file, error)) cameraRawStatus(ErrorCode::FileNotFound);
    const auto size = std::filesystem::file_size(file, error);
    if (error || !size) cameraRawStatus(ErrorCode::FileNotFound);
    if (size > 512ull * 1024 * 1024)
        fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW, SONY2FUJI_HDR_FIELD_PATH, "Camera RAW exceeds the source file limit",
            SONY2FUJI_STATUS_UNSUPPORTED);
    const auto modified = std::filesystem::last_write_time(file, error);
    if (error) cameraRawStatus(ErrorCode::FileNotFound);
    return {size, modified};
}

float cameraLuminance(const RGB& pixel) {
    return .2126f * pixel.r + .7152f * pixel.g + .0722f * pixel.b;
}

void protectCameraAIHighlights(const ImageData& reference, ImageData& denoised) {
    if (denoised.width != reference.width || denoised.height != reference.height)
        cameraRawStatus(ErrorCode::InvalidFormat);
    parallelPixelRanges(reference.pixels.size(), [&](size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            const auto& original = reference.pixels[i];
            auto& pixel = denoised.pixels[i];
            const float peak = std::max({original.r, original.g, original.b});
            if (peak >= 1) {
                pixel = original;
                continue;
            }
            // 白平衡、基准曝光和矩阵转换都可能将像素推过参考白。
            const float t = std::clamp((peak - .5f) * 2.f, 0.f, 1.f);
            float amount = 1.f - t * t * (3.f - 2.f * t);
            const float denoisedPeak = std::max({pixel.r, pixel.g, pixel.b});
            if (denoisedPeak > 1.f) amount = std::min(amount, (1.f - peak) / (denoisedPeak - peak));
            pixel = {original.r + (pixel.r - original.r) * amount,
                     original.g + (pixel.g - original.g) * amount,
                     original.b + (pixel.b - original.b) * amount};
        }
    });
}

RGB cameraSDR(const RGB& pixel) {
    const float y = cameraLuminance(pixel);
    if (y <= 0) return {0, 0, 0};
    const float mapped = neutralDisplayLinear(y);
    const float highest = std::max({pixel.r, pixel.g, pixel.b});
    const float lowest = std::min({pixel.r, pixel.g, pixel.b});
    // Reduce chroma about mapped luminance only as far as sRGB requires.
    float chroma = mapped / y;
    if (highest > y) chroma = std::min(chroma, (1 - mapped) / (highest - y));
    if (lowest < y) chroma = std::min(chroma, mapped / (y - lowest));
    auto component = [&](float value) { return std::clamp(mapped + (value - y) * chroma, 0.0f, 1.0f); };
    return {component(pixel.r), component(pixel.g), component(pixel.b)};
}

bool overlaps(const void* a,uint64_t aSize,const void* b,uint64_t bSize) {
    if (!a || !b || !aSize || !bSize) return false;
    const auto ap=reinterpret_cast<uintptr_t>(a),bp=reinterpret_cast<uintptr_t>(b);
    return ap<=bp ? aSize>bp-ap : bSize>ap-bp;
}
bool requestAliases(const sony2fuji_hdr_request_v1* request, const void* result, size_t size) {
    size_t bytes = sizeof(*request);
    if (request && request->version == SONY2FUJI_HDR_VERSION && request->struct_size >= bytes)
        bytes = std::max(bytes, std::min(size_t(request->struct_size), requestSize(request->hdr_processing_version)));
    return overlaps(request, bytes, result, size);
}
bool sourceAliases(const sony2fuji_hdr_image_pair_v1* source, const void* result, size_t size) {
    if (!source || !result) return false;
    if (overlaps(source,sizeof(*source),result,size)) return true;
    if (source->version!=1 || source->struct_size<sizeof(*source)) return false;
    return overlaps(source->hdr.data,source->hdr.size_bytes,result,size) ||
        overlaps(source->sdr.data,source->sdr.size_bytes,result,size);
}
void differentFile(const std::string& sourcePath,const char* target) {
    if (sourcePath.empty()) return;
    std::error_code aError,bError,equivalentError;
    const auto a=std::filesystem::weakly_canonical(std::filesystem::u8path(sourcePath),aError);
    const auto b=std::filesystem::weakly_canonical(std::filesystem::u8path(target),bError);
    if ((!aError && !bError && a==b) || std::filesystem::equivalent(a,b,equivalentError))
        fail(SONY2FUJI_HDR_REASON_SAME_FILE,SONY2FUJI_HDR_FIELD_PATH,"HDR export cannot replace its source");
}
void differentFile(const Owner& source,const char* target) {
    differentFile(source.sourcePath, target);
    differentFile(source.lookPath, target);
    differentFile(source.cameraProfilePath, target);
}
void metadataSource(const Owner& source,const char* file,const uint8_t sha[32]) {
    if (!file) return;
    path(file);
    if (std::memcmp(source.sha.data(),sha,32)!=0)
        fail(SONY2FUJI_HDR_REASON_SOURCE_CHANGED,SONY2FUJI_HDR_FIELD_EXPORT,
            "Metadata source identity differs from the decoded image");
}

void exportSDRDNG(const Owner& source,const sony2fuji_hdr_sdr_export_config_v1& config,const char* file) {
    if (config.quality>100)
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT,SONY2FUJI_HDR_FIELD_EXPORT,"Invalid SDR quality");
    if (config.metadata_source_path) {
        differentFile(std::string(config.metadata_source_path),file);
        const auto info=hdr::probeFile(config.metadata_source_path);
        if (std::memcmp(info.source_sha256,config.source_sha256,32)!=0)
            fail(SONY2FUJI_HDR_REASON_SOURCE_CHANGED,SONY2FUJI_HDR_FIELD_EXPORT,"HDR metadata source changed");
    }
    // 既有 DNG writer 消费显示编码 sRGB，并自行转成中性的 float32 LinearRaw。
    // 只烘焙 SDR 呈现，不给成片复制来源相机的 RAW 白平衡/校准标签。
    ImageData display=source.pixels.sdr;
    for (auto& pixel:display.pixels) for (float* component:{&pixel.r,&pixel.g,&pixel.b}) {
        const float value=std::clamp(*component,0.0f,1.0f);
        *component=value<=.0031308f ? 12.92f*value : 1.055f*std::pow(value,1/2.4f)-.055f;
    }
    const auto status=saveRenderedDNG(display,file);
    if (status==ErrorCode::OutOfMemory) throw std::bad_alloc();
    if (status!=ErrorCode::Success)
        fail(SONY2FUJI_HDR_REASON_OUTPUT_IO,SONY2FUJI_HDR_FIELD_EXPORT,"Cannot write SDR DNG",SONY2FUJI_STATUS_OUTPUT_IO_ERROR);
}
} // namespace

extern "C" {
sony2fuji_status sony2fuji_hdr_estimate_auto_exposure(const sony2fuji_hdr_image_pair_v1* source,
    float temperature, float tint, float* exposure, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(source, SONY2FUJI_HDR_FIELD_SOURCE);
        if (!exposure || source->hdr.width > 2048 || source->hdr.height > 2048 ||
            overlaps(exposure, sizeof(*exposure), source, sizeof(*source)) ||
            overlaps(exposure, sizeof(*exposure), source->hdr.data, source->hdr.size_bytes) ||
            overlaps(exposure, sizeof(*exposure), source->sdr.data, source->sdr.size_bytes))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR metering input or output");
        HDRRenderOptions options;
        options.temperature = temperature;
        options.tint = tint;
        validateHDRRenderOptions(options);
        if (!source->owner_token)
            hdr::admitMemory(uint64_t(source->hdr.width) * source->hdr.height * 2 * sizeof(RGB));
        const auto input = readPair(source);
        const RGB gain = hdrRelativeWhiteBalance(temperature, tint);
        float ev;
        if (!estimateAutoExposure(input->pixels.hdr, ColorSpace::sRGB, gain, ev, true))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE,
                "HDR metering requires measurable light", SONY2FUJI_STATUS_UNSUPPORTED);
        *exposure = std::abs(ev) < 1e-6f ? 0.f : ev;
    });
}

sony2fuji_status sony2fuji_hdr_geometry_size(uint32_t nativeWidth, uint32_t nativeHeight,
    const sony2fuji_hdr_request_v1* request, uint32_t* width, uint32_t* height,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        validateRequestVersion(request);
        if (!width || !height || width == height || !nativeWidth || !nativeHeight ||
            uint64_t(nativeWidth) * nativeHeight > 128000000 || request->flip_horizontal > 1 ||
            request->flip_vertical > 1)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR geometry dimensions");
        const GeometryOptions geometry{request->crop_x, request->crop_y, request->crop_width, request->crop_height,
            request->quarter_turns, request->flip_horizontal != 0, request->flip_vertical != 0,
            request->straighten_degrees, request->perspective_horizontal, request->perspective_vertical};
        const auto size = geometryOutputSize(int(nativeWidth), int(nativeHeight), geometry);
        if (size.first <= 0 || size.second <= 0)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR geometry");
        *width = uint32_t(size.first); *height = uint32_t(size.second);
    });
}

sony2fuji_status sony2fuji_hdr_render(sony2fuji_session* session, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (sourceAliases(source,result,sizeof(*result)) || requestAliases(request,result,sizeof(*result)))
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        prepareOutput(result);
        if (!session) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, "Missing HDR session");
        validateRequestVersion(request);
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "HDR computation is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        auto input = readPair(source);
        if (request->intent == SONY2FUJI_INTENT_FINAL) {
            finalSource(input->pixels);
            if (input->pixels.hdr.width!=int(input->pixels.nativeWidth) || input->pixels.hdr.height!=int(input->pixels.nativeHeight))
                fail(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE,SONY2FUJI_HDR_FIELD_SOURCE,"FINAL render requires the complete decoded source canvas");
        }
        std::string lookPath;
        const auto o = renderOptions(request, session, &lookPath);
        const ProcessingCancellationScope cancellation(o.hasPhotoEffects() || o.hasDetail() || o.look ?
            hdrSessionCancellation(session) : ProcessingCancellation{});
        const uint64_t pixels = uint64_t(input->pixels.hdr.width) * input->pixels.hdr.height;
        // A borrowed C pair was copied into a private Owner by readPair(). Its
        // vectors can now be transferred into the render result; published
        // owners remain immutable and still need the copy-sized budget.
        uint64_t extra = 0;
        if (o.hasDetail()) {
            const auto native = geometryOutputSize(input->pixels.hdr.width, input->pixels.hdr.height, o.geometry);
            const auto size = hdrResizeSize(native.first, native.second, o.longEdge);
            const auto halo = o.detail.halo(size.first, size.second);
            extra = uint64_t(size.first) * size.second * sizeof(RGB) +
                uint64_t(size.first) * std::min(size.second, hdrDetailBandHeight + 2 * halo) * sizeof(float);
        }
        hdr::admitMemory(pixels * (source->owner_token ? 48 : 24) + extra);
        auto output = std::make_shared<Owner>();
        output->pixels = source->owner_token ? renderHDRPair(input->pixels, o) :
            renderHDRPair(std::move(input->pixels), o);
        output->sha = input->sha; output->sourceHeadroomKind = input->sourceHeadroomKind;
        output->sourcePath = input->sourcePath;
        output->cameraProfilePath = input->cameraProfilePath;
        output->lookPath = std::move(lookPath);
        publish(std::move(output), result);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_create_hsl_probe(sony2fuji_session* session, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, uint64_t sourceRevision, uint64_t requestRevision,
    sony2fuji_hsl_probe** outProbe, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (!outProbe || sourceAliases(source, outProbe, sizeof(*outProbe)) || requestAliases(request, outProbe, sizeof(*outProbe)))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_RESULT, "Invalid HDR probe output");
        *outProbe = nullptr;
        if (!session) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, "Missing HDR session");
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "HDR computation is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        const auto options = renderOptions(request, session);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto input = readPair(source);
        if (options.intent == HDRQuality::Final) {
            finalSource(input->pixels);
            if (input->pixels.hdr.width != int(input->pixels.nativeWidth) || input->pixels.hdr.height != int(input->pixels.nativeHeight))
                fail(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE, SONY2FUJI_HDR_FIELD_SOURCE, "FINAL probe requires the complete decoded source canvas");
        }
        hdr::admitMemory(uint64_t(input->pixels.hdr.width) * input->pixels.hdr.height * (source->owner_token ? 12 : 24));
        auto image = source->owner_token ? input->pixels.hdr : std::move(input->pixels.hdr);
        auto probe = renderHDRHslProbe(std::move(image), options);
        checkProcessingCancellation();
        *outProbe = makeHDRHslProbe(std::move(probe), sourceRevision, requestRevision, options.intent == HDRQuality::Preview);
    });
}

sony2fuji_status sony2fuji_hdr_probe(const char* file, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info); path(file);
        auto value = hdr::probeFile(file); value.struct_size = info->struct_size; *info = value;
    });
}
sony2fuji_status sony2fuji_hdr_probe_look(const char* file, sony2fuji_hdr_look_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info);
        const auto look = loadLook(file);
        info->grid_size = uint32_t(look->gridSize());
        const auto& low = look->domainMin();
        const auto& high = look->domainMax();
        info->domain_min[0] = low.r; info->domain_min[1] = low.g; info->domain_min[2] = low.b;
        info->domain_max[0] = high.r; info->domain_max[1] = high.g; info->domain_max[2] = high.b;
        std::copy_n(look->fingerprint().begin(), 64, info->sha256);
    });
}
sony2fuji_status sony2fuji_hdr_probe_camera_profile(const char* file, sony2fuji_hdr_camera_profile_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info);
        const auto resource = loadCameraProfile(file);
        std::copy(resource.profile.cameraModel.begin(), resource.profile.cameraModel.end(), info->camera_model);
        std::copy_n(resource.digest.c_str(), 65, info->sha256);
    });
}
sony2fuji_status sony2fuji_hdr_decode(const char* file, const sony2fuji_hdr_decode_options_v1* options,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        prepareOutput(result); header(options, SONY2FUJI_HDR_FIELD_REQUEST); path(file);
        if (options->intent > 1 || options->long_edge > 65535 ||
            (options->intent == SONY2FUJI_INTENT_FINAL && options->long_edge != 0))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "FINAL decode cannot use a proxy size");
        auto decoded = hdr::decodeFile(file, *options);
        auto owner = std::make_shared<Owner>(); owner->pixels = std::move(decoded.pixels);
        owner->sourcePath = file;
        owner->sourceHeadroomKind = decoded.info.headroom_kind;
        std::copy_n(decoded.info.source_sha256, 32, owner->sha.begin());
        publish(std::move(owner), result);
    });
}
sony2fuji_status sony2fuji_hdr_probe_camera_raw(const char* file, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info); path(file);
        cameraRawStamp(std::filesystem::u8path(file));
        RAWProcessor processor;
        int width = 0, height = 0;
        uint64_t sensorPixels = 0;
        cameraRawStatus(processor.inspectCameraHDR(file, width, height, sensorPixels));
        info->container = SONY2FUJI_HDR_CONTAINER_CAMERA_RAW;
        info->color_description = SONY2FUJI_HDR_COLOR_SRGB;
        info->width = width;
        info->height = height;
        info->orientation = 1;
        if (info->struct_size >= sizeof(sony2fuji_hdr_camera_source_info_v1)) {
            const uint32_t capabilities = processor.supportsNoiseReduction() ? SONY2FUJI_HDR_CAMERA_SOURCE_BAYER : 0;
            std::memcpy(reinterpret_cast<unsigned char*>(info) + offsetof(sony2fuji_hdr_camera_source_info_v1, capabilities),
                &capabilities, sizeof(capabilities));
        }
    });
}

sony2fuji_status sony2fuji_hdr_decode_camera_raw(sony2fuji_session* session, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return sony2fuji_hdr_decode_camera_raw_with_development(session,file,options,nullptr,result,diagnostic);
}

sony2fuji_status sony2fuji_hdr_prepare_camera_raw_ai(sony2fuji_session* session, const char* file,
    sony2fuji_ai_progress_callback progress, void* context, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        path(file);
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "Camera RAW HDR development is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        const auto stamp = cameraRawStamp(std::filesystem::u8path(file));
        hdrSessionPrepareCameraAI(session, file, stamp.size, progress, context);
    });
}

sony2fuji_status sony2fuji_hdr_camera_ai_key(sony2fuji_session* session, const char* file,
    char* key, uint32_t capacity, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (!key || capacity < 65)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_RESULT, "Truncated HDR camera AI key buffer");
        key[0] = '\0';
        path(file);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        cameraRawStamp(std::filesystem::u8path(file));
        const auto identity = hdrSessionCameraAIKey(session, file);
        std::memcpy(key, identity.c_str(), 65);
    });
}

static sony2fuji_status decodeCameraRaw(sony2fuji_session* session, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, const sony2fuji_hdr_camera_development_v1* development,
    bool ai, sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        prepareOutput(result); header(options, SONY2FUJI_HDR_FIELD_REQUEST); path(file);
        const bool preview = options->intent == SONY2FUJI_INTENT_PREVIEW;
        if (options->intent > 1 || (preview ? !options->long_edge || options->long_edge > 65535 : options->long_edge != 0))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid camera RAW HDR decode size");
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "Camera RAW HDR development is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        RAWProcessOptions raw;
        raw.outputLinear = true;
        raw.applyBaselineExposure = false;
        bool useMetadataExposure = true;
        std::optional<CameraProfileResource> profile;
        sony2fuji_hdr_camera_development_v2 profiled{};
        if (development) {
            if (development->version == 2 && !ai) {
                if (development->struct_size < sizeof(profiled))
                    fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
                        "Truncated HDR camera profile configuration");
                std::memcpy(&profiled, development, sizeof(profiled));
            } else {
                header(development, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT);
            }
            const auto flags = development->lens_flags;
            const bool temperatureWB = development->white_balance == SONY2FUJI_HDR_CAMERA_WB_TEMPERATURE;
            const bool validWB = temperatureWB
                ? development->temperature >= 2000 && development->temperature <= 50000 &&
                    development->tint >= -150 && development->tint <= 150
                : development->white_balance == SONY2FUJI_HDR_CAMERA_WB_AS_SHOT &&
                    development->temperature == 0 && development->tint == 0;
            raw.lensCorrection.distortion = (flags & SONY2FUJI_HDR_CAMERA_LENS_DISTORTION) != 0;
            raw.lensCorrection.tca = (flags & SONY2FUJI_HDR_CAMERA_LENS_TCA) != 0;
            raw.lensCorrection.autoCrop = (flags & SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP) != 0;
            if (!validWB || development->exposure_reference > SONY2FUJI_HDR_CAMERA_EXPOSURE_SENSOR ||
                development->fbdd_level > 2 || (flags & ~7u) ||
                (!raw.lensCorrection.active() && (flags || development->lens_profile_id)))
                fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
                    "Invalid camera RAW HDR development parameters");
            if (raw.lensCorrection.active()) {
                raw.lensDatabase = hdrSessionLensDatabase(session);
                if (!raw.lensDatabase)
                    fail(SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
                        "Camera RAW HDR lens database is unavailable", SONY2FUJI_STATUS_UNSUPPORTED);
                if (development->lens_profile_id) raw.lensCorrection.profileID = development->lens_profile_id;
            }
            raw.useCameraWhiteBalance = !temperatureWB;
            raw.useTemperatureWhiteBalance = temperatureWB;
            if (temperatureWB) {
                raw.temperature = development->temperature;
                raw.tint = development->tint;
            }
            raw.rawNoiseReduction = static_cast<int>(development->fbdd_level);
            useMetadataExposure = development->exposure_reference == SONY2FUJI_HDR_CAMERA_EXPOSURE_METADATA;
            if (profiled.base.version == 2) {
                const auto* sha = profiled.profile_sha256;
                if (sha[64] != '\0' || !std::all_of(sha, sha + 64, [](char c) {
                        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                    }))
                    fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
                        "Invalid HDR camera profile fingerprint");
                profile = loadCameraProfile(profiled.profile_path, {sha, 64});
                raw.hdrCameraProfile = &profile->profile;
            }
        }
        if (ai && raw.rawNoiseReduction != 0)
            fail(SONY2FUJI_HDR_REASON_CAMERA_AI, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "FBDD and HDR AI cannot be combined");
        raw.halfSize = preview && raw.rawNoiseReduction == 0 && !ai;
        const auto filePath = std::filesystem::u8path(file);
        const auto before = cameraRawStamp(filePath);
        const auto aiKey = ai ? hdrSessionCameraAIKey(session, file) : std::string{};

        auto owner = std::make_shared<Owner>();
        auto& pair = owner->pixels;
        {
            RAWProcessor processor;
            int width = 0, height = 0;
            uint64_t sensorPixels = 0;
            cameraRawStatus(processor.inspectCameraHDR(file, width, height, sensorPixels));
            if (profile && !processor.supportsHDRCameraProfile(profile->profile))
                fail(SONY2FUJI_HDR_REASON_CAMERA_PROFILE, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
                    "HDR profile does not match the camera calibration", SONY2FUJI_STATUS_UNSUPPORTED);
            const uint64_t developedPixels = raw.halfSize ? uint64_t((width + 1) / 2) * ((height + 1) / 2)
                                                    : uint64_t(width) * height;
            // The mosaic still unpacks at sensor size. LibRaw's working RGBA16
            // and the float RGB development are smaller in half-size mode.
            // HDR AI also holds the reference development, mosaic and sensor backup.
            const uint64_t xTransSourceCopy = !raw.halfSize && !processor.supportsNoiseReduction() ? developedPixels * 8 : 0;
            hdr::admitMemory(before.size + sensorPixels * 4 + developedPixels * (ai ? 42 : 24) + xTransSourceCopy);
            cameraRawStatus(processor.unpackInspectedCameraHDR());
            if (raw.useTemperatureWhiteBalance && !profile) {
                float temperature = 0, tint = 0;
                if (!processor.getAsShotWhiteBalance(temperature, tint))
                    fail(SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
                        "Camera RAW HDR custom white balance calibration is unavailable", SONY2FUJI_STATUS_UNSUPPORTED);
            }
            pair.nativeWidth = width;
            pair.nativeHeight = height;
            // Camera RAW HDR v1 anchors reference white at one quarter of the
            // baseline-adjusted scene scale, with two stops above diffuse white.
            raw.exposure = (useMetadataExposure ? processor.getMetadataExposureEV() : 0) + 2.0f;
            if (ai) {
                RAWBayerSource bayer;
                if (!processor.getBayerMetadata(bayer)) cameraRawStatus(ErrorCode::InvalidFormat);
                const auto replacement = hdrSessionLoadCameraAI(session, aiKey, bayer);
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
                    (raw.lensCorrection.tca && !report.appliedTCA))
                    fail(SONY2FUJI_HDR_REASON_CAMERA_DEVELOPMENT, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT,
                        "Requested camera RAW HDR lens calibration is unavailable", SONY2FUJI_STATUS_UNSUPPORTED);
            }
        }
        if (preview) {
            const auto longest = std::max(pair.hdr.width, pair.hdr.height);
            if (uint32_t(longest) > options->long_edge) {
                const double scale = double(options->long_edge) / longest;
                auto width = std::max(1l, std::lround(pair.hdr.width * scale));
                auto height = std::max(1l, std::lround(pair.hdr.height * scale));
                hdr::admitMemory(uint64_t(width) * height * sizeof(RGB));
                pair.hdr = hdr::resample(pair.hdr, uint32_t(width), uint32_t(height));
            }
        } else if (uint32_t(pair.hdr.width) != pair.nativeWidth || uint32_t(pair.hdr.height) != pair.nativeHeight) {
            cameraRawStatus(ErrorCode::InvalidFormat);
        }
        hdr::admitMemory(pair.hdr.pixels.size() * sizeof(RGB));
        pair.sdr = ImageData(pair.hdr.width, pair.hdr.height);
        std::atomic<bool> nonfinite{false};
        parallelPixelRanges(pair.hdr.pixels.size(), [&](size_t first, size_t last) {
            for (size_t i = first; i < last; ++i) {
                const auto& pixel = pair.hdr.pixels[i];
                if (!std::isfinite(pixel.r) || !std::isfinite(pixel.g) || !std::isfinite(pixel.b)) {
                    nonfinite.store(true, std::memory_order_relaxed);
                    return;
                }
                pair.sdr.pixels[i] = cameraSDR(pixel);
            }
        });
        if (nonfinite.load(std::memory_order_relaxed))
            fail(SONY2FUJI_HDR_REASON_NONFINITE, SONY2FUJI_HDR_FIELD_SOURCE, "Nonfinite camera RAW pixel",
                SONY2FUJI_STATUS_PROCESSING_ERROR);
        if (!preview) {
            pair.sourceHeadroom = 1;
            for (const auto& pixel : pair.hdr.pixels)
                pair.sourceHeadroom = std::max(pair.sourceHeadroom, cameraLuminance(pixel));
            owner->sourceHeadroomKind = SONY2FUJI_HDR_HEADROOM_MEASURED;
        }
        std::string digest;
        try { digest = hash::sha256File(file, checkProcessingCancellation); }
        catch (const std::runtime_error&) { cameraRawStatus(ErrorCode::FileNotFound); }
        const auto after = cameraRawStamp(filePath);
        if (before.size != after.size || before.modified != after.modified ||
            (ai && aiKey != hdrSessionCameraAIKey(session, file)))
            fail(SONY2FUJI_HDR_REASON_SOURCE_CHANGED, SONY2FUJI_HDR_FIELD_SOURCE, "Camera RAW source changed during decode");
        for (size_t i = 0; i < owner->sha.size(); ++i) {
            auto digit = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
            owner->sha[i] = uint8_t(digit(digest[2*i]) * 16 + digit(digest[2*i+1]));
        }
        checkProcessingCancellation();
        pair.sourceQuality = pair.renderQuality = static_cast<HDRQuality>(options->intent);
        pair.isProxy = preview;
        pair.decodeRevision = nextCameraRevision.fetch_add(1);
        owner->sourcePath = file;
        if (profile) owner->cameraProfilePath = profiled.profile_path;
        publish(std::move(owner), result);
        if (session) hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_decode_camera_raw_with_development(sony2fuji_session* session, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, const sony2fuji_hdr_camera_development_v1* development,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return decodeCameraRaw(session, file, options, development, false, result, diagnostic);
}

sony2fuji_status sony2fuji_hdr_decode_camera_raw_with_ai(sony2fuji_session* session, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, const sony2fuji_hdr_camera_development_v1* development,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return decodeCameraRaw(session, file, options, development, true, result, diagnostic);
}

sony2fuji_status sony2fuji_hdr_probe_proraw(const char* file, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info); path(file);
        auto value = hdr::probeProRAW(file); value.struct_size = info->struct_size; *info = value;
    });
}
sony2fuji_status sony2fuji_hdr_decode_proraw(sony2fuji_session* session, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, const char* temporaryRoot,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        prepareOutput(result); header(options, SONY2FUJI_HDR_FIELD_REQUEST); path(file); path(temporaryRoot);
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "ProRAW development is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto decoded = hdr::decodeProRAW(file, *options, std::filesystem::u8path(temporaryRoot));
        auto owner = std::make_shared<Owner>(); owner->pixels = std::move(decoded.pixels);
        owner->sourcePath = file; owner->sourceHeadroomKind = decoded.info.headroom_kind;
        std::copy_n(decoded.info.source_sha256, 32, owner->sha.begin());
        publish(std::move(owner), result);
        if (session) hdrSessionDidRenderCPU(session);
    });
}
sony2fuji_status sony2fuji_hdr_export_proraw(sony2fuji_session* session, const char* sourceFile,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_export_config_v1* config,
    uint32_t keepHDR, const char* temporaryRoot, const char* file,
    sony2fuji_hdr_stream_result_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT); header(result, SONY2FUJI_HDR_FIELD_RESULT);
        if (overlaps(config, sizeof(*config), result, sizeof(*result)) || requestAliases(request,result,sizeof(*result)))
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "ProRAW result aliases input");
        clearOutput(result); path(sourceFile); path(file); path(temporaryRoot); path(config->metadata_source_path);
        if (!session) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, "Missing HDR session");
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "ProRAW development is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        std::string lookPath;
        const auto options = renderOptions(request, session, &lookPath);
        if (options.intent != HDRQuality::Final || keepHDR > 1 || config->metadata_policy != SONY2FUJI_HDR_METADATA_ISO_XMP)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT, "Invalid ProRAW export configuration");
        if (std::filesystem::weakly_canonical(std::filesystem::u8path(sourceFile)) !=
            std::filesystem::weakly_canonical(std::filesystem::u8path(config->metadata_source_path)) ||
            std::all_of(config->source_sha256, config->source_sha256 + 32, [](uint8_t value) { return value == 0; }))
            fail(SONY2FUJI_HDR_REASON_SOURCE_CHANGED, SONY2FUJI_HDR_FIELD_SOURCE, "ProRAW export requires a frozen source");
        differentFile(std::string(sourceFile), file);
        differentFile(lookPath, file);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        const auto info = hdr::probeProRAW(sourceFile);
        hdr::validateStreamSource(*config, info.width, info.height, file);
        const auto streamBytes = hdr::streamScratchBytes(info.width, info.height, options, keepHDR != 0);
        // SDK stage 与完整源 float spool 同时存活，开始解码前按同一卷的合计峰值准入。
        hdr::storage::requireSpace(std::filesystem::u8path(temporaryRoot),
            hdr::proRAWStageBytes(uint64_t(info.width) * info.height) + streamBytes);
        auto source = hdr::openProRAW(sourceFile, std::filesystem::u8path(temporaryRoot));
        auto encoded = hdr::encodeStream(source, options, keepHDR != 0, config->jpeg_quality ? config->jpeg_quality : 95,
            config->base_color, std::filesystem::u8path(temporaryRoot));
        hdr::publishStreamJPEG(std::move(encoded.jpeg), encoded.width, encoded.height, *config, keepHDR != 0, file);
        result->width = encoded.width; result->height = encoded.height;
        result->native_width = info.width; result->native_height = info.height;
        result->output_native_width = encoded.outputNativeWidth; result->output_native_height = encoded.outputNativeHeight;
        result->decode_revision = hdr::portableProRAWRevision;
        result->source_headroom = encoded.sourceHeadroom; result->edited_headroom = encoded.editedHeadroom;
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_export_jpeg(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1* config, const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT); path(file);
        auto owned = readPair(image); finalSource(owned->pixels);
        differentFile(*owned,file);
        metadataSource(*owned,config->metadata_source_path,config->source_sha256);
        hdr::admitMemory(uint64_t(owned->pixels.hdr.width)*owned->pixels.hdr.height*64);
        hdr::exportJPEG(owned->pixels, *config, file);
    });
}
uint32_t sony2fuji_hdr_heif_export_available(void) { return hdr::heifExportAvailable() ? 1 : 0; }
sony2fuji_status sony2fuji_hdr_export_heif(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1* config, const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT); path(file);
        if (!hdr::heifExportAvailable())
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL, SONY2FUJI_HDR_FIELD_EXPORT,
                "HDR HEIF encoding is unavailable", SONY2FUJI_STATUS_UNSUPPORTED);
        if (config->metadata_policy != SONY2FUJI_HDR_METADATA_ISO || config->jpeg_quality > 100 ||
            (config->base_color != SONY2FUJI_HDR_COLOR_SRGB && config->base_color != SONY2FUJI_HDR_COLOR_DISPLAY_P3))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT,"Invalid HDR HEIF export configuration");
        header(image,SONY2FUJI_HDR_FIELD_SOURCE);
        const bool borrowed = !image->owner_token;
        if (borrowed) {
            buffer(image->hdr,true); buffer(image->sdr,false);
            // 借用双图需要先复制，准入时把复制和后续编码工作集一起计算。
            const uint64_t hdrPixels = uint64_t(image->hdr.width) * image->hdr.height;
            const uint64_t sdrPixels = uint64_t(image->sdr.width) * image->sdr.height;
            hdr::admitMemory((hdrPixels+sdrPixels)*sizeof(RGB) + hdrPixels*64);
        }
        auto owned = readPair(image); finalSource(owned->pixels);
        differentFile(*owned,file);
        metadataSource(*owned,config->metadata_source_path,config->source_sha256);
        if (!borrowed) hdr::admitMemory(uint64_t(owned->pixels.hdr.width)*owned->pixels.hdr.height*64);
        hdr::exportHEIF(owned->pixels, *config, file);
    });
}
sony2fuji_status sony2fuji_hdr_export_sdr(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_sdr_export_config_v1* config, const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT); path(file);
        auto owned = readPair(image); finalSource(owned->pixels);
        differentFile(*owned,file);
        metadataSource(*owned,config->metadata_source_path,config->source_sha256);
        hdr::admitMemory(uint64_t(owned->pixels.sdr.width)*owned->pixels.sdr.height*24);
        if (config->output_format==SONY2FUJI_OUTPUT_DNG) exportSDRDNG(*owned,*config,file);
        else hdr::exportSDR(owned->pixels, *config, file);
    });
}

sony2fuji_status sony2fuji_hdr_export_stream(sony2fuji_session* session,
    const sony2fuji_hdr_stream_source_v1* source, const sony2fuji_hdr_request_v1* request,
    const sony2fuji_hdr_export_config_v1* config, uint32_t keepHDR, const char* temporaryRoot,
    const char* file, sony2fuji_hdr_stream_result_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(source, SONY2FUJI_HDR_FIELD_SOURCE); header(config, SONY2FUJI_HDR_FIELD_EXPORT);
        header(result, SONY2FUJI_HDR_FIELD_RESULT);
        if (overlaps(source, sizeof(*source), result, sizeof(*result)) ||
            overlaps(config, sizeof(*config), result, sizeof(*result)) || requestAliases(request,result,sizeof(*result)))
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "Stream result aliases input");
        clearOutput(result);
        path(file); path(temporaryRoot); path(config->metadata_source_path);
        if (!session) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, "Missing HDR session");
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "Streamed HDR processing is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        std::string lookPath;
        const auto options = renderOptions(request, session, &lookPath);
        differentFile(lookPath, file);
        if (source->source_intent != SONY2FUJI_INTENT_FINAL || source->orientation_applied != 1 ||
            options.intent != HDRQuality::Final)
            fail(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE, SONY2FUJI_HDR_FIELD_SOURCE, "Stream export requires a complete oriented FINAL source");
        if (!source->native_width || !source->native_height || uint64_t(source->native_width) * source->native_height > 128000000 ||
            !source->decode_revision || !source->decoder_identifier || !*source->decoder_identifier ||
            !source->read_rows || !source->finish_decode || keepHDR > 1 ||
            config->metadata_policy != SONY2FUJI_HDR_METADATA_ISO_XMP)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE, "Incomplete stream source or export configuration");
        if (std::memcmp(source->source_sha256, config->source_sha256, 32) != 0 ||
            std::all_of(source->source_sha256, source->source_sha256 + 32, [](uint8_t value) { return value == 0; }))
            fail(SONY2FUJI_HDR_REASON_SOURCE_CHANGED, SONY2FUJI_HDR_FIELD_SOURCE, "Stream source digest does not match the frozen file");
        differentFile(std::string(config->metadata_source_path), file);
        struct Cancellation {
            ProcessingCancellation session;
            const sony2fuji_hdr_stream_source_v1* source;
        } cancellation{hdrSessionCancellation(session), source};
        const ProcessingCancellationScope scope({[](void* opaque) {
            auto& state = *static_cast<Cancellation*>(opaque);
            return state.session.cancelled() || (state.source->is_cancelled && state.source->is_cancelled(state.source->context)) ? 1 : 0;
        }, &cancellation});
        checkProcessingCancellation();
        hdr::validateStreamSource(*config, source->native_width, source->native_height, file);
        auto checkCallback = [&](sony2fuji_status status, bool finish) {
            if (status == SONY2FUJI_STATUS_OK) return;
            if (status == SONY2FUJI_STATUS_CANCELLED) throw ProcessingCancelled();
            fail(status == SONY2FUJI_STATUS_OUT_OF_MEMORY ? SONY2FUJI_HDR_REASON_OUT_OF_MEMORY :
                finish ? SONY2FUJI_HDR_REASON_SOURCE_CHANGED : SONY2FUJI_HDR_REASON_INVALID_BUFFER,
                SONY2FUJI_HDR_FIELD_SOURCE, "Stream source callback failed", status);
        };
        HDRRowSource rows;
        rows.width = source->native_width; rows.height = source->native_height;
        rows.read = [&](bool hdr, uint32_t row, uint32_t count, RGB* pixels) {
            static_assert(sizeof(RGB) == 3 * sizeof(float));
            checkCallback(source->read_rows(source->context, hdr ? 1 : 0, row, count, reinterpret_cast<float*>(pixels)), false);
        };
        rows.finish = [&] { checkCallback(source->finish_decode(source->context), true); };
        auto encoded = hdr::encodeStream(rows, options, keepHDR != 0, config->jpeg_quality ? config->jpeg_quality : 95,
            config->base_color, std::filesystem::u8path(temporaryRoot));
        hdr::publishStreamJPEG(std::move(encoded.jpeg), encoded.width, encoded.height, *config, keepHDR != 0, file);
        result->width = encoded.width; result->height = encoded.height;
        result->native_width = source->native_width; result->native_height = source->native_height;
        result->output_native_width = encoded.outputNativeWidth; result->output_native_height = encoded.outputNativeHeight;
        result->decode_revision = source->decode_revision;
        result->source_headroom = encoded.sourceHeadroom; result->edited_headroom = encoded.editedHeadroom;
        hdrSessionDidRenderCPU(session);

    });
}
void sony2fuji_hdr_release_pair(sony2fuji_hdr_image_pair_v1* image) {
    if (!image || image->version != 1 || image->struct_size < sizeof(*image)) return;
    const size_t size=image->struct_size;
    { std::lock_guard<std::mutex> lock(ownersMutex); owners.erase(image->owner_token); }
    std::memset(image,0,size);
}
} // extern C
