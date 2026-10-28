#pragma once
#include "sony2fuji/common.h"
#include <stdexcept>

namespace sony2fuji::ai {
// 模型契约错误不是后端故障；Auto 不得用 CPU 成功掩盖错误资源或无效输出。
class ModelContractError : public std::logic_error {
public:
    using std::logic_error::logic_error;
};
class DecodeError : public std::runtime_error {
public:
    DecodeError(ErrorCode code, const char* message) : std::runtime_error(message), code(code) {}
    const ErrorCode code;
};
} // namespace sony2fuji::ai
