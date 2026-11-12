#pragma once

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef int32_t EGLint;
typedef void* EGLDisplay;
typedef void* EGLConfig;
typedef void* EGLSurface;
typedef void* EGLContext;
typedef void* EGLNativeDisplayType;

#define EGL_FALSE 0u
#define EGL_TRUE 1u
#define EGL_DEFAULT_DISPLAY ((EGLNativeDisplayType)0)
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
#define EGL_NO_SURFACE ((EGLSurface)0)

#define EGL_SUCCESS 0x3000
#define EGL_BAD_ACCESS 0x3002
#define EGL_BAD_MATCH 0x3009
#define EGL_BAD_PARAMETER 0x300C
#define EGL_BLUE_SIZE 0x3022
#define EGL_GREEN_SIZE 0x3023
#define EGL_RED_SIZE 0x3024
#define EGL_ALPHA_SIZE 0x3021
#define EGL_SURFACE_TYPE 0x3033
#define EGL_NONE 0x3038
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_HEIGHT 0x3056
#define EGL_WIDTH 0x3057
#define EGL_DRAW 0x3059
#define EGL_READ 0x305A
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_OPENGL_API 0x30A2
#define EGL_PBUFFER_BIT 0x0001
#define EGL_OPENGL_ES3_BIT 0x00000040

EGLDisplay eglGetDisplay(EGLNativeDisplayType display_id);
EGLBoolean eglInitialize(EGLDisplay dpy, EGLint* major, EGLint* minor);
EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint* attrib_list, EGLConfig* configs, EGLint config_size, EGLint* num_config);
EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config, const EGLint* attrib_list);
EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig config, EGLContext share_context, const EGLint* attrib_list);
EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx);
EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface surface);
EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx);
EGLDisplay eglGetCurrentDisplay(void);
EGLSurface eglGetCurrentSurface(EGLint readdraw);
EGLContext eglGetCurrentContext(void);
EGLBoolean eglBindAPI(EGLenum api);
EGLenum eglQueryAPI(void);
EGLint eglGetError(void);

#ifdef __cplusplus
}
#endif
