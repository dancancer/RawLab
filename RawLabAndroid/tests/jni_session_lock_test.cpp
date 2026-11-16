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
    ByteArray,
    IntArray,
    FloatArray,
    DoubleArray,
    ObjectArray,
    DirectBuffer,
    Class,
    Object,
    Throwable,
};

struct FakeJObject {
    FakeObjKind kind;
    std::string text;
    std::vector<jbyte> bytes;
    std::vector<jint> ints;
    std::vector<jfloat> floats;
    std::vector<jdouble> doubles;
    std::vector<jobject> objects;
    void* directAddress = nullptr;
    jlong directCapacity = 0;
    jint intArg = 0;
    std::string strArg;
};

struct FakeMethodId {
    std::string className;
    std::string name;
    std::string sig;
};

std::mutex gJniMutex;
std::vector<std::unique_ptr<FakeJObject>> gAllocatedObjects;
std::vector<std::unique_ptr<FakeMethodId>> gAllocatedMethods;

struct ThreadJniException {
    bool active = false;
    std::string className;
    std::string message;
    jint status = 0;
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

FakeJObject* asFake(jobject obj) { return reinterpret_cast<FakeJObject*>(obj); }

jclass JNICALL mockFindClass(JNIEnv*, const char* name) {
    auto* obj = reinterpret_cast<FakeJObject*>(allocObj(FakeObjKind::Class));
    obj->text = name ? name : "";
    return reinterpret_cast<jclass>(obj);
}

jmethodID JNICALL mockGetMethodID(JNIEnv*, jclass clazz, const char* name, const char* sig) {
    auto method = std::make_unique<FakeMethodId>();
    method->className = clazz ? asFake(clazz)->text : "";
    method->name = name ? name : "";
    method->sig = sig ? sig : "";
    auto* raw = reinterpret_cast<jmethodID>(method.get());
    std::lock_guard<std::mutex> lock(gJniMutex);
    gAllocatedMethods.push_back(std::move(method));
    return raw;
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
    }
    return reinterpret_cast<jobject>(obj);
}

jint JNICALL mockThrow(JNIEnv*, jthrowable throwable) {
    auto* obj = asFake(throwable);
    gTlsException.active = true;
    gTlsException.className = obj ? obj->text : "java/lang/Throwable";
    gTlsException.message = obj ? obj->strArg : "";
    gTlsException.status = obj ? obj->intArg : 0;
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
        case FakeObjKind::ByteArray: return static_cast<jsize>(obj->bytes.size());
        case FakeObjKind::IntArray: return static_cast<jsize>(obj->ints.size());
        case FakeObjKind::FloatArray: return static_cast<jsize>(obj->floats.size());
        case FakeObjKind::DoubleArray: return static_cast<jsize>(obj->doubles.size());
        case FakeObjKind::ObjectArray: return static_cast<jsize>(obj->objects.size());
        default: return 0;
    }
}

jbyteArray JNICALL mockNewByteArray(JNIEnv*, jsize len) {
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
    t.NewObjectV = mockNewObjectV;
    t.Throw = mockThrow;
    t.ThrowNew = mockThrowNew;
    t.ExceptionCheck = mockExceptionCheck;
    t.ExceptionClear = mockExceptionClear;
    t.DeleteLocalRef = mockDeleteLocalRef;
    t.GetMethodID = mockGetMethodID;
    t.NewStringUTF = mockNewStringUTF;
    t.GetStringUTFChars = mockGetStringUTFChars;
    t.ReleaseStringUTFChars = mockReleaseStringUTFChars;
    t.GetArrayLength = mockGetArrayLength;
    t.NewByteArray = mockNewByteArray;
    t.NewIntArray = mockNewIntArray;
    t.NewFloatArray = mockNewFloatArray;
    t.GetByteArrayElements = mockGetByteArrayElements;
    t.ReleaseByteArrayElements = mockReleaseByteArrayElements;
    t.GetByteArrayRegion = mockGetByteArrayRegion;
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
    clearJniRegistries();
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
sony2fuji_status sony2fuji_session_inspect_lens_v2(sony2fuji_session* s, const char*, sony2fuji_lens_report_v2*,
    sony2fuji_lens_profile_v2*, uint32_t, uint32_t* count) {
    SessionCallScope scope(s);
    *count = 0;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_inspect_lens_metadata_v2(sony2fuji_session* s, const sony2fuji_lens_metadata*,
    sony2fuji_lens_report_v2*, sony2fuji_lens_profile_v2*, uint32_t, uint32_t* count) {
    SessionCallScope scope(s);
    *count = 0;
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_get_lens_report_v2(sony2fuji_session* s, sony2fuji_lens_report_v2* r) {
    SessionCallScope scope(s);
    std::memset(r, 0, sizeof(*r));
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_processing_version(sony2fuji_session* s, sony2fuji_processing_version) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_x3f_mode(sony2fuji_session* s, sony2fuji_x3f_mode) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_raw_exposure_mode(sony2fuji_session* s, sony2fuji_raw_exposure_mode) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_hsl(sony2fuji_session* s, const sony2fuji_hsl_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_interactive_preview(sony2fuji_session* s, int32_t) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_viewport_preview(sony2fuji_session* s, int32_t) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_wavelet_denoise(sony2fuji_session* s, const sony2fuji_wavelet_denoise_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_photo_effects(sony2fuji_session* s, const sony2fuji_photo_effects_config*) {
    SessionCallScope scope(s);
    return SONY2FUJI_STATUS_OK;
}
sony2fuji_status sony2fuji_session_set_chroma_denoise(sony2fuji_session* s, int32_t) {
    SessionCallScope scope(s);
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

    const uint32_t dim = (req && req->preview_long_edge > 0) ? req->preview_long_edge : 16u;
    const size_t size = static_cast<size_t>(dim) * dim * 4;
    out->data = std::calloc(1, size);
    out->size_bytes = size;
    out->width = dim;
    out->height = dim;
    out->stride_bytes = dim * 4;
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
sony2fuji_render_backend sony2fuji_session_get_last_backend(const sony2fuji_session*) {
    return SONY2FUJI_BACKEND_CPU;
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
sony2fuji_status sony2fuji_hdr_geometry_size(uint32_t w, uint32_t h, const sony2fuji_hdr_request_v1*,
    uint32_t* ow, uint32_t* oh, sony2fuji_hdr_diagnostic_v1*) {
    *ow = w; *oh = h;
    return SONY2FUJI_STATUS_OK;
}

static sony2fuji_hdr_image_pair_v1 makeMockPair() {
    std::lock_guard<std::mutex> lock(gCoreMutex);
    auto pair = std::make_shared<MockHdrPairState>();
    pair->token = gNextMockToken++;
    pair->hdrPixels.assign(4 * 3, 1.0f);
    pair->sdrPixels.assign(4 * 3, 0.5f);
    gMockPairs.emplace(pair->token, pair);

    sony2fuji_hdr_image_pair_v1 out{};
    out.version = SONY2FUJI_HDR_VERSION;
    out.struct_size = sizeof(out);
    out.hdr = {SONY2FUJI_HDR_VERSION, sizeof(out.hdr), pair->hdrPixels.data(), pair->hdrPixels.size() * sizeof(float),
        2, 2, 2 * 12, SONY2FUJI_HDR_RGB32F_LINEAR, SONY2FUJI_HDR_LINEAR_SRGB, 2.0f, SONY2FUJI_HDR_HEADROOM_MEASURED};
    out.sdr = {SONY2FUJI_HDR_VERSION, sizeof(out.sdr), pair->sdrPixels.data(), pair->sdrPixels.size() * sizeof(float),
        2, 2, 2 * 12, SONY2FUJI_HDR_RGB32F_LINEAR, SONY2FUJI_HDR_LINEAR_SRGB, 1.0f, SONY2FUJI_HDR_HEADROOM_MEASURED};
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
    const sony2fuji_hdr_request_v1*, sony2fuji_hdr_image_pair_v1* result, sony2fuji_hdr_diagnostic_v1*) {
    SessionCallScope scope(s);
    bool validSource = false;
    {
        std::unique_lock<std::mutex> lock(gCoreMutex);
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

jobject callNativeProcess(JNIEnv* env, jlong id, const std::string& path, jint edge, jlong generation) {
    auto hsl = makeJFloatArray(std::vector<jfloat>(24, 0.f));
    return Java_com_rawlab_android_engine_NativeProcessor_nativeProcess(
        env, nullptr, id,
        makeJString(path), nullptr, 0, 0, 0,
        nullptr, nullptr, 1.f, 0.f,
        JNI_FALSE, 6500.f, 0.f, 0.f, 0.f,
        0.f, 0.f, 0.f, 0.f,
        edge, JNI_FALSE, 0, 0,
        JNI_FALSE, 0.f, 0.f, 0.f, 0,
        0.f, 50.f, 0.f, 50.f, 0.f, 0.f, 50.f, 50.f,
        0, hsl, JNI_FALSE, 3, 0, nullptr,
        0, 0, nullptr, generation, nullptr);
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
    std::vector<jfloat> hdrValues(17, 0.f);
    hdrValues[1] = 6500.f;

    std::thread h1([&] {
        LocalEnv env;
        out1 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
            env.ptr(), nullptr, s1, p1, makeJFloatArray(hdrValues), 0, nullptr, nullptr, nullptr, 0, -1, nullptr, nullptr);
        hdrEx1 = consumeException();
    });
    ThreadJoiner jh1{h1};
    std::thread h2([&] {
        LocalEnv env;
        out2 = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
            env.ptr(), nullptr, s2, p2, makeJFloatArray(hdrValues), 0, nullptr, nullptr, nullptr, 0, -1, nullptr, nullptr);
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

    std::vector<jfloat> hdrValues(17, 0.f);
    hdrValues[1] = 6500.f;
    uint64_t out1Token = 0;
    const jlong exportPair = Java_com_rawlab_android_engine_NativeHDRBridge_nativeRender(
        envMain.ptr(), nullptr, s1, p1, makeJFloatArray(hdrValues), 0, nullptr, nullptr, nullptr, 0, -1, nullptr, nullptr);
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
        {"testNativePng16LutColorConversion", testNativePng16LutColorConversion},
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
