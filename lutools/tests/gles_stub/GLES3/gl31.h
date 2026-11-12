#pragma once

#include <cstddef>
#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned int GLenum;
typedef unsigned char GLboolean;
typedef unsigned int GLbitfield;
typedef int32_t GLint;
typedef uint32_t GLuint;
typedef int32_t GLsizei;
typedef int64_t GLint64;
typedef intptr_t GLintptr;
typedef intptr_t GLsizeiptr;
typedef char GLchar;
typedef float GLfloat;

#define GL_FALSE 0
#define GL_TRUE 1
#define GL_NO_ERROR 0
#define GL_INVALID_VALUE 0x0501
#define GL_INVALID_OPERATION 0x0502

#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_RGBA 0x1908
#define GL_FLOAT 0x1406
#define GL_NEAREST 0x2600
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_TEXTURE_3D 0x806F
#define GL_TEXTURE_WRAP_R 0x8072
#define GL_MAX_3D_TEXTURE_SIZE 0x8073
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_MAJOR_VERSION 0x821B
#define GL_MINOR_VERSION 0x821C
#define GL_TEXTURE0 0x84C0
#define GL_RGBA32F 0x8814
#define GL_DYNAMIC_DRAW 0x88E8
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_MAP_READ_BIT 0x0001
#define GL_BUFFER_UPDATE_BARRIER_BIT 0x00000200
#define GL_SHADER_STORAGE_BARRIER_BIT 0x00002000
#define GL_SHADER_STORAGE_BUFFER 0x90D2
#define GL_MAX_SHADER_STORAGE_BLOCK_SIZE 0x90DE
#define GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS 0x90EB
#define GL_COMPUTE_SHADER 0x91B9
#define GL_MAX_COMPUTE_WORK_GROUP_COUNT 0x91BE
#define GL_MAX_COMPUTE_WORK_GROUP_SIZE 0x91BF

GLuint glCreateShader(GLenum type);
void glShaderSource(GLuint shader, GLsizei count, const GLchar* const* string, const GLint* length);
void glCompileShader(GLuint shader);
void glGetShaderiv(GLuint shader, GLenum pname, GLint* params);
void glDeleteShader(GLuint shader);

GLuint glCreateProgram(void);
void glAttachShader(GLuint program, GLuint shader);
void glLinkProgram(GLuint program);
void glGetProgramiv(GLuint program, GLenum pname, GLint* params);
void glDeleteProgram(GLuint program);
void glUseProgram(GLuint program);
GLint glGetUniformLocation(GLuint program, const GLchar* name);
void glUniform1i(GLint location, GLint v0);

void glGetIntegerv(GLenum pname, GLint* data);
void glGetIntegeri_v(GLenum target, GLuint index, GLint* data);
void glGetInteger64v(GLenum pname, GLint64* data);
GLenum glGetError(void);

void glGenTextures(GLsizei n, GLuint* textures);
void glBindTexture(GLenum target, GLuint texture);
void glTexParameteri(GLenum target, GLenum pname, GLint param);
void glPixelStorei(GLenum pname, GLint param);
void glTexImage3D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLsizei depth, GLint border, GLenum format, GLenum type, const void* pixels);
void glActiveTexture(GLenum texture);
void glDeleteTextures(GLsizei n, const GLuint* textures);

void glGenBuffers(GLsizei n, GLuint* buffers);
void glBindBuffer(GLenum target, GLuint buffer);
void glBindBufferBase(GLenum target, GLuint index, GLuint buffer);
void glBufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage);
void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data);
void* glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access);
GLboolean glUnmapBuffer(GLenum target);
void glDeleteBuffers(GLsizei n, const GLuint* buffers);

void glDispatchCompute(GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z);
void glMemoryBarrier(GLbitfield barriers);

#ifdef __cplusplus
}
#endif
