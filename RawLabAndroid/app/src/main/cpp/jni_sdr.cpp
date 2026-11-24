#include "jni_internal.h"
#include "png16_color.h"
#include "png16_decoder.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace rawlab::jni {

std::mutex sessionsMutex;
std::unordered_map<jlong, std::shared_ptr<Session>> sessions;
jlong nextId = 1;
std::mutex cancellationMutex;
std::unordered_map<jlong, std::shared_ptr<std::atomic<jlong>>> cancellationStates;

namespace {

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

jmethodID cacheMethod(JNIEnv* env, jclass clazz, const char* name, const char* sig) {
    jmethodID method = env->GetMethodID(clazz, name, sig);
    if (!method) throw std::runtime_error(std::string("Missing JNI method: ") + name + " " + sig);
    return method;
}

jmethodID cacheStaticMethod(JNIEnv* env, jclass clazz, const char* name, const char* sig) {
    jmethodID method = env->GetStaticMethodID(clazz, name, sig);
    if (!method) throw std::runtime_error(std::string("Missing JNI static method: ") + name + " " + sig);
    return method;
}

void initJniCache(JNIEnv* env) {
    JniCache c{};
    try {
        struct Binding { jclass* clazz; const char* className; jmethodID* ctor; const char* sig; };
        const Binding bindings[] = {
            {&c.nativeFrame.clazz, "com/rawlab/android/engine/NativeFrame", &c.nativeFrame.ctor, "(IILandroid/graphics/Bitmap;FFI[I)V"},
            {&c.nativeProcessingException.clazz, "com/rawlab/android/engine/NativeProcessingException", &c.nativeProcessingException.ctor, "(ILjava/lang/String;I)V"},
            {&c.hdrProcessingException.clazz, "com/rawlab/android/engine/HDRProcessingException", &c.hdrProcessingException.ctor, "(III)V"},
            {&c.dcpCompilationException.clazz, "com/rawlab/android/looks/DcpCompilationException", &c.dcpCompilationException.ctor, "(I)V"},
            {&c.lutColorContractException.clazz, "com/rawlab/android/engine/LUTColorContractException", &c.lutColorContractException.ctor, "(I)V"},
            {&c.hdrSourceInfo.clazz, "com/rawlab/android/photo/HDRSourceInfo", &c.hdrSourceInfo.ctor, "(IIIIIIFI[BZI)V"},
            {&c.nativeRoiBounds.clazz, "com/rawlab/android/engine/NativeRoiBounds", &c.nativeRoiBounds.ctor, "(IIIIII)V"},
            {&c.nativeRoiFrame.clazz, "com/rawlab/android/engine/NativeRoiFrame", &c.nativeRoiFrame.ctor, "(Lcom/rawlab/android/engine/NativeFrame;Lcom/rawlab/android/engine/NativeRoiBounds;)V"},
            {&c.nativeWbProbeResult.clazz, "com/rawlab/android/engine/NativeWbProbeResult", &c.nativeWbProbeResult.ctor, "(IFFII)V"},
            {&c.nativeHslProbeResult.clazz, "com/rawlab/android/engine/NativeHslProbeResult", &c.nativeHslProbeResult.ctor, "(IZ[F[F)V"},
            {&c.nativeMigrationResult.clazz, "com/rawlab/android/engine/NativeMigrationResult", &c.nativeMigrationResult.ctor, "(IIIIFFFFFFFFFFFFFF)V"},
            {&c.lensCandidate.clazz, "com/rawlab/android/engine/LensCandidate", &c.lensCandidate.ctor, "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ZZZZ)V"},
            {&c.nativeLensReport.clazz, "com/rawlab/android/engine/NativeLensReport", &c.nativeLensReport.ctor, "(ILjava/lang/String;Ljava/lang/String;ZZFZ)V"},
            {&c.nativeLensInspection.clazz, "com/rawlab/android/engine/NativeLensInspection", &c.nativeLensInspection.ctor, "(ZZZ)V"},
            {&c.nativeLookValidation.clazz, "com/rawlab/android/engine/NativeLookValidation", &c.nativeLookValidation.ctor, "(III)V"},
            {&c.nativeCameraWhiteBalance.clazz, "com/rawlab/android/engine/NativeCameraWhiteBalance", &c.nativeCameraWhiteBalance.ctor, "(FF)V"},
            {&c.nativeHdrPairInfo.clazz, "com/rawlab/android/engine/NativeHDRPairInfo", &c.nativeHdrPairInfo.ctor, "(IIIIIIFF)V"},
            {&c.nativeHdrRoiPair.clazz, "com/rawlab/android/engine/NativeHDRRoiPair", &c.nativeHdrRoiPair.ctor, "(JLcom/rawlab/android/engine/NativeRoiBounds;)V"},
        };
        for (const auto& b : bindings) {
            *b.clazz = cacheGlobalClass(env, b.className);
            *b.ctor = cacheMethod(env, *b.clazz, "<init>", b.sig);
        }
        c.nativeFrame.allocateBitmap = cacheStaticMethod(env, c.nativeFrame.clazz, "allocateBitmap",
            "(IILandroid/graphics/Bitmap;)Landroid/graphics/Bitmap;");
        c.javaString.clazz = cacheGlobalClass(env, "java/lang/String");
        c.javaString.bytesCtor = cacheMethod(env, c.javaString.clazz, "<init>", "([BLjava/lang/String;)V");
        c.hdrProgressListener.clazz = cacheGlobalClass(env, "com/rawlab/android/engine/HDRProgressListener");
        c.hdrProgressListener.onProgress = cacheMethod(env, c.hdrProgressListener.clazz, "onProgress", "(I)V");
        gJniCache = c;
        gJniCacheReady.store(true, std::memory_order_release);
    } catch (...) {
        gJniCache = c;
        gJniCacheReady.store(true, std::memory_order_release);
        releaseJniCache(env);
        throw;
    }
}

} // namespace

const JniCache& jniCache(JNIEnv* env) {
    std::call_once(gJniCacheOnce, [&] { initJniCache(env); });
    return gJniCache;
}

void releaseJniCache(JNIEnv* env) {
    if (!gJniCacheReady.exchange(false, std::memory_order_acq_rel)) return;
    jclass* classes[] = {
        &gJniCache.nativeFrame.clazz, &gJniCache.nativeProcessingException.clazz,
        &gJniCache.hdrProcessingException.clazz, &gJniCache.dcpCompilationException.clazz,
        &gJniCache.lutColorContractException.clazz, &gJniCache.javaString.clazz,
        &gJniCache.hdrSourceInfo.clazz, &gJniCache.nativeRoiBounds.clazz,
        &gJniCache.nativeRoiFrame.clazz, &gJniCache.nativeWbProbeResult.clazz,
        &gJniCache.nativeHslProbeResult.clazz, &gJniCache.nativeMigrationResult.clazz,
        &gJniCache.lensCandidate.clazz, &gJniCache.nativeLensReport.clazz,
        &gJniCache.nativeLensInspection.clazz, &gJniCache.nativeLookValidation.clazz,
        &gJniCache.nativeCameraWhiteBalance.clazz, &gJniCache.nativeHdrPairInfo.clazz,
        &gJniCache.nativeHdrRoiPair.clazz, &gJniCache.hdrProgressListener.clazz,
    };
    for (jclass* slot : classes) {
        if (*slot) { env->DeleteGlobalRef(*slot); *slot = nullptr; }
    }
}

std::shared_ptr<Session> acquireSession(jlong id) {
    std::lock_guard<std::mutex> lock(sessionsMutex);
    const auto found = sessions.find(id);
    if (found == sessions.end()) throw std::invalid_argument("Processor is closed");
    return found->second;
}

void throwJava(JNIEnv* env, const char* type, const char* message) {
    if (!env->ExceptionCheck()) {
        if (jclass clazz = env->FindClass(type)) {
            env->ThrowNew(clazz, message);
            env->DeleteLocalRef(clazz);
        }
    }
}

void throwNativeStatus(JNIEnv* env, const NativeStatusError& error) {
    if (env->ExceptionCheck()) return;
    try {
        const auto& cache = jniCache(env);
        LocalRef message(env, env->NewStringUTF(error.what()));
        if (!message) return;
        LocalRef exception(env, env->NewObject(cache.nativeProcessingException.clazz, cache.nativeProcessingException.ctor,
            static_cast<jint>(error.status), message.get(), static_cast<jint>(error.unsupportedReason)));
        if (exception) env->Throw(static_cast<jthrowable>(exception.get()));
    } catch (...) {
        env->ExceptionClear();
        throwJava(env, "java/io/IOException", error.what());
    }
}

void handleSdrException(JNIEnv* env, const char* oomMessage) noexcept {
    try {
        throw;
    } catch (const NativeStatusError& error) {
        throwNativeStatus(env, error);
    } catch (const std::bad_alloc&) {
        throwJava(env, "java/lang/OutOfMemoryError", oomMessage);
    } catch (const std::invalid_argument& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) {
        throwJava(env, "java/io/IOException", error.what());
    } catch (...) {
        throwJava(env, "java/io/IOException", "Native processing failed");
    }
}

void check(sony2fuji_status status, sony2fuji_session* session) {
    if (status != SONY2FUJI_STATUS_OK && status != SONY2FUJI_STATUS_CANCELLED && session) {
        const char* message = sony2fuji_session_x3f_error(session);
        if (message && *message) throw std::runtime_error(message);
    }
    if (status == SONY2FUJI_STATUS_UNSUPPORTED) {
        throw NativeStatusError(status,
            session ? sony2fuji_session_get_unsupported_reason(session) : SONY2FUJI_UNSUPPORTED_NONE);
    }
    if (status == SONY2FUJI_STATUS_IO_ERROR || status == SONY2FUJI_STATUS_OUTPUT_IO_ERROR ||
        status == SONY2FUJI_STATUS_CANCELLED) {
        throw NativeStatusError(status);
    }
    if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) throw std::bad_alloc();
    if (status == SONY2FUJI_STATUS_INVALID_ARGUMENT) throw std::invalid_argument(sony2fuji_status_message(status));
    if (status != SONY2FUJI_STATUS_OK) throw std::runtime_error(sony2fuji_status_message(status));
}

jstring newUtf8String(JNIEnv* env, const char* utf8) {
    const char* text = utf8 ? utf8 : "";
    const size_t len = std::strlen(text);
    if (len > static_cast<size_t>(std::numeric_limits<jsize>::max())) throw std::bad_alloc();
    const auto& cache = jniCache(env);
    LocalRef charset(env, env->NewStringUTF("UTF-8"));
    LocalRef bytes(env, charset ? env->NewByteArray(static_cast<jsize>(len)) : nullptr);
    if (!bytes) return nullptr;
    if (len > 0) {
        env->SetByteArrayRegion(bytes.asByteArray(), 0, static_cast<jsize>(len), reinterpret_cast<const jbyte*>(text));
        if (env->ExceptionCheck()) return nullptr;
    }
    LocalRef str(env, env->NewObject(cache.javaString.clazz, cache.javaString.bytesCtor, bytes.get(), charset.get()));
    return env->ExceptionCheck() ? nullptr : static_cast<jstring>(str.release());
}

BitmapPixels::BitmapPixels(JNIEnv* e, jobject bitmap, jint width, jint height, jint format, bool compactInput)
    : env(e), value(bitmap) {
    if (!bitmap) {
        if (width != 0 || height != 0 || format != 0) throw std::invalid_argument("Invalid RAW image buffer");
        return;
    }
    if (format == SONY2FUJI_PIXEL_RGBA16) {
        if (width <= 0 || height <= 0 || uint64_t(width) * height > 128000000) {
            throw std::invalid_argument("Invalid display buffer dimensions");
        }
        const auto capacity = env->GetDirectBufferCapacity(bitmap);
        bytes = env->GetDirectBufferAddress(bitmap);
        if (!bytes || capacity != int64_t(width) * height * 8) throw std::invalid_argument("Invalid RGBA16 display buffer");
        stride = static_cast<uint32_t>(width) * 8;
        return;
    }
    AndroidBitmapInfo info{};
    if (width <= 0 || height <= 0 || format != SONY2FUJI_PIXEL_RGBA8 ||
        AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
        info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.width != static_cast<uint32_t>(width) ||
        info.height != static_cast<uint32_t>(height) || info.stride < uint64_t(width) * 4) {
        throw std::invalid_argument("Invalid display bitmap");
    }
    stride = info.stride;
    const size_t rowBytes = static_cast<size_t>(width) * 4;
    if (static_cast<size_t>(height) > std::numeric_limits<size_t>::max() / rowBytes) {
        throw std::invalid_argument("Display bitmap is too large");
    }
    const auto result = AndroidBitmap_lockPixels(env, bitmap, &locked);
    if (result == ANDROID_BITMAP_RESULT_ALLOCATION_FAILED) throw std::bad_alloc();
    if (result != ANDROID_BITMAP_RESULT_SUCCESS) throw std::runtime_error("Unable to lock display bitmap");
    try {
        if (!locked) throw std::runtime_error("Display bitmap has no pixels");
        bytes = locked;
        if (compactInput && info.stride != rowBytes) {
            packed.resize(rowBytes * height);
            for (int y = 0; y < height; ++y) {
                std::memcpy(packed.data() + size_t(y) * rowBytes,
                    static_cast<const uint8_t*>(locked) + size_t(y) * info.stride, rowBytes);
            }
            bytes = packed.data();
        }
    } catch (...) {
        AndroidBitmap_unlockPixels(env, value);
        locked = nullptr;
        throw;
    }
}

OutputBitmapLock::OutputBitmapLock(JNIEnv* e, jobject bmp, AndroidBitmapInfo& info,
    uint32_t expectedWidth, uint32_t expectedHeight)
    : env(e), bitmap(bmp) {
    if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
        info.format != ANDROID_BITMAP_FORMAT_RGBA_8888 || info.width != expectedWidth ||
        info.height != expectedHeight || info.stride < static_cast<uint64_t>(expectedWidth) * 4) {
        throw std::runtime_error("Invalid output bitmap");
    }
    const auto lockResult = AndroidBitmap_lockPixels(env, bitmap, &locked);
    if (lockResult == ANDROID_BITMAP_RESULT_ALLOCATION_FAILED) throw std::bad_alloc();
    if (lockResult != ANDROID_BITMAP_RESULT_SUCCESS) throw std::runtime_error("Unable to lock output bitmap");
    if (!locked) {
        AndroidBitmap_unlockPixels(env, bitmap);
        locked = nullptr;
        throw std::runtime_error("Output bitmap has no pixels");
    }
}

size_t previewByteCount(const sony2fuji_buffer& buffer) {
    const uint64_t row = static_cast<uint64_t>(buffer.width) * 4;
    if (!buffer.data || buffer.width == 0 || buffer.height == 0 ||
        buffer.pixel_format != SONY2FUJI_PIXEL_RGBA8 || buffer.stride_bytes < row ||
        buffer.height > std::numeric_limits<size_t>::max() / buffer.stride_bytes ||
        buffer.size_bytes < static_cast<size_t>(buffer.height - 1) * buffer.stride_bytes + row) {
        throw std::runtime_error("Invalid preview buffer");
    }
    return static_cast<size_t>(row) * buffer.height;
}

jobject writeRgba8Bitmap(JNIEnv* env, const sony2fuji_buffer& b, jobject reusableBitmap,
    const CancellationScope* cancellation) {
    if (!b.data || b.width == 0 || b.height == 0 || b.pixel_format != SONY2FUJI_PIXEL_RGBA8 ||
        b.width > static_cast<uint32_t>(std::numeric_limits<jint>::max()) ||
        b.height > static_cast<uint32_t>(std::numeric_limits<jint>::max()) ||
        b.stride_bytes < static_cast<uint64_t>(b.width) * 4) {
        throw std::runtime_error("Invalid preview buffer");
    }
    const size_t row = static_cast<size_t>(b.width) * 4;
    const size_t bytes = previewByteCount(b);
    if (bytes > static_cast<size_t>(std::numeric_limits<jsize>::max())) throw std::runtime_error("Invalid preview buffer");
    const auto& cache = jniCache(env);
    LocalRef bitmap(env, env->CallStaticObjectMethod(cache.nativeFrame.clazz, cache.nativeFrame.allocateBitmap,
        static_cast<jint>(b.width), static_cast<jint>(b.height), reusableBitmap));
    if (env->ExceptionCheck()) return nullptr;
    if (!bitmap) throw std::bad_alloc();
    {
        AndroidBitmapInfo info{};
        OutputBitmapLock lock(env, bitmap.get(), info, b.width, b.height);
        if (b.stride_bytes == row && info.stride == row && !cancellation) {
            std::memcpy(lock.locked, b.data, bytes);
        } else {
            const auto* src = static_cast<const uint8_t*>(b.data);
            auto* dst = static_cast<uint8_t*>(lock.locked);
            for (uint32_t y = 0; y < b.height; ++y) {
                if (cancellation && cancellation->isCancelled()) throw NativeStatusError(SONY2FUJI_STATUS_CANCELLED);
                std::memcpy(dst + static_cast<size_t>(y) * info.stride, src + static_cast<size_t>(y) * b.stride_bytes, row);
            }
        }
    }
    return bitmap.release();
}

jobject sampleHslProbeResult(JNIEnv* env, const sony2fuji_hsl_probe* probe,
    jlong sourceRevision, jlong requestRevision, jfloat x, jfloat y) {
    sony2fuji_hsl_probe_query query{SONY2FUJI_HSL_PROBE_VERSION, sizeof(query),
        static_cast<uint64_t>(sourceRevision), static_cast<uint64_t>(requestRevision), x, y};
    sony2fuji_hsl_probe_result sample{};
    check(sony2fuji_hsl_probe_sample(probe, &query, &sample));
    LocalRef rgbArr(env, env->NewFloatArray(3));
    LocalRef weightsArr(env, env->NewFloatArray(SONY2FUJI_HSL_CHANNELS));
    if (!rgbArr || !weightsArr) return nullptr;
    env->SetFloatArrayRegion(rgbArr.asFloatArray(), 0, 3, sample.rgb);
    env->SetFloatArrayRegion(weightsArr.asFloatArray(), 0, SONY2FUJI_HSL_CHANNELS, sample.weights);
    if (env->ExceptionCheck()) return nullptr;
    const auto& cache = jniCache(env);
    return env->NewObject(cache.nativeHslProbeResult.clazz, cache.nativeHslProbeResult.ctor,
        static_cast<jint>(sample.availability), static_cast<jboolean>(sample.quality != 0 ? JNI_TRUE : JNI_FALSE),
        rgbArr.get(), weightsArr.get());
}

sony2fuji_render_options_v1 makeRenderOptions(const char* inputPath, const BitmapPixels& pixels,
    jint width, jint height, jint pixelFormat, const char* outputPath, jint format, jint edge,
    jint longEdge, bool interactive, bool viewportPreview, const sony2fuji_viewport_roi* roi,
    bool allowZeroPreviewEdge) {
    if (!inputPath || !*inputPath) throw std::invalid_argument("Missing input path");
    if (outputPath && format != SONY2FUJI_OUTPUT_JPEG && format != SONY2FUJI_OUTPUT_PNG && format != SONY2FUJI_OUTPUT_DNG) {
        throw std::invalid_argument("Invalid output format");
    }
    if (!outputPath && (allowZeroPreviewEdge ? (edge < 0 || edge > 1600) : (edge < 1 || edge > 1600))) {
        throw std::invalid_argument("Invalid preview edge");
    }
    if (outputPath && (longEdge < 0 || longEdge > 65535)) throw std::invalid_argument("Invalid export long edge");
    const bool displayInput = pixels.bytes != nullptr;
    const bool isExport = outputPath != nullptr;
    sony2fuji_render_options_v1 opts{};
    opts.version = SONY2FUJI_RENDER_OPTIONS_V1_VERSION;
    opts.struct_size = sizeof(opts);
    opts.input_type = displayInput ? SONY2FUJI_INPUT_DISPLAY_BUFFER : SONY2FUJI_INPUT_RAW;
    opts.input_pixel_format = displayInput ? static_cast<sony2fuji_pixel_format>(pixelFormat) : SONY2FUJI_PIXEL_RGBA8;
    opts.input_path = inputPath;
    opts.input_pixels = pixels.bytes;
    opts.input_width = displayInput ? static_cast<uint32_t>(width) : 0u;
    opts.input_height = displayInput ? static_cast<uint32_t>(height) : 0u;
    opts.input_color_space = SONY2FUJI_COLOR_SRGB;
    opts.intent = isExport ? SONY2FUJI_INTENT_FINAL : SONY2FUJI_INTENT_PREVIEW;
    opts.size_mode = (isExport && longEdge > 0) ? SONY2FUJI_SIZE_LIMIT_LONG_EDGE : SONY2FUJI_SIZE_NATIVE;
    opts.long_edge = isExport ? static_cast<uint32_t>(longEdge) : 0u;
    opts.preview_long_edge = isExport ? 0u : static_cast<uint32_t>(edge);
    opts.interactive_preview = (interactive && !isExport && !roi) ? 1 : 0;
    opts.viewport_preview = (viewportPreview || roi) ? 1 : 0;
    opts.viewport_roi = roi;
    opts.output_target = isExport ? SONY2FUJI_TARGET_FILE : SONY2FUJI_TARGET_BUFFER;
    opts.output_format = isExport ? static_cast<sony2fuji_output_format>(format) : SONY2FUJI_OUTPUT_RGBA8;
    opts.output_path = outputPath;
    opts.jpeg_quality = 95u;
    return opts;
}

} // namespace rawlab::jni

using namespace rawlab::jni;

namespace {

jobject buildNativeFrame(JNIEnv* env, sony2fuji_session* session, const sony2fuji_buffer& b,
    jobject reusableBitmap, bool computeHistogram, bool fetchWhiteBalance, const CancellationScope* cancellation) {
    LocalRef bitmapOut(env, writeRgba8Bitmap(env, b, reusableBitmap, cancellation));
    if (!bitmapOut) return nullptr;
    LocalRef histogram(env, nullptr);
    if (cancellation) check(cancellation->isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
    if (computeHistogram) {
        uint32_t counts[768]{};
        uint32_t shadowsCount = 0, highlightsCount = 0;
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
    if (cancellation) check(cancellation->isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
    float kelvin = NAN, wbTint = NAN;
    if (!fetchWhiteBalance ||
        sony2fuji_session_get_effective_raw_white_balance(session, &kelvin, &wbTint) != SONY2FUJI_STATUS_OK) {
        kelvin = NAN; wbTint = NAN;
    }
    const auto& cache = jniCache(env);
    return env->NewObject(cache.nativeFrame.clazz, cache.nativeFrame.ctor,
        static_cast<jint>(b.width), static_cast<jint>(b.height), bitmapOut.get(),
        kelvin, wbTint, static_cast<jint>(sony2fuji_session_get_last_backend(session)), histogram.get());
}

} // namespace

extern "C" JNIEXPORT void JNICALL JNI_OnUnload(JavaVM* vm, void*) {
    JNIEnv* env = nullptr;
    if (vm && vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK && env) releaseJniCache(env);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(JNIEnv* env, jobject, jint mode) {
    try {
        if (mode < SONY2FUJI_GPU_OFF || mode > SONY2FUJI_GPU_FORCE) throw std::invalid_argument("Invalid GPU mode");
        sony2fuji_session* pointer = nullptr;
        check(sony2fuji_session_create(&pointer));
        std::unique_ptr<sony2fuji_session, SessionDeleter> owned(pointer);
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), static_cast<sony2fuji_gpu_mode>(mode)};
        check(sony2fuji_session_set_gpu_config(owned.get(), &config));
        auto session = std::make_shared<Session>(nullptr);
        session->value = std::move(owned);
        std::lock_guard<std::mutex> lock(sessionsMutex);
        const jlong id = nextId++;
        { std::lock_guard<std::mutex> signalLock(cancellationMutex); cancellationStates.emplace(id, session->generation); }
        try { sessions.emplace(id, std::move(session)); }
        catch (...) {
            std::lock_guard<std::mutex> signalLock(cancellationMutex);
            cancellationStates.erase(id);
            throw;
        }
        return id;
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to create a RAW session");
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalStateException", error.what()); }
    return 0;
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(JNIEnv*, jobject, jlong id) {
    std::shared_ptr<Session> removed;
    {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        { std::lock_guard<std::mutex> signalLock(cancellationMutex); cancellationStates.erase(id); }
        const auto found = sessions.find(id);
        if (found != sessions.end()) { removed = std::move(found->second); sessions.erase(found); }
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
        if (mode < SONY2FUJI_GPU_OFF || mode > SONY2FUJI_GPU_FORCE) throw std::invalid_argument("Invalid processor or GPU mode");
        sony2fuji_gpu_config config{SONY2FUJI_GPU_CONFIG_VERSION, sizeof(config), static_cast<sony2fuji_gpu_mode>(mode)};
        check(sony2fuji_session_set_gpu_config(guard.get(), &config));
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
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
    } catch (...) { handleSdrException(env, "Not enough memory to inspect X3F"); }
    return SONY2FUJI_X3F_NORMAL;
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeGeometrySize(JNIEnv* env, jobject, jlong id) {
    try {
        SessionGuard guard(id);
        uint32_t width = 0, height = 0;
        check(sony2fuji_session_get_geometry_size(guard.get(), &width, &height));
        if (!width || !height || width > INT32_MAX || height > INT32_MAX) throw std::runtime_error("Invalid geometry dimensions");
        auto result = env->NewIntArray(2);
        if (!result) return nullptr;
        const jint dimensions[] = {static_cast<jint>(width), static_cast<jint>(height)};
        env->SetIntArrayRegion(result, 0, 2, dimensions);
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring inputPath, jobject inputPixels, jint inputWidth, jint inputHeight,
    jint inputPixelFormat, jstring outputPath, jint format, jint edge, jint longEdge,
    jboolean interactive, jboolean viewportPreview, jobject reusableBitmap, jlong cancellationGeneration,
    jintArray backendOut) {
    try {
        UtfChars json(env, editStateJson), in(env, inputPath), out(env, outputPath);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing edit state JSON");
        if (backendOut && env->GetArrayLength(backendOut) != 1) throw std::invalid_argument("Invalid backend output");
        SessionGuard guard(id);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        auto* session = guard.get();
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const auto options = makeRenderOptions(in.chars, inputBytes, inputWidth, inputHeight, inputPixelFormat,
            out.chars, format, edge, longEdge, interactive != JNI_FALSE, viewportPreview != JNI_FALSE, nullptr);
        Buffer buffer;
        const auto status = sony2fuji_session_render(session, &options, json.chars, out.chars ? nullptr : &buffer.value, nullptr);
        if (out.chars && status == SONY2FUJI_STATUS_CANCELLED) std::remove(out.chars);
        check(status, session);
        if (!out.chars) check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        if (backendOut) {
            const auto backend = static_cast<jint>(sony2fuji_session_get_last_backend(session));
            env->SetIntArrayRegion(backendOut, 0, 1, &backend);
            if (env->ExceptionCheck()) return nullptr;
        }
        if (out.chars) return nullptr;
        return buildNativeFrame(env, session, buffer.value, reusableBitmap,
            interactive == JNI_FALSE, inputPixels == nullptr, &cancellation);
    } catch (...) { handleSdrException(env, "Not enough memory to develop this RAW"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeProcessRoi(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring inputPath, jobject inputPixels, jint inputWidth, jint inputHeight,
    jint inputPixelFormat, jfloat x0, jfloat y0, jfloat x1, jfloat y1, jint maxOutputLongEdge,
    jlong cancellationGeneration) {
    try {
        UtfChars json(env, editStateJson), in(env, inputPath);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing edit state JSON");
        if (!std::isfinite(x0) || !std::isfinite(y0) || !std::isfinite(x1) || !std::isfinite(y1) || maxOutputLongEdge <= 0) {
            throw std::invalid_argument("Invalid ROI bounds");
        }
        sony2fuji_viewport_roi roi{sizeof(roi), 1u, x0, y0, x1, y1,
            static_cast<uint32_t>(std::clamp(maxOutputLongEdge, jint(1), jint(2048)))};
        SessionGuard guard(id);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        auto* session = guard.get();
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const auto options = makeRenderOptions(in.chars, inputBytes, inputWidth, inputHeight, inputPixelFormat,
            nullptr, 0, 1600, 0, false, true, &roi);
        Buffer buffer;
        sony2fuji_viewport_roi_result roiRes{};
        roiRes.struct_size = sizeof(roiRes);
        check(sony2fuji_session_render(session, &options, json.chars, &buffer.value, &roiRes), session);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        if (roiRes.active == 0) throw std::runtime_error("Viewport ROI result was not produced");
        LocalRef frame(env, buildNativeFrame(env, session, buffer.value, nullptr, false, false, &cancellation));
        if (!frame) return nullptr;
        const auto& cache = jniCache(env);
        LocalRef bounds(env, env->NewObject(cache.nativeRoiBounds.clazz, cache.nativeRoiBounds.ctor,
            static_cast<jint>(roiRes.native_x0), static_cast<jint>(roiRes.native_y0),
            static_cast<jint>(roiRes.native_x1), static_cast<jint>(roiRes.native_y1),
            static_cast<jint>(roiRes.full_native_width), static_cast<jint>(roiRes.full_native_height)));
        return bounds ? env->NewObject(cache.nativeRoiFrame.clazz, cache.nativeRoiFrame.ctor, frame.get(), bounds.get()) : nullptr;
    } catch (...) { handleSdrException(env, "Not enough memory to develop ROI"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSampleWbProbe(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring inputPath, jobject inputPixels, jint inputWidth, jint inputHeight,
    jint inputPixelFormat, jint edge, jfloat x, jfloat y, jint windowSize, jlong cancellationGeneration) {
    try {
        UtfChars json(env, editStateJson), in(env, inputPath);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing edit state JSON");
        SessionGuard guard(id);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        auto* session = guard.get();
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const auto options = makeRenderOptions(in.chars, inputBytes, inputWidth, inputHeight, inputPixelFormat,
            nullptr, 0, edge, 0, false, edge > 0, nullptr, true);
        sony2fuji_wb_probe_query query{SONY2FUJI_WB_PROBE_VERSION, sizeof(query), x, y,
            windowSize <= 0 ? 0u : static_cast<uint32_t>(windowSize), 0u};
        sony2fuji_wb_probe_result wbResult{SONY2FUJI_WB_PROBE_VERSION, sizeof(wbResult)};
        check(sony2fuji_session_sample_wb_probe_json(session, &options, json.chars, &query, &wbResult), session);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeWbProbeResult.clazz, cache.nativeWbProbeResult.ctor,
            static_cast<jint>(wbResult.availability), wbResult.temperature, wbResult.tint,
            static_cast<jint>(wbResult.valid_pixel_count), static_cast<jint>(wbResult.rejected_overexposed_count));
    } catch (...) { handleSdrException(env, "Not enough memory for WB probe"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeSampleHsl(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring inputPath, jobject inputPixels, jint inputWidth, jint inputHeight,
    jint inputPixelFormat, jint edge, jboolean interactive, jlong sourceRevision, jlong requestRevision,
    jfloat x, jfloat y, jlong cancellationGeneration) {
    try {
        UtfChars json(env, editStateJson), in(env, inputPath);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing edit state JSON");
        SessionGuard guard(id);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        auto* session = guard.get();
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const auto options = makeRenderOptions(in.chars, inputBytes, inputWidth, inputHeight, inputPixelFormat,
            nullptr, 0, edge, 0, interactive != JNI_FALSE, edge > 0, nullptr, true);
        sony2fuji_hsl_probe* snapshot = nullptr;
        check(sony2fuji_session_create_hsl_probe_json(session, &options, json.chars,
            static_cast<uint64_t>(sourceRevision), static_cast<uint64_t>(requestRevision), &snapshot), session);
        std::unique_ptr<sony2fuji_hsl_probe, decltype(&sony2fuji_hsl_probe_destroy)> owned(snapshot, sony2fuji_hsl_probe_destroy);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        return sampleHslProbeResult(env, snapshot, sourceRevision, requestRevision, x, y);
    } catch (...) { handleSdrException(env, "Not enough memory for HSL probe"); }
    return nullptr;
}

extern "C" JNIEXPORT jfloat JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeAutoExposure(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring inputPath, jobject inputPixels, jint inputWidth, jint inputHeight, jint inputPixelFormat) {
    try {
        UtfChars json(env, editStateJson), in(env, inputPath);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing edit state JSON");
        SessionGuard guard(id);
        auto* session = guard.get();
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const auto options = makeRenderOptions(in.chars, inputBytes, inputWidth, inputHeight, inputPixelFormat,
            nullptr, 0, 1, 0, false, false, nullptr);
        float ev = 0.0f;
        check(sony2fuji_session_estimate_auto_exposure_json(session, &options, json.chars, &ev), session);
        return ev;
    } catch (...) { handleSdrException(env, "Not enough memory to meter this RAW"); }
    return 0.0f;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeMigrateProcessing(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring inputPath, jobject inputPixels, jint inputWidth, jint inputHeight,
    jint inputPixelFormat, jlong cancellationGeneration) {
    try {
        UtfChars json(env, editStateJson), in(env, inputPath);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing edit state JSON");
        SessionGuard guard(id);
        CancellationScope cancellation(guard.session(), cancellationGeneration);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        auto* session = guard.get();
        BitmapPixels inputBytes(env, inputPixels, inputWidth, inputHeight, inputPixelFormat);
        const auto options = makeRenderOptions(in.chars, inputBytes, inputWidth, inputHeight, inputPixelFormat,
            nullptr, 0, 0, 0, false, false, nullptr, true);
        sony2fuji_processing_migration_result result{};
        check(sony2fuji_session_migrate_processing_json(session, &options, json.chars, &result), session);
        check(cancellation.isCancelled() ? SONY2FUJI_STATUS_CANCELLED : SONY2FUJI_STATUS_OK);
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeMigrationResult.clazz, cache.nativeMigrationResult.ctor,
            static_cast<jint>(result.source_version), static_cast<jint>(result.target_version),
            static_cast<jint>(result.disposition), static_cast<jint>(result.evaluation_count),
            result.exposure_ev, result.contrast, result.highlights, result.shadows, result.saturation,
            result.black_point, result.white_point, result.vibrance, result.clarity, result.dehaze,
            result.rgb_rmse, result.p99_error, result.worst_tile_rmse, result.detail_rmse);
    } catch (...) { handleSdrException(env, "Not enough memory for migration"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeCompatibilityPreview(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring inputPath, jobject bitmap, jint width, jint height, jint pixelFormat, jstring configuration) {
    try {
        UtfChars json(env, editStateJson), source(env, inputPath), contract(env, configuration);
        if (!json.chars || !*json.chars) throw std::invalid_argument("Missing edit state JSON");
        SessionGuard guard(id);
        auto* session = guard.get();
        BitmapPixels pixels(env, bitmap, width, height, pixelFormat);
        const auto options = makeRenderOptions(source.chars, pixels, width, height, pixelFormat,
            nullptr, 0, 512, 0, false, false, nullptr);
        Buffer result;
        const auto status = contract.chars
            ? sony2fuji_preview_lut_compatibility_json(session, &options, json.chars, contract.chars, &result.value)
            : sony2fuji_session_render(session, &options, json.chars, &result.value, nullptr);
        check(status, session);
        const auto& b = result.value;
        const auto count = previewByteCount(b);
        if (b.width > 1024 || b.height > 1024 || count > static_cast<size_t>(std::numeric_limits<jsize>::max())) {
            throw std::runtime_error("Invalid preview output");
        }
        return buildNativeFrame(env, session, b, nullptr, false, false, nullptr);
    } catch (...) { handleSdrException(env, "Not enough memory for LUT preview"); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeResolveCameraWhiteBalance(JNIEnv* env, jobject, jlong id,
    jstring input, jint processingVersion, jint x3fMode, jint exposureMode) {
    try {
        SessionGuard guard(id);
        auto* session = guard.get();
        UtfChars path(env, input);
        if (!path.chars || !*path.chars) throw std::invalid_argument("Missing input path");
        sony2fuji_recipe_wb_request req{SONY2FUJI_RECIPE_WB_REQUEST_VERSION, sizeof(req), path.chars,
            static_cast<sony2fuji_processing_version>(processingVersion), static_cast<sony2fuji_x3f_mode>(x3fMode),
            static_cast<sony2fuji_raw_exposure_mode>(exposureMode), 1, 1.0f, 0, 6500.0f, 1.0f};
        sony2fuji_recipe_wb_result res{};
        const auto status = sony2fuji_session_resolve_recipe_wb(session, &req, &res);
        if (status == SONY2FUJI_STATUS_UNSUPPORTED || !res.camera_calibrated) return nullptr;
        check(status, session);
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeCameraWhiteBalance.clazz, cache.nativeCameraWhiteBalance.ctor,
            res.camera_temperature, res.camera_tint);
    } catch (...) { handleSdrException(env, "Not enough memory to inspect white balance"); }
    return nullptr;
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

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_raster_NativePng16_nativeConvert(JNIEnv* env, jobject, jobject pixels, jbyteArray iccProfile) {
    try {
        auto* data = pixels ? static_cast<uint16_t*>(env->GetDirectBufferAddress(pixels)) : nullptr;
        const auto bytes = pixels ? env->GetDirectBufferCapacity(pixels) : -1;
        const jsize profileLength = iccProfile ? env->GetArrayLength(iccProfile) : 0;
        if (!data || bytes < 0 || bytes % 8 != 0 || profileLength <= 0) {
            throw std::invalid_argument("Invalid PNG color conversion buffer");
        }
        ByteArrayElements profile(env, iccProfile);
        if (env->ExceptionCheck()) return;
        rawlab::convertPng16ToSrgb(data, static_cast<size_t>(bytes / 8), profile.bytes, static_cast<size_t>(profileLength));
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for PNG");
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
}

extern "C" JNIEXPORT void JNICALL
Java_com_rawlab_android_raster_NativePng16_nativeRelease(JNIEnv* env, jobject, jobject pixels) {
    rawlab::Png16Deleter{}(static_cast<uint16_t*>(env->GetDirectBufferAddress(pixels)));
}

extern "C" JNIEXPORT jint JNICALL
Java_com_rawlab_android_raster_NativeMpf_nativeInspectSdrJpegMpf(JNIEnv* env, jobject, jstring path) {
    try {
        UtfChars source(env, path);
        return source.chars ? static_cast<jint>(sony2fuji_inspect_sdr_jpeg_mpf(source.chars)) : -1;
    } catch (...) { return -1; }
}
