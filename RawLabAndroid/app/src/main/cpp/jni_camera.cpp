#include <jni.h>

#include "sony2fuji/ffi/sony2fuji_c.h"

#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {

void throwIOException(JNIEnv* env, const char* message) {
    jclass exClass = env->FindClass("java/io/IOException");
    if (exClass != nullptr) {
        env->ThrowNew(exClass, message ? message : "Sony PTP/IP error");
        env->DeleteLocalRef(exClass);
    }
}

void appendU16LE(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
}

void appendU32LE(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xffu));
}

void appendU64LE(std::vector<uint8_t>& out, uint64_t v) {
    appendU32LE(out, static_cast<uint32_t>(v & 0xffffffffu));
    appendU32LE(out, static_cast<uint32_t>((v >> 32) & 0xffffffffu));
}

void appendI64LE(std::vector<uint8_t>& out, int64_t v) {
    uint64_t raw = 0;
    std::memcpy(&raw, &v, sizeof(raw));
    appendU64LE(out, raw);
}

void appendLenStr(std::vector<uint8_t>& out, const char* str) {
    const std::string s = str ? str : "";
    appendU32LE(out, static_cast<uint32_t>(s.size()));
    out.insert(out.end(), s.begin(), s.end());
}

jbyteArray toJByteArray(JNIEnv* env, const uint8_t* data, size_t len) {
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

bool readByteArray(JNIEnv* env, jbyteArray arr, std::vector<uint8_t>& out) {
    if (!arr) return false;
    const jsize len = env->GetArrayLength(arr);
    out.resize(static_cast<size_t>(len));
    if (len > 0) {
        env->GetByteArrayRegion(arr, 0, len, reinterpret_cast<jbyte*>(out.data()));
    }
    return !env->ExceptionCheck();
}

std::string readJString(JNIEnv* env, jstring s) {
    if (!s) return {};
    const char* utf = env->GetStringUTFChars(s, nullptr);
    if (!utf) return {};
    std::string out(utf);
    env->ReleaseStringUTFChars(s, utf);
    return out;
}

sony2fuji_sony_property_info makePropertyInfo(
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

bool readFocusState(JNIEnv* env, jbyteArray arr, sony2fuji_sony_focus_state& out) {
    if (!arr || env->GetArrayLength(arr) != static_cast<jsize>(sizeof(sony2fuji_sony_focus_state))) {
        throwIOException(env, "Invalid focus state byte array");
        return false;
    }
    env->GetByteArrayRegion(arr, 0, static_cast<jsize>(sizeof(sony2fuji_sony_focus_state)),
                            reinterpret_cast<jbyte*>(&out));
    return !env->ExceptionCheck();
}

void writeFocusState(JNIEnv* env, jbyteArray arr, const sony2fuji_sony_focus_state& st) {
    env->SetByteArrayRegion(arr, 0, static_cast<jsize>(sizeof(sony2fuji_sony_focus_state)),
                            reinterpret_cast<const jbyte*>(&st));
}

std::vector<uint16_t> readU16IntArray(JNIEnv* env, jintArray arr) {
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

} // namespace

extern "C" {

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeInitCmdPacket(
    JNIEnv* env, jobject, jbyteArray guid16Arr, jstring clientNameStr, jint protocolVersion
) {
    std::vector<uint8_t> guid;
    if (!readByteArray(env, guid16Arr, guid) || guid.size() != 16) {
        throwIOException(env, "PTP/IP init command requires 16-byte GUID");
        return nullptr;
    }
    const std::string clientName = readJString(env, clientNameStr);
    size_t len = 0;
    if (sony2fuji_sony_ptpip_build_init_cmd(guid.data(), clientName.c_str(),
            static_cast<uint32_t>(protocolVersion), nullptr, 0, &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP init command");
        return nullptr;
    }
    std::vector<uint8_t> out(len);
    if (sony2fuji_sony_ptpip_build_init_cmd(guid.data(), clientName.c_str(),
            static_cast<uint32_t>(protocolVersion), out.data(), out.size(), &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP init command");
        return nullptr;
    }
    return toJByteArray(env, out.data(), len);
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeInitEvtPacket(
    JNIEnv* env, jobject, jint connectionNumber
) {
    size_t len = 0;
    sony2fuji_sony_ptpip_build_init_evt(static_cast<uint32_t>(connectionNumber), nullptr, 0, &len);
    std::vector<uint8_t> out(len);
    if (sony2fuji_sony_ptpip_build_init_evt(static_cast<uint32_t>(connectionNumber),
            out.data(), out.size(), &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP init event");
        return nullptr;
    }
    return toJByteArray(env, out.data(), len);
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeOpReqPacket(
    JNIEnv* env, jobject, jint dataPhase, jint opCode, jint transactionId, jintArray paramsArr
) {
    std::vector<uint32_t> params;
    if (paramsArr) {
        const jsize n = env->GetArrayLength(paramsArr);
        if (n > 0) {
            std::vector<jint> tmp(static_cast<size_t>(n));
            env->GetIntArrayRegion(paramsArr, 0, n, tmp.data());
            for (jint p : tmp) params.push_back(static_cast<uint32_t>(p));
        }
    }
    size_t len = 0;
    if (sony2fuji_sony_ptpip_build_op_req(
            static_cast<uint32_t>(dataPhase),
            static_cast<uint16_t>(opCode & 0xffff),
            static_cast<uint32_t>(transactionId),
            params.empty() ? nullptr : params.data(),
            static_cast<uint32_t>(params.size()),
            nullptr, 0, &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP op request");
        return nullptr;
    }
    std::vector<uint8_t> out(len);
    if (sony2fuji_sony_ptpip_build_op_req(
            static_cast<uint32_t>(dataPhase),
            static_cast<uint16_t>(opCode & 0xffff),
            static_cast<uint32_t>(transactionId),
            params.empty() ? nullptr : params.data(),
            static_cast<uint32_t>(params.size()),
            out.data(), out.size(), &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP op request");
        return nullptr;
    }
    return toJByteArray(env, out.data(), len);
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeStartDataPacket(
    JNIEnv* env, jobject, jint transactionId, jlong totalBytes
) {
    if (totalBytes < 0) {
        throwIOException(env, "Negative PTP/IP start data length");
        return nullptr;
    }
    size_t len = 0;
    sony2fuji_sony_ptpip_build_start_data(static_cast<uint32_t>(transactionId),
        static_cast<uint64_t>(totalBytes), nullptr, 0, &len);
    std::vector<uint8_t> out(len);
    if (sony2fuji_sony_ptpip_build_start_data(static_cast<uint32_t>(transactionId),
            static_cast<uint64_t>(totalBytes), out.data(), out.size(), &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP start data");
        return nullptr;
    }
    return toJByteArray(env, out.data(), len);
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeEndDataPacket(
    JNIEnv* env, jobject, jint transactionId, jbyteArray payloadArr
) {
    std::vector<uint8_t> payload;
    if (payloadArr && !readByteArray(env, payloadArr, payload)) {
        return nullptr;
    }
    size_t len = 0;
    if (sony2fuji_sony_ptpip_build_end_data(static_cast<uint32_t>(transactionId),
            payload.empty() ? nullptr : payload.data(), payload.size(), nullptr, 0, &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP end data");
        return nullptr;
    }
    std::vector<uint8_t> out(len);
    if (sony2fuji_sony_ptpip_build_end_data(static_cast<uint32_t>(transactionId),
            payload.empty() ? nullptr : payload.data(), payload.size(), out.data(), out.size(), &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP end data");
        return nullptr;
    }
    return toJByteArray(env, out.data(), len);
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeProbeRespPacket(JNIEnv* env, jobject) {
    size_t len = 0;
    sony2fuji_sony_ptpip_build_probe_resp(nullptr, 0, &len);
    std::vector<uint8_t> out(len);
    if (sony2fuji_sony_ptpip_build_probe_resp(out.data(), out.size(), &len) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Failed to build PTP/IP probe response");
        return nullptr;
    }
    return toJByteArray(env, out.data(), len);
}

JNIEXPORT jlongArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseHeader(
    JNIEnv* env, jobject, jbyteArray headerArr, jlong maxPayloadBytes
) {
    std::vector<uint8_t> headerBytes;
    if (!readByteArray(env, headerArr, headerBytes) || maxPayloadBytes < 0) {
        throwIOException(env, "Invalid PTP/IP packet header");
        return nullptr;
    }
    sony2fuji_sony_ptpip_header hdr{};
    if (sony2fuji_sony_ptpip_parse_header(headerBytes.data(), headerBytes.size(),
            static_cast<uint64_t>(maxPayloadBytes), &hdr) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Invalid PTP/IP packet length");
        return nullptr;
    }
    jlong values[2]{static_cast<jlong>(hdr.packet_type), static_cast<jlong>(hdr.payload_size)};
    jlongArray res = env->NewLongArray(2);
    if (res) env->SetLongArrayRegion(res, 0, 2, values);
    return res;
}

JNIEXPORT jint JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseInitCmdAck(
    JNIEnv* env, jobject, jbyteArray payloadArr
) {
    std::vector<uint8_t> payload;
    if (!readByteArray(env, payloadArr, payload)) {
        throwIOException(env, "Invalid PTP/IP command ack");
        return 0;
    }
    uint32_t conn = 0;
    if (sony2fuji_sony_ptpip_parse_init_cmd_ack(payload.data(), payload.size(), &conn) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "PTP/IP command init rejected");
        return 0;
    }
    return static_cast<jint>(conn);
}

JNIEXPORT jlongArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseStartData(
    JNIEnv* env, jobject, jbyteArray payloadArr
) {
    std::vector<uint8_t> payload;
    if (!readByteArray(env, payloadArr, payload)) {
        throwIOException(env, "Invalid PTP/IP start data");
        return nullptr;
    }
    sony2fuji_sony_ptpip_start_data start{};
    if (sony2fuji_sony_ptpip_parse_start_data(payload.data(), payload.size(), &start) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Invalid PTP/IP start data");
        return nullptr;
    }
    jlong values[2]{static_cast<jlong>(static_cast<int32_t>(start.transaction_id)),
                    static_cast<jlong>(start.total_bytes)};
    jlongArray res = env->NewLongArray(2);
    if (res) env->SetLongArrayRegion(res, 0, 2, values);
    return res;
}

JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseResponse(
    JNIEnv* env, jobject, jbyteArray payloadArr
) {
    std::vector<uint8_t> payload;
    if (!readByteArray(env, payloadArr, payload)) {
        throwIOException(env, "Invalid PTP/IP response");
        return nullptr;
    }
    sony2fuji_sony_ptpip_response resp{};
    if (sony2fuji_sony_ptpip_parse_response(payload.data(), payload.size(), &resp) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Invalid PTP/IP response");
        return nullptr;
    }
    jint values[8]{
        static_cast<jint>(resp.response_code),
        static_cast<jint>(resp.transaction_id),
        static_cast<jint>(resp.param_count),
        static_cast<jint>(resp.params[0]),
        static_cast<jint>(resp.params[1]),
        static_cast<jint>(resp.params[2]),
        static_cast<jint>(resp.params[3]),
        static_cast<jint>(resp.params[4]),
    };
    jintArray res = env->NewIntArray(8);
    if (res) env->SetIntArrayRegion(res, 0, 8, values);
    return res;
}

JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseEvent(
    JNIEnv* env, jobject, jbyteArray payloadArr
) {
    std::vector<uint8_t> payload;
    if (!readByteArray(env, payloadArr, payload)) {
        throwIOException(env, "Invalid PTP/IP event");
        return nullptr;
    }
    sony2fuji_sony_ptpip_event evt{};
    if (sony2fuji_sony_ptpip_parse_event(payload.data(), payload.size(), &evt) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Invalid PTP/IP event");
        return nullptr;
    }
    jint values[6]{
        static_cast<jint>(evt.event_code),
        static_cast<jint>(evt.transaction_id),
        static_cast<jint>(evt.param_count),
        static_cast<jint>(evt.params[0]),
        static_cast<jint>(evt.params[1]),
        static_cast<jint>(evt.params[2]),
    };
    jintArray res = env->NewIntArray(6);
    if (res) env->SetIntArrayRegion(res, 0, 6, values);
    return res;
}

JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeIsValidPhotoFilename(
    JNIEnv* env, jobject, jstring nameStr
) {
    const std::string name = readJString(env, nameStr);
    return sony2fuji_sony_is_valid_photo_filename(name.c_str()) != 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeIsPhotoFilename(
    JNIEnv* env, jobject, jstring nameStr
) {
    const std::string name = readJString(env, nameStr);
    return sony2fuji_sony_is_photo_filename(name.c_str()) != 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeValidatePhotoHeader(
    JNIEnv* env, jobject, jstring nameStr, jbyteArray prefixArr
) {
    std::vector<uint8_t> prefix;
    if (!readByteArray(env, prefixArr, prefix)) return JNI_FALSE;
    const std::string name = readJString(env, nameStr);
    return sony2fuji_sony_validate_photo_header(name.c_str(), prefix.data(), prefix.size()) != 0
               ? JNI_TRUE
               : JNI_FALSE;
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseDeviceInfo(
    JNIEnv* env, jobject, jbyteArray dataArr
) {
    std::vector<uint8_t> data;
    if (!readByteArray(env, dataArr, data)) {
        throwIOException(env, "Truncated device info");
        return nullptr;
    }
    sony2fuji_sony_device_info* info = nullptr;
    const sony2fuji_status st = sony2fuji_sony_parse_device_info(data.data(), data.size(), &info);
    if (st == SONY2FUJI_STATUS_UNSUPPORTED) {
        std::vector<uint8_t> out;
        appendU32LE(out, static_cast<uint32_t>(st));
        return toJByteArray(env, out.data(), out.size());
    }
    if (st != SONY2FUJI_STATUS_OK || !info) {
        throwIOException(env, "Invalid Sony device info");
        return nullptr;
    }
    uint32_t opCount = 0;
    sony2fuji_sony_device_info_operations(info, nullptr, 0, &opCount);
    std::vector<uint16_t> ops(opCount);
    if (opCount > 0) {
        sony2fuji_sony_device_info_operations(info, ops.data(), opCount, &opCount);
    }
    std::vector<uint8_t> out;
    appendU32LE(out, static_cast<uint32_t>(SONY2FUJI_STATUS_OK));
    appendLenStr(out, sony2fuji_sony_device_info_manufacturer(info));
    appendLenStr(out, sony2fuji_sony_device_info_model(info));
    appendLenStr(out, sony2fuji_sony_device_info_firmware(info));
    appendLenStr(out, sony2fuji_sony_device_info_serial(info));
    appendU32LE(out, opCount);
    for (uint32_t i = 0; i < opCount; ++i) {
        appendU16LE(out, ops[i]);
    }
    sony2fuji_sony_device_info_free(info);
    return toJByteArray(env, out.data(), out.size());
}

JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseRemoteDescriptor(
    JNIEnv* env, jobject, jbyteArray dataArr
) {
    std::vector<uint8_t> data;
    if (!readByteArray(env, dataArr, data)) {
        throwIOException(env, "Invalid remote descriptor");
        return nullptr;
    }
    uint16_t version = 0;
    int32_t enumTables = 1;
    sony2fuji_sony_remote_descriptor* desc = nullptr;
    const sony2fuji_status st = sony2fuji_sony_parse_remote_descriptor(
        data.data(), data.size(), &version, &enumTables, &desc);
    if (st == SONY2FUJI_STATUS_UNSUPPORTED) {
        jint values[5]{static_cast<jint>(st), static_cast<jint>(version), enumTables, 0, 0};
        jintArray res = env->NewIntArray(5);
        if (res) env->SetIntArrayRegion(res, 0, 5, values);
        return res;
    }
    if (st != SONY2FUJI_STATUS_OK || !desc) {
        throwIOException(env, "Invalid remote descriptor");
        return nullptr;
    }
    uint32_t propCount = 0;
    uint32_t ctrlCount = 0;
    sony2fuji_sony_remote_descriptor_properties(desc, nullptr, 0, &propCount);
    sony2fuji_sony_remote_descriptor_controls(desc, nullptr, 0, &ctrlCount);
    std::vector<uint16_t> props(propCount);
    std::vector<uint16_t> ctrls(ctrlCount);
    if (propCount > 0) sony2fuji_sony_remote_descriptor_properties(desc, props.data(), propCount, &propCount);
    if (ctrlCount > 0) sony2fuji_sony_remote_descriptor_controls(desc, ctrls.data(), ctrlCount, &ctrlCount);
    sony2fuji_sony_remote_descriptor_free(desc);

    std::vector<jint> values;
    values.reserve(5 + propCount + ctrlCount);
    values.push_back(static_cast<jint>(SONY2FUJI_STATUS_OK));
    values.push_back(static_cast<jint>(version));
    values.push_back(static_cast<jint>(enumTables));
    values.push_back(static_cast<jint>(propCount));
    values.push_back(static_cast<jint>(ctrlCount));
    for (uint16_t p : props) values.push_back(static_cast<jint>(p));
    for (uint16_t c : ctrls) values.push_back(static_cast<jint>(c));

    jintArray res = env->NewIntArray(static_cast<jsize>(values.size()));
    if (res) env->SetIntArrayRegion(res, 0, static_cast<jsize>(values.size()), values.data());
    return res;
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseProperties(
    JNIEnv* env, jobject, jbyteArray dataArr, jint enumTables
) {
    std::vector<uint8_t> data;
    if (!readByteArray(env, dataArr, data)) {
        throwIOException(env, "Invalid properties payload");
        return nullptr;
    }
    sony2fuji_sony_property_table* table = nullptr;
    if (sony2fuji_sony_parse_properties(data.data(), data.size(), static_cast<int32_t>(enumTables), &table) !=
            SONY2FUJI_STATUS_OK ||
        !table) {
        throwIOException(env, "Invalid Sony properties");
        return nullptr;
    }
    const uint32_t count = sony2fuji_sony_property_table_count(table);
    std::vector<uint8_t> out;
    appendU32LE(out, count);
    std::vector<int64_t> choices;
    for (uint32_t i = 0; i < count; ++i) {
        sony2fuji_sony_property_info info{};
        sony2fuji_sony_property_table_get_at(table, i, &info);
        appendU16LE(out, info.code);
        appendU16LE(out, info.type);
        out.push_back(info.writable != 0 ? 1u : 0u);
        out.push_back(info.enabled);
        out.push_back(info.form);
        out.push_back(static_cast<uint8_t>(info.value_kind));
        appendI64LE(out, info.number_value);
        if (info.value_kind == SONY2FUJI_SONY_PROP_TEXT) {
            appendLenStr(out, sony2fuji_sony_property_table_text_at(table, i));
        } else {
            appendU32LE(out, 0u);
        }
        out.push_back(info.has_range != 0 ? 1u : 0u);
        appendI64LE(out, info.minimum);
        appendI64LE(out, info.maximum);
        appendI64LE(out, info.step);
        uint32_t cCount = info.choice_count;
        choices.resize(cCount);
        if (cCount > 0) {
            sony2fuji_sony_property_table_choices_at(table, i, choices.data(), cCount, &cCount);
        }
        appendU32LE(out, cCount);
        for (uint32_t c = 0; c < cCount; ++c) {
            appendI64LE(out, choices[c]);
        }
    }
    sony2fuji_sony_property_table_free(table);
    return toJByteArray(env, out.data(), out.size());
}

JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativePropertyCanSet(
    JNIEnv* env, jobject, jint code, jint type, jboolean writable, jint enabled, jint form,
    jboolean hasRange, jlong minVal, jlong maxVal, jlong step, jlongArray choicesArr, jlong requested
) {
    std::vector<int64_t> choices;
    const sony2fuji_sony_property_info info = makePropertyInfo(
        code, type, writable, enabled, form, hasRange, minVal, maxVal, step, choicesArr, env, choices);
    return sony2fuji_sony_property_accepts(
               &info, choices.empty() ? nullptr : choices.data(), static_cast<uint32_t>(choices.size()),
               static_cast<int64_t>(requested)) != 0
               ? JNI_TRUE
               : JNI_FALSE;
}

JNIEXPORT jlongArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativePropertyOptions(
    JNIEnv* env, jobject, jint code, jint type, jboolean writable, jint enabled, jint form,
    jboolean hasRange, jlong minVal, jlong maxVal, jlong step, jlongArray choicesArr,
    jboolean onlySettable, jboolean sortUnique, jint maxRangeCount
) {
    std::vector<int64_t> choices;
    const sony2fuji_sony_property_info info = makePropertyInfo(
        code, type, writable, enabled, form, hasRange, minVal, maxVal, step, choicesArr, env, choices);
    uint32_t outCount = 0;
    if (sony2fuji_sony_property_options(
            &info, choices.empty() ? nullptr : choices.data(), static_cast<uint32_t>(choices.size()),
            onlySettable ? 1 : 0, sortUnique ? 1 : 0, static_cast<uint32_t>(maxRangeCount),
            nullptr, 0, &outCount) != SONY2FUJI_STATUS_OK) {
        return env->NewLongArray(0);
    }
    std::vector<int64_t> values(outCount);
    if (outCount > 0) {
        sony2fuji_sony_property_options(
            &info, choices.empty() ? nullptr : choices.data(), static_cast<uint32_t>(choices.size()),
            onlySettable ? 1 : 0, sortUnique ? 1 : 0, static_cast<uint32_t>(maxRangeCount),
            values.data(), outCount, &outCount);
    }
    jlongArray res = env->NewLongArray(static_cast<jsize>(outCount));
    if (res && outCount > 0) {
        std::vector<jlong> jvals(outCount);
        for (uint32_t i = 0; i < outCount; ++i) jvals[i] = static_cast<jlong>(values[i]);
        env->SetLongArrayRegion(res, 0, static_cast<jsize>(outCount), jvals.data());
    }
    return res;
}

JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusIndication(
    JNIEnv* env, jobject, jbyteArray propTableBytes
) {
    std::vector<uint8_t> data;
    sony2fuji_sony_property_table* table = nullptr;
    if (readByteArray(env, propTableBytes, data) && !data.empty()) {
        sony2fuji_sony_parse_properties(data.data(), data.size(), 2, &table);
    }
    int32_t locked = 0;
    int32_t failed = 0;
    sony2fuji_sony_property_table_focus_indication(table, &locked, &failed);
    sony2fuji_sony_property_table_free(table);
    jint out[2]{locked, failed};
    jintArray res = env->NewIntArray(2);
    if (res) env->SetIntArrayRegion(res, 0, 2, out);
    return res;
}

JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeCanCancelTouchFocus(
    JNIEnv* env, jobject, jbyteArray propTableBytes, jintArray controlsArr, jintArray opsArr, jboolean remoteReady
) {
    std::vector<uint8_t> data;
    sony2fuji_sony_property_table* table = nullptr;
    if (readByteArray(env, propTableBytes, data) && !data.empty()) {
        sony2fuji_sony_parse_properties(data.data(), data.size(), 2, &table);
    }
    const auto controls = readU16IntArray(env, controlsArr);
    const auto ops = readU16IntArray(env, opsArr);
    const int32_t ok = sony2fuji_sony_property_table_can_cancel_touch_focus(
        table,
        controls.empty() ? nullptr : controls.data(),
        static_cast<uint32_t>(controls.size()),
        ops.empty() ? nullptr : ops.data(),
        static_cast<uint32_t>(ops.size()),
        remoteReady ? 1 : 0);
    sony2fuji_sony_property_table_free(table);
    return ok != 0 ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeResolveFocusTarget(
    JNIEnv* env, jobject, jbyteArray propTableBytes, jintArray controlsArr, jintArray opsArr, jboolean remoteReady
) {
    std::vector<uint8_t> data;
    sony2fuji_sony_property_table* table = nullptr;
    if (readByteArray(env, propTableBytes, data) && !data.empty()) {
        sony2fuji_sony_parse_properties(data.data(), data.size(), 2, &table);
    }
    const auto controls = readU16IntArray(env, controlsArr);
    const auto ops = readU16IntArray(env, opsArr);
    sony2fuji_sony_focus_target target = SONY2FUJI_SONY_FOCUS_TARGET_NONE;
    sony2fuji_sony_focus_unavailable_reason reason = SONY2FUJI_SONY_FOCUS_UNAVAILABLE_UNSUPPORTED;
    sony2fuji_sony_property_table_resolve_focus_target(
        table,
        controls.empty() ? nullptr : controls.data(),
        static_cast<uint32_t>(controls.size()),
        ops.empty() ? nullptr : ops.data(),
        static_cast<uint32_t>(ops.size()),
        remoteReady ? 1 : 0,
        &target,
        &reason);
    sony2fuji_sony_property_table_free(table);
    jint out[2]{static_cast<jint>(target), static_cast<jint>(reason)};
    jintArray res = env->NewIntArray(2);
    if (res) env->SetIntArrayRegion(res, 0, 2, out);
    return res;
}

JNIEXPORT jlong JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseSlotPhotoCount(
    JNIEnv* env, jobject, jbyteArray dataArr
) {
    std::vector<uint8_t> data;
    if (!readByteArray(env, dataArr, data)) {
        throwIOException(env, "Invalid slot photo count");
        return 0;
    }
    uint32_t count = 0;
    if (sony2fuji_sony_parse_slot_photo_count(data.data(), data.size(), &count) != SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Slot date list exceeds 256 KiB budget");
        return 0;
    }
    return static_cast<jlong>(count);
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseMobilePage(
    JNIEnv* env, jobject, jbyteArray dataArr
) {
    std::vector<uint8_t> data;
    if (!readByteArray(env, dataArr, data)) {
        throwIOException(env, "Invalid mobile contents page");
        return nullptr;
    }
    sony2fuji_sony_mobile_page* page = nullptr;
    if (sony2fuji_sony_parse_mobile_page(data.data(), data.size(), &page) != SONY2FUJI_STATUS_OK || !page) {
        throwIOException(env, "Invalid mobile contents page");
        return nullptr;
    }
    const uint32_t entryCount = sony2fuji_sony_mobile_page_entry_count(page);
    const uint64_t cursor = sony2fuji_sony_mobile_page_cursor(page);
    const uint32_t assetCount = sony2fuji_sony_mobile_page_asset_count(page);
    std::vector<uint8_t> out;
    appendU32LE(out, entryCount);
    appendU64LE(out, cursor);
    appendU32LE(out, assetCount);
    for (uint32_t i = 0; i < assetCount; ++i) {
        sony2fuji_sony_mobile_asset_info info{};
        const char* name = nullptr;
        sony2fuji_sony_mobile_page_asset_at(page, i, &info, &name);
        appendU32LE(out, info.content);
        appendU32LE(out, info.file);
        appendU64LE(out, info.size);
        appendU64LE(out, info.created);
        appendLenStr(out, name);
    }
    sony2fuji_sony_mobile_page_free(page);
    return toJByteArray(env, out.data(), out.size());
}

JNIEXPORT jbyteArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseLegacyObject(
    JNIEnv* env, jobject, jbyteArray dataArr
) {
    std::vector<uint8_t> data;
    if (!readByteArray(env, dataArr, data)) {
        throwIOException(env, "Invalid legacy object metadata");
        return nullptr;
    }
    sony2fuji_sony_legacy_object* obj = nullptr;
    if (sony2fuji_sony_parse_legacy_object(data.data(), data.size(), &obj) != SONY2FUJI_STATUS_OK || !obj) {
        throwIOException(env, "Invalid legacy object metadata");
        return nullptr;
    }
    sony2fuji_sony_legacy_object_info info{};
    const char* name = nullptr;
    const char* created = nullptr;
    const char* modified = nullptr;
    sony2fuji_sony_legacy_object_get(obj, &info, &name, &created, &modified);
    std::vector<uint8_t> out;
    appendU32LE(out, info.storage);
    appendU16LE(out, info.format);
    appendU64LE(out, info.size);
    appendLenStr(out, name);
    appendLenStr(out, created);
    appendLenStr(out, modified);
    sony2fuji_sony_legacy_object_free(obj);
    return toJByteArray(env, out.data(), out.size());
}

JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseLiveFrameBounds(
    JNIEnv* env, jobject, jintArray fieldsArr, jlong maxTotalBytes
) {
    if (!fieldsArr || env->GetArrayLength(fieldsArr) != 4 || maxTotalBytes < 16) {
        throwIOException(env, "Invalid live frame bounds");
        return nullptr;
    }
    jint raw[4]{};
    env->GetIntArrayRegion(fieldsArr, 0, 4, raw);
    const uint32_t ufields[4]{
        static_cast<uint32_t>(raw[0]),
        static_cast<uint32_t>(raw[1]),
        static_cast<uint32_t>(raw[2]),
        static_cast<uint32_t>(raw[3]),
    };
    sony2fuji_sony_live_frame_bounds bounds{};
    if (sony2fuji_sony_parse_live_frame_bounds(ufields, static_cast<uint64_t>(maxTotalBytes), &bounds) !=
        SONY2FUJI_STATUS_OK) {
        throwIOException(env, "Invalid live frame bounds");
        return nullptr;
    }
    jint out[6]{
        static_cast<jint>(bounds.body_size),
        static_cast<jint>(bounds.image_offset),
        static_cast<jint>(bounds.image_length),
        bounds.has_metadata,
        static_cast<jint>(bounds.metadata_offset),
        static_cast<jint>(bounds.metadata_length),
    };
    jintArray res = env->NewIntArray(6);
    if (res) env->SetIntArrayRegion(res, 0, 6, out);
    return res;
}

JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeParseLiveViewFrames(
    JNIEnv* env, jobject, jbyteArray metadataArr
) {
    std::vector<uint8_t> metadata;
    if (metadataArr && !readByteArray(env, metadataArr, metadata)) {
        return env->NewDoubleArray(0);
    }
    uint32_t count = 0;
    if (sony2fuji_sony_parse_live_view_frames(metadata.data(), metadata.size(), nullptr, 0, &count) !=
            SONY2FUJI_STATUS_OK ||
        count == 0) {
        return env->NewDoubleArray(0);
    }
    std::vector<sony2fuji_sony_live_view_frame> frames(count);
    if (sony2fuji_sony_parse_live_view_frames(
            metadata.data(), metadata.size(), frames.data(), count, &count) != SONY2FUJI_STATUS_OK) {
        return env->NewDoubleArray(0);
    }
    std::vector<jdouble> out(static_cast<size_t>(count) * 6u);
    for (uint32_t i = 0; i < count; ++i) {
        const size_t base = static_cast<size_t>(i) * 6u;
        out[base + 0] = static_cast<jdouble>(frames[i].kind);
        out[base + 1] = frames[i].focused != 0 ? 1.0 : 0.0;
        out[base + 2] = frames[i].cx;
        out[base + 3] = frames[i].cy;
        out[base + 4] = frames[i].width;
        out[base + 5] = frames[i].height;
    }
    jdoubleArray res = env->NewDoubleArray(static_cast<jsize>(out.size()));
    if (res && !out.empty()) env->SetDoubleArrayRegion(res, 0, static_cast<jsize>(out.size()), out.data());
    return res;
}

JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusPointFromTap(
    JNIEnv* env, jobject, jdouble tapX, jdouble tapY, jdouble containerWidth, jdouble containerHeight,
    jdouble imageWidth, jdouble imageHeight
) {
    int32_t valid = 0;
    sony2fuji_sony_focus_tap_point tap{};
    if (sony2fuji_sony_focus_point_from_tap(
            tapX, tapY, containerWidth, containerHeight, imageWidth, imageHeight, &valid, &tap) !=
            SONY2FUJI_STATUS_OK ||
        valid == 0) {
        return nullptr;
    }
    jdouble out[5]{tap.u, tap.v, static_cast<jdouble>(tap.x), static_cast<jdouble>(tap.y),
                   static_cast<jdouble>(tap.packed)};
    jdoubleArray res = env->NewDoubleArray(5);
    if (res) env->SetDoubleArrayRegion(res, 0, 5, out);
    return res;
}

JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusOverlayBox(
    JNIEnv* env, jobject, jint kind, jboolean focused, jdouble cx, jdouble cy, jdouble width, jdouble height,
    jdouble left, jdouble top, jdouble fittedWidth, jdouble fittedHeight
) {
    sony2fuji_sony_live_view_frame frame{};
    frame.kind = static_cast<sony2fuji_sony_live_view_frame_kind>(kind);
    frame.focused = focused ? 1 : 0;
    frame.cx = cx;
    frame.cy = cy;
    frame.width = width;
    frame.height = height;
    sony2fuji_sony_focus_overlay_box box{};
    sony2fuji_sony_compute_focus_overlay_box(&frame, left, top, fittedWidth, fittedHeight, &box);
    jdouble out[6]{box.x, box.y, box.width, box.height,
                   box.is_normalized_square != 0 ? 1.0 : 0.0,
                   box.focused != 0 ? 1.0 : 0.0};
    jdoubleArray res = env->NewDoubleArray(6);
    if (res) env->SetDoubleArrayRegion(res, 0, 6, out);
    return res;
}

JNIEXPORT jdouble JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeNormalizedFocusSquareRatio(
    JNIEnv*, jobject, jint kind, jdouble width, jdouble height, jdouble imageWidth, jdouble imageHeight
) {
    sony2fuji_sony_live_view_frame frame{};
    frame.kind = static_cast<sony2fuji_sony_live_view_frame_kind>(kind);
    frame.width = width;
    frame.height = height;
    int32_t valid = 0;
    double ratio = 0.0;
    if (sony2fuji_sony_normalized_focus_square_ratio(&frame, imageWidth, imageHeight, &valid, &ratio) !=
            SONY2FUJI_STATUS_OK ||
        valid == 0) {
        return std::numeric_limits<double>::quiet_NaN();
    }
    return ratio;
}

JNIEXPORT jdouble JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeTapFocusSide(
    JNIEnv*, jobject, jdouble fittedWidth, jdouble fittedHeight, jdouble minDefaultPx,
    jdouble maxDefaultPx, jdouble minLearnedPx, jboolean hasLastRatio, jdouble lastRatio
) {
    double side = minDefaultPx;
    sony2fuji_sony_tap_focus_side(
        fittedWidth, fittedHeight, minDefaultPx, maxDefaultPx, minLearnedPx,
        hasLastRatio ? 1 : 0, lastRatio, &side);
    return side;
}

JNIEXPORT jint JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateSize(JNIEnv*, jobject) {
    return static_cast<jint>(sizeof(sony2fuji_sony_focus_state));
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateInit(JNIEnv* env, jobject, jbyteArray stateArr) {
    if (!stateArr || env->GetArrayLength(stateArr) != static_cast<jsize>(sizeof(sony2fuji_sony_focus_state))) {
        throwIOException(env, "Invalid focus state byte array");
        return;
    }
    sony2fuji_sony_focus_state st{};
    sony2fuji_sony_focus_state_init(&st);
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateReset(
    JNIEnv* env, jobject, jbyteArray stateArr, jboolean preserveLastRatio
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_reset(&st, preserveLastRatio ? 1 : 0);
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnTap(
    JNIEnv* env, jobject, jbyteArray stateArr, jdouble u, jdouble v, jint x, jint y, jlong nowMs
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_tap(&st, u, v, x, y, static_cast<uint64_t>(nowMs));
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnCancelStart(
    JNIEnv* env, jobject, jbyteArray stateArr
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_cancel_start(&st);
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnFocusFinished(
    JNIEnv* env, jobject, jbyteArray stateArr, jboolean succeeded, jboolean focusLocked, jlong nowMs
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_focus_finished(
        &st, succeeded ? 1 : 0, focusLocked ? 1 : 0, static_cast<uint64_t>(nowMs));
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnLiveFrame(
    JNIEnv* env, jobject, jbyteArray stateArr, jdoubleArray framesData, jdouble imageWidth, jdouble imageHeight
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    std::vector<sony2fuji_sony_live_view_frame> frames;
    if (framesData) {
        const jsize len = env->GetArrayLength(framesData);
        if (len >= 6 && (len % 6) == 0) {
            std::vector<jdouble> raw(static_cast<size_t>(len));
            env->GetDoubleArrayRegion(framesData, 0, len, raw.data());
            const size_t count = static_cast<size_t>(len) / 6u;
            frames.resize(count);
            for (size_t i = 0; i < count; ++i) {
                const size_t b = i * 6u;
                frames[i].kind = static_cast<sony2fuji_sony_live_view_frame_kind>(static_cast<int>(raw[b + 0]));
                frames[i].focused = raw[b + 1] != 0.0 ? 1 : 0;
                frames[i].cx = raw[b + 2];
                frames[i].cy = raw[b + 3];
                frames[i].width = raw[b + 4];
                frames[i].height = raw[b + 5];
            }
        }
    }
    sony2fuji_sony_focus_state_on_live_frame(
        &st,
        frames.empty() ? nullptr : frames.data(),
        static_cast<uint32_t>(frames.size()),
        imageWidth,
        imageHeight);
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnProperties(
    JNIEnv* env, jobject, jbyteArray stateArr, jboolean canCancelTouchFocus,
    jboolean propsFocusLocked, jboolean propsFocusFailed
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_properties(
        &st, canCancelTouchFocus ? 1 : 0, propsFocusLocked ? 1 : 0, propsFocusFailed ? 1 : 0);
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnCaptureOrParamStart(
    JNIEnv* env, jobject, jbyteArray stateArr
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_capture_or_param_start(&st);
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnLiveChanged(
    JNIEnv* env, jobject, jbyteArray stateArr, jboolean liveActive
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_live_changed(&st, liveActive ? 1 : 0);
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnTick(
    JNIEnv* env, jobject, jbyteArray stateArr, jlong nowMs
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_tick(&st, static_cast<uint64_t>(nowMs));
    writeFocusState(env, stateArr, st);
}

JNIEXPORT void JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateOnTimeout(
    JNIEnv* env, jobject, jbyteArray stateArr, jlong generation, jlong nowMs
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return;
    sony2fuji_sony_focus_state_on_timeout(
        &st, static_cast<uint64_t>(generation), static_cast<uint64_t>(nowMs));
    writeFocusState(env, stateArr, st);
}

JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateSnapshot(
    JNIEnv* env, jobject, jbyteArray stateArr
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return nullptr;
    jdouble out[15]{
        static_cast<jdouble>(st.focus_busy),
        static_cast<jdouble>(st.tap_active),
        static_cast<jdouble>(st.tap_generation),
        st.tap_u,
        st.tap_v,
        static_cast<jdouble>(st.tap_x),
        static_cast<jdouble>(st.tap_y),
        static_cast<jdouble>(st.tap_deadline_ms),
        static_cast<jdouble>(st.tap_focus_locked),
        static_cast<jdouble>(st.props_focus_locked),
        static_cast<jdouble>(st.can_cancel_touch_focus),
        static_cast<jdouble>(st.has_live_frames),
        static_cast<jdouble>(st.has_last_square_ratio),
        static_cast<jdouble>(st.has_pending_deadline),
        st.last_square_ratio,
    };
    jdoubleArray res = env->NewDoubleArray(15);
    if (res) env->SetDoubleArrayRegion(res, 0, 15, out);
    return res;
}

JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_camera_SonyCameraNative_nativeFocusStateResolveRender(
    JNIEnv* env, jobject, jbyteArray stateArr, jdouble left, jdouble top,
    jdouble fittedWidth, jdouble fittedHeight, jdouble minDefaultPx, jdouble maxDefaultPx, jdouble minLearnedPx
) {
    sony2fuji_sony_focus_state st{};
    if (!readFocusState(env, stateArr, st)) return nullptr;
    sony2fuji_sony_focus_render_decision dec{};
    sony2fuji_sony_focus_state_resolve_render(
        &st, left, top, fittedWidth, fittedHeight, minDefaultPx, maxDefaultPx, minLearnedPx, &dec);
    jdouble out[8]{
        static_cast<jdouble>(dec.mode),
        static_cast<jdouble>(dec.effective_focus_locked),
        dec.tap_box.x,
        dec.tap_box.y,
        dec.tap_box.width,
        dec.tap_box.height,
        dec.tap_box.is_normalized_square != 0 ? 1.0 : 0.0,
        dec.tap_box.focused != 0 ? 1.0 : 0.0,
    };
    jdoubleArray res = env->NewDoubleArray(8);
    if (res) env->SetDoubleArrayRegion(res, 0, 8, out);
    return res;
}

} // extern "C"
