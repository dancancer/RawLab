#pragma once

#include <jni.h>
#include <android/bitmap.h>
#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace rawlab::jni {

struct SessionDeleter {
    void operator()(sony2fuji_session* session) const { sony2fuji_session_destroy(session); }
};

struct DisplayLensMetadata {
    bool present = false;
    std::array<std::string, 4> names;
    float focal = 0.0f;
    float aperture = 0.0f;
    float crop = 0.0f;
    int orientation = 1;

    sony2fuji_lens_metadata value() const {
        return {
            SONY2FUJI_LENS_METADATA_VERSION,
            sizeof(sony2fuji_lens_metadata),
            names[0].c_str(),
            names[1].c_str(),
            names[2].c_str(),
            names[3].c_str(),
            focal,
            aperture,
            crop,
            0,
            orientation,
        };
    }
};

struct Session {
    std::mutex mutex;
    bool closed = false;
    DisplayLensMetadata displayLens;
    std::unique_ptr<sony2fuji_session, SessionDeleter> value;
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

// Defined strictly in jni_sdr.cpp (single TU).
extern std::mutex sessionsMutex;
extern std::unordered_map<jlong, std::shared_ptr<Session>> sessions;
extern std::mutex cancellationMutex;
extern std::unordered_map<jlong, std::shared_ptr<std::atomic<jlong>>> cancellationStates;

// Defined strictly in jni_hdr.cpp (single TU).
extern std::mutex hdrPairsMutex;
extern std::unordered_map<jlong, std::shared_ptr<const HdrPairOwner>> hdrPairs;

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

    bool isCancelled() const {
        return expected >= 0 && generation->load(std::memory_order_acquire) != expected;
    }
};

std::shared_ptr<Session> acquireSession(jlong id);

struct SessionGuard {
    std::shared_ptr<Session> owner;
    std::unique_lock<std::mutex> lock;

    explicit SessionGuard(jlong id) : owner(acquireSession(id)), lock(owner->mutex) {
        if (owner->closed || !owner->get()) throw std::invalid_argument("Processor is closed");
    }

    Session& session() { return *owner; }
    sony2fuji_session* get() const { return owner->get(); }
};

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

    jobject release() {
        jobject released = ref;
        ref = nullptr;
        return released;
    }

    jobject get() const { return ref; }
    jstring asString() const { return static_cast<jstring>(ref); }
    jfloatArray asFloatArray() const { return static_cast<jfloatArray>(ref); }
    jintArray asIntArray() const { return static_cast<jintArray>(ref); }
    jdoubleArray asDoubleArray() const { return static_cast<jdoubleArray>(ref); }
    jbyteArray asByteArray() const { return static_cast<jbyteArray>(ref); }
    explicit operator bool() const { return ref != nullptr; }
};

struct UtfChars {
    JNIEnv* env;
    jstring value;
    const char* chars;

    UtfChars(JNIEnv* e, jstring s)
        : env(e), value(s), chars(s ? e->GetStringUTFChars(s, nullptr) : nullptr) {
        if (s && !chars) throw std::bad_alloc();
    }

    ~UtfChars() { if (chars) env->ReleaseStringUTFChars(value, chars); }
};

struct ByteArrayElements {
    JNIEnv* env;
    jbyteArray value;
    jbyte* bytes;

    ByteArrayElements(JNIEnv* e, jbyteArray array)
        : env(e), value(array), bytes(array ? e->GetByteArrayElements(array, nullptr) : nullptr) {
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

struct BitmapPixels {
    JNIEnv* env;
    jobject value;
    void* locked = nullptr;
    const void* bytes = nullptr;
    uint32_t stride = 0;
    std::vector<uint8_t> packed;

    BitmapPixels(JNIEnv* e, jobject bitmap, jint width, jint height, jint format, bool compactInput = true);
    ~BitmapPixels() { if (locked) AndroidBitmap_unlockPixels(env, value); }
};

struct OutputBitmapLock {
    JNIEnv* env;
    jobject bitmap;
    void* locked = nullptr;

    OutputBitmapLock(JNIEnv* e, jobject bmp, AndroidBitmapInfo& info, uint32_t expectedWidth, uint32_t expectedHeight);
    ~OutputBitmapLock() { if (locked) AndroidBitmap_unlockPixels(env, bitmap); }
};

struct NativeStatusError : std::runtime_error {
    sony2fuji_status status;
    sony2fuji_unsupported_reason unsupportedReason;

    explicit NativeStatusError(
        sony2fuji_status value,
        sony2fuji_unsupported_reason reason = SONY2FUJI_UNSUPPORTED_NONE)
        : std::runtime_error(sony2fuji_status_message(value)),
          status(value),
          unsupportedReason(reason) {}
};

struct JniCache {
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; jmethodID allocateBitmap = nullptr; } nativeFrame;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeProcessingException;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } hdrProcessingException;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } dcpCompilationException;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } lutColorContractException;
    struct { jclass clazz = nullptr; jmethodID bytesCtor = nullptr; } javaString;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } hdrSourceInfo;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeRoiBounds;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeRoiFrame;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeWbProbeResult;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeHslProbeResult;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeMigrationResult;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } lensCandidate;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeLensReport;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeLensInspection;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeLookValidation;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeCameraWhiteBalance;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeHdrPairInfo;
    struct { jclass clazz = nullptr; jmethodID ctor = nullptr; } nativeHdrRoiPair;
    struct { jclass clazz = nullptr; jmethodID onProgress = nullptr; } hdrProgressListener;
};

const JniCache& jniCache(JNIEnv* env);
void releaseJniCache(JNIEnv* env);
void throwJava(JNIEnv* env, const char* type, const char* message);
void throwNativeStatus(JNIEnv* env, const NativeStatusError& error);
void handleSdrException(JNIEnv* env, const char* oomMessage) noexcept;
void check(sony2fuji_status status, sony2fuji_session* session = nullptr);
jstring newUtf8String(JNIEnv* env, const char* utf8);
size_t previewByteCount(const sony2fuji_buffer& buffer);
jobject writeRgba8Bitmap(JNIEnv* env, const sony2fuji_buffer& b, jobject reusableBitmap, const CancellationScope* cancellation);
jobject sampleHslProbeResult(JNIEnv* env, const sony2fuji_hsl_probe* probe, jlong sourceRevision, jlong requestRevision, jfloat x, jfloat y);
sony2fuji_render_options_v1 makeRenderOptions(
    const char* inputPath,
    const BitmapPixels& pixels,
    jint width,
    jint height,
    jint pixelFormat,
    const char* outputPath,
    jint format,
    jint edge,
    jint longEdge,
    bool interactive,
    bool viewportPreview,
    const sony2fuji_viewport_roi* roi,
    bool allowZeroPreviewEdge = false);

} // namespace rawlab::jni
