#include "jni_internal.h"

namespace {

#define GEOM_PARAMS \
    jfloat cropX, jfloat cropY, jfloat cropWidth, jfloat cropHeight, jint quarterTurns, \
    jboolean flipHorizontal, jboolean flipVertical, jfloat straightenDegrees, \
    jfloat perspectiveHorizontal, jfloat perspectiveVertical

void fillGeometryConfigs(GEOM_PARAMS, sony2fuji_geometry_config& geom, sony2fuji_perspective_config& persp) {
    geom = {SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(sony2fuji_geometry_config),
            cropX, cropY, cropWidth, cropHeight, quarterTurns,
            flipHorizontal ? 1 : 0, flipVertical ? 1 : 0, straightenDegrees};
    persp = {SONY2FUJI_PERSPECTIVE_CONFIG_VERSION, sizeof(sony2fuji_perspective_config),
             perspectiveHorizontal, perspectiveVertical};
}

sony2fuji_inspection_sample makeSampleStorage() {
    sony2fuji_inspection_sample sample{};
    sample.version = SONY2FUJI_INSPECTION_SAMPLE_VERSION;
    sample.struct_size = sizeof(sony2fuji_inspection_sample);
    return sample;
}

uint8_t clampByte(jint v) {
    return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
}

sony2fuji_buffer makeRgbaBuffer(void* data, const AndroidBitmapInfo& info, uint32_t stride) {
    const size_t sizeBytes = static_cast<size_t>(stride) * (info.height - 1u) + static_cast<size_t>(info.width) * 4u;
    return {data, sizeBytes, info.width, info.height, stride, SONY2FUJI_PIXEL_RGBA8};
}

jdoubleArray sampleToDoubleArray(JNIEnv* env, const sony2fuji_inspection_sample& s) {
    const jdouble values[7] = {
        static_cast<jdouble>(s.r), static_cast<jdouble>(s.g), static_cast<jdouble>(s.b),
        s.hue_deg, s.saturation_pct, s.brightness_pct, s.luminance,
    };
    jdoubleArray out = env->NewDoubleArray(7);
    if (!out) return nullptr;
    env->SetDoubleArrayRegion(out, 0, 7, values);
    return env->ExceptionCheck() ? nullptr : out;
}

jfloatArray mapNormPoint(JNIEnv* env, jint sourceWidth, jint sourceHeight, GEOM_PARAMS,
                         jdouble x, jdouble y, bool toSource) {
    if (sourceWidth <= 0 || sourceHeight <= 0) return nullptr;
    sony2fuji_geometry_config geom{};
    sony2fuji_perspective_config persp{};
    fillGeometryConfigs(cropX, cropY, cropWidth, cropHeight, quarterTurns, flipHorizontal,
                        flipVertical, straightenDegrees, perspectiveHorizontal, perspectiveVertical, geom, persp);
    double outX = 0.0, outY = 0.0;
    int32_t valid = 0;
    const auto fn = toSource ? sony2fuji_geometry_output_norm_to_source_norm : sony2fuji_geometry_source_norm_to_output_norm;
    if (fn(static_cast<uint32_t>(sourceWidth), static_cast<uint32_t>(sourceHeight),
           &geom, &persp, x, y, &outX, &outY, &valid) != SONY2FUJI_STATUS_OK || valid == 0) {
        return nullptr;
    }
    const jfloat pt[2] = {static_cast<jfloat>(outX), static_cast<jfloat>(outY)};
    jfloatArray out = env->NewFloatArray(2);
    if (!out) return nullptr;
    env->SetFloatArrayRegion(out, 0, 2, pt);
    return env->ExceptionCheck() ? nullptr : out;
}

} // namespace

extern "C" JNIEXPORT jintArray JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativeInferSourceSize(
    JNIEnv* env, jclass, jint outputWidth, jint outputHeight, GEOM_PARAMS) {
    if (outputWidth <= 0 || outputHeight <= 0) return nullptr;
    sony2fuji_geometry_config geom{};
    sony2fuji_perspective_config persp{};
    fillGeometryConfigs(cropX, cropY, cropWidth, cropHeight, quarterTurns, flipHorizontal,
                        flipVertical, straightenDegrees, perspectiveHorizontal, perspectiveVertical, geom, persp);
    uint32_t srcW = 0, srcH = 0;
    if (sony2fuji_geometry_infer_source_size(static_cast<uint32_t>(outputWidth), static_cast<uint32_t>(outputHeight),
                                             &geom, &persp, &srcW, &srcH) != SONY2FUJI_STATUS_OK ||
        srcW == 0 || srcH == 0) {
        return nullptr;
    }
    const jint dims[2] = {static_cast<jint>(srcW), static_cast<jint>(srcH)};
    jintArray out = env->NewIntArray(2);
    if (!out) return nullptr;
    env->SetIntArrayRegion(out, 0, 2, dims);
    return env->ExceptionCheck() ? nullptr : out;
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativeOutputNormToSourceNorm(
    JNIEnv* env, jclass, jint sourceWidth, jint sourceHeight, GEOM_PARAMS, jdouble outX, jdouble outY) {
    return mapNormPoint(env, sourceWidth, sourceHeight, cropX, cropY, cropWidth, cropHeight, quarterTurns,
                        flipHorizontal, flipVertical, straightenDegrees, perspectiveHorizontal, perspectiveVertical,
                        outX, outY, true);
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativeSourceNormToOutputNorm(
    JNIEnv* env, jclass, jint sourceWidth, jint sourceHeight, GEOM_PARAMS, jdouble srcX, jdouble srcY) {
    return mapNormPoint(env, sourceWidth, sourceHeight, cropX, cropY, cropWidth, cropHeight, quarterTurns,
                        flipHorizontal, flipVertical, straightenDegrees, perspectiveHorizontal, perspectiveVertical,
                        srcX, srcY, false);
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativeColorFromRgb(
    JNIEnv* env, jclass, jint r, jint g, jint b) {
    auto sample = makeSampleStorage();
    if (sony2fuji_inspection_color_from_rgb(clampByte(r), clampByte(g), clampByte(b), &sample) != SONY2FUJI_STATUS_OK) {
        return nullptr;
    }
    return sampleToDoubleArray(env, sample);
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativeSampleBitmapPatch(
    JNIEnv* env, jclass, jobject bitmap, jdouble normX, jdouble normY, jint radiusPx) {
    if (!bitmap || radiusPx < 0) return nullptr;
    try {
        AndroidBitmapInfo info{};
        if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS ||
            info.width == 0 || info.height == 0 || info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) {
            return nullptr;
        }
        rawlab::jni::BitmapPixels pixels(env, bitmap, static_cast<jint>(info.width),
                                         static_cast<jint>(info.height), SONY2FUJI_PIXEL_RGBA8, false);
        const sony2fuji_buffer buf = makeRgbaBuffer(const_cast<void*>(pixels.bytes), info, pixels.stride);
        auto sample = makeSampleStorage();
        if (sony2fuji_inspection_sample_patch(&buf, normX, normY, static_cast<uint32_t>(radiusPx), &sample) != SONY2FUJI_STATUS_OK) {
            return nullptr;
        }
        return sampleToDoubleArray(env, sample);
    } catch (...) {
        return nullptr;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativeOverlayPixel(
    JNIEnv*, jclass, jint r, jint g, jint b, jint mode) {
    const uint8_t cr = clampByte(r), cg = clampByte(g), cb = clampByte(b);
    uint8_t outR = cr, outG = cg, outB = cb;
    if (sony2fuji_inspection_overlay_pixel(
            cr, cg, cb, static_cast<sony2fuji_inspection_overlay_mode>(mode),
            &outR, &outG, &outB) != SONY2FUJI_STATUS_OK) {
        outR = cr; outG = cg; outB = cb;
    }
    return static_cast<jint>((0xffu << 24) | (static_cast<uint32_t>(outR) << 16) |
                             (static_cast<uint32_t>(outG) << 8) | static_cast<uint32_t>(outB));
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativeRenderOverlay(
    JNIEnv* env, jclass, jobject srcBitmap, jobject dstBitmap, jint mode) {
    if (!srcBitmap || !dstBitmap || env->IsSameObject(srcBitmap, dstBitmap)) return JNI_FALSE;
    try {
        AndroidBitmapInfo srcInfo{}, dstInfo{};
        if (AndroidBitmap_getInfo(env, srcBitmap, &srcInfo) != ANDROID_BITMAP_RESULT_SUCCESS ||
            srcInfo.width == 0 || srcInfo.height == 0 || srcInfo.format != ANDROID_BITMAP_FORMAT_RGBA_8888) {
            return JNI_FALSE;
        }
        rawlab::jni::BitmapPixels srcPixels(env, srcBitmap, static_cast<jint>(srcInfo.width),
                                            static_cast<jint>(srcInfo.height), SONY2FUJI_PIXEL_RGBA8, false);
        rawlab::jni::OutputBitmapLock dstLock(env, dstBitmap, dstInfo, srcInfo.width, srcInfo.height);
        const sony2fuji_buffer srcBuf = makeRgbaBuffer(const_cast<void*>(srcPixels.bytes), srcInfo, srcPixels.stride);
        sony2fuji_buffer dstBuf = makeRgbaBuffer(dstLock.locked, dstInfo, dstInfo.stride);
        return sony2fuji_inspection_render_overlay(
            &srcBuf, static_cast<sony2fuji_inspection_overlay_mode>(mode), &dstBuf) == SONY2FUJI_STATUS_OK
            ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        return JNI_FALSE;
    }
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_rawlab_android_editor_inspection_InspectionNative_nativePointColorPreviewSwatch(
    JNIEnv* env,
    jclass,
    jfloat srcHue,
    jfloat srcSaturation,
    jfloat srcLuminance,
    jfloat hueShift,
    jfloat saturationShift,
    jfloat luminanceShift) {
    float srcRgb[3]{};
    float shiftedRgb[3]{};
    if (sony2fuji_point_color_preview_swatch(
            srcHue, srcSaturation, srcLuminance,
            hueShift, saturationShift, luminanceShift,
            srcRgb, shiftedRgb) != SONY2FUJI_STATUS_OK) {
        return nullptr;
    }
    const jfloat values[6] = {
        srcRgb[0], srcRgb[1], srcRgb[2],
        shiftedRgb[0], shiftedRgb[1], shiftedRgb[2],
    };
    jfloatArray out = env->NewFloatArray(6);
    if (!out) return nullptr;
    env->SetFloatArrayRegion(out, 0, 6, values);
    return env->ExceptionCheck() ? nullptr : out;
}
