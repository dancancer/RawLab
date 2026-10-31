#include "core/hdr_half.h"
#include <cmath>
#include <iostream>
#include <limits>
#include <random>

int main() {
    using namespace sony2fuji::hdr;
    for (uint32_t bits=0;bits<=65535;++bits) {
        const auto half=uint16_t(bits); const float value=halfToFloat(half);
        if ((half&0x7c00)==0x7c00 && (half&1023)) {
            if (!std::isnan(value)) return 1;
        } else if (floatToHalf(value)!=half) return 2;
#if defined(__clang__) && defined(__FLT16_MANT_DIG__)
        _Float16 native; std::memcpy(&native,&half,2);
        if (!std::isnan(value) && float(native)!=value) return 3;
#endif
    }
#if defined(__clang__) && defined(__FLT16_MANT_DIG__)
    std::mt19937 random(21496);
    for (int i=0;i<1000000;++i) {
        const uint32_t bits=random(); float value; std::memcpy(&value,&bits,4);
        if (std::isnan(value)) continue;
        const _Float16 native=static_cast<_Float16>(value); uint16_t expected;
        std::memcpy(&expected,&native,2);
        if (floatToHalf(value)!=expected) return 4;
    }
#endif
    std::cout<<"all binary16 values and rounding checks passed\n";
}
