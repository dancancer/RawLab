#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "ffi/hdr_session.h"
#include "platform/hdr_image.h"
#include "core/rendered_dng.h"
#include "core/hdr_resample.h"
#include "core/parallel_pixels.h"
#include "core/photo_rendering.h"
#include "core/sha256.h"
#include "core/hdr_stream.h"
#include "core/hdr_storage.h"
#include "core/proraw_source.h"
#include "sony2fuji/raw_processor.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
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

HDRRenderOptions renderOptions(const sony2fuji_hdr_request_v1* request) {
    header(request, SONY2FUJI_HDR_FIELD_REQUEST);
    if (request->hdr_processing_version != 1)
        fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION, SONY2FUJI_HDR_FIELD_REQUEST,
            "Unsupported HDR processing version", SONY2FUJI_STATUS_UNSUPPORTED);
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
    validateHDRRenderOptions(options);
    return options;
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
bool aliases(const sony2fuji_hdr_image_pair_v1* source,const sony2fuji_hdr_image_pair_v1* result) {
    if (!source || !result) return false;
    if (overlaps(source,sizeof(*source),result,sizeof(*result))) return true;
    if (source->version!=1 || source->struct_size<sizeof(*source)) return false;
    return overlaps(source->hdr.data,source->hdr.size_bytes,result,sizeof(*result)) ||
        overlaps(source->sdr.data,source->sdr.size_bytes,result,sizeof(*result));
}
void differentFile(const std::string& sourcePath,const char* target) {
    if (sourcePath.empty()) return;
    std::error_code aError,bError,equivalentError;
    const auto a=std::filesystem::weakly_canonical(std::filesystem::u8path(sourcePath),aError);
    const auto b=std::filesystem::weakly_canonical(std::filesystem::u8path(target),bError);
    if ((!aError && !bError && a==b) || std::filesystem::equivalent(a,b,equivalentError))
        fail(SONY2FUJI_HDR_REASON_SAME_FILE,SONY2FUJI_HDR_FIELD_PATH,"HDR export cannot replace its source");
}
void differentFile(const Owner& source,const char* target) { differentFile(source.sourcePath,target); }
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
sony2fuji_status sony2fuji_hdr_geometry_size(uint32_t nativeWidth, uint32_t nativeHeight,
    const sony2fuji_hdr_request_v1* request, uint32_t* width, uint32_t* height,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(request, SONY2FUJI_HDR_FIELD_REQUEST);
        if (!width || !height || width == height || !nativeWidth || !nativeHeight ||
            uint64_t(nativeWidth) * nativeHeight > 128000000 || request->flip_horizontal > 1 ||
            request->flip_vertical > 1)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR geometry dimensions");
        if (request->hdr_processing_version != 1)
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION, SONY2FUJI_HDR_FIELD_REQUEST,
                "Unsupported HDR geometry version", SONY2FUJI_STATUS_UNSUPPORTED);
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
        if (aliases(source,result)) fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR source/result alias");
        prepareOutput(result);
        if (!session) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, "Missing HDR session");
        header(request, SONY2FUJI_HDR_FIELD_REQUEST);
        if (request->hdr_processing_version != 1)
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION, SONY2FUJI_HDR_FIELD_REQUEST, "Unsupported HDR processing version",
                SONY2FUJI_STATUS_UNSUPPORTED);
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "HDR computation is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        auto input = readPair(source);
        if (request->intent == SONY2FUJI_INTENT_FINAL) {
            finalSource(input->pixels);
            if (input->pixels.hdr.width!=int(input->pixels.nativeWidth) || input->pixels.hdr.height!=int(input->pixels.nativeHeight))
                fail(SONY2FUJI_HDR_REASON_PREVIEW_SOURCE,SONY2FUJI_HDR_FIELD_SOURCE,"FINAL render requires the complete decoded source canvas");
        }
        const auto o = renderOptions(request);
        const uint64_t pixels = uint64_t(input->pixels.hdr.width) * input->pixels.hdr.height;
        // A borrowed C pair was copied into a private Owner by readPair(). Its
        // vectors can now be transferred into the render result; published
        // owners remain immutable and still need the copy-sized budget.
        hdr::admitMemory(pixels * (source->owner_token ? 48 : 24));
        auto output = std::make_shared<Owner>();
        output->pixels = source->owner_token ? renderHDRPair(input->pixels, o) :
            renderHDRPair(std::move(input->pixels), o);
        output->sha = input->sha; output->sourceHeadroomKind = input->sourceHeadroomKind;
        output->sourcePath = input->sourcePath;
        publish(std::move(output), result);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_probe(const char* file, sony2fuji_hdr_source_info_v1* info,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info); path(file);
        auto value = hdr::probeFile(file); value.struct_size = info->struct_size; *info = value;
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
    });
}

sony2fuji_status sony2fuji_hdr_decode_camera_raw(sony2fuji_session* session, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
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
        const auto filePath = std::filesystem::u8path(file);
        const auto before = cameraRawStamp(filePath);

        auto owner = std::make_shared<Owner>();
        auto& pair = owner->pixels;
        {
            RAWProcessor processor;
            int width = 0, height = 0;
            uint64_t sensorPixels = 0;
            cameraRawStatus(processor.inspectCameraHDR(file, width, height, sensorPixels));
            const uint64_t developedPixels = preview ? uint64_t((width + 1) / 2) * ((height + 1) / 2)
                                                    : uint64_t(width) * height;
            // The mosaic still unpacks at sensor size. LibRaw's working RGBA16
            // and the float RGB development are smaller in half-size mode.
            hdr::admitMemory(before.size + sensorPixels * 4 + developedPixels * 24);
            cameraRawStatus(processor.unpackInspectedCameraHDR());
            RAWBayerSource bayer;
            if (!processor.getBayerMetadata(bayer)) cameraRawStatus(ErrorCode::InvalidFormat);
            pair.nativeWidth = (bayer.flip & 4) ? bayer.height : bayer.width;
            pair.nativeHeight = (bayer.flip & 4) ? bayer.width : bayer.height;
            if (pair.nativeWidth != uint32_t(width) || pair.nativeHeight != uint32_t(height))
                cameraRawStatus(ErrorCode::InvalidFormat);
            RAWProcessOptions raw;
            raw.halfSize = preview;
            raw.outputLinear = true;
            raw.applyBaselineExposure = false;
            // Camera RAW HDR v1 anchors reference white at one quarter of the
            // baseline-adjusted scene scale, with two stops above diffuse white.
            raw.exposure = processor.getMetadataExposureEV() + 2.0f;
            cameraRawStatus(processor.process(raw, pair.hdr));
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
        try { digest = hash::sha256File(file); }
        catch (const std::runtime_error&) { cameraRawStatus(ErrorCode::FileNotFound); }
        const auto after = cameraRawStamp(filePath);
        if (before.size != after.size || before.modified != after.modified)
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
        publish(std::move(owner), result);
        if (session) hdrSessionDidRenderCPU(session);
    });
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
        if (overlaps(config, sizeof(*config), result, sizeof(*result)) ||
            overlaps(request, sizeof(*request), result, sizeof(*result)))
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "ProRAW result aliases input");
        clearOutput(result); path(sourceFile); path(file); path(temporaryRoot); path(config->metadata_source_path);
        if (!session) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, "Missing HDR session");
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "ProRAW development is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        const auto options = renderOptions(request);
        if (options.intent != HDRQuality::Final || keepHDR > 1 || config->metadata_policy != SONY2FUJI_HDR_METADATA_ISO_XMP)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT, "Invalid ProRAW export configuration");
        if (std::filesystem::weakly_canonical(std::filesystem::u8path(sourceFile)) !=
            std::filesystem::weakly_canonical(std::filesystem::u8path(config->metadata_source_path)) ||
            std::all_of(config->source_sha256, config->source_sha256 + 32, [](uint8_t value) { return value == 0; }))
            fail(SONY2FUJI_HDR_REASON_SOURCE_CHANGED, SONY2FUJI_HDR_FIELD_SOURCE, "ProRAW export requires a frozen source");
        differentFile(std::string(sourceFile), file);
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
            overlaps(config, sizeof(*config), result, sizeof(*result)) ||
            overlaps(request, sizeof(*request), result, sizeof(*result)))
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "Stream result aliases input");
        clearOutput(result);
        path(file); path(temporaryRoot); path(config->metadata_source_path);
        if (!session) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, "Missing HDR session");
        if (hdrSessionForcesGPU(session))
            fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, "Streamed HDR processing is CPU only",
                SONY2FUJI_STATUS_UNSUPPORTED);
        const auto options = renderOptions(request);
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
