// SPDX-License-Identifier: LGPL-2.1
// Copyright 2026
// Adapted from dnglab 0f044c2c, header.rs and pi.rs; see README.md.
#include "internal.h"
#include <algorithm>

namespace rawlab {
namespace nikon_he {
namespace {
unsigned be16(const uint8_t *p) { return (unsigned(p[0]) << 8) | p[1]; }
} // namespace
Header parse(const uint8_t *buf, size_t size) {
    BitReader r(buf, size);
    if (be16(r.bytes(2)) != 0xff10)
        throw DecodeError("Missing Nikon HE SOC");
    Header h;
    bool cap = false, pih = false, cdt = false, wgt = false;
    unsigned ncomp = 0;
    for (;;) {
        const size_t here = r.byte_pos();
        const auto marker = be16(r.bytes(2));
        if (marker == 0xff20) {
            if (!cap || !pih || !cdt || !wgt || h.weights.size() != h.total_bands())
                throw DecodeError("Incomplete Nikon HE header");
            h.first_slice = here;
            if (!h.grid_width || !h.grid_height || h.grid_width % 2 || h.grid_height % 4 ||
                h.precinct_width || !h.slice_height || h.components.size() != 4 ||
                h.group_size != 4 || h.sig_group_size != 8 || h.bw != 18 || h.fq != 4 ||
                h.br != 4 || h.ppoc != 1 || h.cpih || h.nlx != 5 || h.nly != 1 || h.qpih > 1 ||
                h.fs > 1 || h.rm > 1 || h.lh || h.rl)
                throw UnsupportedError("Unsupported Nikon HE profile");
            const auto &v = h.vendor;
            // 固定字段标识当前 Nikon 传递函数，黑位、增益和偏移仍逐文件读取。
            if (v[0] != 0x50 || v[1] != 0x88 || v[2] != 0x70 || (v[3] & 0xf0) != 0x80 ||
                v[5] != 0x15 || v[6] != 0x23 || (v[7] & 0xfc) != 0xd0 || v[12] != 7)
                throw UnsupportedError("Unsupported Nikon HE transfer function");
            for (size_t i = 0; i < 4; ++i) {
                const auto &c = h.components[i];
                if (c.bit_depth != 14 || c.sx != 1 || c.sy != 1 ||
                    (i == 2 ? !c.suppressed() : c.nlx != 5 || c.nly != 1))
                    throw UnsupportedError("Unsupported Nikon HE component layout");
            }
            return h;
        }
        if (marker == 0xff11)
            throw DecodeError("Nikon HE EOC before slices");
        const auto len = be16(r.bytes(2));
        if (len < 2)
            throw DecodeError("Invalid Nikon HE marker size");
        const size_t body = len - 2;
        const auto *p = r.bytes(body);
        switch (marker) {
        case 0xff50: {
            static constexpr uint8_t signature[32] = {'C', 'O', 'N', 'T', 'A',  'C',
                                                      'T', '_', 'I', 'N', 'T',  'O',
                                                      'P', 'I', 'X', '_', 0xef, 0xc0};
            if (cap || pih || body != sizeof(signature) || !std::equal(p, p + body, signature))
                throw UnsupportedError("Unsupported Nikon HE capabilities");
            cap = true;
            break;
        }
        case 0xff12:
            if (pih || body != 37)
                throw UnsupportedError("Unsupported Nikon HE PIH");
            pih = true;
            h.lcod = (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
            h.grid_width = be16(p + 8);
            h.grid_height = be16(p + 10);
            h.precinct_width = be16(p + 12);
            h.slice_height = be16(p + 14);
            ncomp = p[16];
            h.group_size = p[17];
            h.sig_group_size = p[18];
            h.bw = p[19];
            h.fq = p[20] >> 4;
            h.br = p[20] & 15;
            h.ppoc = (p[21] >> 4) & 7;
            h.cpih = p[21] & 15;
            h.nlx = p[22] >> 4;
            h.nly = p[22] & 15;
            h.lh = p[23] >> 7;
            h.rl = (p[23] >> 6) & 1;
            h.qpih = (p[23] >> 4) & 3;
            h.fs = (p[23] >> 2) & 3;
            h.rm = p[23] & 3;
            std::copy_n(p + 24, 13, h.vendor.begin());
            break;
        case 0xff13:
            if (!pih || cdt || ncomp != 4 || body != 3 * ncomp)
                throw UnsupportedError("Unsupported Nikon HE CDT");
            cdt = true;
            for (size_t i = 0; i < ncomp; ++i)
                h.components.push_back({p[3 * i], uint8_t(p[3 * i + 1] >> 4),
                                        uint8_t(p[3 * i + 1] & 15), uint8_t(p[3 * i + 2] >> 4),
                                        uint8_t(p[3 * i + 2] & 15)});
            break;
        case 0xff14:
            if (!cdt || wgt || body % 2 || body / 2 != h.total_bands())
                throw DecodeError("Invalid Nikon HE WGT");
            wgt = true;
            for (size_t i = 0; i < body; i += 2)
                h.weights.emplace_back(p[i], p[i + 1]);
            break;
        default:
            throw UnsupportedError("Unknown Nikon HE marker");
        }
    }
}
Topology build(const Header &h) {
    Topology t;
    const auto w = h.plane_width();
    if (h.nly != 1 || !h.group_size || !h.sig_group_size || h.components.size() != 4)
        throw UnsupportedError("Unsupported Nikon HE topology");
    for (size_t ci = 0; ci < h.components.size(); ++ci) {
        const auto &c = h.components[ci];
        const size_t first = t.bands.size();
        std::vector<size_t> widths;
        if (c.suppressed())
            widths.push_back(w);
        else {
            if (c.nly != 1 || c.nlx > 5)
                throw UnsupportedError("Unsupported Nikon HE wavelet");
            size_t low = w;
            std::vector<size_t> high;
            for (unsigned j = 0; j < c.nlx; ++j) {
                high.push_back(low / 2);
                low -= low / 2;
            }
            widths.push_back(low);
            widths.insert(widths.end(), high.rbegin(), high.rend());
            widths.push_back(w - w / 2);
            widths.push_back(w / 2);
        }
        for (size_t local = 0; local < widths.size(); ++local) {
            const size_t gw = ceil_div(widths[local], h.group_size);
            t.bands.push_back({ci, local, widths[local], gw, ceil_div(gw, h.sig_group_size),
                               c.suppressed() ? h.precinct_height() : 1, 0, 0});
        }
        t.component_bands.push_back({first, t.bands.size()});
    }
    for (size_t half = 0; half < 2; ++half)
        for (size_t ci = 0; ci < h.components.size(); ++ci) {
            auto range = t.component_bands[ci];
            if (!h.components[ci].suppressed()) {
                size_t total = 0, acc = 0, split = range.start;
                for (size_t b = range.start; b < range.end; ++b)
                    total += t.bands[b].width * t.bands[b].lines_per_precinct;
                while (split < range.end) {
                    acc += t.bands[split].width * t.bands[split].lines_per_precinct;
                    ++split;
                    if (2 * acc >= total)
                        break;
                }
                if (!half)
                    range.end = split;
                else
                    range.start = split;
            }
            t.packets.push_back({ci, range, half});
        }
    std::vector<bool> seen(t.bands.size(), false);
    size_t assigned = 0;
    for (const auto &p : t.packets)
        for (size_t b = p.bands.start; b < p.bands.end; ++b)
            if (!seen[b]) {
                if (assigned >= h.weights.size())
                    throw DecodeError("Missing Nikon HE weights");
                seen[b] = true;
                t.bands[b].gain = h.weights[assigned].first;
                t.bands[b].priority = h.weights[assigned++].second;
            }
    if (assigned != h.weights.size() || assigned != t.bands.size())
        throw DecodeError("Inconsistent Nikon HE weights");
    return t;
}
} // namespace nikon_he
} // namespace rawlab
