#include <jni.h>
#include <android/bitmap.h>
#include "render_request.h"
#include "recipe_probe_stages.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
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
struct Session {
    std::unique_ptr<sony2fuji_session, SessionDeleter> value;
    rawlab::RecipeProbeStages stages;
    std::shared_ptr<std::atomic<jlong>> generation = std::make_shared<std::atomic<jlong>>(0);
    explicit Session(sony2fuji_session* pointer) : value(pointer) {}
    sony2fuji_session* get() const { return value.get(); }
};
// Opaque IDs keep stale Java handles from becoming native pointers.
std::mutex sessionsMutex;
std::unordered_map<jlong, Session> sessions;
jlong nextId = 1;
// 取消信号不能等待覆盖整次处理的 sessionsMutex。
std::mutex cancellationMutex;
std::unordered_map<jlong, std::shared_ptr<std::atomic<jlong>>> cancellationStates;
std::mutex hdrPairsMutex;
std::unordered_map<jlong, sony2fuji_hdr_image_pair_v1> hdrPairs;
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
    if (!env->ExceptionCheck()) env->ThrowNew(env->FindClass(type), message);
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
    auto type=env->FindClass("com/rawlab/android/engine/HDRProcessingException");
    if(!type)return;
    auto constructor=env->GetMethodID(type,"<init>","(III)V");if(!constructor)return;
    auto object=env->NewObject(type,constructor,jint(detail->status),jint(detail->diagnostic.reason),jint(detail->diagnostic.field));
    if(object){env->Throw(static_cast<jthrowable>(object));env->DeleteLocalRef(object);}
    env->DeleteLocalRef(type);
}

struct NativeStatusError : std::runtime_error {
    sony2fuji_status status;
    NativeStatusError(sony2fuji_status value)
        : std::runtime_error(sony2fuji_status_message(value)), status(value) {}
};

void throwNativeStatus(JNIEnv* env, const NativeStatusError& error) {
    if (env->ExceptionCheck()) return;
    auto type = env->FindClass("com/rawlab/android/engine/NativeProcessingException");
    if (!type) {
        env->ExceptionClear();
        throwJava(env, "java/io/IOException", error.what());
        return;
    }
    auto constructor = env->GetMethodID(type, "<init>", "(ILjava/lang/String;)V");
    if (!constructor) {
        env->ExceptionClear();
        throwJava(env, "java/io/IOException", error.what());
        return;
    }
    auto message = env->NewStringUTF(error.what());
    if (!message) return;
    auto exception = env->NewObject(type, constructor, static_cast<jint>(error.status), message);
    if (exception) env->Throw(static_cast<jthrowable>(exception));
}

sony2fuji_hdr_image_pair_v1& hdrPairFor(jlong id) {
    const auto found = hdrPairs.find(id);
    if (found == hdrPairs.end()) throw std::invalid_argument("HDR pair is closed");
    return found->second;
}

jlong retainHdrPair(sony2fuji_hdr_image_pair_v1 value) {
    const jlong id = nextHdrPairId++;
    try { hdrPairs.emplace(id, value); }
    catch (...) { sony2fuji_hdr_release_pair(&value); throw; }
    return id;
}

void releaseHdrPair(jlong id) {
    const auto found = hdrPairs.find(id);
    if (found != hdrPairs.end()) {
        sony2fuji_hdr_release_pair(&found->second);
        hdrPairs.erase(found);
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
    if (length % 2 || length > 2 * SONY2FUJI_TONE_CURVE_MAX_POINTS || (mode != 0 && mode != 1))
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
void prepareRecipeWb(Session& owner, const char* input, bool active, float strength,
    bool& custom, float& temperature, float& tint, bool normalX3f) {
    if (!active || (!custom && tint * strength == 0)) return;
    if (normalX3f) {
        if (!custom) temperature = 6500;
        tint = std::clamp(tint * strength, -150.0f, 150.0f);
        custom = true;
        return;
    }
    auto* session = owner.get();
    rawlab::RecipeProbeStageScope stages(session, owner.stages);
    // 临时显影只解析目标 RAW 的拍摄白平衡，随后正式请求重设完整配置。
    sony2fuji_hsl_config hsl{SONY2FUJI_HSL_CONFIG_VERSION, sizeof(sony2fuji_hsl_config)};
    sony2fuji_wavelet_denoise_config denoise{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION, sizeof(sony2fuji_wavelet_denoise_config)};
    sony2fuji_photo_effects_config effects{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION, sizeof(sony2fuji_photo_effects_config)};
    check(sony2fuji_session_set_hsl(session, &hsl));
    check(sony2fuji_session_set_wavelet_denoise(session, &denoise));
    check(sony2fuji_session_set_photo_effects(session, &effects));
    check(sony2fuji_session_set_chroma_denoise(session, 0));
    check(sony2fuji_session_set_interactive_preview(session, 0));
    auto neutral = rawlab::makeRequest(input, nullptr, nullptr, 0, 0, false, 6500, 0, 32, rawlab::ExportFormat::JPEG);
    Buffer buffer;
    check(sony2fuji_process(session, &neutral, &buffer.value), session);
    float cameraTemperature = 0, cameraTint = 0;
    check(sony2fuji_session_get_raw_white_balance(session, &cameraTemperature, &cameraTint));
    if (!std::isfinite(cameraTemperature) || !std::isfinite(cameraTint))
        throw std::runtime_error("Cannot resolve target RAW white balance for master recipe");
    if (!custom) temperature = std::round(cameraTemperature);
    tint = std::clamp(std::round(cameraTint) + tint * strength, -150.0f, 150.0f);
    custom = true;
}
}

namespace {
sony2fuji_session* sessionFor(jlong id) {
    const auto found = sessions.find(id);
    if (found == sessions.end()) throw std::invalid_argument("Processor is closed");
    return found->second.get();
}
jobjectArray strings(JNIEnv* env, const std::vector<std::string>& values) {
    auto type = env->FindClass("java/lang/String");
    if (!type) return nullptr;
    auto constructor = env->GetMethodID(type, "<init>", "([BLjava/lang/String;)V");
    auto charset = env->NewStringUTF("UTF-8");
    if (!constructor || !charset) return nullptr;
    auto result = env->NewObjectArray(static_cast<jsize>(values.size()), type, nullptr);
    if (!result) return nullptr;
    for (size_t i = 0; i < values.size() && !env->ExceptionCheck(); ++i) {
        auto bytes = env->NewByteArray(static_cast<jsize>(values[i].size()));
        if (!bytes) return nullptr;
        env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(values[i].size()), reinterpret_cast<const jbyte*>(values[i].data()));
        auto value = env->NewObject(type, constructor, bytes, charset);
        if (!value) return nullptr;
        env->SetObjectArrayElement(result, static_cast<jsize>(i), value);
        env->DeleteLocalRef(value);
        env->DeleteLocalRef(bytes);
    }
    return env->ExceptionCheck() ? nullptr : result;
}
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetLensDatabase(JNIEnv* env, jobject, jlong id, jstring path) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        UtfChars directory(env, path);
        check(sony2fuji_session_set_lens_database(sessionFor(id), directory.chars));
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetLensCorrection(JNIEnv* env, jobject, jlong id,
    jboolean distortion, jboolean tca, jboolean crop, jbyteArray profile) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        if (!profile) throw std::invalid_argument("Missing lens profile ID");
        std::string value(static_cast<size_t>(env->GetArrayLength(profile)), '\0');
        env->GetByteArrayRegion(profile, 0, static_cast<jsize>(value.size()), reinterpret_cast<jbyte*>(value.data()));
        if (env->ExceptionCheck()) return;
        sony2fuji_lens_correction_config config{SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION,
            sizeof(config), distortion ? 1 : 0, tca ? 1 : 0, crop ? 1 : 0, value.c_str()};
        check(sony2fuji_session_set_lens_correction(sessionFor(id), &config));
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetToneCurve(JNIEnv* env, jobject, jlong id,
    jint mode, jdoubleArray points) {
    try {
        const auto config = curveConfig(env, mode, points);
        std::lock_guard<std::mutex> lock(sessionsMutex);
        check(sony2fuji_session_set_tone_curve(sessionFor(id), &config));
        sessions.at(id).stages.curve = config;
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
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

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetColorGrading(JNIEnv* env, jobject, jlong id,
    jfloat shadowsHue, jfloat shadowsSaturation, jfloat midtonesHue, jfloat midtonesSaturation,
    jfloat highlightsHue, jfloat highlightsSaturation) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        sony2fuji_color_grading_config config{SONY2FUJI_COLOR_GRADING_CONFIG_VERSION, sizeof(config),
            shadowsHue, shadowsSaturation, midtonesHue, midtonesSaturation, highlightsHue, highlightsSaturation};
        check(sony2fuji_session_set_color_grading(sessionFor(id), &config));
        sessions.at(id).stages.grading = config;
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetToneControls(JNIEnv* env, jobject, jlong id,
    jfloat blackPoint, jfloat whitePoint, jfloat vibrance) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        sony2fuji_tone_controls_config config{SONY2FUJI_TONE_CONTROLS_CONFIG_VERSION, sizeof(config),
            blackPoint, whitePoint, vibrance};
        check(sony2fuji_session_set_tone_controls(sessionFor(id), &config));
        sessions.at(id).stages.tone = config;
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetAtmosphere(JNIEnv* env, jobject, jlong id,
    jfloat clarity, jfloat dehaze) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        sony2fuji_atmosphere_config config{SONY2FUJI_ATMOSPHERE_CONFIG_VERSION, sizeof(config),
            clarity, dehaze};
        check(sony2fuji_session_set_atmosphere(sessionFor(id), &config));
        sessions.at(id).stages.atmosphere = config;
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSetGeometry(JNIEnv* env, jobject, jlong id,
    jfloat x, jfloat y, jfloat width, jfloat height, jint turns,
    jboolean horizontal, jboolean vertical, jfloat straighten,
    jfloat perspectiveHorizontal, jfloat perspectiveVertical) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        sony2fuji_geometry_config config{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(config),
            x, y, width, height, turns, horizontal ? 1 : 0, vertical ? 1 : 0, straighten};
        auto* session = sessionFor(id);
        check(sony2fuji_session_set_geometry(session, &config));
        sony2fuji_perspective_config perspective{SONY2FUJI_PERSPECTIVE_CONFIG_VERSION, sizeof(perspective),
            perspectiveHorizontal, perspectiveVertical};
        check(sony2fuji_session_set_perspective(session, &perspective));
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeGeometrySize(JNIEnv* env, jobject, jlong id) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        uint32_t width = 0, height = 0;
        check(sony2fuji_session_get_geometry_size(sessionFor(id), &width, &height));
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
        std::lock_guard<std::mutex> lock(sessionsMutex);
        auto* session = sessionFor(id);
        UtfChars path(env, input);
        sony2fuji_lens_report report{};
        uint32_t count = 0;
        check(sony2fuji_session_inspect_lens(session, path.chars, &report, nullptr, 0, &count));
        std::vector<sony2fuji_lens_profile> profiles(count);
        check(sony2fuji_session_inspect_lens(session, path.chars, &report, profiles.data(), count, &count));
        std::vector<std::string> values;
        values.reserve(static_cast<size_t>(count) * 6);
        for (const auto& profile : profiles) {
            values.insert(values.end(), {profile.id, profile.maker, profile.model,
                profile.has_distortion ? "1" : "0", profile.has_tca ? "1" : "0", profile.is_match ? "1" : "0"});
        }
        return strings(env, values);
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeLensReport(JNIEnv* env, jobject, jlong id) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        sony2fuji_lens_report report{};
        check(sony2fuji_session_get_lens_report(sessionFor(id), &report));
        return strings(env, {std::to_string(report.state), report.lens_model, report.profile.model,
            report.applied_distortion ? "1" : "0", report.applied_tca ? "1" : "0", std::to_string(report.crop_scale)});
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
Java_com_rawlab_android_engine_NativeDcpBridge_compile(JNIEnv* env, jclass, jbyteArray source, jbyteArray sourceNameUtf8) {
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
        const auto status = sony2fuji_compile_dcp(bytes.bytes,
            static_cast<size_t>(env->GetArrayLength(source)), name.c_str(), &blob.value, &reason);
        if (status != SONY2FUJI_STATUS_OK) {
            if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) {
                throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to compile DCP");
            } else {
                if (reason == SONY2FUJI_DCP_ERROR_NONE) reason = SONY2FUJI_DCP_ERROR_MALFORMED;
                auto type = env->FindClass("com/rawlab/android/looks/DcpCompilationException");
                if (!type) {
                    env->ExceptionClear();
                    throwJava(env, "java/io/IOException", "DCP compilation failed");
                } else {
                    auto constructor = env->GetMethodID(type, "<init>", "(I)V");
                    if (!constructor) {
                        env->ExceptionClear();
                        throwJava(env, "java/io/IOException", "DCP compilation failed");
                    } else {
                        auto exception = env->NewObject(type, constructor, static_cast<jint>(reason));
                        if (exception) env->Throw(static_cast<jthrowable>(exception));
                    }
                }
            }
            return nullptr;
        }
        if (!blob.value.data || blob.value.size_bytes == 0 ||
            blob.value.size_bytes > 64u * 1024u * 1024u || blob.value.size_bytes > INT32_MAX) {
            auto type = env->FindClass("com/rawlab/android/looks/DcpCompilationException");
            if (type) {
                auto constructor = env->GetMethodID(type, "<init>", "(I)V");
                if (constructor) {
                    auto exception = env->NewObject(type, constructor,
                        static_cast<jint>(SONY2FUJI_DCP_ERROR_TOO_LARGE));
                    if (exception) env->Throw(static_cast<jthrowable>(exception));
                }
            }
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
        std::lock_guard<std::mutex> lock(sessionsMutex);
        if (mode < SONY2FUJI_GPU_OFF || mode > SONY2FUJI_GPU_FORCE) throw std::invalid_argument("Invalid GPU mode");
        sony2fuji_session* pointer = nullptr;
        check(sony2fuji_session_create(&pointer));
        Session session(pointer);
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(sony2fuji_gpu_config), static_cast<sony2fuji_gpu_mode>(mode)};
        check(sony2fuji_session_set_gpu_config(pointer, &config));
        const jlong id = nextId++;
        sessions.emplace(id, std::move(session));
        try {
            std::lock_guard<std::mutex> signalLock(cancellationMutex);
            cancellationStates.emplace(id, sessions.at(id).generation);
        } catch (...) {
            sessions.erase(id);
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
    std::lock_guard<std::mutex> lock(sessionsMutex);
    {
        std::lock_guard<std::mutex> signalLock(cancellationMutex);
        cancellationStates.erase(id);
    }
    sessions.erase(id);
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
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const auto found = sessions.find(id);
        if (found == sessions.end() || mode < 0 || mode > 2) throw std::invalid_argument("Invalid processor or GPU mode");
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), static_cast<sony2fuji_gpu_mode>(mode)};
        check(sony2fuji_session_set_gpu_config(found->second.get(), &config));
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
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
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

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(JNIEnv* env,jclass,jint width,jint height,jfloatArray values) {
    try {
        if (width<=0 || height<=0 || !values || env->GetArrayLength(values)!=17)
            throw std::invalid_argument("Invalid HDR geometry request");
        std::array<jfloat,17> input{}; env->GetFloatArrayRegion(values,0,17,input.data());
        if (env->ExceptionCheck()) return nullptr;
        sony2fuji_hdr_request_v1 request{}; request.version=1; request.struct_size=sizeof(request);
        request.hdr_processing_version=1; request.temperature=6500;
        request.crop_x=input[7]; request.crop_y=input[8]; request.crop_width=input[9]; request.crop_height=input[10];
        request.quarter_turns=static_cast<int32_t>(input[11]); request.flip_horizontal=input[12]!=0; request.flip_vertical=input[13]!=0;
        request.straighten_degrees=input[14]; request.perspective_horizontal=input[15]; request.perspective_vertical=input[16];
        uint32_t outputWidth=0,outputHeight=0;
        sony2fuji_hdr_diagnostic_v1 diagnostic{}; diagnostic.version=1; diagnostic.struct_size=sizeof(diagnostic);
        if (sony2fuji_hdr_geometry_size(width,height,&request,&outputWidth,&outputHeight,&diagnostic)!=SONY2FUJI_STATUS_OK)
            throw std::invalid_argument("Invalid HDR geometry");
        const jint output[]={jint(outputWidth),jint(outputHeight)}; auto result=env->NewIntArray(2);
        if (result) env->SetIntArrayRegion(result,0,2,output); return result;
    } catch (const std::exception& error) { throwJava(env,"java/lang/IllegalArgumentException",error.what()); return nullptr; }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(JNIEnv* env, jclass, jlong sessionId, jlong sourceId,
    jfloatArray values, jint longEdge, jlong cancellationGeneration) {
    try {
        if (!values || env->GetArrayLength(values) != 17 || longEdge < 0 || longEdge > 65535)
            throw std::invalid_argument("Invalid HDR render request");
        std::array<jfloat, 17> input{};
        env->GetFloatArrayRegion(values, 0, 17, input.data());
        if (env->ExceptionCheck()) return 0;
        std::lock_guard<std::mutex> sessionLock(sessionsMutex);
        const auto session = sessions.find(sessionId);
        if (session == sessions.end()) throw std::invalid_argument("Processor is closed");
        CancellationScope cancellation(session->second, cancellationGeneration);
        if (cancellation.isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        std::lock_guard<std::mutex> pairLock(hdrPairsMutex);
        auto& source = hdrPairFor(sourceId);
        sony2fuji_hdr_request_v1 request{};
        request.version = SONY2FUJI_HDR_VERSION;
        request.struct_size = sizeof(request);
        request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_VERSION;
        request.intent = source.source_intent;
        request.exposure_ev = input[0]; request.temperature = input[1]; request.tint = input[2];
        request.contrast = input[3]; request.highlights = input[4]; request.shadows = input[5]; request.saturation = input[6];
        request.crop_x = input[7]; request.crop_y = input[8]; request.crop_width = input[9]; request.crop_height = input[10];
        request.quarter_turns = static_cast<int32_t>(input[11]);
        request.flip_horizontal = input[12] != 0 ? 1u : 0u;
        request.flip_vertical = input[13] != 0 ? 1u : 0u;
        request.straighten_degrees = input[14]; request.perspective_horizontal = input[15]; request.perspective_vertical = input[16];
        request.long_edge = static_cast<uint32_t>(longEdge);
        sony2fuji_hdr_image_pair_v1 result{};
        result.version = SONY2FUJI_HDR_VERSION;
        result.struct_size = sizeof(result);
        sony2fuji_hdr_diagnostic_v1 diagnostic{};
        diagnostic.version = SONY2FUJI_HDR_VERSION;
        diagnostic.struct_size = sizeof(diagnostic);
        const auto status = sony2fuji_hdr_render(session->second.get(), &source, &request, &result, &diagnostic);
        if (cancellation.isCancelled()) {
            sony2fuji_hdr_release_pair(&result);
            throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
        }
        if (status != SONY2FUJI_STATUS_OK) {
            sony2fuji_hdr_release_pair(&result);
            throw HDRStatusError(status,diagnostic);
        }
        return retainHdrPair(result);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for HDR render");
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwHDRFailure(env,error);
    }
    return 0;
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeMetadata(JNIEnv* env, jclass, jlong pairId) {
    try {
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        const auto& pair = hdrPairFor(pairId);
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
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        const auto& pair = hdrPairFor(pairId);
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
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        const auto& pair = hdrPairFor(pairId);
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
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        const auto& buffer = hdrPairFor(pairId).sdr;
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
    std::lock_guard<std::mutex> lock(hdrPairsMutex);
    releaseHdrPair(pairId);
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportJpeg(JNIEnv* env, jclass, jlong pairId,
    jstring sourcePath, jstring outputPath, jint baseColor) {
    try {
        UtfChars source(env, sourcePath), output(env, outputPath);
        if (!source.chars || !output.chars || !*output.chars || baseColor < SONY2FUJI_HDR_COLOR_SRGB || baseColor > SONY2FUJI_HDR_COLOR_BT2020)
            throw std::invalid_argument("Invalid HDR JPEG export request");
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        auto& pair = hdrPairFor(pairId);
        sony2fuji_hdr_export_config_v1 config{};
        config.version = SONY2FUJI_HDR_VERSION; config.struct_size = sizeof(config);
        config.jpeg_quality = 95; config.base_color = static_cast<uint32_t>(baseColor);
        config.metadata_policy = SONY2FUJI_HDR_METADATA_ISO_XMP;
        config.metadata_source_path = source.chars; std::memcpy(config.source_sha256, pair.source_sha256, 32);
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
        if (!source.chars || !output.chars || !*output.chars ||
            (format != SONY2FUJI_OUTPUT_JPEG && format != SONY2FUJI_OUTPUT_PNG && format != SONY2FUJI_OUTPUT_DNG))
            throw std::invalid_argument("Invalid SDR export request");
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        auto& pair = hdrPairFor(pairId);
        sony2fuji_hdr_sdr_export_config_v1 config{};
        config.version = SONY2FUJI_HDR_VERSION; config.struct_size = sizeof(config);
        config.output_format = static_cast<uint32_t>(format); config.quality = 95;
        config.metadata_source_path = source.chars; std::memcpy(config.source_sha256, pair.source_sha256, 32);
        sony2fuji_hdr_diagnostic_v1 diagnostic{SONY2FUJI_HDR_VERSION, sizeof(diagnostic)};
        const auto status = sony2fuji_hdr_export_sdr(&pair, &config, output.chars, &diagnostic);
        if (status != SONY2FUJI_STATUS_OK) throw HDRStatusError(status,diagnostic);
    } catch (const std::exception& error) { throwHDRFailure(env,error); }
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeCompatibilityPreview(JNIEnv* env,jobject,jlong id,
    jstring input,jobject bitmap,jint width,jint height,jstring lut,jstring configuration) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const auto found=sessions.find(id);
        if(found==sessions.end()) throw std::invalid_argument("Processor is closed");
        auto* session=found->second.get();
        UtfChars source(env,input),look(env,lut),contract(env,configuration);
        BitmapPixels pixels(env,bitmap,width,height,bitmap?SONY2FUJI_PIXEL_RGBA8:0);
        check(sony2fuji_session_set_processing_version(session,SONY2FUJI_PROCESSING_C5_V2));
        check(sony2fuji_session_set_raw_exposure_mode(session,SONY2FUJI_EXPOSURE_SCENE));
        auto request=rawlab::makeRequest(source.chars,look.chars,nullptr,look.chars?1:0,0,false,6500,0,512,rawlab::ExportFormat::JPEG);
        if(bitmap) {
            request.input_type=SONY2FUJI_INPUT_DISPLAY_BUFFER;request.input_pixels=pixels.bytes;
            request.input_width=width;request.input_height=height;request.input_pixel_format=SONY2FUJI_PIXEL_RGBA8;
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
        auto type=env->FindClass("com/rawlab/android/engine/NativeFrame");if(!type)return nullptr;
        auto constructor=env->GetMethodID(type,"<init>","(II[BFFI[I)V");if(!constructor)return nullptr;
        return env->NewObject(type,constructor,static_cast<jint>(b.width),static_cast<jint>(b.height),bytes,6500.f,0.f,0,nullptr);
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

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(JNIEnv* env, jobject, jlong id,
    jstring input, jobject inputPixels, jint inputWidth, jint inputHeight, jint inputPixelFormat,
    jstring lut, jstring output, jfloat strength, jfloat exposure,
    jboolean customWb, jfloat temperature, jfloat tint, jfloat highlights, jfloat shadows,
    jfloat contrast, jfloat toneCurve, jfloat saturation, jfloat sharpening,
    jint edge, jboolean interactive, jint format, jint longEdge,
    jboolean denoiseEnabled, jfloat luma, jfloat chroma, jfloat coarse, jint displayChromaDenoise,
    jfloat vignetteAmount, jfloat vignetteMidpoint, jfloat vignetteRoundness, jfloat vignetteFeather,
    jfloat vignetteHighlights, jfloat grainAmount, jfloat grainSize, jfloat grainRoughness,
    jint exposureMode, jfloatArray hslValues, jboolean recipeActive, jint processingVersion, jint x3fMode, jintArray backendOut,
    jlong sourceRevision, jlong requestRevision, jfloatArray hslProbe, jlong cancellationGeneration) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const auto found = sessions.find(id);
        if (found == sessions.end()) throw std::invalid_argument("Processor is closed");
        CancellationScope cancellation(found->second, output ? -1 : cancellationGeneration);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        auto* session = found->second.get();
        check(sony2fuji_session_set_processing_version(session, static_cast<sony2fuji_processing_version>(processingVersion)));
        check(sony2fuji_session_set_x3f_mode(session, static_cast<sony2fuji_x3f_mode>(x3fMode)));
        if (backendOut && env->GetArrayLength(backendOut) != 1) throw std::invalid_argument("Invalid backend output");
        check(sony2fuji_session_set_raw_exposure_mode(session, static_cast<sony2fuji_raw_exposure_mode>(exposureMode)));
        UtfChars in(env, input), film(env, lut), out(env, output);
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const bool displayInput = inputPixels != nullptr;

        bool effectiveCustom = customWb;
        if (!displayInput)
            prepareRecipeWb(found->second, in.chars, recipeActive, strength, effectiveCustom, temperature, tint, isNormalX3f(in.chars, x3fMode));
        if (!hslValues || env->GetArrayLength(hslValues) != 24) throw std::invalid_argument("Invalid HSL values");
        float hslData[24];
        env->GetFloatArrayRegion(hslValues, 0, 24, hslData);
        if (env->ExceptionCheck()) return nullptr;
        sony2fuji_hsl_config hsl{};
        hsl.version = SONY2FUJI_HSL_CONFIG_VERSION;
        hsl.struct_size = sizeof(hsl);
        std::copy(hslData, hslData+8, hsl.hue);
        std::copy(hslData+8, hslData+16, hsl.saturation);
        std::copy(hslData+16, hslData+24, hsl.lightness);
        check(sony2fuji_session_set_hsl(session, &hsl));
        const auto outputFormat = rawlab::parseExportFormat(format);
        auto request = displayInput
            ? rawlab::makeDisplayRequest(in.chars, inputBytes.bytes, static_cast<uint32_t>(inputWidth),
                static_cast<uint32_t>(inputHeight), static_cast<sony2fuji_pixel_format>(inputPixelFormat),
                film.chars, out.chars, strength, exposure, effectiveCustom, temperature, tint,
                highlights, shadows, contrast, toneCurve, saturation, sharpening, edge, outputFormat,
                longEdge < 0 ? 0u : static_cast<uint32_t>(longEdge))
            : rawlab::makeRequest(in.chars, film.chars, out.chars, strength,
                exposure, effectiveCustom, temperature, tint, highlights, shadows, contrast,
                toneCurve, saturation, sharpening, edge, outputFormat,
                longEdge < 0 ? 0u : static_cast<uint32_t>(longEdge));
        if (recipeActive) {
            request.exposure_ev *= strength;
            request.highlights *= strength;
            request.shadows *= strength;
            request.contrast = 1 + contrast * strength;
            request.saturation = 1 + saturation * strength;
        }
        check(sony2fuji_session_set_interactive_preview(session, interactive && !out.chars));
        check(sony2fuji_session_set_viewport_preview(session, !out.chars && edge > 0));
        sony2fuji_wavelet_denoise_config denoise{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,
            sizeof(sony2fuji_wavelet_denoise_config), denoiseEnabled ? 1 : 0, luma, chroma, coarse};
        check(sony2fuji_session_set_wavelet_denoise(session, &denoise));
        sony2fuji_photo_effects_config effects{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION,
            sizeof(sony2fuji_photo_effects_config), vignetteAmount, vignetteMidpoint, vignetteRoundness,
            vignetteFeather, vignetteHighlights, grainAmount, grainSize, grainRoughness};
        check(sony2fuji_session_set_photo_effects(session, &effects));
        check(sony2fuji_session_set_chroma_denoise(session, displayChromaDenoise));
        if (hslProbe) {
            if (out.chars || env->GetArrayLength(hslProbe) != 13) throw std::invalid_argument("Invalid HSL probe output");
            float point[2]; env->GetFloatArrayRegion(hslProbe, 0, 2, point);
            if (env->ExceptionCheck()) return nullptr;
            sony2fuji_hsl_probe* snapshot = nullptr;
            check(sony2fuji_session_create_hsl_probe(session, &request, static_cast<uint64_t>(sourceRevision),
                static_cast<uint64_t>(requestRevision), &snapshot), session);
            std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> owned(snapshot, sony2fuji_hsl_probe_destroy);
            sony2fuji_hsl_probe_query query{SONY2FUJI_HSL_PROBE_VERSION, sizeof(query),
                static_cast<uint64_t>(sourceRevision), static_cast<uint64_t>(requestRevision), point[0], point[1]};
            sony2fuji_hsl_probe_result sample{};
            check(sony2fuji_hsl_probe_sample(snapshot, &query, &sample));
            float values[13]{static_cast<float>(sample.availability), static_cast<float>(sample.quality),
                sample.rgb[0], sample.rgb[1], sample.rgb[2]};
            std::copy(std::begin(sample.weights), std::end(sample.weights), values+5);
            env->SetFloatArrayRegion(hslProbe, 0, 13, values);
            return nullptr;
        }
        Buffer buffer;
        check(sony2fuji_process(session, &request, &buffer.value), session);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        if (backendOut) {
            const auto backend = static_cast<jint>(sony2fuji_session_get_last_backend(session));
            env->SetIntArrayRegion(backendOut, 0, 1, &backend);
            if (env->ExceptionCheck()) return nullptr;
        }
        if (output) return nullptr;
        const auto& b = buffer.value;
        const size_t row = static_cast<size_t>(b.width) * 4;
        const size_t bytes = rawlab::previewByteCount(b);
        if (bytes > static_cast<size_t>(std::numeric_limits<jsize>::max()))
            throw std::runtime_error("Invalid preview buffer");
        auto pixels = env->NewByteArray(static_cast<jsize>(bytes));
        if (!pixels) return nullptr;
        for (uint32_t y = 0; y < b.height && !env->ExceptionCheck(); ++y) {
            check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
            env->SetByteArrayRegion(pixels, static_cast<jsize>(y * row), static_cast<jsize>(row),
                reinterpret_cast<const jbyte*>(b.data) + y * b.stride_bytes);
        }
        if (env->ExceptionCheck()) return nullptr;
        jintArray histogram = nullptr;
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        if (!interactive) {
            uint32_t counts[768]{};
            uint32_t shadows = 0, highlights = 0;
            // 统计当前 CPU 显示 buffer，独立于照片渲染 backend；失败仍交付像素。
            if (sony2fuji_analyze_image(&b, SONY2FUJI_GPU_OFF, counts, &shadows, &highlights, nullptr) == SONY2FUJI_STATUS_OK) {
                jint signedCounts[768];
                static_assert(sizeof(signedCounts) == sizeof(counts));
                std::memcpy(signedCounts, counts, sizeof(counts));
                histogram = env->NewIntArray(768);
                if (!histogram) return nullptr;
                env->SetIntArrayRegion(histogram, 0, 768, signedCounts);
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
        auto type = env->FindClass("com/rawlab/android/engine/NativeFrame");
        if (!type) return nullptr;
        auto constructor = env->GetMethodID(type, "<init>", "(II[BFFI[I)V");
        if (!constructor) return nullptr;
        return env->NewObject(type, constructor, static_cast<jint>(b.width),
            static_cast<jint>(b.height), pixels, kelvin, wbTint, static_cast<jint>(sony2fuji_session_get_last_backend(session)), histogram);
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
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const auto found = sessions.find(id);
        if (found == sessions.end()) throw std::invalid_argument("Processor is closed");
        UtfChars in(env, input);
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const bool displayInput = inputPixels != nullptr;

        check(sony2fuji_session_set_processing_version(found->second.get(), static_cast<sony2fuji_processing_version>(processingVersion)));
        check(sony2fuji_session_set_x3f_mode(found->second.get(), static_cast<sony2fuji_x3f_mode>(x3fMode)));
        check(sony2fuji_session_set_raw_exposure_mode(found->second.get(), static_cast<sony2fuji_raw_exposure_mode>(exposureMode)));
        bool effectiveCustom = customWb;
        if (!displayInput)
            prepareRecipeWb(found->second, in.chars, recipeActive, strength, effectiveCustom, temperature, tint, isNormalX3f(in.chars, x3fMode));
        auto request = displayInput
            ? rawlab::makeDisplayRequest(in.chars, inputBytes.bytes, static_cast<uint32_t>(inputWidth),
                static_cast<uint32_t>(inputHeight), static_cast<sony2fuji_pixel_format>(inputPixelFormat),
                nullptr, nullptr, 0, 0, effectiveCustom, temperature, tint,
                0, 0, 0, 0, 0, 0, 1, rawlab::ExportFormat::JPEG)
            : rawlab::makeRequest(in.chars, nullptr, nullptr, 0, 0, effectiveCustom,
                temperature, tint, 0, 0, 0, 0, 0, 0, 1, rawlab::ExportFormat::JPEG);
        check(sony2fuji_session_set_raw_exposure_mode(found->second.get(), static_cast<sony2fuji_raw_exposure_mode>(exposureMode)));
        float ev = 0;
        const auto status = sony2fuji_session_estimate_auto_exposure(found->second.get(), &request, &ev);
        if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) throw std::bad_alloc();
        check(status, found->second.get());
        return ev;
    } catch (const NativeStatusError& error) { throwNativeStatus(env, error); }
    catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to meter this RAW"); }
    catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    catch (...) { throwJava(env, "java/io/IOException", "Automatic exposure failed"); }
    return 0;
}
