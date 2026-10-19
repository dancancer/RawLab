#pragma once
// 合成 Sony ARW6 容器与码流，只用于解码器边界回归，不含个人照片或内嵌 JPEG。
// 解码器会展开 LibRaw 的 width/height 等短宏，因此本文件须在解码器源码之前包含。
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

namespace sony_arw6_fixture {
using Bytes = std::vector<unsigned char>;

inline void putLe16(Bytes& bytes, size_t offset, uint32_t value) {
    bytes.at(offset) = static_cast<unsigned char>(value);
    bytes.at(offset + 1) = static_cast<unsigned char>(value >> 8);
}

inline void putLe32(Bytes& bytes, size_t offset, uint32_t value) {
    putLe16(bytes, offset, value & 0xffff);
    putLe16(bytes, offset + 2, value >> 16);
}

inline void putBe(Bytes& bytes, size_t offset, uint32_t value, int count) {
    for (int i = 0; i < count; ++i)
        bytes.at(offset + i) = static_cast<unsigned char>(value >> (8 * (count - 1 - i)));
}

class BitWriter {
public:
    void put(uint32_t value, int count) {
        for (int i = count - 1; i >= 0; --i) {
            if (bits_ % 8 == 0) bytes_.push_back(0);
            if ((value >> i) & 1) bytes_.back() |= static_cast<unsigned char>(0x80 >> (bits_ % 8));
            ++bits_;
        }
    }
    void zeros(int count) {
        for (int i = 0; i < count; ++i) put(0, 1);
    }
    Bytes padded(size_t size) const {
        Bytes out(bytes_);
        out.resize((out.size() + size - 1) / size * size, 0);
        return out;
    }

private:
    Bytes bytes_;
    size_t bits_ = 0;
};

inline int bitLength(int value) {
    int count = 0;
    for (; value; value >>= 1) ++count;
    return count;
}

// 一行系数：x 为 0 时整行为零；否则以 19 位宽写入 x，fullRow 决定只写首个系数还是整行。
inline void encodeRow(BitWriter& bits, int samples, uint32_t x, bool negative, bool fullRow) {
    const int groups = (samples + 3) / 4;
    auto zeroRun = [&](int remaining) {
        if (remaining > 1) bits.zeros(bitLength(remaining - 1));
    };
    if (!x) {
        bits.put(0, 1);
        zeroRun(groups);
        return;
    }
    bits.put(2, 2); bits.zeros(18); bits.put(1, 1);
    if (fullRow) {
        for (int group = 0; group < groups; ++group) {
            for (int i = 0; i < 4; ++i) bits.put(x, 19);
            if (group + 1 < groups) bits.put(0, 1);
            for (int i = 0; i < 4; ++i) bits.put(negative ? 1 : 0, 1);
        }
        return;
    }
    bits.put(x, 19); bits.zeros(19 * 3);
    if (groups > 1) { bits.put(3, 2); bits.zeros(18); }
    bits.put(negative ? 1 : 0, 1);
    zeroRun(groups - 1);
}

struct Record {
    Bytes payload;
    unsigned selectors[3] = {0, 0, 0};
};

inline Bytes packet(int type, const std::vector<Record>& records) {
    const size_t controlBits = 128 + records.size() * (16 + 4 * type);
    const uint32_t controlUnits = static_cast<uint32_t>((controlBits + 127) / 128);
    size_t payloadBytes = 0;
    for (const auto& record : records) payloadBytes += record.payload.size();
    BitWriter header;
    header.put(controlUnits - 1, 16); header.put(static_cast<uint32_t>(payloadBytes / 16), 24);
    header.put(4, 4); header.put(0, 4); header.put(type, 2); header.put(0, 6);
    header.put(static_cast<uint32_t>(records.size()), 16); header.put(0x10, 8); header.put(0, 8);
    header.zeros(40);
    for (const auto& record : records) {
        header.put(static_cast<uint32_t>(record.payload.size()), 16);
        for (int c = 0; c < type; ++c) header.put(record.selectors[c], 4);
    }
    Bytes out = header.padded(16);
    out.resize(size_t(controlUnits) * 16, 0);
    for (const auto& record : records) out.insert(out.end(), record.payload.begin(), record.payload.end());
    return out;
}

// 指定 (group, index, record, component) 位置的首个系数；record 为 -1 时写入每条记录。
// shift 为该分量的选择位。
struct Coefficient {
    int group, index, record, component;
    uint32_t x;
    unsigned shift;
    bool negative;
    bool fullRow;
};

// columns 为 16 的倍数；rows 为逻辑行数（Bayer 行），即码流 coded_half_height 的两倍。
inline Bytes arw6Stream(int columns, int rows, const std::vector<Coefficient>& coefficients = {}) {
    const int blocks = (rows + 15) / 16 + 1;
    Bytes out(0x80, 0);
    std::memcpy(out.data(), "A000", 4);
    putBe(out, 8, columns, 2); putBe(out, 0x0a, rows / 2, 2);
    putBe(out, 0x0c, 16 << 4, 2); putBe(out, 0x0e, (3 << 13) | (3 << 10), 2);
    for (int group = 0; group < 5; ++group) {
        const int type = group == 0 || group == 4 ? 1 : 3;
        const int samples = group == 0 ? columns / 16 : group == 4 ? columns / 2 : columns >> (5 - group);
        const int multiplier = group == 0 ? 1 : group == 4 ? 8 : 1 << (group - 1);
        const int entries = group == 4 ? 1 : 3;
        uint32_t groupLength = 0;
        for (int index = 0; index < entries; ++index) {
            std::vector<Record> records(blocks);
            for (int r = 0; r < blocks; ++r) {
                const Coefficient* chosen[3] = {nullptr, nullptr, nullptr};
                bool any = false;
                for (const auto& c : coefficients)
                    if (c.group == group && c.index == index && (c.record == r || c.record < 0) &&
                        c.component < type) {
                        chosen[c.component] = &c;
                        any = true;
                    }
                if (!any) continue;
                BitWriter bits;
                for (int component = 0; component < type; ++component) {
                    const auto* c = chosen[component];
                    if (c) records[r].selectors[component] = c->shift;
                    for (int row = 0; row < multiplier; ++row)
                        encodeRow(bits, samples, c ? c->x : 0, c && c->negative, c && c->fullRow);
                }
                records[r].payload = bits.padded(16);
            }
            const Bytes body = packet(type, records);
            putBe(out, 0x30 + 0x10 * group + 1 + 3 * index, static_cast<uint32_t>(body.size() >> 4), 3);
            groupLength += static_cast<uint32_t>(body.size());
            out.insert(out.end(), body.begin(), body.end());
        }
        out.at(0x30 + 0x10 * group) = static_cast<unsigned char>(entries);
        putBe(out, 0x10 + 3 * group, groupLength >> 4, 3);
    }
    return out;
}

// 单 tile 表，码流位于 0x200。
inline Bytes arw6Strip(const Bytes& stream, int tileColumns, int tileRows) {
    Bytes out(0x200, 0);
    putLe32(out, 0, 1);
    putLe32(out, 0x08, 0x200);
    putLe32(out, 0x18, static_cast<uint32_t>(tileColumns));
    putLe32(out, 0x1c, static_cast<uint32_t>(tileRows));
    out.insert(out.end(), stream.begin(), stream.end());
    return out;
}

// 最小 Sony ILCE-7M5 TIFF，单条带位于 1024。
inline Bytes arw6Tiff(uint32_t columns, uint32_t rows, const Bytes& strip, unsigned compression = 32766) {
    Bytes bytes(1024, 0);
    bytes[0] = bytes[1] = 'I'; putLe16(bytes, 2, 42); putLe32(bytes, 4, 8);
    putLe16(bytes, 8, 14);
    size_t entry = 10;
    auto tag = [&](unsigned id, unsigned type, unsigned count, uint32_t value) {
        putLe16(bytes, entry, id); putLe16(bytes, entry + 2, type); putLe32(bytes, entry + 4, count);
        putLe32(bytes, entry + 8, value); entry += 12;
    };
    tag(256, 4, 1, columns); tag(257, 4, 1, rows); tag(258, 3, 1, 14);
    tag(259, 3, 1, compression); tag(262, 3, 1, 32803);
    tag(271, 2, 5, 512); tag(272, 2, 9, 520);
    tag(273, 4, 1, 1024); tag(274, 3, 1, 1); tag(277, 3, 1, 1);
    tag(278, 4, 1, rows); tag(279, 4, 1, static_cast<uint32_t>(strip.size()));
    tag(33421, 3, 2, 0x00020002); tag(33422, 1, 4, 0x02010100);
    std::memcpy(bytes.data() + 512, "SONY", 5);
    std::memcpy(bytes.data() + 520, "ILCE-7M5", 9);
    bytes.insert(bytes.end(), strip.begin(), strip.end());
    return bytes;
}

inline Bytes tiledArw6(int tileColumns, int tileRows, const std::vector<Coefficient>& coefficients = {}) {
    return arw6Tiff(64, tileRows > 32 ? tileRows : 32,
        arw6Strip(arw6Stream(tileColumns, tileRows, coefficients), tileColumns, tileRows));
}

// 遍历各子带、记录和分量的正负大系数，覆盖逆小波、边缘细节、绿色重建和输出合成；
// 每条记录都写入时相邻行同时取大值。
// 32768 对应评审中的 1073758208，65535 对应不超过 INT32_MAX 的最大可编码幅值。
template <typename Decode>
void sweepLargeCoefficients(int tileRows, Decode&& decode) {
    for (int group = 0; group <= 4; ++group)
        for (int index = 0; index < (group == 4 ? 1 : 3); ++index)
            for (int record = -1; record < (tileRows + 15) / 16 + 1; ++record)
                for (int component = 0; component < (group == 0 || group == 4 ? 1 : 3); ++component)
                    for (uint32_t x : {32768u, 65535u})
                        for (bool negative : {false, true})
                            for (bool fullRow : {false, true})
                                decode(tiledArw6(64, tileRows,
                                    {{group, index, record, component, x, 15, negative, fullRow}}));
}

// 固定种子的多系数组合，覆盖需要多个子带同时取大值的重建路径。
// 只用 mt19937 原始输出取模，保证各标准库实现生成相同序列。
template <typename Decode>
void randomLargeCoefficients(int tileRows, int count, Decode&& decode) {
    std::mt19937 random(0x41525736u + static_cast<unsigned>(tileRows));
    auto pick = [&](int limit) { return static_cast<int>(random() % static_cast<unsigned>(limit)); };
    for (int i = 0; i < count; ++i) {
        std::vector<Coefficient> coefficients(2 + pick(7));
        for (auto& c : coefficients) {
            c.group = 1 + pick(4);
            c.index = c.group == 4 ? 0 : pick(3);
            c.record = pick((tileRows + 15) / 16 + 2) - 1;
            c.component = c.group == 4 ? 0 : pick(3);
            // 幅值 ((2x + 1) << (shift - 1)) - (x & 1) 不超过 INT32_MAX，跨越 2^28 到 2^31。
            c.x = 32768u + static_cast<uint32_t>(pick(32768));
            c.shift = 12u + static_cast<unsigned>(pick(4));
            c.negative = pick(2) != 0;
            c.fullRow = pick(2) != 0;
        }
        decode(tiledArw6(64, tileRows, coefficients));
    }
}
} // namespace sony_arw6_fixture
