// SPDX-License-Identifier: LGPL-2.1
// Whole-plane adaptation of LibRaw PR 826's Bayer reconstruction (Dmitri
// Sotnikov, 2026), with RdWing's documented bottom-edge and PIH transfer fixes.
#include "internal.h"
#include <algorithm>

namespace rawlab {
namespace nikon_he {
namespace {
int64_t sample(const std::vector<int32_t> &p, size_t r, size_t c, size_t w) { return p[r * w + c]; }
uint16_t transfer(int64_t v, const Header &h) {
    const auto &t = h.vendor;
    const int64_t black = ((t[3] & 15) << 8) | t[4];
    const int64_t gain = ((t[7] & 3) << 16) | (t[8] << 8) | t[9];
    const int64_t offset = (t[10] << 8) | t[11];
    const int64_t d = std::clamp(v + 32768, int64_t(0), int64_t(65535)) - offset;
    const int64_t rounded = shift(d * gain + 32768, 16);
    const int64_t q = d < 0 ? -d * d : rounded * rounded;
    return static_cast<uint16_t>(
        std::clamp(black + shift(q + 163840, 18), int64_t(0), int64_t(16383)));
}
} // namespace
std::vector<uint16_t> decode(const uint8_t *stream, size_t size, size_t expected_width,
                             size_t expected_height) {
    if (!stream || size < 2)
        throw DecodeError("Empty Nikon HE codestream");
    const auto h = parse(stream, size);
    if (h.grid_width != expected_width || h.grid_height != expected_height)
        throw DecodeError("Nikon HE dimensions disagree with NEF");
    if (expected_width > 134217728 / expected_height)
        throw DecodeError("Nikon HE image exceeds pixel limit");
    if (!h.lcod || h.lcod > size)
        throw DecodeError("Invalid Nikon HE codestream length");
    const auto topology = build(h);
    const auto p = inverse_wavelet(stream, h.lcod, h, topology);
    const size_t w = h.plane_width(), rows = h.plane_height();
    const auto &p1 = p[1];
    const auto &p2 = p[0];
    const auto &p3 = p[2];
    const auto &p4 = p[3];
    std::vector<int32_t> pred(w * rows), low(w * rows), high(w * rows);
    for (size_t r = 0; r < rows; ++r)
        for (size_t c = 0; c < w; ++c) {
            const size_t prev = r ? r - 1 : 0, next = std::min(c + 1, w - 1);
            pred[r * w + c] = narrow(sample(p2, r, c, w) -
                                     shift(sample(p3, r, c, w) + sample(p3, r, next, w) +
                                               sample(p3, prev, c, w) + sample(p3, prev, next, w),
                                           3));
        }
    for (size_t r = 0; r < rows; ++r)
        for (size_t c = 0; c < w; ++c) {
            const size_t pr = r ? r - 1 : 0, nr = std::min(r + 1, rows - 1), pc = c ? c - 1 : 0,
                         nc = std::min(c + 1, w - 1);
            const int64_t cur = pred[r * w + c];
            low[r * w + c] = narrow(cur - shift(sample(p1, r, c, w) + sample(p4, r, c, w) +
                                                    sample(p1, r, nc, w) + sample(p4, pr, c, w),
                                                3));
            const int64_t sum =
                cur + pred[nr * w + c] + int64_t(pred[r * w + pc]) + pred[nr * w + pc];
            high[r * w + c] = narrow(sample(p3, r, c, w) -
                                     shift(sample(p1, r, c, w) + sample(p4, r, c, w) +
                                               sample(p4, r, pc, w) + sample(p1, nr, c, w),
                                           3) +
                                     shift(sum, 2));
        }
    std::vector<uint16_t> out(expected_width * expected_height);
    for (size_t r = 0; r < rows; ++r)
        for (size_t c = 0; c < w; ++c) {
            const size_t pr = r ? r - 1 : 0, nr = std::min(r + 1, rows - 1), pc = c ? c - 1 : 0,
                         nc = std::min(c + 1, w - 1);
            const int64_t g1 = sample(low, r, c, w), g2 = sample(high, r, c, w);
            const int64_t red = sample(p1, r, c, w) +
                                shift(sample(low, r, pc, w) + sample(high, pr, c, w) + g2 + g1, 2);
            const int64_t blue = sample(p4, r, c, w) +
                                 shift(sample(high, r, nc, w) + g2 + g1 + sample(low, nr, c, w), 2);
            const size_t top = 2 * r * expected_width + 2 * c, bottom = top + expected_width;
            out[top] = transfer(red, h);
            out[top + 1] = transfer(g1, h);
            out[bottom] = transfer(g2, h);
            out[bottom + 1] = transfer(blue, h);
        }
    return out;
}
} // namespace nikon_he
} // namespace rawlab
