#include "model_package.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace sony2fuji::ai {
namespace {
constexpr std::array<uint32_t, 8> initialState{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                                             0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
uint32_t rotate(uint32_t value, unsigned count) { return (value >> count) | (value << (32 - count)); }

void compress(std::array<uint32_t, 8>& state, const uint8_t* block) {
    static constexpr uint32_t constants[] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    };
    uint32_t words[64];
    for (int i = 0; i < 16; ++i)
        words[i] = (uint32_t(block[4*i]) << 24) | (uint32_t(block[4*i+1]) << 16) |
                   (uint32_t(block[4*i+2]) << 8) | block[4*i+3];
    for (int i = 16; i < 64; ++i) {
        const uint32_t a = words[i-15], b = words[i-2];
        words[i] = words[i-16] + (rotate(a,7) ^ rotate(a,18) ^ (a >> 3)) + words[i-7] +
                   (rotate(b,17) ^ rotate(b,19) ^ (b >> 10));
    }
    auto working = state;
    for (int i = 0; i < 64; ++i) {
        const auto a = working[0], b = working[1], c = working[2], e = working[4], f = working[5], g = working[6];
        const uint32_t first = working[7] + (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) +
                               ((e & f) ^ (~e & g)) + constants[i] + words[i];
        const uint32_t second = (rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) + ((a & b) ^ (a & c) ^ (b & c));
        for (int j = 7; j > 0; --j) working[j] = working[j-1];
        working[4] += first; working[0] = first + second;
    }
    for (size_t i = 0; i < state.size(); ++i) state[i] += working[i];
}

std::string finishDigest(std::array<uint32_t, 8> state, const uint8_t* tail, size_t remaining, uint64_t bytes) {
    std::array<uint8_t, 128> buffer{};
    std::copy_n(tail, remaining, buffer.data());
    buffer[remaining] = 0x80;
    const size_t padding = remaining < 56 ? 64 : 128;
    const uint64_t bits = bytes * 8;
    for (int i = 0; i < 8; ++i) buffer[padding - 1 - i] = uint8_t(bits >> (8 * i));
    compress(state, buffer.data());
    if (padding == 128) compress(state, buffer.data() + 64);
    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (uint32_t value : state) output << std::setw(8) << value;
    return output.str();
}
}

std::string sha256Bytes(const void* data, size_t size) {
    if (!data && size) throw std::invalid_argument("invalid SHA-256 input");
    static const uint8_t empty = 0;
    const auto* input = data ? static_cast<const uint8_t*>(data) : &empty;
    auto state = initialState;
    size_t offset = 0;
    while (size - offset >= 64) { compress(state, input + offset); offset += 64; }
    return finishDigest(state, input + offset, size - offset, size);
}

std::string sha256File(const std::string& path) {
    std::ifstream input(std::filesystem::u8path(path), std::ios::binary);
    if (!input) throw std::runtime_error("Cannot read DualDn package file");
    auto state = initialState;
    std::array<uint8_t, 65536> buffer{};
    uint64_t bytes = 0;
    size_t remaining = 0;
    while (input) {
        input.read(reinterpret_cast<char*>(buffer.data()), buffer.size());
        const size_t count = static_cast<size_t>(input.gcount());
        bytes += count;
        size_t offset = 0;
        while (offset + 64 <= count) { compress(state, buffer.data() + offset); offset += 64; }
        remaining = count - offset;
        std::copy_n(buffer.data() + offset, remaining, buffer.data());
    }
    if (!input.eof()) throw std::runtime_error("Cannot finish reading DualDn package file");
    return finishDigest(state, buffer.data(), remaining, bytes);
}
} // namespace sony2fuji::ai
