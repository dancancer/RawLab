#include "jni_internal.h"

using namespace rawlab::jni;

namespace {

sony2fuji_tone_curve_config curveConfig(JNIEnv* env, jint mode, jdoubleArray points) {
    if (!points) throw std::invalid_argument("Missing curve points");
    const jsize length = env->GetArrayLength(points);
    if (length < 0 || length % 2 != 0 ||
        static_cast<uint32_t>(length) > 2u * SONY2FUJI_TONE_CURVE_MAX_POINTS || (mode != 0 && mode != 1)) {
        throw std::invalid_argument("Invalid curve points");
    }
    sony2fuji_tone_curve_config config{};
    config.version = SONY2FUJI_TONE_CURVE_CONFIG_VERSION;
    config.struct_size = sizeof(config);
    config.mode = static_cast<sony2fuji_curve_mode>(mode);
    config.count = static_cast<uint32_t>(length / 2);
    std::vector<double> values(static_cast<size_t>(length));
    if (length) env->GetDoubleArrayRegion(points, 0, length, values.data());
    if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read curve points");
    for (uint32_t i = 0; i < config.count; ++i) config.points[i] = {values[i * 2], values[i * 2 + 1]};
    return config;
}

sony2fuji_tone_curve_parametric_config readParametricArray(JNIEnv* env, jdoubleArray parametric) {
    if (!parametric || env->GetArrayLength(parametric) != 7) {
        throw std::invalid_argument("Invalid parametric curve");
    }
    jdouble vals[7]{};
    env->GetDoubleArrayRegion(parametric, 0, 7, vals);
    if (env->ExceptionCheck()) throw std::invalid_argument("Cannot read parametric curve");
    return {
        SONY2FUJI_TONE_CURVE_PARAMETRIC_CONFIG_VERSION,
        sizeof(sony2fuji_tone_curve_parametric_config),
        static_cast<float>(vals[0]),
        static_cast<float>(vals[1]),
        static_cast<float>(vals[2]),
        static_cast<float>(vals[3]),
        static_cast<float>(vals[4]),
        static_cast<float>(vals[5]),
        static_cast<float>(vals[6]),
        0u,
    };
}

} // namespace

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
        if (env->GetArrayLength(names) != 4 || !numbers || env->GetArrayLength(numbers) != 3) {
            throw std::invalid_argument("Invalid display lens metadata");
        }
        DisplayLensMetadata next;
        next.present = true;
        for (int index = 0; index < 4; ++index) {
            LocalRef item(env, env->GetObjectArrayElement(names, index));
            UtfChars name(env, item.asString());
            next.names[index] = name.chars ? name.chars : "";
        }
        float values[3];
        env->GetFloatArrayRegion(numbers, 0, 3, values);
        if (env->ExceptionCheck()) return;
        next.focal = values[0];
        next.aperture = values[1];
        next.crop = values[2];
        next.orientation = orientation;
        const auto metadata = next.value();
        check(sony2fuji_session_set_display_lens_metadata(session, &metadata));
        owner.displayLens = std::move(next);
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
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
        const auto& cache = jniCache(env);
        auto result = env->NewObjectArray(static_cast<jsize>(count), cache.lensCandidate.clazz, nullptr);
        if (!result) return nullptr;
        for (uint32_t i = 0; i < count; ++i) {
            const auto& p = profiles[i];
            LocalRef jId(env, newUtf8String(env, p.base.id));
            LocalRef jMaker(env, newUtf8String(env, p.base.maker));
            LocalRef jModel(env, newUtf8String(env, p.base.model));
            if (!jId || !jMaker || !jModel) return nullptr;
            LocalRef candidate(env, env->NewObject(cache.lensCandidate.clazz, cache.lensCandidate.ctor,
                jId.get(), jMaker.get(), jModel.get(),
                static_cast<jboolean>(p.base.has_distortion ? JNI_TRUE : JNI_FALSE),
                static_cast<jboolean>(p.base.has_tca ? JNI_TRUE : JNI_FALSE),
                static_cast<jboolean>(p.base.is_match ? JNI_TRUE : JNI_FALSE),
                static_cast<jboolean>(p.has_vignetting ? JNI_TRUE : JNI_FALSE)));
            if (!candidate) return nullptr;
            env->SetObjectArrayElement(result, static_cast<jsize>(i), candidate.get());
            if (env->ExceptionCheck()) return nullptr;
        }
        return result;
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeLensReport(JNIEnv* env, jobject, jlong id) {
    try {
        SessionGuard guard(id);
        sony2fuji_lens_report_v2 report{};
        check(sony2fuji_session_get_lens_report_v2(guard.get(), &report));
        LocalRef detected(env, newUtf8String(env, report.base.lens_model));
        LocalRef selected(env, newUtf8String(env, report.base.profile.model));
        if (!detected || !selected) return nullptr;
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeLensReport.clazz, cache.nativeLensReport.ctor,
            static_cast<jint>(report.base.state), detected.get(), selected.get(),
            static_cast<jboolean>(report.base.applied_distortion ? JNI_TRUE : JNI_FALSE),
            static_cast<jboolean>(report.base.applied_tca ? JNI_TRUE : JNI_FALSE),
            report.base.crop_scale,
            static_cast<jboolean>(report.applied_vignetting ? JNI_TRUE : JNI_FALSE));
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeProcessor_nativeInspectLens(JNIEnv* env, jobject, jlong id,
    jstring editStateJson, jstring input) {
    try {
        SessionGuard guard(id);
        auto* session = guard.get();
        if (editStateJson) {
            UtfChars json(env, editStateJson);
            if (!json.chars || !*json.chars) throw std::invalid_argument("Missing recipe parameters");
            check(sony2fuji_apply_params(session, json.chars), session);
        }
        UtfChars path(env, input);
        sony2fuji_lens_report_v2 report{};
        uint32_t count = 0;
        const auto& display = guard.session().displayLens;
        const auto metadata = display.value();
        if (!input && !display.present) throw std::invalid_argument("Display lens metadata not configured");
        const auto status = input
            ? sony2fuji_session_inspect_lens_v2(session, path.chars, &report, nullptr, 0, &count)
            : sony2fuji_session_inspect_lens_metadata_v2(session, &metadata, &report, nullptr, 0, &count);
        check(status, session);
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeLensInspection.clazz, cache.nativeLensInspection.ctor,
            static_cast<jboolean>(report.base.applied_distortion ? JNI_TRUE : JNI_FALSE),
            static_cast<jboolean>(report.base.applied_tca ? JNI_TRUE : JNI_FALSE),
            static_cast<jboolean>(report.applied_vignetting ? JNI_TRUE : JNI_FALSE));
    } catch (const NativeStatusError& error) { throwNativeStatus(env, error);
    } catch (const std::invalid_argument& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what());
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_rawlab_android_engine_NativeLookBridge_validate(JNIEnv* env, jclass, jstring path) {
    try {
        UtfChars value(env, path);
        sony2fuji_look_format format = SONY2FUJI_LOOK_UNKNOWN;
        uint32_t version = 0;
        const auto status = sony2fuji_validate_look(value.chars, &format, &version);
        const auto color = sony2fuji_inspect_lut_color(value.chars);
        if (status != SONY2FUJI_STATUS_OK) {
            if (status == SONY2FUJI_STATUS_UNSUPPORTED && color <= SONY2FUJI_LUT_INVALID_CONTRACT) {
                const auto& cache = jniCache(env);
                LocalRef ex(env, env->NewObject(cache.lutColorContractException.clazz,
                    cache.lutColorContractException.ctor, static_cast<jint>(color)));
                if (ex) env->Throw(static_cast<jthrowable>(ex.get()));
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
        const auto& cache = jniCache(env);
        return env->NewObject(cache.nativeLookValidation.clazz, cache.nativeLookValidation.ctor,
            static_cast<jint>(format), static_cast<jint>(version), static_cast<jint>(color));
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to validate look");
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeLookBridge_compatibility(JNIEnv* env, jclass, jstring path, jstring request) {
    DcpBlob blob;
    try {
        UtfChars source(env, path);
        if (request) {
            UtfChars parameters(env, request);
            check(sony2fuji_prepare_lut_compatibility(source.chars, parameters.chars, &blob.value));
        } else {
            check(sony2fuji_inspect_lut_compatibility(source.chars, &blob.value));
        }
        if (blob.value.size_bytes > static_cast<size_t>(std::numeric_limits<jsize>::max())) throw std::bad_alloc();
        auto result = env->NewByteArray(static_cast<jsize>(blob.value.size_bytes));
        if (!result) return nullptr;
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(blob.value.size_bytes),
            static_cast<const jbyte*>(blob.value.data));
        return env->ExceptionCheck() ? nullptr : result;
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for LUT compatibility");
    } catch (const std::exception& error) { throwJava(env, "java/io/IOException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeLookBridge_compare(JNIEnv* env, jclass, jbyteArray candidate, jint width, jint height,
    jbyteArray reference, jint referenceWidth, jint referenceHeight, jstring conditions) {
    try {
        if (!candidate || !reference || !conditions || width < 1 || height < 1 || width > 1024 || height > 1024 ||
            referenceWidth < 1 || referenceHeight < 1 || referenceWidth > 1024 || referenceHeight > 1024) {
            throw std::invalid_argument("Invalid preview dimensions");
        }
        ByteArrayElements a(env, candidate), b(env, reference);
        UtfChars text(env, conditions);
        sony2fuji_buffer left{a.bytes, static_cast<size_t>(env->GetArrayLength(candidate)),
            static_cast<uint32_t>(width), static_cast<uint32_t>(height),
            static_cast<uint32_t>(width * 4), SONY2FUJI_PIXEL_RGBA8};
        sony2fuji_buffer right{b.bytes, static_cast<size_t>(env->GetArrayLength(reference)),
            static_cast<uint32_t>(referenceWidth), static_cast<uint32_t>(referenceHeight),
            static_cast<uint32_t>(referenceWidth * 4), SONY2FUJI_PIXEL_RGBA8};
        DcpBlob report;
        check(sony2fuji_compare_lut_previews(&left, &right, text.chars, &report.value));
        auto bytes = env->NewByteArray(static_cast<jsize>(report.value.size_bytes));
        if (!bytes) return nullptr;
        env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(report.value.size_bytes),
            static_cast<const jbyte*>(report.value.data));
        return bytes;
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for comparison");
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_engine_NativeDcpBridge_compile(JNIEnv* env, jclass, jbyteArray source,
    jbyteArray sourceNameUtf8, jbyteArray toneCurve, jboolean omitAutomaticBlack) {
    DcpBlob blob;
    try {
        if (!source || !sourceNameUtf8) throw std::invalid_argument("Missing DCP source");
        ByteArrayElements bytes(env, source), sourceName(env, sourceNameUtf8);
        const auto sourceNameLength = env->GetArrayLength(sourceNameUtf8);
        if (sourceNameLength <= 0) throw std::invalid_argument("Missing DCP source filename");
        const std::string name(reinterpret_cast<const char*>(sourceName.bytes), static_cast<size_t>(sourceNameLength));
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
    } catch (const std::bad_alloc&) { throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory to compile DCP");
    } catch (const std::exception& error) { throwJava(env, "java/lang/IllegalArgumentException", error.what()); }
    return nullptr;
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_engine_ToneCurveSampling_nativeSamples(
    JNIEnv* env, jclass, jdoubleArray points, jdoubleArray parametric, jint count) {
    try {
        if (count < 2 || count > 4097) throw std::invalid_argument("Invalid curve sample count");
        const auto config = curveConfig(env, SONY2FUJI_CURVE_CUSTOM, points);
        sony2fuji_tone_curve_parametric_config paramCfg{};
        const sony2fuji_tone_curve_parametric_config* paramPtr = nullptr;
        if (parametric) {
            paramCfg = readParametricArray(env, parametric);
            paramPtr = &paramCfg;
        }
        std::vector<double> values(static_cast<size_t>(count));
        for (jint i = 0; i < count; ++i) values[i] = double(i) / (count - 1);
        check(sony2fuji_sample_tone_curve_v2(&config, paramPtr, values.data(), values.data(), static_cast<uint32_t>(count)));
        auto result = env->NewDoubleArray(count);
        if (result) env->SetDoubleArrayRegion(result, 0, count, values.data());
        return result;
    } catch (const std::exception& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
        return nullptr;
    }
}

extern "C" JNIEXPORT jdouble JNICALL
Java_com_rawlab_android_engine_ToneCurveSampling_nativeSampleParametricValue(
    JNIEnv* env, jclass, jdoubleArray parametric, jdouble x) {
    try {
        const auto paramCfg = readParametricArray(env, parametric);
        const sony2fuji_tone_curve_config identityConfig{
            SONY2FUJI_TONE_CURVE_CONFIG_VERSION, sizeof(sony2fuji_tone_curve_config),
            SONY2FUJI_CURVE_CUSTOM, 2, {{0.0, 0.0}, {1.0, 1.0}}};
        double input = static_cast<double>(x);
        double output = input;
        check(sony2fuji_sample_tone_curve_v2(&identityConfig, &paramCfg, &input, &output, 1));
        return static_cast<jdouble>(output);
    } catch (const std::exception& error) {
        throwJava(env, "java/lang/IllegalArgumentException", error.what());
        return x;
    }
}
