#include RAWLAB_ARW6_SOURCE
#include <iostream>
#include <stdexcept>

int main() {
    try {
        const unsigned char signs[16] = {0x80};
        SonyArw6NativeBits bits(signs, sizeof(signs), 0, sizeof(signs));
        int32_t values[4] = {1073758208, 0, 0, 0};
        sony_arw6_apply_signs(bits, values);
        if (values[0] != -1073758208 || bits.status)
            throw std::runtime_error("Large positive coefficients must negate without overflow");
        const unsigned char oversized[16] = {
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
        SonyArw6NativeBits malformed(oversized, sizeof(oversized), 0, sizeof(oversized));
        bool rejected = false;
        try { sony_arw6_decode_coeff_group(malformed, 19, 15, values); }
        catch (LibRaw_exceptions error) { rejected = error == LIBRAW_EXCEPTION_IO_CORRUPT; }
        if (!rejected) throw std::runtime_error("Out-of-range coefficient magnitudes must reject the stream");
        std::cout << "PASS ARW6 coefficient narrowing and sign arithmetic boundaries\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
