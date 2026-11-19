#pragma once

#include <algorithm>
#include <cmath>
#include <string>

namespace sony2fuji {

enum class ShaderDialect {
    Metal,
    Hlsl,
    Glsl,
};

#define RAWLAB_LOG_FUNCTIONS_BODY \
RAWLAB_FN float flog2(float linearValue) { \
    if (linearValue < 0.00088899597f) { \
        return RAWLAB_CLAMP01(8.799461f * linearValue + 0.092864f); \
    } \
    return RAWLAB_CLAMP01(RAWLAB_LOG10(linearValue * 5.555556f + 0.064829f) * 0.245281f + 0.384316f); \
} \
RAWLAB_FN float flog(float linearValue) { \
    if (linearValue < 0.00089f) { \
        return RAWLAB_CLAMP01(8.735631f * linearValue + 0.092864f); \
    } \
    return RAWLAB_CLAMP01(0.344676f * RAWLAB_LOG10(0.555556f * linearValue + 0.009468f) + 0.790453f); \
} \
RAWLAB_FN float decodeFLog(float encoded) { \
    return encoded < 0.100537775223865f \
        ? (encoded - 0.092864f) / 8.735631f \
        : (RAWLAB_POW(10.0f, (encoded - 0.790453f) / 0.344676f) - 0.009468f) / 0.555556f; \
} \
RAWLAB_FN float decodeFLog2(float encoded) { \
    return encoded < 0.100686685370811f \
        ? (encoded - 0.092864f) / 8.799461f \
        : (RAWLAB_POW(10.0f, (encoded - 0.384316f) / 0.245281f) - 0.064829f) / 5.555556f; \
} \
RAWLAB_FN float encodePhotoLog(float linearValue, bool isFLog) { \
    return isFLog ? flog(linearValue) : flog2(linearValue); \
} \
RAWLAB_FN float decodePhotoLog(float encoded, bool isFLog) { \
    return isFLog ? decodeFLog(encoded) : decodeFLog2(encoded); \
}

#define RAWLAB_FN inline
#define RAWLAB_CLAMP01(x) std::max(0.0f, std::min(1.0f, (x)))
#define RAWLAB_LOG10(x) std::log10(x)
#define RAWLAB_POW(x, y) std::pow((x), (y))

namespace detail {
RAWLAB_LOG_FUNCTIONS_BODY
} // namespace detail

#undef RAWLAB_FN
#undef RAWLAB_CLAMP01
#undef RAWLAB_LOG10
#undef RAWLAB_POW

#define RAWLAB_LOG_SHADER_STR(...) #__VA_ARGS__
#define RAWLAB_LOG_SHADER_TEXT(body) RAWLAB_LOG_SHADER_STR(body)

inline std::string photoLogShader(ShaderDialect dialect) {
    std::string preamble = "\n";
    switch (dialect) {
    case ShaderDialect::Metal:
        preamble +=
            "#define RAWLAB_FN inline\n"
            "#define RAWLAB_CLAMP01(x) clamp((x), 0.0f, 1.0f)\n"
            "#define RAWLAB_LOG10(x) log10(x)\n"
            "#define RAWLAB_POW(x, y) pow((x), (y))\n";
        break;
    case ShaderDialect::Hlsl:
        preamble +=
            "#define RAWLAB_FN\n"
            "#define RAWLAB_CLAMP01(x) saturate(x)\n"
            "#define RAWLAB_LOG10(x) log10(x)\n"
            "#define RAWLAB_POW(x, y) pow((x), (y))\n";
        break;
    case ShaderDialect::Glsl:
        preamble +=
            "#define RAWLAB_FN\n"
            "#define RAWLAB_CLAMP01(x) clamp((x), 0.0f, 1.0f)\n"
            "#define RAWLAB_LOG10(x) (log(x) / log(10.0f))\n"
            "#define RAWLAB_POW(x, y) pow((x), (y))\n";
        break;
    }
    return preamble + RAWLAB_LOG_SHADER_TEXT(RAWLAB_LOG_FUNCTIONS_BODY) +
        "\n#undef RAWLAB_FN\n"
        "#undef RAWLAB_CLAMP01\n"
        "#undef RAWLAB_LOG10\n"
        "#undef RAWLAB_POW\n";
}

#undef RAWLAB_LOG_SHADER_TEXT
#undef RAWLAB_LOG_SHADER_STR
#undef RAWLAB_LOG_FUNCTIONS_BODY

} // namespace sony2fuji
