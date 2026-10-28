#pragma once
#include "sony2fuji/lut_contract.h"
#include <string>
#include <memory>

namespace sony2fuji {
class LUT3D;
LUTContractState parseLUTColorContract(const std::string& text, LUTColorContract& out);
std::string inspectLUTCompatibility(const std::string& path);
std::string prepareLUTCompatibility(const std::string& path, const std::string& request);
// 预览只在内存中使用候选配置，不生成确认记录或修改原文件。
std::shared_ptr<LUT3D> loadLUTCompatibilityPreview(const std::string& path, const std::string& request);
}
