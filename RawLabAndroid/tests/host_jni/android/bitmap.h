#pragma once

#include <jni.h>
#include <stdint.h>

#define ANDROID_BITMAP_RESULT_SUCCESS 0
#define ANDROID_BITMAP_RESULT_ALLOCATION_FAILED -2
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

inline int AndroidBitmap_getInfo(JNIEnv*, jobject, AndroidBitmapInfo*) { return -1; }
inline int AndroidBitmap_lockPixels(JNIEnv*, jobject, void**) { return -1; }
inline int AndroidBitmap_unlockPixels(JNIEnv*, jobject) { return -1; }

#ifdef __cplusplus
}
#endif
