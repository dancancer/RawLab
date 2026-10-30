#pragma once

#include "sony2fuji/common.h"
#include "sony2fuji/lens_correction.h"
#include <string>
#include <memory>
#include <array>

namespace sony2fuji {

enum class BayerDemosaicMethod {
    Legacy,
    VNG,
    DHT
};

enum class X3fMode { Legacy = 0, Normal = 1 };

// 有效 sensor 区域，尚未白平衡或旋转。相机标定与原始 RAW 一起保存。
struct RAWBayerSource {
    int width = 0, height = 0, flip = 0;
    std::vector<uint16_t> pixels;
    std::array<int, 4> pattern{};
    std::array<float, 4> black{}, whiteBalance{};
    float white = 0, iso = 0, shutterSeconds = 0;
    unsigned rawBits = 0, sonyRawType = 0;
    std::string cameraModel;
    std::array<std::array<float, 3>, 3> cameraCalibration{}, cameraToSrgb{};
};

// 只在一次 process 调用中覆盖内存像素，不修改源文件或保留的解包数据。
struct RAWBayerOverride {
    int width = 0, height = 0;
    std::vector<float> normalizedMosaic;
    // 未旋转 sensor 坐标；已白平衡并以绿色归一化的相机通道线性修正。
    std::vector<RGB> cameraCorrection;
};

/**
 * @brief RAW 处理选项
 */
struct RAWProcessOptions {
    X3fMode x3fMode = X3fMode::Legacy;
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
    BayerDemosaicMethod bayerDemosaic; // 非 Bayer 保留 LibRaw 原有插值路径
    bool matchEmbeddedPreviewExposure; // Optional JPEG-based approximation, not the default
    bool applyBaselineExposure; // Scene default + DNG BaselineExposure; ignored by preview match
    std::shared_ptr<const LensCorrectionDatabase> lensDatabase;
    LensCorrectionOptions lensCorrection;
    const RAWBayerOverride* bayerOverride = nullptr;

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
        , bayerDemosaic(BayerDemosaicMethod::Legacy)
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
    // Normal X3F 只让 LibRaw 识别元数据，像素由专用解码器读取；切回 Legacy 时再解包。
    ErrorCode loadFile(const std::string& filepath, X3fMode mode);

    /**
     * @brief 处理 RAW 数据并转换为 ImageData
     * @param options 处理选项
     * @param output 输出图像数据
     * @return 错误码
     */
    ErrorCode process(const RAWProcessOptions& options, ImageData& output);
    ErrorCode readBayerSource(const RAWProcessOptions& options, RAWBayerSource& output);
    bool getBayerMetadata(RAWBayerSource& output) const;

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
    bool isDisplayReferred() const;
    const std::string& getLastError() const;
    static ErrorCode readLensMetadata(const std::string& filepath, LensMetadata& metadata);
    LensCorrectionReport getLensCorrectionReport() const;

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
