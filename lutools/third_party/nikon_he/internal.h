// SPDX-License-Identifier: LGPL-2.1
// Internal stages only: Header/Topology/Precinct must come from parse/build.
#pragma once
#include "codec.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <utility>
#include <vector>

namespace rawlab {
namespace nikon_he {
inline int64_t shift(int64_t v, unsigned n) { return v >= 0 ? v >> n : -1 - (-(v + 1) >> n); }
inline int32_t narrow(int64_t v) {
    if (v < INT32_MIN || v > INT32_MAX)
        throw DecodeError("Nikon HE coefficient overflow");
    return static_cast<int32_t>(v);
}
inline size_t ceil_div(size_t a, size_t b) { return a / b + (a % b != 0); }
class BitReader {
    const uint8_t *buf_;
    size_t size_, bit_;

  public:
    BitReader(const uint8_t *b, size_t n, size_t offset = 0) : buf_(b), size_(n), bit_(0) {
        if (offset > n || n > SIZE_MAX / 8)
            throw DecodeError("Nikon HE bitstream bounds");
        bit_ = offset * 8;
    }
    unsigned bit() {
        if (bit_ / 8 >= size_)
            throw DecodeError("Truncated Nikon HE bitstream");
        const auto v = (buf_[bit_ / 8] >> (7 - bit_ % 8)) & 1;
        ++bit_;
        return v;
    }
    uint32_t bits(unsigned n) {
        if (n > 32)
            throw DecodeError("Invalid Nikon HE bit width");
        uint32_t v = 0;
        while (n--)
            v = (v << 1) | bit();
        return v;
    }
    unsigned nibble() {
        if (bit_ % 4)
            throw DecodeError("Unaligned Nikon HE nibble");
        return bits(4);
    }
    unsigned unary() {
        unsigned v = 0;
        while (bit())
            if (++v >= 32)
                throw DecodeError("Invalid Nikon HE unary code");
        return v;
    }
    void align() { bit_ = ceil_div(bit_, 8) * 8; }
    size_t byte_pos() const { return bit_ / 8; }
    void skip_bits(size_t n) {
        while (n--)
            (void)bit();
    }
    const uint8_t *bytes(size_t n) {
        if (bit_ % 8 || byte_pos() > size_ || n > size_ - byte_pos())
            throw DecodeError("Truncated Nikon HE byte stream");
        const auto *p = buf_ + byte_pos();
        bit_ += n * 8;
        return p;
    }
};
struct Component {
    uint8_t bit_depth = 0, sx = 0, sy = 0, nlx = 0, nly = 0;
    bool suppressed() const { return nlx == 0 && nly == 0; }
    size_t bands() const { return suppressed() ? 1 : 2 * nly + nlx + 1; }
};
struct Header {
    uint32_t lcod = 0;
    uint16_t grid_width = 0, grid_height = 0, precinct_width = 0, slice_height = 0;
    uint8_t group_size = 0, sig_group_size = 0, bw = 0, fq = 0, br = 0;
    uint8_t ppoc = 0, cpih = 0, nlx = 0, nly = 0, qpih = 0, fs = 0, rm = 0, lh = 0, rl = 0;
    std::vector<Component> components;
    std::vector<std::pair<uint8_t, uint8_t>> weights;
    std::array<uint8_t, 13> vendor{};
    size_t first_slice = 0;
    size_t plane_width() const { return grid_width / 2; }
    size_t plane_height() const { return grid_height / 2; }
    size_t precinct_height() const { return size_t(1) << nly; }
    size_t precinct_count() const { return ceil_div(plane_height(), precinct_height()); }
    size_t slice_count() const { return ceil_div(precinct_count(), slice_height); }
    size_t total_bands() const {
        size_t n = 0;
        for (const auto &c : components)
            n += c.bands();
        return n;
    }
};
struct Range {
    size_t start = 0, end = 0;
};
struct Band {
    size_t component = 0, local = 0, width = 0, gcli_width = 0, significance_width = 0,
           lines_per_precinct = 0;
    uint8_t gain = 0, priority = 0;
    uint8_t gtli(uint8_t qp, uint8_t rp, uint8_t max) const {
        const int v = int(qp) - gain - (priority < rp ? 1 : 0);
        return static_cast<uint8_t>(v < 0 ? 0 : v > max ? max : v);
    }
};
struct Packet {
    size_t component = 0;
    Range bands;
    size_t line = 0;
};
struct Topology {
    std::vector<Band> bands;
    std::vector<Packet> packets;
    std::vector<Range> component_bands;
};
struct BandData {
    uint8_t gtli = 0;
    std::vector<uint8_t> gcli;
    std::vector<uint16_t> coeff;
};
struct Precinct {
    std::vector<BandData> bands;
};
Header parse(const uint8_t *, size_t);
Topology build(const Header &);
Precinct decode_precinct(const uint8_t *, size_t, size_t, const Header &, const Topology &,
                         const Precinct *, size_t &);
std::vector<std::vector<int32_t>> inverse_wavelet(const uint8_t *, size_t, const Header &,
                                                  const Topology &);
} // namespace nikon_he
} // namespace rawlab
