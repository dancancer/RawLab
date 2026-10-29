#pragma once
#include <cstdint>
#include <cstring>

namespace sony2fuji::hdr {
// IEEE 754 binary16，不依赖 MSVC 不支持的 _Float16；舍入模式固定为 ties-to-even。
inline uint16_t floatToHalf(float value) {
    uint32_t bits; std::memcpy(&bits,&value,sizeof(bits));
    const uint16_t sign=uint16_t((bits>>16)&0x8000);
    const uint32_t exponent=(bits>>23)&255, mantissa=bits&0x7fffff;
    if (exponent==255) return sign | (mantissa ? 0x7e00 : 0x7c00);
    if (exponent>142) return sign | 0x7c00;
    if (exponent<102) return sign;
    const uint32_t significant=exponent<113 ? (mantissa|0x800000) : mantissa;
    const unsigned shift=exponent<113 ? 126-exponent : 13;
    const uint32_t rounded=(significant + ((uint32_t(1)<<(shift-1))-1) + ((significant>>shift)&1))>>shift;
    const uint32_t result=exponent<113 ? rounded : ((exponent-112)<<10)+rounded;
    return sign | uint16_t(result);
}

inline float halfToFloat(uint16_t value) {
    const uint32_t sign=uint32_t(value&0x8000)<<16;
    uint32_t exponent=(value>>10)&31, mantissa=value&1023, bits;
    if (!exponent && mantissa) {
        int adjusted=-14;
        while (!(mantissa&1024)) { mantissa<<=1; --adjusted; }
        bits=sign | uint32_t(adjusted+127)<<23 | (mantissa&1023)<<13;
    } else if (!exponent) bits=sign;
    else bits=sign | (exponent==31 ? 255u : exponent+112)<<23 | mantissa<<13;
    float result; std::memcpy(&result,&bits,sizeof(result)); return result;
}
} // namespace sony2fuji::hdr
