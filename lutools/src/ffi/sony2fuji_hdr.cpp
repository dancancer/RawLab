#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "ffi/hdr_session.h"
#include "ffi/session_internal.h"
#include "core/bsh_diagnostics.h"
#include "core/edit_recipe_params.h"
#include "core/hdr_display.h"
#include "core/hdr_look.h"
#include "core/hdr_pipeline.h"
#include "core/hdr_progress.h"
#include "core/photo_rendering.h"
#include "core/proraw_source.h"
#include "platform/hdr_image.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

namespace {
using namespace sony2fuji;
using sony2fuji::hdr::Error;

static_assert(kHdrCameraLensDistortion == SONY2FUJI_HDR_CAMERA_LENS_DISTORTION);
static_assert(kHdrCameraLensTca == SONY2FUJI_HDR_CAMERA_LENS_TCA);
static_assert(kHdrCameraLensAutoCrop == SONY2FUJI_HDR_CAMERA_LENS_AUTO_CROP);
static_assert(kHdrCameraLensVignetting == SONY2FUJI_HDR_CAMERA_LENS_VIGNETTING);

[[noreturn]] void fail(uint32_t reason, uint32_t field, const char* msg,
                       sony2fuji_status status = SONY2FUJI_STATUS_INVALID_ARGUMENT) {
    throw Error(static_cast<RenderStatus>(status), reason, field, msg);
}
template <class T> T initialized() { T v{}; v.version = 1; v.struct_size = sizeof(T); return v; }
template <class T> void header(const T* v, uint32_t field) {
    if (!v) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, field, "Missing HDR structure");
    if (v->version != 1) fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION, field, "Unsupported HDR structure version", SONY2FUJI_STATUS_UNSUPPORTED);
    if (v->struct_size < sizeof(T)) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, field, "Truncated HDR structure");
}
template <class T> void clearOutput(T* v) { const uint32_t s = v->struct_size; *v = initialized<T>(); v->struct_size = s; }
void prepareOutput(sony2fuji_hdr_image_pair_v1* v) {
    header(v, SONY2FUJI_HDR_FIELD_RESULT);
    if (v->owner_token || v->hdr.data || v->sdr.data)
        fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "Release the previous HDR result first");
    clearOutput(v);
}
template <class Fn> sony2fuji_status boundary(sony2fuji_hdr_diagnostic_v1* diag, Fn fn) noexcept {
    if (diag && (diag->version != 1 || diag->struct_size < sizeof(*diag))) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    auto report = [&](uint32_t r, uint32_t f) { if (diag) { diag->reason = r; diag->field = f; } };
    try { fn(); report(0, 0); return SONY2FUJI_STATUS_OK; }
    catch (const ProcessingCancelled&) { report(0, 0); return SONY2FUJI_STATUS_CANCELLED; }
    catch (const Error& e) { report(e.reason, e.field); return static_cast<sony2fuji_status>(e.status); }
    catch (const std::bad_alloc&) { report(SONY2FUJI_HDR_REASON_OUT_OF_MEMORY, SONY2FUJI_HDR_FIELD_RESULT); return SONY2FUJI_STATUS_OUT_OF_MEMORY; }
    catch (const std::invalid_argument&) { report(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST); return SONY2FUJI_STATUS_INVALID_ARGUMENT; }
    catch (...) { report(SONY2FUJI_HDR_REASON_NONFINITE, SONY2FUJI_HDR_FIELD_RESULT); return SONY2FUJI_STATUS_PROCESSING_ERROR; }
}

sony2fuji_hdr_source_info_v1 toFfiSourceInfo(const HDRSourceInfo& i, uint32_t structSize) {
    sony2fuji_hdr_source_info_v1 r{1, structSize, i.width, i.height, i.orientation, i.container, i.protocol,
                                   i.colorDescription, i.contentHeadroom, i.headroomKind, {}};
    std::copy_n(i.sourceSha256, 32, r.source_sha256);
    return r;
}
HDRExportConfig toCoreExportConfig(const sony2fuji_hdr_export_config_v1& c) {
    HDRExportConfig r{c.jpeg_quality, c.base_color, c.metadata_policy, c.metadata_source_path, {}};
    std::copy_n(c.source_sha256, 32, r.sourceSha256);
    return r;
}
ToneCurveConfig toCoreToneCurveConfig(const sony2fuji_tone_curve_config& c) {
    if (c.version != SONY2FUJI_TONE_CURVE_CONFIG_VERSION || c.struct_size != sizeof(c))
        throw std::invalid_argument("invalid tone curve");
    ToneCurveConfig r;
    r.mode = c.mode == SONY2FUJI_CURVE_CUSTOM ? ToneCurveMode::Custom
        : (c.mode == SONY2FUJI_CURVE_LEGACY ? ToneCurveMode::Legacy : static_cast<ToneCurveMode>(c.mode));
    r.count = c.count;
    for (size_t i = 0; i < kToneCurveMaxPoints; ++i) r.points[i] = {c.points[i].x, c.points[i].y};
    return r;
}
hdr::BufferViewDescriptor toBufferDescriptor(const sony2fuji_hdr_buffer_v1& b, uint32_t field) {
    header(&b, field);
    return {b.version, b.struct_size, b.data, b.size_bytes, b.width, b.height, b.stride_bytes, b.pixel_format, b.color_encoding,
            b.pixel_format == SONY2FUJI_HDR_RGB32F_LINEAR && b.color_encoding == SONY2FUJI_HDR_LINEAR_SRGB,
            b.pixel_format == SONY2FUJI_HDR_RGB8_SRGB && b.color_encoding == SONY2FUJI_HDR_DISPLAY_SRGB,
            b.content_headroom, b.headroom_kind};
}
hdr::PairSnapshot toPairSnapshot(const sony2fuji_hdr_image_pair_v1* p) {
    // C/Swift 调用方的结构 padding 没有约定，不能 memcmp 整个公开结构。
    hdr::PairSnapshot snap{p->owner_token, toBufferDescriptor(p->hdr, SONY2FUJI_HDR_FIELD_HDR_BUFFER),
        toBufferDescriptor(p->sdr, SONY2FUJI_HDR_FIELD_SDR_BUFFER),
        {p->native_width, p->native_height, p->output_native_width, p->output_native_height, p->orientation_applied,
         p->source_intent, p->render_intent, p->is_proxy, p->decode_revision, p->source_headroom, p->source_headroom_kind}, {}};
    std::copy_n(p->source_sha256, 32, snap.sourceSha256.begin());
    return snap;
}
std::shared_ptr<hdr::OwnedPairRecord> readPair(const sony2fuji_hdr_image_pair_v1* p) {
    header(p, SONY2FUJI_HDR_FIELD_SOURCE);
    return hdr::acquirePairRecord(toPairSnapshot(p));
}
void publishPair(HDRImagePair pixels, float hdrHeadroom, float sdrHeadroom, uint32_t headroomKind,
                 hdr::ExportSourceMetadata meta, sony2fuji_hdr_image_pair_v1* result) {
    auto record = std::make_shared<hdr::OwnedPairRecord>();
    record->pixels = std::move(pixels); record->hdrContentHeadroom = hdrHeadroom; record->sdrContentHeadroom = sdrHeadroom;
    record->sourceHeadroomKind = headroomKind; record->meta = std::move(meta);
    auto fillView = [](ImageData& img, float h) {
        static_assert(sizeof(RGB) == 12);
        auto b = initialized<sony2fuji_hdr_buffer_v1>();
        b.data = img.pixels.data(); b.width = img.width; b.height = img.height;
        b.stride_bytes = uint64_t(img.width) * 12; b.size_bytes = img.pixels.size() * sizeof(RGB);
        b.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR; b.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
        b.headroom_kind = SONY2FUJI_HDR_HEADROOM_MEASURED; b.content_headroom = hdr::measureContentHeadroom(img, h);
        return b;
    };
    auto v = initialized<sony2fuji_hdr_image_pair_v1>();
    v.struct_size = result->struct_size;
    v.hdr = fillView(record->pixels.hdr, record->hdrContentHeadroom);
    v.sdr = fillView(record->pixels.sdr, record->sdrContentHeadroom);
    v.native_width = record->pixels.nativeWidth; v.native_height = record->pixels.nativeHeight;
    v.output_native_width = record->pixels.outputNativeWidth ? record->pixels.outputNativeWidth : v.native_width;
    v.output_native_height = record->pixels.outputNativeHeight ? record->pixels.outputNativeHeight : v.native_height;
    v.orientation_applied = 1; v.source_intent = uint32_t(record->pixels.sourceQuality);
    v.render_intent = uint32_t(record->pixels.renderQuality); v.is_proxy = record->pixels.isProxy;
    v.decode_revision = record->pixels.decodeRevision; v.source_headroom = record->pixels.sourceHeadroom;
    v.source_headroom_kind = record->sourceHeadroomKind;
    std::copy(record->meta.sourceSha256.begin(), record->meta.sourceSha256.end(), v.source_sha256);
    v.owner_token = hdr::registerPairRecord(std::move(record), toPairSnapshot(&v));
    *result = v;
}
void publishDecoded(hdr::DecodedImage decoded, const char* file, sony2fuji_hdr_image_pair_v1* result) {
    hdr::ExportSourceMetadata meta{{}, file, {}, {}};
    std::copy_n(decoded.info.sourceSha256, 32, meta.sourceSha256.begin());
    publishPair(std::move(decoded.pixels), 0.0f, 0.0f, decoded.info.headroomKind, std::move(meta), result);
}

void requirePath(const char* v) { if (!v || !*v) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_PATH, "Missing HDR file path"); }
void requireSession(sony2fuji_session* h, SessionLease& lease, bool allowNull = false) {
    if (!SessionLease::acquire(h, lease, allowNull))
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SESSION, h ? "Invalid or busy HDR session" : "Missing HDR session");
}
void requireCpuSession(sony2fuji_session* h, SessionLease& lease, const char* msg, bool allowNull = false) {
    requireSession(h, lease, allowNull);
    if (hdrSessionForcesGPU(lease)) fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_GPU, SONY2FUJI_HDR_FIELD_SESSION, msg, SONY2FUJI_STATUS_UNSUPPORTED);
}
size_t requestSize(uint32_t v) {
    constexpr size_t sizes[] = {0, sizeof(sony2fuji_hdr_request_v1), sizeof(sony2fuji_hdr_request_v2),
        sizeof(sony2fuji_hdr_request_v3), sizeof(sony2fuji_hdr_request_v4), sizeof(sony2fuji_hdr_request_v5),
        sizeof(sony2fuji_hdr_request_v6), sizeof(sony2fuji_hdr_request_v7), sizeof(sony2fuji_hdr_request_v8),
        sizeof(sony2fuji_hdr_request_v9), sizeof(sony2fuji_hdr_request_v9)};
    return v < std::size(sizes) ? sizes[v] : 0;
}
void validateRequestVersion(const sony2fuji_hdr_request_v1* req) {
    header(req, SONY2FUJI_HDR_FIELD_REQUEST);
    const size_t size = requestSize(req->hdr_processing_version);
    if (size == 0) fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION, SONY2FUJI_HDR_FIELD_REQUEST, "Unsupported HDR processing version", SONY2FUJI_STATUS_UNSUPPORTED);
    if (req->struct_size < size) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Truncated HDR processing request");
}
template <class Req> Req readExt(const sony2fuji_hdr_request_v1* req) { Req ext; std::memcpy(&ext, req, sizeof(ext)); return ext; }
HDRRenderOptions parseRenderOptions(const sony2fuji_hdr_request_v1* req, const SessionLease& session, std::string* lookPath = nullptr) {
    validateRequestVersion(req);
    if (req->flip_horizontal > 1 || req->flip_vertical > 1) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR flip");
    HDRRenderOptions o{req->hdr_processing_version, req->exposure_ev, req->temperature, req->tint, req->contrast,
        req->highlights, req->shadows, req->saturation, {req->crop_x, req->crop_y, req->crop_width, req->crop_height,
        req->quarter_turns, req->flip_horizontal != 0, req->flip_vertical != 0, req->straighten_degrees,
        req->perspective_horizontal, req->perspective_vertical}, static_cast<HDRQuality>(req->intent), req->long_edge,
        {}, {}, {}, {}, {}, nullptr, 0.0f};
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_TONE_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v2>(req);
        if (e.reserved != 0) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR tone request padding");
        o.tone = {e.black_point, e.white_point, e.curve_strength, toCoreToneCurveConfig(e.curve)};
    }
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_COLOR_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v3>(req);
        if (e.reserved != 0) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR color request padding");
        header(&e.hsl, SONY2FUJI_HDR_FIELD_REQUEST); header(&e.grading, SONY2FUJI_HDR_FIELD_REQUEST);
        o.color.vibrance = e.vibrance;
        std::copy_n(e.hsl.hue, SONY2FUJI_HSL_CHANNELS, o.color.hsl.hue.begin());
        std::copy_n(e.hsl.saturation, SONY2FUJI_HSL_CHANNELS, o.color.hsl.saturation.begin());
        std::copy_n(e.hsl.lightness, SONY2FUJI_HSL_CHANNELS, o.color.hsl.lightness.begin());
        o.color.grading.wheels = {{{e.grading.shadows_hue, e.grading.shadows_saturation},
            {e.grading.midtones_hue, e.grading.midtones_saturation}, {e.grading.highlights_hue, e.grading.highlights_saturation}}};
    }
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v4>(req);
        o.rendition = {e.peak_limit_ev, e.sdr_exposure_ev, e.sdr_contrast, e.sdr_saturation};
    }
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v5>(req); header(&e.effects, SONY2FUJI_HDR_FIELD_REQUEST);
        o.effects = {e.effects.vignette_amount, e.effects.vignette_midpoint, e.effects.vignette_roundness,
            e.effects.vignette_feather, e.effects.vignette_highlights, e.effects.grain_amount, e.effects.grain_size, e.effects.grain_roughness};
    }
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v6>(req); o.detail = {e.sharpening, e.clarity, e.dehaze, e.denoise};
    }
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_LOOK_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v7>(req);
        if (e.reserved != 0 || !(e.look_strength >= 0 && e.look_strength <= 2))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_LOOK, "Invalid HDR look settings");
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        o.look = hdr::loadLookForRequest(e.look_path, e.look_strength, e.look_sha256, lookPath);
        if (o.look) o.lookStrength = e.look_strength;
    }
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v8>(req);
        for (size_t i = 0; i < 3; ++i) o.tone.channels[i] = toCoreToneCurveConfig(e.channels[i]);
    }
    if (o.processingVersion >= SONY2FUJI_HDR_PROCESSING_V2_GRADING_CURVE_VERSION) {
        const auto e = readExt<sony2fuji_hdr_request_v9>(req);
        if ((e.curve_apply_to_luminosity != 0 && e.curve_apply_to_luminosity != 1) ||
            e.output_sharpening > SONY2FUJI_OUTPUT_SHARPENING_HIGH ||
            e.parametric_curve.version != SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION ||
            e.parametric_curve.struct_size != sizeof(e.parametric_curve) ||
            e.parametric_curve.reserved != 0 ||
            e.grading_v2.version != SONY2FUJI_COLOR_GRADING_V2_CONFIG_VERSION ||
            e.grading_v2.struct_size != sizeof(e.grading_v2)) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR v9 request configuration");
        }
        o.tone.applyToLuminosity = e.curve_apply_to_luminosity != 0;
        o.tone.parametric = {
            e.parametric_curve.highlights,
            e.parametric_curve.lights,
            e.parametric_curve.darks,
            e.parametric_curve.shadows,
            e.parametric_curve.split_shadow,
            e.parametric_curve.split_midtone,
            e.parametric_curve.split_highlight
        };
        o.outputSharpening = static_cast<OutputSharpening>(e.output_sharpening);
        o.color.grading.wheels = {{
            {e.grading_v2.shadows_hue, e.grading_v2.shadows_saturation, e.grading_v2.shadows_luminance},
            {e.grading_v2.midtones_hue, e.grading_v2.midtones_saturation, e.grading_v2.midtones_luminance},
            {e.grading_v2.highlights_hue, e.grading_v2.highlights_saturation, e.grading_v2.highlights_luminance}
        }};
        o.color.grading.global = {
            e.grading_v2.global_hue, e.grading_v2.global_saturation, e.grading_v2.global_luminance
        };
        o.color.grading.blending = e.grading_v2.blending;
        o.color.grading.balance = e.grading_v2.balance;
    }
    validateHDRRenderOptions(o);
    return o;
}

bool overlaps(const void* a, uint64_t aSize, const void* b, uint64_t bSize) {
    if (!a || !b || !aSize || !bSize) return false;
    const auto ap = reinterpret_cast<uintptr_t>(a), bp = reinterpret_cast<uintptr_t>(b);
    return ap <= bp ? aSize > bp - ap : bSize > ap - bp;
}
bool requestAliases(const sony2fuji_hdr_request_v1* req, const void* result, size_t size) {
    size_t bytes = sizeof(*req);
    if (req && req->version == SONY2FUJI_HDR_VERSION && req->struct_size >= bytes)
        bytes = std::max(bytes, std::min(size_t(req->struct_size), requestSize(req->hdr_processing_version)));
    return overlaps(req, bytes, result, size);
}
bool sourceAliases(const sony2fuji_hdr_image_pair_v1* src, const void* result, size_t size) {
    if (!src || !result) return false;
    if (overlaps(src, sizeof(*src), result, size)) return true;
    if (src->version != 1 || src->struct_size < sizeof(*src)) return false;
    return overlaps(src->hdr.data, src->hdr.size_bytes, result, size) || overlaps(src->sdr.data, src->sdr.size_bytes, result, size);
}
void beginStreamExport(const sony2fuji_hdr_export_config_v1* config, sony2fuji_hdr_stream_result_v1* result,
                       const sony2fuji_hdr_request_v1* request, bool extraAlias, const char* file,
                       const char* temporaryRoot, const char* aliasMsg) {
    header(config, SONY2FUJI_HDR_FIELD_EXPORT); header(result, SONY2FUJI_HDR_FIELD_RESULT);
    if (extraAlias || overlaps(config, sizeof(*config), result, sizeof(*result)) || requestAliases(request, result, sizeof(*result)))
        fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, aliasMsg);
    clearOutput(result); requirePath(file); requirePath(temporaryRoot);
}
void finishStreamExport(sony2fuji_hdr_stream_result_v1* res, const HDRStreamResult& enc,
                        uint32_t nativeW, uint32_t nativeH, uint64_t rev, const SessionLease& session) {
    res->width = enc.width; res->height = enc.height; res->native_width = nativeW; res->native_height = nativeH;
    res->output_native_width = enc.outputNativeWidth; res->output_native_height = enc.outputNativeHeight;
    res->decode_revision = rev; res->source_headroom = enc.sourceHeadroom; res->edited_headroom = enc.editedHeadroom;
    hdrSessionDidRenderCPU(session);
}
hdr::StreamSourceSpec toStreamSpec(const sony2fuji_hdr_stream_source_v1* s) {
    auto checkCb = [](sony2fuji_status st, bool fin) {
        if (st == SONY2FUJI_STATUS_OK) return;
        if (st == SONY2FUJI_STATUS_CANCELLED) throw ProcessingCancelled();
        fail(st == SONY2FUJI_STATUS_OUT_OF_MEMORY ? SONY2FUJI_HDR_REASON_OUT_OF_MEMORY
             : (fin ? SONY2FUJI_HDR_REASON_SOURCE_CHANGED : SONY2FUJI_HDR_REASON_INVALID_BUFFER),
             SONY2FUJI_HDR_FIELD_SOURCE, "Stream source callback failed", st);
    };
    hdr::StreamSourceSpec spec{s->native_width, s->native_height, s->orientation_applied, s->source_intent,
                               s->decode_revision, s->decoder_identifier, {}, {}};
    std::copy_n(s->source_sha256, 32, spec.sourceSha256.begin());
    spec.rows.width = s->native_width; spec.rows.height = s->native_height;
    if (s->read_rows) spec.rows.read = [s, checkCb](bool isHdr, uint32_t r, uint32_t c, RGB* px) {
        static_assert(sizeof(RGB) == 3 * sizeof(float));
        checkCb(s->read_rows(s->context, isHdr ? 1 : 0, r, c, reinterpret_cast<float*>(px)), false);
    };
    if (s->finish_decode) spec.rows.finish = [s, checkCb] { checkCb(s->finish_decode(s->context), true); };
    return spec;
}
struct StreamCancellation {
    ProcessingCancellation session; const sony2fuji_hdr_stream_source_v1* source; ProcessingCancellationScope scope;
    StreamCancellation(const SessionLease& lease, const sony2fuji_hdr_stream_source_v1* s)
        : session(hdrSessionCancellation(lease)), source(s), scope({[](void* opaque) {
              const auto& st = *static_cast<StreamCancellation*>(opaque);
              return st.session.cancelled() || (st.source && st.source->is_cancelled && st.source->is_cancelled(st.source->context)) ? 1 : 0;
          }, this}) {}
};
template <class ProbeFn>
sony2fuji_status probeFileEntry(const char* file, sony2fuji_hdr_source_info_v1* info, sony2fuji_hdr_diagnostic_v1* diag, ProbeFn fn) {
    return boundary(diag, [&] { header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info); requirePath(file); *info = toFfiSourceInfo(fn(file), info->struct_size); });
}
hdr::CameraRawDevelopmentSpec buildCameraRawDevSpec(
    const SessionLease& session,
    const sony2fuji_hdr_camera_development_v1* development,
    bool preview,
    uint32_t longEdge,
    bool ai,
    sony2fuji_hdr_camera_development_v2& profiledOut
) {
    hdr::CameraRawDevelopmentSpec spec;
    spec.preview = preview;
    spec.longEdge = longEdge;
    spec.legacySonyCrop = hdrSessionUsesLegacySonyCrop(session);
    spec.useAi = ai;
    if (ai) {
        spec.aiKeyForFile = [&session](const char* f) { return hdrSessionCameraAIKey(session, f); };
        spec.loadAiOverride = [&session](const std::string& k, const RAWBayerSource& m) { return hdrSessionLoadCameraAI(session, k, m); };
    }
    profiledOut = {};
    if (development) {
        if (development->version == 2 && !ai) {
            if (development->struct_size < sizeof(profiledOut))
                fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "Truncated HDR camera profile configuration");
            std::memcpy(&profiledOut, development, sizeof(profiledOut));
        } else header(development, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT);
        spec.hasDevelopment = true;
        spec.whiteBalance = development->white_balance;
        spec.exposureReference = development->exposure_reference;
        spec.temperature = development->temperature;
        spec.tint = development->tint;
        spec.fbddLevel = development->fbdd_level;
        spec.lensFlags = development->lens_flags;
        spec.lensProfileId = development->lens_profile_id;
        spec.getLensDatabase = [&session] { return hdrSessionLensDatabase(session); };
        if (profiledOut.base.version == 2) {
            spec.hasCameraProfile = true;
            spec.cameraProfilePath = profiledOut.profile_path;
            spec.cameraProfileSha256 = profiledOut.profile_sha256;
        }
    }
    return spec;
}

HDRRoiSpec toCoreRoiSpec(const sony2fuji_hdr_roi_v1* roi) {
    header(roi, SONY2FUJI_HDR_FIELD_REQUEST);
    if ((roi->full_source_width == 0 && roi->full_source_height == 0 && (roi->source_x0 != 0 || roi->source_y0 != 0)) ||
        ((roi->full_source_width == 0) != (roi->full_source_height == 0))) {
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR ROI source sub-rect metadata");
    }
    return {
        roi->norm_x0, roi->norm_y0, roi->norm_x1, roi->norm_y1,
        roi->max_output_long_edge, roi->base_content_headroom,
        roi->source_x0, roi->source_y0, roi->full_source_width, roi->full_source_height
    };
}

void writeRoiResult(const hdr::RoiRenderOutput& output, sony2fuji_hdr_roi_result_v1* out_roi) {
    if (!out_roi) return;
    out_roi->native_x0 = static_cast<uint32_t>(output.bounds.plan.ox0);
    out_roi->native_y0 = static_cast<uint32_t>(output.bounds.plan.oy0);
    out_roi->native_x1 = static_cast<uint32_t>(output.bounds.plan.ox1);
    out_roi->native_y1 = static_cast<uint32_t>(output.bounds.plan.oy1);
    out_roi->full_native_width = static_cast<uint32_t>(output.bounds.plan.fullNativeWidth);
    out_roi->full_native_height = static_cast<uint32_t>(output.bounds.plan.fullNativeHeight);
    out_roi->is_proxy = output.isProxy ? 1u : 0u;
}

sony2fuji_status decodeCameraRawEntry(sony2fuji_session* sessionHandle, const char* file, const sony2fuji_hdr_decode_options_v1* options,
                                      const sony2fuji_hdr_camera_development_v1* development, bool ai,
                                      sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        prepareOutput(result); SessionLease session;
        requireCpuSession(sessionHandle, session, "Camera RAW HDR development is CPU only", true);
        header(options, SONY2FUJI_HDR_FIELD_REQUEST); requirePath(file);
        hdr::validateDecodeSize(options->intent, options->long_edge, true);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        sony2fuji_hdr_camera_development_v2 profiled{};
        const auto spec = buildCameraRawDevSpec(session, development, options->intent == SONY2FUJI_INTENT_PREVIEW,
            options->long_edge, ai, profiled);
        auto decoded = hdr::decodeCameraRaw(file, spec);
        hdr::ExportSourceMetadata meta{{}, file, {}, decoded.usedCameraProfile ? profiled.profile_path : ""};
        publishPair(std::move(decoded.pixels), 0.0f, 0.0f, decoded.sourceHeadroomKind, std::move(meta), result);
        reportHdrProgress(1000, 1000);
        if (session) hdrSessionDidRenderCPU(session);
    });
}

CanonicalEditState parseHdrJsonState(const char* editStateJson, bool requireHdr = true) {
    CanonicalEditState state;
    if (!editStateJson) {
        state.isHdr = true;
        state.schemaVersion = 16;
        return state;
    }
    if (!*editStateJson) {
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Empty HDR edit state JSON");
    }
    std::string error;
    if (!parseCanonicalEditState(editStateJson, state, error, {RecipeParseMode::SessionState, true})) {
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, error.c_str());
    }
    if (requireHdr && !state.isHdr) {
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Expected HDR CanonicalEditState JSON");
    }
    return state;
}

void parseHdrExecOptions(
    const sony2fuji_hdr_render_options_v1* options,
    HDRQuality& outIntent,
    uint32_t& outLongEdge
) {
    if (!options) {
        outIntent = HDRQuality::Final;
        outLongEdge = 0;
        return;
    }
    header(options, SONY2FUJI_HDR_FIELD_REQUEST);
    if (options->intent > SONY2FUJI_INTENT_FINAL) {
        fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR render intent");
    }
    outIntent = static_cast<HDRQuality>(options->intent);
    outLongEdge = options->long_edge;
}

HDRRenderOptions buildHdrRenderOptionsFromJson(
    const sony2fuji_hdr_render_options_v1* execOptions,
    const char* editStateJson,
    const SessionLease* session,
    bool loadLook,
    std::string* outLookPath,
    CanonicalEditState* outState = nullptr
) {
    HDRQuality intent = HDRQuality::Final;
    uint32_t longEdge = 0;
    parseHdrExecOptions(execOptions, intent, longEdge);
    CanonicalEditState state = parseHdrJsonState(editStateJson, true);
    if (loadLook && session && !state.lookPath.empty() &&
        state.hdr.processingVersion >= kHdrProcessingLookVersion) {
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(*session));
        auto opts = state.toHdrRenderOptions(intent, longEdge, true);
        if (outLookPath && opts.look) *outLookPath = state.lookPath;
        if (outState) *outState = std::move(state);
        return opts;
    }
    auto opts = state.toHdrRenderOptions(intent, longEdge, loadLook);
    if (outLookPath && opts.look) *outLookPath = state.lookPath;
    if (outState) *outState = std::move(state);
    return opts;
}

hdr::CameraRawDevelopmentSpec buildCameraRawDevSpecFromState(
    const SessionLease& session,
    const CanonicalEditState& state,
    bool preview,
    uint32_t longEdge,
    std::string& outProfilePath
) {
    outProfilePath.clear();
    auto spec = state.toCameraRawDevSpec(preview, longEdge, hdrSessionUsesLegacySonyCrop(session));
    if (spec.hasDevelopment) {
        if (spec.lensFlags) {
            spec.getLensDatabase = [&session] { return hdrSessionLensDatabase(session); };
        }
        if (spec.hasCameraProfile && spec.cameraProfilePath) {
            outProfilePath = spec.cameraProfilePath;
        }
        if (spec.useAi) {
            spec.aiKeyForFile = [&session](const char* f) { return hdrSessionCameraAIKey(session, f); };
            spec.loadAiOverride = [&session](const std::string& k, const RAWBayerSource& m) {
                return hdrSessionLoadCameraAI(session, k, m);
            };
        }
    }
    return spec;
}

bool validateHdrFloatSourceFor8Bit(const sony2fuji_hdr_buffer_v1* source, sony2fuji_status& outError) noexcept {
    if (source->version != SONY2FUJI_HDR_VERSION) {
        outError = SONY2FUJI_STATUS_UNSUPPORTED;
        return false;
    }
    if (source->struct_size < sizeof(*source) || !source->data ||
        source->width == 0 || source->height == 0 ||
        source->width > UINT32_MAX / 4u ||
        source->height > static_cast<uint32_t>(std::numeric_limits<int>::max()) ||
        static_cast<uint64_t>(source->width) * static_cast<uint64_t>(source->height) > UINT32_MAX ||
        source->pixel_format != SONY2FUJI_HDR_RGB32F_LINEAR ||
        source->color_encoding != SONY2FUJI_HDR_LINEAR_SRGB) {
        outError = SONY2FUJI_STATUS_INVALID_ARGUMENT;
        return false;
    }
    const uint64_t rowBytes = static_cast<uint64_t>(source->width) * 3u * sizeof(float);
    if (source->stride_bytes < rowBytes ||
        (source->height > 1u &&
         source->stride_bytes > (std::numeric_limits<uint64_t>::max() - rowBytes) / (source->height - 1u))) {
        outError = SONY2FUJI_STATUS_INVALID_ARGUMENT;
        return false;
    }
    const uint64_t requiredBytes = static_cast<uint64_t>(source->height - 1u) * source->stride_bytes + rowBytes;
    if (requiredBytes > source->size_bytes || source->size_bytes > std::numeric_limits<size_t>::max()) {
        outError = SONY2FUJI_STATUS_INVALID_ARGUMENT;
        return false;
    }
    return true;
}

sony2fuji_status encodeHdrDisplay8Buffer(
    const sony2fuji_hdr_buffer_v1* source,
    bool bgra,
    sony2fuji_buffer* outBuf
) noexcept {
    if (!outBuf || !source || overlaps(source, sizeof(*source), outBuf, sizeof(*outBuf))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (source->struct_size >= sizeof(*source) && source->data && source->size_bytes > 0 &&
        overlaps(source->data, source->size_bytes, outBuf, sizeof(*outBuf))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *outBuf = {};
    sony2fuji_status err = SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (!validateHdrFloatSourceFor8Bit(source, err)) {
        return err;
    }
    try {
        sony2fuji::OwnedPixelBuffer owned;
        const auto status = sony2fuji::encodeDisplay8BufferFromFloatRgb(
            static_cast<const float*>(source->data),
            source->width,
            source->height,
            source->stride_bytes,
            bgra,
            owned);
        if (status != sony2fuji::RenderStatus::Ok) {
            return toFfiStatus(status);
        }
        *outBuf = toFfiBuffer(owned);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

// 显示统计与映射按 float 索引行，因此另需 4 字节对齐与 128MP 栅格上限。
bool validateHdrDisplayPlane(const sony2fuji_hdr_buffer_v1* plane, sony2fuji_status& outError) noexcept {
    if (!plane) {
        outError = SONY2FUJI_STATUS_INVALID_ARGUMENT;
        return false;
    }
    if (!validateHdrFloatSourceFor8Bit(plane, outError)) return false;
    if (uint64_t(plane->width) * plane->height > 128000000u || plane->stride_bytes % sizeof(float) != 0 ||
        reinterpret_cast<uintptr_t>(plane->data) % alignof(float) != 0) {
        outError = SONY2FUJI_STATUS_INVALID_ARGUMENT;
        return false;
    }
    return true;
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
        HDRRenderOptions opts; opts.temperature = temperature; opts.tint = tint; validateHDRRenderOptions(opts);
        if (!source->owner_token) hdr::admitMemory(uint64_t(source->hdr.width) * source->hdr.height * 2 * sizeof(RGB));
        *exposure = hdr::estimateAutoExposureEV(readPair(source)->pixels.hdr, temperature, tint);
    });
}

sony2fuji_status sony2fuji_hdr_geometry_size(uint32_t nativeWidth, uint32_t nativeHeight,
    const sony2fuji_hdr_request_v1* request, uint32_t* width, uint32_t* height, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        validateRequestVersion(request);
        if (!width || !height || width == height || !nativeWidth || !nativeHeight ||
            uint64_t(nativeWidth) * nativeHeight > 128000000 || request->flip_horizontal > 1 || request->flip_vertical > 1)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR geometry dimensions");
        const GeometryOptions geo{request->crop_x, request->crop_y, request->crop_width, request->crop_height,
            request->quarter_turns, request->flip_horizontal != 0, request->flip_vertical != 0,
            request->straighten_degrees, request->perspective_horizontal, request->perspective_vertical};
        std::tie(*width, *height) = hdr::computeGeometryOutputSize(nativeWidth, nativeHeight, geo);
    });
}

sony2fuji_status sony2fuji_hdr_render(sony2fuji_session* sessionHandle, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (sourceAliases(source, result, sizeof(*result)) || requestAliases(request, result, sizeof(*result)))
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        prepareOutput(result); SessionLease session; requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        validateRequestVersion(request);
        auto input = readPair(source); std::string lookPath;
        const auto options = parseRenderOptions(request, session, &lookPath);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        auto rendered = hdr::renderPair(input->pixels, source->owner_token != 0, options);
        auto meta = input->meta; meta.lookPath = std::move(lookPath);
        const float hdrH = rendered.editedHeadroom, sdrH = rendered.editedSdrHeadroom;
        publishPair(std::move(rendered), hdrH, sdrH, input->sourceHeadroomKind, std::move(meta), result);
        reportHdrProgress(1000, 1000);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_encode_rgba16(
    const sony2fuji_hdr_buffer_v1* source,
    sony2fuji_buffer* out_rgba16
) {
    if (!out_rgba16 || !source || overlaps(source, sizeof(*source), out_rgba16, sizeof(*out_rgba16))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (source->struct_size >= sizeof(*source) && source->data && source->size_bytes > 0 &&
        overlaps(source->data, source->size_bytes, out_rgba16, sizeof(*out_rgba16))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *out_rgba16 = {};
    if (source->version != SONY2FUJI_HDR_VERSION) {
        return SONY2FUJI_STATUS_UNSUPPORTED;
    }
    if (source->struct_size < sizeof(*source) || !source->data ||
        source->width == 0 || source->height == 0 ||
        source->width > UINT32_MAX / 8u ||
        static_cast<uint64_t>(source->width) * static_cast<uint64_t>(source->height) > UINT32_MAX ||
        source->pixel_format != SONY2FUJI_HDR_RGB32F_LINEAR ||
        source->color_encoding != SONY2FUJI_HDR_LINEAR_SRGB) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint64_t rowBytes = static_cast<uint64_t>(source->width) * 3u * sizeof(float);
    if (source->stride_bytes < rowBytes ||
        (source->height > 1u &&
         source->stride_bytes > (std::numeric_limits<uint64_t>::max() - rowBytes) / (source->height - 1u))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint64_t requiredBytes = static_cast<uint64_t>(source->height - 1u) * source->stride_bytes + rowBytes;
    if (requiredBytes > source->size_bytes || source->size_bytes > std::numeric_limits<size_t>::max()) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        sony2fuji::OwnedPixelBuffer rgba16 = sony2fuji::encodeRgba16BufferFromFloatRgb(
            static_cast<const float*>(source->data),
            source->width,
            source->height,
            source->stride_bytes,
            /*linearToSrgb=*/true);
        if (!rgba16.data) {
            return SONY2FUJI_STATUS_OUT_OF_MEMORY;
        }
        *out_rgba16 = toFfiBuffer(rgba16);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_hdr_encode_rgba8(
    const sony2fuji_hdr_buffer_v1* source,
    sony2fuji_buffer* out_rgba8
) {
    return encodeHdrDisplay8Buffer(source, /*bgra=*/false, out_rgba8);
}

sony2fuji_status sony2fuji_hdr_encode_bgra8(
    const sony2fuji_hdr_buffer_v1* source,
    sony2fuji_buffer* out_bgra8
) {
    return encodeHdrDisplay8Buffer(source, /*bgra=*/true, out_bgra8);
}

sony2fuji_status sony2fuji_hdr_encode_rgba8_into(
    const sony2fuji_hdr_buffer_v1* source,
    void* dst,
    uint64_t dst_size_bytes,
    uint64_t dst_stride_bytes
) {
    if (!source || !dst || overlaps(source, sizeof(*source), dst, dst_size_bytes)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji_status err = SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (!validateHdrFloatSourceFor8Bit(source, err)) {
        return err;
    }
    if (overlaps(source->data, source->size_bytes, dst, dst_size_bytes)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        return toFfiStatus(sony2fuji::encodeDisplay8IntoFloatRgb(
            static_cast<const float*>(source->data),
            source->width,
            source->height,
            source->stride_bytes,
            /*bgra=*/false,
            dst,
            dst_size_bytes,
            dst_stride_bytes));
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_hdr_analyze_luminance(
    const sony2fuji_hdr_buffer_v1* image,
    uint32_t* ev_bins,
    uint32_t* above_white,
    float* peak_luminance
) {
    if (!ev_bins || !above_white || !peak_luminance) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    sony2fuji_status err = SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (!validateHdrDisplayPlane(image, err)) return err;
    try {
        hdr::LuminanceStatistics stats;
        if (!hdr::analyzeLuminance(static_cast<const float*>(image->data), image->width, image->height,
                static_cast<size_t>(image->stride_bytes / sizeof(float)), stats)) {
            return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        }
        std::copy(std::begin(stats.bins), std::end(stats.bins), ev_bins);
        *above_white = stats.aboveWhite;
        *peak_luminance = stats.peak;
        return SONY2FUJI_STATUS_OK;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_hdr_display_into(
    const sony2fuji_hdr_buffer_v1* hdrPlane,
    const sony2fuji_hdr_buffer_v1* sdrPlane,
    float display_headroom,
    float content_headroom,
    uint32_t flags,
    void* dst,
    uint64_t dst_size_bytes,
    uint64_t dst_stride_bytes
) {
    static_assert(hdr::kDisplaySdr == SONY2FUJI_HDR_DISPLAY_SDR && hdr::kDisplayFalseColor == SONY2FUJI_HDR_DISPLAY_FALSE_COLOR &&
        hdr::kDisplayP3 == SONY2FUJI_HDR_DISPLAY_P3 && hdr::kDisplayClampSdr == SONY2FUJI_HDR_DISPLAY_CLAMP_SDR &&
        hdr::kDisplayBgra8Srgb == SONY2FUJI_HDR_DISPLAY_BGRA8_SRGB, "HDR display flags");
    const bool falseColor = (flags & SONY2FUJI_HDR_DISPLAY_FALSE_COLOR) != 0;
    if (!dst || (flags & ~uint32_t(hdr::kDisplayAllFlags)) != 0 || (!sdrPlane && !falseColor) ||
        !std::isfinite(content_headroom) || content_headroom < 1.0f) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    sony2fuji_status err = SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (!validateHdrDisplayPlane(hdrPlane, err) || (sdrPlane && !validateHdrDisplayPlane(sdrPlane, err))) return err;
    if (sdrPlane && (sdrPlane->width != hdrPlane->width || sdrPlane->height != hdrPlane->height)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint64_t rowBytes = uint64_t(hdrPlane->width) * ((flags & SONY2FUJI_HDR_DISPLAY_BGRA8_SRGB) ? 4u : 8u);
    if (dst_stride_bytes < rowBytes ||
        (hdrPlane->height > 1u &&
         dst_stride_bytes > (std::numeric_limits<uint64_t>::max() - rowBytes) / (hdrPlane->height - 1u)) ||
        uint64_t(hdrPlane->height - 1u) * dst_stride_bytes + rowBytes > dst_size_bytes ||
        dst_size_bytes > std::numeric_limits<size_t>::max() ||
        overlaps(hdrPlane->data, hdrPlane->size_bytes, dst, dst_size_bytes) ||
        (sdrPlane && overlaps(sdrPlane->data, sdrPlane->size_bytes, dst, dst_size_bytes))) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    try {
        hdr::DisplayPlanes planes;
        planes.hdr = static_cast<const float*>(hdrPlane->data);
        planes.hdrStride = static_cast<size_t>(hdrPlane->stride_bytes / sizeof(float));
        if (sdrPlane) {
            planes.sdr = static_cast<const float*>(sdrPlane->data);
            planes.sdrStride = static_cast<size_t>(sdrPlane->stride_bytes / sizeof(float));
        }
        planes.dst = static_cast<uint8_t*>(dst);
        planes.dstStride = static_cast<size_t>(dst_stride_bytes);
        planes.width = hdrPlane->width;
        planes.height = hdrPlane->height;
        switch (hdr::mapDisplay(planes, display_headroom, content_headroom, flags)) {
            case hdr::DisplayResult::Ok: return SONY2FUJI_STATUS_OK;
            case hdr::DisplayResult::NonFinite: return SONY2FUJI_STATUS_INVALID_ARGUMENT;
            case hdr::DisplayResult::Unrepresentable: return SONY2FUJI_STATUS_PROCESSING_ERROR;
        }
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_hdr_create_hsl_probe(sony2fuji_session* sessionHandle, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, uint64_t sourceRevision, uint64_t requestRevision,
    sony2fuji_hsl_probe** outProbe, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (!outProbe || sourceAliases(source, outProbe, sizeof(*outProbe)) || requestAliases(request, outProbe, sizeof(*outProbe)))
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_RESULT, "Invalid HDR probe output");
        *outProbe = nullptr; SessionLease session; requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        const auto options = parseRenderOptions(request, session);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto probe = hdr::createHslProbeImage(readPair(source)->pixels, source->owner_token != 0, options);
        *outProbe = makeHDRHslProbe(std::move(probe), sourceRevision, requestRevision, options.intent == HDRQuality::Preview);
    });
}

sony2fuji_status sony2fuji_hdr_probe(const char* f, sony2fuji_hdr_source_info_v1* i, sony2fuji_hdr_diagnostic_v1* d) { return probeFileEntry(f, i, d, hdr::probeFile); }
sony2fuji_status sony2fuji_hdr_probe_proraw(const char* f, sony2fuji_hdr_source_info_v1* i, sony2fuji_hdr_diagnostic_v1* d) { return probeFileEntry(f, i, d, hdr::probeProRAW); }
sony2fuji_status sony2fuji_hdr_probe_apple_proraw(const char* f, sony2fuji_hdr_source_info_v1* i, sony2fuji_hdr_diagnostic_v1* d) {
#if defined(__APPLE__)
    return probeFileEntry(f, i, d, hdr::probeAppleProRAW);
#else
    return boundary(d, [&] {
        header(i, SONY2FUJI_HDR_FIELD_RESULT);
        clearOutput(i);
        requirePath(f);
        fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM, SONY2FUJI_HDR_FIELD_SOURCE,
             "Apple ProRAW probing requires an Apple runtime", SONY2FUJI_STATUS_UNSUPPORTED);
    });
#endif
}
sony2fuji_status sony2fuji_hdr_probe_camera_raw(const char* f, sony2fuji_hdr_source_info_v1* i, sony2fuji_hdr_diagnostic_v1* d) { return sony2fuji_hdr_probe_camera_raw_with_processing(f, SONY2FUJI_PROCESSING_LEGACY, i, d); }

sony2fuji_status sony2fuji_hdr_probe_look(const char* file, sony2fuji_hdr_look_info_v1* info, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info);
        const auto look = hdr::loadLookResource(file);
        info->grid_size = uint32_t(look->gridSize());
        const auto &low = look->domainMin(), &high = look->domainMax();
        info->domain_min[0] = low.r; info->domain_min[1] = low.g; info->domain_min[2] = low.b;
        info->domain_max[0] = high.r; info->domain_max[1] = high.g; info->domain_max[2] = high.b;
        std::copy_n(look->fingerprint().begin(), 64, info->sha256);
    });
}

sony2fuji_status sony2fuji_hdr_probe_camera_profile(const char* file, sony2fuji_hdr_camera_profile_info_v1* info, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info);
        const auto res = hdr::loadCameraProfileResource(file);
        std::copy_n(res.profile.cameraModel.data(), std::min(res.profile.cameraModel.size(), sizeof(info->camera_model) - 1), info->camera_model);
        std::copy_n(res.digest.c_str(), 65, info->sha256);
    });
}

sony2fuji_status sony2fuji_hdr_decode_with_session(sony2fuji_session* sessionHandle, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        prepareOutput(result); header(options, SONY2FUJI_HDR_FIELD_REQUEST); requirePath(file);
        SessionLease session; requireSession(sessionHandle, session, true);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        hdr::validateDecodeSize(options->intent, options->long_edge, false);
        reportHdrProgress(0, 1000);
        publishDecoded(hdr::decodeFile(file, {options->intent, options->long_edge}), file, result);
        reportHdrProgress(1000, 1000);
    });
}

sony2fuji_status sony2fuji_hdr_decode(const char* file, const sony2fuji_hdr_decode_options_v1* options,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return sony2fuji_hdr_decode_with_session(nullptr, file, options, result, diagnostic);
}

sony2fuji_status sony2fuji_hdr_probe_camera_raw_with_processing(const char* file, sony2fuji_processing_version processing,
    sony2fuji_hdr_source_info_v1* info, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(info, SONY2FUJI_HDR_FIELD_RESULT); clearOutput(info); requirePath(file);
        const auto probed = hdr::probeCameraRaw(file, static_cast<ProcessingVersion>(processing));
        info->container = SONY2FUJI_HDR_CONTAINER_CAMERA_RAW; info->color_description = SONY2FUJI_HDR_COLOR_SRGB;
        info->width = probed.width; info->height = probed.height; info->orientation = 1;
        if (info->struct_size >= sizeof(sony2fuji_hdr_camera_source_info_v1)) {
            const uint32_t caps = probed.supportsNoiseReduction ? SONY2FUJI_HDR_CAMERA_SOURCE_BAYER : 0;
            std::memcpy(reinterpret_cast<unsigned char*>(info) + offsetof(sony2fuji_hdr_camera_source_info_v1, capabilities), &caps, sizeof(caps));
        }
    });
}

sony2fuji_status sony2fuji_hdr_decode_camera_raw(sony2fuji_session* s, const char* f, const sony2fuji_hdr_decode_options_v1* o,
    sony2fuji_hdr_image_pair_v1* r, sony2fuji_hdr_diagnostic_v1* d) { return decodeCameraRawEntry(s, f, o, nullptr, false, r, d); }
sony2fuji_status sony2fuji_hdr_decode_camera_raw_with_development(sony2fuji_session* s, const char* f, const sony2fuji_hdr_decode_options_v1* o,
    const sony2fuji_hdr_camera_development_v1* dev, sony2fuji_hdr_image_pair_v1* r, sony2fuji_hdr_diagnostic_v1* d) { return decodeCameraRawEntry(s, f, o, dev, false, r, d); }
sony2fuji_status sony2fuji_hdr_decode_camera_raw_with_ai(sony2fuji_session* s, const char* f, const sony2fuji_hdr_decode_options_v1* o,
    const sony2fuji_hdr_camera_development_v1* dev, sony2fuji_hdr_image_pair_v1* r, sony2fuji_hdr_diagnostic_v1* d) { return decodeCameraRawEntry(s, f, o, dev, true, r, d); }

sony2fuji_status sony2fuji_hdr_prepare_camera_raw_ai(sony2fuji_session* sessionHandle, const char* file,
    sony2fuji_ai_progress_callback progress, void* context, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        SessionLease session; requireCpuSession(sessionHandle, session, "Camera RAW HDR development is CPU only", true);
        requirePath(file);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        hdrSessionPrepareCameraAI(session, file, hdr::stampCameraRawFile(std::filesystem::u8path(file)).size, progress, context);
    });
}

sony2fuji_status sony2fuji_hdr_camera_ai_key(sony2fuji_session* sessionHandle, const char* file,
    char* key, uint32_t capacity, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (!key || capacity < 65) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_RESULT, "Truncated HDR camera AI key buffer");
        key[0] = '\0'; requirePath(file);
        SessionLease session; requireSession(sessionHandle, session, true);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        hdr::stampCameraRawFile(std::filesystem::u8path(file));
        std::memcpy(key, hdrSessionCameraAIKey(session, file).c_str(), 65);
    });
}

sony2fuji_status sony2fuji_hdr_decode_proraw(sony2fuji_session* sessionHandle, const char* file,
    const sony2fuji_hdr_decode_options_v1* options, const char* temporaryRoot,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        prepareOutput(result); header(options, SONY2FUJI_HDR_FIELD_REQUEST); requirePath(file); requirePath(temporaryRoot);
        SessionLease session; requireCpuSession(sessionHandle, session, "ProRAW development is CPU only", true);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        publishDecoded(hdr::decodeProRAW(file, {options->intent, options->long_edge}, std::filesystem::u8path(temporaryRoot)), file, result);
        reportHdrProgress(1000, 1000);
        if (session) hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_export_proraw(sony2fuji_session* sessionHandle, const char* sourceFile,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_export_config_v1* config,
    uint32_t keepHDR, const char* temporaryRoot, const char* file,
    sony2fuji_hdr_stream_result_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        beginStreamExport(config, result, request, false, file, temporaryRoot, "ProRAW result aliases input");
        requirePath(sourceFile); requirePath(config->metadata_source_path);
        SessionLease session; requireCpuSession(sessionHandle, session, "ProRAW development is CPU only");
        std::string lookPath;
        const auto options = parseRenderOptions(request, session, &lookPath);
        if (keepHDR > 1) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT, "Invalid ProRAW export configuration");
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        reportHdrProgress(0, 1000);
        const auto exported = hdr::exportProRAWStream(sourceFile, options, lookPath, toCoreExportConfig(*config),
                                                      keepHDR != 0, temporaryRoot, file);
        reportHdrProgress(1000, 1000);
        finishStreamExport(result, exported.stream, exported.nativeWidth, exported.nativeHeight, hdr::portableProRAWRevision, session);
    });
}

sony2fuji_status sony2fuji_hdr_export_jpeg_with_session(sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* image, const sony2fuji_hdr_export_config_v1* config,
    const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT); requirePath(file);
        SessionLease session; requireSession(sessionHandle, session, true);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        auto owned = readPair(image);
        hdr::exportImagePairJPEG(owned->pixels, owned->meta, toCoreExportConfig(*config), file);
        reportHdrProgress(1000, 1000);
    });
}

sony2fuji_status sony2fuji_hdr_export_jpeg(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1* config, const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return sony2fuji_hdr_export_jpeg_with_session(nullptr, image, config, file, diagnostic);
}

uint32_t sony2fuji_hdr_heif_export_available(void) { return hdr::heifExportAvailable() ? 1 : 0; }

sony2fuji_status sony2fuji_hdr_export_heif_with_session(sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* image, const sony2fuji_hdr_export_config_v1* config,
    const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT); requirePath(file); header(image, SONY2FUJI_HDR_FIELD_SOURCE);
        SessionLease session; requireSession(sessionHandle, session, true);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        const auto coreCfg = toCoreExportConfig(*config);
        const bool borrowed = !image->owner_token;
        if (borrowed) {
            const auto hdrD = toBufferDescriptor(image->hdr, SONY2FUJI_HDR_FIELD_HDR_BUFFER);
            const auto sdrD = toBufferDescriptor(image->sdr, SONY2FUJI_HDR_FIELD_SDR_BUFFER);
            hdr::prepareHEIFExport(coreCfg, &hdrD, &sdrD);
        } else hdr::prepareHEIFExport(coreCfg, nullptr, nullptr);
        auto owned = readPair(image);
        hdr::exportImagePairHEIF(owned->pixels, owned->meta, coreCfg, file, borrowed);
        reportHdrProgress(1000, 1000);
    });
}

sony2fuji_status sony2fuji_hdr_export_heif(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1* config, const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return sony2fuji_hdr_export_heif_with_session(nullptr, image, config, file, diagnostic);
}

sony2fuji_status sony2fuji_hdr_export_sdr_with_session(sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* image, const sony2fuji_hdr_sdr_export_config_v1* config,
    const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT); requirePath(file);
        SessionLease session; requireSession(sessionHandle, session, true);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        auto owned = readPair(image);
        HDRSdrExportConfig coreCfg{config->output_format, config->quality, config->metadata_source_path, {}};
        std::copy_n(config->source_sha256, 32, coreCfg.sourceSha256);
        hdr::exportImagePairSDR(owned->pixels, owned->meta, coreCfg, file);
        reportHdrProgress(1000, 1000);
    });
}

sony2fuji_status sony2fuji_hdr_export_sdr(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_sdr_export_config_v1* config, const char* file, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return sony2fuji_hdr_export_sdr_with_session(nullptr, image, config, file, diagnostic);
}

sony2fuji_status sony2fuji_hdr_export_stream(sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_stream_source_v1* source, const sony2fuji_hdr_request_v1* request,
    const sony2fuji_hdr_export_config_v1* config, uint32_t keepHDR, const char* temporaryRoot,
    const char* file, sony2fuji_hdr_stream_result_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(source, SONY2FUJI_HDR_FIELD_SOURCE);
        beginStreamExport(config, result, request, overlaps(source, sizeof(*source), result, sizeof(*result)),
                          file, temporaryRoot, "Stream result aliases input");
        requirePath(config->metadata_source_path);
        SessionLease session; requireCpuSession(sessionHandle, session, "Streamed HDR processing is CPU only");
        std::string lookPath;
        const auto options = parseRenderOptions(request, session, &lookPath);
        if (keepHDR > 1) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE, "Incomplete stream source or export configuration");
        StreamCancellation cancellation(session, source);
        const HdrProgressScope progress(hdrSessionProgress(session));
        reportHdrProgress(0, 1000);
        const auto encoded = hdr::exportRowStream(toStreamSpec(source), options, lookPath, toCoreExportConfig(*config),
                                                  keepHDR != 0, temporaryRoot, file);
        reportHdrProgress(1000, 1000);
        finishStreamExport(result, encoded, source->native_width, source->native_height, source->decode_revision, session);
    });
}

sony2fuji_status sony2fuji_hdr_export_tiled(sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* source, const sony2fuji_hdr_stream_source_v1* stream, const char* sourceFile,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_export_config_v1* config,
    uint32_t format, const char* temporaryRoot, const char* file,
    sony2fuji_hdr_stream_result_v1* result, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
#if defined(__APPLE__)
        if (source && stream) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE, "Specify one tiled source representation");
        if (stream) header(stream, SONY2FUJI_HDR_FIELD_SOURCE);
        const bool srcAlias = (source && sourceAliases(source, result, sizeof(*result))) ||
            (stream && overlaps(stream, sizeof(*stream), result, sizeof(*result)));
        beginStreamExport(config, result, request, srcAlias, file, temporaryRoot, "Tiled result aliases input");
        requirePath(sourceFile);
        SessionLease session; requireCpuSession(sessionHandle, session, "Tiled HDR processing is CPU only");
        std::string lookPath;
        const auto options = parseRenderOptions(request, session, &lookPath);
        if (format != SONY2FUJI_HDR_TILED_HEIF && format != SONY2FUJI_HDR_TILED_SDR_DNG)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT, "Invalid tiled export configuration");
        StreamCancellation cancellation(session, stream); checkProcessingCancellation();
        const HdrProgressScope progress(hdrSessionProgress(session));
        reportHdrProgress(0, 1000);
        std::shared_ptr<hdr::OwnedPairRecord> ownedCamera; hdr::StreamSourceSpec streamSpec; hdr::TiledSourceInput input{};
        if (source) {
            header(source, SONY2FUJI_HDR_FIELD_SOURCE);
            if (!source->owner_token || config->metadata_source_path)
                fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE, "Tiled RAW export requires an owned camera source without copied metadata");
            ownedCamera = readPair(source);
            input.ownedCameraPixels = &ownedCamera->pixels; input.ownedCameraMeta = &ownedCamera->meta;
        } else if (stream) {
            streamSpec = toStreamSpec(stream); input.stream = &streamSpec;
        }
        const auto exported = hdr::exportTiledStream(input, sourceFile, options, lookPath, toCoreExportConfig(*config),
                                                     format == SONY2FUJI_HDR_TILED_HEIF, temporaryRoot, file);
        reportHdrProgress(1000, 1000);
        finishStreamExport(result, exported.stream, exported.sourceWidth, exported.sourceHeight, exported.decodeRevision, session);
#else
        (void)sessionHandle; (void)source; (void)stream; (void)sourceFile; (void)request;
        (void)config; (void)format; (void)temporaryRoot; (void)file; (void)result;
        fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM, SONY2FUJI_HDR_FIELD_EXPORT, "Tiled HDR file export requires an Apple runtime", SONY2FUJI_STATUS_UNSUPPORTED);
#endif
    });
}

sony2fuji_status sony2fuji_hdr_roi_source_bounds(uint32_t native_width, uint32_t native_height,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_roi_source_bounds_v1* out_bounds, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        header(out_bounds, SONY2FUJI_HDR_FIELD_RESULT);
        if (requestAliases(request, out_bounds, sizeof(*out_bounds)) ||
            overlaps(roi, sizeof(*roi), out_bounds, sizeof(*out_bounds))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI bounds alias input");
        }
        clearOutput(out_bounds);
        validateRequestVersion(request);
        if (request->flip_horizontal > 1 || request->flip_vertical > 1) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR flip");
        }
        const auto roiSpec = toCoreRoiSpec(roi);
        HDRRenderOptions options;
        options.processingVersion = request->hdr_processing_version;
        options.geometry = {request->crop_x, request->crop_y, request->crop_width, request->crop_height,
            request->quarter_turns, request->flip_horizontal != 0, request->flip_vertical != 0,
            request->straighten_degrees, request->perspective_horizontal, request->perspective_vertical};
        options.intent = static_cast<HDRQuality>(request->intent);
        options.longEdge = request->long_edge;
        if (options.processingVersion >= SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION) {
            const auto e = readExt<sony2fuji_hdr_request_v6>(request);
            options.detail = {e.sharpening, e.clarity, e.dehaze, e.denoise};
        }
        const auto bounds = computeHDRRoiSourceBounds(native_width, native_height, options, roiSpec);
        out_bounds->source_x0 = static_cast<uint32_t>(bounds.sourceRect.x0);
        out_bounds->source_y0 = static_cast<uint32_t>(bounds.sourceRect.y0);
        out_bounds->source_x1 = static_cast<uint32_t>(bounds.sourceRect.x1);
        out_bounds->source_y1 = static_cast<uint32_t>(bounds.sourceRect.y1);
        out_bounds->native_x0 = static_cast<uint32_t>(bounds.plan.ox0);
        out_bounds->native_y0 = static_cast<uint32_t>(bounds.plan.oy0);
        out_bounds->native_x1 = static_cast<uint32_t>(bounds.plan.ox1);
        out_bounds->native_y1 = static_cast<uint32_t>(bounds.plan.oy1);
        out_bounds->full_native_width = static_cast<uint32_t>(bounds.plan.fullNativeWidth);
        out_bounds->full_native_height = static_cast<uint32_t>(bounds.plan.fullNativeHeight);
        out_bounds->output_width = static_cast<uint32_t>(bounds.plan.outputWidth);
        out_bounds->output_height = static_cast<uint32_t>(bounds.plan.outputHeight);
    });
}

sony2fuji_status sony2fuji_hdr_render_roi(sony2fuji_session* sessionHandle, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (sourceAliases(source, result, sizeof(*result)) || requestAliases(request, result, sizeof(*result)) ||
            overlaps(roi, sizeof(*roi), result, sizeof(*result))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        }
        if (out_roi) {
            header(out_roi, SONY2FUJI_HDR_FIELD_RESULT);
            if (sourceAliases(source, out_roi, sizeof(*out_roi)) ||
                requestAliases(request, out_roi, sizeof(*out_roi)) ||
                overlaps(roi, sizeof(*roi), out_roi, sizeof(*out_roi)) ||
                overlaps(result, sizeof(*result), out_roi, sizeof(*out_roi))) {
                fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI metadata aliases buffer");
            }
            clearOutput(out_roi);
        }
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        validateRequestVersion(request);
        const auto roiSpec = toCoreRoiSpec(roi);
        auto input = readPair(source);
        std::string lookPath;
        const auto options = parseRenderOptions(request, session, &lookPath);
        const ProcessingCancellationScope cancellation(
            options.hasPhotoEffects() || options.hasDetail() || options.look ? hdrSessionCancellation(session) : ProcessingCancellation{});
        auto output = hdr::renderPairROI(input->pixels, lookPath, input->meta, input->sourceHeadroomKind, options, roiSpec);
        writeRoiResult(output, out_roi);
        publishPair(std::move(output.pixels), output.hdrHeadroom, output.sdrHeadroom, output.sourceHeadroomKind, std::move(output.meta), result);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_render_camera_raw_roi(sony2fuji_session* sessionHandle, const char* file,
    const sony2fuji_hdr_camera_development_v1* development, uint32_t use_ai,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (requestAliases(request, result, sizeof(*result)) ||
            overlaps(roi, sizeof(*roi), result, sizeof(*result)) ||
            overlaps(development, sizeof(*development), result, sizeof(*result))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        }
        if (out_roi) {
            header(out_roi, SONY2FUJI_HDR_FIELD_RESULT);
            if (requestAliases(request, out_roi, sizeof(*out_roi)) ||
                overlaps(roi, sizeof(*roi), out_roi, sizeof(*out_roi)) ||
                overlaps(result, sizeof(*result), out_roi, sizeof(*out_roi))) {
                fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI metadata aliases buffer");
            }
            clearOutput(out_roi);
        }
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        requirePath(file);
        if (use_ai > 1) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_CAMERA_DEVELOPMENT, "Invalid AI flag");
        validateRequestVersion(request);
        const auto roiSpec = toCoreRoiSpec(roi);
        if (roiSpec.fullSourceWidth != 0 || roiSpec.fullSourceHeight != 0) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Camera RAW ROI cannot use pre-cropped source metadata");
        }
        std::string lookPath;
        const auto options = parseRenderOptions(request, session, &lookPath);
        sony2fuji_hdr_camera_development_v2 profiled{};
        const auto devSpec = buildCameraRawDevSpec(session, development, false, 0, use_ai != 0, profiled);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto* cache = hdrSessionRoiCache(session);
        auto output = hdr::renderCameraRawROI(*cache, file, devSpec, lookPath, options, roiSpec);
        writeRoiResult(output, out_roi);
        publishPair(std::move(output.pixels), output.hdrHeadroom, output.sdrHeadroom, output.sourceHeadroomKind, std::move(output.meta), result);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_render_file_roi(sony2fuji_session* sessionHandle, const char* file,
    const sony2fuji_hdr_request_v1* request, const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return boundary(diagnostic, [&] {
        if (requestAliases(request, result, sizeof(*result)) ||
            overlaps(roi, sizeof(*roi), result, sizeof(*result))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        }
        if (out_roi) {
            header(out_roi, SONY2FUJI_HDR_FIELD_RESULT);
            if (requestAliases(request, out_roi, sizeof(*out_roi)) ||
                overlaps(roi, sizeof(*roi), out_roi, sizeof(*out_roi)) ||
                overlaps(result, sizeof(*result), out_roi, sizeof(*out_roi))) {
                fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI metadata aliases buffer");
            }
            clearOutput(out_roi);
        }
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        requirePath(file);
        validateRequestVersion(request);
        const auto roiSpec = toCoreRoiSpec(roi);
        if (roiSpec.fullSourceWidth != 0 || roiSpec.fullSourceHeight != 0) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "HDR file ROI cannot use pre-cropped source metadata");
        }
        std::string lookPath;
        const auto options = parseRenderOptions(request, session, &lookPath);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto* cache = hdrSessionRoiCache(session);
        auto output = hdr::renderFileROI(*cache, file, lookPath, options, roiSpec);
        writeRoiResult(output, out_roi);
        publishPair(std::move(output.pixels), output.hdrHeadroom, output.sdrHeadroom, output.sourceHeadroomKind, std::move(output.meta), result);
        hdrSessionDidRenderCPU(session);
    });
}

void sony2fuji_hdr_clear_session_cache(sony2fuji_session* sessionHandle) {
    SessionLease session;
    if (SessionLease::acquire(sessionHandle, session, false)) {
        hdrSessionClearRoiCache(session);
    }
}

void sony2fuji_hdr_release_pair(sony2fuji_hdr_image_pair_v1* image) {
    if (!image || image->version != 1 || image->struct_size < sizeof(*image)) return;
    const size_t size = image->struct_size;
    hdr::releasePairRecord(image->owner_token);
    std::memset(image, 0, size);
}

sony2fuji_status sony2fuji_hdr_geometry_size_json(
    uint32_t native_width,
    uint32_t native_height,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    uint32_t* width,
    uint32_t* height,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        if (!width || !height || width == height || !native_width || !native_height ||
            uint64_t(native_width) * native_height > 128000000 ||
            (exec_options && (overlaps(exec_options, sizeof(*exec_options), width, sizeof(*width)) ||
                              overlaps(exec_options, sizeof(*exec_options), height, sizeof(*height))))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Invalid HDR geometry dimensions");
        }
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, nullptr, false, nullptr);
        std::tie(*width, *height) = hdr::computeGeometryOutputSize(native_width, native_height, options.geometry);
    });
}

sony2fuji_status sony2fuji_hdr_roi_source_bounds_json(
    uint32_t full_source_width,
    uint32_t full_source_height,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_roi_source_bounds_v1* out_bounds,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        header(out_bounds, SONY2FUJI_HDR_FIELD_RESULT);
        if ((exec_options && overlaps(exec_options, sizeof(*exec_options), out_bounds, sizeof(*out_bounds))) ||
            overlaps(roi, sizeof(*roi), out_bounds, sizeof(*out_bounds))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI bounds alias input");
        }
        clearOutput(out_bounds);
        const auto roiSpec = toCoreRoiSpec(roi);
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, nullptr, false, nullptr);
        const auto bounds = computeHDRRoiSourceBounds(full_source_width, full_source_height, options, roiSpec);
        out_bounds->source_x0 = static_cast<uint32_t>(bounds.sourceRect.x0);
        out_bounds->source_y0 = static_cast<uint32_t>(bounds.sourceRect.y0);
        out_bounds->source_x1 = static_cast<uint32_t>(bounds.sourceRect.x1);
        out_bounds->source_y1 = static_cast<uint32_t>(bounds.sourceRect.y1);
        out_bounds->native_x0 = static_cast<uint32_t>(bounds.plan.ox0);
        out_bounds->native_y0 = static_cast<uint32_t>(bounds.plan.oy0);
        out_bounds->native_x1 = static_cast<uint32_t>(bounds.plan.ox1);
        out_bounds->native_y1 = static_cast<uint32_t>(bounds.plan.oy1);
        out_bounds->full_native_width = static_cast<uint32_t>(bounds.plan.fullNativeWidth);
        out_bounds->full_native_height = static_cast<uint32_t>(bounds.plan.fullNativeHeight);
        out_bounds->output_width = static_cast<uint32_t>(bounds.plan.outputWidth);
        out_bounds->output_height = static_cast<uint32_t>(bounds.plan.outputHeight);
    });
}

sony2fuji_status sony2fuji_hdr_render_json(
    sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        if (sourceAliases(source, result, sizeof(*result)) ||
            (exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result)))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        }
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        auto input = readPair(source);
        std::string lookPath;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        auto rendered = hdr::renderPair(input->pixels, source->owner_token != 0, options);
        auto meta = input->meta;
        meta.lookPath = std::move(lookPath);
        const float hdrH = rendered.editedHeadroom, sdrH = rendered.editedSdrHeadroom;
        publishPair(std::move(rendered), hdrH, sdrH, input->sourceHeadroomKind, std::move(meta), result);
        reportHdrProgress(1000, 1000);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_render_roi_json(
    sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        if (sourceAliases(source, result, sizeof(*result)) ||
            (exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result))) ||
            overlaps(roi, sizeof(*roi), result, sizeof(*result))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        }
        if (out_roi) {
            header(out_roi, SONY2FUJI_HDR_FIELD_RESULT);
            if (sourceAliases(source, out_roi, sizeof(*out_roi)) ||
                (exec_options && overlaps(exec_options, sizeof(*exec_options), out_roi, sizeof(*out_roi))) ||
                overlaps(roi, sizeof(*roi), out_roi, sizeof(*out_roi)) ||
                overlaps(result, sizeof(*result), out_roi, sizeof(*out_roi))) {
                fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI metadata aliases buffer");
            }
            clearOutput(out_roi);
        }
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        const auto roiSpec = toCoreRoiSpec(roi);
        auto input = readPair(source);
        std::string lookPath;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath);
        const ProcessingCancellationScope cancellation(
            options.hasPhotoEffects() || options.hasDetail() || options.look ? hdrSessionCancellation(session) : ProcessingCancellation{});
        auto output = hdr::renderPairROI(input->pixels, lookPath, input->meta, input->sourceHeadroomKind, options, roiSpec);
        writeRoiResult(output, out_roi);
        publishPair(std::move(output.pixels), output.hdrHeadroom, output.sdrHeadroom, output.sourceHeadroomKind, std::move(output.meta), result);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_render_camera_raw_roi_json(
    sony2fuji_session* sessionHandle,
    const char* file,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        if ((exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result))) ||
            overlaps(roi, sizeof(*roi), result, sizeof(*result))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        }
        if (out_roi) {
            header(out_roi, SONY2FUJI_HDR_FIELD_RESULT);
            if ((exec_options && overlaps(exec_options, sizeof(*exec_options), out_roi, sizeof(*out_roi))) ||
                overlaps(roi, sizeof(*roi), out_roi, sizeof(*out_roi)) ||
                overlaps(result, sizeof(*result), out_roi, sizeof(*out_roi))) {
                fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI metadata aliases buffer");
            }
            clearOutput(out_roi);
        }
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        requirePath(file);
        const auto roiSpec = toCoreRoiSpec(roi);
        if (roiSpec.fullSourceWidth != 0 || roiSpec.fullSourceHeight != 0) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "Camera RAW ROI cannot use pre-cropped source metadata");
        }
        std::string lookPath;
        CanonicalEditState state;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath, &state);
        std::string profilePath;
        const auto devSpec = buildCameraRawDevSpecFromState(session, state, false, 0, profilePath);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto* cache = hdrSessionRoiCache(session);
        auto output = hdr::renderCameraRawROI(*cache, file, devSpec, lookPath, options, roiSpec);
        writeRoiResult(output, out_roi);
        publishPair(std::move(output.pixels), output.hdrHeadroom, output.sdrHeadroom, output.sourceHeadroomKind, std::move(output.meta), result);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_render_file_roi_json(
    sony2fuji_session* sessionHandle,
    const char* file,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_roi_v1* roi,
    sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        if ((exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result))) ||
            overlaps(roi, sizeof(*roi), result, sizeof(*result))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR result aliases input");
        }
        if (out_roi) {
            header(out_roi, SONY2FUJI_HDR_FIELD_RESULT);
            if ((exec_options && overlaps(exec_options, sizeof(*exec_options), out_roi, sizeof(*out_roi))) ||
                overlaps(roi, sizeof(*roi), out_roi, sizeof(*out_roi)) ||
                overlaps(result, sizeof(*result), out_roi, sizeof(*out_roi))) {
                fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "HDR ROI metadata aliases buffer");
            }
            clearOutput(out_roi);
        }
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        requirePath(file);
        const auto roiSpec = toCoreRoiSpec(roi);
        if (roiSpec.fullSourceWidth != 0 || roiSpec.fullSourceHeight != 0) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_REQUEST, "HDR file ROI cannot use pre-cropped source metadata");
        }
        std::string lookPath;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto* cache = hdrSessionRoiCache(session);
        auto output = hdr::renderFileROI(*cache, file, lookPath, options, roiSpec);
        writeRoiResult(output, out_roi);
        publishPair(std::move(output.pixels), output.hdrHeadroom, output.sdrHeadroom, output.sourceHeadroomKind, std::move(output.meta), result);
        hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_decode_camera_raw_json(
    sony2fuji_session* sessionHandle,
    const char* file,
    const sony2fuji_hdr_decode_options_v1* options,
    const char* edit_state_json,
    sony2fuji_hdr_image_pair_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        prepareOutput(result);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "Camera RAW HDR development is CPU only", true);
        header(options, SONY2FUJI_HDR_FIELD_REQUEST);
        requirePath(file);
        hdr::validateDecodeSize(options->intent, options->long_edge, true);
        const auto state = parseHdrJsonState(edit_state_json, /*requireHdr=*/false);
        std::string profilePath;
        const auto spec = buildCameraRawDevSpecFromState(
            session, state, options->intent == SONY2FUJI_INTENT_PREVIEW, options->long_edge, profilePath);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        checkProcessingCancellation();
        reportHdrProgress(0, 1000);
        auto decoded = hdr::decodeCameraRaw(file, spec);
        hdr::ExportSourceMetadata meta{{}, file, {}, decoded.usedCameraProfile ? std::move(profilePath) : ""};
        publishPair(std::move(decoded.pixels), 0.0f, 0.0f, decoded.sourceHeadroomKind, std::move(meta), result);
        reportHdrProgress(1000, 1000);
        if (session) hdrSessionDidRenderCPU(session);
    });
}

sony2fuji_status sony2fuji_hdr_export_stream_json(
    sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_stream_source_v1* source,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_export_config_v1* config,
    uint32_t keepHDR,
    const char* temporaryRoot,
    const char* file,
    sony2fuji_hdr_stream_result_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        header(source, SONY2FUJI_HDR_FIELD_SOURCE);
        header(config, SONY2FUJI_HDR_FIELD_EXPORT);
        header(result, SONY2FUJI_HDR_FIELD_RESULT);
        if (overlaps(source, sizeof(*source), result, sizeof(*result)) ||
            overlaps(config, sizeof(*config), result, sizeof(*result)) ||
            (exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result)))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "Stream result aliases input");
        }
        clearOutput(result);
        requirePath(file);
        requirePath(temporaryRoot);
        requirePath(config->metadata_source_path);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "Streamed HDR processing is CPU only");
        std::string lookPath;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath);
        if (keepHDR > 1) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE, "Incomplete stream source or export configuration");
        StreamCancellation cancellation(session, source);
        const HdrProgressScope progress(hdrSessionProgress(session));
        reportHdrProgress(0, 1000);
        const auto encoded = hdr::exportRowStream(toStreamSpec(source), options, lookPath, toCoreExportConfig(*config),
                                                  keepHDR != 0, temporaryRoot, file);
        reportHdrProgress(1000, 1000);
        finishStreamExport(result, encoded, source->native_width, source->native_height, source->decode_revision, session);
    });
}

sony2fuji_status sony2fuji_hdr_export_tiled_json(
    sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_stream_source_v1* stream,
    const char* sourceFile,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_export_config_v1* config,
    uint32_t format,
    const char* temporaryRoot,
    const char* file,
    sony2fuji_hdr_stream_result_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
#if defined(__APPLE__)
        if (source && stream) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE, "Specify one tiled source representation");
        if (stream) header(stream, SONY2FUJI_HDR_FIELD_SOURCE);
        header(config, SONY2FUJI_HDR_FIELD_EXPORT);
        header(result, SONY2FUJI_HDR_FIELD_RESULT);
        const bool srcAlias = (source && sourceAliases(source, result, sizeof(*result))) ||
            (stream && overlaps(stream, sizeof(*stream), result, sizeof(*result))) ||
            (exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result)));
        if (srcAlias || overlaps(config, sizeof(*config), result, sizeof(*result))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "Tiled result aliases input");
        }
        clearOutput(result);
        requirePath(file);
        requirePath(temporaryRoot);
        requirePath(sourceFile);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "Tiled HDR processing is CPU only");
        std::string lookPath;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath);
        if (format != SONY2FUJI_HDR_TILED_HEIF && format != SONY2FUJI_HDR_TILED_SDR_DNG)
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT, "Invalid tiled export configuration");
        StreamCancellation cancellation(session, stream);
        checkProcessingCancellation();
        const HdrProgressScope progress(hdrSessionProgress(session));
        reportHdrProgress(0, 1000);
        std::shared_ptr<hdr::OwnedPairRecord> ownedCamera;
        hdr::StreamSourceSpec streamSpec;
        hdr::TiledSourceInput input{};
        if (source) {
            header(source, SONY2FUJI_HDR_FIELD_SOURCE);
            if (!source->owner_token || config->metadata_source_path)
                fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_SOURCE, "Tiled RAW export requires an owned camera source without copied metadata");
            ownedCamera = readPair(source);
            input.ownedCameraPixels = &ownedCamera->pixels;
            input.ownedCameraMeta = &ownedCamera->meta;
        } else if (stream) {
            streamSpec = toStreamSpec(stream);
            input.stream = &streamSpec;
        }
        const auto exported = hdr::exportTiledStream(input, sourceFile, options, lookPath, toCoreExportConfig(*config),
                                                     format == SONY2FUJI_HDR_TILED_HEIF, temporaryRoot, file);
        reportHdrProgress(1000, 1000);
        finishStreamExport(result, exported.stream, exported.sourceWidth, exported.sourceHeight, exported.decodeRevision, session);
#else
        (void)sessionHandle; (void)source; (void)stream; (void)sourceFile; (void)exec_options;
        (void)edit_state_json; (void)config; (void)format; (void)temporaryRoot; (void)file; (void)result;
        fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM, SONY2FUJI_HDR_FIELD_EXPORT, "Tiled HDR file export requires an Apple runtime", SONY2FUJI_STATUS_UNSUPPORTED);
#endif
    });
}

sony2fuji_status sony2fuji_hdr_export_proraw_json(
    sony2fuji_session* sessionHandle,
    const char* sourceFile,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_export_config_v1* config,
    uint32_t keepHDR,
    const char* temporaryRoot,
    const char* file,
    sony2fuji_hdr_stream_result_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        header(config, SONY2FUJI_HDR_FIELD_EXPORT);
        header(result, SONY2FUJI_HDR_FIELD_RESULT);
        if (overlaps(config, sizeof(*config), result, sizeof(*result)) ||
            (exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result)))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "ProRAW result aliases input");
        }
        clearOutput(result);
        requirePath(file);
        requirePath(temporaryRoot);
        requirePath(sourceFile);
        requirePath(config->metadata_source_path);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "ProRAW development is CPU only");
        std::string lookPath;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath);
        if (keepHDR > 1) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT, "Invalid ProRAW export configuration");
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        reportHdrProgress(0, 1000);
        const auto exported = hdr::exportProRAWStream(sourceFile, options, lookPath, toCoreExportConfig(*config),
                                                      keepHDR != 0, temporaryRoot, file);
        reportHdrProgress(1000, 1000);
        finishStreamExport(result, exported.stream, exported.nativeWidth, exported.nativeHeight, hdr::portableProRAWRevision, session);
    });
}

sony2fuji_status sony2fuji_hdr_export_apple_proraw_json(
    sony2fuji_session* sessionHandle,
    const char* sourceFile,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    const sony2fuji_hdr_export_config_v1* config,
    uint32_t keepHDR,
    const char* temporaryRoot,
    const char* file,
    sony2fuji_hdr_stream_result_v1* result,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
#if defined(__APPLE__)
        header(config, SONY2FUJI_HDR_FIELD_EXPORT);
        header(result, SONY2FUJI_HDR_FIELD_RESULT);
        if (overlaps(config, sizeof(*config), result, sizeof(*result)) ||
            (exec_options && overlaps(exec_options, sizeof(*exec_options), result, sizeof(*result)))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_BUFFER, SONY2FUJI_HDR_FIELD_RESULT, "ProRAW result aliases input");
        }
        clearOutput(result);
        requirePath(file);
        requirePath(temporaryRoot);
        requirePath(sourceFile);
        requirePath(config->metadata_source_path);
        SessionLease session;
        requireCpuSession(sessionHandle, session, "ProRAW development is CPU only");
        std::string lookPath;
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, &lookPath);
        if (keepHDR > 1) fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_EXPORT, "Invalid ProRAW export configuration");
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        const HdrProgressScope progress(hdrSessionProgress(session));
        reportHdrProgress(0, 1000);
        const auto exported = hdr::exportAppleProRAWStream(sourceFile, options, lookPath, toCoreExportConfig(*config),
                                                           keepHDR != 0, temporaryRoot, file);
        reportHdrProgress(1000, 1000);
        finishStreamExport(result, exported.stream, exported.nativeWidth, exported.nativeHeight, hdr::appleProRAWRevision, session);
#else
        (void)sessionHandle; (void)sourceFile; (void)exec_options; (void)edit_state_json;
        (void)config; (void)keepHDR; (void)temporaryRoot; (void)file; (void)result;
        fail(SONY2FUJI_HDR_REASON_UNSUPPORTED_SYSTEM, SONY2FUJI_HDR_FIELD_EXPORT,
             "Apple ProRAW export requires an Apple runtime", SONY2FUJI_STATUS_UNSUPPORTED);
#endif
    });
}

sony2fuji_status sony2fuji_hdr_create_hsl_probe_json(
    sony2fuji_session* sessionHandle,
    const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_render_options_v1* exec_options,
    const char* edit_state_json,
    uint64_t sourceRevision,
    uint64_t requestRevision,
    sony2fuji_hsl_probe** outProbe,
    sony2fuji_hdr_diagnostic_v1* diagnostic
) {
    return boundary(diagnostic, [&] {
        if (!outProbe || sourceAliases(source, outProbe, sizeof(*outProbe)) ||
            (exec_options && overlaps(exec_options, sizeof(*exec_options), outProbe, sizeof(*outProbe)))) {
            fail(SONY2FUJI_HDR_REASON_INVALID_ARGUMENT, SONY2FUJI_HDR_FIELD_RESULT, "Invalid HDR probe output");
        }
        *outProbe = nullptr;
        SessionLease session;
        requireCpuSession(sessionHandle, session, "HDR computation is CPU only");
        const auto options = buildHdrRenderOptionsFromJson(exec_options, edit_state_json, &session, true, nullptr);
        const ProcessingCancellationScope cancellation(hdrSessionCancellation(session));
        checkProcessingCancellation();
        auto probe = hdr::createHslProbeImage(readPair(source)->pixels, source->owner_token != 0, options);
        *outProbe = makeHDRHslProbe(std::move(probe), sourceRevision, requestRevision, options.intent == HDRQuality::Preview);
    });
}
} // extern "C"
