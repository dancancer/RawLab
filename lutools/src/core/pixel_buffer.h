#pragma once

#include "sony2fuji/common.h"

#include <cstddef>
#include <cstdint>
#include <cstdlib>

namespace sony2fuji {

enum class RenderStatus : int32_t {
    Ok = 0,
    InvalidArgument = 1,
    Unsupported = 2,
    IoError = 3,
    ProcessingError = 4,
    OutOfMemory = 5,
    OutputIoError = 6,
    Cancelled = 7,
    AiNotReady = 8
};

enum class PixelBufferFormat : int32_t {
    RGB8 = 0,
    RGBA8 = 1,
    RGBA16 = 2
};

struct PixelBufferView {
    const void* data = nullptr;
    size_t sizeBytes = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t strideBytes = 0;
    PixelBufferFormat format = PixelBufferFormat::RGB8;
};

struct OwnedPixelBuffer {
    void* data = nullptr;
    size_t sizeBytes = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t strideBytes = 0;
    PixelBufferFormat format = PixelBufferFormat::RGB8;

    OwnedPixelBuffer() = default;
    ~OwnedPixelBuffer() { reset(); }
    OwnedPixelBuffer(const OwnedPixelBuffer&) = delete;
    OwnedPixelBuffer& operator=(const OwnedPixelBuffer&) = delete;

    OwnedPixelBuffer(OwnedPixelBuffer&& other) noexcept
        : data(other.data),
          sizeBytes(other.sizeBytes),
          width(other.width),
          height(other.height),
          strideBytes(other.strideBytes),
          format(other.format) {
        other.data = nullptr;
        other.sizeBytes = 0;
        other.width = 0;
        other.height = 0;
        other.strideBytes = 0;
        other.format = PixelBufferFormat::RGB8;
    }

    OwnedPixelBuffer& operator=(OwnedPixelBuffer&& other) noexcept {
        if (this != &other) {
            reset();
            data = other.data;
            sizeBytes = other.sizeBytes;
            width = other.width;
            height = other.height;
            strideBytes = other.strideBytes;
            format = other.format;
            other.data = nullptr;
            other.sizeBytes = 0;
            other.width = 0;
            other.height = 0;
            other.strideBytes = 0;
            other.format = PixelBufferFormat::RGB8;
        }
        return *this;
    }

    void reset() noexcept {
        if (data) {
            std::free(data);
            data = nullptr;
        }
        sizeBytes = 0;
        width = 0;
        height = 0;
        strideBytes = 0;
        format = PixelBufferFormat::RGB8;
    }

    void* releaseData() noexcept {
        void* released = data;
        data = nullptr;
        sizeBytes = 0;
        width = 0;
        height = 0;
        strideBytes = 0;
        format = PixelBufferFormat::RGB8;
        return released;
    }
};

inline RenderStatus mapErrorCode(ErrorCode code) noexcept {
    switch (code) {
        case ErrorCode::Success:
            return RenderStatus::Ok;
        case ErrorCode::FileNotFound:
            return RenderStatus::IoError;
        case ErrorCode::IOError:
            return RenderStatus::OutputIoError;
        case ErrorCode::ParseError:
        case ErrorCode::InvalidFormat:
        case ErrorCode::Unsupported:
            return RenderStatus::Unsupported;
        case ErrorCode::OutOfMemory:
            return RenderStatus::OutOfMemory;
        case ErrorCode::ProcessingError:
        default:
            return RenderStatus::ProcessingError;
    }
}

} // namespace sony2fuji
