#pragma once

#include "sony2fuji/common.h"
#include <array>
#include <cstddef>

namespace sony2fuji {

/**
 * @brief 色彩空间转换器
 *
 * 处理不同色彩空间之间的转换
 * 主要用于将 Sony 原生色彩空间转换到 Fuji F-Gamut
 */
class ColorConverter {
public:
    /**
     * @brief 3x3 色彩转换矩阵
     */
    using Matrix3x3 = std::array<std::array<float, 3>, 3>;

    ColorConverter() = default;

    /**
     * @brief 应用色彩空间转换到单个像素
     * @param input 输入 RGB
     * @param from 源色彩空间
     * @param to 目标色彩空间
     * @return 转换后的 RGB
     */
    RGB convert(const RGB& input, ColorSpace from, ColorSpace to) const;

    /**
     * @brief 应用色彩空间转换到整张图像
     * @param image 输入/输出图像
     * @param from 源色彩空间
     * @param to 目标色彩空间
     * @return 错误码
     */
    ErrorCode convertImage(ImageData& image, ColorSpace from, ColorSpace to) const;

    // ============================================================================
    // Camera matrix conversion (source -> XYZ with chromatic adaptation).
    // ============================================================================
    ErrorCode convertImage(
        ImageData& image,
        const Matrix3x3& fromToXYZ,
        ColorSpace fromWhitePoint,
        ColorSpace to
    ) const;

    /**
     * @brief 获取色彩空间转换矩阵
     * @param from 源色彩空间
     * @param to 目标色彩空间
     * @return 3x3 转换矩阵
     */
    static Matrix3x3 getConversionMatrix(ColorSpace from, ColorSpace to);

    // ============================================================================
    // Camera matrix conversion (matrix-only API).
    // ============================================================================
    static Matrix3x3 getConversionMatrix(
        const Matrix3x3& fromToXYZ,
        ColorSpace fromWhitePoint,
        ColorSpace to
    );

    /**
     * @brief 应用矩阵变换到 RGB
     * @param rgb 输入 RGB
     * @param matrix 3x3 矩阵
     * @return 变换后的 RGB
     */
    static RGB applyMatrix(const RGB& rgb, const Matrix3x3& matrix);

    /**
     * @brief 矩阵乘法 (A * B)
     */
    static Matrix3x3 multiplyMatrices(const Matrix3x3& a, const Matrix3x3& b);

    /**
     * @brief 矩阵求逆
     */
    static Matrix3x3 invertMatrix(const Matrix3x3& matrix);

private:
    using XYZ = std::array<float, 3>;

    // 预定义的色彩空间到 XYZ 的转换矩阵
    static Matrix3x3 getSonyNativeToXYZ();
    static Matrix3x3 getFGamutToXYZ();
    static Matrix3x3 getACES2065ToXYZ();
    static Matrix3x3 getACEScgToXYZ();
    static Matrix3x3 getBT709ToXYZ();
    static Matrix3x3 getProPhotoToXYZ();
    static Matrix3x3 getAdobeRGBToXYZ();
    static Matrix3x3 getSRGBToXYZ();

    // 从 XYZ 返回各色彩空间的矩阵 (即上述矩阵的逆)
    static Matrix3x3 getXYZToColorSpace(ColorSpace cs);

    static Matrix3x3 identityMatrix();
    static XYZ getWhitePointXYZ(ColorSpace cs);
    static XYZ multiplyXYZ(const Matrix3x3& matrix, const XYZ& value);
    static Matrix3x3 getChromaticAdaptationMatrix(ColorSpace fromWhitePoint, ColorSpace toWhitePoint);
};

/**
 * @brief Gamma 曲线处理
 */
class GammaConverter {
public:
    // ============================================================================
    // F-Log2 diagnostics.
    // ============================================================================
    struct FLog2Diagnostics {
        float min_linear = 0.0f;
        float max_linear = 0.0f;
        float scale = 1.0f;
        float offset = 0.0f;
        size_t negative_pixels = 0;
        size_t over_pixels = 0;
    };

    // ============================================================================
    // F-Log2 options.
    // ============================================================================
    struct FLog2Options {
        // Retained for source compatibility; encoding no longer rescales exposure.
        bool normalizeToRange = false;
        bool clampOnly = false;
        bool enableDiagnostics = false; /* 关闭时返回默认统计值，不扫描输入范围。 */
    };

    /**
     * @brief 应用 gamma 编码 (线性 -> gamma)
     * @param linear 线性值 [0, 1]
     * @param gamma gamma 值 (如 2.2)
     * @return gamma 编码后的值
     */
    static float applyGamma(float linear, float gamma);

    /**
     * @brief 去除 gamma 编码 (gamma -> 线性)
     * @param encoded gamma 编码值
     * @param gamma gamma 值 (如 2.2)
     * @return 线性值
     */
    static float removeGamma(float encoded, float gamma);

    /**
     * @brief 应用 sRGB gamma 曲线
     */
    static float applySRGBGamma(float linear);

    /**
     * @brief 去除 sRGB gamma 曲线
     */
    static float removeSRGBGamma(float encoded);

    /**
     * @brief 应用 F-Log2 编码曲线 (线性 -> F-Log2)
     */
    static float applyFLog2(float linear);

    /**
     * @brief 对 RGB 应用 F-Log2 编码
     */
    static RGB applyFLog2ToRGB(const RGB& rgb);

    // ============================================================================
    // F-Log2 image encoding.
    // ============================================================================
    static FLog2Diagnostics applyFLog2ToImage(
        ImageData& image,
        const FLog2Options& options
    );

    /**
     * @brief 对 RGB 应用 gamma
     */
    static RGB applyGammaToRGB(const RGB& rgb, float gamma);

    /**
     * @brief 对 RGB 去除 gamma
     */
    static RGB removeGammaFromRGB(const RGB& rgb, float gamma);
};

} // namespace sony2fuji
