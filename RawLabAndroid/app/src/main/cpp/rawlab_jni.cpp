#include <jni.h>
#include <android/bitmap.h>
#include "render_request.h"
#include "recipe_probe_stages.h"
#include "recipe_white_balance_cache.h"
#include "core/jpeg_mpf.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>
#include <atomic>
#include <array>
#include <fstream>
#include "png16_decoder.h"
#include "png16_color.h"

static_assert(sizeof(sony2fuji_photo_effects_config) == 40,
    "Photo effects config ABI must remain a versioned 40-byte struct");
static_assert(sizeof(sony2fuji_geometry_config) == 40,
    "Geometry config ABI must remain a versioned 40-byte struct");
static_assert(sizeof(sony2fuji_perspective_config) == 16,
    "Perspective config ABI must remain a versioned 16-byte struct");
static_assert(sizeof(sony2fuji_tone_curve_config) == 544, "Curve v1 retains binary64 control points");

namespace {
struct SessionDeleter {
    void operator()(sony2fuji_session* session) const { sony2fuji_session_destroy(session); }
};
struct DisplayLensMetadata {
    bool present = false;
    std::array<std::string, 4> names;
    float focal = 0, aperture = 0, crop = 0;
    int orientation = 1;
    sony2fuji_lens_metadata value() const {
        return {SONY2FUJI_LENS_METADATA_VERSION, sizeof(sony2fuji_lens_metadata),
            names[0].c_str(), names[1].c_str(), names[2].c_str(), names[3].c_str(), focal, aperture, crop, 0, orientation};
    }
};
struct Session {
    std::mutex mutex;
    bool closed = false;
    DisplayLensMetadata displayLens;
    std::unique_ptr<sony2fuji_session, SessionDeleter> value;
    std::string appliedParamsJson;
    rawlab::RecipeWhiteBalanceCache recipeWhiteBalance;
    std::shared_ptr<std::atomic<jlong>> generation = std::make_shared<std::atomic<jlong>>(0);
    explicit Session(sony2fuji_session* pointer) : value(pointer) {}
    sony2fuji_session* get() const { return value.get(); }
};
struct HdrPairOwner {
    sony2fuji_hdr_image_pair_v1 value;
    explicit HdrPairOwner(sony2fuji_hdr_image_pair_v1 v) : value(v) {}
    ~HdrPairOwner() { sony2fuji_hdr_release_pair(&value); }
    HdrPairOwner(const HdrPairOwner&) = delete;
    HdrPairOwner& operator=(const HdrPairOwner&) = delete;
};
// Opaque IDs keep stale Java handles from becoming native pointers.
std::mutex sessionsMutex;
std::unordered_map<jlong, std::shared_ptr<Session>> sessions;
jlong nextId = 1;
// 取消信号不能等待覆盖整次处理的 sessionsMutex。
std::mutex cancellationMutex;
std::unordered_map<jlong, std::shared_ptr<std::atomic<jlong>>> cancellationStates;
std::mutex hdrPairsMutex;
std::unordered_map<jlong, std::shared_ptr<const HdrPairOwner>> hdrPairs;
jlong nextHdrPairId = 1;

struct CancellationScope {
    sony2fuji_session* session;
    std::shared_ptr<std::atomic<jlong>> generation;
    jlong expected;
    static int32_t cancelled(void* context) {
        const auto& self = *static_cast<CancellationScope*>(context);
        return self.generation->load(std::memory_order_acquire) != self.expected;
    }
    CancellationScope(Session& owner, jlong value)
        : session(owner.get()), generation(owner.generation), expected(value) {
        sony2fuji_session_set_cancellation_callback(session, value >= 0 ? cancelled : nullptr, this);
    }
    ~CancellationScope() { sony2fuji_session_set_cancellation_callback(session, nullptr, nullptr); }
    bool isCancelled() const { return expected >= 0 && generation->load(std::memory_order_acquire) != expected; }
};

void throwJava(JNIEnv* env, const char* type, const char* message) {
    if (!env->ExceptionCheck()) {
        jclass clazz = env->FindClass(type);
        if (clazz) {
            env->ThrowNew(clazz, message);
            env->DeleteLocalRef(clazz);
        }
    }
}

struct LocalRef {
    JNIEnv* env;
    jobject ref;
    LocalRef(JNIEnv* e, jobject r) : env(e), ref(r) {}
    ~LocalRef() { if (ref) env->DeleteLocalRef(ref); }
    LocalRef(const LocalRef&) = delete;
    LocalRef& operator=(const LocalRef&) = delete;
    LocalRef(LocalRef&& other) noexcept : env(other.env), ref(other.ref) { other.ref = nullptr; }
    void reset(jobject next = nullptr) {
        if (ref) env->DeleteLocalRef(ref);
        ref = next;
    }
    jobject get() const { return ref; }
    jclass asClass() const { return static_cast<jclass>(ref); }
    jstring asString() const { return static_cast<jstring>(ref); }
    jfloatArray asFloatArray() const { return static_cast<jfloatArray>(ref); }
    jintArray asIntArray() const { return static_cast<jintArray>(ref); }
    jdoubleArray asDoubleArray() const { return static_cast<jdoubleArray>(ref); }
    jbyteArray asByteArray() const { return static_cast<jbyteArray>(ref); }
    explicit operator bool() const { return ref != nullptr; }
};

struct JniCache {
    struct ClassRef {
        jclass clazz = nullptr;
    };

    struct {
        jclass clazz = nullptr;
        jmethodID ctor = nullptr;
    } nativeFrame;

    struct {
        jclass clazz = nullptr;
        jmethodID ctor = nullptr;
    } nativeProcessingException;

    struct {
        jclass clazz = nullptr;
        jmethodID ctor = nullptr;
    } hdrProcessingException;

    struct {
        jclass clazz = nullptr;
        jmethodID ctor = nullptr;
    } dcpCompilationException;

    struct {
        jclass clazz = nullptr;
        jmethodID bytesCtor = nullptr;
    } javaString;

    struct {
        jclass clazz = nullptr;
        jfieldID path = nullptr;
        jfieldID pixels = nullptr;
        jfieldID width = nullptr;
        jfieldID height = nullptr;
        jfieldID pixelFormat = nullptr;
    } processInput;

    struct {
        jclass clazz = nullptr;
        jfieldID path = nullptr;
        jfieldID format = nullptr;
        jfieldID edge = nullptr;
        jfieldID longEdge = nullptr;
        jfieldID interactive = nullptr;
        jfieldID viewportPreview = nullptr;
    } processOutput;

    struct {
        jclass clazz = nullptr;
        jfieldID custom = nullptr;
        jfieldID temperature = nullptr;
        jfieldID tint = nullptr;
        jfieldID recipeActive = nullptr;
        jfieldID recipeStrength = nullptr;
    } processWhiteBalance;

    struct {
        jclass clazz = nullptr;
        jfieldID exposureEv = nullptr;
        jfieldID contrast = nullptr;
        jfieldID highlights = nullptr;
        jfieldID shadows = nullptr;
        jfieldID toneCurve = nullptr;
        jfieldID saturation = nullptr;
        jfieldID sharpening = nullptr;
    } processTone;

    struct {
        jclass clazz = nullptr;
        jfieldID enabled = nullptr;
        jfieldID luma = nullptr;
        jfieldID chroma = nullptr;
        jfieldID coarse = nullptr;
        jfieldID displayChroma = nullptr;
    } denoiseConfig;

    struct {
        jclass clazz = nullptr;
        jfieldID vignetteAmount = nullptr;
        jfieldID vignetteMidpoint = nullptr;
        jfieldID vignetteRoundness = nullptr;
        jfieldID vignetteFeather = nullptr;
        jfieldID vignetteHighlights = nullptr;
        jfieldID grainAmount = nullptr;
        jfieldID grainSize = nullptr;
        jfieldID grainRoughness = nullptr;
    } photoEffectsConfig;

    struct {
        jclass clazz = nullptr;
        jfieldID sourceRevision = nullptr;
        jfieldID requestRevision = nullptr;
        jfieldID output = nullptr;
    } hslProbeTarget;

    struct {
        jclass clazz = nullptr;
        jfieldID input = nullptr;
        jfieldID output = nullptr;
        jfieldID lutPath = nullptr;
        jfieldID lutStrength = nullptr;
        jfieldID whiteBalance = nullptr;
        jfieldID tone = nullptr;
        jfieldID denoise = nullptr;
        jfieldID effects = nullptr;
        jfieldID hsl = nullptr;
        jfieldID exposureMode = nullptr;
        jfieldID processingVersion = nullptr;
        jfieldID x3fMode = nullptr;
        jfieldID cancellationGeneration = nullptr;
        jfieldID backendOut = nullptr;
        jfieldID hslProbe = nullptr;
        jfieldID migrationOut = nullptr;
    } processRequest;

    struct {
        jclass clazz = nullptr;
        jfieldID cropX = nullptr;
        jfieldID cropY = nullptr;
        jfieldID cropWidth = nullptr;
        jfieldID cropHeight = nullptr;
        jfieldID quarterTurns = nullptr;
        jfieldID flipHorizontal = nullptr;
        jfieldID flipVertical = nullptr;
        jfieldID straightenDegrees = nullptr;
        jfieldID perspectiveHorizontal = nullptr;
        jfieldID perspectiveVertical = nullptr;
    } geometry;

    struct {
        jclass clazz = nullptr;
        jfieldID mode = nullptr;
        jfieldID points = nullptr;
    } toneCurve;

    struct {
        jclass clazz = nullptr;
        jfieldID shadowsHue = nullptr;
        jfieldID shadowsSaturation = nullptr;
        jfieldID midtonesHue = nullptr;
        jfieldID midtonesSaturation = nullptr;
        jfieldID highlightsHue = nullptr;
        jfieldID highlightsSaturation = nullptr;
    } colorGrading;

    struct {
        jclass clazz = nullptr;
        jfieldID blackPoint = nullptr;
        jfieldID whitePoint = nullptr;
        jfieldID curveStrength = nullptr;
        jfieldID curve = nullptr;
    } hdrTone;

    struct {
        jclass clazz = nullptr;
        jfieldID vibrance = nullptr;
        jfieldID hsl = nullptr;
        jfieldID grading = nullptr;
    } hdrColor;

    struct {
        jclass clazz = nullptr;
        jfieldID peakLimitEv = nullptr;
        jfieldID sdrExposureEv = nullptr;
        jfieldID sdrContrast = nullptr;
        jfieldID sdrSaturation = nullptr;
    } hdrRendition;

    struct {
        jclass clazz = nullptr;
        jfieldID sharpening = nullptr;
        jfieldID clarity = nullptr;
        jfieldID dehaze = nullptr;
        jfieldID denoise = nullptr;
    } hdrDetail;

    struct {
        jclass clazz = nullptr;
        jfieldID path = nullptr;
        jfieldID sha256 = nullptr;
        jfieldID strength = nullptr;
    } hdrLook;

    struct {
        jclass clazz = nullptr;
        jfieldID red = nullptr;
        jfieldID green = nullptr;
        jfieldID blue = nullptr;
    } hdrChannelCurves;

    struct {
        jclass clazz = nullptr;
        jfieldID exposureEv = nullptr;
        jfieldID temperature = nullptr;
        jfieldID tint = nullptr;
        jfieldID contrast = nullptr;
        jfieldID highlights = nullptr;
        jfieldID shadows = nullptr;
        jfieldID saturation = nullptr;
        jfieldID geometry = nullptr;
        jfieldID longEdge = nullptr;
        jfieldID tone = nullptr;
        jfieldID color = nullptr;
        jfieldID rendition = nullptr;
        jfieldID effects = nullptr;
        jfieldID detail = nullptr;
        jfieldID look = nullptr;
        jfieldID channelCurves = nullptr;
    } hdrRenderRequest;
};

JniCache gJniCache{};
std::once_flag gJniCacheOnce;
std::atomic<bool> gJniCacheReady{false};

jclass cacheGlobalClass(JNIEnv* env, const char* name) {
    LocalRef local(env, env->FindClass(name));
    if (!local) throw std::runtime_error(std::string("Missing JNI class: ") + name);
    auto global = static_cast<jclass>(env->NewGlobalRef(local.get()));
    if (!global) throw std::bad_alloc();
    return global;
}

jfieldID cacheField(JNIEnv* env, jclass clazz, const char* name, const char* sig) {
    jfieldID field = env->GetFieldID(clazz, name, sig);
    if (!field) throw std::runtime_error(std::string("Missing JNI field: ") + name + " " + sig);
    return field;
}

jmethodID cacheMethod(JNIEnv* env, jclass clazz, const char* name, const char* sig) {
    jmethodID method = env->GetMethodID(clazz, name, sig);
    if (!method) throw std::runtime_error(std::string("Missing JNI method: ") + name + " " + sig);
    return method;
}

void releaseJniCache(JNIEnv* env) {
    if (!gJniCacheReady.exchange(false, std::memory_order_acq_rel)) return;
    jclass* classes[] = {
        &gJniCache.nativeFrame.clazz,
        &gJniCache.nativeProcessingException.clazz,
        &gJniCache.hdrProcessingException.clazz,
        &gJniCache.dcpCompilationException.clazz,
        &gJniCache.javaString.clazz,
        &gJniCache.processInput.clazz,
        &gJniCache.processOutput.clazz,
        &gJniCache.processWhiteBalance.clazz,
        &gJniCache.processTone.clazz,
        &gJniCache.denoiseConfig.clazz,
        &gJniCache.photoEffectsConfig.clazz,
        &gJniCache.hslProbeTarget.clazz,
        &gJniCache.processRequest.clazz,
        &gJniCache.geometry.clazz,
        &gJniCache.toneCurve.clazz,
        &gJniCache.colorGrading.clazz,
        &gJniCache.hdrTone.clazz,
        &gJniCache.hdrColor.clazz,
        &gJniCache.hdrRendition.clazz,
        &gJniCache.hdrDetail.clazz,
        &gJniCache.hdrLook.clazz,
        &gJniCache.hdrChannelCurves.clazz,
        &gJniCache.hdrRenderRequest.clazz,
    };
    for (jclass* slot : classes) {
        if (*slot) {
            env->DeleteGlobalRef(*slot);
            *slot = nullptr;
        }
    }
}

void initJniCache(JNIEnv* env) {
    JniCache c{};
    try {
        c.nativeFrame.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeFrame");
        c.nativeFrame.ctor = cacheMethod(env, c.nativeFrame.clazz, "<init>", "(II[BFFI[I)V");

        c.nativeProcessingException.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeProcessingException");
        c.nativeProcessingException.ctor = cacheMethod(env, c.nativeProcessingException.clazz, "<init>", "(ILjava/lang/String;)V");

        c.hdrProcessingException.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/HDRProcessingException");
        c.hdrProcessingException.ctor = cacheMethod(env, c.hdrProcessingException.clazz, "<init>", "(III)V");

        c.dcpCompilationException.clazz = cacheGlobalClass(env, "com/rawlab/android/looks/DcpCompilationException");
        c.dcpCompilationException.ctor = cacheMethod(env, c.dcpCompilationException.clazz, "<init>", "(I)V");

        c.javaString.clazz = cacheGlobalClass(env, "java/lang/String");
        c.javaString.bytesCtor = cacheMethod(env, c.javaString.clazz, "<init>", "([BLjava/lang/String;)V");

        c.processInput.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeProcessInput");
        c.processInput.path = cacheField(env, c.processInput.clazz, "path", "Ljava/lang/String;");
        c.processInput.pixels = cacheField(env, c.processInput.clazz, "pixels", "Ljava/lang/Object;");
        c.processInput.width = cacheField(env, c.processInput.clazz, "width", "I");
        c.processInput.height = cacheField(env, c.processInput.clazz, "height", "I");
        c.processInput.pixelFormat = cacheField(env, c.processInput.clazz, "pixelFormat", "I");

        c.processOutput.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeProcessOutput");
        c.processOutput.path = cacheField(env, c.processOutput.clazz, "path", "Ljava/lang/String;");
        c.processOutput.format = cacheField(env, c.processOutput.clazz, "format", "I");
        c.processOutput.edge = cacheField(env, c.processOutput.clazz, "edge", "I");
        c.processOutput.longEdge = cacheField(env, c.processOutput.clazz, "longEdge", "I");
        c.processOutput.interactive = cacheField(env, c.processOutput.clazz, "interactive", "Z");
        c.processOutput.viewportPreview = cacheField(env, c.processOutput.clazz, "viewportPreview", "Z");

        c.processWhiteBalance.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeProcessWhiteBalance");
        c.processWhiteBalance.custom = cacheField(env, c.processWhiteBalance.clazz, "custom", "Z");
        c.processWhiteBalance.temperature = cacheField(env, c.processWhiteBalance.clazz, "temperature", "F");
        c.processWhiteBalance.tint = cacheField(env, c.processWhiteBalance.clazz, "tint", "F");
        c.processWhiteBalance.recipeActive = cacheField(env, c.processWhiteBalance.clazz, "recipeActive", "Z");
        c.processWhiteBalance.recipeStrength = cacheField(env, c.processWhiteBalance.clazz, "recipeStrength", "F");

        c.processTone.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeProcessTone");
        c.processTone.exposureEv = cacheField(env, c.processTone.clazz, "exposureEv", "F");
        c.processTone.contrast = cacheField(env, c.processTone.clazz, "contrast", "F");
        c.processTone.highlights = cacheField(env, c.processTone.clazz, "highlights", "F");
        c.processTone.shadows = cacheField(env, c.processTone.clazz, "shadows", "F");
        c.processTone.toneCurve = cacheField(env, c.processTone.clazz, "toneCurve", "F");
        c.processTone.saturation = cacheField(env, c.processTone.clazz, "saturation", "F");
        c.processTone.sharpening = cacheField(env, c.processTone.clazz, "sharpening", "F");

        c.denoiseConfig.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeDenoiseConfig");
        c.denoiseConfig.enabled = cacheField(env, c.denoiseConfig.clazz, "enabled", "Z");
        c.denoiseConfig.luma = cacheField(env, c.denoiseConfig.clazz, "luma", "F");
        c.denoiseConfig.chroma = cacheField(env, c.denoiseConfig.clazz, "chroma", "F");
        c.denoiseConfig.coarse = cacheField(env, c.denoiseConfig.clazz, "coarse", "F");
        c.denoiseConfig.displayChroma = cacheField(env, c.denoiseConfig.clazz, "displayChroma", "I");

        c.photoEffectsConfig.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativePhotoEffectsConfig");
        c.photoEffectsConfig.vignetteAmount = cacheField(env, c.photoEffectsConfig.clazz, "vignetteAmount", "F");
        c.photoEffectsConfig.vignetteMidpoint = cacheField(env, c.photoEffectsConfig.clazz, "vignetteMidpoint", "F");
        c.photoEffectsConfig.vignetteRoundness = cacheField(env, c.photoEffectsConfig.clazz, "vignetteRoundness", "F");
        c.photoEffectsConfig.vignetteFeather = cacheField(env, c.photoEffectsConfig.clazz, "vignetteFeather", "F");
        c.photoEffectsConfig.vignetteHighlights = cacheField(env, c.photoEffectsConfig.clazz, "vignetteHighlights", "F");
        c.photoEffectsConfig.grainAmount = cacheField(env, c.photoEffectsConfig.clazz, "grainAmount", "F");
        c.photoEffectsConfig.grainSize = cacheField(env, c.photoEffectsConfig.clazz, "grainSize", "F");
        c.photoEffectsConfig.grainRoughness = cacheField(env, c.photoEffectsConfig.clazz, "grainRoughness", "F");

        c.hslProbeTarget.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHslProbeTarget");
        c.hslProbeTarget.sourceRevision = cacheField(env, c.hslProbeTarget.clazz, "sourceRevision", "J");
        c.hslProbeTarget.requestRevision = cacheField(env, c.hslProbeTarget.clazz, "requestRevision", "J");
        c.hslProbeTarget.output = cacheField(env, c.hslProbeTarget.clazz, "output", "[F");

        c.processRequest.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeProcessRequest");
        c.processRequest.input = cacheField(env, c.processRequest.clazz, "input", "Lcom/rawlab/android/engine/NativeProcessInput;");
        c.processRequest.output = cacheField(env, c.processRequest.clazz, "output", "Lcom/rawlab/android/engine/NativeProcessOutput;");
        c.processRequest.lutPath = cacheField(env, c.processRequest.clazz, "lutPath", "Ljava/lang/String;");
        c.processRequest.lutStrength = cacheField(env, c.processRequest.clazz, "lutStrength", "F");
        c.processRequest.whiteBalance = cacheField(env, c.processRequest.clazz, "whiteBalance", "Lcom/rawlab/android/engine/NativeProcessWhiteBalance;");
        c.processRequest.tone = cacheField(env, c.processRequest.clazz, "tone", "Lcom/rawlab/android/engine/NativeProcessTone;");
        c.processRequest.denoise = cacheField(env, c.processRequest.clazz, "denoise", "Lcom/rawlab/android/engine/NativeDenoiseConfig;");
        c.processRequest.effects = cacheField(env, c.processRequest.clazz, "effects", "Lcom/rawlab/android/engine/NativePhotoEffectsConfig;");
        c.processRequest.hsl = cacheField(env, c.processRequest.clazz, "hsl", "[F");
        c.processRequest.exposureMode = cacheField(env, c.processRequest.clazz, "exposureMode", "I");
        c.processRequest.processingVersion = cacheField(env, c.processRequest.clazz, "processingVersion", "I");
        c.processRequest.x3fMode = cacheField(env, c.processRequest.clazz, "x3fMode", "I");
        c.processRequest.cancellationGeneration = cacheField(env, c.processRequest.clazz, "cancellationGeneration", "J");
        c.processRequest.backendOut = cacheField(env, c.processRequest.clazz, "backendOut", "[I");
        c.processRequest.hslProbe = cacheField(env, c.processRequest.clazz, "hslProbe", "Lcom/rawlab/android/engine/NativeHslProbeTarget;");
        c.processRequest.migrationOut = cacheField(env, c.processRequest.clazz, "migrationOut", "[F");

        c.geometry.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeGeometry");
        c.geometry.cropX = cacheField(env, c.geometry.clazz, "cropX", "F");
        c.geometry.cropY = cacheField(env, c.geometry.clazz, "cropY", "F");
        c.geometry.cropWidth = cacheField(env, c.geometry.clazz, "cropWidth", "F");
        c.geometry.cropHeight = cacheField(env, c.geometry.clazz, "cropHeight", "F");
        c.geometry.quarterTurns = cacheField(env, c.geometry.clazz, "quarterTurns", "I");
        c.geometry.flipHorizontal = cacheField(env, c.geometry.clazz, "flipHorizontal", "Z");
        c.geometry.flipVertical = cacheField(env, c.geometry.clazz, "flipVertical", "Z");
        c.geometry.straightenDegrees = cacheField(env, c.geometry.clazz, "straightenDegrees", "F");
        c.geometry.perspectiveHorizontal = cacheField(env, c.geometry.clazz, "perspectiveHorizontal", "F");
        c.geometry.perspectiveVertical = cacheField(env, c.geometry.clazz, "perspectiveVertical", "F");

        c.toneCurve.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeToneCurve");
        c.toneCurve.mode = cacheField(env, c.toneCurve.clazz, "mode", "I");
        c.toneCurve.points = cacheField(env, c.toneCurve.clazz, "points", "[D");

        c.colorGrading.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeColorGrading");
        c.colorGrading.shadowsHue = cacheField(env, c.colorGrading.clazz, "shadowsHue", "F");
        c.colorGrading.shadowsSaturation = cacheField(env, c.colorGrading.clazz, "shadowsSaturation", "F");
        c.colorGrading.midtonesHue = cacheField(env, c.colorGrading.clazz, "midtonesHue", "F");
        c.colorGrading.midtonesSaturation = cacheField(env, c.colorGrading.clazz, "midtonesSaturation", "F");
        c.colorGrading.highlightsHue = cacheField(env, c.colorGrading.clazz, "highlightsHue", "F");
        c.colorGrading.highlightsSaturation = cacheField(env, c.colorGrading.clazz, "highlightsSaturation", "F");

        c.hdrTone.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHDRTone");
        c.hdrTone.blackPoint = cacheField(env, c.hdrTone.clazz, "blackPoint", "F");
        c.hdrTone.whitePoint = cacheField(env, c.hdrTone.clazz, "whitePoint", "F");
        c.hdrTone.curveStrength = cacheField(env, c.hdrTone.clazz, "curveStrength", "F");
        c.hdrTone.curve = cacheField(env, c.hdrTone.clazz, "curve", "Lcom/rawlab/android/engine/NativeToneCurve;");

        c.hdrColor.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHDRColor");
        c.hdrColor.vibrance = cacheField(env, c.hdrColor.clazz, "vibrance", "F");
        c.hdrColor.hsl = cacheField(env, c.hdrColor.clazz, "hsl", "[F");
        c.hdrColor.grading = cacheField(env, c.hdrColor.clazz, "grading", "Lcom/rawlab/android/engine/NativeColorGrading;");

        c.hdrRendition.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHDRRendition");
        c.hdrRendition.peakLimitEv = cacheField(env, c.hdrRendition.clazz, "peakLimitEv", "F");
        c.hdrRendition.sdrExposureEv = cacheField(env, c.hdrRendition.clazz, "sdrExposureEv", "F");
        c.hdrRendition.sdrContrast = cacheField(env, c.hdrRendition.clazz, "sdrContrast", "F");
        c.hdrRendition.sdrSaturation = cacheField(env, c.hdrRendition.clazz, "sdrSaturation", "F");

        c.hdrDetail.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHDRDetail");
        c.hdrDetail.sharpening = cacheField(env, c.hdrDetail.clazz, "sharpening", "F");
        c.hdrDetail.clarity = cacheField(env, c.hdrDetail.clazz, "clarity", "F");
        c.hdrDetail.dehaze = cacheField(env, c.hdrDetail.clazz, "dehaze", "F");
        c.hdrDetail.denoise = cacheField(env, c.hdrDetail.clazz, "denoise", "F");

        c.hdrLook.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHDRLook");
        c.hdrLook.path = cacheField(env, c.hdrLook.clazz, "path", "Ljava/lang/String;");
        c.hdrLook.sha256 = cacheField(env, c.hdrLook.clazz, "sha256", "Ljava/lang/String;");
        c.hdrLook.strength = cacheField(env, c.hdrLook.clazz, "strength", "F");

        c.hdrChannelCurves.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHDRChannelCurves");
        c.hdrChannelCurves.red = cacheField(env, c.hdrChannelCurves.clazz, "red", "Lcom/rawlab/android/engine/NativeToneCurve;");
        c.hdrChannelCurves.green = cacheField(env, c.hdrChannelCurves.clazz, "green", "Lcom/rawlab/android/engine/NativeToneCurve;");
        c.hdrChannelCurves.blue = cacheField(env, c.hdrChannelCurves.clazz, "blue", "Lcom/rawlab/android/engine/NativeToneCurve;");

        c.hdrRenderRequest.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/NativeHDRRenderRequest");
        c.hdrRenderRequest.exposureEv = cacheField(env, c.hdrRenderRequest.clazz, "exposureEv", "F");
        c.hdrRenderRequest.temperature = cacheField(env, c.hdrRenderRequest.clazz, "temperature", "F");
        c.hdrRenderRequest.tint = cacheField(env, c.hdrRenderRequest.clazz, "tint", "F");
        c.hdrRenderRequest.contrast = cacheField(env, c.hdrRenderRequest.clazz, "contrast", "F");
        c.hdrRenderRequest.highlights = cacheField(env, c.hdrRenderRequest.clazz, "highlights", "F");
        c.hdrRenderRequest.shadows = cacheField(env, c.hdrRenderRequest.clazz, "shadows", "F");
        c.hdrRenderRequest.saturation = cacheField(env, c.hdrRenderRequest.clazz, "saturation", "F");
        c.hdrRenderRequest.geometry = cacheField(env, c.hdrRenderRequest.clazz, "geometry", "Lcom/rawlab/android/engine/NativeGeometry;");
        c.hdrRenderRequest.longEdge = cacheField(env, c.hdrRenderRequest.clazz, "longEdge", "I");
        c.hdrRenderRequest.tone = cacheField(env, c.hdrRenderRequest.clazz, "tone", "Lcom/rawlab/android/engine/NativeHDRTone;");
        c.hdrRenderRequest.color = cacheField(env, c.hdrRenderRequest.clazz, "color", "Lcom/rawlab/android/engine/NativeHDRColor;");
        c.hdrRenderRequest.rendition = cacheField(env, c.hdrRenderRequest.clazz, "rendition", "Lcom/rawlab/android/engine/NativeHDRRendition;");
        c.hdrRenderRequest.effects = cacheField(env, c.hdrRenderRequest.clazz, "effects", "Lcom/rawlab/android/engine/NativePhotoEffectsConfig;");
        c.hdrRenderRequest.detail = cacheField(env, c.hdrRenderRequest.clazz, "detail", "Lcom/rawlab/android/engine/NativeHDRDetail;");
        c.hdrRenderRequest.look = cacheField(env, c.hdrRenderRequest.clazz, "look", "Lcom/rawlab/android/engine/NativeHDRLook;");
        c.hdrRenderRequest.channelCurves = cacheField(env, c.hdrRenderRequest.clazz, "channelCurves", "Lcom/rawlab/android/engine/NativeHDRChannelCurves;");

        gJniCache = c;
        gJniCacheReady.store(true, std::memory_order_release);
    } catch (...) {
        gJniCache = c;
        gJniCacheReady.store(true, std::memory_order_release);
        releaseJniCache(env);
        throw;
    }
}

const JniCache& jniCache(JNIEnv* env) {
    std::call_once(gJniCacheOnce, [&] { initJniCache(env); });
    return gJniCache;
}

struct HDRStatusError : std::runtime_error {
    sony2fuji_status status;sony2fuji_hdr_diagnostic_v1 diagnostic;
    HDRStatusError(sony2fuji_status value,sony2fuji_hdr_diagnostic_v1 detail)
        : std::runtime_error("HDR processing failed"),status(value),diagnostic(detail) {}
};
void throwHDRFailure(JNIEnv* env,const std::exception& error) {
    const auto* detail=dynamic_cast<const HDRStatusError*>(&error);
    if(!detail) {throwJava(env,"java/io/IOException",error.what());return;}
    if(env->ExceptionCheck())return;
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

struct NativeStatusError : std::runtime_error {
    sony2fuji_status status;
    NativeStatusError(sony2fuji_status value)
        : std::runtime_error(sony2fuji_status_message(value)), status(value) {}
};

void throwNativeStatus(JNIEnv* env, const NativeStatusError& error) {
    if (env->ExceptionCheck()) return;
    try {
        const auto& cache = jniCache(env);
        LocalRef message(env, env->NewStringUTF(error.what()));
        if (!message) return;
        LocalRef exception(env, env->NewObject(cache.nativeProcessingException.clazz, cache.nativeProcessingException.ctor,
            static_cast<jint>(error.status), message.get()));
        if (exception) env->Throw(static_cast<jthrowable>(exception.get()));
    } catch (...) {
        env->ExceptionClear();
        throwJava(env, "java/io/IOException", error.what());
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

void check(sony2fuji_status status, sony2fuji_session* session = nullptr) {
    if (status != SONY2FUJI_STATUS_OK && status != SONY2FUJI_STATUS_CANCELLED && session) {
        const char* message = sony2fuji_session_x3f_error(session);
        if (message && *message) throw std::runtime_error(message);
    }
    if (status == SONY2FUJI_STATUS_IO_ERROR || status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR ||
        status == SONY2FUJI_STATUS_CANCELLED)
        throw NativeStatusError(status);
    rawlab::checkStatus(status);
}
sony2fuji_tone_curve_config curveConfig(JNIEnv* env, jint mode, jdoubleArray points) {
    if (!points) throw std::invalid_argument("Missing curve points");
    const jsize length = env->GetArrayLength(points);
    if (length < 0 || length % 2 != 0 ||
        static_cast<uint32_t>(length) > 2u * SONY2FUJI_TONE_CURVE_MAX_POINTS || (mode != 0 && mode != 1))
        throw std::invalid_argument("Invalid curve points");
    sony2fuji_tone_curve_config config{};
    config.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION; config.struct_size = sizeof(config);
    config.mode = static_cast<sony2fuji_curve_mode>(mode); config.count = static_cast<uint32_t>(length / 2);
    std::vector<double> values(static_cast<size_t>(length));
    if (length) env->GetDoubleArrayRegion(points, 0, length, values.data());
    if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read curve points");
    for (uint32_t i = 0; i < config.count; ++i) config.points[i] = {values[i * 2], values[i * 2 + 1]};
    return config;
}

sony2fuji_tone_curve_config marshalToneCurve(JNIEnv* env, const JniCache& cache, jobject curveObj) {
    if (!curveObj) throw std::invalid_argument("Missing tone curve");
    const jint mode = env->GetIntField(curveObj, cache.toneCurve.mode);
    LocalRef pointsRef(env, env->GetObjectField(curveObj, cache.toneCurve.points));
    if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read tone curve");
    return curveConfig(env, mode, pointsRef.asDoubleArray());
}

sony2fuji_photo_effects_config marshalPhotoEffects(JNIEnv* env, const JniCache& cache, jobject effectsObj) {
    if (!effectsObj) throw std::invalid_argument("Missing photo effects config");
    sony2fuji_photo_effects_config config{
        SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION,
        sizeof(sony2fuji_photo_effects_config),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.vignetteAmount),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.vignetteMidpoint),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.vignetteRoundness),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.vignetteFeather),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.vignetteHighlights),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.grainAmount),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.grainSize),
        env->GetFloatField(effectsObj, cache.photoEffectsConfig.grainRoughness),
    };
    if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read photo effects config");
    return config;
}

void marshalGeometryFields(JNIEnv* env, const JniCache& cache, jobject geometryObj, sony2fuji_hdr_request_v1& request) {
    if (!geometryObj) throw std::invalid_argument("Missing HDR geometry");
    request.crop_x = env->GetFloatField(geometryObj, cache.geometry.cropX);
    request.crop_y = env->GetFloatField(geometryObj, cache.geometry.cropY);
    request.crop_width = env->GetFloatField(geometryObj, cache.geometry.cropWidth);
    request.crop_height = env->GetFloatField(geometryObj, cache.geometry.cropHeight);
    request.quarter_turns = env->GetIntField(geometryObj, cache.geometry.quarterTurns);
    request.flip_horizontal = env->GetBooleanField(geometryObj, cache.geometry.flipHorizontal) ? 1u : 0u;
    request.flip_vertical = env->GetBooleanField(geometryObj, cache.geometry.flipVertical) ? 1u : 0u;
    request.straighten_degrees = env->GetFloatField(geometryObj, cache.geometry.straightenDegrees);
    request.perspective_horizontal = env->GetFloatField(geometryObj, cache.geometry.perspectiveHorizontal);
    request.perspective_vertical = env->GetFloatField(geometryObj, cache.geometry.perspectiveVertical);
    if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR geometry");
}

struct MarshalledHdrRequest {
    sony2fuji_hdr_request_v8 value{};
    std::string lookPath;
    MarshalledHdrRequest() = default;
    MarshalledHdrRequest(const MarshalledHdrRequest&) = delete;
    MarshalledHdrRequest& operator=(const MarshalledHdrRequest&) = delete;
    sony2fuji_hdr_request_v1& base() { return value.base.base.base.base.base.base.base; }
};

void marshalHdrRenderRequest(JNIEnv* env, jobject requestObj, MarshalledHdrRequest& out) {
    if (!requestObj) throw std::invalid_argument("Missing HDR render request");
    const auto& cache = jniCache(env);
    auto& result = out.value;
    auto& look = result.base;
    auto& detail = look.base;
    auto& effectsRequest = detail.base;
    auto& rendition = effectsRequest.base;
    auto& color = rendition.base;
    auto& tone = color.base;
    auto& request = tone.base;

    request.version = SONY2FUJI_HDR_VERSION;
    request.struct_size = sizeof(request);
    request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_VERSION;
    request.exposure_ev = env->GetFloatField(requestObj, cache.hdrRenderRequest.exposureEv);
    request.temperature = env->GetFloatField(requestObj, cache.hdrRenderRequest.temperature);
    request.tint = env->GetFloatField(requestObj, cache.hdrRenderRequest.tint);
    request.contrast = env->GetFloatField(requestObj, cache.hdrRenderRequest.contrast);
    request.highlights = env->GetFloatField(requestObj, cache.hdrRenderRequest.highlights);
    request.shadows = env->GetFloatField(requestObj, cache.hdrRenderRequest.shadows);
    request.saturation = env->GetFloatField(requestObj, cache.hdrRenderRequest.saturation);
    const jint longEdge = env->GetIntField(requestObj, cache.hdrRenderRequest.longEdge);
    if (env->ExceptionCheck() || longEdge < 0 || longEdge > 65535)
        throw std::invalid_argument("Invalid HDR render request");
    request.long_edge = static_cast<uint32_t>(longEdge);
    LocalRef geometryRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.geometry));
    marshalGeometryFields(env, cache, geometryRef.get(), request);

    LocalRef toneRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.tone));
    LocalRef colorRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.color));
    LocalRef renditionRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.rendition));
    LocalRef effectsRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.effects));
    LocalRef detailRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.detail));
    LocalRef lookRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.look));
    LocalRef channelCurvesRef(env, env->GetObjectField(requestObj, cache.hdrRenderRequest.channelCurves));
    if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR request sections");

    if ((colorRef && !toneRef) || (renditionRef && !colorRef) || (effectsRef && !renditionRef) ||
        (detailRef && !effectsRef) || (lookRef && !detailRef) || (channelCurvesRef && !lookRef)) {
        throw std::invalid_argument("Invalid HDR render request");
    }

    if (toneRef) {
        request.struct_size = sizeof(tone);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_TONE_VERSION;
        tone.black_point = env->GetFloatField(toneRef.get(), cache.hdrTone.blackPoint);
        tone.white_point = env->GetFloatField(toneRef.get(), cache.hdrTone.whitePoint);
        tone.curve_strength = env->GetFloatField(toneRef.get(), cache.hdrTone.curveStrength);
        LocalRef curveRef(env, env->GetObjectField(toneRef.get(), cache.hdrTone.curve));
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR tone settings");
        tone.curve = marshalToneCurve(env, cache, curveRef.get());
    }
    if (colorRef) {
        request.struct_size = sizeof(color);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_COLOR_VERSION;
        color.vibrance = env->GetFloatField(colorRef.get(), cache.hdrColor.vibrance);
        LocalRef hslRef(env, env->GetObjectField(colorRef.get(), cache.hdrColor.hsl));
        auto hslArr = hslRef.asFloatArray();
        if (!hslArr || env->GetArrayLength(hslArr) != 3 * SONY2FUJI_HSL_CHANNELS)
            throw std::invalid_argument("Invalid HDR HSL settings");
        jfloat hslData[3 * SONY2FUJI_HSL_CHANNELS]{};
        env->GetFloatArrayRegion(hslArr, 0, 3 * SONY2FUJI_HSL_CHANNELS, hslData);
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR HSL settings");
        color.hsl.version = SONY2FUJI_HSL_CONFIG_VERSION;
        color.hsl.struct_size = sizeof(color.hsl);
        std::copy_n(hslData, SONY2FUJI_HSL_CHANNELS, color.hsl.hue);
        std::copy_n(hslData + SONY2FUJI_HSL_CHANNELS, SONY2FUJI_HSL_CHANNELS, color.hsl.saturation);
        std::copy_n(hslData + 2 * SONY2FUJI_HSL_CHANNELS, SONY2FUJI_HSL_CHANNELS, color.hsl.lightness);
        LocalRef gradingRef(env, env->GetObjectField(colorRef.get(), cache.hdrColor.grading));
        if (!gradingRef) throw std::invalid_argument("Missing HDR color grading");
        color.grading = {
            SONY2FUJI_COLOR_GRADING_CONFIG_VERSION,
            sizeof(color.grading),
            env->GetFloatField(gradingRef.get(), cache.colorGrading.shadowsHue),
            env->GetFloatField(gradingRef.get(), cache.colorGrading.shadowsSaturation),
            env->GetFloatField(gradingRef.get(), cache.colorGrading.midtonesHue),
            env->GetFloatField(gradingRef.get(), cache.colorGrading.midtonesSaturation),
            env->GetFloatField(gradingRef.get(), cache.colorGrading.highlightsHue),
            env->GetFloatField(gradingRef.get(), cache.colorGrading.highlightsSaturation),
        };
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR color grading");
    }
    if (renditionRef) {
        request.struct_size = sizeof(rendition);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_RENDITION_VERSION;
        rendition.peak_limit_ev = env->GetFloatField(renditionRef.get(), cache.hdrRendition.peakLimitEv);
        rendition.sdr_exposure_ev = env->GetFloatField(renditionRef.get(), cache.hdrRendition.sdrExposureEv);
        rendition.sdr_contrast = env->GetFloatField(renditionRef.get(), cache.hdrRendition.sdrContrast);
        rendition.sdr_saturation = env->GetFloatField(renditionRef.get(), cache.hdrRendition.sdrSaturation);
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR rendition settings");
    }
    if (effectsRef) {
        request.struct_size = sizeof(effectsRequest);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_EFFECTS_VERSION;
        effectsRequest.effects = marshalPhotoEffects(env, cache, effectsRef.get());
    }
    if (detailRef) {
        request.struct_size = sizeof(detail);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_DETAIL_VERSION;
        detail.sharpening = env->GetFloatField(detailRef.get(), cache.hdrDetail.sharpening);
        detail.clarity = env->GetFloatField(detailRef.get(), cache.hdrDetail.clarity);
        detail.dehaze = env->GetFloatField(detailRef.get(), cache.hdrDetail.dehaze);
        detail.denoise = env->GetFloatField(detailRef.get(), cache.hdrDetail.denoise);
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR detail settings");
    }
    if (lookRef) {
        request.struct_size = sizeof(look);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_LOOK_VERSION;
        look.look_strength = env->GetFloatField(lookRef.get(), cache.hdrLook.strength);
        LocalRef pathRef(env, env->GetObjectField(lookRef.get(), cache.hdrLook.path));
        LocalRef shaRef(env, env->GetObjectField(lookRef.get(), cache.hdrLook.sha256));
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR look settings");
        if (bool(pathRef) != bool(shaRef)) throw std::invalid_argument("Invalid HDR render request");
        if (pathRef && shaRef) {
            const char* pChars = env->GetStringUTFChars(pathRef.asString(), nullptr);
            if (!pChars) throw std::bad_alloc();
            out.lookPath = pChars;
            env->ReleaseStringUTFChars(pathRef.asString(), pChars);
            const char* sChars = env->GetStringUTFChars(shaRef.asString(), nullptr);
            if (!sChars) throw std::bad_alloc();
            const size_t sLen = std::strlen(sChars);
            if (sLen != 64) {
                env->ReleaseStringUTFChars(shaRef.asString(), sChars);
                throw std::invalid_argument("Invalid HDR render request");
            }
            std::copy_n(sChars, 64, look.look_sha256);
            env->ReleaseStringUTFChars(shaRef.asString(), sChars);
            look.look_path = out.lookPath.c_str();
        }
    }
    if (channelCurvesRef) {
        LocalRef redRef(env, env->GetObjectField(channelCurvesRef.get(), cache.hdrChannelCurves.red));
        LocalRef greenRef(env, env->GetObjectField(channelCurvesRef.get(), cache.hdrChannelCurves.green));
        LocalRef blueRef(env, env->GetObjectField(channelCurvesRef.get(), cache.hdrChannelCurves.blue));
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read HDR channel curves");
        result.channels[0] = marshalToneCurve(env, cache, redRef.get());
        result.channels[1] = marshalToneCurve(env, cache, greenRef.get());
        result.channels[2] = marshalToneCurve(env, cache, blueRef.get());
        request.struct_size = sizeof(result);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION;
    }
}

void sampleHslProbe(JNIEnv* env, const sony2fuji_hsl_probe* probe, jlong sourceRevision, jlong requestRevision,
    jfloatArray output) {
    if (!output || env->GetArrayLength(output) != 13) throw std::invalid_argument("Invalid HSL probe output");
    float point[2]; env->GetFloatArrayRegion(output, 0, 2, point);
    if (env->ExceptionCheck()) return;
    sony2fuji_hsl_probe_query query{SONY2FUJI_HSL_PROBE_VERSION, sizeof(query),
        static_cast<uint64_t>(sourceRevision), static_cast<uint64_t>(requestRevision), point[0], point[1]};
    sony2fuji_hsl_probe_result sample{};
    check(sony2fuji_hsl_probe_sample(probe, &query, &sample));
    float values[13]{static_cast<float>(sample.availability), static_cast<float>(sample.quality),
        sample.rgb[0], sample.rgb[1], sample.rgb[2]};
    std::copy(std::begin(sample.weights), std::end(sample.weights), values+5);
    env->SetFloatArrayRegion(output, 0, 13, values);
}

struct UtfChars {
    JNIEnv* env;
    jstring value;
    const char* chars;
    UtfChars(JNIEnv* e, jstring s) : env(e), value(s), chars(s ? e->GetStringUTFChars(s, nullptr) : nullptr) {
        if (s && !chars) throw std::bad_alloc();
    }
    ~UtfChars() { if (chars) env->ReleaseStringUTFChars(value, chars); }
};
struct BitmapPixels {
    JNIEnv* env;
    jobject value;
    void* locked = nullptr;
    const void* bytes = nullptr;
    uint32_t stride = 0;
    std::vector<uint8_t> packed;
    BitmapPixels(JNIEnv* e, jobject bitmap, jint width, jint height, jint format, bool compactInput = true) : env(e), value(bitmap) {
        if (!bitmap) {
            if (width != 0 || height != 0 || format != 0) throw std::invalid_argument("Invalid RAW image buffer");
            return;
        }
        if (format == SONY2FUJI_PIXEL_RGBA16) {
            if (width <= 0 || height <= 0 || uint64_t(width) * height > 128000000)
                throw std::invalid_argument("Invalid display buffer dimensions");
            const auto capacity = env->GetDirectBufferCapacity(bitmap);
            bytes = env->GetDirectBufferAddress(bitmap);
            if (!bytes || capacity != int64_t(width) * height * 8)
                throw std::invalid_argument("Invalid RGBA16 display buffer");
            stride = static_cast<uint32_t>(width) * 8;
            return;
        }
        AndroidBitmapInfo info{};
        if (width <= 0 || height <= 0 || format != SONY2FUJI_PIXEL_RGBA8 ||
            AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
            info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.width != static_cast<uint32_t>(width) ||
            info.height != static_cast<uint32_t>(height) || info.stride < uint64_t(width) * 4)
            throw std::invalid_argument("Invalid display bitmap");
        stride = info.stride;
        const size_t rowBytes = static_cast<size_t>(width) * 4;
        if (static_cast<size_t>(height) > std::numeric_limits<size_t>::max() / rowBytes)
            throw std::invalid_argument("Display bitmap is too large");
        const auto result = AndroidBitmap_lockPixels(env, bitmap, &locked);
        if (result == ANDROID_BITMAP_RESULT_ALLOCATION_FAILED) throw std::bad_alloc();
        if (result != ANDROID_BITMAP_RESULT_SUCCESS) throw std::runtime_error("Unable to lock display bitmap");
        try {
            if (!locked) throw std::runtime_error("Display bitmap has no pixels");
            bytes = locked;
            // C ABI 接收紧凑 RGBA；只有平台给出填充行时才在原生内存重新排布。
            if (compactInput && info.stride != rowBytes) {
                packed.resize(rowBytes * height);
                for (int y = 0; y < height; ++y)
                    std::memcpy(packed.data() + size_t(y) * rowBytes,
                        static_cast<const uint8_t*>(locked) + size_t(y) * info.stride, rowBytes);
                bytes = packed.data();
            }
        } catch (...) {
            AndroidBitmap_unlockPixels(env, value);
            locked = nullptr;
            throw;
        }
    }
    ~BitmapPixels() { if (locked) AndroidBitmap_unlockPixels(env, value); }
};
struct ByteArrayElements {
    JNIEnv* env;
    jbyteArray value;
    jbyte* bytes;
    ByteArrayElements(JNIEnv* e, jbyteArray array) : env(e), value(array), bytes(array ? e->GetByteArrayElements(array, nullptr) : nullptr) {
        if (array && !bytes) throw std::bad_alloc();
    }
    ~ByteArrayElements() { if (bytes) env->ReleaseByteArrayElements(value, bytes, JNI_ABORT); }
};
struct Buffer {
    sony2fuji_buffer value{};
    ~Buffer() { sony2fuji_release_buffer(&value); }
};
struct DcpBlob {
    sony2fuji_blob value{};
    ~DcpBlob() { sony2fuji_release_blob(&value); }
};
bool isNormalX3f(const char* input, jint mode) {
    if (mode != SONY2FUJI_X3F_NORMAL || !input) return false;
    // 导入副本可能没有扩展名；白平衡基准跟随实际文件格式。
    std::ifstream file(input, std::ios::binary);
    char signature[4]{};
    return file.read(signature, sizeof(signature)) && std::memcmp(signature, "FOVb", 4) == 0;
}
std::string processingOnlyParamsJson(int processingVersion, const char* exposureMode = "scene") {
    const int version = std::max(1, std::min(3, processingVersion));
    return "{\"schema_version\":5,\"processing\":{\"family\":\"rawlab\",\"version\":" +
        std::to_string(version) + ",\"quality\":\"standard\"},\"input\":{\"path\":\"session.raw\",\"type\":\"raw\"},"
        "\"edits\":{\"exposure\":{\"mode\":\"" + std::string(exposureMode) +
        "\",\"ev\":0.0,\"brightness\":1.0},\"white_balance\":{\"mode\":\"camera\"},"
        "\"look\":{\"path\":null,\"strength\":1.0},\"detail\":{\"sharpening\":0.0}},"
        "\"output\":{\"path\":\"session.png\",\"format\":\"png\",\"size\":{\"mode\":\"native\"}}}";
}
std::optional<rawlab::RecipeWhiteBalance> probeRecipeWhiteBalance(Session& owner, const char* input) {
    auto* session = owner.get();
    rawlab::RecipeProbeStageScope stages(session, owner.appliedParamsJson);
    check(sony2fuji_session_set_interactive_preview(session, 0));
    auto neutral = rawlab::makeRequest(input, nullptr, nullptr, 0, 0, false, 6500, 0, 32, rawlab::ExportFormat::JPEG);
    Buffer buffer;
    check(sony2fuji_process(session, &neutral, &buffer.value), session);
    float cameraTemperature = 0, cameraTint = 0;
    const auto status = sony2fuji_session_get_raw_white_balance(session, &cameraTemperature, &cameraTint);
    if (status == SONY2FUJI_STATUS_UNSUPPORTED) return std::nullopt;
    check(status);
    if (!std::isfinite(cameraTemperature) || !std::isfinite(cameraTint))
        throw std::runtime_error("Cannot resolve target RAW white balance for master recipe");
    return rawlab::RecipeWhiteBalance{std::round(cameraTemperature), std::round(cameraTint)};
}

void prepareRecipeWb(Session& owner, const char* input, bool active, float strength,
    bool& custom, float& temperature, float& tint, int processingVersion, int x3fMode, int exposureMode) {
    if (!active || (!custom && tint * strength == 0)) return;
    const auto camera = owner.recipeWhiteBalance.resolve(input, processingVersion, x3fMode, exposureMode,
        [&]() -> std::optional<rawlab::RecipeWhiteBalance> {
            if (isNormalX3f(input, x3fMode)) return rawlab::RecipeWhiteBalance{6500, 0};
            return probeRecipeWhiteBalance(owner, input);
        });
    if (!camera) {
        // 无法校准色温和色调时，沿用基础显影的相机白平衡。
        custom = false;
        return;
    }
    if (!custom) temperature = camera->temperature;
    tint = std::clamp(camera->tint + tint * strength, -150.0f, 150.0f);
    custom = true;
}
}

namespace {
std::shared_ptr<Session> acquireSession(jlong id) {
    std::lock_guard<std::mutex> lock(sessionsMutex);
    const auto found = sessions.find(id);
    if (found == sessions.end()) throw std::invalid_argument("Processor is closed");
    return found->second;
}

struct SessionGuard {
    std::shared_ptr<Session> owner;
    std::unique_lock<std::mutex> lock;
    explicit SessionGuard(jlong id) : owner(acquireSession(id)), lock(owner->mutex) {
        if (owner->closed || !owner->get()) throw std::invalid_argument("Processor is closed");
    }
    Session& session() { return *owner; }
    sony2fuji_session* get() const { return owner->get(); }
};
jobjectArray strings(JNIEnv* env, const std::vector<std::string>& values) {
    const auto& cache = jniCache(env);
    LocalRef charset(env, env->NewStringUTF("UTF-8"));
    if (!charset) return nullptr;
    auto result = env->NewObjectArray(static_cast<jsize>(values.size()), cache.javaString.clazz, nullptr);
    if (!result) return nullptr;
    for (size_t i = 0; i < values.size() && !env->ExceptionCheck(); ++i) {
        LocalRef bytes(env, env->NewByteArray(static_cast<jsize>(values[i].size())));
        if (!bytes) return nullptr;
        env->SetByteArrayRegion(bytes.asByteArray(), 0, static_cast<jsize>(values[i].size()),
            reinterpret_cast<const jbyte*>(values[i].data()));
        LocalRef value(env, env->NewObject(cache.javaString.clazz, cache.javaString.bytesCtor, bytes.get(), charset.get()));
        if (!value) return nullptr;
        env->SetObjectArrayElement(result, static_cast<jsize>(i), value.get());
    }
    return env->ExceptionCheck() ? nullptr : result;
}
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_raster_NativePng16_nativeDecode(JNIEnv* env, jobject, jstring path,
    jint width, jint height, jint orientation) {
    try {
        UtfChars source(env, path);
        auto pixels = rawlab::decodePng16(source.chars, width, height, orientation);
        auto buffer = env->NewDirectByteBuffer(pixels.get(), int64_t(width) * height * 8);
        if (buffer) pixels.release();
        return buffer;
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for PNG");
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_rawlab_android_raster_NativeMpf_nativeInspectSdrJpegMpf(JNIEnv* env, jobject, jstring path) {
    try {
        UtfChars source(env, path);
        if (!source.chars) return -1;
        return static_cast<jint>(sony2fuji::inspectSdrJpegMpf(std::filesystem::u8path(source.chars)));
    } catch (...) {
        return -1;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_raster_NativePng16_nativeConvert(JNIEnv* env, jobject, jobject pixels,
    jbyteArray iccProfile) {
    try {
        auto* data = pixels ? static_cast<uint16_t*>(env->GetDirectBufferAddress(pixels)) : nullptr;
        const auto bytes = pixels ? env->GetDirectBufferCapacity(pixels) : -1;
        const jsize profileLength = iccProfile ? env->GetArrayLength(iccProfile) : 0;
        if (!data || bytes < 0 || bytes % 8 != 0 || profileLength <= 0)
            throw std::invalid_argument("Invalid PNG color conversion buffer");
        ByteArrayElements profile(env, iccProfile);
        if (env->ExceptionCheck()) return;
        rawlab::convertPng16ToSrgb(data, static_cast<size_t>(bytes / 8),
            profile.bytes, static_cast<size_t>(profileLength));
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for PNG");
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_raster_NativePng16_nativeRelease(JNIEnv* env, jobject, jobject pixels) {
    rawlab::Png16Deleter{}(static_cast<uint16_t*>(env->GetDirectBufferAddress(pixels)));
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetLensDatabase(JNIEnv* env, jobject, jlong id, jstring path) {
    try {
        SessionGuard guard(id);
        UtfChars directory(env, path);
        check(sony2fuji_session_set_lens_database(guard.get(), directory.chars));
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetDisplayLensMetadata(JNIEnv* env, jobject, jlong id,
    jobjectArray names, jfloatArray numbers, jint orientation) {
    try {
        SessionGuard guard(id);
        auto* session = guard.get();
        auto& owner = guard.session();
        if (!names) {
            check(sony2fuji_session_set_display_lens_metadata(session, nullptr));
            owner.displayLens = DisplayLensMetadata();
            return;
        }
        if (env->GetArrayLength(names) != 4 || !numbers || env->GetArrayLength(numbers) != 3)
            throw std::invalid_argument("Invalid display lens metadata");
        DisplayLensMetadata next;
        next.present = true;
        for (int index = 0; index < 4; ++index) {
            auto item = static_cast<jstring>(env->GetObjectArrayElement(names, index));
            { UtfChars name(env, item); next.names[index] = name.chars ? name.chars : ""; }
            env->DeleteLocalRef(item);
        }
        float values[3]; env->GetFloatArrayRegion(numbers, 0, 3, values);
        if (env->ExceptionCheck()) return;
        next.focal = values[0]; next.aperture = values[1]; next.crop = values[2]; next.orientation = orientation;
        const auto metadata = next.value();
        check(sony2fuji_session_set_display_lens_metadata(session, &metadata));
        owner.displayLens = std::move(next);
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeApplyParams(JNIEnv* env, jobject, jlong id, jstring recipeJson) {
    try {
        UtfChars json(env, recipeJson);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing recipe parameters");
        SessionGuard guard(id);
        check(sony2fuji_apply_params(guard.get(), json.chars), guard.get());
        guard.session().appliedParamsJson = json.chars;
    } catch (const NativeStatusError& error) { throwNativeStatus(env, error); }
    catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_engine_ToneCurveSampling_nativeSamples(JNIEnv* env, jclass, jdoubleArray points, jint count) {
    try {
        if (count < 2 || count > 4097) throw std::invalid_argument("Invalid curve sample count");
        const auto config = curveConfig(env, SONY2FUJI_CURVE_CUSTOM, points);
        std::vector<double> values(static_cast<size_t>(count));
        for (jint i = 0; i < count; ++i) values[i] = double(i) / (count - 1);
        check(sony2fuji_sample_tone_curve(&config, values.data(), values.data(), static_cast<uint32_t>(count)));
        auto result = env->NewDoubleArray(count);
        if (result) env->SetDoubleArrayRegion(result, 0, count, values.data());
        return result;
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); return nullptr; }
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeGeometrySize(JNIEnv* env, jobject, jlong id) {
    try {
        SessionGuard guard(id);
        uint32_t width = 0, height = 0;
        check(sony2fuji_session_get_geometry_size(guard.get(), &width, &height));
        if (!width || !height || width > INT32_MAX || height > INT32_MAX)
            throw std::runtime_error("Invalid geometry dimensions");
        auto result = env->NewIntArray(2);
        if (!result) return nullptr;
        const jint dimensions[] = {static_cast<jint>(width), static_cast<jint>(height)};
        env->SetIntArrayRegion(result, 0, 2, dimensions);
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeLensProfiles(JNIEnv* env, jobject, jlong id, jstring input) {
    try {
        SessionGuard guard(id);
        auto* session = guard.get();
        UtfChars path(env, input);
        sony2fuji_lens_report_v2 report{};
        uint32_t count = 0;
        const auto& display = guard.session().displayLens;
        const auto metadata = display.value();
        auto inspect = [&](sony2fuji_lens_profile_v2* profiles, uint32_t capacity) {
            if (input) return sony2fuji_session_inspect_lens_v2(session, path.chars, &report, profiles, capacity, &count);
            if (!display.present) throw std::invalid_argument("Display lens metadata not configured");
            return sony2fuji_session_inspect_lens_metadata_v2(session, &metadata, &report, profiles, capacity, &count);
        };
        check(inspect(nullptr, 0));
        std::vector<sony2fuji_lens_profile_v2> profiles(count);
        check(inspect(profiles.data(), count));
        std::vector<std::string> values;
        values.reserve(static_cast<size_t>(count) * 7);
        for (const auto& profile : profiles) {
            values.insert(values.end(), {profile.base.id, profile.base.maker, profile.base.model,
                profile.base.has_distortion ? "1" : "0", profile.base.has_tca ? "1" : "0", profile.base.is_match ? "1" : "0", profile.has_vignetting ? "1" : "0"});
        }
        return strings(env, values);
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeLensReport(JNIEnv* env, jobject, jlong id) {
    try {
        SessionGuard guard(id);
        sony2fuji_lens_report_v2 report{};
        check(sony2fuji_session_get_lens_report_v2(guard.get(), &report));
        return strings(env, {std::to_string(report.base.state), report.base.lens_model, report.base.profile.model,
            report.base.applied_distortion ? "1" : "0", report.base.applied_tca ? "1" : "0", std::to_string(report.base.crop_scale), report.applied_vignetting ? "1" : "0"});
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_engine_NativeLookBridge_validate(JNIEnv* env, jclass, jstring path) {
    try {
        UtfChars value(env, path);
        sony2fuji_look_format format = SONY2FUJI_LOOK_UNKNOWN;
        uint32_t version = 0;
        const auto status = sony2fuji_validate_look(value.chars, &format, &version);
        const auto color = sony2fuji_inspect_lut_color(value.chars);
        if (status != SONY2FUJI_STATUS_OK) {
            if (status == SONY2FUJI_STATUS_UNSUPPORTED && color <= SONY2FUJI_LUT_INVALID_CONTRACT) {
                const auto reason = "rawlab-lut-color:" + std::to_string(color);
                throwJava(env, "java/lang/UnsupportedOperationException", reason.c_str());
                return nullptr;
            }
            const char* type = status == SONY2FUJI_STATUS_INVALID_ARGUMENT
                ? "java/lang/IllegalArgumentException"
                : status == SONY2FUJI_STATUS_UNSUPPORTED
                    ? "java/lang/UnsupportedOperationException"
                    : status == SONY2FUJI_STATUS_OUT_OF_MEMORY
                        ? "java/lang/OutOfMemoryError"
                        : "java/io/IOException";
            throwJava(env, type, sony2fuji_status_message(status));
            return nullptr;
        }
        auto result = env->NewIntArray(3);
        if (!result) return nullptr;
        const jint values[] = {static_cast<jint>(format), static_cast<jint>(version), static_cast<jint>(color)};
        env->SetIntArrayRegion(result, 0, 3, values);
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to validate look");
    } catch (const std::exception& error) {
        throwJava(env, "java/io/IOException", error.what());
    }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeLookBridge_compatibility(JNIEnv* env, jclass, jstring path, jstring request) {
    DcpBlob blob;
    try {
        UtfChars source(env,path);
        if(request) {
            UtfChars parameters(env,request);
            check(sony2fuji_prepare_lut_compatibility(source.chars,parameters.chars,&blob.value));
        } else check(sony2fuji_inspect_lut_compatibility(source.chars,&blob.value));
        if(blob.value.size_bytes>static_cast<size_t>(std::numeric_limits<jsize>::max())) throw std::bad_alloc();
        auto result=env->NewByteArray(static_cast<jsize>(blob.value.size_bytes));
        if(!result) return nullptr;
        env->SetByteArrayRegion(result,0,static_cast<jsize>(blob.value.size_bytes),static_cast<const jbyte*>(blob.value.data));
        return env->ExceptionCheck()?nullptr:result;
    } catch(const std::bad_alloc&) { throwJava(env,"java/lang/OutOfMemoryError","Not enough memory for LUT compatibility");
    } catch(const std::exception& error) { throwJava(env,"java/io/IOException",error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeDcpBridge_compile(JNIEnv* env, jclass, jbyteArray source,
    jbyteArray sourceNameUtf8, jbyteArray toneCurve, jboolean omitAutomaticBlack) {
    DcpBlob blob;
    try {
        if (!source || !sourceNameUtf8) throw std::invalid_argument("Missing DCP source");
        ByteArrayElements bytes(env, source);
        ByteArrayElements sourceName(env, sourceNameUtf8);
        const auto sourceNameLength = env->GetArrayLength(sourceNameUtf8);
        if (sourceNameLength <= 0) throw std::invalid_argument("Missing DCP source filename");
        const std::string name(reinterpret_cast<const char*>(sourceName.bytes),
            static_cast<size_t>(sourceNameLength));
        sony2fuji_dcp_error reason = SONY2FUJI_DCP_ERROR_NONE;
        ByteArrayElements curve(env, toneCurve);
        const auto curveSize = toneCurve ? static_cast<size_t>(env->GetArrayLength(toneCurve)) : 0;
        const auto status = sony2fuji_compile_dcp_with_options(bytes.bytes,
            static_cast<size_t>(env->GetArrayLength(source)), name.c_str(), curve.bytes, curveSize,
            omitAutomaticBlack ? 1 : 0, &blob.value, &reason);
        if (status != SONY2FUJI_STATUS_OK) {
            if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) {
                throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to compile DCP");
            } else {
                if (reason == SONY2FUJI_DCP_ERROR_NONE) reason = SONY2FUJI_DCP_ERROR_MALFORMED;
                try {
                    const auto& cache = jniCache(env);
                    LocalRef exception(env, env->NewObject(cache.dcpCompilationException.clazz,
                        cache.dcpCompilationException.ctor, static_cast<jint>(reason)));
                    if (exception) env->Throw(static_cast<jthrowable>(exception.get()));
                } catch (...) {
                    env->ExceptionClear();
                    throwJava(env, "java/io/IOException", "DCP compilation failed");
                }
            }
            return nullptr;
        }
        if (!blob.value.data || blob.value.size_bytes == 0 ||
            blob.value.size_bytes > 64u * 1024u * 1024u || blob.value.size_bytes > INT32_MAX) {
            const auto& cache = jniCache(env);
            LocalRef exception(env, env->NewObject(cache.dcpCompilationException.clazz,
                cache.dcpCompilationException.ctor, static_cast<jint>(SONY2FUJI_DCP_ERROR_TOO_LARGE)));
            if (exception) env->Throw(static_cast<jthrowable>(exception.get()));
            return nullptr;
        }
        auto result = env->NewByteArray(static_cast<jsize>(blob.value.size_bytes));
        if (!result) return nullptr;
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(blob.value.size_bytes),
            static_cast<const jbyte*>(blob.value.data));
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to compile DCP");
    } catch (const std::exception& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    }
    return nullptr;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(JNIEnv* env, jobject, jint mode) {
    try {
        if (mode < SONY2FUJI_GPU_OFF || mode > SONY2FUJI_GPU_FORCE) throw std::invalid_argument("Invalid GPU mode");
        sony2fuji_session* pointer = nullptr;
        check(sony2fuji_session_create(&pointer));
        std::unique_ptr<sony2fuji_session, SessionDeleter> owned(pointer);
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(sony2fuji_gpu_config), static_cast<sony2fuji_gpu_mode>(mode)};
        check(sony2fuji_session_set_gpu_config(owned.get(), &config));
        auto session = std::make_shared<Session>(nullptr);
        session->value = std::move(owned);
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const jlong id = nextId++;
        {
            std::lock_guard<std::mutex> signalLock(cancellationMutex);
            cancellationStates.emplace(id, session->generation);
        }
        try {
            sessions.emplace(id, std::move(session));
        } catch (...) {
            std::lock_guard<std::mutex> signalLock(cancellationMutex);
            cancellationStates.erase(id);
            throw;
        }
        return id;
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to create a RAW session");
        return 0;
    } catch (const std::exception& error) {
        throwJava(env, "java/lang/IllegalStateException", error.what());
        return 0;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(JNIEnv*, jobject, jlong id) {
    std::shared_ptr<Session> removed;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        {
            std::lock_guard<std::mutex> signalLock(cancellationMutex);
            cancellationStates.erase(id);
        }
        const auto found = sessions.find(id);
        if (found != sessions.end()) {
            removed = std::move(found->second);
            sessions.erase(found);
        }
    }
    if (removed) {
        std::lock_guard<std::mutex> sessionLock(removed->mutex);
        removed->closed = true;
        removed->value.reset();
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeCancellationGeneration(JNIEnv*, jobject, jlong id) {
    std::lock_guard<std::mutex> lock(cancellationMutex);
    const auto found = cancellationStates.find(id);
    return found == cancellationStates.end() ? -1 : found->second->load(std::memory_order_acquire);
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeCancelPreview(JNIEnv*, jobject, jlong id) {
    std::lock_guard<std::mutex> lock(cancellationMutex);
    const auto found = cancellationStates.find(id);
    if (found != cancellationStates.end()) found->second->fetch_add(1, std::memory_order_acq_rel);
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetGpuMode(JNIEnv* env, jobject, jlong id, jint mode) {
    try {
        SessionGuard guard(id);
        if (mode < 0 || mode > 2) throw std::invalid_argument("Invalid processor or GPU mode");
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), static_cast<sony2fuji_gpu_mode>(mode)};
        check(sony2fuji_session_set_gpu_config(guard.get(), &config));
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeProbe(JNIEnv* env, jclass, jstring path) {
    try {
        UtfChars source(env, path);
        if (!source.chars || !*source.chars) throw std::invalid_argument("Missing HDR source path");
        sony2fuji_hdr_source_info_v1 info{};
        info.version = SONY2FUJI_HDR_VERSION;
        info.struct_size = sizeof(info);
        sony2fuji_hdr_diagnostic_v1 diagnostic{};
        diagnostic.version = SONY2FUJI_HDR_VERSION;
        diagnostic.struct_size = sizeof(diagnostic);
        const auto status = sony2fuji_hdr_probe(source.chars, &info, &diagnostic);
        if (status == SONY2FUJI_STATUS_UNSUPPORTED &&
            diagnostic.reason == SONY2FUJI_HDR_REASON_NOT_HDR) return nullptr;
        if (status != SONY2FUJI_STATUS_OK) {
            throw HDRStatusError(status,diagnostic);
        }
        // Kotlin's decoder consumes a fixed little-endian contract; Android ABIs are little-endian.
        std::array<uint8_t, 64> encoded{};
        size_t offset = 0;
        auto append = [&](const void* value, size_t size) {
            if (offset + size > encoded.size()) throw std::runtime_error("HDR metadata overflow");
            std::memcpy(encoded.data() + offset, value, size); offset += size;
        };
        append(&info.width, sizeof(info.width)); append(&info.height, sizeof(info.height));
        append(&info.orientation, sizeof(info.orientation)); append(&info.container, sizeof(info.container));
        append(&info.protocol, sizeof(info.protocol)); append(&info.color_description, sizeof(info.color_description));
        append(&info.content_headroom, sizeof(info.content_headroom)); append(&info.headroom_kind, sizeof(info.headroom_kind));
        append(info.source_sha256, sizeof(info.source_sha256));
        auto result = env->NewByteArray(static_cast<jsize>(encoded.size()));
        if (!result) return nullptr;
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(encoded.size()), reinterpret_cast<const jbyte*>(encoded.data()));
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for HDR probe");
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env,error);
    }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeProbeCameraRaw(JNIEnv* env, jclass, jstring path, jint processingVersion) {
    try {
        UtfChars source(env, path);
        if (!source.chars || !*source.chars) throw std::invalid_argument("Missing camera RAW source path");
        sony2fuji_hdr_camera_source_info_v1 camera{};
        auto& info = camera.base;
        info.version = SONY2FUJI_HDR_VERSION;
        info.struct_size = sizeof(camera);
        sony2fuji_hdr_diagnostic_v1 diagnostic{};
        diagnostic.version = SONY2FUJI_HDR_VERSION;
        diagnostic.struct_size = sizeof(diagnostic);
        auto status = sony2fuji_hdr_probe_camera_raw_with_processing(source.chars,
            static_cast<sony2fuji_processing_version>(processingVersion), &info, &diagnostic);
        if (status == SONY2FUJI_STATUS_UNSUPPORTED && diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW)
            status = sony2fuji_hdr_probe_proraw(source.chars, &info, &diagnostic);
        if (status == SONY2FUJI_STATUS_UNSUPPORTED &&
            diagnostic.reason == SONY2FUJI_HDR_REASON_UNSUPPORTED_RAW) return nullptr;
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        std::array<uint8_t, 68> encoded{};
        size_t offset = 0;
        auto append = [&](const void* value, size_t size) {
            if (offset + size > encoded.size()) throw std::runtime_error("HDR metadata overflow");
            std::memcpy(encoded.data() + offset, value, size); offset += size;
        };
        append(&info.width, sizeof(info.width)); append(&info.height, sizeof(info.height));
        append(&info.orientation, sizeof(info.orientation)); append(&info.container, sizeof(info.container));
        append(&info.protocol, sizeof(info.protocol)); append(&info.color_description, sizeof(info.color_description));
        append(&info.content_headroom, sizeof(info.content_headroom)); append(&info.headroom_kind, sizeof(info.headroom_kind));
        append(info.source_sha256, sizeof(info.source_sha256));
        append(&camera.capabilities, sizeof(camera.capabilities));
        auto result = env->NewByteArray(static_cast<jsize>(encoded.size()));
        if (!result) return nullptr;
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(encoded.size()), reinterpret_cast<const jbyte*>(encoded.data()));
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for camera RAW HDR probe");
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env, error);
    }
    return nullptr;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(JNIEnv* env, jclass, jstring path, jint longEdge) {
    try {
        UtfChars source(env, path);
        if (!source.chars || !*source.chars || longEdge < 0 || longEdge > 65535)
            throw std::invalid_argument("Invalid HDR preview request");
        sony2fuji_hdr_decode_options_v1 options{};
        options.version = SONY2FUJI_HDR_VERSION;
        options.struct_size = sizeof(options);
        options.intent = longEdge == 0 ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
        options.long_edge = static_cast<uint32_t>(longEdge);
        sony2fuji_hdr_image_pair_v1 result{};
        result.version = SONY2FUJI_HDR_VERSION;
        result.struct_size = sizeof(result);
        sony2fuji_hdr_diagnostic_v1 diagnostic{};
        diagnostic.version = SONY2FUJI_HDR_VERSION;
        diagnostic.struct_size = sizeof(diagnostic);
        const auto status = sony2fuji_hdr_decode(source.chars, &options, &result, &diagnostic);
        if (status != SONY2FUJI_STATUS_OK) {
            sony2fuji_hdr_release_pair(&result);
            throw HDRStatusError(status,diagnostic);
        }
        return retainHdrPair(result);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for HDR decode");
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env,error);
    }
    return 0;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecodeCameraRaw(JNIEnv* env, jclass, jlong sessionId,
    jstring path, jint longEdge, jlong cancellationGeneration, jboolean proRAW, jstring temporaryRoot,
    jboolean customWhiteBalance, jfloat temperature, jfloat tint, jboolean sensorExposure,
    jint fbddLevel, jint lensFlags, jstring lensProfile, jstring profilePath, jstring profileDigest, jint processingVersion) {
    try {
        UtfChars source(env, path), temporary(env, temporaryRoot), profile(env, lensProfile);
        UtfChars resource(env, profilePath), digest(env, profileDigest);
        if (!source.chars || !*source.chars || longEdge < 0 || longEdge > 65535)
            throw std::invalid_argument("Invalid camera RAW HDR preview request");
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        if (!proRAW) {
            const auto paramsJson = processingOnlyParamsJson(processingVersion, "preview");
            check(sony2fuji_apply_params(guard.get(), paramsJson.c_str()));
            guard.session().appliedParamsJson = paramsJson;
        }
        sony2fuji_hdr_decode_options_v1 options{};
        options.version = SONY2FUJI_HDR_VERSION;
        options.struct_size = sizeof(options);
        options.intent = longEdge == 0 ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
        options.long_edge = static_cast<uint32_t>(longEdge);
        sony2fuji_hdr_image_pair_v1 result{};
        result.version = SONY2FUJI_HDR_VERSION;
        result.struct_size = sizeof(result);
        sony2fuji_hdr_diagnostic_v1 diagnostic{};
        diagnostic.version = SONY2FUJI_HDR_VERSION;
        diagnostic.struct_size = sizeof(diagnostic);
        sony2fuji_hdr_camera_development_v1 development{SONY2FUJI_HDR_VERSION, sizeof(development),
            uint32_t(customWhiteBalance != 0), uint32_t(sensorExposure != 0), temperature, tint,
            static_cast<uint32_t>(fbddLevel), static_cast<uint32_t>(lensFlags), profile.chars};
        sony2fuji_hdr_camera_development_v2 profiled{};
        const auto* settings = &development;
        if (resource.chars) {
            profiled.base = development;
            profiled.base.version = 2;
            profiled.base.struct_size = sizeof(profiled);
            profiled.profile_path = resource.chars;
            if (digest.chars) std::strncpy(profiled.profile_sha256, digest.chars, sizeof(profiled.profile_sha256) - 1);
            settings = &profiled.base;
        }
        const auto status = proRAW
            ? sony2fuji_hdr_decode_proraw(guard.get(), source.chars, &options, temporary.chars, &result, &diagnostic)
            : sony2fuji_hdr_decode_camera_raw_with_development(guard.get(), source.chars, &options, settings, &result, &diagnostic);
        if (cancellation.isCancelled()) {
            sony2fuji_hdr_release_pair(&result);
            throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        }
        if (status != SONY2FUJI_STATUS_OK) {
            sony2fuji_hdr_release_pair(&result);
            if (status == SONY2FUJI_STATUS_CANCELLED) throw NativeStatusError(status);
            throw HDRStatusError(status, diagnostic);
        }
        return retainHdrPair(result);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for camera RAW HDR decode");
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env, error);
    }
    return 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportProRAW(JNIEnv* env, jclass, jlong sessionId,
    jstring path, jobject requestObj, jboolean keepHDR, jbyteArray fingerprint,
    jstring temporaryRoot, jstring outputPath, jlong cancellationGeneration) {
    try {
        if (!fingerprint || env->GetArrayLength(fingerprint) != 32) throw std::invalid_argument("Invalid ProRAW export fingerprint");
        MarshalledHdrRequest marshalled;
        marshalHdrRenderRequest(env, requestObj, marshalled);
        auto& base = marshalled.base();
        base.intent = SONY2FUJI_INTENT_FINAL;
        UtfChars source(env, path), temporary(env, temporaryRoot), output(env, outputPath);
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        sony2fuji_hdr_export_config_v1 config{};
        config.version = SONY2FUJI_HDR_VERSION; config.struct_size = sizeof(config);
        config.jpeg_quality = 95; config.base_color = SONY2FUJI_HDR_COLOR_DISPLAY_P3;
        config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP; config.metadata_source_path = source.chars;
        env->GetByteArrayRegion(fingerprint, 0, 32, reinterpret_cast<jbyte*>(config.source_sha256));
        if (env->ExceptionCheck()) return;
        sony2fuji_hdr_stream_result_v1 result{SONY2FUJI_HDR_VERSION, sizeof(result)};
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_export_proraw(guard.get(), source.chars, &base, &config,
            keepHDR ? 1 : 0, temporary.chars, output.chars, &result, &diagnostic);
        if (status == SONY2FUJI_STATUS_CANCELLED) throw NativeStatusError(status);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
    } catch (const NativeStatusError& error) { throwNativeStatus(env, error); }
      catch (const std::exception& error) { throwHDRFailure(env, error); }
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(JNIEnv* env, jclass, jint width, jint height, jobject geometryObj) {
    try {
        if (width <= 0 || height <= 0 || !geometryObj)
            throw std::invalid_argument("Invalid HDR geometry request");
        const auto& cache = jniCache(env);
        sony2fuji_hdr_request_v1 request{};
        request.version = 1;
        request.struct_size = sizeof(request);
        request.hdr_processing_version = 1;
        request.temperature = 6500;
        marshalGeometryFields(env, cache, geometryObj, request);
        uint32_t outputWidth = 0, outputHeight = 0;
        sony2fuji_hdr_diagnostic_v1 diagnostic{}; diagnostic.version = 1; diagnostic.struct_size = sizeof(diagnostic);
        if (sony2fuji_hdr_geometry_size(width, height, &request, &outputWidth, &outputHeight, &diagnostic) != SONY2FUJI_STATUS_OK)
            throw std::invalid_argument("Invalid HDR geometry");
        const jint output[] = {jint(outputWidth), jint(outputHeight)};
        auto result = env->NewIntArray(2);
        if (result) env->SetIntArrayRegion(result, 0, 2, output);
        return result;
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); return nullptr; }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(JNIEnv* env, jclass, jlong sessionId, jlong sourceId,
    jobject requestObj, jlong cancellationGeneration) {
    try {
        MarshalledHdrRequest marshalled;
        marshalHdrRenderRequest(env, requestObj, marshalled);
        auto& base = marshalled.base();
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        const auto sourceOwner = acquireHdrPair(sourceId);
        const auto& source = sourceOwner->value;
        base.intent = source.source_intent;
        sony2fuji_hdr_image_pair_v1 result{};
        result.version = SONY2FUJI_HDR_VERSION;
        result.struct_size = sizeof(result);
        sony2fuji_hdr_diagnostic_v1 diagnostic{};
        diagnostic.version = SONY2FUJI_HDR_VERSION;
        diagnostic.struct_size = sizeof(diagnostic);
        const auto status = sony2fuji_hdr_render(guard.get(), &source, &base, &result, &diagnostic);
        if (cancellation.isCancelled()) {
            sony2fuji_hdr_release_pair(&result);
            throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        }
        if (status != SONY2FUJI_STATUS_OK) {
            sony2fuji_hdr_release_pair(&result);
            throw HDRStatusError(status, diagnostic);
        }
        return retainHdrPair(result);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for HDR render");
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env, error);
    }
    return 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeSampleHsl(JNIEnv* env, jclass, jlong sessionId, jlong sourceId,
    jobject requestObj, jlong sourceRevision, jlong requestRevision, jfloatArray output, jlong cancellationGeneration) {
    try {
        MarshalledHdrRequest marshalled;
        marshalHdrRenderRequest(env, requestObj, marshalled);
        auto& base = marshalled.base();
        base.intent = SONY2FUJI_INTENT_PREVIEW;
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        const auto sourceOwner = acquireHdrPair(sourceId);
        const auto& source = sourceOwner->value;
        sony2fuji_hsl_probe* probe = nullptr;
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_create_hsl_probe(guard.get(), &source, &base,
            static_cast<uint64_t>(sourceRevision), static_cast<uint64_t>(requestRevision), &probe, &diagnostic);
        const std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> owner(probe, sony2fuji_hsl_probe_destroy);
        if (status == SONY2FUJI_STATUS_CANCELLED || cancellation.isCancelled())
            throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        sampleHslProbe(env, probe, sourceRevision, requestRevision, output);
    } catch (const NativeStatusError& error) { throwNativeStatus(env, error); }
      catch (const std::exception& error) { throwHDRFailure(env, error); }
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

extern "C" JNIEXPORT jfloat JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeEstimateAutoExposure(JNIEnv* env, jclass, jlong sessionId,
    jlong sourceId, jfloat temperature, jfloat tint, jlong cancellationGeneration) {
    try {
        SessionGuard guard(sessionId);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        const auto sourceOwner = acquireHdrPair(sourceId);
        const auto& source = sourceOwner->value;
        sony2fuji_hdr_diagnostic_v1 diagnostic{};
        diagnostic.version = SONY2FUJI_HDR_VERSION;
        diagnostic.struct_size = sizeof(diagnostic);
        float exposure = 0;
        const auto status = sony2fuji_hdr_estimate_auto_exposure(&source, temperature, tint, &exposure, &diagnostic);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status, diagnostic);
        return exposure;
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env, error);
    }
    return 0;
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeMetadata(JNIEnv* env, jclass, jlong pairId) {
    try {
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        const float metadata[] = {static_cast<float>(pair.hdr.width), static_cast<float>(pair.hdr.height),
            static_cast<float>(pair.native_width), static_cast<float>(pair.native_height),
            static_cast<float>(pair.output_native_width), static_cast<float>(pair.output_native_height),
            pair.hdr.content_headroom, pair.source_headroom};
        auto result = env->NewFloatArray(8);
        if (!result) return nullptr;
        env->SetFloatArrayRegion(result, 0, 8, metadata);
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::exception& error) {
        throwHDRFailure(env,error);
    }
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
    } catch (const std::exception& error) {
        throwHDRFailure(env,error);
    }
    return nullptr;
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativePlane(JNIEnv* env, jclass, jlong pairId, jboolean hdr) {
    try {
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        const auto& buffer = hdr ? pair.hdr : pair.sdr;
        if (!buffer.data || buffer.width == 0 || buffer.height == 0 || buffer.pixel_format != SONY2FUJI_HDR_RGB32F_LINEAR ||
            buffer.stride_bytes < static_cast<uint64_t>(buffer.width) * 3 * sizeof(float))
            throw std::runtime_error("Invalid HDR float plane");
        const uint64_t count = static_cast<uint64_t>(buffer.width) * buffer.height * 3;
        if (count > static_cast<uint64_t>(std::numeric_limits<jsize>::max())) throw std::runtime_error("HDR plane is too large");
        auto result = env->NewFloatArray(static_cast<jsize>(count));
        if (!result) return nullptr;
        std::vector<float> compact(static_cast<size_t>(count));
        for (uint32_t y = 0; y < buffer.height; ++y)
            std::memcpy(compact.data() + static_cast<size_t>(y) * buffer.width * 3,
                static_cast<const uint8_t*>(buffer.data) + static_cast<size_t>(y) * buffer.stride_bytes,
                static_cast<size_t>(buffer.width) * 3 * sizeof(float));
        env->SetFloatArrayRegion(result, 0, static_cast<jsize>(count), compact.data());
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for HDR plane");
    } catch (const std::exception& error) {
        throwHDRFailure(env,error);
    }
    return nullptr;
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeSdrBitmap(JNIEnv* env, jclass, jlong pairId, jobject bitmap) {
    try {
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& buffer = pairOwner->value.sdr;
        if (!buffer.data || buffer.width == 0 || buffer.height == 0 || buffer.pixel_format != SONY2FUJI_HDR_RGB32F_LINEAR ||
            buffer.stride_bytes < static_cast<uint64_t>(buffer.width) * 3 * sizeof(float))
            throw std::runtime_error("Invalid SDR float plane");
        BitmapPixels output(env, bitmap, buffer.width, buffer.height, SONY2FUJI_PIXEL_RGBA8, false);
        const auto encode = [](float value) -> uint8_t {
            if (!std::isfinite(value)) throw std::runtime_error("Nonfinite SDR rendition");
            const float v = std::clamp(value, 0.0f, 1.0f);
            const float encoded = v <= .0031308f ? 12.92f * v :
                1.055f * static_cast<float>(std::pow(static_cast<double>(v), 1.0 / 2.4)) - .055f;
            return static_cast<uint8_t>(std::clamp(std::lround(encoded * 255.0f), 0L, 255L));
        };
        // 直接写位图，避免完整尺寸 SDR 导出在 Java 堆同时持有 RGB32F 和 ARGB 数组。
        for (uint32_t y = 0; y < buffer.height; ++y) {
            const auto* source = reinterpret_cast<const float*>(static_cast<const uint8_t*>(buffer.data) + y * buffer.stride_bytes);
            auto* destination = static_cast<uint8_t*>(output.locked) + static_cast<size_t>(y) * output.stride;
            for (uint32_t x = 0; x < buffer.width; ++x) {
                for (uint32_t channel = 0; channel < 3; ++channel) destination[x * 4 + channel] = encode(source[x * 3 + channel]);
                destination[x * 4 + 3] = 255;
            }
        }
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for SDR bitmap"); }
      catch (const std::exception& error) { throwHDRFailure(env, error); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(JNIEnv*, jclass, jlong pairId) {
    releaseHdrPair(pairId);
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportJpeg(JNIEnv* env, jclass, jlong pairId,
    jstring sourcePath, jstring outputPath, jint baseColor) {
    try {
        UtfChars source(env, sourcePath), output(env, outputPath);
        if (!output.chars || !*output.chars || baseColor < SONY2FUJI_HDR_COLOR_SRGB || baseColor > SONY2FUJI_HDR_COLOR_BT2020)
            throw std::invalid_argument("Invalid HDR JPEG export request");
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        sony2fuji_hdr_export_config_v1 config{};
        config.version = SONY2FUJI_HDR_VERSION; config.struct_size = sizeof(config);
        config.jpeg_quality = 95; config.base_color = static_cast<uint32_t>(baseColor);
        config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
        config.metadata_source_path = source.chars;
        if (source.chars) std::memcpy(config.source_sha256, pair.source_sha256, 32);
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_export_jpeg(&pair, &config, output.chars, &diagnostic);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status,diagnostic);
    } catch (const std::exception& error) { throwHDRFailure(env,error); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportSdr(JNIEnv* env, jclass, jlong pairId,
    jstring sourcePath, jstring outputPath, jint format) {
    try {
        UtfChars source(env, sourcePath), output(env, outputPath);
        if (!output.chars || !*output.chars ||
            (format != SONY2FUJI_OUTPUT_JPEG && format != SONY2FUJI_OUTPUT_PNG && format != SONY2FUJI_OUTPUT_DNG))
            throw std::invalid_argument("Invalid SDR export request");
        const auto pairOwner = acquireHdrPair(pairId);
        const auto& pair = pairOwner->value;
        sony2fuji_hdr_sdr_export_config_v1 config{};
        config.version = SONY2FUJI_HDR_VERSION; config.struct_size = sizeof(config);
        config.output_format = static_cast<uint32_t>(format); config.quality = 95;
        config.metadata_source_path = source.chars;
        if (source.chars) std::memcpy(config.source_sha256, pair.source_sha256, 32);
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_export_sdr(&pair, &config, output.chars, &diagnostic);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status,diagnostic);
    } catch (const std::exception& error) { throwHDRFailure(env,error); }
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeCompatibilityPreview(JNIEnv* env,jobject,jlong id,
    jstring input,jobject bitmap,jint width,jint height,jint pixelFormat,jstring lut,jstring configuration) {
    try {
        SessionGuard guard(id);
        auto* session=guard.get();
        UtfChars source(env,input),look(env,lut),contract(env,configuration);
        BitmapPixels pixels(env,bitmap,width,height,pixelFormat);
        const auto paramsJson = processingOnlyParamsJson(SONY2FUJI_PROCESSING_C5_V2, "scene");
        check(sony2fuji_apply_params(session, paramsJson.c_str()));
        guard.session().appliedParamsJson = paramsJson;
        auto request=rawlab::makeRequest(source.chars,look.chars,nullptr,look.chars?1:0,0,false,6500,0,512,rawlab::ExportFormat::JPEG);
        if(bitmap) {
            request.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;request.input_pixels=pixels.bytes;
            request.input_width=width;request.input_height=height;
            request.input_pixel_format=static_cast<sony2fuji_pixel_format>(pixelFormat);
            request.input_color_space=SONY2FUJI_COLOR_SRGB;request.input_is_linear=0;
        }
        Buffer result;
        check(contract.chars?sony2fuji_preview_lut_compatibility(session,&request,contract.chars,&result.value):
            sony2fuji_process(session,&request,&result.value));
        const auto& b=result.value;
        const auto count=rawlab::previewByteCount(b);
        if(b.width>1024 || b.height>1024 || count>std::numeric_limits<jsize>::max()) throw std::runtime_error("Invalid preview output");
        auto bytes=env->NewByteArray(static_cast<jsize>(count));if(!bytes)return nullptr;
        for(uint32_t row=0;row<b.height;++row) {
            env->SetByteArrayRegion(bytes,static_cast<jsize>(row*b.width*4),static_cast<jsize>(b.width*4),
                reinterpret_cast<const jbyte*>(static_cast<const uint8_t*>(b.data)+size_t(row)*b.stride_bytes));
            if(env->ExceptionCheck())return nullptr;
        }
        if(env->ExceptionCheck())return nullptr;
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeFrame.clazz, cache.nativeFrame.ctor,
            static_cast<jint>(b.width), static_cast<jint>(b.height), bytes, 6500.f, 0.f, 0, nullptr);
    } catch(const std::bad_alloc&) {throwJava(env,"java/lang/OutOfMemoryError","Not enough memory for LUT preview");
    } catch(const std::exception& error) {throwJava(env,"java/io/IOException",error.what());}
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeLookBridge_compare(JNIEnv* env,jclass,jbyteArray candidate,jint width,jint height,
    jbyteArray reference,jint referenceWidth,jint referenceHeight,jstring conditions) {
    try {
        if(!candidate || !reference || !conditions || width<1 || height<1 || width>1024 || height>1024 ||
            referenceWidth<1 || referenceHeight<1 || referenceWidth>1024 || referenceHeight>1024)
            throw std::invalid_argument("Invalid preview dimensions");
        ByteArrayElements a(env,candidate),b(env,reference);UtfChars text(env,conditions);
        sony2fuji_buffer left{a.bytes,static_cast<size_t>(env->GetArrayLength(candidate)),static_cast<uint32_t>(width),
            static_cast<uint32_t>(height),static_cast<uint32_t>(width*4),SONY2FUJI_PIXEL_RGBA8};
        sony2fuji_buffer right{b.bytes,static_cast<size_t>(env->GetArrayLength(reference)),static_cast<uint32_t>(referenceWidth),
            static_cast<uint32_t>(referenceHeight),static_cast<uint32_t>(referenceWidth*4),SONY2FUJI_PIXEL_RGBA8};
        DcpBlob report;check(sony2fuji_compare_lut_previews(&left,&right,text.chars,&report.value));
        auto bytes=env->NewByteArray(static_cast<jsize>(report.value.size_bytes));if(!bytes)return nullptr;
        env->SetByteArrayRegion(bytes,0,static_cast<jsize>(report.value.size_bytes),static_cast<const jbyte*>(report.value.data));
        return bytes;
    } catch(const std::bad_alloc&) {throwJava(env,"java/lang/OutOfMemoryError","Not enough memory for comparison");
    } catch(const std::exception& error) {throwJava(env,"java/lang/IllegalArgumentException",error.what());}
    return nullptr;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeX3fAvailable(JNIEnv*, jobject) {
    return sony2fuji_x3f_available() != 0;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeX3fDefaultMode(JNIEnv* env, jclass, jstring input) {
    try {
        UtfChars path(env, input);
        sony2fuji_x3f_mode mode = SONY2FUJI_X3F_NORMAL;
        check(sony2fuji_x3f_default_mode(path.chars, &mode));
        return static_cast<jint>(mode);
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to inspect X3F");
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwJava(env, "java/io/IOException", error.what());
    }
    return SONY2FUJI_X3F_NORMAL;
}

extern "C" JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void*) {
    JNIEnv* env = nullptr;
    if (vm && vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK && env) {
        releaseJniCache(env);
    }
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(JNIEnv* env, jobject, jlong id, jobject requestObj) {
    try {
        if (!requestObj) throw std::invalid_argument("Missing native process request");
        const auto& cache = jniCache(env);

        LocalRef inputObj(env, env->GetObjectField(requestObj, cache.processRequest.input));
        LocalRef outputObj(env, env->GetObjectField(requestObj, cache.processRequest.output));
        LocalRef wbObj(env, env->GetObjectField(requestObj, cache.processRequest.whiteBalance));
        LocalRef toneObj(env, env->GetObjectField(requestObj, cache.processRequest.tone));
        LocalRef denoiseObj(env, env->GetObjectField(requestObj, cache.processRequest.denoise));
        LocalRef effectsObj(env, env->GetObjectField(requestObj, cache.processRequest.effects));
        LocalRef lutRef(env, env->GetObjectField(requestObj, cache.processRequest.lutPath));
        LocalRef backendRef(env, env->GetObjectField(requestObj, cache.processRequest.backendOut));
        LocalRef hslProbeObj(env, env->GetObjectField(requestObj, cache.processRequest.hslProbe));
        LocalRef migrationRef(env, env->GetObjectField(requestObj, cache.processRequest.migrationOut));
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read native process request");
        if (!inputObj || !outputObj || !wbObj || !toneObj || !denoiseObj || !effectsObj)
            throw std::invalid_argument("Missing native process request section");

        const jfloat lutStrength = env->GetFloatField(requestObj, cache.processRequest.lutStrength);
        const jint exposureMode = env->GetIntField(requestObj, cache.processRequest.exposureMode);
        const jint processingVersion = env->GetIntField(requestObj, cache.processRequest.processingVersion);
        const jint x3fMode = env->GetIntField(requestObj, cache.processRequest.x3fMode);
        const jlong cancellationGeneration = env->GetLongField(requestObj, cache.processRequest.cancellationGeneration);

        LocalRef inputPathRef(env, env->GetObjectField(inputObj.get(), cache.processInput.path));
        LocalRef inputPixelsRef(env, env->GetObjectField(inputObj.get(), cache.processInput.pixels));
        const jint inputWidth = env->GetIntField(inputObj.get(), cache.processInput.width);
        const jint inputHeight = env->GetIntField(inputObj.get(), cache.processInput.height);
        const jint inputPixelFormat = env->GetIntField(inputObj.get(), cache.processInput.pixelFormat);

        LocalRef outputPathRef(env, env->GetObjectField(outputObj.get(), cache.processOutput.path));
        const jint format = env->GetIntField(outputObj.get(), cache.processOutput.format);
        const jint edge = env->GetIntField(outputObj.get(), cache.processOutput.edge);
        const jint longEdge = env->GetIntField(outputObj.get(), cache.processOutput.longEdge);
        const jboolean interactive = env->GetBooleanField(outputObj.get(), cache.processOutput.interactive);
        const jboolean viewportPreview = env->GetBooleanField(outputObj.get(), cache.processOutput.viewportPreview);

        const jboolean customWb = env->GetBooleanField(wbObj.get(), cache.processWhiteBalance.custom);
        jfloat temperature = env->GetFloatField(wbObj.get(), cache.processWhiteBalance.temperature);
        jfloat tint = env->GetFloatField(wbObj.get(), cache.processWhiteBalance.tint);
        const jboolean recipeActive = env->GetBooleanField(wbObj.get(), cache.processWhiteBalance.recipeActive);
        const jfloat recipeStrength = env->GetFloatField(wbObj.get(), cache.processWhiteBalance.recipeStrength);

        const jfloat exposureEv = env->GetFloatField(toneObj.get(), cache.processTone.exposureEv);
        const jfloat contrast = env->GetFloatField(toneObj.get(), cache.processTone.contrast);
        const jfloat highlights = env->GetFloatField(toneObj.get(), cache.processTone.highlights);
        const jfloat shadows = env->GetFloatField(toneObj.get(), cache.processTone.shadows);
        const jfloat toneCurve = env->GetFloatField(toneObj.get(), cache.processTone.toneCurve);
        const jfloat saturation = env->GetFloatField(toneObj.get(), cache.processTone.saturation);
        const jfloat sharpening = env->GetFloatField(toneObj.get(), cache.processTone.sharpening);

        jlong sourceRevision = 0;
        jlong requestRevision = 0;
        LocalRef hslProbeRef(env, nullptr);
        if (hslProbeObj) {
            sourceRevision = env->GetLongField(hslProbeObj.get(), cache.hslProbeTarget.sourceRevision);
            requestRevision = env->GetLongField(hslProbeObj.get(), cache.hslProbeTarget.requestRevision);
            hslProbeRef.reset(env->GetObjectField(hslProbeObj.get(), cache.hslProbeTarget.output));
        }
        if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read native process fields");

        SessionGuard guard(id);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        auto* session = guard.get();
        auto backendOut = backendRef.asIntArray();
        if (backendOut && env->GetArrayLength(backendOut) != 1) throw std::invalid_argument("Invalid backend output");

        UtfChars in(env, inputPathRef.asString()), film(env, lutRef.asString()), out(env, outputPathRef.asString());
        BitmapPixels inputBytes(env, inputPixelsRef.get(), inputWidth, inputHeight, inputPixelFormat);
        const bool displayInput = inputPixelsRef.get() != nullptr;

        bool effectiveCustom = customWb != JNI_FALSE;
        if (!displayInput)
            prepareRecipeWb(guard.session(), in.chars, recipeActive != JNI_FALSE, recipeStrength,
                effectiveCustom, temperature, tint, processingVersion, x3fMode, exposureMode);

        auto migrationValues = migrationRef.asFloatArray();
        auto hslProbe = hslProbeRef.asFloatArray();
        const auto outputFormat = rawlab::parseExportFormat(format);
        auto request = displayInput
            ? rawlab::makeDisplayRequest(in.chars, inputBytes.bytes, static_cast<uint32_t>(inputWidth),
                static_cast<uint32_t>(inputHeight), static_cast<sony2fuji_pixel_format>(inputPixelFormat),
                film.chars, out.chars, lutStrength, exposureEv, highlights, shadows, contrast,
                toneCurve, saturation, sharpening, edge, outputFormat,
                longEdge < 0 ? 0u : static_cast<uint32_t>(longEdge), migrationValues != nullptr)
            : rawlab::makeRequest(in.chars, film.chars, out.chars, lutStrength,
                exposureEv, effectiveCustom, temperature, tint, highlights, shadows, contrast,
                toneCurve, saturation, sharpening, edge, outputFormat,
                longEdge < 0 ? 0u : static_cast<uint32_t>(longEdge), migrationValues != nullptr);

        check(sony2fuji_session_set_interactive_preview(session, interactive != JNI_FALSE ? 1 : 0));
        check(sony2fuji_session_set_viewport_preview(session, viewportPreview != JNI_FALSE ? 1 : 0));

        if (migrationValues) {
            if (env->GetArrayLength(migrationValues) != 20 || out.chars || hslProbe)
                throw std::invalid_argument("Invalid processing migration output");
            static_assert(sizeof(sony2fuji_processing_migration_result) == 80, "migration result ABI");
            sony2fuji_processing_migration_result result{};
            request.preview_long_edge = 0;
            check(sony2fuji_session_migrate_processing(session, &request, &result), session);
            check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
            const jfloat values[] = {float(result.version), float(result.struct_size), float(result.source_version),
                float(result.target_version), float(result.disposition), float(result.evaluation_count),
                result.exposure_ev, result.contrast, result.highlights, result.shadows, result.saturation,
                result.black_point, result.white_point, result.vibrance, result.clarity, result.dehaze,
                result.rgb_rmse, result.p99_error, result.worst_tile_rmse, result.detail_rmse};
            env->SetFloatArrayRegion(migrationValues, 0, 20, values);
            return nullptr;
        }
        if (hslProbe) {
            if (out.chars) throw std::invalid_argument("Invalid HSL probe output");
            sony2fuji_hsl_probe* snapshot = nullptr;
            check(sony2fuji_session_create_hsl_probe(session, &request, static_cast<uint64_t>(sourceRevision),
                static_cast<uint64_t>(requestRevision), &snapshot), session);
            std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> owned(snapshot, sony2fuji_hsl_probe_destroy);
            sampleHslProbe(env, snapshot, sourceRevision, requestRevision, hslProbe);
            return nullptr;
        }
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        Buffer buffer;
        const auto status = sony2fuji_process(session, &request, &buffer.value);
        // Q12: 核心状态就是提交点判据——CANCELLED 只可能来自提交点之前的检查点（staged 临时文件已由核心
        // 自行删除）；状态 OK 表示 staged write 已原子替换发布，提交点之后迟到的取消不删已渲染文件，
        // 导出按「已完成」收尾。仅缓冲区（预览）路径没有已发布文件，迟到取消仍按取消处理。
        if (out.chars && status == SONY2FUJI_STATUS_CANCELLED)
            std::remove(out.chars);
        check(status, session);
        if (!out.chars)
            check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        if (backendOut) {
            const auto backend = static_cast<jint>(sony2fuji_session_get_last_backend(session));
            env->SetIntArrayRegion(backendOut, 0, 1, &backend);
            if (env->ExceptionCheck()) return nullptr;
        }
        if (outputPathRef) return nullptr;
        const auto& b = buffer.value;
        const size_t row = static_cast<size_t>(b.width) * 4;
        const size_t bytes = rawlab::previewByteCount(b);
        if (bytes > static_cast<size_t>(std::numeric_limits<jsize>::max()))
            throw std::runtime_error("Invalid preview buffer");
        LocalRef pixels(env, env->NewByteArray(static_cast<jsize>(bytes)));
        if (!pixels) return nullptr;
        for (uint32_t y = 0; y < b.height && !env->ExceptionCheck(); ++y) {
            check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
            env->SetByteArrayRegion(reinterpret_cast<jbyteArray>(pixels.get()), static_cast<jsize>(y * row), static_cast<jsize>(row),
                reinterpret_cast<const jbyte*>(b.data) + y * b.stride_bytes);
        }
        if (env->ExceptionCheck()) return nullptr;
        LocalRef histogram(env, nullptr);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        if (!interactive) {
            uint32_t counts[768]{};
            uint32_t shadowsCount = 0, highlightsCount = 0;
            // 统计当前 CPU 显示 buffer，独立于照片渲染 backend；失败仍交付像素。
            if (sony2fuji_analyze_image(&b, SONY2FUJI_GPU_OFF, counts, &shadowsCount, &highlightsCount, nullptr) == SONY2FUJI_STATUS_OK) {
                jint signedCounts[768];
                static_assert(sizeof(signedCounts) == sizeof(counts));
                std::memcpy(signedCounts, counts, sizeof(counts));
                histogram.reset(env->NewIntArray(768));
                if (!histogram) return nullptr;
                env->SetIntArrayRegion(histogram.asIntArray(), 0, 768, signedCounts);
                if (env->ExceptionCheck()) return nullptr;
            }
        }
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        float kelvin = NAN, wbTint = NAN;
        if (!displayInput && isNormalX3f(in.chars, x3fMode)) {
            kelvin = 6500; wbTint = 0;
        } else if (!displayInput) {
            sony2fuji_session_get_raw_white_balance(session, &kelvin, &wbTint);
            kelvin = std::round(kelvin); wbTint = std::round(wbTint);
        }
        return env->NewObject(cache.nativeFrame.clazz, cache.nativeFrame.ctor, static_cast<jint>(b.width),
            static_cast<jint>(b.height), pixels.get(), kelvin, wbTint,
            static_cast<jint>(sony2fuji_session_get_last_backend(session)), histogram.get());
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to develop this RAW");
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwJava(env, "java/io/IOException", error.what());
    } catch (...) {
        throwJava(env, "java/io/IOException", "RAW processing failed");
    }
    return nullptr;
}

extern "C" JNIEXPORT jfloat JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeAutoExposure(JNIEnv* env, jobject, jlong id,
    jstring input, jobject inputPixels, jint inputWidth, jint inputHeight, jint inputPixelFormat,
    jboolean customWb, jfloat temperature, jfloat tint, jint exposureMode, jboolean recipeActive, jfloat strength, jint processingVersion, jint x3fMode) {
    try {
        SessionGuard guard(id);
        auto* session = guard.get();
        UtfChars in(env, input);
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const bool displayInput = inputPixels != nullptr;

        bool effectiveCustom = customWb;
        if (!displayInput)
            prepareRecipeWb(guard.session(), in.chars, recipeActive, strength, effectiveCustom, temperature, tint,
                            processingVersion, x3fMode, exposureMode);
        auto request = displayInput
            ? rawlab::makeDisplayRequest(in.chars, inputBytes.bytes, static_cast<uint32_t>(inputWidth),
                static_cast<uint32_t>(inputHeight), static_cast<sony2fuji_pixel_format>(inputPixelFormat),
                nullptr, nullptr, 0, 0,
                0, 0, 1, 0, 1, 0, 1, rawlab::ExportFormat::JPEG)
            : rawlab::makeRequest(in.chars, nullptr, nullptr, 0, 0, effectiveCustom,
                temperature, tint, 0, 0, 1, 0, 1, 0, 1, rawlab::ExportFormat::JPEG);
        float ev = 0;
        const auto status = sony2fuji_session_estimate_auto_exposure(session, &request, &ev);
        if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) throw std::bad_alloc();
        check(status, session);
        return ev;
    } catch (const NativeStatusError& error) { throwNativeStatus(env, error); }
    catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to meter this RAW"); }
    catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    catch (...) { throwJava(env, "java/io/IOException", "Automatic exposure failed"); }
    return 0;
}
