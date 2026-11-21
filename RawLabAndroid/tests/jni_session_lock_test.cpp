#include "../app/src/main/cpp/rawlab_jni.cpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <unistd.h>

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
    if (mid && mid->className == "com/rawlab/android/engine/NativeProcessingException") {
        obj->kind = FakeObjKind::Throwable;
        obj->intArg = va_arg(args, jint);
        auto msg = va_arg(args, jstring);
        obj->strArg = msg ? asFake(msg)->text : "";
        obj->secondIntArg = va_arg(args, jint);
    } else if (mid && mid->className == "com/rawlab/android/engine/NativeFrame") {
        (void)va_arg(args, jint); // width
        (void)va_arg(args, jint); // height
        obj->fields["bitmap"].l = va_arg(args, jobject); // backingBitmap
        obj->fields["rawTemperature"].f = static_cast<jfloat>(va_arg(args, double));
        obj->fields["rawTint"].f = static_cast<jfloat>(va_arg(args, double));
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
    int activeCalls = 0;
    int maxConcurrentCalls = 0;
    int totalProcessCalls = 0;
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
sony2fuji_request gCapturedRequest{};
std::string gCapturedInputPath;
std::string gCapturedLutPath;
std::string gCapturedOutputPath;
std::string gCapturedParamsJson;
sony2fuji_hsl_config gCapturedHsl{};
sony2fuji_wavelet_denoise_config gCapturedDenoise{};
sony2fuji_photo_effects_config gCapturedEffects{};
int32_t gCapturedInteractive = 0;
int32_t gCapturedViewport = 0;
int32_t gCapturedChromaDenoise = 0;
int gCapturedProcessingVersion = 0;
int gCapturedX3fMode = 0;
int gCapturedExposureMode = 0;
sony2fuji_hdr_request_v8 gCapturedHdrRequest{};
std::string gCapturedHdrLookPath;
sony2fuji_hdr_request_v1 gCapturedHdrGeometryRequest{};
sony2fuji_recipe_wb_request gCapturedRecipeWbRequest{};
std::string gCapturedRecipeWbInputPath;
std::string gCapturedMpfPath;
int32_t gMockMpfResult = 0;
sony2fuji_status gMockResolveRecipeWbStatus = SONY2FUJI_STATUS_OK;
sony2fuji_status gMockEffectiveWbStatus = SONY2FUJI_STATUS_OK;
sony2fuji_status gMockProcessStatus = SONY2FUJI_STATUS_OK;
sony2fuji_unsupported_reason gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_NONE;
float gMockEffectiveWbTemp = 5500.0f;
float gMockEffectiveWbTint = 0.0f;

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
        std::lock_guard<std::mutex> lock(cancellationMutex);
        cancellationStates.clear();
    }
    {
        std::lock_guard<std::mutex> lock(sessionsMutex);
        sessions.clear();
    }
    {
        std::lock_guard<std::mutex> lock(hdrPairsMutex);
        hdrPairs.clear();
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
    gCapturedRequest = {};
    gCapturedInputPath.clear();
    gCapturedLutPath.clear();
    gCapturedOutputPath.clear();
    gCapturedParamsJson.clear();
    gCapturedHsl = {};
    gCapturedDenoise = {};
    gCapturedEffects = {};
    gCapturedInteractive = 0;
    gCapturedViewport = 0;
    gCapturedChromaDenoise = 0;
    gCapturedProcessingVersion = 0;
    gCapturedX3fMode = 0;
    gCapturedExposureMode = 0;
    gCapturedHdrRequest = {};
    gCapturedHdrLookPath.clear();
    gCapturedHdrGeometryRequest = {};
    gCapturedRecipeWbRequest = {};
    gCapturedRecipeWbInputPath.clear();
    gCapturedMpfPath.clear();
    gMockMpfResult = 0;
    gMockResolveRecipeWbStatus = SONY2FUJI_STATUS_OK;
    gMockEffectiveWbStatus = SONY2FUJI_STATUS_OK;
    gMockProcessStatus = SONY2FUJI_STATUS_OK;
    gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_NONE;
    gMockEffectiveWbTemp = 5500.0f;
    gMockEffectiveWbTint = 0.0f;
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
sony2fuji_status sony2fuji_session_set_processing_version(sony2fuji_session* s, sony2fuji_processing_version v) {
    SessionCallScope scope(s);
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedProcessingVersion = static_cast<int>(v);
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_x3f_mode(sony2fuji_session* s, sony2fuji_x3f_mode m) {
    SessionCallScope scope(s);
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedX3fMode = static_cast<int>(m);
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_raw_exposure_mode(sony2fuji_session* s, sony2fuji_raw_exposure_mode m) {
    SessionCallScope scope(s);
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedExposureMode = static_cast<int>(m);
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_hsl(sony2fuji_session* s, const sony2fuji_hsl_config* cfg) {
    SessionCallScope scope(s);
    if (gCapturePayloads && cfg) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedHsl = *cfg;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* s, int32_t enabled) {
    SessionCallScope scope(s);
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedInteractive = enabled;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_viewport_preview(sony2fuji_session* s, int32_t enabled) {
    SessionCallScope scope(s);
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedViewport = enabled;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_wavelet_denoise(sony2fuji_session* s, const sony2fuji_wavelet_denoise_config* cfg) {
    SessionCallScope scope(s);
    if (gCapturePayloads && cfg) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedDenoise = *cfg;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_photo_effects(sony2fuji_session* s, const sony2fuji_photo_effects_config* cfg) {
    SessionCallScope scope(s);
    if (gCapturePayloads && cfg) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedEffects = *cfg;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_chroma_denoise(sony2fuji_session* s, int32_t mode) {
    SessionCallScope scope(s);
    if (gCapturePayloads) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedChromaDenoise = mode;
    }
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_migrate_processing(const sony2fuji_session* s, const sony2fuji_request*,
    sony2fuji_processing_migration_result* r) {
    SessionCallScope scope(const_cast<sony2fuji_session*>(s));
    std::memset(r, 0, sizeof(*r));
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_create_hsl_probe(sony2fuji_session* s, const sony2fuji_request*, uint64_t, uint64_t,
    sony2fuji_hsl_probe** out) {
    SessionCallScope scope(s);
    *out = new sony2fuji_hsl_probe{};
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_cancellation_callback(sony2fuji_session* s, sony2fuji_cancel_callback cb, void* ctx) {
    // CancellationScope calls this under SessionGuard in constructor & destructor; track call scope and record without blocking.
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
sony2fuji_status sony2fuji_process(sony2fuji_session* s, const sony2fuji_request* req, sony2fuji_buffer* out) {
    SessionCallScope scope(s);
    sony2fuji_cancel_callback cancelCb = nullptr;
    void* cancelCtx = nullptr;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        if (gCapturePayloads && req) {
            gCapturedRequest = *req;
            gCapturedInputPath = req->input_path ? req->input_path : "";
            gCapturedLutPath = req->lut_path ? req->lut_path : "";
            gCapturedOutputPath = req->output_path ? req->output_path : "";
        }
        gMockSessions.at(s)->totalProcessCalls++;
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
            // Re-read cancellation callback under lock before returning.
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

    const uint32_t dim = (req && req->preview_long_edge > 0) ? req->preview_long_edge : 16u;
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
sony2fuji_status sony2fuji_preview_lut_compatibility(sony2fuji_session* s, const sony2fuji_request* req, const char*,
    sony2fuji_buffer* out) {
    return sony2fuji_process(s, req, out);
}
sony2fuji_status sony2fuji_session_estimate_auto_exposure(sony2fuji_session* s, const sony2fuji_request*, float* ev) {
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
sony2fuji_status sony2fuji_validate_look(const char*, sony2fuji_look_format* f, uint32_t* v) {
    *f = SONY2FUJI_LOOK_CUBE; *v = 1;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_lut_color_state sony2fuji_inspect_lut_color(const char*) { return SONY2FUJI_LUT_MISSING_COLOR; }
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
sony2fuji_status sony2fuji_hdr_geometry_size(uint32_t w, uint32_t h, const sony2fuji_hdr_request_v1* req,
    uint32_t* ow, uint32_t* oh, sony2fuji_hdr_diagnostic_v1*) {
    if (gCapturePayloads && req) {
        std::lock_guard<std::mutex> lock(gCoreMutex);
        gCapturedHdrGeometryRequest = *req;
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
sony2fuji_status sony2fuji_hdr_decode_camera_raw_with_development(sony2fuji_session* s, const char*,
    const sony2fuji_hdr_decode_options_v1*, const sony2fuji_hdr_camera_development_v1*,
    sony2fuji_hdr_image_pair_v1* out, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    *out = makeMockPair();
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_decode_proraw(sony2fuji_session* s, const char*, const sony2fuji_hdr_decode_options_v1*,
    const char*, sony2fuji_hdr_image_pair_v1* out, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    *out = makeMockPair();
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_export_proraw(sony2fuji_session* s, const char*, const sony2fuji_hdr_request_v1*,
    const sony2fuji_hdr_export_config_v1*, uint32_t, const char*, const char*,
    sony2fuji_hdr_stream_result_v1*, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_hdr_render(sony2fuji_session* s, const sony2fuji_hdr_image_pair_v1* source,
    const sony2fuji_hdr_request_v1* req, sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    bool validSource = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
        if (gCapturePayloads && req) {
            std::memset(&gCapturedHdrRequest, 0, sizeof(gCapturedHdrRequest));
            const size_t copyBytes = std::min<size_t>(req->struct_size, sizeof(gCapturedHdrRequest));
            std::memcpy(&gCapturedHdrRequest, req, copyBytes);
            if (req->hdr_processing_version >= SONY2FUJI_HDR_PROCESSING_LOOK_VERSION &&
                gCapturedHdrRequest.base.look_path) {
                gCapturedHdrLookPath = gCapturedHdrRequest.base.look_path;
            } else {
                gCapturedHdrLookPath.clear();
            }
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
sony2fuji_status sony2fuji_hdr_create_hsl_probe(sony2fuji_session* s, const sony2fuji_hdr_image_pair_v1*,
    const sony2fuji_hdr_request_v1*, uint64_t, uint64_t, sony2fuji_hsl_probe** out, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    *out = new sony2fuji_hsl_probe{};
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
sony2fuji_status sony2fuji_hdr_export_sdr(const sony2fuji_hdr_image_pair_v1*, const sony2fuji_hdr_sdr_export_config_v1*,
    const char*, sony2fuji_hdr_diagnostic_v1*) { return SONY2FUJI_STATUS_OK; }
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

jobject makeNativeGeometry(jfloat cropX = 0.f, jfloat cropY = 0.f, jfloat cropW = 1.f, jfloat cropH = 1.f,
    jint turns = 0, jboolean flipH = JNI_FALSE, jboolean flipV = JNI_FALSE,
    jfloat straighten = 0.f, jfloat perspH = 0.f, jfloat perspV = 0.f) {
    jobject obj = makeStruct("com/rawlab/android/engine/NativeGeometry");
    setFloatField(obj, "cropX", cropX);
    setFloatField(obj, "cropY", cropY);
    setFloatField(obj, "cropWidth", cropW);
    setFloatField(obj, "cropHeight", cropH);
    setIntField(obj, "quarterTurns", turns);
    setBoolField(obj, "flipHorizontal", flipH);
    setBoolField(obj, "flipVertical", flipV);
    setFloatField(obj, "straightenDegrees", straighten);
    setFloatField(obj, "perspectiveHorizontal", perspH);
    setFloatField(obj, "perspectiveVertical", perspV);
    return obj;
}

jobject makeNativeToneCurve(jint mode, const std::vector<jdouble>& points) {
    jobject obj = makeStruct("com/rawlab/android/engine/NativeToneCurve");
    setIntField(obj, "mode", mode);
    setObjField(obj, "points", makeJDoubleArray(points));
    return obj;
}

jobject makeNativeHdrRenderRequest(jint longEdge = 0) {
    jobject obj = makeStruct("com/rawlab/android/engine/NativeHDRRenderRequest");
    setFloatField(obj, "exposureEv", 0.f);
    setFloatField(obj, "temperature", 6500.f);
    setFloatField(obj, "tint", 0.f);
    setFloatField(obj, "contrast", 0.f);
    setFloatField(obj, "highlights", 0.f);
    setFloatField(obj, "shadows", 0.f);
    setFloatField(obj, "saturation", 0.f);
    setObjField(obj, "geometry", makeNativeGeometry());
    setIntField(obj, "longEdge", longEdge);
    return obj;
}

jobject makeNativeProcessRequest(const std::string& path, jint edge, jlong generation) {
    jobject input = makeStruct("com/rawlab/android/engine/NativeProcessInput");
    setObjField(input, "path", makeJString(path));
    setObjField(input, "pixels", nullptr);
    setIntField(input, "width", 0);
    setIntField(input, "height", 0);
    setIntField(input, "pixelFormat", 0);

    jobject output = makeStruct("com/rawlab/android/engine/NativeProcessOutput");
    setObjField(output, "path", nullptr);
    setIntField(output, "format", 0);
    setIntField(output, "edge", edge);
    setIntField(output, "longEdge", 0);
    setBoolField(output, "interactive", JNI_FALSE);
    setBoolField(output, "viewportPreview", edge > 0 ? JNI_TRUE : JNI_FALSE);
    setObjField(output, "reusableBitmap", nullptr);

    jobject wb = makeStruct("com/rawlab/android/engine/NativeProcessWhiteBalance");
    setBoolField(wb, "custom", JNI_FALSE);
    setFloatField(wb, "temperature", 6500.f);
    setFloatField(wb, "tint", 0.f);
    setBoolField(wb, "recipeActive", JNI_FALSE);
    setFloatField(wb, "recipeStrength", 1.f);

    jobject tone = makeStruct("com/rawlab/android/engine/NativeProcessTone");
    setFloatField(tone, "exposureEv", 0.f);
    setFloatField(tone, "contrast", 1.f);
    setFloatField(tone, "highlights", 0.f);
    setFloatField(tone, "shadows", 0.f);
    setFloatField(tone, "toneCurve", 0.f);
    setFloatField(tone, "saturation", 1.f);
    setFloatField(tone, "sharpening", 0.f);

    jobject denoise = makeStruct("com/rawlab/android/engine/NativeDenoiseConfig");
    setBoolField(denoise, "enabled", JNI_FALSE);
    setFloatField(denoise, "luma", 0.f);
    setFloatField(denoise, "chroma", 46.f);
    setFloatField(denoise, "coarse", 50.f);
    setIntField(denoise, "displayChroma", 0);

    jobject effects = makeStruct("com/rawlab/android/engine/NativePhotoEffectsConfig");
    setFloatField(effects, "vignetteAmount", 0.f);
    setFloatField(effects, "vignetteMidpoint", 50.f);
    setFloatField(effects, "vignetteRoundness", 0.f);
    setFloatField(effects, "vignetteFeather", 50.f);
    setFloatField(effects, "vignetteHighlights", 0.f);
    setFloatField(effects, "grainAmount", 0.f);
    setFloatField(effects, "grainSize", 25.f);
    setFloatField(effects, "grainRoughness", 50.f);

    jobject req = makeStruct("com/rawlab/android/engine/NativeProcessRequest");
    setObjField(req, "input", input);
    setObjField(req, "output", output);
    setObjField(req, "lutPath", nullptr);
    setFloatField(req, "lutStrength", 0.f);
    setObjField(req, "whiteBalance", wb);
    setObjField(req, "tone", tone);
    setObjField(req, "denoise", denoise);
    setObjField(req, "effects", effects);
    setObjField(req, "hsl", makeJFloatArray(std::vector<jfloat>(24, 0.f)));
    setIntField(req, "exposureMode", 0);
    setIntField(req, "processingVersion", 3);
    setIntField(req, "x3fMode", 0);
    setLongField(req, "cancellationGeneration", generation);
    setObjField(req, "backendOut", nullptr);
    setObjField(req, "hslProbe", nullptr);
    setObjField(req, "migrationOut", nullptr);
    return req;
}

jobject callNativeProcess(JNIEnv* env, jlong id, const std::string& path, jint edge, jlong generation) {
    return Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(
        env, nullptr, id, makeNativeProcessRequest(path, edge, generation));
}

jobject callNativeAutoExposure(JNIEnv* env, jlong id, const std::string& path) {
    Java_com_rawlab_android_engine_NativeProcessor_nativeAutoExposure(
        env, nullptr, id,
        makeJString(path), nullptr, 0, 0, 0,
        JNI_FALSE, 6500.f, 0.f, 0, JNI_FALSE, 1.f, 3, 0);
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

    const jlong p1 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(envMain.ptr(), nullptr, makeJString("hdr1.jpg"), 0);
    const jlong p2 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(envMain.ptr(), nullptr, makeJString("hdr2.jpg"), 0);
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
            env.ptr(), nullptr, s1, p1, makeNativeHdrRenderRequest(), -1);
        hdrEx1 = consumeException();
    });
    ThreadJoiner jh1{h1};
    std::thread h2([&] {
        LocalEnv env;
        out2 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
            env.ptr(), nullptr, s2, p2, makeNativeHdrRenderRequest(), -1);
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
    const jlong p1 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(envMain.ptr(), nullptr, makeJString("hdr1.jpg"), 0);
    require(p1 > 0 && !consumeException().active, "Failed to decode mock HDR pair");

    uint64_t out1Token = 0;
    const jlong exportPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        envMain.ptr(), nullptr, s1, p1, makeNativeHdrRenderRequest(), -1);
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
            env.ptr(), nullptr, exportPair, makeJString("src.jpg"), makeJString("out.jpg"), SONY2FUJI_HDR_COLOR_SRGB);
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
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, makeJString("hdr.jpg"), 0);
    require(s > 0 && p > 0 && !consumeException().active, "Setup failed");

    // Warm the lazy JniCache with one call.
    jobject frame1 = callNativeProcess(env.ptr(), s, "warm.dng", 64, -1);
    require(frame1 != nullptr && !consumeException().active, "Warmup nativeProcess failed");

    const int findBefore = gFindClassCalls.load(std::memory_order_relaxed);
    const int fieldBefore = gGetFieldIdCalls.load(std::memory_order_relaxed);
    const int methodBefore = gGetMethodIdCalls.load(std::memory_order_relaxed);
    const int staticMethodBefore = gGetStaticMethodIdCalls.load(std::memory_order_relaxed);
    require(findBefore > 0 && fieldBefore > 0 && methodBefore > 0 && staticMethodBefore > 0, "JniCache must initialize on first use");

    // Subsequent calls across process, geometry, HDR render, HSL sample, ProRAW export must perform ZERO lookups.
    jobject frame2 = callNativeProcess(env.ptr(), s, "second.dng", 64, -1);
    require(frame2 != nullptr && !consumeException().active, "Second nativeProcess failed");

    jintArray geomOut = Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(
        env.ptr(), nullptr, 400, 300, makeNativeGeometry());
    require(geomOut != nullptr && !consumeException().active, "nativeGeometry failed");

    jlong rendered = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        env.ptr(), nullptr, s, p, makeNativeHdrRenderRequest(256), -1);
    require(rendered > 0 && !consumeException().active, "nativeRender failed");

    jfloatArray probeOut = makeJFloatArray(std::vector<jfloat>(13, 0.5f));
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeSampleHsl(
        env.ptr(), nullptr, s, p, makeNativeHdrRenderRequest(256), 1, 2, probeOut, -1);
    require(!consumeException().active, "nativeSampleHsl failed");

    jbyteArray fp = makeJByteArray(std::vector<jbyte>(32, 7));
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeExportProRAW(
        env.ptr(), nullptr, s, makeJString("in.dng"), makeNativeHdrRenderRequest(0), JNI_TRUE, fp,
        makeJString("/tmp"), makeJString("/tmp/out.jpg"), -1);
    require(!consumeException().active, "nativeExportProRAW failed");

    require(gFindClassCalls.load(std::memory_order_relaxed) == findBefore,
        "Cached jclass refs must eliminate repeat FindClass calls");
    require(gGetFieldIdCalls.load(std::memory_order_relaxed) == fieldBefore,
        "Cached jfieldIDs must eliminate repeat GetFieldID calls");
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

    jobject req = makeNativeProcessRequest("photo.arw", 512, -1);
    jobject output = mockGetObjectField(env.ptr(), req, nullptr);
    (void)output;
    // Build a fully populated structured request
    jobject inObj = makeStruct("com/rawlab/android/engine/NativeProcessInput");
    setObjField(inObj, "path", makeJString("sample/photo.arw"));
    setObjField(inObj, "pixels", nullptr);
    setIntField(inObj, "width", 0);
    setIntField(inObj, "height", 0);
    setIntField(inObj, "pixelFormat", 0);

    jobject outObj = makeStruct("com/rawlab/android/engine/NativeProcessOutput");
    setObjField(outObj, "path", makeJString("/tmp/exported.png"));
    setIntField(outObj, "format", SONY2FUJI_OUTPUT_PNG);
    setIntField(outObj, "edge", 0);
    setIntField(outObj, "longEdge", 2048);
    setBoolField(outObj, "interactive", JNI_FALSE);
    setBoolField(outObj, "viewportPreview", JNI_FALSE);

    jobject wbObj = makeStruct("com/rawlab/android/engine/NativeProcessWhiteBalance");
    setBoolField(wbObj, "custom", JNI_TRUE);
    setFloatField(wbObj, "temperature", 5400.f);
    setFloatField(wbObj, "tint", -12.5f);
    setBoolField(wbObj, "recipeActive", JNI_FALSE);
    setFloatField(wbObj, "recipeStrength", 1.f);

    jobject toneObj = makeStruct("com/rawlab/android/engine/NativeProcessTone");
    setFloatField(toneObj, "exposureEv", 1.75f);
    setFloatField(toneObj, "contrast", 1.35f);
    setFloatField(toneObj, "highlights", -0.45f);
    setFloatField(toneObj, "shadows", 0.30f);
    setFloatField(toneObj, "toneCurve", -0.25f);
    setFloatField(toneObj, "saturation", 1.20f);
    setFloatField(toneObj, "sharpening", 0.85f);

    jobject denoiseObj = makeStruct("com/rawlab/android/engine/NativeDenoiseConfig");
    setBoolField(denoiseObj, "enabled", JNI_TRUE);
    setFloatField(denoiseObj, "luma", 18.f);
    setFloatField(denoiseObj, "chroma", 64.f);
    setFloatField(denoiseObj, "coarse", 75.f);
    setIntField(denoiseObj, "displayChroma", 2);

    jobject effectsObj = makeStruct("com/rawlab/android/engine/NativePhotoEffectsConfig");
    setFloatField(effectsObj, "vignetteAmount", -22.f);
    setFloatField(effectsObj, "vignetteMidpoint", 40.f);
    setFloatField(effectsObj, "vignetteRoundness", 15.f);
    setFloatField(effectsObj, "vignetteFeather", 65.f);
    setFloatField(effectsObj, "vignetteHighlights", 30.f);
    setFloatField(effectsObj, "grainAmount", 25.f);
    setFloatField(effectsObj, "grainSize", 45.f);
    setFloatField(effectsObj, "grainRoughness", 60.f);

    std::vector<jfloat> hslVec(24);
    for (int i = 0; i < 24; ++i) hslVec[i] = static_cast<jfloat>(i - 10);
    jintArray backendOut = makeJIntArray({-1});

    setObjField(req, "input", inObj);
    setObjField(req, "output", outObj);
    setObjField(req, "lutPath", makeJString("looks/classic.cube"));
    setFloatField(req, "lutStrength", 0.75f);
    setObjField(req, "whiteBalance", wbObj);
    setObjField(req, "tone", toneObj);
    setObjField(req, "denoise", denoiseObj);
    setObjField(req, "effects", effectsObj);
    setObjField(req, "hsl", makeJFloatArray(hslVec));
    setIntField(req, "exposureMode", SONY2FUJI_EXPOSURE_PREVIEW);
    setIntField(req, "processingVersion", SONY2FUJI_PROCESSING_BASIC_V3);
    setIntField(req, "x3fMode", SONY2FUJI_X3F_NORMAL);
    setObjField(req, "backendOut", backendOut);

    const char* kParamsJson = R"({"schema_version":7,"processing":{"family":"rawlab","version":3,"quality":"standard"}})";
    Java_com_rawlab_android_engine_NativeProcessor_nativeApplyParams(env.ptr(), nullptr, s, makeJString(kParamsJson));
    auto applyEx = consumeException();
    require(!applyEx.active, "nativeApplyParams must succeed: " + applyEx.message);
    require(gCapturedParamsJson == kParamsJson, "nativeApplyParams payload mismatch");

    jobject res = Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
    auto ex = consumeException();
    require(res == nullptr && !ex.active, "Export nativeProcess must succeed returning null: " + ex.message);
    require(gCapturedInputPath == "sample/photo.arw", "inputPath mismatch");
    require(gCapturedLutPath == "looks/classic.cube", "lutPath mismatch");
    require(gCapturedOutputPath == "/tmp/exported.png", "outputPath mismatch");
    require(gCapturedRequest.lut_strength == 0.75f, "lutStrength mismatch");
    require(gCapturedRequest.wb_mode == SONY2FUJI_WB_TEMPERATURE &&
            gCapturedRequest.temperature == 5400.f && gCapturedRequest.tint == -12.5f, "WB mismatch");
    require(gCapturedRequest.exposure_ev == 1.75f && gCapturedRequest.contrast == 1.35f &&
            gCapturedRequest.highlights == -0.45f && gCapturedRequest.shadows == 0.30f &&
            gCapturedRequest.tone_curve == -0.25f && gCapturedRequest.saturation == 1.20f &&
            gCapturedRequest.sharpening == 0.85f, "Tone mismatch (no JNI product math allowed)");
    require(gCapturedRequest.output_target == SONY2FUJI_TARGET_FILE &&
            gCapturedRequest.output_format == SONY2FUJI_OUTPUT_PNG &&
            gCapturedRequest.long_edge == 2048 && gCapturedRequest.preview_long_edge == 0, "Output mismatch");
    require(gCapturedInteractive == 0 && gCapturedViewport == 0, "Preview flags mismatch");
    require(asFake(backendOut)->ints[0] == SONY2FUJI_BACKEND_CPU, "backendOut must be populated");

    // Empty recipe JSON must throw IllegalArgumentException without mutating captured state.
    Java_com_rawlab_android_engine_NativeProcessor_nativeApplyParams(env.ptr(), nullptr, s, makeJString(""));
    ex = consumeException();
    require(ex.active && ex.className == "java/lang/IllegalArgumentException", "Empty recipe JSON must throw");
    require(gCapturedParamsJson == kParamsJson, "Failed nativeApplyParams must not overwrite captured state");

    // Null request must throw IllegalArgumentException
    Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, nullptr);
    ex = consumeException();
    require(ex.active && ex.className == "java/lang/IllegalArgumentException", "Null request must throw IllegalArgumentException");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testStructuredProcessMarshalling" << std::endl;
}

void testStructuredHdrMarshalling() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 0);
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, makeJString("hdr.jpg"), 0);
    gCapturePayloads = true;

    jobject geom = makeNativeGeometry(0.1f, 0.2f, 0.8f, 0.7f, 1, JNI_TRUE, JNI_FALSE, -3.5f, 0.25f, -0.15f);
    jintArray geomRes = Java_com_rawlab_android_engine_NativeHDRBridge_nativeGeometry(env.ptr(), nullptr, 1000, 800, geom);
    require(geomRes != nullptr && !consumeException().active, "nativeGeometry failed");
    require(gCapturedHdrGeometryRequest.crop_x == 0.1f && gCapturedHdrGeometryRequest.crop_y == 0.2f &&
            gCapturedHdrGeometryRequest.crop_width == 0.8f && gCapturedHdrGeometryRequest.crop_height == 0.7f &&
            gCapturedHdrGeometryRequest.quarter_turns == 1 && gCapturedHdrGeometryRequest.flip_horizontal == 1 &&
            gCapturedHdrGeometryRequest.flip_vertical == 0 && gCapturedHdrGeometryRequest.straighten_degrees == -3.5f &&
            gCapturedHdrGeometryRequest.perspective_horizontal == 0.25f &&
            gCapturedHdrGeometryRequest.perspective_vertical == -0.15f, "Geometry marshalling mismatch");

    jobject req = makeNativeHdrRenderRequest(1024);
    setFloatField(req, "exposureEv", 1.25f);
    setFloatField(req, "temperature", 7200.f);
    setFloatField(req, "tint", 18.f);
    setFloatField(req, "contrast", -30.f);
    setFloatField(req, "highlights", 40.f);
    setFloatField(req, "shadows", -20.f);
    setFloatField(req, "saturation", 15.f);
    setObjField(req, "geometry", geom);

    jobject toneObj = makeStruct("com/rawlab/android/engine/NativeHDRTone");
    setFloatField(toneObj, "blackPoint", -15.f);
    setFloatField(toneObj, "whitePoint", 25.f);
    setFloatField(toneObj, "curveStrength", 45.f);
    setObjField(toneObj, "curve", makeNativeToneCurve(1, {0.0, 0.0, 0.5, 0.65, 1.0, 1.0}));
    setObjField(req, "tone", toneObj);

    jobject gradingObj = makeStruct("com/rawlab/android/engine/NativeColorGrading");
    setFloatField(gradingObj, "shadowsHue", 10.f);
    setFloatField(gradingObj, "shadowsSaturation", 20.f);
    setFloatField(gradingObj, "midtonesHue", 30.f);
    setFloatField(gradingObj, "midtonesSaturation", 40.f);
    setFloatField(gradingObj, "highlightsHue", 50.f);
    setFloatField(gradingObj, "highlightsSaturation", 60.f);

    std::vector<jfloat> hdrHsl(24);
    for (int i = 0; i < 24; ++i) hdrHsl[i] = static_cast<jfloat>(i + 1);
    jobject colorObj = makeStruct("com/rawlab/android/engine/NativeHDRColor");
    setFloatField(colorObj, "vibrance", 22.f);
    setObjField(colorObj, "hsl", makeJFloatArray(hdrHsl));
    setObjField(colorObj, "grading", gradingObj);
    setObjField(req, "color", colorObj);

    jobject rendObj = makeStruct("com/rawlab/android/engine/NativeHDRRendition");
    setFloatField(rendObj, "peakLimitEv", 2.5f);
    setFloatField(rendObj, "sdrExposureEv", -0.5f);
    setFloatField(rendObj, "sdrContrast", 12.f);
    setFloatField(rendObj, "sdrSaturation", -8.f);
    setObjField(req, "rendition", rendObj);

    jobject fxObj = makeStruct("com/rawlab/android/engine/NativePhotoEffectsConfig");
    setFloatField(fxObj, "vignetteAmount", -10.f);
    setFloatField(fxObj, "vignetteMidpoint", 55.f);
    setFloatField(fxObj, "vignetteRoundness", 5.f);
    setFloatField(fxObj, "vignetteFeather", 45.f);
    setFloatField(fxObj, "vignetteHighlights", 15.f);
    setFloatField(fxObj, "grainAmount", 12.f);
    setFloatField(fxObj, "grainSize", 30.f);
    setFloatField(fxObj, "grainRoughness", 70.f);
    setObjField(req, "effects", fxObj);

    jobject detailObj = makeStruct("com/rawlab/android/engine/NativeHDRDetail");
    setFloatField(detailObj, "sharpening", 1.1f);
    setFloatField(detailObj, "clarity", 0.35f);
    setFloatField(detailObj, "dehaze", -0.25f);
    setFloatField(detailObj, "denoise", 0.5f);
    setObjField(req, "detail", detailObj);

    const std::string sha(64, 'a');
    jobject lookObj = makeStruct("com/rawlab/android/engine/NativeHDRLook");
    setObjField(lookObj, "path", makeJString("/tmp/look.cube"));
    setObjField(lookObj, "sha256", makeJString(sha));
    setFloatField(lookObj, "strength", 0.9f);
    setObjField(req, "look", lookObj);

    jobject chObj = makeStruct("com/rawlab/android/engine/NativeHDRChannelCurves");
    setObjField(chObj, "red", makeNativeToneCurve(1, {0.0, 0.0, 0.5, 0.7, 1.0, 1.0}));
    setObjField(chObj, "green", makeNativeToneCurve(0, {}));
    setObjField(chObj, "blue", makeNativeToneCurve(1, {0.0, 0.0, 1.0, 1.0}));
    setObjField(req, "channelCurves", chObj);

    const jlong outPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(env.ptr(), nullptr, s, p, req, -1);
    auto ex = consumeException();
    require(outPair > 0 && !ex.active, "Full v8 HDR render failed: " + ex.message);

    const auto& v8 = gCapturedHdrRequest;
    const auto& v7 = v8.base;
    const auto& v6 = v7.base;
    const auto& v5 = v6.base;
    const auto& v4 = v5.base;
    const auto& v3 = v4.base;
    const auto& v2 = v3.base;
    const auto& v1 = v2.base;
    require(v1.struct_size == sizeof(sony2fuji_hdr_request_v8), "HDR struct_size mismatch");
    require(v1.hdr_processing_version == SONY2FUJI_HDR_PROCESSING_CHANNEL_CURVES_VERSION, "HDR version mismatch");
    require(v1.exposure_ev == 1.25f && v1.temperature == 7200.f && v1.contrast == -30.f && v1.long_edge == 1024,
        "HDR v1 fields mismatch");
    require(v2.black_point == -15.f && v2.white_point == 25.f && v2.curve_strength == 45.f &&
            v2.curve.mode == SONY2FUJI_CURVE_CUSTOM && v2.curve.count == 3 && v2.curve.points[1].y == 0.65,
        "HDR v2 tone/curve mismatch");
    require(v3.vibrance == 22.f && v3.hsl.hue[0] == 1.f && v3.hsl.lightness[7] == 24.f &&
            v3.grading.highlights_saturation == 60.f, "HDR v3 color mismatch");
    require(v4.peak_limit_ev == 2.5f && v4.sdr_exposure_ev == -0.5f &&
            v4.sdr_contrast == 12.f && v4.sdr_saturation == -8.f, "HDR v4 rendition mismatch");
    require(v5.effects.vignette_amount == -10.f && v5.effects.grain_roughness == 70.f, "HDR v5 effects mismatch");
    require(v6.sharpening == 1.1f && v6.clarity == 0.35f && v6.dehaze == -0.25f && v6.denoise == 0.5f,
        "HDR v6 detail mismatch");
    require(gCapturedHdrLookPath == "/tmp/look.cube" && v7.look_strength == 0.9f &&
            std::string(v7.look_sha256, 64) == sha, "HDR v7 look mismatch");
    require(v8.channels[0].mode == SONY2FUJI_CURVE_CUSTOM && v8.channels[0].count == 3 &&
            v8.channels[0].points[1].y == 0.7 && v8.channels[1].mode == SONY2FUJI_CURVE_LEGACY &&
            v8.channels[2].count == 2, "HDR v8 channel curves mismatch");

    // Out-of-order section (color != null while tone == null) must throw IllegalArgumentException
    jobject badReq = makeNativeHdrRenderRequest(0);
    setObjField(badReq, "color", colorObj);
    Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(env.ptr(), nullptr, s, p, badReq, -1);
    ex = consumeException();
    require(ex.active && ex.className == "java/lang/IllegalArgumentException",
        "Out-of-order HDR sections must throw IllegalArgumentException");

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
    gMockEffectiveWbTemp = 5200.f;
    gMockEffectiveWbTint = 4.f;

    jobject req = makeStruct("com/rawlab/android/engine/NativeProcessRequest");
    jobject inObj = makeStruct("com/rawlab/android/engine/NativeProcessInput");
    setObjField(inObj, "path", makeJString("sample/recipe.arw"));
    setObjField(inObj, "pixels", nullptr);
    jobject outObj = makeStruct("com/rawlab/android/engine/NativeProcessOutput");
    setObjField(outObj, "path", makeJString("/tmp/recipe_out.png"));
    setIntField(outObj, "format", SONY2FUJI_OUTPUT_PNG);
    setIntField(outObj, "edge", 0);
    setIntField(outObj, "longEdge", 1024);
    jobject wbObj = makeStruct("com/rawlab/android/engine/NativeProcessWhiteBalance");
    setBoolField(wbObj, "custom", JNI_FALSE);
    setFloatField(wbObj, "temperature", 6500.f);
    setFloatField(wbObj, "tint", 12.f);
    setBoolField(wbObj, "recipeActive", JNI_TRUE);
    setFloatField(wbObj, "recipeStrength", 0.5f);
    jobject toneObj = makeStruct("com/rawlab/android/engine/NativeProcessTone");
    setFloatField(toneObj, "contrast", 1.f);
    setFloatField(toneObj, "saturation", 1.f);
    jobject denoiseObj = makeStruct("com/rawlab/android/engine/NativeDenoiseConfig");
    jobject effectsObj = makeStruct("com/rawlab/android/engine/NativePhotoEffectsConfig");
    setObjField(req, "input", inObj);
    setObjField(req, "output", outObj);
    setObjField(req, "whiteBalance", wbObj);
    setObjField(req, "tone", toneObj);
    setObjField(req, "denoise", denoiseObj);
    setObjField(req, "effects", effectsObj);
    setIntField(req, "exposureMode", SONY2FUJI_EXPOSURE_PREVIEW);
    setIntField(req, "processingVersion", SONY2FUJI_PROCESSING_BASIC_V3);
    setIntField(req, "x3fMode", SONY2FUJI_X3F_NORMAL);

    Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
    auto ex = consumeException();
    require(!ex.active, "Calibrated recipe process must succeed: " + ex.message);
    require(gCapturedRecipeWbInputPath == "sample/recipe.arw" &&
            gCapturedRecipeWbRequest.processing_version == SONY2FUJI_PROCESSING_BASIC_V3 &&
            gCapturedRecipeWbRequest.x3f_mode == SONY2FUJI_X3F_NORMAL &&
            gCapturedRecipeWbRequest.exposure_mode == SONY2FUJI_EXPOSURE_PREVIEW &&
            gCapturedRecipeWbRequest.recipe_active == 1 &&
            gCapturedRecipeWbRequest.recipe_strength == 0.5f,
        "JNI must forward recipe WB params into sony2fuji_session_resolve_recipe_wb");
    require(gCapturedRequest.wb_mode == SONY2FUJI_WB_TEMPERATURE &&
            gCapturedRequest.temperature == 5200.f && gCapturedRequest.tint == 10.f,
        "JNI must use C ABI resolved recipe temperature/tint");

    // UNSUPPORTED from C ABI falls back to CAMERA WB instead of throwing.
    gMockResolveRecipeWbStatus = SONY2FUJI_STATUS_UNSUPPORTED;
    setBoolField(wbObj, "custom", JNI_TRUE);
    Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
    ex = consumeException();
    require(!ex.active && gCapturedRequest.wb_mode == SONY2FUJI_WB_CAMERA,
        "UNSUPPORTED recipe WB calibration must fall back to CAMERA WB");

    // Preview render reads effective RAW WB via sony2fuji_session_get_effective_raw_white_balance.
    gMockResolveRecipeWbStatus = SONY2FUJI_STATUS_OK;
    setBoolField(wbObj, "recipeActive", JNI_FALSE);
    setBoolField(wbObj, "custom", JNI_FALSE);
    setObjField(outObj, "path", nullptr);
    setIntField(outObj, "edge", 64);
    gMockEffectiveWbTemp = 6500.f;
    gMockEffectiveWbTint = 0.f;
    jobject previewFrame = Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
    ex = consumeException();
    require(previewFrame != nullptr && !ex.active, "Preview nativeProcess must succeed");
    const auto& frameFields = asFake(previewFrame)->fields;
    require(frameFields.at("rawTemperature").f == 6500.f && frameFields.at("rawTint").f == 0.f,
        "NativeFrame WB must come from sony2fuji_session_get_effective_raw_white_balance");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testAbiDelegationRecipeWbAndMpf" << std::endl;
}

void testForceGpuUnsupportedExceptionMarshalling() {
    resetMocks();
    LocalEnv env;
    const jlong s = Java_com_rawlab_android_engine_NativeProcessor_nativeCreate(env.ptr(), nullptr, 2);
    jobject req = makeNativeProcessRequest("force-gpu.dng", 64, -1);

    gMockProcessStatus = SONY2FUJI_STATUS_UNSUPPORTED;
    gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_FORCE_GPU;
    Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
    ThreadJniException ex = consumeException();
    require(ex.active && ex.className == "com/rawlab/android/engine/NativeProcessingException",
        "UNSUPPORTED status must throw NativeProcessingException");
    require(ex.status == SONY2FUJI_STATUS_UNSUPPORTED &&
            ex.unsupportedReason == SONY2FUJI_UNSUPPORTED_FORCE_GPU,
        "Force GPU unsupported failure must marshal SONY2FUJI_UNSUPPORTED_FORCE_GPU");

    gMockUnsupportedReason = SONY2FUJI_UNSUPPORTED_NONE;
    Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
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

    jobject req = makeNativeProcessRequest("padded.dng", 12, -1);
    jobject frame = Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
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

    // Passing reusableBitmap reuses the exact same Bitmap object.
    jobject outObj = mockGetObjectField(env.ptr(), req, nullptr);
    (void)outObj;
    auto reqOutIt = asFake(req)->fields.find("output");
    require(reqOutIt != asFake(req)->fields.end() && reqOutIt->second.l != nullptr, "Missing request.output");
    setObjField(reqOutIt->second.l, "reusableBitmap", bmp);
    gMockProcessPixelSeed = 41;
    jobject reusedFrame = Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
    ex = consumeException();
    require(reusedFrame != nullptr && !ex.active, "Reusable bitmap nativeProcess must succeed");
    require(gNewByteArrayCalls.load() == 0, "Reusable bitmap preview must perform ZERO NewByteArray allocations");
    require(asFake(reusedFrame)->fields.at("bitmap").l == bmp, "Reusable bitmap must be reused in place");
    require(asFake(bmp)->bitmapPixels[0] == 41, "Reusable bitmap must receive updated pixels");

    // nativeCompatibilityPreview also uses Bitmap-backed NativeFrame with zero NewByteArray calls.
    gMockProcessPixelSeed = 73;
    jobject compatFrame = Java_com_rawlab_android_engine_NativeProcessor_nativeCompatibilityPreview(
        env.ptr(), nullptr, s, makeJString("compat.dng"), nullptr, 0, 0, 0, nullptr, nullptr);
    ex = consumeException();
    require(compatFrame != nullptr && !ex.active, "nativeCompatibilityPreview must succeed: " + ex.message);
    require(gNewByteArrayCalls.load() == 0, "nativeCompatibilityPreview must perform ZERO NewByteArray allocations");
    jobject compatBmp = asFake(compatFrame)->fields.at("bitmap").l;
    require(compatBmp != nullptr && asFake(compatBmp)->kind == FakeObjKind::Bitmap &&
            asFake(compatBmp)->bitmapPixels[0] == 73,
        "nativeCompatibilityPreview must write directly into NativeFrame Bitmap");

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

    jobject req = makeNativeProcessRequest("cancel-copy.dng", 16, gen);
    jobject frame = Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(env.ptr(), nullptr, s, req);
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
    const jlong p = Java_com_rawlab_android_engine_NativeHDRBridge_nativeDecode(env.ptr(), nullptr, makeJString("hdr.jpg"), 0);
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
    jbooleanArray lensFlags = Java_com_rawlab_android_engine_NativeProcessor_nativeInspectLens(
        env.ptr(), nullptr, s, makeJString("raw.arw"));
    ex = consumeException();
    require(lensFlags != nullptr && !ex.active && asFake(lensFlags)->booleans.size() == 3,
        "nativeInspectLens must return 3 booleans");
    require(asFake(lensFlags)->booleans[0] == JNI_TRUE &&
            asFake(lensFlags)->booleans[1] == JNI_FALSE &&
            asFake(lensFlags)->booleans[2] == JNI_TRUE,
        "nativeInspectLens flags mismatch");

    gCapturePayloads = true;
    jfloatArray wb = Java_com_rawlab_android_engine_NativeProcessor_nativeResolveCameraWhiteBalance(
        env.ptr(), nullptr, s, makeJString("raw.arw"), SONY2FUJI_PROCESSING_BASIC_V3, SONY2FUJI_X3F_NORMAL, SONY2FUJI_EXPOSURE_SCENE);
    ex = consumeException();
    require(wb != nullptr && !ex.active && asFake(wb)->floats.size() == 2,
        "nativeResolveCameraWhiteBalance must return camera WB");
    require(asFake(wb)->floats[0] == 5200.0f && asFake(wb)->floats[1] == 4.0f,
        "nativeResolveCameraWhiteBalance values mismatch");
    require(gCapturedRecipeWbRequest.recipe_active == 1 && gCapturedRecipeWbRequest.recipe_strength == 1.0f,
        "nativeResolveCameraWhiteBalance must engage recipe_active=1 calibration");

    Java_com_rawlab_android_engine_NativeProcessor_nativeDestroy(env.ptr(), nullptr, s);
    std::cout << "PASS: testNativePlaneDirectCopyAndMetadataInspection" << std::endl;
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
