#include "codec.h"
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;
using namespace rawlab::nikon_he;

void require(bool condition, const char *message) {
    if (!condition)
        throw std::runtime_error(message);
}
void word(Bytes &out, unsigned value) {
    out.push_back(static_cast<uint8_t>(value >> 8));
    out.push_back(static_cast<uint8_t>(value));
}
void segment(Bytes &out, unsigned marker, const Bytes &body) {
    word(out, marker);
    word(out, static_cast<unsigned>(body.size() + 2));
    out.insert(out.end(), body.begin(), body.end());
}

Bytes zeroStream(unsigned width, unsigned height, unsigned black = 1008, bool separateSigns = true,
                 int dc = 0) {
    Bytes out;
    word(out, 0xff10);
    Bytes cap{'C', 'O', 'N', 'T', 'A', 'C', 'T', '_',  'I',
              'N', 'T', 'O', 'P', 'I', 'X', '_', 0xef, 0xc0};
    cap.resize(32, 0);
    segment(out, 0xff50, cap);
    Bytes pih(8, 0);
    word(pih, width);
    word(pih, height);
    word(pih, 0);
    word(pih, 16);
    pih.insert(pih.end(),
               {4, 4, 8, 18, 0x44, 0x10, 0x51, static_cast<uint8_t>(separateSigns ? 0x14 : 0x10)});
    Bytes vendor{0x50,
                 0x88,
                 0x70,
                 static_cast<uint8_t>(0x80 | (black >> 8)),
                 static_cast<uint8_t>(black),
                 0x15,
                 0x23,
                 0xd1,
                 0x49,
                 0xcd,
                 0x3f,
                 0x7f,
                 7};
    pih.insert(pih.end(), vendor.begin(), vendor.end());
    segment(out, 0xff12, pih);
    segment(out, 0xff13, {14, 0x11, 0x51, 14, 0x11, 0x51, 14, 0x11, 0, 14, 0x11, 0x51});
    segment(out, 0xff14, Bytes(50, 0));
    // Independent packet lengths for plane widths 64 and 66. The latter has
    // partial trailing coefficient groups at several wavelet levels.
    const std::vector<unsigned> lengths =
        width == 128 ? std::vector<unsigned>{9, 9, 8, 9, 8, 8, 8, 8} : std::vector<unsigned>(8, 9);
    const unsigned count = height / 4;
    for (unsigned p = 0; p < count; ++p) {
        if (p % 16 == 0) {
            word(out, 0xff20);
            word(out, 4);
            word(out, p / 16);
        }
        Bytes payload;
        for (size_t packetIndex = 0; packetIndex < lengths.size(); ++packetIndex) {
            const auto length = lengths[packetIndex];
            const bool nonzero = dc != 0 && packetIndex == 0;
            Bytes packet{0x80,
                         0,
                         static_cast<uint8_t>(nonzero ? 8 : 0),
                         0,
                         static_cast<uint8_t>(length >> 1),
                         static_cast<uint8_t>((length & 1) << 7),
                         static_cast<uint8_t>(nonzero && separateSigns ? 1 : 0)};
            payload.insert(payload.end(), packet.begin(), packet.end());
            Bytes gcli(length, 0);
            if (nonzero)
                gcli[0] = 0x10;
            payload.insert(payload.end(), gcli.begin(), gcli.end());
            if (nonzero) {
                payload.push_back(separateSigns ? 0xf0 : dc < 0 ? 0xff : 0x0f);
                if (separateSigns)
                    payload.push_back(dc < 0 ? 0xf0 : 0);
            }
        }
        out.push_back(static_cast<uint8_t>(payload.size() >> 16));
        out.push_back(static_cast<uint8_t>(payload.size() >> 8));
        out.push_back(static_cast<uint8_t>(payload.size()));
        out.insert(out.end(), 9, 0); // Qp, Rp, then 25 two-bit modes, aligned.
        out.insert(out.end(), payload.begin(), payload.end());
    }
    word(out, 0xff11);
    const uint32_t size = static_cast<uint32_t>(out.size());
    for (unsigned i = 0; i < 4; ++i)
        out[42 + i] = static_cast<uint8_t>(size >> (24 - 8 * i));
    return out;
}
void rejects(const Bytes &bytes, size_t width, size_t height) {
    bool rejected = false;
    try {
        (void)decode(bytes.data(), bytes.size(), width, height);
    } catch (const DecodeError &) {
        rejected = true;
    }
    require(rejected, "invalid codestream must fail");
}
} // namespace

int main() {
    try {
        for (const unsigned width : {128u, 132u})
            for (const unsigned height : {4u, 8u, 68u})
                for (const bool signs : {false, true}) {
                    const auto stream = zeroStream(width, height, 1008, signs);
                    const auto raw = decode(stream.data(), stream.size(), width, height);
                    require(raw.size() == width * height, "decoded sensor dimensions");
                    require(
                        std::all_of(raw.begin(), raw.end(), [](uint16_t v) { return v == 2734; }),
                        "zero coefficients must follow the PIH integer transfer");
                }
        const auto shifted = zeroStream(128, 8, 1024);
        const auto shiftedRaw = decode(shifted.data(), shifted.size(), 128, 8);
        require(
            std::all_of(shiftedRaw.begin(), shiftedRaw.end(), [](uint16_t v) { return v == 2750; }),
            "black offset must come from each file, not a fitted constant");
        // A constant +/-1 DC band in component 0 reconstructs a uniform +/-16
        // Bayer plane after Fq=4; the file transfer gives these exact values.
        for (const unsigned width : {128u, 132u})
            for (const bool signs : {false, true})
                for (const int dc : {-1, 1}) {
                    const auto stream = zeroStream(width, 8, 1008, signs, dc);
                    const auto raw = decode(stream.data(), stream.size(), width, 8);
                    const uint16_t expected = dc < 0 ? 2731 : 2738;
                    require(std::all_of(raw.begin(), raw.end(),
                                        [expected](uint16_t v) { return v == expected; }),
                            "signed DC coefficients must reconstruct the exact sensor value");
                }
        const auto valid = zeroStream(128, 8);
        rejects({0, 0, 0, 0}, 128, 8);
        rejects(valid, 130, 8);
        for (size_t length = 0; length < valid.size(); ++length)
            rejects(Bytes(valid.begin(), valid.begin() + length), 128, 8);
        auto bad = valid;
        bad.back() ^= 1;
        rejects(bad, 128, 8);
        bad = valid;
        bad[42] = 0x7f;
        rejects(bad, 128, 8);
        bad = valid;
        bad[61] = 19;
        rejects(bad, 128, 8);
        bad = valid;
        bad[6] = 'X';
        rejects(bad, 128, 8);
        bad = valid;
        bad[66] ^= 1;
        rejects(bad, 128, 8);
        for (const uint8_t flag : {uint8_t(0x40), uint8_t(0x80)}) {
            bad = valid;
            bad[65] |= flag;
            rejects(bad, 128, 8);
        }
        for (size_t i = 0; i < valid.size(); ++i)
            for (unsigned bit = 0; bit < 8; ++bit) {
                bad = valid;
                bad[i] ^= uint8_t(1u << bit);
                try {
                    const auto raw = decode(bad.data(), bad.size(), 128, 8);
                    require(raw.size() == 1024, "mutated stream sensor dimensions");
                    require(
                        std::all_of(raw.begin(), raw.end(), [](uint16_t v) { return v <= 16383; }),
                        "mutated stream pixel range");
                } catch (const DecodeError &) {
                }
            }
        std::cout << "PASS: Nikon HE profiles, RAW packets, transfer, partial "
                     "widths, slice "
                     "boundaries and malformed input\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
