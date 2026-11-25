#include "../app/src/main/cpp/jni_internal.h"
#include <spng.h>
#include <lcms2.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <unistd.h>

extern "C" {
jlong JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(JNIEnv*, jobject, jint);
void JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(JNIEnv*, jobject, jlong);
jlong JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeCancellationGeneration(JNIEnv*, jobject, jlong);
void JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeCancelPreview(JNIEnv*, jobject, jlong);
void JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeSetGpuMode(JNIEnv*, jobject, jlong, jint);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(
    JNIEnv*, jobject, jlong, jstring, jstring, jobject, jint, jint, jint, jstring, jint, jint, jint, jboolean, jboolean, jobject, jlong, jintArray);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeProcessRoi(
    JNIEnv*, jobject, jlong, jstring, jstring, jobject, jint, jint, jint, jfloat, jfloat, jfloat, jfloat, jint, jlong);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeSampleWbProbe(
    JNIEnv*, jobject, jlong, jstring, jstring, jobject, jint, jint, jint, jint, jfloat, jfloat, jint, jlong);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeSampleHsl(
    JNIEnv*, jobject, jlong, jstring, jstring, jobject, jint, jint, jint, jint, jboolean, jlong, jlong, jfloat, jfloat, jlong);
jfloat JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeAutoExposure(
    JNIEnv*, jobject, jlong, jstring, jstring, jobject, jint, jint, jint);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeMigrateProcessing(
    JNIEnv*, jobject, jlong, jstring, jstring, jobject, jint, jint, jint, jlong);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeCompatibilityPreview(
    JNIEnv*, jobject, jlong, jstring, jstring, jobject, jint, jint, jint, jstring);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeInspectLens(
    JNIEnv*, jobject, jlong, jstring, jstring);
jobject JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeResolveCameraWhiteBalance(
    JNIEnv*, jobject, jlong, jstring, jint, jint, jint);
jobject JNICALL Java_com_rawlab_android_engine_NativeLookBridge_validate(JNIEnv*, jclass, jstring);
jobject JNICALL Java_com_rawlab_android_raster_NativePng16_nativeDecode(JNIEnv*, jobject, jstring, jint, jint, jint);
void JNICALL Java_com_rawlab_android_raster_NativePng16_nativeConvert(JNIEnv*, jobject, jobject, jbyteArray);
void JNICALL Java_com_rawlab_android_raster_NativePng16_nativeRelease(JNIEnv*, jobject, jobject);
jint JNICALL Java_com_rawlab_android_raster_NativeMpf_nativeInspectSdrJpegMpf(JNIEnv*, jobject, jstring);
jintArray JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(JNIEnv*, jclass, jint, jint, jstring);
jlong JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(JNIEnv*, jclass, jlong, jstring, jint, jlong, jobject);
jlong JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(JNIEnv*, jclass, jlong, jlong, jstring, jint, jlong, jobject);
jobject JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeSampleHsl(
    JNIEnv*, jclass, jlong, jlong, jstring, jint, jlong, jlong, jfloat, jfloat, jlong);
void JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportProRAW(
    JNIEnv*, jclass, jlong, jstring, jstring, jint, jboolean, jbyteArray, jstring, jstring, jlong, jobject);
jfloatArray JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativePlane(JNIEnv*, jclass, jlong, jboolean);
void JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeSdrBitmap(JNIEnv*, jclass, jlong, jobject);
void JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(JNIEnv*, jclass, jlong);
jobject JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeMetadata(JNIEnv*, jclass, jlong);
void JNICALL Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportJpeg(
    JNIEnv*, jclass, jlong, jlong, jstring, jstring, jint, jlong, jobject);
jdouble JNICALL Java_com_rawlab_android_engine_ToneCurveSampling_nativeSampleParametricValue(
    JNIEnv*, jclass, jdoubleArray, jdouble);
jintArray JNICALL Java_com_rawlab_android_editor_inspection_InspectionNative_nativeInferSourceSize(
    JNIEnv*, jclass, jint, jint, jfloat, jfloat, jfloat, jfloat, jint, jboolean, jboolean, jfloat, jfloat, jfloat);
jfloatArray JNICALL Java_com_rawlab_android_editor_inspection_InspectionNative_nativeOutputNormToSourceNorm(
    JNIEnv*, jclass, jint, jint, jfloat, jfloat, jfloat, jfloat, jint, jboolean, jboolean, jfloat, jfloat, jfloat, jdouble, jdouble);
jfloatArray JNICALL Java_com_rawlab_android_editor_inspection_InspectionNative_nativeSourceNormToOutputNorm(
    JNIEnv*, jclass, jint, jint, jfloat, jfloat, jfloat, jfloat, jint, jboolean, jboolean, jfloat, jfloat, jfloat, jdouble, jdouble);
jdoubleArray JNICALL Java_com_rawlab_android_editor_inspection_InspectionNative_nativeColorFromRgb(
    JNIEnv*, jclass, jint, jint, jint);
jdoubleArray JNICALL Java_com_rawlab_android_editor_inspection_InspectionNative_nativeSampleBitmapPatch(
    JNIEnv*, jclass, jobject, jdouble, jdouble, jint);
jint JNICALL Java_com_rawlab_android_editor_inspection_InspectionNative_nativeOverlayPixel(
    JNIEnv*, jclass, jint, jint, jint, jint);
jboolean JNICALL Java_com_rawlab_android_editor_inspection_InspectionNative_nativeRenderOverlay(
    JNIEnv*, jclass, jobject, jobject, jint);
jboolean JNICALL Java_com_rawlab_android_engine_NativeProcessor_nativeSupportsFastFullResGpu(
    JNIEnv*, jobject, jlong, jint, jint, jint, jint, jstring, jstring);
jint JNICALL Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel(
    JNIEnv*, jclass, jdouble, jdouble);
jdoubleArray JNICALL Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidTiles(
    JNIEnv*, jclass, jint, jint, jint, jint, jdouble, jdouble, jdouble, jdouble, jdouble, jdouble);
jdoubleArray JNICALL Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel0Grid(
    JNIEnv*, jclass, jint, jint, jint);
jboolean JNICALL Java_com_rawlab_android_editor_canvas_ViewportNative_nativeDetailOverlayCovers(
    JNIEnv*, jclass, jint, jint, jint, jint, jint,
    jdouble, jdouble, jdouble, jdouble,
    jdouble, jdouble, jdouble, jdouble, jdouble);
}

namespace {

using Clock = std::chrono::steady_clock;

struct TestFailure : std::runtime_error {
    using std::runtime_error::runtime_error;
};

void unblockAllWaitersForCleanup();

[[noreturn]] void failTest(const std::string& message) {
    unblockAllWaitersForCleanup();
    throw TestFailure(message);
}

void require(bool condition, const std::string& message) {
    if (!condition) failTest(message);
}

// ============================================================================
//  Thread-safe minimal JNI mock backed by real JDK <jni.h>
// ============================================================================

enum class FakeObjKind {
    String,
    BooleanArray,
    ByteArray,
    IntArray,
    FloatArray,
    DoubleArray,
    ObjectArray,
    DirectBuffer,
    Bitmap,
    Class,
    Object,
    Throwable,
};

struct FakeJObject {
    FakeObjKind kind;
    std::string text;
    std::vector<jboolean> booleans;
    std::vector<jbyte> bytes;
    std::vector<jint> ints;
    std::vector<jfloat> floats;
    std::vector<jdouble> doubles;
    std::vector<jobject> objects;
    std::unordered_map<std::string, jvalue> fields;
    void* directAddress = nullptr;
    jlong directCapacity = 0;
    uint32_t bitmapWidth = 0;
    uint32_t bitmapHeight = 0;
    uint32_t bitmapStride = 0;
    std::vector<uint8_t> bitmapPixels;
    int bitmapLockCount = 0;
    int bitmapUnlockCount = 0;
    jint intArg = 0;
    jint secondIntArg = 0;
    std::string strArg;
};

struct FakeMethodId {
    std::string className;
    std::string name;
    std::string sig;
};

struct FakeFieldId {
    std::string className;
    std::string name;
    std::string sig;
};

std::mutex gJniMutex;
std::vector<std::unique_ptr<FakeJObject>> gAllocatedObjects;
std::vector<std::unique_ptr<FakeMethodId>> gAllocatedMethods;
std::vector<std::unique_ptr<FakeFieldId>> gAllocatedFields;
std::vector<jint> gRecordedHdrProgress;
std::atomic<int> gFindClassCalls{0};
std::atomic<int> gGetFieldIdCalls{0};
std::atomic<int> gGetMethodIdCalls{0};
std::atomic<int> gGetStaticMethodIdCalls{0};
std::atomic<int> gNewByteArrayCalls{0};
std::atomic<int> gAllocateBitmapCalls{0};
std::atomic<int> gBitmapLockCalls{0};
std::atomic<int> gBitmapUnlockCalls{0};
uint32_t gMockBitmapStridePaddingBytes = 0;
uint32_t gMockProcessBufferStridePaddingBytes = 0;
uint8_t gMockProcessPixelSeed = 0;
bool gCancelOnNextBitmapLock = false;
jlong gCancelSessionIdOnBitmapLock = 0;
uint32_t gMockHdrPlaneStridePaddingFloats = 0;
bool gMockLensAppliedDistortion = false;
bool gMockLensAppliedTca = false;
bool gMockLensAppliedVignetting = false;

struct ThreadJniException {
    bool active = false;
    std::string className;
    std::string message;
    jint status = 0;
    jint unsupportedReason = 0;
};
thread_local ThreadJniException gTlsException;

jobject allocObj(FakeObjKind kind) {
    auto obj = std::make_unique<FakeJObject>();
    obj->kind = kind;
    auto* raw = reinterpret_cast<jobject>(obj.get());
    std::lock_guard<std::mutex> lock(gJniMutex);
    gAllocatedObjects.push_back(std::move(obj));
    return raw;
}

jstring makeJString(const std::string& text) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::String));
    obj->text = text;
    return reinterpret_cast<jstring>(obj);
}

jfloatArray makeJFloatArray(const std::vector<jfloat>& values) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::FloatArray));
    obj->floats = values;
    return reinterpret_cast<jfloatArray>(obj);
}

jdoubleArray makeJDoubleArray(const std::vector<jdouble>& values) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::DoubleArray));
    obj->doubles = values;
    return reinterpret_cast<jdoubleArray>(obj);
}

jintArray makeJIntArray(const std::vector<jint>& values) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::IntArray));
    obj->ints = values;
    return reinterpret_cast<jintArray>(obj);
}

jbyteArray makeJByteArray(const std::vector<jbyte>& values) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::ByteArray));
    obj->bytes = values;
    return reinterpret_cast<jbyteArray>(obj);
}

FakeJObject* asFake(jobject obj) { return reinterpret_cast<FakeJObject*>(obj); }

jobject makeStruct(const std::string& className) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::Object));
    obj->text = className;
    return reinterpret_cast<jobject>(obj);
}

void setObjField(jobject obj, const std::string& name, jobject val) {
    jvalue v{}; v.l = val; asFake(obj)->fields[name] = v;
}
void setBoolField(jobject obj, const std::string& name, jboolean val) {
    jvalue v{}; v.z = val; asFake(obj)->fields[name] = v;
}
void setIntField(jobject obj, const std::string& name, jint val) {
    jvalue v{}; v.i = val; asFake(obj)->fields[name] = v;
}
void setLongField(jobject obj, const std::string& name, jlong val) {
    jvalue v{}; v.j = val; asFake(obj)->fields[name] = v;
}
void setFloatField(jobject obj, const std::string& name, jfloat val) {
    jvalue v{}; v.f = val; asFake(obj)->fields[name] = v;
}

jclass JNICALL mockFindClass(JNIEnv*, const char* name) {
    gFindClassCalls.fetch_add(1, std::memory_order_relaxed);
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::Class));
    obj->text = name ? name : "";
    return reinterpret_cast<jclass>(obj);
}

jobject JNICALL mockNewGlobalRef(JNIEnv*, jobject obj) {
    return obj;
}

void JNICALL mockDeleteGlobalRef(JNIEnv*, jobject) {}

jmethodID JNICALL mockGetMethodID(JNIEnv*, jclass clazz, const char* name, const char* sig) {
    gGetMethodIdCalls.fetch_add(1, std::memory_order_relaxed);
    auto method = std::make_unique<FakeMethodId>();
    method->className = clazz ? asFake(clazz)->text : "";
    method->name = name ? name : "";
    method->sig = sig ? sig : "";
    auto* raw = reinterpret_cast<jmethodID>(method.get());
    std::lock_guard<std::mutex> lock(gJniMutex);
    gAllocatedMethods.push_back(std::move(method));
    return raw;
}

jmethodID JNICALL mockGetStaticMethodID(JNIEnv*, jclass clazz, const char* name, const char* sig) {
    gGetStaticMethodIdCalls.fetch_add(1, std::memory_order_relaxed);
    auto method = std::make_unique<FakeMethodId>();
    method->className = clazz ? asFake(clazz)->text : "";
    method->name = name ? name : "";
    method->sig = sig ? sig : "";
    auto* raw = reinterpret_cast<jmethodID>(method.get());
    std::lock_guard<std::mutex> lock(gJniMutex);
    gAllocatedMethods.push_back(std::move(method));
    return raw;
}

jobject makeFakeBitmap(uint32_t width, uint32_t height, uint32_t extraStrideBytes = 0) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::Bitmap));
    obj->bitmapWidth = width;
    obj->bitmapHeight = height;
    obj->bitmapStride = width * 4u + extraStrideBytes;
    obj->bitmapPixels.assign(static_cast<size_t>(obj->bitmapStride) * height, 0xAA);
    return reinterpret_cast<jobject>(obj);
}

jobject JNICALL mockCallStaticObjectMethodV(JNIEnv*, jclass, jmethodID method, va_list args) {
    auto* mid = reinterpret_cast<FakeMethodId*>(method);
    if (mid && mid->className == "com/rawlab/android/engine/NativeFrame" && mid->name == "allocateBitmap") {
        gAllocateBitmapCalls.fetch_add(1, std::memory_order_relaxed);
        const jint w = va_arg(args, jint);
        const jint h = va_arg(args, jint);
        jobject reusable = va_arg(args, jobject);
        if (reusable && asFake(reusable)->kind == FakeObjKind::Bitmap &&
            asFake(reusable)->bitmapWidth == static_cast<uint32_t>(w) &&
            asFake(reusable)->bitmapHeight == static_cast<uint32_t>(h)) {
            return reusable;
        }
        return makeFakeBitmap(static_cast<uint32_t>(w), static_cast<uint32_t>(h), gMockBitmapStridePaddingBytes);
    }
    return nullptr;
}

void JNICALL mockCallVoidMethodV(JNIEnv*, jobject, jmethodID method, va_list args) {
    auto* mid = reinterpret_cast<FakeMethodId*>(method);
    if (mid && mid->className == "com/rawlab/android/engine/HDRProgressListener" && mid->name == "onProgress") {
        const jint permille = va_arg(args, jint);
        std::lock_guard<std::mutex> lock(gJniMutex);
        gRecordedHdrProgress.push_back(permille);
    }
}

jfieldID JNICALL mockGetFieldID(JNIEnv*, jclass clazz, const char* name, const char* sig) {
    gGetFieldIdCalls.fetch_add(1, std::memory_order_relaxed);
    auto field = std::make_unique<FakeFieldId>();
    field->className = clazz ? asFake(clazz)->text : "";
    field->name = name ? name : "";
    field->sig = sig ? sig : "";
    auto* raw = reinterpret_cast<jfieldID>(field.get());
    std::lock_guard<std::mutex> lock(gJniMutex);
    gAllocatedFields.push_back(std::move(field));
    return raw;
}

jobject JNICALL mockGetObjectField(JNIEnv*, jobject obj, jfieldID fid) {
    if (!obj || !fid) return nullptr;
    const auto& name = reinterpret_cast<FakeFieldId*>(fid)->name;
    auto it = asFake(obj)->fields.find(name);
    return it == asFake(obj)->fields.end() ? nullptr : it->second.l;
}

jboolean JNICALL mockGetBooleanField(JNIEnv*, jobject obj, jfieldID fid) {
    if (!obj || !fid) return JNI_FALSE;
    const auto& name = reinterpret_cast<FakeFieldId*>(fid)->name;
    auto it = asFake(obj)->fields.find(name);
    return it == asFake(obj)->fields.end() ? JNI_FALSE : it->second.z;
}

jint JNICALL mockGetIntField(JNIEnv*, jobject obj, jfieldID fid) {
    if (!obj || !fid) return 0;
    const auto& name = reinterpret_cast<FakeFieldId*>(fid)->name;
    auto it = asFake(obj)->fields.find(name);
    return it == asFake(obj)->fields.end() ? 0 : it->second.i;
}

jlong JNICALL mockGetLongField(JNIEnv*, jobject obj, jfieldID fid) {
    if (!obj || !fid) return 0;
    const auto& name = reinterpret_cast<FakeFieldId*>(fid)->name;
    auto it = asFake(obj)->fields.find(name);
    return it == asFake(obj)->fields.end() ? 0 : it->second.j;
}

jfloat JNICALL mockGetFloatField(JNIEnv*, jobject obj, jfieldID fid) {
    if (!obj || !fid) return 0.f;
    const auto& name = reinterpret_cast<FakeFieldId*>(fid)->name;
    auto it = asFake(obj)->fields.find(name);
    return it == asFake(obj)->fields.end() ? 0.f : it->second.f;
}

jdouble JNICALL mockGetDoubleField(JNIEnv*, jobject obj, jfieldID fid) {
    if (!obj || !fid) return 0.0;
    const auto& name = reinterpret_cast<FakeFieldId*>(fid)->name;
    auto it = asFake(obj)->fields.find(name);
    return it == asFake(obj)->fields.end() ? 0.0 : it->second.d;
}

jobject JNICALL mockNewObjectV(JNIEnv*, jclass clazz, jmethodID method, va_list args) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::Object));
    obj->text = clazz ? asFake(clazz)->text : "";
    auto* mid = reinterpret_cast<FakeMethodId*>(method);
    const std::string cls = mid ? mid->className : obj->text;
    if (cls == "java/lang/String") {
        obj->kind = FakeObjKind::String;
        auto bytes = va_arg(args, jbyteArray);
        (void)va_arg(args, jstring);
        if (bytes) {
            const auto& raw = asFake(bytes)->bytes;
            obj->text.assign(reinterpret_cast<const char*>(raw.data()), raw.size());
        } else {
            obj->text.clear();
        }
    } else if (cls == "com/rawlab/android/engine/NativeProcessingException") {
        obj->kind = FakeObjKind::Throwable;
        obj->intArg = va_arg(args, jint);
        auto msg = va_arg(args, jstring);
        obj->strArg = msg ? asFake(msg)->text : "";
        obj->secondIntArg = va_arg(args, jint);
    } else if (cls == "com/rawlab/android/engine/HDRProcessingException") {
        obj->kind = FakeObjKind::Throwable;
        obj->intArg = va_arg(args, jint);
        obj->secondIntArg = va_arg(args, jint);
        obj->fields["field"].i = va_arg(args, jint);
    } else if (cls == "com/rawlab/android/engine/LUTColorContractException") {
        obj->kind = FakeObjKind::Throwable;
        obj->intArg = va_arg(args, jint);
        obj->fields["reason"].i = obj->intArg;
    } else if (cls == "com/rawlab/android/engine/NativeFrame") {
        obj->fields["width"].i = va_arg(args, jint);
        obj->fields["height"].i = va_arg(args, jint);
        obj->fields["bitmap"].l = va_arg(args, jobject);
        obj->fields["rawTemperature"].f = static_cast<jfloat>(va_arg(args, double));
        obj->fields["rawTint"].f = static_cast<jfloat>(va_arg(args, double));
        obj->fields["backend"].i = va_arg(args, jint);
        obj->fields["histogram"].l = va_arg(args, jobject);
    } else if (cls == "com/rawlab/android/engine/NativeRoiBounds") {
        obj->fields["x0"].i = va_arg(args, jint);
        obj->fields["y0"].i = va_arg(args, jint);
        obj->fields["x1"].i = va_arg(args, jint);
        obj->fields["y1"].i = va_arg(args, jint);
        obj->fields["fullWidth"].i = va_arg(args, jint);
        obj->fields["fullHeight"].i = va_arg(args, jint);
    } else if (cls == "com/rawlab/android/engine/NativeRoiFrame") {
        obj->fields["frame"].l = va_arg(args, jobject);
        obj->fields["bounds"].l = va_arg(args, jobject);
    } else if (cls == "com/rawlab/android/engine/NativeWbProbeResult") {
        obj->fields["availability"].i = va_arg(args, jint);
        obj->fields["temperature"].f = static_cast<jfloat>(va_arg(args, double));
        obj->fields["tint"].f = static_cast<jfloat>(va_arg(args, double));
        obj->fields["validPixelCount"].i = va_arg(args, jint);
        obj->fields["rejectedOverexposedCount"].i = va_arg(args, jint);
    } else if (cls == "com/rawlab/android/engine/NativeHslProbeResult") {
        obj->fields["availability"].i = va_arg(args, jint);
        obj->fields["previewQuality"].z = static_cast<jboolean>(va_arg(args, int));
        obj->fields["rgb"].l = va_arg(args, jobject);
        obj->fields["weights"].l = va_arg(args, jobject);
    } else if (cls == "com/rawlab/android/engine/NativeLensInspection") {
        obj->fields["appliedDistortion"].z = static_cast<jboolean>(va_arg(args, int));
        obj->fields["appliedTca"].z = static_cast<jboolean>(va_arg(args, int));
        obj->fields["appliedVignetting"].z = static_cast<jboolean>(va_arg(args, int));
    } else if (cls == "com/rawlab/android/engine/NativeLookValidation") {
        obj->fields["format"].i = va_arg(args, jint);
        obj->fields["version"].i = va_arg(args, jint);
        obj->fields["colorState"].i = va_arg(args, jint);
    } else if (cls == "com/rawlab/android/engine/NativeCameraWhiteBalance") {
        obj->fields["temperature"].f = static_cast<jfloat>(va_arg(args, double));
        obj->fields["tint"].f = static_cast<jfloat>(va_arg(args, double));
    } else if (cls == "com/rawlab/android/engine/NativeMigrationResult") {
        obj->fields["sourceVersion"].i = va_arg(args, jint);
        obj->fields["targetVersion"].i = va_arg(args, jint);
        obj->fields["disposition"].i = va_arg(args, jint);
        obj->fields["evaluationCount"].i = va_arg(args, jint);
        obj->fields["exposureEv"].f = static_cast<jfloat>(va_arg(args, double));
        obj->fields["contrast"].f = static_cast<jfloat>(va_arg(args, double));
    }
    return reinterpret_cast<jobject>(obj);
}

jint JNICALL mockThrow(JNIEnv*, jthrowable throwable) {
    auto* obj = asFake(throwable);
    gTlsException.active = true;
    gTlsException.className = obj ? obj->text : "java/lang/Throwable";
    gTlsException.message = obj ? obj->strArg : "";
    gTlsException.status = obj ? obj->intArg : 0;
    gTlsException.unsupportedReason = obj ? obj->secondIntArg : 0;
    return 0;
}

jint JNICALL mockThrowNew(JNIEnv*, jclass clazz, const char* msg) {
    gTlsException.active = true;
    gTlsException.className = clazz ? asFake(clazz)->text : "java/lang/Exception";
    gTlsException.message = msg ? msg : "";
    gTlsException.status = 0;
    return 0;
}

jboolean JNICALL mockExceptionCheck(JNIEnv*) { return gTlsException.active ? JNI_TRUE : JNI_FALSE; }
void JNICALL mockExceptionClear(JNIEnv*) { gTlsException = {}; }
void JNICALL mockDeleteLocalRef(JNIEnv*, jobject) {}

jstring JNICALL mockNewStringUTF(JNIEnv*, const char* utf) {
    return makeJString(utf ? utf : "");
}

const char* JNICALL mockGetStringUTFChars(JNIEnv*, jstring str, jboolean* isCopy) {
    if (isCopy) *isCopy = JNI_FALSE;
    return str ? asFake(str)->text.c_str() : nullptr;
}

void JNICALL mockReleaseStringUTFChars(JNIEnv*, jstring, const char*) {}

jsize JNICALL mockGetArrayLength(JNIEnv*, jarray array) {
    if (!array) return 0;
    const auto* obj = asFake(array);
    switch (obj->kind) {
        case FakeObjKind::BooleanArray: return static_cast<jsize>(obj->booleans.size());
        case FakeObjKind::ByteArray: return static_cast<jsize>(obj->bytes.size());
        case FakeObjKind::IntArray: return static_cast<jsize>(obj->ints.size());
        case FakeObjKind::FloatArray: return static_cast<jsize>(obj->floats.size());
        case FakeObjKind::DoubleArray: return static_cast<jsize>(obj->doubles.size());
        case FakeObjKind::ObjectArray: return static_cast<jsize>(obj->objects.size());
        default: return 0;
    }
}

jbooleanArray JNICALL mockNewBooleanArray(JNIEnv*, jsize len) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::BooleanArray));
    obj->booleans.resize(static_cast<size_t>(len));
    return reinterpret_cast<jbooleanArray>(obj);
}

jbyteArray JNICALL mockNewByteArray(JNIEnv*, jsize len) {
    gNewByteArrayCalls.fetch_add(1, std::memory_order_relaxed);
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::ByteArray));
    obj->bytes.resize(static_cast<size_t>(len));
    return reinterpret_cast<jbyteArray>(obj);
}

jintArray JNICALL mockNewIntArray(JNIEnv*, jsize len) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::IntArray));
    obj->ints.resize(static_cast<size_t>(len));
    return reinterpret_cast<jintArray>(obj);
}

jfloatArray JNICALL mockNewFloatArray(JNIEnv*, jsize len) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::FloatArray));
    obj->floats.resize(static_cast<size_t>(len));
    return reinterpret_cast<jfloatArray>(obj);
}

jdoubleArray JNICALL mockNewDoubleArray(JNIEnv*, jsize len) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::DoubleArray));
    obj->doubles.resize(static_cast<size_t>(len));
    return reinterpret_cast<jdoubleArray>(obj);
}

jboolean JNICALL mockIsSameObject(JNIEnv*, jobject a, jobject b) {
    return a == b ? JNI_TRUE : JNI_FALSE;
}

void JNICALL mockGetByteArrayRegion(JNIEnv*, jbyteArray arr, jsize start, jsize len, jbyte* buf) {
    if (!arr || !buf) return;
    std::memcpy(buf, asFake(arr)->bytes.data() + start, static_cast<size_t>(len) * sizeof(jbyte));
}

void JNICALL mockSetByteArrayRegion(JNIEnv*, jbyteArray arr, jsize start, jsize len, const jbyte* buf) {
    if (!arr || !buf) return;
    std::memcpy(asFake(arr)->bytes.data() + start, buf, static_cast<size_t>(len) * sizeof(jbyte));
}

void JNICALL mockSetBooleanArrayRegion(JNIEnv*, jbooleanArray arr, jsize start, jsize len, const jboolean* buf) {
    if (!arr || !buf) return;
    std::memcpy(asFake(arr)->booleans.data() + start, buf, static_cast<size_t>(len) * sizeof(jboolean));
}

void JNICALL mockGetIntArrayRegion(JNIEnv*, jintArray arr, jsize start, jsize len, jint* buf) {
    if (!arr || !buf) return;
    std::memcpy(buf, asFake(arr)->ints.data() + start, static_cast<size_t>(len) * sizeof(jint));
}

void JNICALL mockSetIntArrayRegion(JNIEnv*, jintArray arr, jsize start, jsize len, const jint* buf) {
    if (!arr || !buf) return;
    std::memcpy(asFake(arr)->ints.data() + start, buf, static_cast<size_t>(len) * sizeof(jint));
}

void JNICALL mockGetFloatArrayRegion(JNIEnv*, jfloatArray arr, jsize start, jsize len, jfloat* buf) {
    if (!arr || !buf) return;
    std::memcpy(buf, asFake(arr)->floats.data() + start, static_cast<size_t>(len) * sizeof(jfloat));
}

void JNICALL mockSetFloatArrayRegion(JNIEnv*, jfloatArray arr, jsize start, jsize len, const jfloat* buf) {
    if (!arr || !buf) return;
    std::memcpy(asFake(arr)->floats.data() + start, buf, static_cast<size_t>(len) * sizeof(jfloat));
}

void JNICALL mockGetDoubleArrayRegion(JNIEnv*, jdoubleArray arr, jsize start, jsize len, jdouble* buf) {
    if (!arr || !buf) return;
    std::memcpy(buf, asFake(arr)->doubles.data() + start, static_cast<size_t>(len) * sizeof(jdouble));
}

void JNICALL mockSetDoubleArrayRegion(JNIEnv*, jdoubleArray arr, jsize start, jsize len, const jdouble* buf) {
    if (!arr || !buf) return;
    std::memcpy(asFake(arr)->doubles.data() + start, buf, static_cast<size_t>(len) * sizeof(jdouble));
}

jobject JNICALL mockGetObjectArrayElement(JNIEnv*, jobjectArray arr, jsize index) {
    return arr ? asFake(arr)->objects[static_cast<size_t>(index)] : nullptr;
}

jobjectArray JNICALL mockNewObjectArray(JNIEnv*, jsize len, jclass, jobject init) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::ObjectArray));
    obj->objects.assign(static_cast<size_t>(len), init);
    return reinterpret_cast<jobjectArray>(obj);
}

void JNICALL mockSetObjectArrayElement(JNIEnv*, jobjectArray arr, jsize index, jobject val) {
    if (arr) asFake(arr)->objects[static_cast<size_t>(index)] = val;
}

jbyte* JNICALL mockGetByteArrayElements(JNIEnv*, jbyteArray arr, jboolean* isCopy) {
    if (isCopy) *isCopy = JNI_FALSE;
    return arr ? asFake(arr)->bytes.data() : nullptr;
}

void JNICALL mockReleaseByteArrayElements(JNIEnv*, jbyteArray, jbyte*, jint) {}

jobject JNICALL mockNewDirectByteBuffer(JNIEnv*, void* address, jlong capacity) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::DirectBuffer));
    obj->directAddress = address;
    obj->directCapacity = capacity;
    return reinterpret_cast<jobject>(obj);
}

void* JNICALL mockGetDirectBufferAddress(JNIEnv*, jobject buf) {
    return buf && asFake(buf)->kind == FakeObjKind::DirectBuffer ? asFake(buf)->directAddress : nullptr;
}

jlong JNICALL mockGetDirectBufferCapacity(JNIEnv*, jobject buf) {
    return buf && asFake(buf)->kind == FakeObjKind::DirectBuffer ? asFake(buf)->directCapacity : -1;
}

JNINativeInterface_ makeEnvTable() {
    JNINativeInterface_ t{};
    t.FindClass = mockFindClass;
    t.NewGlobalRef = mockNewGlobalRef;
    t.DeleteGlobalRef = mockDeleteGlobalRef;
    t.NewObjectV = mockNewObjectV;
    t.Throw = mockThrow;
    t.ThrowNew = mockThrowNew;
    t.ExceptionCheck = mockExceptionCheck;
    t.ExceptionClear = mockExceptionClear;
    t.DeleteLocalRef = mockDeleteLocalRef;
    t.GetMethodID = mockGetMethodID;
    t.GetStaticMethodID = mockGetStaticMethodID;
    t.CallVoidMethodV = mockCallVoidMethodV;
    t.CallStaticObjectMethodV = mockCallStaticObjectMethodV;
    t.GetFieldID = mockGetFieldID;
    t.GetObjectField = mockGetObjectField;
    t.GetBooleanField = mockGetBooleanField;
    t.GetIntField = mockGetIntField;
    t.GetLongField = mockGetLongField;
    t.GetFloatField = mockGetFloatField;
    t.GetDoubleField = mockGetDoubleField;
    t.NewStringUTF = mockNewStringUTF;
    t.GetStringUTFChars = mockGetStringUTFChars;
    t.ReleaseStringUTFChars = mockReleaseStringUTFChars;
    t.GetArrayLength = mockGetArrayLength;
    t.NewBooleanArray = mockNewBooleanArray;
    t.NewByteArray = mockNewByteArray;
    t.NewIntArray = mockNewIntArray;
    t.NewFloatArray = mockNewFloatArray;
    t.NewDoubleArray = mockNewDoubleArray;
    t.IsSameObject = mockIsSameObject;
    t.GetByteArrayElements = mockGetByteArrayElements;
    t.ReleaseByteArrayElements = mockReleaseByteArrayElements;
    t.GetByteArrayRegion = mockGetByteArrayRegion;
    t.SetBooleanArrayRegion = mockSetBooleanArrayRegion;
    t.SetByteArrayRegion = mockSetByteArrayRegion;
    t.GetIntArrayRegion = mockGetIntArrayRegion;
    t.SetIntArrayRegion = mockSetIntArrayRegion;
    t.GetFloatArrayRegion = mockGetFloatArrayRegion;
    t.SetFloatArrayRegion = mockSetFloatArrayRegion;
    t.GetDoubleArrayRegion = mockGetDoubleArrayRegion;
    t.SetDoubleArrayRegion = mockSetDoubleArrayRegion;
    t.NewObjectArray = mockNewObjectArray;
    t.GetObjectArrayElement = mockGetObjectArrayElement;
    t.SetObjectArrayElement = mockSetObjectArrayElement;
    t.NewDirectByteBuffer = mockNewDirectByteBuffer;
    t.GetDirectBufferAddress = mockGetDirectBufferAddress;
    t.GetDirectBufferCapacity = mockGetDirectBufferCapacity;
    return t;
}

JNINativeInterface_ gEnvTable = makeEnvTable();

struct LocalEnv {
    JNIEnv env;
    LocalEnv() {
        env.functions = &gEnvTable;
        gTlsException = {};
    }
    JNIEnv* ptr() { return &env; }
};

ThreadJniException consumeException() {
    auto copy = gTlsException;
    gTlsException = {};
    return copy;
}

int hostBitmapGetInfo(JNIEnv*, jobject bitmap, AndroidBitmapInfo* info) {
    if (!bitmap || !info) return ANDROID_BITMAP_RESULT_BAD_PARAMETER;
    auto* obj = asFake(bitmap);
    if (obj->kind != FakeObjKind::Bitmap) return ANDROID_BITMAP_RESULT_BAD_PARAMETER;
    info->width = obj->bitmapWidth;
    info->height = obj->bitmapHeight;
    info->stride = obj->bitmapStride;
    info->format = ANDROID_BITMAP_FORMAT_RGBA_8888;
    info->flags = 0;
    return ANDROID_BITMAP_RESULT_SUCCESS;
}

int hostBitmapLockPixels(JNIEnv*, jobject bitmap, void** addrPtr) {
    if (!bitmap || !addrPtr) return ANDROID_BITMAP_RESULT_BAD_PARAMETER;
    auto* obj = asFake(bitmap);
    if (obj->kind != FakeObjKind::Bitmap) return ANDROID_BITMAP_RESULT_BAD_PARAMETER;
    gBitmapLockCalls.fetch_add(1, std::memory_order_relaxed);
    obj->bitmapLockCount++;
    *addrPtr = obj->bitmapPixels.data();
    if (gCancelOnNextBitmapLock && gCancelSessionIdOnBitmapLock > 0) {
        gCancelOnNextBitmapLock = false;
        LocalEnv cancelEnv;
        Java_com_rawlab_android_engine_NativeProcessor_nativeCancelPreview(
            cancelEnv.ptr(), nullptr, gCancelSessionIdOnBitmapLock);
    }
    return ANDROID_BITMAP_RESULT_SUCCESS;
}

int hostBitmapUnlockPixels(JNIEnv*, jobject bitmap) {
    if (!bitmap) return ANDROID_BITMAP_RESULT_BAD_PARAMETER;
    auto* obj = asFake(bitmap);
    if (obj->kind != FakeObjKind::Bitmap) return ANDROID_BITMAP_RESULT_BAD_PARAMETER;
    gBitmapUnlockCalls.fetch_add(1, std::memory_order_relaxed);
    obj->bitmapUnlockCount++;
    return ANDROID_BITMAP_RESULT_SUCCESS;
}

RawLabHostBitmapHooks gHostBitmapHooks{
    hostBitmapGetInfo,
    hostBitmapLockPixels,
    hostBitmapUnlockPixels,
};

// ============================================================================
//  Deterministic Mock State for sony2fuji_* C ABI (ZERO sleeps!)
// ============================================================================

struct MockSessionState {
    uint64_t id = 0;
    sony2fuji_cancel_callback cancelCb = nullptr;
    void* cancelCtx = nullptr;
    sony2fuji_hdr_progress_callback progressCb = nullptr;
    void* progressCtx = nullptr;
    int activeCalls = 0;
    int maxConcurrentCalls = 0;
    int totalProcessCalls = 0;
    bool viewportRoiEnabled = false;
    bool destroyed = false;
};

struct MockHdrPairState {
    uint64_t token = 0;
    std::vector<float> hdrPixels;
    std::vector<float> sdrPixels;
    bool released = false;
};

std::mutex gCoreMutex;
std::condition_variable gCoreCv;
uint64_t gNextMockSessionId = 1;
uint64_t gNextMockToken = 1;
std::unordered_map<sony2fuji_session*, std::unique_ptr<MockSessionState>> gMockSessions;
std::unordered_map<uint64_t, std::shared_ptr<MockHdrPairState>> gMockPairs;

int gSessionDestroyCount = 0;
int gHdrPairReleaseCount = 0;
std::vector<std::string> gEventLog;

// Deterministic rendezvous controls
int gTargetConcurrentProcesses = 0;
int gActiveProcesses = 0;
int gMaxConcurrentProcesses = 0;
bool gProcessBarrierTimedOut = false;
std::set<sony2fuji_session*> gEnteredProcessSessions;

sony2fuji_session* gHoldProcessForSession = nullptr;
bool gReleaseHeldProcess = false;

int gStallAnalyzeOnWidth = 0;
bool gAnalyzeEntered = false;
bool gReleaseAnalyze = false;

int gTargetConcurrentHdrRenders = 0;
int gActiveHdrRenders = 0;
int gMaxConcurrentHdrRenders = 0;
bool gHdrRenderTimedOut = false;

uint64_t gHoldHdrExportToken = 0;
bool gHdrExportEntered = false;
bool gReleaseHdrExport = false;

// Captured C ABI payloads for marshalling verification
bool gCapturePayloads = false;
sony2fuji_render_options_v1 gCapturedRenderOptions{};
std::string gCapturedEditStateJson;
std::string gCapturedInputPath;
std::string gCapturedOutputPath;
std::string gCapturedParamsJson;
sony2fuji_hdr_render_options_v1 gCapturedHdrRenderOptions{};
std::string gCapturedHdrEditStateJson;
std::string gCapturedHdrGeometryJson;
std::string gCapturedCompatConfigJson;
sony2fuji_recipe_wb_request gCapturedRecipeWbRequest{};
std::string gCapturedRecipeWbInputPath;
std::string gCapturedMpfPath;
int32_t gMockMpfResult = 0;
sony2fuji_status gMockResolveRecipeWbStatus = SONY2FUJI_STATUS_OK;
sony2fuji_status gMockEffectiveWbStatus = SONY2FUJI_STATUS_OK;
sony2fuji_status gMockProcessStatus = SONY2FUJI_STATUS_OK;
sony2fuji_status gMockValidateLookStatus = SONY2FUJI_STATUS_OK;
sony2fuji_lut_color_state gMockLutColorState = SONY2FUJI_LUT_LEGACY_DECLARATION;
sony2fuji_unsupported_reason gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_NONE;
float gMockEffectiveWbTemp = 5500.0f;
float gMockEffectiveWbTint = 0.0f;
bool gLastProcessSawViewportRoi = false;
bool gInjectNonFiniteSdr = false;
sony2fuji_fast_gpu_query_v1 gCapturedFastGpuQuery{};
std::string gCapturedFastGpuInputPath;
std::string gCapturedFastGpuEditJson;
bool gCapturedFastGpuEditJsonPresent = false;
int32_t gMockFastGpuSupported = 1;
sony2fuji_status gMockFastGpuStatus = SONY2FUJI_STATUS_OK;

void unblockAllWaitersForCleanup() {
    std::lock_guard<std::mutex> lock(gCoreMutex);
    gTargetConcurrentProcesses = 0;
    gReleaseHeldProcess = true;
    gReleaseAnalyze = true;
    gTargetConcurrentHdrRenders = 0;
    gReleaseHdrExport = true;
    gCoreCv.notify_all();
}

struct ThreadJoiner {
    std::thread& t;
    ~ThreadJoiner() {
        if (t.joinable()) {
            unblockAllWaitersForCleanup();
            t.join();
        }
    }
};

void clearJniRegistries() {
    {
        std::lock_guard<std::mutex> lock(rawlab::jni::cancellationMutex);
        rawlab::jni::cancellationStates.clear();
    }
    {
        std::lock_guard<std::mutex> lock(rawlab::jni::sessionsMutex);
        rawlab::jni::sessions.clear();
    }
    {
        std::lock_guard<std::mutex> lock(rawlab::jni::hdrPairsMutex);
        rawlab::jni::hdrPairs.clear();
    }
}

void resetMocks() {
    *rawlabHostBitmapHooksSlot() = &gHostBitmapHooks;
    clearJniRegistries();
    gNewByteArrayCalls.store(0, std::memory_order_relaxed);
    gAllocateBitmapCalls.store(0, std::memory_order_relaxed);
    gBitmapLockCalls.store(0, std::memory_order_relaxed);
    gBitmapUnlockCalls.store(0, std::memory_order_relaxed);
    gMockBitmapStridePaddingBytes = 0;
    gMockProcessBufferStridePaddingBytes = 0;
    gMockProcessPixelSeed = 0;
    gCancelOnNextBitmapLock = false;
    gCancelSessionIdOnBitmapLock = 0;
    gMockHdrPlaneStridePaddingFloats = 0;
    gMockLensAppliedDistortion = false;
    gMockLensAppliedTca = false;
    gMockLensAppliedVignetting = false;
    std::lock_guard<std::mutex> lock(gCoreMutex);
    gMockSessions.clear();
    gMockPairs.clear();
    gSessionDestroyCount = 0;
    gHdrPairReleaseCount = 0;
    gEventLog.clear();
    gRecordedHdrProgress.clear();
    gTargetConcurrentProcesses = 0;
    gActiveProcesses = 0;
    gMaxConcurrentProcesses = 0;
    gProcessBarrierTimedOut = false;
    gEnteredProcessSessions.clear();
    gHoldProcessForSession = nullptr;
    gReleaseHeldProcess = false;
    gStallAnalyzeOnWidth = 0;
    gAnalyzeEntered = false;
    gReleaseAnalyze = false;
    gTargetConcurrentHdrRenders = 0;
    gActiveHdrRenders = 0;
    gMaxConcurrentHdrRenders = 0;
    gHdrRenderTimedOut = false;
    gHoldHdrExportToken = 0;
    gHdrExportEntered = false;
    gReleaseHdrExport = false;
    gCapturePayloads = false;
    gCapturedRenderOptions = {};
    gCapturedEditStateJson.clear();
    gCapturedInputPath.clear();
    gCapturedOutputPath.clear();
    gCapturedParamsJson.clear();
    gCapturedHdrRenderOptions = {};
    gCapturedHdrEditStateJson.clear();
    gCapturedHdrGeometryJson.clear();
    gCapturedCompatConfigJson.clear();
    gCapturedRecipeWbRequest = {};
    gCapturedRecipeWbInputPath.clear();
    gCapturedMpfPath.clear();
    gMockMpfResult = 0;
    gMockResolveRecipeWbStatus = SONY2FUJI_STATUS_OK;
    gMockEffectiveWbStatus = SONY2FUJI_STATUS_OK;
    gMockProcessStatus = SONY2FUJI_STATUS_OK;
    gMockValidateLookStatus = SONY2FUJI_STATUS_OK;
    gMockLutColorState = SONY2FUJI_LUT_LEGACY_DECLARATION;
    gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_NONE;
    gMockEffectiveWbTemp = 5500.0f;
    gMockEffectiveWbTint = 0.0f;
    gLastProcessSawViewportRoi = false;
    gInjectNonFiniteSdr = false;
    gCapturedFastGpuQuery = {};
    gCapturedFastGpuInputPath.clear();
    gCapturedFastGpuEditJson.clear();
    gCapturedFastGpuEditJsonPresent = false;
    gMockFastGpuSupported = 1;
    gMockFastGpuStatus = SONY2FUJI_STATUS_OK;
}

class SessionCallScope {
    sony2fuji_session* s_;
public:
    explicit SessionCallScope(sony2fuji_session* s) : s_(s) {
        bool valid = false;
        {
            std::lock_guard<std::mutex> lock(gCoreMutex);
            auto it = gMockSessions.find(s_);
            if (it != gMockSessions.end() && !it->second->destroyed) {
                valid = true;
                auto& st = *it->second;
                st.activeCalls++;
                if (st.activeCalls > st.maxConcurrentCalls) st.maxConcurrentCalls = st.activeCalls;
            }
        }
        require(valid, "Use-after-destroy or unknown sony2fuji_session*");
    }
    ~SessionCallScope() {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        auto it = gMockSessions.find(s_);
        if (it != gMockSessions.end()) {
            it->second->activeCalls--;
        }
    }
};

struct SessionCallbacks {
    sony2fuji_hdr_progress_callback progressCb = nullptr;
    void* progressCtx = nullptr;
    sony2fuji_cancel_callback cancelCb = nullptr;
    void* cancelCtx = nullptr;
};

SessionCallbacks snapshotSessionCallbacks(sony2fuji_session* s) {
    SessionCallbacks out{};
    if (!s) return out;
    std::lock_guard<std::mutex> lock(gCoreMutex);
    auto it = gMockSessions.find(s);
    if (it != gMockSessions.end()) {
        out.progressCb = it->second->progressCb;
        out.progressCtx = it->second->progressCtx;
        out.cancelCb = it->second->cancelCb;
        out.cancelCtx = it->second->cancelCtx;
    }
    return out;
}

template <class Fn>
sony2fuji_status runHdrWithSessionCallbacks(sony2fuji_session* s, Fn&& fn) {
    std::optional<SessionCallScope> scope;
    if (s) scope.emplace(s);
    const auto callbacks = snapshotSessionCallbacks(s);
    if (callbacks.cancelCb && callbacks.cancelCb(callbacks.cancelCtx)) {
        return SONY2FUJI_STATUS_CANCELLED;
    }
    if (callbacks.progressCb) {
        callbacks.progressCb(callbacks.progressCtx, 0, 1000);
    }
    const sony2fuji_status status = fn();
    if (status == SONY2FUJI_STATUS_OK && callbacks.progressCb) {
        callbacks.progressCb(callbacks.progressCtx, 1000, 1000);
    }
    return status;
}

} // namespace

struct sony2fuji_session {
    uint64_t magic = 0x53455353;
};

struct sony2fuji_hsl_probe {
    int dummy = 0;
};

extern "C" {

sony2fuji_status sony2fuji_session_create(sony2fuji_session** out_session) {
    auto* ptr = new sony2fuji_session{};
    std::lock_guard<std::mutex> lock(gCoreMutex);
    auto st = std::make_unique<MockSessionState>();
    st->id = gNextMockSessionId++;
    gMockSessions.emplace(ptr, std::move(st));
    *out_session = ptr;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_destroy(sony2fuji_session* session) {
    if (!session) return SONY2FUJI_STATUS_OK;
    bool known = false;
    bool idle = false;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        auto it = gMockSessions.find(session);
        if (it != gMockSessions.end()) {
            known = true;
            idle = (it->second->activeCalls == 0);
            if (idle) {
                it->second->destroyed = true;
                gMockSessions.erase(it);
                gSessionDestroyCount++;
                gEventLog.push_back("session_destroy");
            }
        }
    }
    require(known, "sony2fuji_session_destroy called on unknown session");
    require(idle, "sony2fuji_session_destroy called while call in flight");
    gCoreCv.notify_all();
    delete session;
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_set_gpu_config(sony2fuji_session* s, const sony2fuji_gpu_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_lens_database(sony2fuji_session* s, const char*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_display_lens_metadata(sony2fuji_session* s, const sony2fuji_lens_metadata*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_lens_correction_v2(sony2fuji_session* s, const sony2fuji_lens_correction_config_v2*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_tone_curves(sony2fuji_session* s, const sony2fuji_tone_curve_set_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_tone_curve(sony2fuji_session* s, const sony2fuji_tone_curve_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_color_grading(sony2fuji_session* s, const sony2fuji_color_grading_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_tone_controls(sony2fuji_session* s, const sony2fuji_tone_controls_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_atmosphere(sony2fuji_session* s, const sony2fuji_atmosphere_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_geometry(sony2fuji_session* s, const sony2fuji_geometry_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_perspective(sony2fuji_session* s, const sony2fuji_perspective_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_get_geometry_size(const sony2fuji_session* s, uint32_t* w, uint32_t* h) {
    SessionCallScope scope(const_cast<sony2fuji_session*>(s));
    *w = 64; *h = 64;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_inspect_lens_v2(sony2fuji_session* s, const char*, sony2fuji_lens_report_v2* r,
    sony2fuji_lens_profile_v2*, uint32_t, uint32_t* count) {
    SessionCallScope scope(s);
    if (r) {
        std::memset(r, 0, sizeof(*r));
        r->base.applied_distortion = gMockLensAppliedDistortion ? 1 : 0;
        r->base.applied_tca = gMockLensAppliedTca ? 1 : 0;
        r->applied_vignetting = gMockLensAppliedVignetting ? 1 : 0;
    }
    *count = 0;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_inspect_lens_metadata_v2(sony2fuji_session* s, const sony2fuji_lens_metadata*,
    sony2fuji_lens_report_v2* r, sony2fuji_lens_profile_v2*, uint32_t, uint32_t* count) {
    SessionCallScope scope(s);
    if (r) {
        std::memset(r, 0, sizeof(*r));
        r->base.applied_distortion = gMockLensAppliedDistortion ? 1 : 0;
        r->base.applied_tca = gMockLensAppliedTca ? 1 : 0;
        r->applied_vignetting = gMockLensAppliedVignetting ? 1 : 0;
    }
    *count = 0;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_get_lens_report_v2(sony2fuji_session* s, sony2fuji_lens_report_v2* r) {
    SessionCallScope scope(s);
    std::memset(r, 0, sizeof(*r));
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_apply_params(sony2fuji_session* s, const char* recipe_json) {
    SessionCallScope scope(s);
    if (!recipe_json || !*recipe_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedParamsJson = recipe_json;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_migrate_processing_json(
    sony2fuji_session* s, const sony2fuji_render_options_v1*, const char* edit_state_json,
    sony2fuji_processing_migration_result* r) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json || !r) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    std::memset(r, 0, sizeof(*r));
    r->source_version = 2;
    r->target_version = 3;
    r->disposition = 1;
    r->evaluation_count = 20;
    r->exposure_ev = 0.75f;
    r->contrast = 1.1f;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_create_hsl_probe_json(
    sony2fuji_session* s, const sony2fuji_render_options_v1*, const char* edit_state_json,
    uint64_t, uint64_t, sony2fuji_hsl_probe** out) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json || !out) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *out = new sony2fuji_hsl_probe{};
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_cancellation_callback(sony2fuji_session* s, sony2fuji_cancel_callback cb, void* ctx) {
    SessionCallScope scope(s);
    std::lock_guard<std::mutex> lock(gCoreMutex);
    auto it = gMockSessions.find(s);
    if (it != gMockSessions.end()) {
        it->second->cancelCb = cb;
        it->second->cancelCtx = ctx;
    }
    gCoreCv.notify_all();
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_supports_fast_full_res_gpu(
    sony2fuji_session* s,
    const sony2fuji_fast_gpu_query_v1* query,
    const char* edit_state_json,
    int32_t* out_supported) {
    SessionCallScope scope(s);
    if (out_supported) *out_supported = 0;
    if (!query || !out_supported || query->version != SONY2FUJI_FAST_GPU_QUERY_V1_VERSION ||
        query->struct_size < sizeof(sony2fuji_fast_gpu_query_v1)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    if (edit_state_json && !*edit_state_json) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    std::lock_guard<std::mutex> lock(gCoreMutex);
    gCapturedFastGpuQuery = *query;
    gCapturedFastGpuInputPath = query->input_path ? query->input_path : "";
    gCapturedFastGpuEditJsonPresent = (edit_state_json != nullptr);
    gCapturedFastGpuEditJson = edit_state_json ? edit_state_json : "";
    if (gMockFastGpuStatus == SONY2FUJI_STATUS_OK) {
        *out_supported = gMockFastGpuSupported;
    }
    return gMockFastGpuStatus;
}
sony2fuji_status sony2fuji_session_set_hdr_progress_callback(sony2fuji_session* s,
    sony2fuji_hdr_progress_callback cb, void* ctx) {
    SessionCallScope scope(s);
    std::lock_guard<std::mutex> lock(gCoreMutex);
    auto it = gMockSessions.find(s);
    if (it != gMockSessions.end()) {
        it->second->progressCb = cb;
        it->second->progressCtx = ctx;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_render(
    sony2fuji_session* s, const sony2fuji_render_options_v1* options, const char* edit_state_json,
    sony2fuji_buffer* out, sony2fuji_viewport_roi_result* out_roi) {
    SessionCallScope scope(s);
    sony2fuji_cancel_callback cancelCb = nullptr;
    void* cancelCtx = nullptr;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        if (gCapturePayloads && options) {
            gCapturedRenderOptions = *options;
            gCapturedInputPath = options->input_path ? options->input_path : "";
            gCapturedOutputPath = options->output_path ? options->output_path : "";
            gCapturedEditStateJson = edit_state_json ? edit_state_json : "";
        }
        gMockSessions.at(s)->totalProcessCalls++;
        gLastProcessSawViewportRoi = (options && options->viewport_roi != nullptr && options->viewport_roi->enabled != 0);
        gActiveProcesses++;
        if (gActiveProcesses > gMaxConcurrentProcesses) gMaxConcurrentProcesses = gActiveProcesses;
        gEnteredProcessSessions.insert(s);
        cancelCb = gMockSessions.at(s)->cancelCb;
        cancelCtx = gMockSessions.at(s)->cancelCtx;
        gCoreCv.notify_all();

        if (gTargetConcurrentProcesses > 0) {
            if (!gCoreCv.wait_for(lock, std::chrono::milliseconds(1500),
                    [] { return static_cast<int>(gEnteredProcessSessions.size()) >= gTargetConcurrentProcesses; })) {
                gProcessBarrierTimedOut = true;
            }
        }
        if (gHoldProcessForSession == s) {
            gCoreCv.wait_for(lock, std::chrono::milliseconds(2000), [] { return gReleaseHeldProcess; });
            auto it = gMockSessions.find(s);
            if (it != gMockSessions.end()) {
                cancelCb = it->second->cancelCb;
                cancelCtx = it->second->cancelCtx;
            }
        }
        gActiveProcesses--;
        gEventLog.push_back("process_exit");
        gCoreCv.notify_all();
    }

    if (cancelCb && cancelCb(cancelCtx) != 0) {
        return SONY2FUJI_STATUS_CANCELLED;
    }
    if (gMockProcessStatus != SONY2FUJI_STATUS_OK) {
        return gMockProcessStatus;
    }
    if (out_roi) {
        out_roi->active = 1;
        out_roi->native_x0 = 0; out_roi->native_y0 = 0;
        out_roi->native_x1 = 2; out_roi->native_y1 = 2;
        out_roi->full_native_width = 2; out_roi->full_native_height = 2;
    }
    if (!out) return SONY2FUJI_STATUS_OK;

    const uint32_t dim = (options && options->preview_long_edge > 0) ? options->preview_long_edge : 16u;
    const uint32_t strideBytes = dim * 4u + gMockProcessBufferStridePaddingBytes;
    const size_t size = static_cast<size_t>(strideBytes) * dim;
    auto* bytes = static_cast<uint8_t*>(std::calloc(1, size));
    if (gMockProcessPixelSeed != 0 && bytes) {
        for (uint32_t y = 0; y < dim; ++y) {
            uint8_t* row = bytes + static_cast<size_t>(y) * strideBytes;
            for (uint32_t x = 0; x < dim; ++x) {
                row[x * 4 + 0] = static_cast<uint8_t>((gMockProcessPixelSeed + x + y * 3) & 0xFF);
                row[x * 4 + 1] = static_cast<uint8_t>((gMockProcessPixelSeed + x * 2 + y) & 0xFF);
                row[x * 4 + 2] = static_cast<uint8_t>((gMockProcessPixelSeed + x + y * 5) & 0xFF);
                row[x * 4 + 3] = 255;
            }
        }
    }
    out->data = bytes;
    out->size_bytes = size;
    out->width = dim;
    out->height = dim;
    out->stride_bytes = strideBytes;
    out->pixel_format = SONY2FUJI_PIXEL_RGBA8;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_preview_lut_compatibility_json(
    sony2fuji_session* s, const sony2fuji_render_options_v1* options,
    const char* edit_state_json, const char* configuration_json, sony2fuji_buffer* out) {
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedCompatConfigJson = configuration_json ? configuration_json : "";
    }
    return sony2fuji_session_render(s, options, edit_state_json, out, nullptr);
}
sony2fuji_status sony2fuji_session_estimate_auto_exposure_json(
    sony2fuji_session* s, const sony2fuji_render_options_v1*, const char*, float* ev) {
    SessionCallScope scope(s);
    *ev = 0.25f;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_get_raw_white_balance(const sony2fuji_session* s, float* t, float* tint) {
    SessionCallScope scope(const_cast<sony2fuji_session*>(s));
    *t = 5500.f; *tint = 0.f;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_get_effective_raw_white_balance(const sony2fuji_session* s, float* t, float* tint) {
    SessionCallScope scope(const_cast<sony2fuji_session*>(s));
    if (gMockEffectiveWbStatus != SONY2FUJI_STATUS_OK) return gMockEffectiveWbStatus;
    *t = gMockEffectiveWbTemp;
    *tint = gMockEffectiveWbTint;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_resolve_recipe_wb(sony2fuji_session* s, const sony2fuji_recipe_wb_request* req,
    sony2fuji_recipe_wb_result* res) {
    SessionCallScope scope(s);
    if (res) {
        *res = {};
        res->version = SONY2FUJI_RECIPE_WB_RESULT_VERSION;
        res->struct_size = sizeof(*res);
    }
    if (!req || !res) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedRecipeWbRequest = *req;
        gCapturedRecipeWbInputPath = req->input_path ? req->input_path : "";
    }
    if (gMockResolveRecipeWbStatus != SONY2FUJI_STATUS_OK) return gMockResolveRecipeWbStatus;
    res->wb_mode = (req->recipe_active && (req->custom_wb || req->tint * req->recipe_strength != 0.0f))
        ? SONY2FUJI_WB_TEMPERATURE
        : (req->custom_wb ? SONY2FUJI_WB_TEMPERATURE : SONY2FUJI_WB_CAMERA);
    res->camera_temperature = 5200.0f;
    res->camera_tint = 4.0f;
    res->camera_calibrated = 1;
    res->temperature = req->custom_wb ? req->temperature : res->camera_temperature;
    res->tint = req->recipe_active ? (res->camera_tint + req->tint * req->recipe_strength) : req->tint;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_sample_wb_probe_json(
    sony2fuji_session* s, const sony2fuji_render_options_v1* options, const char* edit_state_json,
    const sony2fuji_wb_probe_query* query, sony2fuji_wb_probe_result* out) {
    SessionCallScope scope(s);
    if (!options || !edit_state_json || !*edit_state_json || !query || !out) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    out->availability = SONY2FUJI_WB_PROBE_AVAILABLE;
    out->valid_pixel_count = query->window_size * query->window_size;
    out->rejected_overexposed_count = 0;
    out->temperature = 5420.0f;
    out->tint = -12.5f;
    return SONY2FUJI_STATUS_OK;
}
int32_t sony2fuji_inspect_sdr_jpeg_mpf(const char* path) {
    gCapturedMpfPath = path ? path : "";
    return gMockMpfResult;
}
int32_t sony2fuji_is_normal_x3f(const char*, sony2fuji_x3f_mode) { return 0; }
sony2fuji_render_backend sony2fuji_session_get_last_backend(const sony2fuji_session*) {
    return SONY2FUJI_BACKEND_CPU;
}
sony2fuji_unsupported_reason sony2fuji_session_get_unsupported_reason(const sony2fuji_session*) {
    return gMockUnsupportedReason;
}
const char* sony2fuji_session_x3f_error(const sony2fuji_session*) { return nullptr; }
void sony2fuji_release_buffer(sony2fuji_buffer* b) {
    if (b && b->data) {
        std::free(b->data);
        b->data = nullptr;
        b->size_bytes = 0;
    }
}
void sony2fuji_release_blob(sony2fuji_blob* b) {
    if (b) { b->data = nullptr; b->size_bytes = 0; }
}
const char* sony2fuji_status_message(sony2fuji_status status) {
    switch (status) {
        case SONY2FUJI_STATUS_CANCELLED: return "Cancelled";
        case SONY2FUJI_STATUS_OUT_OF_MEMORY: return "Out of memory";
        default: return "Mock status";
    }
}
sony2fuji_status sony2fuji_sample_tone_curve(const sony2fuji_tone_curve_config*, const double* x, double* y, uint32_t n) {
    std::memcpy(y, x, n * sizeof(double));
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_sample_tone_curve_v2(const sony2fuji_tone_curve_config*,
    const sony2fuji_tone_curve_parametric_config*, const double* x, double* y, uint32_t n) {
    std::memcpy(y, x, n * sizeof(double));
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_validate_look(const char*, sony2fuji_look_format* f, uint32_t* v) {
    if (f) *f = SONY2FUJI_LOOK_CUBE;
    if (v) *v = 1;
    return gMockValidateLookStatus;
}
sony2fuji_lut_color_state sony2fuji_inspect_lut_color(const char*) { return gMockLutColorState; }
sony2fuji_status sony2fuji_inspect_lut_compatibility(const char*, sony2fuji_blob*) { return SONY2FUJI_STATUS_OK; }
sony2fuji_status sony2fuji_prepare_lut_compatibility(const char*, const char*, sony2fuji_blob*) { return SONY2FUJI_STATUS_OK; }
sony2fuji_status sony2fuji_compile_dcp_with_options(const void*, size_t, const char*, const void*, size_t, uint32_t,
    sony2fuji_blob*, sony2fuji_dcp_error*) { return SONY2FUJI_STATUS_OK; }
sony2fuji_status sony2fuji_compare_lut_previews(const sony2fuji_buffer*, const sony2fuji_buffer*, const char*,
    sony2fuji_blob*) { return SONY2FUJI_STATUS_OK; }
int32_t sony2fuji_x3f_available(void) { return 1; }
sony2fuji_status sony2fuji_x3f_default_mode(const char*, sony2fuji_x3f_mode* m) {
    *m = SONY2FUJI_X3F_NORMAL;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_analyze_image(const sony2fuji_buffer* buffer, sony2fuji_gpu_mode, uint32_t* counts,
    uint32_t* shadows, uint32_t* highlights, sony2fuji_buffer*) {
    if (buffer && gStallAnalyzeOnWidth > 0 && static_cast<int>(buffer->width) == gStallAnalyzeOnWidth) {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        gAnalyzeEntered = true;
        gCoreCv.notify_all();
        gCoreCv.wait_for(lock, std::chrono::milliseconds(2000), [] { return gReleaseAnalyze; });
    }
    if (counts) std::memset(counts, 0, sizeof(uint32_t) * 768);
    if (shadows) *shadows = 0;
    if (highlights) *highlights = 0;
    return SONY2FUJI_STATUS_OK;
}
void sony2fuji_hsl_probe_destroy(sony2fuji_hsl_probe* p) { delete p; }
sony2fuji_status sony2fuji_hsl_probe_sample(const sony2fuji_hsl_probe*, const sony2fuji_hsl_probe_query*,
    sony2fuji_hsl_probe_result* out) {
    std::memset(out, 0, sizeof(*out));
    return SONY2FUJI_STATUS_OK;
}

// HDR C API mocks
sony2fuji_status sony2fuji_hdr_probe(const char*, sony2fuji_hdr_source_info_v1*, sony2fuji_hdr_diagnostic_v1*) {
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_probe_camera_raw_with_processing(const char*, sony2fuji_processing_version,
    sony2fuji_hdr_source_info_v1*, sony2fuji_hdr_diagnostic_v1*) { return SONY2FUJI_STATUS_OK; }
sony2fuji_status sony2fuji_hdr_probe_proraw(const char*, sony2fuji_hdr_source_info_v1*, sony2fuji_hdr_diagnostic_v1*) {
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_probe_look(const char*, sony2fuji_hdr_look_info_v1*, sony2fuji_hdr_diagnostic_v1*) {
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_probe_camera_profile(const char*, sony2fuji_hdr_camera_profile_info_v1*,
    sony2fuji_hdr_diagnostic_v1*) { return SONY2FUJI_STATUS_OK; }
sony2fuji_status sony2fuji_hdr_geometry_size_json(uint32_t w, uint32_t h, const sony2fuji_hdr_render_options_v1*,
    const char* edit_state_json, uint32_t* ow, uint32_t* oh, sony2fuji_hdr_diagnostic_v1*) {
    if (!edit_state_json || !*edit_state_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedHdrGeometryJson = edit_state_json;
    }
    *ow = w; *oh = h;
    return SONY2FUJI_STATUS_OK;
}

static sony2fuji_hdr_image_pair_v1 makeMockPair() {
    std::lock_guard<std::mutex> lock(gCoreMutex);
    auto pair = std::make_shared<MockHdrPairState>();
    pair->token = gNextMockToken++;
    const uint32_t hdrWidth = 2;
    const uint32_t hdrHeight = 2;
    const uint32_t hdrStrideFloats = hdrWidth * 3 + gMockHdrPlaneStridePaddingFloats;
    pair->hdrPixels.assign(static_cast<size_t>(hdrStrideFloats) * hdrHeight, 0.0f);
    pair->sdrPixels.assign(static_cast<size_t>(hdrStrideFloats) * hdrHeight, 0.0f);
    for (uint32_t y = 0; y < hdrHeight; ++y) {
        for (uint32_t x = 0; x < hdrWidth; ++x) {
            const size_t idx = static_cast<size_t>(y) * hdrStrideFloats + x * 3;
            pair->hdrPixels[idx + 0] = 1.0f + y * 0.25f + x * 0.1f;
            pair->hdrPixels[idx + 1] = 1.0f;
            pair->hdrPixels[idx + 2] = 0.5f;
            pair->sdrPixels[idx + 0] = 0.5f;
            pair->sdrPixels[idx + 1] = 0.25f;
            pair->sdrPixels[idx + 2] = 0.75f;
        }
    }
    if (gInjectNonFiniteSdr) {
        pair->sdrPixels[0] = std::numeric_limits<float>::quiet_NaN();
    }
    gMockPairs.emplace(pair->token, pair);

    sony2fuji_hdr_image_pair_v1 out{};
    out.version = SONY2FUJI_HDR_VERSION;
    out.struct_size = sizeof(out);
    out.hdr = {SONY2FUJI_HDR_VERSION, sizeof(out.hdr), pair->hdrPixels.data(), pair->hdrPixels.size() * sizeof(float),
        hdrWidth, hdrHeight, static_cast<uint32_t>(hdrStrideFloats * sizeof(float)), SONY2FUJI_HDR_RGB32F_LINEAR, SONY2FUJI_HDR_LINEAR_SRGB, 2.0f, SONY2FUJI_HDR_HEADROOM_MEASURED};
    out.sdr = {SONY2FUJI_HDR_VERSION, sizeof(out.sdr), pair->sdrPixels.data(), pair->sdrPixels.size() * sizeof(float),
        hdrWidth, hdrHeight, static_cast<uint32_t>(hdrStrideFloats * sizeof(float)), SONY2FUJI_HDR_RGB32F_LINEAR, SONY2FUJI_HDR_LINEAR_SRGB, 1.0f, SONY2FUJI_HDR_HEADROOM_MEASURED};
    out.native_width = 2; out.native_height = 2;
    out.output_native_width = 2; out.output_native_height = 2;
    out.orientation_applied = 1;
    out.source_intent = SONY2FUJI_INTENT_FINAL;
    out.render_intent = SONY2FUJI_INTENT_PREVIEW;
    out.decode_revision = 1;
    out.source_headroom = 2.0f;
    out.owner_token = pair->token;
    return out;
}

sony2fuji_status sony2fuji_hdr_decode(const char*, const sony2fuji_hdr_decode_options_v1*,
    sony2fuji_hdr_image_pair_v1* out, sony2fuji_hdr_diagnostic_v1*) {
    *out = makeMockPair();
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_decode_with_session(sony2fuji_session* s, const char* path,
    const sony2fuji_hdr_decode_options_v1* options, sony2fuji_hdr_image_pair_v1* out,
    sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return runHdrWithSessionCallbacks(s, [&] {
        return sony2fuji_hdr_decode(path, options, out, diagnostic);
    });
}
sony2fuji_status sony2fuji_hdr_decode_camera_raw_json(sony2fuji_session* s, const char*,
    const sony2fuji_hdr_decode_options_v1*, const char* edit_state_json,
    sony2fuji_hdr_image_pair_v1* out, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *out = makeMockPair();
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_decode_proraw(sony2fuji_session* s, const char*, const sony2fuji_hdr_decode_options_v1*,
    const char*, sony2fuji_hdr_image_pair_v1* out, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    *out = makeMockPair();
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_export_proraw_json(sony2fuji_session* s, const char*,
    const sony2fuji_hdr_render_options_v1*, const char* edit_state_json,
    const sony2fuji_hdr_export_config_v1*, uint32_t, const char*, const char*,
    sony2fuji_hdr_stream_result_v1*, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_render_json(sony2fuji_session* s, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_render_options_v1* options, const char* edit_state_json,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    bool validSource = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        if (gCapturePayloads) {
            if (options) gCapturedHdrRenderOptions = *options;
            gCapturedHdrEditStateJson = edit_state_json;
        }
        auto it = gMockPairs.find(source ? source->owner_token : 0);
        validSource = (it != gMockPairs.end() && !it->second->released);
        if (validSource) {
            gActiveHdrRenders++;
            if (gActiveHdrRenders > gMaxConcurrentHdrRenders) gMaxConcurrentHdrRenders = gActiveHdrRenders;
            gCoreCv.notify_all();
            if (gTargetConcurrentHdrRenders > 0) {
                if (!gCoreCv.wait_for(lock, std::chrono::milliseconds(1500),
                        [] { return gMaxConcurrentHdrRenders >= gTargetConcurrentHdrRenders; })) {
                    gHdrRenderTimedOut = true;
                }
            }
            gActiveHdrRenders--;
            gCoreCv.notify_all();
        }
    }
    require(validSource, "HDR render source released during use");
    *result = makeMockPair();
    return SONY2FUJI_STATUS_OK;
}
static void fillMockHdrRoiResult(sony2fuji_hdr_roi_result_v1* out_roi) {
    if (!out_roi) return;
    out_roi->native_x0 = 0; out_roi->native_y0 = 0;
    out_roi->native_x1 = 2; out_roi->native_y1 = 2;
    out_roi->full_native_width = 2; out_roi->full_native_height = 2;
    out_roi->is_proxy = 0;
}
sony2fuji_status sony2fuji_hdr_render_roi_json(sony2fuji_session* s, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_render_options_v1* options, const char* edit_state_json, const sony2fuji_hdr_roi_v1*,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_roi_result_v1* out_roi, sony2fuji_hdr_diagnostic_v1* diag) {
    fillMockHdrRoiResult(out_roi);
    return sony2fuji_hdr_render_json(s, source, options, edit_state_json, result, diag);
}
sony2fuji_status sony2fuji_hdr_render_camera_raw_roi_json(sony2fuji_session* s, const char*,
    const sony2fuji_hdr_render_options_v1*, const char* edit_state_json, const sony2fuji_hdr_roi_v1*,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *result = makeMockPair();
    fillMockHdrRoiResult(out_roi);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_render_file_roi_json(sony2fuji_session* s, const char*,
    const sony2fuji_hdr_render_options_v1*, const char* edit_state_json, const sony2fuji_hdr_roi_v1*,
    sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_roi_result_v1* out_roi,
    sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *result = makeMockPair();
    fillMockHdrRoiResult(out_roi);
    return SONY2FUJI_STATUS_OK;
}
void sony2fuji_hdr_clear_session_cache(sony2fuji_session* s) {
    if (s) { SessionCallScope scope(s); }
}
sony2fuji_status sony2fuji_hdr_create_hsl_probe_json(sony2fuji_session* s, const sony2fuji_hdr_image_pair_v1*,
    const sony2fuji_hdr_render_options_v1*, const char* edit_state_json, uint64_t, uint64_t,
    sony2fuji_hsl_probe** out, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    if (!edit_state_json || !*edit_state_json || !out) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *out = new sony2fuji_hsl_probe{};
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_encode_rgba8_into(
    const sony2fuji_hdr_buffer_v1* source, void* dst, uint64_t dst_size_bytes, uint64_t dst_stride_bytes) {
    if (!source || !source->data || !dst || source->width == 0 || source->height == 0) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    const uint64_t needed = static_cast<uint64_t>(source->height - 1u) * dst_stride_bytes +
        static_cast<uint64_t>(source->width) * 4u;
    if (dst_size_bytes < needed) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    for (uint32_t y = 0; y < source->height; ++y) {
        const auto* srcRow = reinterpret_cast<const float*>(
            static_cast<const uint8_t*>(source->data) + static_cast<size_t>(y) * source->stride_bytes);
        auto* dstRow = static_cast<uint8_t*>(dst) + static_cast<size_t>(y) * dst_stride_bytes;
        for (uint32_t x = 0; x < source->width; ++x) {
            for (int c = 0; c < 3; ++c) {
                const float v = srcRow[x * 3 + c];
                if (!std::isfinite(v)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
                const float clamped = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
                dstRow[x * 4 + c] = static_cast<uint8_t>(clamped * 255.0f + 0.5f);
            }
            dstRow[x * 4 + 3] = 255;
        }
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_estimate_auto_exposure(const sony2fuji_hdr_image_pair_v1*, float, float, float* ev,
    sony2fuji_hdr_diagnostic_v1*) {
    *ev = 0.0f;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_export_jpeg(const sony2fuji_hdr_image_pair_v1* image,
    const sony2fuji_hdr_export_config_v1*, const char*, sony2fuji_hdr_diagnostic_v1*) {
    const uint64_t token = image ? image->owner_token : 0;
    bool validBefore = false;
    bool validAfter = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        auto it = gMockPairs.find(token);
        validBefore = (it != gMockPairs.end() && !it->second->released);
        if (validBefore) {
            if (gHoldHdrExportToken == token) {
                gHdrExportEntered = true;
                gCoreCv.notify_all();
                gCoreCv.wait_for(lock, std::chrono::milliseconds(2000), [] { return gReleaseHdrExport; });
            }
            auto checkAfter = gMockPairs.find(token);
            validAfter = (checkAfter != gMockPairs.end() && !checkAfter->second->released);
        }
    }
    require(validBefore, "HDR export_jpeg source released before/during export");
    require(validAfter, "HDR export_jpeg UAF on owner_token");
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_export_jpeg_with_session(sony2fuji_session* s,
    const sony2fuji_hdr_image_pair_v1* image, const sony2fuji_hdr_export_config_v1* config,
    const char* path, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return runHdrWithSessionCallbacks(s, [&] {
        return sony2fuji_hdr_export_jpeg(image, config, path, diagnostic);
    });
}
sony2fuji_status sony2fuji_hdr_export_sdr(const sony2fuji_hdr_image_pair_v1*, const sony2fuji_hdr_sdr_export_config_v1*,
    const char*, sony2fuji_hdr_diagnostic_v1*) { return SONY2FUJI_STATUS_OK; }
sony2fuji_status sony2fuji_hdr_export_sdr_with_session(sony2fuji_session* s,
    const sony2fuji_hdr_image_pair_v1* image, const sony2fuji_hdr_sdr_export_config_v1* config,
    const char* path, sony2fuji_hdr_diagnostic_v1* diagnostic) {
    return runHdrWithSessionCallbacks(s, [&] {
        return sony2fuji_hdr_export_sdr(image, config, path, diagnostic);
    });
}
void sony2fuji_hdr_release_pair(sony2fuji_hdr_image_pair_v1* image) {
    if (!image || image->owner_token == 0) return;
    std::lock_guard<std::mutex> lock(gCoreMutex);
    auto it = gMockPairs.find(image->owner_token);
    if (it != gMockPairs.end()) {
        it->second->released = true;
        gMockPairs.erase(it);
        gHdrPairReleaseCount++;
    }
    image->owner_token = 0;
    gCoreCv.notify_all();
}

} // extern "C"

namespace {

sony2fuji_session* singleLiveSessionPtr() {
    sony2fuji_session* ptr = nullptr;
    size_t count = 0;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        count = gMockSessions.size();
        if (count == 1) ptr = gMockSessions.begin()->first;
    }
    require(count == 1, "Expected 1 mock session");
    return ptr;
}

jobject callNativeProcess(JNIEnv* env, jlong id, const std::string& path, jint edge, jlong generation,
    jobject reusableBitmap = nullptr) {
    return Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(
        env, nullptr, id,
        makeJString(R"({"schema_version":17,"processing":{"family":"rawlab","version":3,"quality":"standard"}})"),
        makeJString(path), nullptr, 0, 0, 0,
        nullptr, 0, edge, 0, JNI_FALSE, edge > 0 ? JNI_TRUE : JNI_FALSE, reusableBitmap, generation, nullptr);
}

jobject callNativeAutoExposure(JNIEnv* env, jlong id, const std::string& path) {
    Java_com_rawlab_android_engine_NativeProcessor_nativeAutoExposure(
        env, nullptr, id,
        makeJString(R"({"schema_version":17,"processing":{"family":"rawlab","version":3,"quality":"standard"}})"),
        makeJString(path), nullptr, 0, 0, 0);
    return nullptr;
}

// ----------------------------------------------------------------------------
// Test 1: Two independent sessions invoke nativeProcess concurrently
// ----------------------------------------------------------------------------
void testCrossSessionProcessConcurrency() {
    resetMocks();
    LocalEnv envMain;
    const jlong s1 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    const jlong s2 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    require(s1 > 0 && s2 > 0 && s1 != s2, "Failed to create two distinct sessions");

    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gTargetConcurrentProcesses = 2;
    }

    jobject frame1 = nullptr, frame2 = nullptr;
    ThreadJniException ex1{}, ex2{};

    std::thread t1([&] {
        LocalEnv env;
        frame1 = callNativeProcess(env.ptr(), s1, "a.dng", 64, -1);
        ex1 = consumeException();
    });
    ThreadJoiner j1{t1};

    bool entered = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        entered = gCoreCv.wait_for(lock, std::chrono::milliseconds(1500),
            [] { return !gEnteredProcessSessions.empty(); });
    }
    require(entered, "Session 1 never entered sony2fuji_process");

    std::thread t2([&] {
        LocalEnv env;
        frame2 = callNativeProcess(env.ptr(), s2, "b.dng", 64, -1);
        ex2 = consumeException();
    });
    ThreadJoiner j2{t2};

    t1.join();
    t2.join();

    require(!gProcessBarrierTimedOut,
        "Global sessionsMutex serialized independent sessions inside sony2fuji_process (maxConcurrent=" +
        std::to_string(gMaxConcurrentProcesses) + ")");
    require(gMaxConcurrentProcesses == 2,
        "Expected 2 concurrent sessions in sony2fuji_process, got " + std::to_string(gMaxConcurrentProcesses));
    require(!ex1.active && !ex2.active, "Concurrent sessions must not raise JNI exceptions");
    require(frame1 != nullptr && frame2 != nullptr, "Both concurrent nativeProcess calls must return frames");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s1);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s2);
    require(gSessionDestroyCount == 2, "Both sessions must be destroyed");
    std::cout << "PASS: testCrossSessionProcessConcurrency (maxConcurrentProcesses=" << gMaxConcurrentProcesses << ")" << std::endl;
}

// ----------------------------------------------------------------------------
// Test 2: Post-render histogram analysis on session A does not block session B
// ----------------------------------------------------------------------------
void testPostRenderHistogramDoesNotBlockOtherSessions() {
    resetMocks();
    LocalEnv envMain;
    const jlong s1 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    const jlong s2 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);

    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gStallAnalyzeOnWidth = 97;
    }

    jobject frame1 = nullptr;
    ThreadJniException ex1{};
    std::thread t1([&] {
        LocalEnv env;
        frame1 = callNativeProcess(env.ptr(), s1, "slow-hist.dng", 97, -1);
        ex1 = consumeException();
    });
    ThreadJoiner j1{t1};

    bool analyzeEntered = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        analyzeEntered = gCoreCv.wait_for(lock, std::chrono::milliseconds(1500), [] { return gAnalyzeEntered; });
    }
    require(analyzeEntered, "Session 1 did not enter post-render sony2fuji_analyze_image");

    // While session 1 is stalled inside histogram analysis, session 2 + session 3 must finish completely.
    std::atomic<bool> fastWorkDone{false};
    std::thread t2([&] {
        LocalEnv env;
        const jlong s3 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
        require(s3 > 0 && !env.ptr()->ExceptionCheck(), "nativeCreate blocked behind histogram");
        Java_com_rawlab_android_engine_NativeProcessor_nativeSetGpuMode(env.ptr(), nullptr, s3, 1);
        require(!env.ptr()->ExceptionCheck(), "nativeSetGpuMode blocked behind histogram");
        jobject f2 = callNativeProcess(env.ptr(), s2, "fast-preview.dng", 64, -1);
        require(f2 != nullptr && !env.ptr()->ExceptionCheck(), "Session 2 preview failed while session 1 analyzed");
        Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s3);
        {
            std::lock_guard<std::mutex> lock(gCoreMutex);
            fastWorkDone.store(true, std::memory_order_release);
            gCoreCv.notify_all();
        }
    });
    ThreadJoiner j2{t2};

    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        const bool completed = gCoreCv.wait_for(lock, std::chrono::milliseconds(1500),
            [&] { return fastWorkDone.load(std::memory_order_acquire); });
        if (!completed) {
            gReleaseAnalyze = true;
            gCoreCv.notify_all();
            lock.unlock();
            t1.join();
            t2.join();
            failTest("Session 2/3 blocked on global sessionsMutex while session 1 ran post-render histogram");
        }
        gReleaseAnalyze = true;
        gCoreCv.notify_all();
    }

    t1.join();
    t2.join();
    require(frame1 != nullptr && !ex1.active, "Stalled session 1 should succeed cleanly after histogram release");
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s1);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s2);
    std::cout << "PASS: testPostRenderHistogramDoesNotBlockOtherSessions" << std::endl;
}

// ----------------------------------------------------------------------------
// Test 3: Close while active + same-session serialization + cross-session non-blocking
// ----------------------------------------------------------------------------
void testLifecycleDestroyAndSameSessionSerialization() {
    // Part A: Same-session serialization & concurrent destroy of busy session without blocking other sessions.
    resetMocks();
    LocalEnv envMain;
    const jlong s1 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    sony2fuji_session* s1Ptr = singleLiveSessionPtr();
    const jlong s2 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);

    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gHoldProcessForSession = s1Ptr;
    }

    jobject f1 = nullptr;
    ThreadJniException ex1{};
    std::thread t1([&] {
        LocalEnv env;
        f1 = callNativeProcess(env.ptr(), s1, "busy.dng", 64, -1);
        ex1 = consumeException();
    });
    ThreadJoiner j1{t1};

    bool s1EnteredA = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        s1EnteredA = gCoreCv.wait_for(lock, std::chrono::milliseconds(1500),
            [&] { return gEnteredProcessSessions.count(s1Ptr) == 1; });
    }
    require(s1EnteredA, "Session 1 did not enter held sony2fuji_process");

    // Same-session second caller queued while s1 is busy -> must serialize cleanly (never >1 inside core!).
    std::atomic<bool> tSameReady{false};
    ThreadJniException exSame{};
    std::thread tSame([&] {
        LocalEnv env;
        tSameReady.store(true, std::memory_order_release);
        callNativeAutoExposure(env.ptr(), s1, "busy.dng");
        exSame = consumeException();
    });
    ThreadJoiner jSame{tSame};
    while (!tSameReady.load(std::memory_order_acquire)) std::this_thread::yield();
    std::this_thread::yield();

    // Release s1 after tSame is queued against s1's lock; assert strict serialization on s1Ptr.
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gReleaseHeldProcess = true;
        gCoreCv.notify_all();
    }
    t1.join();
    tSame.join();
    require(f1 != nullptr && !ex1.active && !exSame.active, "Serialized calls on same session must succeed");
    int s1MaxCalls = 0;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        s1MaxCalls = gMockSessions.at(s1Ptr)->maxConcurrentCalls;
    }
    require(s1MaxCalls == 1,
        "Same session suffered concurrent native calls! maxConcurrentCalls=" +
        std::to_string(s1MaxCalls));

    // Part B: Destroy s1 while s1 is actively inside sony2fuji_process -> s1 rejects late entrants & waits
    // ONLY on s1, while s2 and new session s3 create/process/destroy concurrently!
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gEnteredProcessSessions.clear();
        gReleaseHeldProcess = false;
        gHoldProcessForSession = s1Ptr;
        gSessionDestroyCount = 0;
    }

    std::thread tBusy([&] {
        LocalEnv env;
        f1 = callNativeProcess(env.ptr(), s1, "busy2.dng", 64, -1);
        ex1 = consumeException();
    });
    ThreadJoiner jBusy{tBusy};
    bool s1EnteredB = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        s1EnteredB = gCoreCv.wait_for(lock, std::chrono::milliseconds(1500),
            [&] { return gEnteredProcessSessions.count(s1Ptr) == 1; });
    }
    require(s1EnteredB, "Session 1 did not enter held sony2fuji_process (part B)");

    std::atomic<bool> destroyDone{false};
    std::thread tDestroy([&] {
        LocalEnv env;
        Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s1);
        destroyDone.store(true, std::memory_order_release);
    });
    ThreadJoiner jDestroy{tDestroy};

    // Wait until nativeDestroy has erased s1 from registry/cancellationStates WITHOUT waiting for tBusy.
    const auto deadline = Clock::now() + std::chrono::milliseconds(1500);
    while (Java_com_rawlab_android_engine_NativeProcessor_nativeCancellationGeneration(envMain.ptr(), nullptr, s1) != -1) {
        if (Clock::now() >= deadline) {
            {
                std::lock_guard<std::mutex> lock(gCoreMutex);
                gReleaseHeldProcess = true;
                gCoreCv.notify_all();
            }
            tBusy.join();
            tDestroy.join();
            failTest("nativeDestroy blocked on global sessionsMutex while s1 was active in sony2fuji_process");
        }
        std::this_thread::yield();
    }

    require(!destroyDone.load(std::memory_order_acquire),
        "nativeDestroy must not return while s1 is still active inside sony2fuji_process");
    int destroyCountBefore = -1;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        destroyCountBefore = gSessionDestroyCount;
    }
    require(destroyCountBefore == 0, "sony2fuji_session_destroy ran prematurely while call was still in flight");

    // Late caller on closing session s1 must immediately fail closed without blocking on s1->mutex!
    callNativeProcess(envMain.ptr(), s1, "late.dng", 64, -1);
    auto lateEx = consumeException();
    require(lateEx.active && lateEx.message == "Processor is closed",
        "Late call after nativeDestroy removal must throw Processor is closed immediately");

    // Independent s2 & s3 lifecycle & rendering must work freely while tDestroy is blocked waiting on s1->mutex!
    const jlong s3 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    require(s3 > 0 && !envMain.ptr()->ExceptionCheck(), "nativeCreate failed while s1 destroying");
    jobject f2 = callNativeProcess(envMain.ptr(), s2, "independent.dng", 64, -1);
    require(f2 != nullptr && !envMain.ptr()->ExceptionCheck(), "s2 nativeProcess failed while s1 destroying");
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s3);
    int destroyCountS3 = -1;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        destroyCountS3 = gSessionDestroyCount;
    }
    require(destroyCountS3 == 1, "s3 must destroy immediately while s1 is still busy/destroying");

    // Release busy s1; tDestroy must synchronously destroy s1Ptr before returning.
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gReleaseHeldProcess = true;
        gCoreCv.notify_all();
    }
    tBusy.join();
    tDestroy.join();
    require(destroyDone.load(), "tDestroy must finish once tBusy completes");
    require(!ex1.active && f1 != nullptr, "In-flight s1 call started before destroy should complete cleanly");
    int destroyCountS1 = -1;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        destroyCountS1 = gSessionDestroyCount;
    }
    require(destroyCountS1 == 2, "s1 sony2fuji_session_destroy must complete before nativeDestroy returns");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s2);
    require(gSessionDestroyCount == 3, "Final s2 destroy count mismatch");
    std::cout << "PASS: testLifecycleDestroyAndSameSessionSerialization" << std::endl;
}

// ----------------------------------------------------------------------------
// Test 4: Cancellation signals immediately without blocking on session or global mutex
// ----------------------------------------------------------------------------
void testCancellationUnderContention() {
    resetMocks();
    LocalEnv envMain;
    const jlong s1 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    sony2fuji_session* s1Ptr = singleLiveSessionPtr();
    const jlong gen = Java_com_rawlab_android_engine_NativeProcessor_nativeCancellationGeneration(envMain.ptr(), nullptr, s1);
    require(gen == 0, "Initial generation must be 0");

    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gHoldProcessForSession = s1Ptr;
    }

    jobject cancelledFrame = nullptr;
    ThreadJniException ex{};
    std::thread t1([&] {
        LocalEnv env;
        cancelledFrame = callNativeProcess(env.ptr(), s1, "cancel.dng", 64, gen);
        ex = consumeException();
    });
    ThreadJoiner j1{t1};

    bool registered = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        registered = gCoreCv.wait_for(lock, std::chrono::milliseconds(1500), [&] {
            auto it = gMockSessions.find(s1Ptr);
            return gEnteredProcessSessions.count(s1Ptr) == 1 && it != gMockSessions.end() && it->second->cancelCb != nullptr;
        });
    }
    require(registered, "Session 1 did not register cancellation callback inside sony2fuji_process");

    // Cancel while s1 is held in sony2fuji_process; must return immediately without blocking!
    Java_com_rawlab_android_engine_NativeProcessor_nativeCancelPreview(envMain.ptr(), nullptr, s1);
    require(Java_com_rawlab_android_engine_NativeProcessor_nativeCancellationGeneration(envMain.ptr(), nullptr, s1) == gen + 1,
        "Generation must bump immediately");

    int cancelResult = 0;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        auto* cb = gMockSessions.at(s1Ptr)->cancelCb;
        void* ctx = gMockSessions.at(s1Ptr)->cancelCtx;
        cancelResult = (cb && cb(ctx) == 1) ? 1 : 0;
        gReleaseHeldProcess = true;
        gCoreCv.notify_all();
    }
    require(cancelResult == 1, "Registered C cancellation callback must reflect bump immediately");

    t1.join();
    require(cancelledFrame == nullptr, "Cancelled render must not return a frame");
    require(ex.active && ex.className == "com/rawlab/android/engine/NativeProcessingException" &&
        ex.status == SONY2FUJI_STATUS_CANCELLED,
        "Cancelled call must throw NativeProcessingException(CANCELLED)");

    // Session stays reusable with the new generation!
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gHoldProcessForSession = nullptr;
    }
    const jlong nextGen = Java_com_rawlab_android_engine_NativeProcessor_nativeCancellationGeneration(envMain.ptr(), nullptr, s1);
    jobject nextFrame = callNativeProcess(envMain.ptr(), s1, "reuse.dng", 64, nextGen);
    auto nextEx = consumeException();
    require(nextFrame != nullptr && !nextEx.active, "Session must remain reusable after cancellation");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s1);
    std::cout << "PASS: testCancellationUnderContention" << std::endl;
}

// ----------------------------------------------------------------------------
// Test 5: Concurrent HDR render across sessions/pairs
// ----------------------------------------------------------------------------
void testHdrCrossSessionRenderConcurrency() {
    resetMocks();
    LocalEnv envMain;
    const jlong s1 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    const jlong s2 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);

    const jlong p1 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(envMain.ptr(), nullptr, 0, makeJString("hdr1.jpg"), 0, -1, nullptr);
    const jlong p2 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(envMain.ptr(), nullptr, 0, makeJString("hdr2.jpg"), 0, -1, nullptr);
    require(p1 > 0 && p2 > 0 && !consumeException().active, "Failed to decode mock HDR pairs");

    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gTargetConcurrentHdrRenders = 2;
    }

    jlong out1 = 0, out2 = 0;
    ThreadJniException hdrEx1{}, hdrEx2{};

    std::thread h1([&] {
        LocalEnv env;
        out1 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
            env.ptr(), nullptr, s1, p1, makeJString(R"({"processing":{"family":"rawlab_hdr","version":9}})"), 0, -1, nullptr);
        hdrEx1 = consumeException();
    });
    ThreadJoiner jh1{h1};
    std::thread h2([&] {
        LocalEnv env;
        out2 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
            env.ptr(), nullptr, s2, p2, makeJString(R"({"processing":{"family":"rawlab_hdr","version":9}})"), 0, -1, nullptr);
        hdrEx2 = consumeException();
    });
    ThreadJoiner jh2{h2};
    h1.join();
    h2.join();

    require(!gHdrRenderTimedOut && gMaxConcurrentHdrRenders == 2,
        "HDR renders serialized across sessions/pairs (maxConcurrentHdrRenders=" +
        std::to_string(gMaxConcurrentHdrRenders) + ")");
    require(out1 > 0 && out2 > 0 && !hdrEx1.active && !hdrEx2.active, "Both concurrent HDR renders must succeed");

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(envMain.ptr(), nullptr, out1);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(envMain.ptr(), nullptr, out2);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(envMain.ptr(), nullptr, p1);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(envMain.ptr(), nullptr, p2);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s1);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s2);
    std::cout << "PASS: testHdrCrossSessionRenderConcurrency (maxConcurrentHdrRenders=" << gMaxConcurrentHdrRenders << ")" << std::endl;
}

// ----------------------------------------------------------------------------
// Test 6: Safe concurrent nativeRelease during long HDR export without UAF
// ----------------------------------------------------------------------------
void testHdrPairReleaseDuringExportConcurrency() {
    resetMocks();
    LocalEnv envMain;
    const jlong s1 = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(envMain.ptr(), nullptr, 0);
    const jlong p1 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(envMain.ptr(), nullptr, 0, makeJString("hdr1.jpg"), 0, -1, nullptr);
    require(p1 > 0 && !consumeException().active, "Failed to decode mock HDR pair");

    uint64_t out1Token = 0;
    const jlong exportPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        envMain.ptr(), nullptr, s1, p1, makeJString(R"({"processing":{"family":"rawlab_hdr","version":9}})"), 0, -1, nullptr);
    require(exportPair > 0 && !consumeException().active, "Failed to produce exportPair");
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        uint64_t maxToken = 0;
        for (const auto& [tok, _] : gMockPairs) maxToken = std::max(maxToken, tok);
        out1Token = maxToken;
        gHoldHdrExportToken = out1Token;
        gHdrPairReleaseCount = 0;
    }

    ThreadJniException exportEx{};
    std::thread tExport([&] {
        LocalEnv env;
        Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportJpeg(
            env.ptr(), nullptr, exportPair, 0, makeJString("src.jpg"), makeJString("out.jpg"), SONY2FUJI_HDR_COLOR_SRGB, -1, nullptr);
        exportEx = consumeException();
    });
    ThreadJoiner jExport{tExport};

    bool exportEntered = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        exportEntered = gCoreCv.wait_for(lock, std::chrono::milliseconds(1500), [] { return gHdrExportEntered; });
    }
    require(exportEntered, "nativeExportJpeg did not enter sony2fuji_hdr_export_jpeg");

    // Main thread releases exportPair concurrently WITHOUT blocking on export or causing UAF!
    std::atomic<bool> releaseReturned{false};
    std::thread tRelease([&] {
        LocalEnv env;
        Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, exportPair);
        releaseReturned.store(true, std::memory_order_release);
    });
    ThreadJoiner jRelease{tRelease};
    const auto relDeadline = Clock::now() + std::chrono::milliseconds(1500);
    while (!releaseReturned.load(std::memory_order_acquire)) {
        if (Clock::now() >= relDeadline) {
            {
                std::lock_guard<std::mutex> lock(gCoreMutex);
                gReleaseHdrExport = true;
                gCoreCv.notify_all();
            }
            tRelease.join();
            tExport.join();
            failTest("nativeRelease blocked behind global hdrPairsMutex during sony2fuji_hdr_export_jpeg");
        }
        std::this_thread::yield();
    }
    tRelease.join();

    int relCountDuring = -1;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        relCountDuring = gHdrPairReleaseCount;
    }
    require(relCountDuring == 0, "sony2fuji_hdr_release_pair ran while nativeExportJpeg was still active!");

    // Subsequent lookup must fail immediately with HDR pair is closed.
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeMetadata(envMain.ptr(), nullptr, exportPair);
    auto metaEx = consumeException();
    require(metaEx.active && metaEx.message == "HDR pair is closed", "Released pair must reject new callers immediately");

    // Unblock export; verify clean completion and eventual native pair release.
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gReleaseHdrExport = true;
        gCoreCv.notify_all();
    }
    tExport.join();
    require(!exportEx.active, "In-flight HDR export must complete cleanly after concurrent nativeRelease");
    int relCountAfter = -1;
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        relCountAfter = gHdrPairReleaseCount;
    }
    require(relCountAfter == 1, "Deferred sony2fuji_hdr_release_pair must execute when export finishes");

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(envMain.ptr(), nullptr, p1);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(envMain.ptr(), nullptr, s1);
    std::cout << "PASS: testHdrPairReleaseDuringExportConcurrency" << std::endl;
}

void testNativePng16DecodeRelease() {
    clearJniRegistries();
    LocalEnv env;
    char path[] = "/tmp/rawlab-jni-png16.XXXXXX";
    const int fd = mkstemp(path);
    require(fd >= 0, "Create PNG16 JNI fixture");
    auto* file = fdopen(fd, "wb");
    require(file != nullptr, "Open PNG16 JNI fixture");
    std::unique_ptr<FILE, decltype(&std::fclose)> output(file, std::fclose);
    std::unique_ptr<spng_ctx, decltype(&spng_ctx_free)> encoder(spng_ctx_new(SPNG_CTX_ENCODER), spng_ctx_free);
    require(encoder != nullptr, "Create PNG16 fixture encoder");
    spng_ihdr header{};
    header.width = 2; header.height = 1;
    header.bit_depth = 16; header.color_type = SPNG_COLOR_TYPE_TRUECOLOR;
    const uint16_t rgb[] = {0x1234, 0x5678, 0x7a01, 0x2345, 0x6789, 0x8b02};
    require(spng_set_png_file(encoder.get(), file) == 0 &&
            spng_set_ihdr(encoder.get(), &header) == 0 &&
            spng_encode_image(encoder.get(), rgb, sizeof(rgb), SPNG_FMT_PNG, SPNG_ENCODE_FINALIZE) == 0,
            "Encode PNG16 JNI fixture");
    output.reset();
    auto buffer = Java_com_rawlab_android_raster_NativePng16_nativeDecode(
        env.ptr(), nullptr, makeJString(path), 2, 1, 2);
    std::remove(path);
    const auto ex = consumeException();
    require(buffer != nullptr && !ex.active, "nativeDecode must return owned PNG16 pixels: " + ex.message);
    require(env.ptr()->GetDirectBufferCapacity(buffer) == 16, "PNG16 JNI buffer has RGBA16 capacity");
    const auto* pixels = static_cast<const uint16_t*>(env.ptr()->GetDirectBufferAddress(buffer));
    const bool correct = pixels && pixels[0] == rgb[3] && pixels[1] == rgb[4] && pixels[2] == rgb[5] &&
        pixels[3] == 65535 && pixels[4] == rgb[0] && pixels[5] == rgb[1] && pixels[6] == rgb[2] && pixels[7] == 65535;
    Java_com_rawlab_android_raster_NativePng16_nativeRelease(env.ptr(), nullptr, buffer);
    require(correct && !env.ptr()->ExceptionCheck(), "Decode/release preserves native-endian pixels and orientation");
    std::cout << "PASS: testNativePng16DecodeRelease" << std::endl;
}

void testNativePng16LutColorConversion() {
    clearJniRegistries();
    LocalEnv env;

    // Build a pure A2B0 LUT RGB profile via lcms2 (no matrix/TRC fallback tags).
    cmsHPROFILE src = cmsCreateProfilePlaceholder(nullptr);
    cmsSetProfileVersion(src, 2.4);
    cmsSetDeviceClass(src, cmsSigDisplayClass);
    cmsSetColorSpace(src, cmsSigRgbData);
    cmsSetPCS(src, cmsSigXYZData);
    cmsCIEXYZ d50 = *cmsD50_XYZ();
    cmsWriteTag(src, cmsSigMediaWhitePointTag, &d50);
    cmsPipeline* pipe = cmsPipelineAlloc(nullptr, 3, 3);
    cmsToneCurve* linear = cmsBuildGamma(nullptr, 1.0);
    cmsToneCurve* curves[3] = {linear, linear, linear};
    cmsUInt16Number clut[2 * 2 * 2 * 3]{};
    size_t idx = 0;
    for (int r = 0; r < 2; ++r)
        for (int g = 0; g < 2; ++g)
            for (int b = 0; b < 2; ++b) {
                cmsCIEXYZ xyz{0.515102 * r + 0.291965 * g + 0.157153 * b,
                              0.241182 * r + 0.692237 * g + 0.066582 * b,
                              std::max(0.0, -0.001049 * r + 0.041882 * g + 0.784378 * b)};
                cmsFloat2XYZEncoded(&clut[idx], &xyz);
                idx += 3;
            }
    cmsPipelineInsertStage(pipe, cmsAT_END, cmsStageAllocToneCurves(nullptr, 3, curves));
    cmsPipelineInsertStage(pipe, cmsAT_END, cmsStageAllocCLut16bit(nullptr, 2, 3, 3, clut));
    cmsPipelineInsertStage(pipe, cmsAT_END, cmsStageAllocToneCurves(nullptr, 3, curves));
    cmsFreeToneCurve(linear);
    cmsWriteTag(src, cmsSigAToB0Tag, pipe);
    cmsPipelineFree(pipe);
    cmsUInt32Number iccLen = 0;
    require(cmsSaveProfileToMem(src, nullptr, &iccLen) != 0 && iccLen > 128, "Serialize A2B0 LUT ICC");
    std::vector<uint8_t> icc(iccLen);
    require(cmsSaveProfileToMem(src, icc.data(), &iccLen) != 0, "Write A2B0 LUT ICC bytes");
    cmsCloseProfile(src);

    jbyteArray jIcc = mockNewByteArray(env.ptr(), static_cast<jsize>(icc.size()));
    mockSetByteArrayRegion(env.ptr(), jIcc, 0, static_cast<jsize>(icc.size()), reinterpret_cast<const jbyte*>(icc.data()));

    std::array<uint16_t, 8> pixels = {32768, 16384, 8192, 65535, 0, 0, 0, 65535};
    jobject directBuf = mockNewDirectByteBuffer(env.ptr(), pixels.data(), sizeof(pixels));
    Java_com_rawlab_android_raster_NativePng16_nativeConvert(env.ptr(), nullptr, directBuf, jIcc);
    auto ex = consumeException();
    require(!ex.active, "Valid A2B0 LUT ICC profile must convert without JNI exception: " + ex.message);
    require(pixels[0] > 32768 && pixels[3] == 65535 && pixels[4] == 0 && pixels[7] == 65535,
        "A2B0 LUT conversion must map wide-gamut red and preserve alpha/black");

    // Reject odd-sized buffer and malformed ICC bytes via IOException.
    jobject badBuf = mockNewDirectByteBuffer(env.ptr(), pixels.data(), 6);
    Java_com_rawlab_android_raster_NativePng16_nativeConvert(env.ptr(), nullptr, badBuf, jIcc);
    ex = consumeException();
    require(ex.active && ex.className == "java/io/IOException", "Unaligned buffer capacity must throw IOException");

    jbyteArray badIcc = mockNewByteArray(env.ptr(), 32);
    Java_com_rawlab_android_raster_NativePng16_nativeConvert(env.ptr(), nullptr, directBuf, badIcc);
    ex = consumeException();
    require(ex.active && ex.className == "java/io/IOException", "Malformed ICC profile must throw IOException");
    std::cout << "PASS: testNativePng16LutColorConversion" << std::endl;
}

void testCachedJniFieldAndClassLookups() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, 0, makeJString("hdr.jpg"), 0, -1, nullptr);
    require(s > 0 && p > 0 && !consumeException().active, "Setup failed");

    // Warm the lazy JniCache with one call.
    jobject frame1 = callNativeProcess(env.ptr(), s, "warm.dng", 64, -1);
    require(frame1 != nullptr && !consumeException().active, "Warmup nativeProcess failed");

    const int findBefore = gFindClassCalls.load(std::memory_order_relaxed);
    const int fieldBefore = gGetFieldIdCalls.load(std::memory_order_relaxed);
    const int methodBefore = gGetMethodIdCalls.load(std::memory_order_relaxed);
    const int staticMethodBefore = gGetStaticMethodIdCalls.load(std::memory_order_relaxed);
    require(findBefore > 0 && methodBefore > 0 && staticMethodBefore > 0, "JniCache must initialize on first use");
    require(fieldBefore == 0, "Constructor-based DTO marshalling must perform ZERO GetFieldID calls");

    const std::string hdrJson = R"({"processing":{"family":"rawlab_hdr","version":9}})";
    jobject frame2 = callNativeProcess(env.ptr(), s, "second.dng", 64, -1);
    require(frame2 != nullptr && !consumeException().active, "Second nativeProcess failed");

    jintArray geomOut = Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(
        env.ptr(), nullptr, 400, 300, makeJString(hdrJson));
    require(geomOut != nullptr && !consumeException().active, "nativeGeometry failed");

    jlong rendered = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        env.ptr(), nullptr, s, p, makeJString(hdrJson), 256, -1, nullptr);
    require(rendered > 0 && !consumeException().active, "nativeRender failed");

    jobject hslOut = Java_com_rawlab_android_engine_NativeHDRBridge_nativeSampleHsl(
        env.ptr(), nullptr, s, p, makeJString(hdrJson), 256, 1, 2, 0.5f, 0.5f, -1);
    require(hslOut != nullptr && !consumeException().active, "nativeSampleHsl failed");

    jbyteArray fp = makeJByteArray(std::vector<jbyte>(32, 7));
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportProRAW(
        env.ptr(), nullptr, s, makeJString("in.dng"), makeJString(hdrJson), 0, JNI_TRUE, fp,
        makeJString("/tmp"), makeJString("/tmp/out.jpg"), -1, nullptr);
    require(!consumeException().active, "nativeExportProRAW failed");

    require(gFindClassCalls.load(std::memory_order_relaxed) == findBefore,
        "Cached jclass refs must eliminate repeat FindClass calls");
    require(gGetFieldIdCalls.load(std::memory_order_relaxed) == 0,
        "Zero GetFieldID calls must occur");
    require(gGetMethodIdCalls.load(std::memory_order_relaxed) == methodBefore,
        "Cached jmethodIDs must eliminate repeat GetMethodID calls");
    require(gGetStaticMethodIdCalls.load(std::memory_order_relaxed) == staticMethodBefore,
        "Cached static jmethodIDs must eliminate repeat GetStaticMethodID calls");

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, rendered);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, p);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testCachedJniFieldAndClassLookups" << std::endl;
}

void testStructuredProcessMarshalling() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    gCapturePayloads = true;

    const std::string editJson = R"({"schema_version":17,"processing":{"family":"rawlab","version":3,"quality":"standard"},"edits":{"exposure":{"mode":"preview","ev":1.75},"look":{"path":"looks/classic.cube","strength":0.75}}})";
    jintArray backendOut = makeJIntArray({-1});

    jobject res = Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(
        env.ptr(), nullptr, s,
        makeJString(editJson),
        makeJString("sample/photo.arw"), nullptr, 0, 0, 0,
        makeJString("/tmp/exported.png"), SONY2FUJI_OUTPUT_PNG, 0, 2048,
        JNI_FALSE, JNI_FALSE, nullptr, -1, backendOut);
    auto ex = consumeException();
    require(res == nullptr && !ex.active, "Export nativeProcess must succeed returning null: " + ex.message);
    require(gCapturedInputPath == "sample/photo.arw", "inputPath mismatch");
    require(gCapturedOutputPath == "/tmp/exported.png", "outputPath mismatch");
    require(gCapturedEditStateJson == editJson, "editStateJson must be forwarded verbatim");
    require(gCapturedRenderOptions.output_target == SONY2FUJI_TARGET_FILE &&
            gCapturedRenderOptions.output_format == SONY2FUJI_OUTPUT_PNG &&
            gCapturedRenderOptions.long_edge == 2048 && gCapturedRenderOptions.preview_long_edge == 0 &&
            gCapturedRenderOptions.interactive_preview == 0 && gCapturedRenderOptions.viewport_preview == 0,
        "Render options mismatch");
    require(asFake(backendOut)->ints[0] == SONY2FUJI_BACKEND_CPU, "backendOut must be populated");

    // Verify nativeMigrateProcessing returns NativeMigrationResult DTO
    jobject mig = Java_com_rawlab_android_engine_NativeProcessor_nativeMigrateProcessing(
        env.ptr(), nullptr, s, makeJString(editJson), makeJString("sample/photo.arw"), nullptr, 0, 0, 0, -1);
    ex = consumeException();
    require(mig != nullptr && !ex.active, "nativeMigrateProcessing must succeed: " + ex.message);
    require(asFake(mig)->fields["sourceVersion"].i == 2 &&
            asFake(mig)->fields["targetVersion"].i == 3 &&
            asFake(mig)->fields["disposition"].i == 1 &&
            asFake(mig)->fields["evaluationCount"].i == 20 &&
            asFake(mig)->fields["exposureEv"].f == 0.75f &&
            asFake(mig)->fields["contrast"].f == 1.1f,
        "NativeMigrationResult DTO field mismatch");

    // Null/empty editStateJson must throw IllegalArgumentException
    Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(
        env.ptr(), nullptr, s, nullptr, makeJString("sample/photo.arw"),
        nullptr, 0, 0, 0, nullptr, 0, 512, 0, JNI_FALSE, JNI_TRUE, nullptr, -1, nullptr);
    ex = consumeException();
    require(ex.active && ex.className == "java/lang/IllegalArgumentException",
        "Null editStateJson must throw IllegalArgumentException");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testStructuredProcessMarshalling" << std::endl;
}

void testStructuredHdrMarshalling() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, 0, makeJString("hdr.jpg"), 0, -1, nullptr);
    gCapturePayloads = true;

    const std::string hdrJson = R"({"schema_version":16,"processing":{"family":"rawlab_hdr","version":9,"quality":"standard"},"edits":{"exposure":{"ev":1.25},"geometry":{"quarter_turns":1}}})";
    jintArray geomRes = Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(env.ptr(), nullptr, 1000, 800, makeJString(hdrJson));
    require(geomRes != nullptr && !consumeException().active, "nativeGeometry failed");
    require(gCapturedHdrGeometryJson == hdrJson, "HDR geometry JSON marshalling mismatch");

    const jlong outPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        env.ptr(), nullptr, s, p, makeJString(hdrJson), 1024, -1, nullptr);
    auto ex = consumeException();
    require(outPair > 0 && !ex.active, "HDR JSON render failed: " + ex.message);
    require(gCapturedHdrRenderOptions.long_edge == 1024, "HDR render options long_edge mismatch");
    require(gCapturedHdrEditStateJson == hdrJson, "HDR render editStateJson mismatch");

    // Verify nativeSdrBitmap encodes finite pixels into Bitmap via sony2fuji_hdr_encode_rgba8_into
    auto* sdrBmpObj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::Bitmap));
    sdrBmpObj->bitmapWidth = 2;
    sdrBmpObj->bitmapHeight = 2;
    sdrBmpObj->bitmapStride = 8;
    sdrBmpObj->bitmapPixels.assign(16, 0);
    jobject sdrBitmap = reinterpret_cast<jobject>(sdrBmpObj);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeSdrBitmap(env.ptr(), nullptr, outPair, sdrBitmap);
    ex = consumeException();
    require(!ex.active, "nativeSdrBitmap finite encode failed: " + ex.message);
    require(asFake(sdrBitmap)->bitmapPixels[0] == 128 && asFake(sdrBitmap)->bitmapPixels[3] == 255,
        "sony2fuji_hdr_encode_rgba8_into encoded pixels mismatch");

    // Verify non-finite SDR float rejects via HDRProcessingException
    gInjectNonFiniteSdr = true;
    const jlong badPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        env.ptr(), nullptr, s, p, makeJString(hdrJson), 1024, -1, nullptr);
    gInjectNonFiniteSdr = false;
    require(badPair > 0 && !consumeException().active, "Setup badPair failed");
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeSdrBitmap(env.ptr(), nullptr, badPair, sdrBitmap);
    ex = consumeException();
    require(ex.active && ex.className == "com/rawlab/android/engine/HDRProcessingException" &&
            ex.unsupportedReason == SONY2FUJI_HDR_REASON_NONFINITE,
        "Non-finite SDR buffer must throw HDRProcessingException(NONFINITE)");

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, badPair);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, outPair);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, p);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testStructuredHdrMarshalling" << std::endl;
}

void testAbiDelegationRecipeWbAndMpf() {
    resetMocks();
    LocalEnv env;
    gMockMpfResult = 2;
    const jint mpf = Java_com_rawlab_android_raster_NativeMpf_nativeInspectSdrJpegMpf(
        env.ptr(), nullptr, makeJString("/tmp/mpf_photo.jpg"));
    require(mpf == 2 && gCapturedMpfPath == "/tmp/mpf_photo.jpg",
        "nativeInspectSdrJpegMpf must delegate directly to sony2fuji_inspect_sdr_jpeg_mpf");

    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    gCapturePayloads = true;
    gMockEffectiveWbTemp = 6500.f;
    gMockEffectiveWbTint = 0.f;

    jobject previewFrame = callNativeProcess(env.ptr(), s, "sample/recipe.arw", 64, -1);
    auto ex = consumeException();
    require(previewFrame != nullptr && !ex.active, "Preview nativeProcess must succeed: " + ex.message);
    const auto& frameFields = asFake(previewFrame)->fields;
    require(frameFields.at("rawTemperature").f == 6500.f && frameFields.at("rawTint").f == 0.f,
        "NativeFrame WB must come from sony2fuji_session_get_effective_raw_white_balance");

    // Verify LUT validation DTO and LUTColorContractException on invalid LUT color contract
    jobject lookValid = Java_com_rawlab_android_engine_NativeLookBridge_validate(env.ptr(), nullptr, makeJString("ok.cube"));
    ex = consumeException();
    require(lookValid != nullptr && !ex.active &&
            asFake(lookValid)->fields["format"].i == SONY2FUJI_LOOK_CUBE &&
            asFake(lookValid)->fields["colorState"].i == SONY2FUJI_LUT_LEGACY_DECLARATION,
        "NativeLookValidation DTO mismatch");

    gMockValidateLookStatus = SONY2FUJI_STATUS_UNSUPPORTED;
    gMockLutColorState = SONY2FUJI_LUT_MISSING_COLOR;
    Java_com_rawlab_android_engine_NativeLookBridge_validate(env.ptr(), nullptr, makeJString("missing_color.cube"));
    ex = consumeException();
    require(ex.active && ex.className == "com/rawlab/android/engine/LUTColorContractException" &&
            ex.status == SONY2FUJI_LUT_MISSING_COLOR,
        "Invalid LUT color contract must throw LUTColorContractException with reason");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testAbiDelegationRecipeWbAndMpf" << std::endl;
}

void testForceGpuUnsupportedExceptionMarshalling() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 2);

    gMockProcessStatus = SONY2FUJI_STATUS_UNSUPPORTED;
    gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_FORCE_GPU;
    callNativeProcess(env.ptr(), s, "force-gpu.dng", 64, -1);
    ThreadJniException ex = consumeException();
    require(ex.active && ex.className == "com/rawlab/android/engine/NativeProcessingException",
        "UNSUPPORTED status must throw NativeProcessingException");
    require(ex.status == SONY2FUJI_STATUS_UNSUPPORTED &&
            ex.unsupportedReason == SONY2FUJI_UNSUPPORTED_FORCE_GPU,
        "Force GPU unsupported failure must marshal SONY2FUJI_UNSUPPORTED_FORCE_GPU");

    gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_NONE;
    callNativeProcess(env.ptr(), s, "force-gpu.dng", 64, -1);
    ex = consumeException();
    require(ex.active && ex.className == "com/rawlab/android/engine/NativeProcessingException",
        "Generic UNSUPPORTED status must also throw NativeProcessingException");
    require(ex.status == SONY2FUJI_STATUS_UNSUPPORTED &&
            ex.unsupportedReason == SONY2FUJI_UNSUPPORTED_NONE,
        "Generic unsupported failure must preserve SONY2FUJI_UNSUPPORTED_NONE");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testForceGpuUnsupportedExceptionMarshalling" << std::endl;
}

void testBitmapBackedPreviewZeroByteArrayAndPaddedStride() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);

    // Padded source buffer AND padded Bitmap stride, non-zero pixel pattern.
    gMockProcessBufferStridePaddingBytes = 12;
    gMockBitmapStridePaddingBytes = 20;
    gMockProcessPixelSeed = 17;
    gNewByteArrayCalls.store(0, std::memory_order_relaxed);
    gAllocateBitmapCalls.store(0, std::memory_order_relaxed);
    gBitmapLockCalls.store(0, std::memory_order_relaxed);
    gBitmapUnlockCalls.store(0, std::memory_order_relaxed);

    jobject frame = callNativeProcess(env.ptr(), s, "padded.dng", 12, -1);
    auto ex = consumeException();
    require(frame != nullptr && !ex.active, "Bitmap-backed nativeProcess must succeed: " + ex.message);
    require(gNewByteArrayCalls.load() == 0,
        "Bitmap-backed preview must allocate ZERO jbyteArrays, got " + std::to_string(gNewByteArrayCalls.load()));
    require(gAllocateBitmapCalls.load() == 1, "nativeProcess must invoke NativeFrame.allocateBitmap");
    require(gBitmapLockCalls.load() == 1 && gBitmapUnlockCalls.load() == 1,
        "nativeProcess must lock and unlock Bitmap pixels symmetrically");

    jobject bmp = asFake(frame)->fields.at("bitmap").l;
    require(bmp != nullptr && asFake(bmp)->kind == FakeObjKind::Bitmap, "NativeFrame must hold backing Bitmap");
    const auto* fakeBmp = asFake(bmp);
    require(fakeBmp->bitmapWidth == 12 && fakeBmp->bitmapHeight == 12, "Bitmap dimensions mismatch");
    require(fakeBmp->bitmapLockCount == 1 && fakeBmp->bitmapUnlockCount == 1, "Per-bitmap lock/unlock mismatch");
    for (uint32_t y = 0; y < 12; ++y) {
        const uint8_t* row = fakeBmp->bitmapPixels.data() + static_cast<size_t>(y) * fakeBmp->bitmapStride;
        for (uint32_t x = 0; x < 12; ++x) {
            const uint8_t r = static_cast<uint8_t>((17 + x + y * 3) & 0xFF);
            const uint8_t g = static_cast<uint8_t>((17 + x * 2 + y) & 0xFF);
            const uint8_t b = static_cast<uint8_t>((17 + x + y * 5) & 0xFF);
            require(row[x * 4 + 0] == r && row[x * 4 + 1] == g && row[x * 4 + 2] == b && row[x * 4 + 3] == 255,
                "Padded-stride pixel mismatch in Bitmap");
        }
    }

    // Passing reusableBitmap directly reuses the exact same Bitmap object.
    gMockProcessPixelSeed = 41;
    jobject reusedFrame = callNativeProcess(env.ptr(), s, "padded.dng", 12, -1, bmp);
    ex = consumeException();
    require(reusedFrame != nullptr && !ex.active, "Reusable bitmap nativeProcess must succeed");
    require(gNewByteArrayCalls.load() == 0, "Reusable bitmap preview must perform ZERO NewByteArray allocations");
    require(asFake(reusedFrame)->fields.at("bitmap").l == bmp, "Reusable bitmap must be reused in place");
    require(asFake(bmp)->bitmapPixels[0] == 41, "Reusable bitmap must receive updated pixels");

    // nativeCompatibilityPreview uses Bitmap-backed NativeFrame and routes null vs non-null configuration.
    gCapturePayloads = true;
    gMockProcessPixelSeed = 73;
    const jstring compatJson = makeJString(R"({"processing":{"family":"rawlab","version":3},"edits":{"exposure":{"mode":"scene","ev":0.0},"look":{"path":"look.cube","strength":0.8}}})");
    jobject compatFrame = Java_com_rawlab_android_engine_NativeProcessor_nativeCompatibilityPreview(
        env.ptr(), nullptr, s, compatJson, makeJString("compat.dng"), nullptr, 0, 0, 0, nullptr);
    ex = consumeException();
    require(compatFrame != nullptr && !ex.active, "nativeCompatibilityPreview must succeed: " + ex.message);
    require(gNewByteArrayCalls.load() == 0, "nativeCompatibilityPreview must perform ZERO NewByteArray allocations");
    jobject compatBmp = asFake(compatFrame)->fields.at("bitmap").l;
    require(compatBmp != nullptr && asFake(compatBmp)->kind == FakeObjKind::Bitmap &&
            asFake(compatBmp)->bitmapPixels[0] == 73,
        "nativeCompatibilityPreview must write directly into NativeFrame Bitmap");

    jobject compatCfgFrame = Java_com_rawlab_android_engine_NativeProcessor_nativeCompatibilityPreview(
        env.ptr(), nullptr, s, compatJson, makeJString("compat.dng"), nullptr, 0, 0, 0,
        makeJString(R"({"variant":"reference"})"));
    ex = consumeException();
    require(compatCfgFrame != nullptr && !ex.active &&
            gCapturedCompatConfigJson == R"({"variant":"reference"})",
        "nativeCompatibilityPreview with configuration must forward JSON to sony2fuji_preview_lut_compatibility_json");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testBitmapBackedPreviewZeroByteArrayAndPaddedStride" << std::endl;
}

void testBitmapPreviewMidCopyCancellationUnlocksSymmetrically() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    const jlong gen = Java_com_rawlab_android_engine_NativeProcessor_nativeCancellationGeneration(env.ptr(), nullptr, s);
    gCancelOnNextBitmapLock = true;
    gCancelSessionIdOnBitmapLock = s;

    jobject frame = callNativeProcess(env.ptr(), s, "cancel-copy.dng", 16, gen);
    auto ex = consumeException();
    require(frame == nullptr && ex.active &&
            ex.className == "com/rawlab/android/engine/NativeProcessingException" &&
            ex.status == SONY2FUJI_STATUS_CANCELLED,
        "Mid-copy cancellation must throw NativeProcessingException(CANCELLED)");
    require(gBitmapLockCalls.load() == 1 && gBitmapUnlockCalls.load() == 1,
        "Mid-copy cancellation must unlock Bitmap pixels via RAII guard");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testBitmapPreviewMidCopyCancellationUnlocksSymmetrically" << std::endl;
}

void testNativePlaneDirectCopyAndMetadataInspection() {
    resetMocks();
    LocalEnv env;
    gMockHdrPlaneStridePaddingFloats = 6; // padded float stride
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, 0, makeJString("hdr.jpg"), 0, -1, nullptr);
    require(p > 0 && !consumeException().active, "Setup HDR pair failed");

    jfloatArray hdrPlane = Java_com_rawlab_android_engine_NativeHDRBridge_nativePlane(env.ptr(), nullptr, p, JNI_TRUE);
    auto ex = consumeException();
    require(hdrPlane != nullptr && !ex.active, "Padded HDR nativePlane must succeed");
    const auto& floats = asFake(hdrPlane)->floats;
    require(floats.size() == 2 * 2 * 3, "Compacted HDR plane float count mismatch");
    require(floats[0] == 1.0f && floats[3] == 1.1f && floats[6] == 1.25f && floats[9] == 1.35f,
        "Padded HDR plane row compaction mismatch");
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, p);

    // Metadata-only lens inspection & recipe WB resolution (0 pixel decode)
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    gMockLensAppliedDistortion = true;
    gMockLensAppliedTca = false;
    gMockLensAppliedVignetting = true;
    jobject lens = Java_com_rawlab_android_engine_NativeProcessor_nativeInspectLens(
        env.ptr(), nullptr, s, makeJString(R"({"lens":{"distortion":true}})"), makeJString("raw.arw"));
    ex = consumeException();
    require(lens != nullptr && !ex.active, "nativeInspectLens must return NativeLensInspection");
    require(asFake(lens)->fields["appliedDistortion"].z == JNI_TRUE &&
            asFake(lens)->fields["appliedTca"].z == JNI_FALSE &&
            asFake(lens)->fields["appliedVignetting"].z == JNI_TRUE,
        "nativeInspectLens flags mismatch");

    gCapturePayloads = true;
    jobject wb = Java_com_rawlab_android_engine_NativeProcessor_nativeResolveCameraWhiteBalance(
        env.ptr(), nullptr, s, makeJString("raw.arw"), SONY2FUJI_PROCESSING_BASIC_V3, SONY2FUJI_X3F_NORMAL, SONY2FUJI_EXPOSURE_SCENE);
    ex = consumeException();
    require(wb != nullptr && !ex.active, "nativeResolveCameraWhiteBalance must return NativeCameraWhiteBalance");
    require(asFake(wb)->fields["temperature"].f == 5200.0f && asFake(wb)->fields["tint"].f == 4.0f,
        "nativeResolveCameraWhiteBalance values mismatch");
    require(gCapturedRecipeWbRequest.recipe_active == 1 && gCapturedRecipeWbRequest.recipe_strength == 1.0f,
        "nativeResolveCameraWhiteBalance must engage recipe_active=1 calibration");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testNativePlaneDirectCopyAndMetadataInspection" << std::endl;
}

void testHdrSessionProgressCallbackAndScopeCleanup() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    require(s > 0 && !consumeException().active, "Failed to create session for HDR progress test");
    jobject listener = makeStruct("com/rawlab/android/engine/HDRProgressListener");

    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(
        env.ptr(), nullptr, s, makeJString("hdr.jpg"), 0, -1, listener);
    require(p > 0 && !consumeException().active, "Session-scoped nativeDecode with progress listener failed");
    {
        std::lock_guard<std::mutex> jniLock(gJniMutex);
        require(gRecordedHdrProgress == std::vector<jint>({0, 1000}),
            "nativeDecode did not emit expected (0, 1000) HDR progress");
        gRecordedHdrProgress.clear();
    }
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        for (const auto& [_, st] : gMockSessions) {
            require(!st->progressCb && !st->progressCtx, "ProgressScope leaked progressCb after nativeDecode");
        }
    }

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportJpeg(
        env.ptr(), nullptr, p, s, makeJString("src.jpg"), makeJString("out.jpg"), SONY2FUJI_HDR_COLOR_SRGB, -1, listener);
    require(!consumeException().active, "Session-scoped nativeExportJpeg with progress listener failed");
    {
        std::lock_guard<std::mutex> jniLock(gJniMutex);
        require(gRecordedHdrProgress == std::vector<jint>({0, 1000}),
            "nativeExportJpeg did not emit expected (0, 1000) HDR progress");
    }
    {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        for (const auto& [_, st] : gMockSessions) {
            require(!st->progressCb && !st->progressCtx, "ProgressScope leaked progressCb after nativeExportJpeg");
        }
    }

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, p);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testHdrSessionProgressCallbackAndScopeCleanup" << std::endl;
}

void testHdrV9WithoutChannelCurvesInitializesLegacyChannels() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, 0, makeJString("hdr.jpg"), 0, -1, nullptr);
    gCapturePayloads = true;

    const std::string v9Json = R"({"schema_version":16,"processing":{"family":"rawlab_hdr","version":9,"quality":"standard"},"edits":{"tone":{"curve":{"mode":"legacy","apply_to_luminosity":true}}}})";
    const jlong outPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        env.ptr(), nullptr, s, p, makeJString(v9Json), 1024, -1, nullptr);
    auto ex = consumeException();
    require(outPair > 0 && !ex.active, "v9 HDR JSON render failed: " + ex.message);
    require(gCapturedHdrEditStateJson == v9Json && gCapturedHdrRenderOptions.long_edge == 1024, "v9 HDR JSON payload mismatch");
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, outPair);

    // Verify nativeSampleParametricValue JNI entrypoint
    {
        jdoubleArray paramArr = makeJDoubleArray({10.0, -5.0, 4.0, 20.0, 0.25, 0.50, 0.75});
        const jdouble sampled = Java_com_rawlab_android_engine_ToneCurveSampling_nativeSampleParametricValue(
            env.ptr(), nullptr, paramArr, 0.3);
        ex = consumeException();
        require(!ex.active && sampled == 0.3, "nativeSampleParametricValue mock failed: " + ex.message);
    }

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, p);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testHdrV9WithoutChannelCurvesInitializesLegacyChannels" << std::endl;
}

void testHdrV9GradingV2AndWbProbe() {
    resetMocks();
    gCapturePayloads = true;
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, 0, makeJString("hdr_v9.jpg"), 0, -1, nullptr);
    require(p > 0, "HDR decode for v9 test failed");

    const jlong outPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        env.ptr(), nullptr, s, p, makeJString(R"({"schema_version":16,"processing":{"family":"rawlab_hdr","version":9}})"), 0, -1, nullptr);
    auto ex = consumeException();
    require(outPair > 0 && !ex.active, "v9 HDR render failed: " + ex.message);

    jobject wbProbe = Java_com_rawlab_android_engine_NativeProcessor_nativeSampleWbProbe(
        env.ptr(), nullptr, s,
        makeJString(R"({"schema_version":17,"processing":{"family":"rawlab","version":3}})"),
        makeJString("wb_probe.dng"), nullptr, 0, 0, 0, 1024, 0.5f, 0.5f, 9, -1);
    ex = consumeException();
    require(wbProbe != nullptr && !ex.active, "nativeSampleWbProbe failed: " + ex.message);
    require(asFake(wbProbe)->fields["availability"].i == static_cast<jint>(SONY2FUJI_WB_PROBE_AVAILABLE) &&
            asFake(wbProbe)->fields["temperature"].f == 5420.0f &&
            asFake(wbProbe)->fields["tint"].f == -12.5f &&
            asFake(wbProbe)->fields["validPixelCount"].i == 81,
        "NativeWbProbeResult DTO mismatch");

    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, outPair);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRelease(env.ptr(), nullptr, p);
    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testHdrV9GradingV2AndWbProbe" << std::endl;
}

void testNativeProcessRoiClearsViewportRoiForSubsequentProcess() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    require(s > 0 && !consumeException().active, "Failed to create session for ROI scope test");

    jobject roiResult = Java_com_rawlab_android_engine_NativeProcessor_nativeProcessRoi(
        env.ptr(), nullptr, s,
        makeJString(R"({"schema_version":17,"processing":{"family":"rawlab","version":3}})"),
        makeJString("photo.arw"), nullptr, 0, 0, 0, 0.25f, 0.25f, 0.50f, 0.50f, 1024, -1);
    auto ex = consumeException();
    require(roiResult != nullptr && !ex.active, "nativeProcessRoi must succeed: " + ex.message);
    require(gLastProcessSawViewportRoi, "nativeProcessRoi must pass viewport_roi to sony2fuji_session_render");
    jobject bounds = asFake(roiResult)->fields["bounds"].l;
    require(bounds != nullptr && asFake(bounds)->fields["x1"].i == 2 && asFake(bounds)->fields["fullWidth"].i == 2,
        "NativeRoiBounds DTO mismatch");

    jobject fullFrame = callNativeProcess(env.ptr(), s, "photo.arw", 512, -1);
    ex = consumeException();
    require(fullFrame != nullptr && !ex.active, "Subsequent nativeProcess must succeed: " + ex.message);
    require(!gLastProcessSawViewportRoi, "Subsequent nativeProcess must have null viewport_roi on render options");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testNativeProcessRoiClearsViewportRoiForSubsequentProcess" << std::endl;
}

void testInspectionJniRoundTripAndPaddedBitmapHooks() {
    resetMocks();
    LocalEnv env;

    // 1. Geometry projection & inferSourceSize via real photo_geometry.cpp + inspection_c.cpp
    jfloatArray srcPt = Java_com_rawlab_android_editor_inspection_InspectionNative_nativeOutputNormToSourceNorm(
        env.ptr(), nullptr, 4000, 3000,
        0.1f, 0.2f, 0.6f, 0.5f, 1, JNI_TRUE, JNI_FALSE, 7.5f, 0.35f, -0.25f,
        0.35, 0.6);
    require(srcPt != nullptr && asFake(srcPt)->floats.size() == 2, "nativeOutputNormToSourceNorm succeeds");

    jfloatArray outPt = Java_com_rawlab_android_editor_inspection_InspectionNative_nativeSourceNormToOutputNorm(
        env.ptr(), nullptr, 4000, 3000,
        0.1f, 0.2f, 0.6f, 0.5f, 1, JNI_TRUE, JNI_FALSE, 7.5f, 0.35f, -0.25f,
        static_cast<jdouble>(asFake(srcPt)->floats[0]), static_cast<jdouble>(asFake(srcPt)->floats[1]));
    require(outPt != nullptr && asFake(outPt)->floats.size() == 2, "nativeSourceNormToOutputNorm round-trips");
    require(std::abs(asFake(outPt)->floats[0] - 0.35f) < 1e-4f && std::abs(asFake(outPt)->floats[1] - 0.6f) < 1e-4f,
        "Android JNI geometry round-trip precision");

    jfloatArray croppedOut = Java_com_rawlab_android_editor_inspection_InspectionNative_nativeSourceNormToOutputNorm(
        env.ptr(), nullptr, 4000, 3000,
        0.25f, 0.25f, 0.5f, 0.5f, 0, JNI_FALSE, JNI_FALSE, 0.0f, 0.0f, 0.0f,
        0.1, 0.1);
    require(croppedOut == nullptr, "Out-of-crop source anchor returns null");

    jintArray inferred = Java_com_rawlab_android_editor_inspection_InspectionNative_nativeInferSourceSize(
        env.ptr(), nullptr, 1500, 2400,
        0.1f, 0.2f, 0.6f, 0.5f, 1, JNI_TRUE, JNI_FALSE, 7.5f, 0.35f, -0.25f);
    require(inferred != nullptr && asFake(inferred)->ints.size() == 2 &&
            asFake(inferred)->ints[0] > 0 && asFake(inferred)->ints[1] > 0,
        "nativeInferSourceSize returns positive dimensions");

    // 2. Color & overlay pixel
    jdoubleArray red = Java_com_rawlab_android_editor_inspection_InspectionNative_nativeColorFromRgb(
        env.ptr(), nullptr, 255, 0, 0);
    require(red != nullptr && asFake(red)->doubles.size() == 7, "nativeColorFromRgb returns 7 doubles");
    require(std::abs(asFake(red)->doubles[3]) < 0.01 && std::abs(asFake(red)->doubles[6] - 0.2126) < 1e-4,
        "nativeColorFromRgb HSB & luminance match core");

    jint gray50 = Java_com_rawlab_android_editor_inspection_InspectionNative_nativeOverlayPixel(
        env.ptr(), nullptr, 20, 200, 250, 5);
    require(gray50 == static_cast<jint>(0xff808080u), "nativeOverlayPixel NEUTRAL_GRAY_50");

    // 3. Padded-stride bitmap sampling ((1/3, 0.5) -> R=133) + overlay rendering via RawLabHostBitmapHooks
    const int w = 4;
    const int h = 4;
    const int stride = w * 4 + 8;
    jobject srcBmp = makeFakeBitmap(w, h, 8);
    jobject dstBmp = makeFakeBitmap(w, h, 8);
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            const size_t off = static_cast<size_t>(y) * stride + x * 4;
            asFake(srcBmp)->bitmapPixels[off + 0] = static_cast<uint8_t>(x < 2 ? 100 : 200);
            asFake(srcBmp)->bitmapPixels[off + 1] = 100;
            asFake(srcBmp)->bitmapPixels[off + 2] = static_cast<uint8_t>(x < 2 ? 100 : 50);
            asFake(srcBmp)->bitmapPixels[off + 3] = 255;
        }
    }

    jdoubleArray straddle = Java_com_rawlab_android_editor_inspection_InspectionNative_nativeSampleBitmapPatch(
        env.ptr(), nullptr, srcBmp, 1.0 / 3.0, 0.5, 1);
    require(straddle != nullptr && asFake(straddle)->doubles.size() == 7, "nativeSampleBitmapPatch succeeds");
    require(static_cast<int>(asFake(straddle)->doubles[0]) == 133, "Android padded-stride 3x3 straddle R == 133");
    require(asFake(srcBmp)->bitmapLockCount == 1 && asFake(srcBmp)->bitmapUnlockCount == 1,
        "nativeSampleBitmapPatch unlocks bitmap symmetrically");

    require(Java_com_rawlab_android_editor_inspection_InspectionNative_nativeRenderOverlay(
                env.ptr(), nullptr, srcBmp, srcBmp, 1) == JNI_FALSE,
        "nativeRenderOverlay rejects aliasing src==dst");
    require(Java_com_rawlab_android_editor_inspection_InspectionNative_nativeRenderOverlay(
                env.ptr(), nullptr, srcBmp, dstBmp, 5) == JNI_TRUE,
        "nativeRenderOverlay succeeds with padded stride");
    require(asFake(srcBmp)->bitmapLockCount == 2 && asFake(srcBmp)->bitmapUnlockCount == 2 &&
            asFake(dstBmp)->bitmapLockCount == 1 && asFake(dstBmp)->bitmapUnlockCount == 1,
        "nativeRenderOverlay unlocks both bitmaps symmetrically");
    require(asFake(dstBmp)->bitmapPixels[0] == 128 && asFake(dstBmp)->bitmapPixels[1] == 128 &&
            asFake(dstBmp)->bitmapPixels[2] == 128 && asFake(dstBmp)->bitmapPixels[3] == 255,
        "nativeRenderOverlay writes gray50 RGBA8 pixels");

    std::cout << "PASS: testInspectionJniRoundTripAndPaddedBitmapHooks" << std::endl;
}

void testViewportJniRoundTripAndSessionGuard() {
    resetMocks();
    LocalEnv env;

    // 1. nativeSupportsFastFullResGpu SessionGuard + marshalling + null vs json + error handling
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 1);
    require(s > 0 && !consumeException().active, "Failed to create session for viewport JNI test");

    gMockFastGpuSupported = 1;
    jboolean ok = Java_com_rawlab_android_engine_NativeProcessor_nativeSupportsFastFullResGpu(
        env.ptr(), nullptr, s, 0, 6000, 4000, 28000000, makeJString("photo.arw"), nullptr);
    auto ex = consumeException();
    require(ok == JNI_TRUE && !ex.active, "nativeSupportsFastFullResGpu succeeds with null editStateJson");
    require(gCapturedFastGpuQuery.version == SONY2FUJI_FAST_GPU_QUERY_V1_VERSION &&
            gCapturedFastGpuQuery.input_width == 6000 && gCapturedFastGpuQuery.input_height == 4000 &&
            gCapturedFastGpuQuery.max_pixels == 28000000 && gCapturedFastGpuInputPath == "photo.arw" &&
            !gCapturedFastGpuEditJsonPresent,
        "nativeSupportsFastFullResGpu forwarded query fields and null JSON");

    gMockFastGpuSupported = 0;
    ok = Java_com_rawlab_android_engine_NativeProcessor_nativeSupportsFastFullResGpu(
        env.ptr(), nullptr, s, 0, 6000, 4000, 12000000, nullptr,
        makeJString(R"({"schema_version":17,"processing":{"family":"rawlab","version":3}})"));
    ex = consumeException();
    require(ok == JNI_FALSE && !ex.active, "nativeSupportsFastFullResGpu returns false when core reports unsupported");
    require(gCapturedFastGpuEditJsonPresent && gCapturedFastGpuEditJson.find("schema_version") != std::string::npos,
        "nativeSupportsFastFullResGpu forwarded explicit editStateJson");

    ok = Java_com_rawlab_android_engine_NativeProcessor_nativeSupportsFastFullResGpu(
        env.ptr(), nullptr, s, 0, -1, 4000, 12000000, nullptr, nullptr);
    ex = consumeException();
    require(ok == JNI_FALSE && ex.active && ex.className == "java/lang/IllegalArgumentException",
        "nativeSupportsFastFullResGpu rejects negative dimensions with IllegalArgumentException");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    ok = Java_com_rawlab_android_engine_NativeProcessor_nativeSupportsFastFullResGpu(
        env.ptr(), nullptr, s, 0, 6000, 4000, 28000000, nullptr, nullptr);
    ex = consumeException();
    require(ok == JNI_FALSE && ex.active && ex.className == "java/lang/IllegalArgumentException",
        "nativeSupportsFastFullResGpu rejects destroyed session via SessionGuard");

    // 2. ViewportNative stateless math against REAL lutools viewport_pyramid.cpp + viewport_pyramid_c.cpp
    const double baseScale = 1600.0 / 6000.0;
    require(Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel(
                env.ptr(), nullptr, baseScale * 1.04, baseScale) == -1,
        "nativePyramidLevel returns -1 below 1.05 * baseScale");
    require(Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel(
                env.ptr(), nullptr, 0.45, baseScale) == 1,
        "nativePyramidLevel selects level 1 at 0.45");
    require(Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel(
                env.ptr(), nullptr, 1.0, baseScale) == 0,
        "nativePyramidLevel selects level 0 at 1.0");
    require(Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel(
                env.ptr(), nullptr, 0.5, 3072.0 / 8064.0) == 0,
        "nativePyramidLevel jumps to level 0 for 48MP 3072px backing");

    jdoubleArray edgeTiles = Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidTiles(
        env.ptr(), nullptr, 6000, 4000, 1024, 0, 1.0, baseScale, 0.90, 0.85, 1.0, 1.0);
    require(edgeTiles != nullptr && asFake(edgeTiles)->doubles.size() == 8, "Edge query returns 1 tile (8 doubles)");
    const auto& ed = asFake(edgeTiles)->doubles;
    require(static_cast<int>(ed[0]) == 0 && static_cast<int>(ed[1]) == 5 &&
            static_cast<int>(ed[2]) == 3 && static_cast<int>(ed[3]) == 928,
        "Edge tile (0,5,3) clamps maxOutputLongEdge to 928");

    jdoubleArray visibleOnly = Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidTiles(
        env.ptr(), nullptr, 6000, 4000, 1024, 0, 1.0, baseScale, 0.40, 0.35, 0.60, 0.65);
    jdoubleArray withRing = Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidTiles(
        env.ptr(), nullptr, 6000, 4000, 1024, 1, 1.0, baseScale, 0.40, 0.35, 0.60, 0.65);
    require(visibleOnly != nullptr && withRing != nullptr, "Center tile queries succeed");
    const size_t visCount = asFake(visibleOnly)->doubles.size() / 8;
    const size_t ringCount = asFake(withRing)->doubles.size() / 8;
    require(visCount > 0 && ringCount > visCount, "Overscan ring adds neighbor tiles strictly after visible tiles");
    for (size_t i = 0; i < asFake(visibleOnly)->doubles.size(); ++i) {
        require(std::abs(asFake(visibleOnly)->doubles[i] - asFake(withRing)->doubles[i]) < 1e-12,
            "Overscan ring preserves visible prefix identically");
    }

    jdoubleArray grid = Java_com_rawlab_android_editor_canvas_ViewportNative_nativePyramidLevel0Grid(
        env.ptr(), nullptr, 6000, 4000, 1024);
    require(grid != nullptr && asFake(grid)->doubles.size() == 24 * 8,
        "Level-0 grid for 6000x4000 @ 1024 produces 6x4=24 tiles");

    require(Java_com_rawlab_android_editor_canvas_ViewportNative_nativeDetailOverlayCovers(
                env.ptr(), nullptr, 1440, 2160, 6000, 4000, 0,
                0.38, 0.23, 0.62, 0.77,
                0.385, 0.235, 0.585, 0.685, 1.0) == JNI_TRUE,
        "nativeDetailOverlayCovers returns true inside overscan with matching density");
    require(Java_com_rawlab_android_editor_canvas_ViewportNative_nativeDetailOverlayCovers(
                env.ptr(), nullptr, 1440, 2160, 6000, 4000, 0,
                0.38, 0.23, 0.62, 0.77,
                0.35, 0.235, 0.55, 0.685, 1.0) == JNI_FALSE,
        "nativeDetailOverlayCovers returns false when panned outside tile");
    require(Java_com_rawlab_android_editor_canvas_ViewportNative_nativeDetailOverlayCovers(
                env.ptr(), nullptr, 1280, 853, 6000, 4000, 1280,
                0.2, 0.2, 0.6, 0.6,
                0.25, 0.25, 0.55, 0.55, 1.0) == JNI_TRUE,
        "nativeDetailOverlayCovers honors capped maxOutputLongEdge");

    std::cout << "PASS: testViewportJniRoundTripAndSessionGuard" << std::endl;
}

} // namespace

int main() {
    struct Case {
        const char* name;
        void (*fn)();
    };
    const Case cases[] = {
        {"testCrossSessionProcessConcurrency", testCrossSessionProcessConcurrency},
        {"testPostRenderHistogramDoesNotBlockOtherSessions", testPostRenderHistogramDoesNotBlockOtherSessions},
        {"testLifecycleDestroyAndSameSessionSerialization", testLifecycleDestroyAndSameSessionSerialization},
        {"testCancellationUnderContention", testCancellationUnderContention},
        {"testHdrCrossSessionRenderConcurrency", testHdrCrossSessionRenderConcurrency},
        {"testHdrPairReleaseDuringExportConcurrency", testHdrPairReleaseDuringExportConcurrency},
        {"testNativePng16DecodeRelease", testNativePng16DecodeRelease},
        {"testNativePng16LutColorConversion", testNativePng16LutColorConversion},
        {"testCachedJniFieldAndClassLookups", testCachedJniFieldAndClassLookups},
        {"testStructuredProcessMarshalling", testStructuredProcessMarshalling},
        {"testStructuredHdrMarshalling", testStructuredHdrMarshalling},
        {"testAbiDelegationRecipeWbAndMpf", testAbiDelegationRecipeWbAndMpf},
        {"testForceGpuUnsupportedExceptionMarshalling", testForceGpuUnsupportedExceptionMarshalling},
        {"testBitmapBackedPreviewZeroByteArrayAndPaddedStride", testBitmapBackedPreviewZeroByteArrayAndPaddedStride},
        {"testBitmapPreviewMidCopyCancellationUnlocksSymmetrically", testBitmapPreviewMidCopyCancellationUnlocksSymmetrically},
        {"testNativePlaneDirectCopyAndMetadataInspection", testNativePlaneDirectCopyAndMetadataInspection},
        {"testHdrSessionProgressCallbackAndScopeCleanup", testHdrSessionProgressCallbackAndScopeCleanup},
        {"testHdrV9WithoutChannelCurvesInitializesLegacyChannels", testHdrV9WithoutChannelCurvesInitializesLegacyChannels},
        {"testHdrV9GradingV2AndWbProbe", testHdrV9GradingV2AndWbProbe},
        {"testNativeProcessRoiClearsViewportRoiForSubsequentProcess", testNativeProcessRoiClearsViewportRoiForSubsequentProcess},
        {"testInspectionJniRoundTripAndPaddedBitmapHooks", testInspectionJniRoundTripAndPaddedBitmapHooks},
        {"testViewportJniRoundTripAndSessionGuard", testViewportJniRoundTripAndSessionGuard},
    };
    int failures = 0;
    for (const auto& c : cases) {
        try {
            c.fn();
        } catch (const std::exception& error) {
            unblockAllWaitersForCleanup();
            std::cerr << "FAIL [" << c.name << "]: " << error.what() << std::endl;
            failures++;
        }
    }
    clearJniRegistries();
    if (failures > 0) {
        std::cerr << failures << " JNI session lock test(s) FAILED" << std::endl;
        return 1;
    }
    std::cout << "ALL JNI SESSION LOCK TESTS PASSED" << std::endl;
    return 0;
}
