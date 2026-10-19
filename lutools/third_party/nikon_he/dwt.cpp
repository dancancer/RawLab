// SPDX-License-Identifier: LGPL-2.1
// Copyright 2026
// Adapted from dnglab 0f044c2c, dwt.rs and mod.rs; see README.md.
#include "internal.h"
#include <algorithm>

namespace rawlab {
namespace nikon_he {
namespace {
void horizontal(const std::vector<int32_t> &low, size_t ln, const std::vector<int32_t> &high,
                size_t hn, std::vector<int32_t> &out) {
    const size_t n = ln + hn;
    if (n < 2 || ln != n - n / 2 || hn != n / 2)
        throw DecodeError("Invalid Nikon HE wavelet split");
    out[0] = narrow(int64_t(low[0]) - shift(int64_t(high[0]) + 1, 1));
    for (size_t k = 0; k < (n - 2) / 2; ++k) {
        out[2 * k + 2] = narrow(int64_t(low[k + 1]) - shift(int64_t(high[k]) + high[k + 1] + 2, 2));
        out[2 * k + 1] = narrow(int64_t(high[k]) + shift(int64_t(out[2 * k]) + out[2 * k + 2], 1));
    }
    if (n % 2) {
        out[n - 1] = narrow(int64_t(low[ln - 1]) - shift(int64_t(high[hn - 1]) + 1, 1));
        out[n - 2] = narrow(int64_t(high[hn - 1]) + shift(int64_t(out[n - 3]) + out[n - 1], 1));
    } else
        out[n - 1] = narrow(int64_t(high[hn - 1]) + out[n - 2]);
}
void extract(const BandData &band, size_t width, size_t line, const Header &h, int32_t *out) {
    const size_t groups = ceil_div(width, h.group_size);
    for (size_t i = 0; i < width; ++i) {
        const uint16_t v = band.coeff[line * width + i];
        uint32_t mag = v & 0x7fff;
        const auto gcli = band.gcli[line * groups + i / h.group_size];
        if (gcli > 15 || band.gtli > 15)
            throw DecodeError("Invalid Nikon HE precision");
        if (band.gtli && gcli > band.gtli && mag) {
            if (h.qpih) {
                const unsigned bits = gcli - band.gtli + 1;
                uint32_t value = mag;
                mag = 0;
                while (value) {
                    mag += value;
                    value >>= bits;
                }
            } else
                mag |= uint32_t(1) << (band.gtli - 1);
        }
        const int64_t value = (v & 0x8000) ? -int64_t(mag) : int64_t(mag);
        out[i] = narrow(value * (int64_t(1) << h.fq));
    }
}
} // namespace
std::vector<std::vector<int32_t>> inverse_wavelet(const uint8_t *stream, size_t size,
                                                  const Header &h, const Topology &t) {
    const size_t w = h.plane_width(), rows = h.plane_height(), count = h.precinct_count();
    if (w < 32 || rows < 2 || rows % h.precinct_height())
        throw UnsupportedError("Unsupported Nikon HE wavelet dimensions");
    std::vector<std::vector<int32_t>> planes(4, std::vector<int32_t>(w * rows));
    std::vector<std::vector<int32_t>> previous(4, std::vector<int32_t>(w));
    std::vector<int32_t> low(w), swap(w), high(w), hf(w);
    size_t offset = h.first_slice, precinct_index = 0;
    for (size_t slice = 0; slice < h.slice_count(); ++slice) {
        if (offset > size || size - offset < 6 || stream[offset] != 0xff ||
            stream[offset + 1] != 0x20 || stream[offset + 2] != 0 || stream[offset + 3] != 4 ||
            ((unsigned(stream[offset + 4]) << 8) | stream[offset + 5]) != slice)
            throw DecodeError("Invalid Nikon HE slice header");
        offset += 6;
        Precinct top;
        bool have_top = false;
        for (size_t line = 0; line < h.slice_height && precinct_index < count;
             ++line, ++precinct_index) {
            auto precinct =
                decode_precinct(stream, size, offset, h, t, have_top ? &top : nullptr, offset);
            const size_t p = precinct_index;
            for (size_t ci = 0; ci < 4; ++ci) {
                const auto range = t.component_bands[ci];
                if (h.components[ci].suppressed()) {
                    for (size_t row = 0; row < h.precinct_height(); ++row)
                        extract(precinct.bands[range.start], w, row, h,
                                planes[ci].data() + (p * h.precinct_height() + row) * w);
                    continue;
                }
                const size_t nlx = h.components[ci].nlx;
                size_t ln = t.bands[range.start].width;
                extract(precinct.bands[range.start], ln, 0, h, low.data());
                for (size_t b = 1; b <= nlx; ++b) {
                    const size_t hn = t.bands[range.start + b].width;
                    extract(precinct.bands[range.start + b], hn, 0, h, high.data());
                    horizontal(low, ln, high, hn, swap);
                    low.swap(swap);
                    ln += hn;
                }
                const size_t ln_h = t.bands[range.start + nlx + 1].width,
                             hn_h = t.bands[range.start + nlx + 2].width;
                extract(precinct.bands[range.start + nlx + 1], ln_h, 0, h, swap.data());
                extract(precinct.bands[range.start + nlx + 2], hn_h, 0, h, high.data());
                horizontal(swap, ln_h, high, hn_h, hf);
                auto &plane = planes[ci];
                auto &prev = previous[ci];
                if (!p)
                    for (size_t x = 0; x < w; ++x)
                        plane[x] = narrow(int64_t(low[x]) - shift(int64_t(hf[x]) + 1, 1));
                else {
                    const size_t even = 2 * p;
                    for (size_t x = 0; x < w; ++x)
                        plane[even * w + x] =
                            narrow(int64_t(low[x]) - shift(int64_t(prev[x]) + hf[x] + 2, 2));
                    for (size_t x = 0; x < w; ++x)
                        plane[(even - 1) * w + x] = narrow(
                            int64_t(prev[x]) +
                            shift(int64_t(plane[(even - 2) * w + x]) + plane[even * w + x], 1));
                }
                if (p == count - 1)
                    for (size_t x = 0; x < w; ++x)
                        plane[(2 * p + 1) * w + x] = narrow(int64_t(hf[x]) + plane[2 * p * w + x]);
                prev.swap(hf);
            }
            top = std::move(precinct);
            have_top = true;
        }
    }
    if (precinct_index != count || offset > size || size - offset != 2 || stream[offset] != 0xff ||
        stream[offset + 1] != 0x11)
        throw DecodeError("Invalid Nikon HE end of codestream");
    return planes;
}
} // namespace nikon_he
} // namespace rawlab
