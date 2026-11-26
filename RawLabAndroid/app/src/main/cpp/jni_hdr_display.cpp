#include "jni_internal.h"

#include <cstdint>

// HDR 亮度统计与显示映射的 JNI 绑定：像素数学全部在共享核心，这里只做数组钉住与状态翻译。
namespace {

using namespace rawlab::jni;

// 钉住期间不得调用其他 JNI 函数，异常一律在释放之后抛出。
struct CriticalArray {
    JNIEnv* env;
    jarray array;
    jint mode;
    void* data;
    CriticalArray(JNIEnv* e, jarray a, jint m) : env(e), array(a), mode(m), data(e->GetPrimitiveArrayCritical(a, nullptr)) {}
    ~CriticalArray() { if (data) env->ReleasePrimitiveArrayCritical(array, data, mode); }
    CriticalArray(const CriticalArray&) = delete;
    CriticalArray& operator=(const CriticalArray&) = delete;
};

sony2fuji_hdr_buffer_v1 floatPlane(void* data, uint64_t floats, uint32_t width, uint32_t height, uint64_t strideFloats) {
    sony2fuji_hdr_buffer_v1 plane{};
    plane.version = SONY2FUJI_HDR_VERSION;
    plane.struct_size = sizeof(plane);
    plane.data = data;
    plane.size_bytes = floats * sizeof(float);
    plane.width = width;
    plane.height = height;
    plane.stride_bytes = strideFloats * sizeof(float);
    plane.pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
    plane.color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
    return plane;
}

void throwDisplayStatus(JNIEnv* env, sony2fuji_status status) {
    if (status == SONY2FUJI_STATUS_OUT_OF_MEMORY) {
        throwJava(env, "java/lang/OutOfMemoryError", "Not enough memory for HDR display");
    } else if (status == SONY2FUJI_STATUS_INVALID_ARGUMENT || status == SONY2FUJI_STATUS_UNSUPPORTED) {
        throwJava(env, "java/lang/IllegalArgumentException", "Invalid or non-finite HDR display input");
    } else {
        throwJava(env, "java/lang/IllegalStateException", "HDR display mapping failed");
    }
}

} // namespace

extern "C" JNIEXPORT jint JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeAnalyzeLuminance(JNIEnv* env, jclass, jfloatArray values,
    jint width, jint height, jint stride, jintArray bins, jfloatArray peak) {
    if (!values || !bins || !peak || width <= 0 || height <= 0 || stride <= 0 ||
        env->GetArrayLength(bins) < static_cast<jsize>(SONY2FUJI_HDR_LUMINANCE_BINS) || env->GetArrayLength(peak) < 1) {
        throwJava(env, "java/lang/IllegalArgumentException", "Invalid HDR statistics request");
        return 0;
    }
    const auto length = static_cast<uint64_t>(env->GetArrayLength(values));
    uint32_t counts[SONY2FUJI_HDR_LUMINANCE_BINS] = {};
    uint32_t above = 0;
    float peakValue = 1;
    sony2fuji_status status = SONY2FUJI_STATUS_OUT_OF_MEMORY;
    {
        CriticalArray pixels(env, values, JNI_ABORT);
        if (pixels.data) {
            const auto plane = floatPlane(pixels.data, length, uint32_t(width), uint32_t(height), uint64_t(stride));
            status = sony2fuji_hdr_analyze_luminance(&plane, counts, &above, &peakValue);
        }
    }
    if (status != SONY2FUJI_STATUS_OK) {
        throwDisplayStatus(env, status);
        return 0;
    }
    env->SetIntArrayRegion(bins, 0, static_cast<jsize>(SONY2FUJI_HDR_LUMINANCE_BINS), reinterpret_cast<const jint*>(counts));
    env->SetFloatArrayRegion(peak, 0, 1, &peakValue);
    return static_cast<jint>(above);
}

// 映射紧密排列平面的 [firstRow, firstRow + rowCount) 行到 RGBA16F 输出的同一行段；
// 返回 false 表示结果超出半精度范围（调用方不出 HDR 位图）。
extern "C" JNIEXPORT jboolean JNICALL
Java_com_rawlab_android_engine_NativeHDRBridge_nativeDisplayRows(JNIEnv* env, jclass, jfloatArray hdr,
    jfloatArray sdr, jint width, jint height, jint firstRow, jint rowCount, jfloat displayHeadroom,
    jfloat contentHeadroom, jint flags, jshortArray output) {
    const uint64_t pixels = width > 0 && height > 0 ? uint64_t(width) * uint64_t(height) : 0;
    if (!hdr || !sdr || !output || pixels == 0 || firstRow < 0 || rowCount <= 0 || firstRow > height - rowCount ||
        uint64_t(env->GetArrayLength(hdr)) < pixels * 3 || uint64_t(env->GetArrayLength(sdr)) < pixels * 3 ||
        uint64_t(env->GetArrayLength(output)) < pixels * 4) {
        throwJava(env, "java/lang/IllegalArgumentException", "Invalid HDR display request");
        return JNI_FALSE;
    }
    const uint64_t rowFloats = uint64_t(width) * 3, rowShorts = uint64_t(width) * 4;
    const uint64_t rows = uint64_t(rowCount);
    sony2fuji_status status = SONY2FUJI_STATUS_OUT_OF_MEMORY;
    {
        CriticalArray hdrPixels(env, hdr, JNI_ABORT);
        if (hdrPixels.data) {
            CriticalArray sdrPixels(env, sdr, JNI_ABORT);
            if (sdrPixels.data) {
                CriticalArray outPixels(env, output, 0);
                if (outPixels.data) {
                    const uint64_t offset = uint64_t(firstRow) * rowFloats;
                    const auto hdrPlane = floatPlane(static_cast<float*>(hdrPixels.data) + offset, rows * rowFloats,
                        uint32_t(width), uint32_t(rowCount), rowFloats);
                    const auto sdrPlane = floatPlane(static_cast<float*>(sdrPixels.data) + offset, rows * rowFloats,
                        uint32_t(width), uint32_t(rowCount), rowFloats);
                    auto* dst = static_cast<jshort*>(outPixels.data) + uint64_t(firstRow) * rowShorts;
                    status = sony2fuji_hdr_display_into(&hdrPlane, &sdrPlane, displayHeadroom, contentHeadroom,
                        static_cast<uint32_t>(flags), dst, rows * rowShorts * sizeof(jshort), rowShorts * sizeof(jshort));
                }
            }
        }
    }
    if (status == SONY2FUJI_STATUS_OK) return JNI_TRUE;
    if (status == SONY2FUJI_STATUS_PROCESSING_ERROR) return JNI_FALSE;
    throwDisplayStatus(env, status);
    return JNI_FALSE;
}
