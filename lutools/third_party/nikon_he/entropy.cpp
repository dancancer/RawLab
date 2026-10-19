// SPDX-License-Identifier: LGPL-2.1
// Copyright 2026
// Adapted from dnglab 0f044c2c, entropy.rs; see README.md.
#include "internal.h"
#include <algorithm>

namespace rawlab {
namespace nikon_he {
namespace {
void finish(BitReader &r, size_t start, size_t declared) {
    const size_t used = r.byte_pos() - start;
    if (used > declared)
        throw DecodeError("Nikon HE packet length mismatch");
    (void)r.bytes(declared - used);
}
size_t band_line(const Band &b, const Packet &p) { return b.lines_per_precinct > 1 ? p.line : 0; }
unsigned vertical(unsigned x, unsigned top, unsigned gtli) {
    const int threshold = std::max(int(top) - int(gtli), 0);
    const int delta = int(x) > 2 * threshold ? int(x) - threshold
                      : (x & 1)              ? -int((x + 1) / 2)
                                             : int(x / 2);
    const int result = int(top) + delta;
    if (result < 0 || result > 15)
        throw DecodeError("Invalid Nikon HE GCLI");
    return static_cast<unsigned>(result);
}
uint8_t data_line(BitReader &r, const uint8_t *gcli, size_t groups, uint8_t gtli, uint8_t fs,
                  uint16_t *out, size_t width) {
    uint8_t leftover = 0;
    for (size_t group = 0; group < groups; ++group) {
        uint16_t values[4] = {}, signs[4] = {};
        if (gcli[group] > 15)
            throw DecodeError("Invalid Nikon HE coefficient precision");
        if (gcli[group] > gtli) {
            if (!fs) {
                const auto s = r.nibble();
                for (unsigned j = 0; j < 4; ++j)
                    signs[j] = uint16_t(((s >> (3 - j)) & 1) << 15);
            }
            uint32_t acc[4] = {};
            for (unsigned plane = 0; plane < unsigned(gcli[group] - gtli); ++plane) {
                const auto v = r.nibble();
                for (unsigned j = 0; j < 4; ++j)
                    acc[j] = (acc[j] << 1) | ((v >> (3 - j)) & 1);
            }
            for (unsigned j = 0; j < 4; ++j)
                values[j] = uint16_t((acc[j] << gtli) | signs[j]);
        }
        const size_t start = group * 4, n = std::min(size_t(4), width - start);
        std::copy_n(values, n, out + start);
        if (n < 4)
            for (size_t j = n; j < 4; ++j)
                leftover += values[j] != 0;
    }
    return leftover;
}
} // namespace
Precinct decode_precinct(const uint8_t *buf, size_t size, size_t offset, const Header &h,
                         const Topology &t, const Precinct *top, size_t &next) {
    BitReader ph(buf, size, offset);
    const auto *fixed = ph.bytes(5);
    const size_t payload = (size_t(fixed[0]) << 16) | (size_t(fixed[1]) << 8) | fixed[2];
    std::vector<uint8_t> modes(t.bands.size());
    for (auto &m : modes)
        m = uint8_t(ph.bits(2));
    ph.align();
    const size_t start = ph.byte_pos();
    if (start > size || payload > size - start)
        throw DecodeError("Truncated Nikon HE precinct");
    const size_t end = start + payload;
    BitReader r(buf, end, start);
    Precinct out;
    for (const auto &b : t.bands)
        out.bands.push_back({b.gtli(fixed[3], fixed[4], 15),
                             std::vector<uint8_t>(b.lines_per_precinct * b.gcli_width),
                             std::vector<uint16_t>(b.lines_per_precinct * b.width)});
    for (const auto &packet : t.packets) {
        const auto *m = r.bytes(7);
        const bool raw = m[0] >> 7;
        const size_t data_len = ((size_t(m[0]) & 127) << 13) | (size_t(m[1]) << 5) | (m[2] >> 3);
        const size_t gcli_len =
            ((size_t(m[2]) & 7) << 17) | (size_t(m[3]) << 9) | (size_t(m[4]) << 1) | (m[5] >> 7);
        const size_t sign_len = ((size_t(m[5]) & 127) << 8) | m[6];
        if (raw) {
            const size_t begin = r.byte_pos();
            for (size_t id = packet.bands.start; id < packet.bands.end; ++id) {
                const auto &b = t.bands[id];
                auto &band = out.bands[id];
                const size_t base = band_line(b, packet) * b.gcli_width;
                for (size_t i = 0; i < b.gcli_width; ++i)
                    band.gcli[base + i] = uint8_t(r.nibble());
            }
            r.align();
            finish(r, begin, gcli_len);
        } else {
            std::vector<std::vector<uint8_t>> significance(packet.bands.end - packet.bands.start);
            for (size_t id = packet.bands.start; id < packet.bands.end; ++id)
                if (modes[id] & 2) {
                    auto &flags = significance[id - packet.bands.start];
                    flags.resize(t.bands[id].significance_width);
                    for (auto &flag : flags)
                        flag = uint8_t(r.bit());
                }
            r.align();
            const size_t begin = r.byte_pos();
            for (size_t id = packet.bands.start; id < packet.bands.end; ++id) {
                const auto &b = t.bands[id];
                auto &band = out.bands[id];
                const size_t line = band_line(b, packet);
                const auto &flags = significance[id - packet.bands.start];
                const uint8_t *reference = nullptr;
                uint8_t reference_gtli = 0;
                if (modes[id] & 1) {
                    if (line) {
                        reference = band.gcli.data() + (line - 1) * b.gcli_width;
                        reference_gtli = band.gtli;
                    } else if (top) {
                        reference =
                            top->bands[id].gcli.data() + (b.lines_per_precinct - 1) * b.gcli_width;
                        reference_gtli = top->bands[id].gtli;
                    }
                }
                for (size_t i = 0; i < b.gcli_width; ++i) {
                    const bool significant = flags.empty() || flags[i / h.sig_group_size] == 0;
                    unsigned v = band.gtli;
                    if (reference) {
                        const auto mt = std::max(reference[i], std::max(band.gtli, reference_gtli));
                        v = significant ? vertical(r.unary(), mt, band.gtli)
                            : h.rm      ? band.gtli
                                        : mt;
                    } else if (significant)
                        v += r.unary();
                    if (v > 15)
                        throw DecodeError("Invalid Nikon HE GCLI");
                    band.gcli[line * b.gcli_width + i] = uint8_t(v);
                }
            }
            r.align();
            finish(r, begin, gcli_len);
        }
        size_t begin = r.byte_pos();
        std::vector<uint8_t> leftover;
        for (size_t id = packet.bands.start; id < packet.bands.end; ++id) {
            const auto &b = t.bands[id];
            auto &band = out.bands[id];
            const size_t line = band_line(b, packet);
            leftover.push_back(data_line(r, band.gcli.data() + line * b.gcli_width, b.gcli_width,
                                         band.gtli, h.fs, band.coeff.data() + line * b.width,
                                         b.width));
        }
        r.align();
        finish(r, begin, data_len);
        if (h.fs) {
            begin = r.byte_pos();
            for (size_t id = packet.bands.start; id < packet.bands.end; ++id) {
                const auto &b = t.bands[id];
                auto &band = out.bands[id];
                const size_t base = band_line(b, packet) * b.width;
                for (size_t i = 0; i < b.width; ++i)
                    if (band.coeff[base + i])
                        band.coeff[base + i] |= uint16_t(r.bit() << 15);
                if (b.width % 4)
                    r.skip_bits(leftover[id - packet.bands.start]);
            }
            r.align();
            finish(r, begin, sign_len);
        } else if (sign_len)
            throw DecodeError("Unexpected Nikon HE sign packet");
    }
    next = end;
    return out;
}
} // namespace nikon_he
} // namespace rawlab
