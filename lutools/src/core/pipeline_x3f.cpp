#include "core/pipeline.h"

#include "core/processing_cancellation.h"
#include "core/x3f_processor.h"

#include <cstring>
#include <filesystem>
#include <fstream>

namespace sony2fuji {

bool Pipeline::x3fAvailable() {
    try {
        return x3fRenderingAvailable();
    } catch (...) {
        return false;
    }
}

RenderStatus Pipeline::x3fDefaultMode(const char* inputPath, X3fMode& outMode) {
    if (inputPath == nullptr || inputPath[0] == '\0') return RenderStatus::InvalidArgument;
    try {
        processingCancellation.check();
        std::ifstream input(std::filesystem::u8path(inputPath), std::ios::binary);
        if (!input) return RenderStatus::IoError;
        char signature[4]{};
        input.read(signature, sizeof(signature));
        if (input.bad() || (input.fail() && !input.eof())) return RenderStatus::IoError;
        processingCancellation.check();
        if (input.gcount() != sizeof(signature) || std::memcmp(signature, "FOVb", sizeof(signature)) != 0) {
            outMode = X3fMode::Legacy;
            return RenderStatus::Ok;
        }
        // 机型判断只读元数据，即使检查后文件被替换也不能触发像素解包。
        RAWProcessor processor;
        const auto loaded = processor.inspectFile(inputPath);
        if (loaded != ErrorCode::Success) return mapErrorCode(loaded);
        outMode = x3fModelSupported(processor.getCameraModel()) ? X3fMode::Normal : X3fMode::Legacy;
        return RenderStatus::Ok;
    } catch (const ProcessingCancelled&) {
        return RenderStatus::Cancelled;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

bool Pipeline::isNormalX3f(const char* inputPath, X3fMode mode) {
    if (mode != X3fMode::Normal || inputPath == nullptr || inputPath[0] == '\0') {
        return false;
    }
    try {
        return hasX3fSignature(inputPath);
    } catch (...) {
        return false;
    }
}

RenderStatus Pipeline::setX3fMode(X3fMode mode) {
    if (mode != X3fMode::Legacy && mode != X3fMode::Normal) {
        return RenderStatus::InvalidArgument;
    }
    x3fMode_ = mode;
    x3fError_.clear();
    unsupportedReason_ = UnsupportedReason::None;
    return RenderStatus::Ok;
}

} // namespace sony2fuji
