#pragma once

#include "sony2fuji/common.h"
#include <string>
#include <vector>
#include <memory>

namespace sony2fuji {

enum class LUTTransfer { Unknown, Display, FLog, FLog2, FLog2C, SRGB };

/**
 * @brief 3D LUT 数据结构
 *
 * 存储 3D LUT 的立方体数据
 * 支持 .cube 文件格式
 */
class LUT3D {
public:
    LUT3D() : size_(0) {}

    /**
     * @brief 从 .cube 文件加载 LUT
     * @param filepath .cube 文件路径
     * @return 错误码
     */
    ErrorCode loadFromFile(const std::string& filepath);

    /**
     * @brief 获取 LUT 大小 (每个维度的采样点数)
     * @return LUT 大小 (通常是 17, 33, 65 等)
     */
    int getSize() const { return size_; }

    /**
     * @brief 获取标题
     */
    const std::string& getTitle() const { return title_; }
    const RGB& domainMin() const { return domainMin_; }
    const RGB& domainMax() const { return domainMax_; }
    bool isPhotoLUT() const { return inputTransfer_ != LUTTransfer::Unknown; }
    LUTTransfer inputTransfer() const { return inputTransfer_; }
    LUTTransfer outputTransfer() const { return outputTransfer_; }

    /**
     * @brief 获取指定索引的 RGB 值
     * @param r 红色索引 [0, size-1]
     * @param g 绿色索引 [0, size-1]
     * @param b 蓝色索引 [0, size-1]
     * @return RGB 值
     */
    RGB getValue(int r, int g, int b) const;

    /**
     * @brief 检查 LUT 是否有效
     */
    bool isValid() const { return size_ > 0 && !data_.empty(); }

private:
    int size_;                  // LUT 大小
    std::vector<RGB> data_;     // LUT 数据 (size^3 个元素)
    std::string title_;         // LUT 标题
    std::string description_;   // LUT 描述
    RGB domainMin_{0, 0, 0};
    RGB domainMax_{1, 1, 1};
    LUTTransfer inputTransfer_ = LUTTransfer::Unknown;
    LUTTransfer outputTransfer_ = LUTTransfer::Unknown;

    // 解析 .cube 文件
    ErrorCode parseCubeFile(const std::string& filepath);
};

/**
 * @brief LUT 解析器工厂类
 */
class LUTParser {
public:
    /**
     * @brief 从文件加载 LUT
     * @param filepath LUT 文件路径 (支持 .cube 格式)
     * @return LUT3D 智能指针
     */
    static std::unique_ptr<LUT3D> loadLUT(const std::string& filepath);

    // ============================================================================
    // Cached LUT loader (shared_ptr reuse).
    // ============================================================================
    static std::shared_ptr<LUT3D> loadLUTCached(const std::string& filepath);

    /**
     * @brief 检测 LUT 文件格式
     * @param filepath 文件路径
     * @return 格式字符串 ("cube", "3dl", 等) 或空字符串表示不支持
     */
    static std::string detectFormat(const std::string& filepath);
};

} // namespace sony2fuji
