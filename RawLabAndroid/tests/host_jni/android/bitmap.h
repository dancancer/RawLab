#pragma once

#include <jni.h>
#include <stdint.h>

// Minimal host stub mirroring NDK <android/bitmap.h> constants and signatures.
// Result codes (AndroidBitmap functions):
//   ANDROID_BITMAP_RESULT_SUCCESS            0  Operation was successful
//   ANDROID_BITMAP_RESULT_BAD_PARAMETER     -1  Bad parameter
//   ANDROID_BITMAP_RESULT_JNI_EXCEPTION     -2  JNI exception occurred
//   ANDROID_BITMAP_RESULT_ALLOCATION_FAILED -3  Allocation failed
// Pixel formats (enum AndroidBitmapFormat):
//   ANDROID_BITMAP_FORMAT_NONE               0  No format
//   ANDROID_BITMAP_FORMAT_RGBA_8888          1  Red: 8, Green: 8, Blue: 8, Alpha: 8
//   ANDROID_BITMAP_FORMAT_RGB_565            4  Red: 5, Green: 6, Blue: 5
//   ANDROID_BITMAP_FORMAT_RGBA_4444          7  Deprecated 4-bit RGBA
//   ANDROID_BITMAP_FORMAT_A_8                8  Alpha: 8 bits
//   ANDROID_BITMAP_FORMAT_RGBA_F16           9  Half-float 16-bit RGBA
//   ANDROID_BITMAP_FORMAT_RGBA_1010102      10  Red: 10, Green: 10, Blue: 10, Alpha: 2
#define ANDROID_BITMAP_RESULT_SUCCESS 0
#define ANDROID_BITMAP_RESULT_BAD_PARAMETER -1
#define ANDROID_BITMAP_RESULT_JNI_EXCEPTION -2
#define ANDROID_BITMAP_RESULT_ALLOCATION_FAILED -3
#define ANDROID_BITMAP_FORMAT_RGBA_8888 1

typedef struct AndroidBitmapInfo {
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    int32_t format;
    uint32_t flags;
} AndroidBitmapInfo;

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RawLabHostBitmapHooks {
    int (*getInfo)(JNIEnv* env, jobject bitmap, AndroidBitmapInfo* info);
    int (*lockPixels)(JNIEnv* env, jobject bitmap, void** addrPtr);
    int (*unlockPixels)(JNIEnv* env, jobject bitmap);
} RawLabHostBitmapHooks;

inline RawLabHostBitmapHooks** rawlabHostBitmapHooksSlot() {
    static RawLabHostBitmapHooks* hooks = nullptr;
    return &hooks;
}

inline int AndroidBitmap_getInfo(JNIEnv* env, jobject bitmap, AndroidBitmapInfo* info) {
    RawLabHostBitmapHooks* hooks = *rawlabHostBitmapHooksSlot();
    return (hooks && hooks->getInfo) ? hooks->getInfo(env, bitmap, info) : ANDROID_BITMAP_RESULT_BAD_PARAMETER;
}

inline int AndroidBitmap_lockPixels(JNIEnv* env, jobject bitmap, void** addrPtr) {
    RawLabHostBitmapHooks* hooks = *rawlabHostBitmapHooksSlot();
    return (hooks && hooks->lockPixels) ? hooks->lockPixels(env, bitmap, addrPtr) : ANDROID_BITMAP_RESULT_BAD_PARAMETER;
}

inline int AndroidBitmap_unlockPixels(JNIEnv* env, jobject bitmap) {
    RawLabHostBitmapHooks* hooks = *rawlabHostBitmapHooksSlot();
    return (hooks && hooks->unlockPixels) ? hooks->unlockPixels(env, bitmap) : ANDROID_BITMAP_RESULT_BAD_PARAMETER;
}

#ifdef __cplusplus
}
#endif
