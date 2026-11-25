// Sony 相机对焦与实时取景 JNI：对焦指示与目标、实时帧解析、点按换算和对焦状态机。
#include "jni_camera_common.h"

using namespace rawlab_camera_jni;

extern "C" {

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
