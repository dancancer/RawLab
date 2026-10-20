#include "sony2fuji/ffi/sony2fuji_c.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef NOGDI
#define NOGDI
#endif
#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <array>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

namespace {

constexpr uint64_t kMaxDisplayPixels = 64000000ull;
constexpr size_t kMetadataChunkLimit = 16u * 1024u * 1024u;
constexpr size_t kAlphaTileBytes = 4u * 1024u * 1024u;

class StatusError final : public std::exception {
public:
    explicit StatusError(sony2fuji_status status) noexcept : status_(status) {}

    sony2fuji_status status() const noexcept { return status_; }

private:
    sony2fuji_status status_;
};

[[noreturn]] void fail(sony2fuji_status status) {
    throw StatusError(status);
}

void clearBuffer(sony2fuji_buffer* buffer) {
    if (!buffer) return;
    sony2fuji_release_buffer(buffer);
    *buffer = {};
    buffer->pixel_format = SONY2FUJI_PIXEL_RGB8;
}

void checkHr(HRESULT result, sony2fuji_status status = SONY2FUJI_STATUS_PROCESSING_ERROR) {
    if (FAILED(result)) {
        if (result == E_OUTOFMEMORY || result == WINCODEC_ERR_OUTOFMEMORY)
            fail(SONY2FUJI_STATUS_OUT_OF_MEMORY);
        fail(status);
    }
}

std::wstring utf8ToWide(const char* path) {
    if (!path || path[0] == '\0') fail(SONY2FUJI_STATUS_INVALID_ARGUMENT);
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (required <= 0) fail(SONY2FUJI_STATUS_INVALID_ARGUMENT);
    std::wstring result(static_cast<size_t>(required), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1,
            result.data(), required) <= 0) {
        fail(SONY2FUJI_STATUS_INVALID_ARGUMENT);
    }
    result.pop_back();
    return result;
}

std::string lowerExtension(const char* path) {
    if (!path) return {};
    const std::string value(path);
    const auto slash = value.find_last_of("/\\");
    const auto dot = value.find_last_of('.');
    if (dot == std::string::npos || (slash != std::string::npos && dot < slash)) return {};
    std::string extension = value.substr(dot + 1);
    for (auto& character : extension)
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return extension;
}

bool knownUnsupportedExtension(const std::string& extension) {
    return extension == "dng" || extension == "bmp" || extension == "gif" ||
        extension == "webp" || extension == "heic" || extension == "heif" ||
        extension == "avif" || extension == "jxl";
}

void requireRegularFile(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
        fail(SONY2FUJI_STATUS_IO_ERROR);
}

class ComApartment final {
public:
    ComApartment() {
        const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (result == RPC_E_CHANGED_MODE) return;
        if (FAILED(result)) {
            checkHr(result, result == E_OUTOFMEMORY ? SONY2FUJI_STATUS_OUT_OF_MEMORY :
                SONY2FUJI_STATUS_PROCESSING_ERROR);
        }
        initialized_ = true;
    }

    ~ComApartment() {
        if (initialized_) CoUninitialize();
    }

    ComApartment(const ComApartment&) = delete;
    ComApartment& operator=(const ComApartment&) = delete;

private:
    bool initialized_ = false;
};

class BinaryReader final {
public:
    explicit BinaryReader(const std::wstring& path) : file_(path, std::ios::binary) {
        if (!file_) fail(SONY2FUJI_STATUS_IO_ERROR);
    }

    void readExact(void* destination, size_t size) {
        if (size > static_cast<size_t>(std::numeric_limits<std::streamsize>::max()))
            fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
        file_.read(static_cast<char*>(destination), static_cast<std::streamsize>(size));
        if (!file_ || file_.gcount() != static_cast<std::streamsize>(size))
            fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    }

    uint8_t readByte() {
        uint8_t result = 0;
        readExact(&result, sizeof(result));
        return result;
    }

    uint16_t readU16BE() {
        const auto high = readByte();
        const auto low = readByte();
        return static_cast<uint16_t>((static_cast<uint16_t>(high) << 8) | low);
    }

    uint32_t readU32BE() {
        uint32_t result = 0;
        for (unsigned shift : {24u, 16u, 8u, 0u})
            result |= static_cast<uint32_t>(readByte()) << shift;
        return result;
    }

    void skip(uint64_t size) {
        std::array<char, 64u * 1024u> bytes{};
        while (size != 0) {
            const auto count = static_cast<std::streamsize>(std::min<uint64_t>(size, bytes.size()));
            file_.read(bytes.data(), count);
            if (!file_ || file_.gcount() != count) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            size -= static_cast<uint64_t>(count);
        }
    }

private:
    std::ifstream file_;
};

bool equalBytes(const uint8_t* data, size_t size, const char* value) {
    const auto length = std::strlen(value);
    return size >= length && std::memcmp(data, value, length) == 0;
}

bool containsInsensitive(const uint8_t* data, size_t size, const char* needle) {
    const auto length = std::strlen(needle);
    if (length == 0 || size < length) return false;
    for (size_t index = 0; index + length <= size; ++index) {
        bool match = true;
        for (size_t offset = 0; offset < length; ++offset) {
            const auto left = static_cast<unsigned char>(data[index + offset]);
            const auto right = static_cast<unsigned char>(needle[offset]);
            if (std::tolower(left) != std::tolower(right)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

uint16_t readEndian16(const uint8_t* data, bool littleEndian) {
    if (littleEndian)
        return static_cast<uint16_t>(data[0] | (static_cast<uint16_t>(data[1]) << 8));
    return static_cast<uint16_t>((static_cast<uint16_t>(data[0]) << 8) | data[1]);
}

uint32_t readEndian32(const uint8_t* data, bool littleEndian) {
    if (littleEndian) {
        return static_cast<uint32_t>(data[0]) |
            (static_cast<uint32_t>(data[1]) << 8) |
            (static_cast<uint32_t>(data[2]) << 16) |
            (static_cast<uint32_t>(data[3]) << 24);
    }
    return (static_cast<uint32_t>(data[0]) << 24) |
        (static_cast<uint32_t>(data[1]) << 16) |
        (static_cast<uint32_t>(data[2]) << 8) | data[3];
}

std::optional<uint32_t> parseExifOrientation(const uint8_t* data, size_t size) {
    if (size < 8) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    const bool littleEndian = data[0] == 'I' && data[1] == 'I';
    const bool bigEndian = data[0] == 'M' && data[1] == 'M';
    if (!littleEndian && !bigEndian) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    if (readEndian16(data + 2, littleEndian) != 42) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    const auto ifdOffset = static_cast<uint64_t>(readEndian32(data + 4, littleEndian));
    if (ifdOffset > size - 2) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    const auto count = readEndian16(data + ifdOffset, littleEndian);
    const auto entriesBytes = static_cast<uint64_t>(count) * 12u;
    if (entriesBytes > size - ifdOffset - 2u) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    for (uint16_t index = 0; index < count; ++index) {
        const auto* entry = data + ifdOffset + 2u + static_cast<uint64_t>(index) * 12u;
        const auto tag = readEndian16(entry, littleEndian);
        if (tag != 274) continue;
        const auto type = readEndian16(entry + 2, littleEndian);
        const auto valueCount = readEndian32(entry + 4, littleEndian);
        if (valueCount != 1 || (type != 3 && type != 4))
            fail(SONY2FUJI_STATUS_UNSUPPORTED);
        uint32_t value = 0;
        if (type == 3) {
            value = readEndian16(entry + 8, littleEndian);
        } else {
            value = readEndian32(entry + 8, littleEndian);
        }
        if (value < 1 || value > 8) fail(SONY2FUJI_STATUS_UNSUPPORTED);
        return value;
    }
    return std::nullopt;
}

struct MetadataInfo {
    uint32_t orientation = 1;
    bool orientationSpecified = false;
    bool colorProfileMarker = false;
    bool explicitSrgb = false;
};

void mergeOrientation(MetadataInfo& info, const std::optional<uint32_t>& value) {
    if (!value) return;
    if (info.orientationSpecified && info.orientation != *value)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    info.orientation = *value;
    info.orientationSpecified = true;
}

void scanPng(const std::wstring& path, MetadataInfo& info) {
    BinaryReader reader(path);
    static constexpr uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    uint8_t actualSignature[sizeof(signature)]{};
    reader.readExact(actualSignature, sizeof(actualSignature));
    if (std::memcmp(actualSignature, signature, sizeof(signature)) != 0)
        fail(SONY2FUJI_STATUS_PROCESSING_ERROR);

    bool seenHeader = false;
    bool seenEnd = false;
    bool hasGamma = false;
    bool hasChromaticities = false;
    size_t metadataBytes = 0;
    while (!seenEnd) {
        const auto length = reader.readU32BE();
        std::array<char, 4> type{};
        reader.readExact(type.data(), type.size());
        const auto is = [&type](const char* value) {
            return std::memcmp(type.data(), value, 4) == 0;
        };
        if (!is("IDAT") && !is("fdAT")) {
            if (length > kMetadataChunkLimit - metadataBytes)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            metadataBytes += length;
        }
        if (is("IHDR")) {
            if (seenHeader || length != 13) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            std::array<uint8_t, 13> header{};
            reader.readExact(header.data(), header.size());
            const auto width = readEndian32(header.data(), false);
            const auto height = readEndian32(header.data() + 4, false);
            if (width == 0 || height == 0) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            if (static_cast<uint64_t>(width) > kMaxDisplayPixels / height)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            seenHeader = true;
        } else if (is("cICP")) {
            if (length != 4) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            std::array<uint8_t, 4> cicp{};
            reader.readExact(cicp.data(), cicp.size());
            // PNG cICP's only accepted SDR form is BT.709/sRGB. In
            // particular, 9/16/0/1 is a valid BT.2020/PQ marker and is HDR.
            if (cicp[0] != 1 || cicp[1] != 13 || cicp[2] != 0 || cicp[3] != 1)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            info.explicitSrgb = true;
        } else if (is("acTL") || is("fcTL") || is("mDCv") || is("cLLi")) {
            fail(SONY2FUJI_STATUS_UNSUPPORTED);
        } else if (is("iCCP")) {
            info.colorProfileMarker = true;
            reader.skip(length);
        } else if (is("sRGB")) {
            if (length != 1) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            const auto renderingIntent = reader.readByte();
            if (renderingIntent > 3) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            info.explicitSrgb = true;
        } else if (is("gAMA") || is("cHRM")) {
            if (is("gAMA")) {
                if (length != 4) fail(SONY2FUJI_STATUS_UNSUPPORTED);
                hasGamma = true;
            } else {
                if (length != 32) fail(SONY2FUJI_STATUS_UNSUPPORTED);
                hasChromaticities = true;
            }
            reader.skip(length);
        } else if (is("eXIf")) {
            if (length > kMetadataChunkLimit) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            std::vector<uint8_t> exif(length);
            reader.readExact(exif.data(), exif.size());
            mergeOrientation(info, parseExifOrientation(exif.data(), exif.size()));
        } else if (is("iTXt")) {
            if (length > kMetadataChunkLimit) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            std::vector<uint8_t> text(length);
            reader.readExact(text.data(), text.size());
            if (containsInsensitive(text.data(), text.size(), "gainmap") ||
                containsInsensitive(text.data(), text.size(), "hdrgm") ||
                containsInsensitive(text.data(), text.size(), "hdrgainmap")) {
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            }
        } else {
            reader.skip(length);
        }
        reader.skip(4);
        if (is("IEND")) {
            if (length != 0) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            seenEnd = true;
        }
    }
    if (!seenHeader || !seenEnd) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    if (info.explicitSrgb && info.colorProfileMarker)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    if ((hasGamma || hasChromaticities) && !info.colorProfileMarker && !info.explicitSrgb)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
}

void scanJpeg(const std::wstring& path, MetadataInfo& info) {
    BinaryReader reader(path);
    if (reader.readByte() != 0xff || reader.readByte() != 0xd8)
        fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    size_t metadataBytes = 0;
    bool seenFrame = false;
    while (true) {
        uint8_t prefix = reader.readByte();
        while (prefix != 0xff) prefix = reader.readByte();
        uint8_t marker = reader.readByte();
        while (marker == 0xff) marker = reader.readByte();
        if (marker == 0xda || marker == 0xd9) {
            if (!seenFrame) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            return;
        }
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (marker == 0x00 || marker < 0xc0) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
        const auto length = reader.readU16BE();
        if (length < 2) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
        const auto payloadLength = static_cast<size_t>(length - 2);
        const bool frameMarker = marker >= 0xc0 && marker <= 0xcf &&
            marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
        if (frameMarker) {
            if (seenFrame || payloadLength < 6) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            if (marker != 0xc0 && marker != 0xc1 && marker != 0xc2)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            const auto precision = reader.readByte();
            const auto height = reader.readU16BE();
            const auto width = reader.readU16BE();
            const auto components = reader.readByte();
            if (precision != 8 || components != 3) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            if (width == 0 || height == 0 || payloadLength != 6u + components * 3u)
                fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            if (static_cast<uint64_t>(width) > kMaxDisplayPixels / height)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            reader.skip(payloadLength - 6);
            seenFrame = true;
        } else if (marker >= 0xe0 && marker <= 0xef) {
            if (payloadLength > kMetadataChunkLimit - metadataBytes)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            metadataBytes += payloadLength;
            std::vector<uint8_t> payload(payloadLength);
            reader.readExact(payload.data(), payload.size());
            if (marker == 0xe2 && equalBytes(payload.data(), payload.size(), "MPF\0"))
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            if (marker == 0xe2 && equalBytes(payload.data(), payload.size(), "ICC_PROFILE\0"))
                info.colorProfileMarker = true;
            if (marker == 0xe1 && equalBytes(payload.data(), payload.size(), "Exif\0\0"))
                mergeOrientation(info, parseExifOrientation(payload.data() + 6, payload.size() - 6));
            if (marker == 0xe1 &&
                (containsInsensitive(payload.data(), payload.size(), "gainmap") ||
                 containsInsensitive(payload.data(), payload.size(), "hdrgm") ||
                 containsInsensitive(payload.data(), payload.size(), "hdrgainmap"))) {
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            }
        } else {
            reader.skip(payloadLength);
        }
    }
}

class TiffReader final {
public:
    explicit TiffReader(const std::wstring& path) : file_(path, std::ios::binary) {
        if (!file_) fail(SONY2FUJI_STATUS_IO_ERROR);
        file_.seekg(0, std::ios::end);
        const auto end = file_.tellg();
        if (end < 0) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
        size_ = static_cast<uint64_t>(end);
        file_.seekg(0, std::ios::beg);
    }

    uint64_t size() const noexcept { return size_; }

    void ensure(uint64_t offset, uint64_t length) const {
        if (offset > size_ || length > size_ - offset)
            fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    }

    void readAt(uint64_t offset, void* destination, size_t length) {
        ensure(offset, length);
        if (length > static_cast<size_t>(std::numeric_limits<std::streamsize>::max()))
            fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
        file_.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
        file_.read(static_cast<char*>(destination), static_cast<std::streamsize>(length));
        if (!file_ || file_.gcount() != static_cast<std::streamsize>(length))
            fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    }

    uint16_t read16(uint64_t offset, bool littleEndian) {
        std::array<uint8_t, 2> bytes{};
        readAt(offset, bytes.data(), bytes.size());
        return readEndian16(bytes.data(), littleEndian);
    }

    uint32_t read32(uint64_t offset, bool littleEndian) {
        std::array<uint8_t, 4> bytes{};
        readAt(offset, bytes.data(), bytes.size());
        return readEndian32(bytes.data(), littleEndian);
    }

private:
    std::ifstream file_;
    uint64_t size_ = 0;
};

struct TiffEntry {
    uint16_t tag = 0;
    uint16_t type = 0;
    uint32_t count = 0;
    uint64_t dataOffset = 0;
    uint64_t dataBytes = 0;
};

uint32_t tiffTypeSize(uint16_t type) {
    switch (type) {
        case 1: case 2: case 6: case 7: return 1;
        case 3: case 8: return 2;
        case 4: case 9: case 11: return 4;
        case 5: case 10: case 12: return 8;
        default: fail(SONY2FUJI_STATUS_UNSUPPORTED);
    }
}

TiffEntry readTiffEntry(TiffReader& reader, uint64_t offset, bool littleEndian) {
    std::array<uint8_t, 12> bytes{};
    reader.readAt(offset, bytes.data(), bytes.size());
    TiffEntry result;
    result.tag = readEndian16(bytes.data(), littleEndian);
    result.type = readEndian16(bytes.data() + 2, littleEndian);
    result.count = readEndian32(bytes.data() + 4, littleEndian);
    const auto typeSize = static_cast<uint64_t>(tiffTypeSize(result.type));
    if (result.count > std::numeric_limits<uint64_t>::max() / typeSize)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    result.dataBytes = static_cast<uint64_t>(result.count) * typeSize;
    result.dataOffset = result.dataBytes <= 4
        ? offset + 8u : readEndian32(bytes.data() + 8, littleEndian);
    reader.ensure(result.dataOffset, result.dataBytes);
    return result;
}

std::vector<uint8_t> readTiffData(TiffReader& reader, const TiffEntry& entry, size_t limit) {
    if (entry.dataBytes > limit || entry.dataBytes > std::numeric_limits<size_t>::max())
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    std::vector<uint8_t> result(static_cast<size_t>(entry.dataBytes));
    if (!result.empty()) reader.readAt(entry.dataOffset, result.data(), result.size());
    return result;
}

std::vector<uint32_t> readTiffUnsignedValues(TiffReader& reader, const TiffEntry& entry,
                                             bool littleEndian, size_t limit = 4096) {
    if (entry.type != 3 && entry.type != 4)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    const auto bytes = readTiffData(reader, entry, limit);
    std::vector<uint32_t> result;
    result.reserve(entry.count);
    for (uint32_t index = 0; index < entry.count; ++index) {
        result.push_back(entry.type == 3
            ? readEndian16(bytes.data() + static_cast<size_t>(index) * 2, littleEndian)
            : readEndian32(bytes.data() + static_cast<size_t>(index) * 4, littleEndian));
    }
    return result;
}

void scanTiff(const std::wstring& path, MetadataInfo& info) {
    TiffReader reader(path);
    if (reader.size() < 8) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    std::array<uint8_t, 8> header{};
    reader.readAt(0, header.data(), header.size());
    const bool littleEndian = header[0] == 'I' && header[1] == 'I';
    const bool bigEndian = header[0] == 'M' && header[1] == 'M';
    if (!littleEndian && !bigEndian) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    const auto magic = readEndian16(header.data() + 2, littleEndian);
    if (magic == 43) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    if (magic != 42) fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    const auto ifdOffset = static_cast<uint64_t>(readEndian32(header.data() + 4, littleEndian));
    reader.ensure(ifdOffset, 2);
    const auto count = reader.read16(ifdOffset, littleEndian);
    if (count > 4096 || static_cast<uint64_t>(count) * 12u > reader.size() - ifdOffset - 2u)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);

    bool hasWidth = false;
    bool hasHeight = false;
    bool hasPhotometric = false;
    uint64_t width = 0;
    uint64_t height = 0;
    bool nonIccColorMetadata = false;
    size_t metadataBytes = 0;
    for (uint16_t index = 0; index < count; ++index) {
        const auto entryOffset = ifdOffset + 2u + static_cast<uint64_t>(index) * 12u;
        const auto entry = readTiffEntry(reader, entryOffset, littleEndian);
        if (entry.tag == 34675) {
            if (entry.dataBytes > kMetadataChunkLimit - metadataBytes)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            metadataBytes += static_cast<size_t>(entry.dataBytes);
            info.colorProfileMarker = true;
            continue;
        }
        if (entry.tag == 700) {
            if (entry.dataBytes > kMetadataChunkLimit - metadataBytes)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            metadataBytes += static_cast<size_t>(entry.dataBytes);
            const auto xmp = readTiffData(reader, entry, kMetadataChunkLimit);
            if (containsInsensitive(xmp.data(), xmp.size(), "gainmap") ||
                containsInsensitive(xmp.data(), xmp.size(), "hdrgm") ||
                containsInsensitive(xmp.data(), xmp.size(), "hdrgainmap"))
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            continue;
        }
        if (entry.tag == 270) {
            if (entry.dataBytes > kMetadataChunkLimit - metadataBytes)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            metadataBytes += static_cast<size_t>(entry.dataBytes);
            const auto description = readTiffData(reader, entry, kMetadataChunkLimit);
            if (containsInsensitive(description.data(), description.size(), "gainmap") ||
                containsInsensitive(description.data(), description.size(), "hdrgm") ||
                containsInsensitive(description.data(), description.size(), "hdrgainmap"))
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            continue;
        }
        if (entry.tag == 256 || entry.tag == 257) {
            const auto values = readTiffUnsignedValues(reader, entry, littleEndian);
            if (values.size() != 1 || values[0] == 0)
                fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
            if (entry.tag == 256) {
                hasWidth = true;
                width = values[0];
            } else {
                hasHeight = true;
                height = values[0];
            }
            continue;
        }
        if (entry.tag == 258) {
            const auto values = readTiffUnsignedValues(reader, entry, littleEndian);
            if (values.empty()) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            for (const auto value : values)
                if (value != 8) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            continue;
        }
        if (entry.tag == 262) {
            const auto values = readTiffUnsignedValues(reader, entry, littleEndian);
            if (values.size() != 1 || values[0] != 2)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            hasPhotometric = true;
            continue;
        }
        if (entry.tag == 274) {
            const auto values = readTiffUnsignedValues(reader, entry, littleEndian);
            if (values.size() != 1 || values[0] < 1 || values[0] > 8)
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            mergeOrientation(info, values[0]);
            continue;
        }
        if (entry.tag == 339) {
            const auto values = readTiffUnsignedValues(reader, entry, littleEndian);
            if (values.empty()) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            for (const auto value : values)
                if (value != 1) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            continue;
        }
        if (entry.tag == 301 || entry.tag == 318 || entry.tag == 319 ||
            entry.tag == 529 || entry.tag == 531 || entry.tag == 532) {
            nonIccColorMetadata = true;
        }
    }
    if (!hasWidth || !hasHeight || !hasPhotometric)
        fail(SONY2FUJI_STATUS_PROCESSING_ERROR);
    if (width > kMaxDisplayPixels / height)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    if (nonIccColorMetadata && !info.colorProfileMarker)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
}

enum class ContainerKind { Jpeg, Png, Tiff };

ContainerKind containerKind(const GUID& container) {
    if (IsEqualGUID(container, GUID_ContainerFormatJpeg)) return ContainerKind::Jpeg;
    if (IsEqualGUID(container, GUID_ContainerFormatPng)) return ContainerKind::Png;
    if (IsEqualGUID(container, GUID_ContainerFormatTiff)) return ContainerKind::Tiff;
    fail(SONY2FUJI_STATUS_UNSUPPORTED);
}

bool missingMetadataProperty(HRESULT result) {
    return result == WINCODEC_ERR_PROPERTYNOTFOUND ||
        result == WINCODEC_ERR_PROPERTYNOTSUPPORTED ||
        result == WINCODEC_ERR_UNSUPPORTEDOPERATION;
}

std::optional<uint32_t> metadataOrientation(IWICBitmapFrameDecode* frame, ContainerKind kind) {
    ComPtr<IWICMetadataQueryReader> reader;
    const auto readerResult = frame->GetMetadataQueryReader(&reader);
    if (FAILED(readerResult)) {
        if (readerResult == WINCODEC_ERR_UNSUPPORTEDOPERATION) return std::nullopt;
        checkHr(readerResult);
    }
    std::array<const wchar_t*, 3> queries{};
    size_t queryCount = 0;
    if (kind == ContainerKind::Tiff) {
        queries[queryCount++] = L"/ifd/{ushort=274}";
    } else if (kind == ContainerKind::Jpeg) {
        queries[queryCount++] = L"/app1/ifd/{ushort=274}";
        queries[queryCount++] = L"/ifd/{ushort=274}";
    } else {
        queries[queryCount++] = L"/eXIf/{ushort=274}";
        queries[queryCount++] = L"/ifd/{ushort=274}";
    }
    std::optional<uint32_t> result;
    for (size_t index = 0; index < queryCount; ++index) {
        PROPVARIANT value{};
        const auto metadataResult = reader->GetMetadataByName(queries[index], &value);
        if (SUCCEEDED(metadataResult)) {
            uint32_t orientation = 0;
            switch (value.vt) {
                case VT_UI1: orientation = value.bVal; break;
                case VT_UI2: orientation = value.uiVal; break;
                case VT_UI4: orientation = value.ulVal; break;
                case VT_I1: orientation = static_cast<uint32_t>(value.cVal); break;
                case VT_I2: orientation = static_cast<uint32_t>(value.iVal); break;
                case VT_I4: orientation = static_cast<uint32_t>(value.lVal); break;
                default:
                    PropVariantClear(&value);
                    fail(SONY2FUJI_STATUS_UNSUPPORTED);
            }
            PropVariantClear(&value);
            if (orientation < 1 || orientation > 8) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            if (result && *result != orientation) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            result = orientation;
        } else if (!missingMetadataProperty(metadataResult)) {
            PropVariantClear(&value);
            checkHr(metadataResult);
        }
    }
    return result;
}

struct IccTag {
    uint32_t signature = 0;
    uint32_t offset = 0;
    uint32_t size = 0;
};

uint32_t readBe32(const uint8_t* data) {
    return (static_cast<uint32_t>(data[0]) << 24) |
        (static_cast<uint32_t>(data[1]) << 16) |
        (static_cast<uint32_t>(data[2]) << 8) | data[3];
}

bool tagName(const uint8_t* data, const char* name) {
    return std::memcmp(data, name, 4) == 0;
}

bool isSdrIccProfile(const std::vector<uint8_t>& profile) {
    if (profile.size() < 132) return false;
    const auto declaredSize = readBe32(profile.data());
    if (declaredSize < 132 || declaredSize > profile.size()) return false;
    if (!tagName(profile.data() + 36, "acsp") || !tagName(profile.data() + 16, "RGB ")) return false;
    if (!tagName(profile.data() + 20, "XYZ ") && !tagName(profile.data() + 20, "Lab ")) return false;
    const auto tagCount = readBe32(profile.data() + 128);
    if (tagCount > 1024 || 132u + static_cast<uint64_t>(tagCount) * 12u > declaredSize) return false;
    const auto classIsDisplay = tagName(profile.data() + 12, "mntr");
    const auto classIsOutput = tagName(profile.data() + 12, "prtr");
    if (!classIsDisplay && !classIsOutput) return false;

    std::vector<IccTag> tags;
    tags.reserve(tagCount);
    for (uint32_t index = 0; index < tagCount; ++index) {
        const auto* entry = profile.data() + 132u + static_cast<size_t>(index) * 12u;
        IccTag tag{readBe32(entry), readBe32(entry + 4), readBe32(entry + 8)};
        if (tag.offset < 128 || tag.offset > declaredSize || tag.size > declaredSize - tag.offset)
            return false;
        tags.push_back(tag);
        const auto* bytes = profile.data() + tag.offset;
        if (tagName(entry, "desc") || tagName(entry, "mluc")) {
            if (containsInsensitive(bytes, tag.size, "hdr") ||
                containsInsensitive(bytes, tag.size, "pq") ||
                containsInsensitive(bytes, tag.size, "hlg") ||
                containsInsensitive(bytes, tag.size, "gainmap") ||
                containsInsensitive(bytes, tag.size, "extended") ||
                containsInsensitive(bytes, tag.size, "bt.2020") ||
                containsInsensitive(bytes, tag.size, "rec.2020")) return false;
        }
        if (tagName(entry, "cicp")) {
            if (tag.size < 12) return false;
            const auto primaries = bytes[8];
            const auto transfer = bytes[9];
            const auto matrix = bytes[10];
            const auto fullRange = bytes[11];
            if ((primaries != 1 && primaries != 12) || transfer != 13 ||
                matrix != 0 || fullRange != 1)
                return false;
        }
    }

    uint32_t transferMask = 0;
    for (const auto& tag : tags) {
        const auto isTransferCurve = [&tag](const char* name) {
            uint32_t signature = 0;
            for (const auto character : std::string(name))
                signature = (signature << 8) | static_cast<unsigned char>(character);
            return tag.signature == signature;
        };
        if (!isTransferCurve("rTRC") && !isTransferCurve("gTRC") &&
            !isTransferCurve("bTRC")) continue;
        if (isTransferCurve("rTRC")) transferMask |= 1;
        if (isTransferCurve("gTRC")) transferMask |= 2;
        if (isTransferCurve("bTRC")) transferMask |= 4;
        const auto* bytes = profile.data() + tag.offset;
        if (tag.size < 12) return false;
        if (tagName(bytes, "para")) {
            const auto functionType = static_cast<uint16_t>((bytes[8] << 8) | bytes[9]);
            if (functionType >= 4) return false;
            const auto parameterCount = functionType == 0 ? 1u : functionType == 1 ? 3u :
                functionType == 2 ? 4u : 5u;
            const auto expectedSize = 12u + static_cast<uint64_t>(parameterCount) * 4u;
            if (tag.size < expectedSize) return false;
            for (uint32_t parameter = 0; parameter < parameterCount; ++parameter) {
                const auto* value = bytes + 12u + parameter * 4u;
                const auto raw = static_cast<int32_t>(readBe32(value));
                if (raw == std::numeric_limits<int32_t>::min()) return false;
                const auto number = static_cast<double>(raw) / 65536.0;
                if (!std::isfinite(number) || std::abs(number) > 64.0 ||
                    (parameter == 0 && number <= 0.0)) return false;
            }
        } else if (!tagName(bytes, "curv")) {
            return false;
        } else {
            if (tag.size < 12) return false;
            const auto count = readBe32(bytes + 8);
            if (count == 0) return false;
            if (count > (tag.size - 12u) / 2u) return false;
            if (count == 1) {
                const auto gamma = readEndian16(bytes + 12, false);
                if (gamma == 0 || gamma > 0x400) return false;
            }
        }
    }
    return transferMask == 7;
}

struct ColorSource {
    ComPtr<IWICColorContext> context;
    bool transformToSrgb = false;
};

ColorSource getColorSource(IWICImagingFactory* factory, IWICBitmapFrameDecode* frame,
                           bool profileMarker) {
    UINT count = 0;
    const auto countResult = frame->GetColorContexts(0, nullptr, &count);
    if (FAILED(countResult) && countResult != WINCODEC_ERR_INSUFFICIENTBUFFER) {
        if (countResult == WINCODEC_ERR_UNSUPPORTEDOPERATION && !profileMarker) return {};
        checkHr(countResult, SONY2FUJI_STATUS_UNSUPPORTED);
    }
    if (count == 0) {
        if (profileMarker) fail(SONY2FUJI_STATUS_UNSUPPORTED);
        return {};
    }
    if (count > 16) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    ColorSource result;
    std::vector<ComPtr<IWICColorContext>> contexts(count);
    std::vector<IWICColorContext*> rawContexts(count, nullptr);
    for (UINT index = 0; index < count; ++index)
        checkHr(factory->CreateColorContext(&contexts[index]), SONY2FUJI_STATUS_UNSUPPORTED);
    for (UINT index = 0; index < count; ++index)
        rawContexts[index] = contexts[index].Get();
    UINT actualCount = 0;
    checkHr(frame->GetColorContexts(count, rawContexts.data(), &actualCount),
        SONY2FUJI_STATUS_UNSUPPORTED);
    if (actualCount != count) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    bool exifSrgb = false;
    bool unsupportedExif = false;
    for (const auto& context : contexts) {
        WICColorContextType type = WICColorContextUninitialized;
        checkHr(context->GetType(&type), SONY2FUJI_STATUS_UNSUPPORTED);
        if (type == WICColorContextProfile) {
            if (result.context) fail(SONY2FUJI_STATUS_UNSUPPORTED);
            result.context = context;
        } else if (type == WICColorContextExifColorSpace) {
            UINT exifColorSpace = 0;
            checkHr(context->GetExifColorSpace(&exifColorSpace), SONY2FUJI_STATUS_UNSUPPORTED);
            exifSrgb |= exifColorSpace == 1;
            unsupportedExif |= exifColorSpace != 1;
        } else {
            fail(SONY2FUJI_STATUS_UNSUPPORTED);
        }
    }
    // WIC 会同时返回 ICC 和 EXIF 色彩标记；有效 ICC 是实际色彩转换的依据。
    if (!result.context) {
        if (profileMarker || !exifSrgb || unsupportedExif) fail(SONY2FUJI_STATUS_UNSUPPORTED);
        return {};
    }
    UINT profileSize = 0;
    const auto profileSizeResult = result.context->GetProfileBytes(0, nullptr, &profileSize);
    if (FAILED(profileSizeResult) && profileSizeResult != WINCODEC_ERR_INSUFFICIENTBUFFER)
        checkHr(profileSizeResult, SONY2FUJI_STATUS_UNSUPPORTED);
    if (profileSize == 0 || profileSize > kMetadataChunkLimit) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    std::vector<uint8_t> profile(profileSize);
    checkHr(result.context->GetProfileBytes(profileSize, profile.data(), &profileSize),
        SONY2FUJI_STATUS_UNSUPPORTED);
    if (!isSdrIccProfile(profile)) fail(SONY2FUJI_STATUS_UNSUPPORTED);
    result.transformToSrgb = true;
    return result;
}

enum class SourceFormat { Rgb24, Rgb32, Rgba32 };

struct SourceDescription {
    SourceFormat format = SourceFormat::Rgb24;
    UINT width = 0;
    UINT height = 0;
};

SourceDescription describeSource(IWICBitmapFrameDecode* frame) {
    GUID format{};
    checkHr(frame->GetPixelFormat(&format));
    SourceDescription result;
    if (IsEqualGUID(format, GUID_WICPixelFormat24bppBGR) ||
        IsEqualGUID(format, GUID_WICPixelFormat24bppRGB)) {
        result.format = SourceFormat::Rgb24;
    } else if (IsEqualGUID(format, GUID_WICPixelFormat32bppBGR) ||
               IsEqualGUID(format, GUID_WICPixelFormat32bppRGB)) {
        result.format = SourceFormat::Rgb32;
    } else if (IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA) ||
               IsEqualGUID(format, GUID_WICPixelFormat32bppRGBA)) {
        result.format = SourceFormat::Rgba32;
    } else {
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    }
    checkHr(frame->GetSize(&result.width, &result.height));
    if (result.width == 0 || result.height == 0 ||
        static_cast<uint64_t>(result.width) > kMaxDisplayPixels / result.height ||
        result.width > UINT32_MAX / 4u) {
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    }
    return result;
}

void validateAlpha(IWICBitmapFrameDecode* frame, const SourceDescription& description) {
    if (description.format != SourceFormat::Rgba32) return;
    constexpr UINT kTileWidth = 4096;
    const UINT tileWidth = std::min<UINT>(description.width, kTileWidth);
    const UINT bytesPerPixel = 4;
    const UINT stride = tileWidth * bytesPerPixel;
    const UINT tileRows = std::max<UINT>(1, static_cast<UINT>(kAlphaTileBytes / stride));
    std::vector<uint8_t> pixels(static_cast<size_t>(stride) * tileRows);
    for (UINT y = 0; y < description.height; y += tileRows) {
        const UINT rows = std::min<UINT>(tileRows, description.height - y);
        for (UINT x = 0; x < description.width; x += tileWidth) {
            const UINT columns = std::min<UINT>(tileWidth, description.width - x);
            const UINT tileStride = columns * bytesPerPixel;
            const auto needed = static_cast<size_t>(tileStride) * rows;
            if (pixels.size() < needed) pixels.resize(needed);
            WICRect rectangle{static_cast<INT>(x), static_cast<INT>(y),
                static_cast<INT>(columns), static_cast<INT>(rows)};
            checkHr(frame->CopyPixels(&rectangle, tileStride, static_cast<UINT>(needed), pixels.data()));
            for (UINT row = 0; row < rows; ++row) {
                const auto* line = pixels.data() + static_cast<size_t>(row) * tileStride;
                for (UINT column = 0; column < columns; ++column) {
                    if (line[column * bytesPerPixel + 3] != 255)
                        fail(SONY2FUJI_STATUS_UNSUPPORTED);
                }
            }
        }
    }
}

WICBitmapTransformOptions transformForOrientation(uint32_t orientation) {
    switch (orientation) {
        case 1: return WICBitmapTransformRotate0;
        case 2: return WICBitmapTransformFlipHorizontal;
        case 3: return WICBitmapTransformRotate180;
        case 4: return WICBitmapTransformFlipVertical;
        case 5: return static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate270 |
            WICBitmapTransformFlipHorizontal);
        case 6: return WICBitmapTransformRotate90;
        case 7: return static_cast<WICBitmapTransformOptions>(WICBitmapTransformRotate90 |
            WICBitmapTransformFlipHorizontal);
        case 8: return WICBitmapTransformRotate270;
        default: fail(SONY2FUJI_STATUS_UNSUPPORTED);
    }
}

struct PreparedImage {
    ComPtr<IWICBitmapSource> oriented;
    UINT orientedWidth = 0;
    UINT orientedHeight = 0;
};

PreparedImage prepareImage(IWICImagingFactory* factory, const std::wstring& path,
                           const char* originalPath) {
    requireRegularFile(path);
    const auto extension = lowerExtension(originalPath);
    if (knownUnsupportedExtension(extension))
        fail(SONY2FUJI_STATUS_UNSUPPORTED);

    MetadataInfo metadata;
    bool metadataScanned = false;
    if (extension == "png") {
        scanPng(path, metadata);
        metadataScanned = true;
    } else if (extension == "jpg" || extension == "jpeg") {
        scanJpeg(path, metadata);
        metadataScanned = true;
    } else if (extension == "tif" || extension == "tiff") {
        scanTiff(path, metadata);
        metadataScanned = true;
    }

    ComPtr<IWICBitmapDecoder> decoder;
    checkHr(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
        WICDecodeMetadataCacheOnDemand, &decoder));
    GUID container{};
    checkHr(decoder->GetContainerFormat(&container));
    const auto kind = containerKind(container);
    UINT frameCount = 0;
    checkHr(decoder->GetFrameCount(&frameCount));
    if (frameCount != 1) fail(SONY2FUJI_STATUS_UNSUPPORTED);

    if (!metadataScanned && kind == ContainerKind::Png) scanPng(path, metadata);
    if (!metadataScanned && kind == ContainerKind::Jpeg) scanJpeg(path, metadata);
    if (!metadataScanned && kind == ContainerKind::Tiff) scanTiff(path, metadata);

    ComPtr<IWICBitmapFrameDecode> frame;
    checkHr(decoder->GetFrame(0, &frame));
    const auto description = describeSource(frame.Get());
    if (kind != ContainerKind::Png)
        mergeOrientation(metadata, metadataOrientation(frame.Get(), kind));
    const auto colors = getColorSource(factory, frame.Get(), metadata.colorProfileMarker);
    validateAlpha(frame.Get(), description);

    ComPtr<IWICBitmapSource> colorSource;
    if (!colors.transformToSrgb) {
        ComPtr<IWICFormatConverter> converter;
        checkHr(factory->CreateFormatConverter(&converter));
        checkHr(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppRGBA,
            WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom));
        checkHr(converter.As(&colorSource));
    }

    if (colors.transformToSrgb) {
        ComPtr<IWICColorContext> destination;
        checkHr(factory->CreateColorContext(&destination));
        checkHr(destination->InitializeFromExifColorSpace(1));
        ComPtr<IWICColorTransform> transform;
        checkHr(factory->CreateColorTransformer(&transform));
        checkHr(transform->Initialize(frame.Get(), colors.context.Get(), destination.Get(),
            GUID_WICPixelFormat32bppRGBA));
        checkHr(transform.As(&colorSource));
    }

    ComPtr<IWICBitmapFlipRotator> rotator;
    checkHr(factory->CreateBitmapFlipRotator(&rotator));
    checkHr(rotator->Initialize(colorSource.Get(), transformForOrientation(metadata.orientation)));
    PreparedImage result;
    checkHr(rotator->GetSize(&result.orientedWidth, &result.orientedHeight));
    if (result.orientedWidth == 0 || result.orientedHeight == 0 ||
        static_cast<uint64_t>(result.orientedWidth) > kMaxDisplayPixels / result.orientedHeight ||
        result.orientedWidth > UINT32_MAX / 4u) {
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    }
    checkHr(rotator.As(&result.oriented));
    return result;
}

void targetSize(const PreparedImage& image, uint32_t edge, UINT* width, UINT* height) {
    if (!width || !height) fail(SONY2FUJI_STATUS_INVALID_ARGUMENT);
    if (edge == 0 || edge >= std::max(image.orientedWidth, image.orientedHeight)) {
        *width = image.orientedWidth;
        *height = image.orientedHeight;
        return;
    }
    const auto longEdge = static_cast<uint64_t>(std::max(image.orientedWidth, image.orientedHeight));
    const auto shortEdge = static_cast<uint64_t>(std::min(image.orientedWidth, image.orientedHeight));
    const auto scaledShort = std::max<uint64_t>(1,
        (shortEdge * edge + longEdge / 2) / longEdge);
    if (image.orientedWidth >= image.orientedHeight) {
        *width = edge;
        *height = static_cast<UINT>(scaledShort);
    } else {
        *width = static_cast<UINT>(scaledShort);
        *height = edge;
    }
}

void copyOutput(IWICImagingFactory* factory, const PreparedImage& image, uint32_t edge,
                sony2fuji_buffer* output) {
    UINT width = 0, height = 0;
    targetSize(image, edge, &width, &height);
    ComPtr<IWICBitmapSource> source = image.oriented;
    if (width != image.orientedWidth || height != image.orientedHeight) {
        ComPtr<IWICBitmapScaler> scaler;
        checkHr(factory->CreateBitmapScaler(&scaler));
        checkHr(scaler->Initialize(image.oriented.Get(), width, height,
            WICBitmapInterpolationModeFant));
        // WIC 缩放可能改为 BGRA；输出字节必须符合 C ABI 的 RGBA 约定。
        ComPtr<IWICFormatConverter> converter;
        checkHr(factory->CreateFormatConverter(&converter));
        checkHr(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppRGBA,
            WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom));
        checkHr(converter.As(&source));
    }
    if (width == 0 || height == 0 || width > UINT32_MAX / 4u ||
        static_cast<uint64_t>(width) > kMaxDisplayPixels / height)
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    const auto stride = static_cast<size_t>(width) * 4u;
    const auto total = stride * static_cast<size_t>(height);
    if (total / stride != height || total > std::numeric_limits<UINT>::max())
        fail(SONY2FUJI_STATUS_UNSUPPORTED);
    auto* pixels = static_cast<uint8_t*>(std::malloc(total));
    if (!pixels) fail(SONY2FUJI_STATUS_OUT_OF_MEMORY);
    try {
        checkHr(source->CopyPixels(nullptr, static_cast<UINT>(stride),
            static_cast<UINT>(total), pixels));
        for (size_t offset = 3; offset < total; offset += 4) {
            if (pixels[offset] != 255) {
                fail(SONY2FUJI_STATUS_UNSUPPORTED);
            }
        }
    } catch (...) {
        std::free(pixels);
        throw;
    }
    output->data = pixels;
    output->size_bytes = total;
    output->width = width;
    output->height = height;
    output->stride_bytes = static_cast<uint32_t>(stride);
    output->pixel_format = SONY2FUJI_PIXEL_RGBA8;
}

sony2fuji_status loadDisplayImageWindows(const char* path, sony2fuji_buffer* output) {
    if (!output) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    clearBuffer(output);
    if (!path || path[0] == '\0') return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        ComApartment apartment;
        const auto widePath = utf8ToWide(path);
        ComPtr<IWICImagingFactory> factory;
        checkHr(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&factory)));
        const auto image = prepareImage(factory.Get(), widePath, path);
        copyOutput(factory.Get(), image, 0, output);
        return SONY2FUJI_STATUS_OK;
    } catch (const StatusError& error) {
        clearBuffer(output);
        return error.status();
    } catch (const std::bad_alloc&) {
        clearBuffer(output);
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        clearBuffer(output);
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status displayPreviewWindows(const char* path, uint32_t edge,
                                       sony2fuji_buffer* output,
                                       uint32_t* orientedSourceWidth,
                                       uint32_t* orientedSourceHeight) {
    if (orientedSourceWidth) *orientedSourceWidth = 0;
    if (orientedSourceHeight) *orientedSourceHeight = 0;
    if (!output) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    clearBuffer(output);
    if (!path || path[0] == '\0') return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (edge == 0) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    try {
        ComApartment apartment;
        const auto widePath = utf8ToWide(path);
        ComPtr<IWICImagingFactory> factory;
        checkHr(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&factory)));
        const auto image = prepareImage(factory.Get(), widePath, path);
        sony2fuji_buffer local{};
        copyOutput(factory.Get(), image, edge, &local);
        if (orientedSourceWidth) *orientedSourceWidth = image.orientedWidth;
        if (orientedSourceHeight) *orientedSourceHeight = image.orientedHeight;
        *output = local;
        return SONY2FUJI_STATUS_OK;
    } catch (const StatusError& error) {
        clearBuffer(output);
        return error.status();
    } catch (const std::bad_alloc&) {
        clearBuffer(output);
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        clearBuffer(output);
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

} // namespace

extern "C" sony2fuji_status sony2fuji_load_display_image(
    const char* path, sony2fuji_buffer* out_buffer) {
    return loadDisplayImageWindows(path, out_buffer);
}

extern "C" sony2fuji_status rawlab_display_preview(
    const char* path, uint32_t edge, sony2fuji_buffer* out_buffer,
    uint32_t* oriented_source_width, uint32_t* oriented_source_height) {
    return displayPreviewWindows(path, edge, out_buffer,
        oriented_source_width, oriented_source_height);
}
