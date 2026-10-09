#pragma once

#include "sony2fuji/common.h"
#include <string>
#include <memory>

namespace sony2fuji {

/**
 * @brief RAW 处理选项
 */
struct RAWProcessOptions {
    bool useAutoWhiteBalance;   // 使用自动白平衡
    bool useCameraWhiteBalance; // 使用相机白平衡
    bool useCustomWhiteBalance;
    bool useTemperatureWhiteBalance;
    float temperature, tint;
    float customWhiteBalance[4];
    float exposure;             // 曝光补偿 (EV)
    float brightness;           // 亮度调整
    bool outputLinear;          // 输出线性数据 (不应用 gamma)
    bool outputAces;            // 输出 ACES 色彩空间
    bool outputAdobe;
    int outputBitsPerSample;    // 8/16 display precision; linear working data stays float
    bool halfSize;              // LibRaw half-resolution demosaic for interactive previews
    int rawNoiseReduction;      // FBDD: 0 off, 1 light, 2 full; requires Bayer RAW
    bool matchEmbeddedPreviewExposure; // Optional JPEG-based approximation, not the default
    bool applyBaselineExposure; // Scene default + DNG BaselineExposure; ignored by preview match

    RAWProcessOptions()
        : useAutoWhiteBalance(false)
        , useCameraWhiteBalance(true)
        , useCustomWhiteBalance(false)
        , useTemperatureWhiteBalance(false)
        , temperature(6500), tint(0)
        , customWhiteBalance{1.0f, 1.0f, 1.0f, 1.0f}
        , exposure(0.0f)
        , brightness(1.0f)
        , outputLinear(true)
        , outputAces(false)
        , outputAdobe(false)
        , outputBitsPerSample(16)
        , halfSize(false)
        , rawNoiseReduction(0)
        , matchEmbeddedPreviewExposure(false)
        , applyBaselineExposure(true)
    {}
};

/**
 * @brief RAW 文件处理器
 *
 * 使用 libraw 解码 Sony RAW 文件
 */
class RAWProcessor {
public:
    RAWProcessor();
    ~RAWProcessor();

    // 禁止拷贝
    RAWProcessor(const RAWProcessor&) = delete;
    RAWProcessor& operator=(const RAWProcessor&) = delete;

    /**
     * @brief 加载 RAW 文件
     * @param filepath RAW 文件路径
     * @return 错误码
     */
    ErrorCode loadFile(const std::string& filepath);

    /**
     * @brief 处理 RAW 数据并转换为 ImageData
     * @param options 处理选项
     * @param output 输出图像数据
     * @return 错误码
     */
    ErrorCode process(const RAWProcessOptions& options, ImageData& output);

    /**
     * @brief 获取原始图像信息
     */
    int getWidth() const;
    int getHeight() const;
    std::string getCameraMake() const;
    std::string getCameraModel() const;
    // Legacy name: returns the last processed image's working space, not sensor RGB.
    ColorSpace getNativeColorSpace() const;
    float getPreviewExposureEV() const;
    float getBaselineExposureEV() const;
    float getMetadataExposureEV() const;
    bool getAsShotWhiteBalance(float& temperature, float& tint) const;
    bool supportsNoiseReduction() const;

    /**
     * @brief 获取相机色彩矩阵 (Camera RGB -> XYZ)
     * 用于色彩空间转换
     */
    bool getCameraColorMatrix(float matrix[3][3]) const;

private:
    class Impl;
    std::unique_ptr<Impl> pImpl_;
};

/**
 * @brief 图像编码器
 *
 * 将 ImageData 保存为 JPEG/PNG
 */
class ImageEncoder {
public:
    /**
     * @brief 保存图像
     * @param image 图像数据
     * @param filepath 输出文件路径
     * @param format 输出格式
     * @param quality JPEG 质量 (1-100, 仅用于 JPEG)
     * @return 错误码
     */
    static ErrorCode saveImage(
        const ImageData& image,
        const std::string& filepath,
        OutputFormat format,
        int quality = 95
    );

    /**
     * @brief 保存为 JPEG
     */
    static ErrorCode saveJPEG(
        const ImageData& image,
        const std::string& filepath,
        int quality = 95
    );

    /**
     * @brief 保存为 PNG
     */
    static ErrorCode savePNG(
        const ImageData& image,
        const std::string& filepath
    );

private:
    // 将 float [0,1] 转换为 uint8_t
    static uint8_t floatToUint8(float value);

    // 将 float [0,1] 转换为 uint16_t
    static uint16_t floatToUint16(float value);
};

} // namespace sony2fuji
