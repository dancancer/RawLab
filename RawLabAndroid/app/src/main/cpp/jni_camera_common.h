// 相机 JNI 两个编译单元（协议、对焦/实时取景）共用的字节序列化与 JNI 读写辅助函数。
#pragma once

#include <jni.h>

#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace rawlab_camera_jni {


inline void throwIOException(JNIEnv* env, const char* message) {
    jclass exClass = env->FindClass("java/io/IOException");
    if (exClass != nullptr) {
        env->ThrowNew(exClass, message ? message : "Sony PTP/IP error");
        env->DeleteLocalRef(exClass);
    }
}

inline void appendU16LE(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
}

inline void appendU32LE(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xffu));
}

inline void appendU64LE(std::vector<uint8_t>& out, uint64_t v) {
    appendU32LE(out, static_cast<uint32_t>(v & 0xffffffffu));
    appendU32LE(out, static_cast<uint32_t>((v >> 32) & 0xffffffffu));
}

inline void appendI64LE(std::vector<uint8_t>& out, int64_t v) {
    uint64_t raw = 0;
    std::memcpy(&raw, &v, sizeof(raw));
    appendU64LE(out, raw);
}

inline void appendLenStr(std::vector<uint8_t>& out, const char* str) {
    const std::string s = str ? str : "";
    appendU32LE(out, static_cast<uint32_t>(s.size()));
    out.insert(out.end(), s.begin(), s.end());
}

inline jbyteArray toJByteArray(JNIEnv* env, const uint8_t* data, size_t len) {
    if (len > static_cast<size_t>(std::numeric_limits<jsize>::max())) {
        throwIOException(env, "Byte array exceeds JNI limit");
        return nullptr;
    }
    jbyteArray arr = env->NewByteArray(static_cast<jsize>(len));
    if (!arr) return nullptr;
    if (len > 0 && data) {
        env->SetByteArrayRegion(arr, 0, static_cast<jsize>(len), reinterpret_cast<const jbyte*>(data));
    }
    return arr;
}

inline bool readByteArray(JNIEnv* env, jbyteArray arr, std::vector<uint8_t>& out) {
    if (!arr) return false;
    const jsize len = env->GetArrayLength(arr);
    out.resize(static_cast<size_t>(len));
    if (len > 0) {
        env->GetByteArrayRegion(arr, 0, len, reinterpret_cast<jbyte*>(out.data()));
    }
    return !env->ExceptionCheck();
}

inline std::string readJString(JNIEnv* env, jstring s) {
    if (!s) return {};
    const char* utf = env->GetStringUTFChars(s, nullptr);
    if (!utf) return {};
    std::string out(utf);
    env->ReleaseStringUTFChars(s, utf);
    return out;
}

inline sony2fuji_sony_property_info makePropertyInfo(
    jint code, jint type, jboolean writable, jint enabled, jint form,
    jboolean hasRange, jlong minVal, jlong maxVal, jlong step, jlongArray choicesArr,
    JNIEnv* env, std::vector<int64_t>& outChoices
) {
    outChoices.clear();
    if (choicesArr) {
        const jsize n = env->GetArrayLength(choicesArr);
        if (n > 0) {
            std::vector<jlong> tmp(static_cast<size_t>(n));
            env->GetLongArrayRegion(choicesArr, 0, n, tmp.data());
            outChoices.reserve(static_cast<size_t>(n));
            for (jlong v : tmp) outChoices.push_back(static_cast<int64_t>(v));
        }
    }
    sony2fuji_sony_property_info info{};
    info.code = static_cast<uint16_t>(code & 0xffff);
    info.type = static_cast<uint16_t>(type & 0xffff);
    info.writable = writable ? 1 : 0;
    info.enabled = static_cast<uint8_t>(enabled & 0xff);
    info.form = static_cast<uint8_t>(form & 0xff);
    info.value_kind = SONY2FUJI_SONY_PROP_NUMBER;
    info.has_range = hasRange ? 1 : 0;
    info.choice_count = static_cast<uint32_t>(outChoices.size());
    info.minimum = static_cast<int64_t>(minVal);
    info.maximum = static_cast<int64_t>(maxVal);
    info.step = static_cast<int64_t>(step);
    return info;
}

inline bool readFocusState(JNIEnv* env, jbyteArray arr, sony2fuji_sony_focus_state& out) {
    if (!arr || env->GetArrayLength(arr) != static_cast<jsize>(sizeof(sony2fuji_sony_focus_state))) {
        throwIOException(env, "Invalid focus state byte array");
        return false;
    }
    env->GetByteArrayRegion(arr, 0, static_cast<jsize>(sizeof(sony2fuji_sony_focus_state)),
                            reinterpret_cast<jbyte*>(&out));
    return !env->ExceptionCheck();
}

inline void writeFocusState(JNIEnv* env, jbyteArray arr, const sony2fuji_sony_focus_state& st) {
    env->SetByteArrayRegion(arr, 0, static_cast<jsize>(sizeof(sony2fuji_sony_focus_state)),
                            reinterpret_cast<const jbyte*>(&st));
}

inline std::vector<uint16_t> readU16IntArray(JNIEnv* env, jintArray arr) {
    std::vector<uint16_t> out;
    if (!arr) return out;
    const jsize n = env->GetArrayLength(arr);
    if (n <= 0) return out;
    std::vector<jint> tmp(static_cast<size_t>(n));
    env->GetIntArrayRegion(arr, 0, n, tmp.data());
    out.reserve(static_cast<size_t>(n));
    for (jint v : tmp) out.push_back(static_cast<uint16_t>(v & 0xffff));
    return out;
}

} // namespace rawlab_camera_jni
