#include "jni_internal.h"

#include <algorithm>
#include <cmath>

namespace rawlab::jni {

std::mutex hdrPairsMutex;
std::unordered_map<jlong, std::shared_ptr<const HdrPairOwner>> hdrPairs;

} // namespace rawlab::jni

using namespace rawlab::jni;

namespace {

jlong nextHdrPairId = 1;

struct HDRStatusError : std::runtime_error {
    sony2fuji_status status;
    sony2fuji_hdr_diagnostic_v1 diagnostic;
    HDRStatusError(sony2fuji_status value, sony2fuji_hdr_diagnostic_v1 detail)
        : std::runtime_error("HDR processing failed"), status(value), diagnostic(detail) {}
};

void throwHDRFailure(JNIEnv* env, const std::exception& error) {
    const auto* detail = dynamic_cast<const HDRStatusError*>(&error);
    if (!detail) {
        throwJava(env, "java/io/IOException", error.what());
        return;
    }
    if (env->ExceptionCheck()) return;
    try {
        const auto& cache = jniCache(env);
        LocalRef object(env, env->NewObject(cache.hdrProcessingException.clazz, cache.hdrProcessingException.ctor,
            jint(detail->status), jint(detail->diagnostic.reason), jint(detail->diagnostic.field)));
        if (object) env->Throw(static_cast<jthrowable>(object.get()));
    } catch (...) {
        env->ExceptionClear();
        throwJava(env, "java/io/IOException", error.what());
    }
}

void handleHdrException(JNIEnv* env, const char* oomMessage) noexcept {
    try {
        throw;
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", oomMessage);
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env, error);
    } catch (...) {
        throwJava(env, "java/io/IOException", "HDR processing failed");
    }
}

std::shared_ptr<const HdrPairOwner> acquireHdrPair(jlong id) {
    std::lock_guard<std::mutex> lock(hdrPairsMutex);
    const auto found = hdrPairs.find(id);
    if (found == hdrPairs.end()) throw std::invalid_argument("HDR pair is closed");
    return found->second;
}

jlong retainHdrPair(sony2fuji_hdr_image_pair_v1 value) {
    std::shared_ptr<HdrPairOwner> owner;
    try {
        owner = std::make_shared<HdrPairOwner>(value);
    } catch (...) {
        sony2fuji_hdr_release_pair(&value);
        throw;
    }
    std::lock_guard<std::mutex> lock(hdrPairsMutex);
    const jlong id = nextHdrPairId++;
    hdrPairs.emplace(id, std::move(owner));
    return id;
}

void releaseHdrPair(jlong id) {
    std::shared_ptr<const HdrPairOwner> removed;
    {
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        const auto found = hdrPairs.find(id);
        if (found != hdrPairs.end()) {
            removed = std::move(found->second);
            hdrPairs.erase(found);
        }
    }
}

struct ProgressScope {
    sony2fuji_session* session;
    JNIEnv* env;
    jobject listener;
    jmethodID method;

    static void onProgress(void* context, uint32_t completed, uint32_t total) {
        auto& self = *static_cast<ProgressScope*>(context);
        if (!self.env || !self.listener || !self.method || total == 0) return;
        const auto permille = static_cast<jint>(std::min<uint64_t>(1000, (uint64_t(completed) * 1000) / total));
        self.env->CallVoidMethod(self.listener, self.method, permille);
        if (self.env->ExceptionCheck()) self.env->ExceptionClear();
    }

    ProgressScope(sony2fuji_session* owner, JNIEnv* e, jobject l)
        : session(owner), env(e), listener(l),
          method(l ? jniCache(e).hdrProgressListener.onProgress : nullptr) {
        if (session && listener && method) sony2fuji_session_set_hdr_progress_callback(session, onProgress, this);
    }

    ~ProgressScope() {
        if (session && listener && method) sony2fuji_session_set_hdr_progress_callback(session, nullptr, nullptr);
    }
};

struct OptionalHdrSessionScopes {
    std::unique_ptr<SessionGuard> guard;
    std::unique_ptr<CancellationScope> cancellation;
    std::unique_ptr<ProgressScope> progress;

    OptionalHdrSessionScopes(jlong sessionId, jlong cancellationGeneration, JNIEnv* env, jobject progressListener) {
        if (sessionId != 0) {
            guard = std::make_unique<SessionGuard>(sessionId);
            cancellation = std::make_unique<CancellationScope>(guard->session(), cancellationGeneration);
            progress = std::make_unique<ProgressScope>(guard->get(), env, progressListener);
            if (cancellation->isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        }
    }

    sony2fuji_session* session() const { return guard ? guard->get() : nullptr; }
    bool isCancelled() const { return cancellation && cancellation->isCancelled(); }
};

sony2fuji_hdr_render_options_v1 makeHdrRenderOptions(uint32_t intent, jint longEdge) {
    if (longEdge < 0 || longEdge > 65535) throw std::invalid_argument("Invalid HDR long edge");
    return {SONY2FUJI_HDR_RENDER_OPTIONS_V1_VERSION, sizeof(sony2fuji_hdr_render_options_v1),
        intent, static_cast<uint32_t>(longEdge)};
}

sony2fuji_hdr_roi_v1 makeHdrRoi(jfloat x0, jfloat y0, jfloat x1, jfloat y1,
    jint maxOutputLongEdge, jfloat baseContentHeadroom) {
    if (!std::isfinite(x0) || !std::isfinite(y0) || !std::isfinite(x1) || !std::isfinite(y1) || maxOutputLongEdge <= 0) {
        throw std::invalid_argument("Invalid HDR ROI bounds");
    }
    return {SONY2FUJI_HDR_VERSION, sizeof(sony2fuji_hdr_roi_v1), x0, y0, x1, y1,
        static_cast<uint32_t>(std::clamp(maxOutputLongEdge, jint(1), jint(1280))),
        std::isfinite(baseContentHeadroom) ? baseContentHeadroom : 0.0f, 0u, 0u, 0u, 0u};
}

jobject makeHdrSourceInfoObj(JNIEnv* env, const sony2fuji_hdr_source_info_v1& info,
    jboolean supportsBayer, jint processingVersion) {
    LocalRef fp(env, env->NewByteArray(32));
    if (!fp) return nullptr;
    env->SetByteArrayRegion(fp.asByteArray(), 0, 32, reinterpret_cast<const jbyte*>(info.source_sha256));
    if (env->ExceptionCheck()) return nullptr;
    const auto& cache = jniCache(env);
    return env->NewObject(cache.hdrSourceInfo.clazz, cache.hdrSourceInfo.ctor,
        static_cast<jint>(info.width), static_cast<jint>(info.height),
        static_cast<jint>(info.orientation), static_cast<jint>(info.container),
        static_cast<jint>(info.protocol), static_cast<jint>(info.color_description),
        info.content_headroom, static_cast<jint>(info.headroom_kind),
        fp.get(), supportsBayer, processingVersion);
}

jobject completeHdrRoiPair(JNIEnv* env, const CancellationScope& cancellation, sony2fuji_status status,
    const sony2fuji_hdr_diagnostic_v1& diagnostic, sony2fuji_hdr_image_pair_v1& result,
    const sony2fuji_hdr_roi_result_v1& roiResult) {
    if (cancellation.isCancelled()) {
        sony2fuji_hdr_release_pair(&result);
        throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
    }
    if (status != SONY2FUJI_STATUS_OK) {
        sony2fuji_hdr_release_pair(&result);
        throw HDRStatusError(status, diagnostic);
    }
    const auto& cache = jniCache(env);
    LocalRef bounds(env, env->NewObject(cache.nativeRoiBounds.clazz, cache.nativeRoiBounds.ctor,
        static_cast<jint>(roiResult.native_x0), static_cast<jint>(roiResult.native_y0),
        static_cast<jint>(roiResult.native_x1), static_cast<jint>(roiResult.native_y1),
        static_cast<jint>(roiResult.full_native_width), static_cast<jint>(roiResult.full_native_height)));
    if (!bounds) { sony2fuji_hdr_release_pair(&result); return nullptr; }
    const jlong handle = retainHdrPair(result);
    jobject pairObj = env->NewObject(cache.nativeHdrRoiPair.clazz, cache.nativeHdrRoiPair.ctor, handle, bounds.get());
    if (!pairObj || env->ExceptionCheck()) { releaseHdrPair(handle); return nullptr; }
    return pairObj;
}

jlong finishPair(const CancellationScope* cancellation, sony2fuji_status status,
    const sony2fuji_hdr_diagnostic_v1& diagnostic, sony2fuji_hdr_image_pair_v1& result) {
    if (cancellation && cancellation->isCancelled()) {
        sony2fuji_hdr_release_pair(&result);
        throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
    }
    if (status != SONY2FUJI_STATUS_OK) {
        sony2fuji_hdr_release_pair(&result);
        if (status == SONY2FUJI_STATUS_CANCELLED) throw NativeStatusError(status);
        throw HDRStatusError(status, diagnostic);
    }
    return retainHdrPair(result);
}

} // namespace

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeProbe(JNIEnv* env, jclass, jstring path) {
    try {
        UtfChars source(env, path);
        if (!source.chars || !*source.chars) throw std::invalid_argument("Missing HDR source path");
        sony2fuji_hdr_source_info_v1 info{SONY2FUJI_HDR_VERSION, sizeof(info)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_probe(source.chars, &info, &diagnostic);
        if (status == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_NOT_HDR) return nullptr;
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        return makeHdrSourceInfoObj(env, info, JNI_FALSE, 3);
    } catch (...) { handleHdrException(env, "Not enough memory for HDR probe"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeProbeCameraRaw(JNIEnv* env, jclass, jstring path, jint processingVersion) {
    try {
        UtfChars source(env, path);
        if (!source.chars || !*source.chars) throw std::invalid_argument("Missing camera RAW source path");
        sony2fuji_hdr_camera_source_info_v1 camera{};
        auto& info = camera.base;
        info.version = SONY2FUJI_HDR_VERSION;
        info.struct_size = sizeof(camera);
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        auto status = sony2fuji_hdr_probe_camera_raw_with_processing(source.chars,
            static_cast<sony2fuji_processing_version>(processingVersion), &info, &diagnostic);
        if (status == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW) {
            status = sony2fuji_hdr_probe_proraw(source.chars, &info, &diagnostic);
        }
        if (status == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW) return nullptr;
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        const jboolean supportsBayer = (camera.capabilities & SONY2FUJI_HDR_CAMERA_SOURCE_BAYER) != 0 ? JNI_TRUE : JNI_FALSE;
        const jint effectiveVersion = info.container == SONY2FUJI_HDR_CONTAINER_PRORAW ? 3 : processingVersion;
        return makeHdrSourceInfoObj(env, info, supportsBayer, effectiveVersion);
    } catch (...) { handleHdrException(env, "Not enough memory for camera RAW HDR probe"); }
    return nullptr;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeProbeLook(JNIEnv* env, jclass, jstring path) {
    try {
        UtfChars input(env, path);
        sony2fuji_hdr_look_info_v1 info{SONY2FUJI_HDR_VERSION, sizeof(info)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_probe_look(input.chars, &info, &diagnostic);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        return env->NewStringUTF(info.sha256);
    } catch (const std::exception& error) { throwHDRFailure(env, error); }
    return nullptr;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeProbeCameraProfile(JNIEnv* env, jclass, jstring path) {
    try {
        UtfChars input(env, path);
        sony2fuji_hdr_camera_profile_info_v1 info{SONY2FUJI_HDR_VERSION, sizeof(info)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_probe_camera_profile(input.chars, &info, &diagnostic);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        return env->NewStringUTF(info.sha256);
    } catch (const std::exception& error) { throwHDRFailure(env, error); }
    return nullptr;
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(JNIEnv* env, jclass,
    jint width, jint height, jstring editStateJson) {
    try {
        UtfChars json(env, editStateJson);
        if (width <= 0 || height <= 0 || !json.chars || !*json.chars) throw std::invalid_argument("Invalid HDR geometry request");
        const auto execOptions = makeHdrRenderOptions(SONY2FUJI_INTENT_PREVIEW, 0);
        uint32_t outputWidth = 0, outputHeight = 0;
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        if (sony2fuji_hdr_geometry_size_json(static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                &execOptions, json.chars, &outputWidth, &outputHeight, &diagnostic) != SONY2FUJI_STATUS_OK) {
            throw std::invalid_argument("Invalid HDR geometry");
        }
        const jint output[] = {jint(outputWidth), jint(outputHeight)};
        auto result = env->NewIntArray(2);
        if (result) env->SetIntArrayRegion(result, 0, 2, output);
        return result;
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); return nullptr; }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(JNIEnv* env, jclass, jlong sessionId, jstring path,
    jint longEdge, jlong cancellationGeneration, jobject progressListener) {
    try {
        UtfChars source(env, path);
        if (!source.chars || !*source.chars || longEdge < 0 || longEdge > 65535) {
            throw std::invalid_argument("Invalid HDR preview request");
        }
        OptionalHdrSessionScopes scopes(sessionId, cancellationGeneration, env, progressListener);
        sony2fuji_hdr_decode_options_v1 options{SONY2FUJI_HDR_VERSION, sizeof(options),
            longEdge == 0 ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW, static_cast<uint32_t>(longEdge)};
        sony2fuji_hdr_image_pair_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_decode_with_session(scopes.session(), source.chars, &options, &result, &diagnostic);
        return finishPair(scopes.cancellation.get(), status, diagnostic, result);
    } catch (...) { handleHdrException(env, "Not enough memory for HDR decode"); }
    return 0;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecodeCameraRaw(JNIEnv* env, jclass, jlong sessionId,
    jstring path, jint longEdge, jlong cancellationGeneration, jboolean proRAW, jstring temporaryRoot,
    jstring editStateJson, jobject progressListener) {
    try {
        UtfChars source(env, path), temporary(env, temporaryRoot), json(env, editStateJson);
        if (!source.chars || !*source.chars || longEdge < 0 || longEdge > 65535 ||
            (!proRAW && (!json.chars || !*json.chars))) {
            throw std::invalid_argument("Invalid camera RAW HDR preview request");
        }
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        ProgressScope progress(guard.get(), env, progressListener);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        sony2fuji_hdr_decode_options_v1 options{SONY2FUJI_HDR_VERSION, sizeof(options),
            longEdge == 0 ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW, static_cast<uint32_t>(longEdge)};
        sony2fuji_hdr_image_pair_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = proRAW
            ? sony2fuji_hdr_decode_proraw(guard.get(), source.chars, &options, temporary.chars, &result, &diagnostic)
            : sony2fuji_hdr_decode_camera_raw_json(guard.get(), source.chars, &options, json.chars, &result, &diagnostic);
        return finishPair(&cancellation, status, diagnostic, result);
    } catch (...) { handleHdrException(env, "Not enough memory for camera RAW HDR decode"); }
    return 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportProRAW(JNIEnv* env, jclass, jlong sessionId,
    jstring path, jstring editStateJson, jint edge, jboolean keepHDR, jbyteArray fingerprint,
    jstring temporaryRoot, jstring outputPath, jlong cancellationGeneration, jobject progressListener) {
    try {
        if (!fingerprint || env->GetArrayLength(fingerprint) != 32) throw std::invalid_argument("Invalid ProRAW export fingerprint");
        UtfChars source(env, path), json(env, editStateJson), temporary(env, temporaryRoot), output(env, outputPath);
        if (!source.chars || !*source.chars || !json.chars || !*json.chars) throw std::invalid_argument("Invalid ProRAW export request");
        const auto execOptions = makeHdrRenderOptions(SONY2FUJI_INTENT_FINAL, edge);
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        ProgressScope progress(guard.get(), env, progressListener);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        sony2fuji_hdr_export_config_v1 config{SONY2FUJI_HDR_VERSION, sizeof(config), 95u,
            SONY2FUJI_HDR_COLOR_DISPLAY_P3, SONY2FUJI_HDR_METADATA_ISO_XMP, source.chars, {}};
        env->GetByteArrayRegion(fingerprint, 0, 32, reinterpret_cast<jbyte*>(config.source_sha256));
        if (env->ExceptionCheck()) return;
        sony2fuji_hdr_stream_result_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_export_proraw_json(guard.get(), source.chars, &execOptions, json.chars,
            &config, keepHDR ? 1u : 0u, temporary.chars, output.chars, &result, &diagnostic);
        if (status == SONY2FUJI_STATUS_CANCELLED) throw NativeStatusError(status);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
    } catch (...) { handleHdrException(env, "Not enough memory for ProRAW export"); }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(JNIEnv* env, jclass, jlong sessionId, jlong sourceId,
    jstring editStateJson, jint edge, jlong cancellationGeneration, jobject progressListener) {
    try {
        UtfChars json(env, editStateJson);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing HDR edit state JSON");
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        ProgressScope progress(guard.get(), env, progressListener);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        const auto sourceOwner = acquireHdrPair(sourceId);
        const auto& source = sourceOwner->value;
        const auto execOptions = makeHdrRenderOptions(source.source_intent, edge);
        sony2fuji_hdr_image_pair_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_render_json(guard.get(), &source, &execOptions, json.chars, &result, &diagnostic);
        return finishPair(&cancellation, status, diagnostic, result);
    } catch (...) { handleHdrException(env, "Not enough memory for HDR render"); }
    return 0;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRenderRoi(JNIEnv* env, jclass, jlong sessionId, jlong sourceId,
    jstring editStateJson, jint edge, jfloat x0, jfloat y0, jfloat x1, jfloat y1, jint maxOutputLongEdge,
    jfloat baseContentHeadroom, jlong cancellationGeneration) {
    try {
        UtfChars json(env, editStateJson);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing HDR edit state JSON");
        const auto roi = makeHdrRoi(x0, y0, x1, y1, maxOutputLongEdge, baseContentHeadroom);
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        const auto sourceOwner = acquireHdrPair(sourceId);
        const auto& source = sourceOwner->value;
        const auto execOptions = makeHdrRenderOptions(source.source_intent, edge);
        sony2fuji_hdr_image_pair_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_roi_result_v1 roiResult{SONY2FUJI_HDR_VERSION, sizeof(roiResult)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_render_roi_json(guard.get(), &source, &execOptions, json.chars,
            &roi, &result, &roiResult, &diagnostic);
        return completeHdrRoiPair(env, cancellation, status, diagnostic, result, roiResult);
    } catch (...) { handleHdrException(env, "Not enough memory for HDR ROI render"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRenderCameraRawRoi(JNIEnv* env, jclass, jlong sessionId,
    jstring path, jstring editStateJson, jint edge, jfloat x0, jfloat y0, jfloat x1, jfloat y1,
    jint maxOutputLongEdge, jfloat baseContentHeadroom, jlong cancellationGeneration) {
    try {
        UtfChars source(env, path), json(env, editStateJson);
        if (!source.chars || !*source.chars || !json.chars || !*json.chars) throw std::invalid_argument("Invalid camera RAW HDR ROI request");
        const auto roi = makeHdrRoi(x0, y0, x1, y1, maxOutputLongEdge, baseContentHeadroom);
        const auto execOptions = makeHdrRenderOptions(SONY2FUJI_INTENT_PREVIEW, edge);
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        sony2fuji_hdr_image_pair_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_roi_result_v1 roiResult{SONY2FUJI_HDR_VERSION, sizeof(roiResult)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_render_camera_raw_roi_json(guard.get(), source.chars, &execOptions,
            json.chars, &roi, &result, &roiResult, &diagnostic);
        return completeHdrRoiPair(env, cancellation, status, diagnostic, result, roiResult);
    } catch (...) { handleHdrException(env, "Not enough memory for camera RAW HDR ROI render"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRenderFileRoi(JNIEnv* env, jclass, jlong sessionId,
    jstring path, jbyteArray expectedFingerprint, jstring editStateJson, jint edge,
    jfloat x0, jfloat y0, jfloat x1, jfloat y1, jint maxOutputLongEdge, jfloat baseContentHeadroom,
    jlong cancellationGeneration) {
    try {
        if (!expectedFingerprint || env->GetArrayLength(expectedFingerprint) != 32) throw std::invalid_argument("Invalid HDR fingerprint");
        uint8_t expected[32]{};
        env->GetByteArrayRegion(expectedFingerprint, 0, 32, reinterpret_cast<jbyte*>(expected));
        if (env->ExceptionCheck()) throw std::invalid_argument("Failed to read HDR fingerprint");
        UtfChars source(env, path), json(env, editStateJson);
        if (!source.chars || !*source.chars || !json.chars || !*json.chars) throw std::invalid_argument("Invalid HDR file ROI request");
        const auto roi = makeHdrRoi(x0, y0, x1, y1, maxOutputLongEdge, baseContentHeadroom);
        const auto execOptions = makeHdrRenderOptions(SONY2FUJI_INTENT_PREVIEW, edge);
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        sony2fuji_hdr_image_pair_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_roi_result_v1 roiResult{SONY2FUJI_HDR_VERSION, sizeof(roiResult)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_render_file_roi_json(guard.get(), source.chars, &execOptions,
            json.chars, &roi, &result, &roiResult, &diagnostic);
        if (status == SONY2FUJI_STATUS_OK && std::memcmp(result.source_sha256, expected, 32) != 0) {
            sony2fuji_hdr_release_pair(&result);
            throw HDRStatusError(SONY2FUJI_STATUS_INVALID_ARGUMENT, {SONY2FUJI_HDR_VERSION, sizeof(diagnostic),
                SONY2FUJI_HDR_REASON_SOURCE_CHANGED, SONY2FUJI_HDR_FIELD_SOURCE});
        }
        return completeHdrRoiPair(env, cancellation, status, diagnostic, result, roiResult);
    } catch (...) { handleHdrException(env, "Not enough memory for HDR file ROI render"); }
    return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeClearHdrSessionCache(JNIEnv*, jclass, jlong sessionId) {
    try { SessionGuard guard(sessionId); sony2fuji_hdr_clear_session_cache(guard.get()); } catch (...) {}
}

extern "C" JNIEXPORT jfloat JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeEstimateAutoExposure(JNIEnv* env, jclass, jlong sessionId,
    jlong sourceId, jfloat temperature, jfloat tint, jlong cancellationGeneration) {
    try {
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        const auto sourceOwner = acquireHdrPair(sourceId);
        const auto& source = sourceOwner->value;
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        float exposure = 0.0f;
        const auto status = sony2fuji_hdr_estimate_auto_exposure(&source, temperature, tint, &exposure, &diagnostic);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        return exposure;
    } catch (...) { handleHdrException(env, "Not enough memory for HDR auto exposure"); }
    return 0.0f;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeSampleHsl(JNIEnv* env, jclass, jlong sessionId, jlong sourceId,
    jstring editStateJson, jint edge, jlong sourceRevision, jlong requestRevision, jfloat x, jfloat y,
    jlong cancellationGeneration) {
    try {
        UtfChars json(env, editStateJson);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing HDR edit state JSON");
        const auto execOptions = makeHdrRenderOptions(SONY2FUJI_INTENT_PREVIEW, edge);
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        const auto sourceOwner = acquireHdrPair(sourceId);
        const auto& source = sourceOwner->value;
        sony2fuji_hsl_probe* probe = nullptr;
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_create_hsl_probe_json(guard.get(), &source, &execOptions, json.chars,
            static_cast<uint64_t>(sourceRevision), static_cast<uint64_t>(requestRevision), &probe, &diagnostic);
        const std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> owner(probe, sony2fuji_hsl_probe_destroy);
        if (status == SONY2FUJI_STATUS_CANCELLED || cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        return sampleHslProbeResult(env, probe, sourceRevision, requestRevision, x, y);
    } catch (...) { handleHdrException(env, "Not enough memory for HDR HSL probe"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeMetadata(JNIEnv* env, jclass, jlong pairId) {
    try {
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeHdrPairInfo.clazz, cache.nativeHdrPairInfo.ctor,
            static_cast<jint>(pair.hdr.width), static_cast<jint>(pair.hdr.height),
            static_cast<jint>(pair.native_width), static_cast<jint>(pair.native_height),
            static_cast<jint>(pair.output_native_width), static_cast<jint>(pair.output_native_height),
            pair.hdr.content_headroom, pair.source_headroom);
    } catch (const std::exception& error) { throwHDRFailure(env, error); }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeFingerprint(JNIEnv* env, jclass, jlong pairId) {
    try {
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        auto result = env->NewByteArray(32);
        if (!result) return nullptr;
        env->SetByteArrayRegion(result, 0, 32, reinterpret_cast<const jbyte*>(pair.source_sha256));
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::exception& error) { throwHDRFailure(env, error); }
    return nullptr;
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativePlane(JNIEnv* env, jclass, jlong pairId, jboolean hdr) {
    try {
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        const auto& buffer = hdr ? pair.hdr : pair.sdr;
        if (!buffer.data || buffer.width == 0 || buffer.height == 0 ||
            buffer.pixel_format != SONY2FUJI_HDR_RGB32F_LINEAR ||
            buffer.stride_bytes < static_cast<uint64_t>(buffer.width) * 3 * sizeof(float)) {
            throw std::runtime_error("Invalid HDR float plane");
        }
        const uint64_t count = static_cast<uint64_t>(buffer.width) * buffer.height * 3;
        if (count > static_cast<uint64_t>(std::numeric_limits<jsize>::max())) throw std::runtime_error("HDR plane is too large");
        auto result = env->NewFloatArray(static_cast<jsize>(count));
        if (!result) return nullptr;
        const size_t rowFloats = static_cast<size_t>(buffer.width) * 3;
        const size_t rowBytes = rowFloats * sizeof(float);
        if (buffer.stride_bytes == rowBytes) {
            env->SetFloatArrayRegion(result, 0, static_cast<jsize>(count), static_cast<const jfloat*>(buffer.data));
        } else {
            for (uint32_t y = 0; y < buffer.height && !env->ExceptionCheck(); ++y) {
                const auto* row = reinterpret_cast<const jfloat*>(
                    static_cast<const uint8_t*>(buffer.data) + static_cast<size_t>(y) * buffer.stride_bytes);
                env->SetFloatArrayRegion(result, static_cast<jsize>(static_cast<size_t>(y) * rowFloats),
                    static_cast<jsize>(rowFloats), row);
            }
        }
        return env->ExceptionCheck() ? nullptr : result;
    } catch (...) { handleHdrException(env, "Not enough memory for HDR plane"); }
    return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeSdrBitmap(JNIEnv* env, jclass, jlong pairId, jobject bitmap) {
    try {
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& buffer = pairOwner->value.sdr;
        if (!buffer.data || buffer.width == 0 || buffer.height == 0 ||
            buffer.pixel_format != SONY2FUJI_HDR_RGB32F_LINEAR ||
            buffer.stride_bytes < static_cast<uint64_t>(buffer.width) * 3 * sizeof(float)) {
            throw std::runtime_error("Invalid SDR float plane");
        }
        AndroidBitmapInfo info{};
        OutputBitmapLock output(env, bitmap, info, buffer.width, buffer.height);
        const uint64_t dstSize = static_cast<uint64_t>(info.height - 1u) * info.stride + static_cast<uint64_t>(info.width) * 4u;
        const auto status = sony2fuji_hdr_encode_rgba8_into(&buffer, output.locked, dstSize, info.stride);
        if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) throw std::bad_alloc();
        if (status == SONY2FUJI_STATUS_INVALID_ARGUMENT) {
            throw HDRStatusError(status, {SONY2FUJI_HDR_VERSION, sizeof(sony2fuji_hdr_diagnostic_v1),
                SONY2FUJI_HDR_REASON_NONFINITE, SONY2FUJI_HDR_FIELD_SDR_BUFFER});
        }
        if (status != SONY2FUJI_STATUS_OK) throw std::runtime_error("SDR bitmap encoding failed");
    } catch (...) { handleHdrException(env, "Not enough memory for SDR bitmap"); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(JNIEnv*, jclass, jlong pairId) {
    releaseHdrPair(pairId);
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportJpeg(JNIEnv* env, jclass, jlong pairId, jlong sessionId,
    jstring sourcePath, jstring outputPath, jint baseColor, jlong cancellationGeneration, jobject progressListener) {
    try {
        UtfChars source(env, sourcePath), output(env, outputPath);
        if (!output.chars || !*output.chars || baseColor < SONY2FUJI_HDR_COLOR_SRGB || baseColor > SONY2FUJI_HDR_COLOR_BT2020) {
            throw std::invalid_argument("Invalid HDR JPEG export request");
        }
        OptionalHdrSessionScopes scopes(sessionId, cancellationGeneration, env, progressListener);
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        sony2fuji_hdr_export_config_v1 config{SONY2FUJI_HDR_VERSION, sizeof(config), 95u,
            static_cast<uint32_t>(baseColor), SONY2FUJI_HDR_METADATA_ISO_XMP, source.chars, {}};
        if (source.chars) std::memcpy(config.source_sha256, pair.source_sha256, 32);
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_export_jpeg_with_session(scopes.session(), &pair, &config, output.chars, &diagnostic);
        if (status == SONY2FUJI_STATUS_CANCELLED) throw NativeStatusError(status);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
    } catch (...) { handleHdrException(env, "Not enough memory for HDR JPEG export"); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportSdr(JNIEnv* env, jclass, jlong pairId, jlong sessionId,
    jstring sourcePath, jstring outputPath, jint format, jlong cancellationGeneration, jobject progressListener) {
    try {
        UtfChars source(env, sourcePath), output(env, outputPath);
        if (!output.chars || !*output.chars ||
            (format != SONY2FUJI_OUTPUT_JPEG && format != SONY2FUJI_OUTPUT_PNG && format != SONY2FUJI_OUTPUT_DNG)) {
            throw std::invalid_argument("Invalid SDR export request");
        }
        OptionalHdrSessionScopes scopes(sessionId, cancellationGeneration, env, progressListener);
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        sony2fuji_hdr_sdr_export_config_v1 config{SONY2FUJI_HDR_VERSION, sizeof(config),
            static_cast<uint32_t>(format), 95u, source.chars, {}};
        if (source.chars) std::memcpy(config.source_sha256, pair.source_sha256, 32);
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_export_sdr_with_session(scopes.session(), &pair, &config, output.chars, &diagnostic);
        if (status == SONY2FUJI_STATUS_CANCELLED) throw NativeStatusError(status);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
    } catch (...) { handleHdrException(env, "Not enough memory for SDR export"); }
}
