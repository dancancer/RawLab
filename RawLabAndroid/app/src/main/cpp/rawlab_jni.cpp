#include <jni.h>
#include "render_request.h"
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>

static_assert(sizeof(sony2fuji_photo_effects_config) == 40,
    "Photo effects config ABI must remain a versioned 40-byte struct");

namespace {
struct SessionDeleter {
    void operator()(sony2fuji_session* session) const { sony2fuji_session_destroy(session); }
};
using Session = std::unique_ptr<sony2fuji_session, SessionDeleter>;
// Opaque IDs keep stale Java handles from becoming native pointers.
std::mutex sessionsMutex;
std::unordered_map<jlong, Session> sessions;
jlong nextId = 1;

void throwJava(JNIEnv* env, const char* type, const char* message) {
    if (!env->ExceptionCheck()) env->ThrowNew(env->FindClass(type), message);
}
void check(sony2fuji_status status) {
    rawlab::checkStatus(status);
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
struct Buffer {
    sony2fuji_buffer value{};
    ~Buffer() { sony2fuji_release_buffer(&value); }
};
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_NativeLookBridge_validate(JNIEnv* env, jclass, jstring path) {
    try {
        UtfChars value(env, path);
        sony2fuji_look_format format = SONY2FUJI_LOOK_UNKNOWN;
        uint32_t version = 0;
        const auto status = sony2fuji_validate_look(value.chars, &format, &version);
        if (status != SONY2FUJI_STATUS_OK) {
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
        auto result = env->NewIntArray(2);
        if (!result) return nullptr;
        const jint values[] = {static_cast<jint>(format), static_cast<jint>(version)};
        env->SetIntArrayRegion(result, 0, 2, values);
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to validate look");
    } catch (const std::exception& error) {
        throwJava(env, "java/io/IOException", error.what());
    }
    return nullptr;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_NativeProcessor_nativeCreate(JNIEnv* env, jobject, jint mode) {
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
Java_com_rawlab_android_NativeProcessor_nativeDestroy(JNIEnv*, jobject, jlong id) {
    std::lock_guard<std::mutex> lock(sessionsMutex);
    sessions.erase(id);
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_NativeProcessor_nativeSetGpuMode(JNIEnv* env, jobject, jlong id, jint mode) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const auto found = sessions.find(id);
        if (found == sessions.end() || mode < 0 || mode > 2) throw std::invalid_argument("Invalid processor or GPU mode");
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), static_cast<sony2fuji_gpu_mode>(mode)};
        check(sony2fuji_session_set_gpu_config(found->second.get(), &config));
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_NativeProcessor_nativeProcess(JNIEnv* env, jobject, jlong id,
    jstring input, jstring lut, jstring output, jfloat strength, jfloat exposure,
    jboolean customWb, jfloat temperature, jfloat tint, jfloat highlights, jfloat shadows,
    jfloat contrast, jfloat toneCurve, jfloat saturation, jfloat sharpening,
    jint edge, jboolean interactive, jboolean png, jint longEdge,
    jboolean denoiseEnabled, jfloat luma, jfloat chroma, jfloat coarse, jint displayChromaDenoise,
    jfloat vignetteAmount, jfloat vignetteMidpoint, jfloat vignetteRoundness, jfloat vignetteFeather,
    jfloat vignetteHighlights, jfloat grainAmount, jfloat grainSize, jfloat grainRoughness) {
    try {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const auto found = sessions.find(id);
        if (found == sessions.end()) throw std::invalid_argument("Processor is closed");
        auto* session = found->second.get();
        UtfChars in(env, input), film(env, lut), out(env, output);
        auto request = rawlab::makeRequest(in.chars, film.chars, out.chars, strength,
            exposure, customWb, temperature, tint, highlights, shadows, contrast,
            toneCurve, saturation, sharpening, edge, png,
            longEdge < 0 ? 0u : static_cast<uint32_t>(longEdge));
        check(sony2fuji_session_set_interactive_preview(session, interactive && !out.chars));
        sony2fuji_wavelet_denoise_config denoise{SONY2FUJI_WAVELET_DENOISE_CONFIG_VERSION,
            sizeof(sony2fuji_wavelet_denoise_config), denoiseEnabled ? 1 : 0, luma, chroma, coarse};
        check(sony2fuji_session_set_wavelet_denoise(session, &denoise));
        sony2fuji_photo_effects_config effects{SONY2FUJI_PHOTO_EFFECTS_CONFIG_VERSION,
            sizeof(sony2fuji_photo_effects_config), vignetteAmount, vignetteMidpoint, vignetteRoundness,
            vignetteFeather, vignetteHighlights, grainAmount, grainSize, grainRoughness};
        check(sony2fuji_session_set_photo_effects(session, &effects));
        check(sony2fuji_session_set_chroma_denoise(session, displayChromaDenoise));
        Buffer buffer;
        check(sony2fuji_process(session, &request, &buffer.value));
        if (output) return nullptr;
        const auto& b = buffer.value;
        const size_t row = static_cast<size_t>(b.width) * 4;
        const size_t bytes = rawlab::previewByteCount(b);
        if (bytes > static_cast<size_t>(std::numeric_limits<jsize>::max()))
            throw std::runtime_error("Invalid preview buffer");
        auto pixels = env->NewByteArray(static_cast<jsize>(bytes));
        if (!pixels) return nullptr;
        for (uint32_t y = 0; y < b.height && !env->ExceptionCheck(); ++y) {
            env->SetByteArrayRegion(pixels, static_cast<jsize>(y * row), static_cast<jsize>(row),
                reinterpret_cast<const jbyte*>(b.data) + y * b.stride_bytes);
        }
        if (env->ExceptionCheck()) return nullptr;
        float kelvin = NAN, wbTint = NAN;
        sony2fuji_session_get_raw_white_balance(session, &kelvin, &wbTint);
        auto type = env->FindClass("com/rawlab/android/NativeFrame");
        if (!type) return nullptr;
        auto constructor = env->GetMethodID(type, "<init>", "(II[BFFI)V");
        if (!constructor) return nullptr;
        return env->NewObject(type, constructor, static_cast<jint>(b.width),
            static_cast<jint>(b.height), pixels, kelvin, wbTint, static_cast<jint>(sony2fuji_session_get_last_backend(session)));
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
