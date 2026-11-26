// Sony PTP/IP 相机协议 JNI：建包、帧头/响应/事件解析、设备信息、属性、槽位与旧对象。
#include "jni_camera_common.h"

using namespace rawlab_camera_jni;

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

} // extern "C"
