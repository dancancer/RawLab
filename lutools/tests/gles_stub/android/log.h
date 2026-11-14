#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef enum android_LogPriority {
    ANDROID_LOG_UNKNOWN = 0,
    ANDROID_LOG_DEFAULT = 1,
    ANDROID_LOG_VERBOSE = 2,
    ANDROID_LOG_DEBUG = 3,
    ANDROID_LOG_INFO = 4,
    ANDROID_LOG_WARN = 5,
    ANDROID_LOG_ERROR = 6,
    ANDROID_LOG_FATAL = 7,
    ANDROID_LOG_SILENT = 8
} android_LogPriority;

int __android_log_print(int prio, const char* tag, const char* fmt, ...);

#ifdef __cplusplus
}
#endif
