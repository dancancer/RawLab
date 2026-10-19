// SPDX-License-Identifier: LGPL-2.1
#pragma once
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace rawlab {
namespace nikon_he {
struct DecodeError : std::runtime_error {
    using std::runtime_error::runtime_error;
};
struct UnsupportedError : DecodeError {
    using DecodeError::DecodeError;
};
// Decode a Nikon codestream to a 14-bit RGGB sensor mosaic, or throw
// DecodeError.
std::vector<uint16_t> decode(const uint8_t *, size_t, size_t, size_t);
} // namespace nikon_he
} // namespace rawlab
