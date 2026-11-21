#include "platform/display_image.h"
#include "platform/hdr_heif.h"
#include "core/jpeg_mpf.h"
#include "core/tiff_ifd.h"

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
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;
namespace fs = std::filesystem;

namespace {

constexpr uint64_t kMaxDisplayPixels = 128000000ull;
constexpr size_t kMetadataChunkLimit = 16u * 1024u * 1024u;
constexpr size_t kAlphaTileBytes = 4u * 1024u * 1024u;

class StatusError final : public std::exception {
public:
    explicit StatusError(sony2fuji::RenderStatus status) noexcept : status_(status) {}

    sony2fuji::RenderStatus status() const noexcept { return status_; }

private:
    sony2fuji::RenderStatus status_;
};

[[noreturn]] void fail(sony2fuji::RenderStatus status) {
    throw StatusError(status);
}

void checkHr(HRESULT result, sony2fuji::RenderStatus status = sony2fuji::RenderStatus::ProcessingError) {
    if (FAILED(result)) {
        if (result == E_OUTOFMEMORY || result == WINCODEC_ERR_OUTOFMEMORY)
            fail(sony2fuji::RenderStatus::OutOfMemory);
        fail(status);
    }
}

std::wstring utf8ToWide(const char* path) {
    if (!path || path[0] == '\0') fail(sony2fuji::RenderStatus::InvalidArgument);
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
    if (required <= 0) fail(sony2fuji::RenderStatus::InvalidArgument);
    std::wstring result(static_cast<size_t>(required), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1,
            result.data(), required) <= 0) {
        fail(sony2fuji::RenderStatus::InvalidArgument);
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
        extension == "webp" || extension == "avif" || extension == "jxl";
}

void requireRegularFile(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0)
        fail(sony2fuji::RenderStatus::IoError);
}

class ComApartment final {
public:
    ComApartment() {
        const HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (result == RPC_E_CHANGED_MODE) return;
        if (FAILED(result)) {
            checkHr(result, result == E_OUTOFMEMORY ? sony2fuji::RenderStatus::OutOfMemory :
                sony2fuji::RenderStatus::ProcessingError);
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
        if (!file_) fail(sony2fuji::RenderStatus::IoError);
    }

    void readExact(void* destination, size_t size) {
        if (size > static_cast<size_t>(std::numeric_limits<std::streamsize>::max()))
            fail(sony2fuji::RenderStatus::ProcessingError);
        file_.read(static_cast<char*>(destination), static_cast<std::streamsize>(size));
        if (!file_ || file_.gcount() != static_cast<std::streamsize>(size))
            fail(sony2fuji::RenderStatus::ProcessingError);
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
            if (!file_ || file_.gcount() != count) fail(sony2fuji::RenderStatus::ProcessingError);
            size -= static_cast<uint64_t>(count);
        }
    }

private:
    std::ifstream file_;
};

// 标识符可能内含 '\0'（如 "Exif\0\0"），长度必须显式传入，不能用 strlen。
bool equalBytes(const uint8_t* data, size_t size, const char* value, size_t length) {
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
    sony2fuji::tiff::Reader reader(data, size);
    uint32_t ifdOffset = 0;
    sony2fuji::tiff::Directory dir;
    if (!reader.header(ifdOffset) || !reader.directory(ifdOffset, dir))
        fail(sony2fuji::RenderStatus::Unsupported);
    std::optional<uint32_t> orientation;
    if (!reader.entries(dir, [&](const sony2fuji::tiff::Entry& entry) {
        if (entry.tag != 274) return true;
        if (entry.count != 1 || (entry.type != 3 && entry.type != 4))
            fail(sony2fuji::RenderStatus::Unsupported);
        sony2fuji::tiff::Payload payload;
        uint64_t value = 0;
        if (!reader.payload(entry, payload) || !reader.integer(payload.offset, payload.width, value) ||
            value < 1 || value > 8) {
            fail(sony2fuji::RenderStatus::Unsupported);
        }
        orientation = static_cast<uint32_t>(value);
        return false;
    })) {
        if (!orientation) fail(sony2fuji::RenderStatus::Unsupported);
    }
    return orientation;
}

struct MetadataInfo {
    uint32_t orientation = 1;
    bool orientationSpecified = false;
    bool colorProfileMarker = false;
    bool explicitSrgb = false;
    uint32_t jpegImageCount = 1;
    bool sigmaTIFFPreview = false;
};

void mergeOrientation(MetadataInfo& info, const std::optional<uint32_t>& value) {
    if (!value) return;
    if (info.orientationSpecified && info.orientation != *value)
        fail(sony2fuji::RenderStatus::Unsupported);
    info.orientation = *value;
    info.orientationSpecified = true;
}

void scanPng(const std::wstring& path, MetadataInfo& info) {
    BinaryReader reader(path);
    static constexpr uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    uint8_t actualSignature[sizeof(signature)]{};
    reader.readExact(actualSignature, sizeof(actualSignature));
    if (std::memcmp(actualSignature, signature, sizeof(signature)) != 0)
        fail(sony2fuji::RenderStatus::ProcessingError);

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
                fail(sony2fuji::RenderStatus::Unsupported);
            metadataBytes += length;
        }
        if (is("IHDR")) {
            if (seenHeader || length != 13) fail(sony2fuji::RenderStatus::ProcessingError);
            std::array<uint8_t, 13> header{};
            reader.readExact(header.data(), header.size());
            const auto width = readEndian32(header.data(), false);
            const auto height = readEndian32(header.data() + 4, false);
            if (width == 0 || height == 0) fail(sony2fuji::RenderStatus::ProcessingError);
            if (static_cast<uint64_t>(width) > kMaxDisplayPixels / height)
                fail(sony2fuji::RenderStatus::Unsupported);
            seenHeader = true;
        } else if (is("cICP")) {
            if (length != 4) fail(sony2fuji::RenderStatus::Unsupported);
            std::array<uint8_t, 4> cicp{};
            reader.readExact(cicp.data(), cicp.size());
            // PNG cICP's only accepted SDR form is BT.709/sRGB. In
            // particular, 9/16/0/1 is a valid BT.2020/PQ marker and is HDR.
            if (cicp[0] != 1 || cicp[1] != 13 || cicp[2] != 0 || cicp[3] != 1)
                fail(sony2fuji::RenderStatus::Unsupported);
            info.explicitSrgb = true;
        } else if (is("acTL") || is("fcTL") || is("mDCv") || is("cLLi")) {
            fail(sony2fuji::RenderStatus::Unsupported);
        } else if (is("iCCP")) {
            info.colorProfileMarker = true;
            reader.skip(length);
        } else if (is("sRGB")) {
            if (length != 1) fail(sony2fuji::RenderStatus::Unsupported);
            const auto renderingIntent = reader.readByte();
            if (renderingIntent > 3) fail(sony2fuji::RenderStatus::Unsupported);
            info.explicitSrgb = true;
        } else if (is("gAMA") || is("cHRM")) {
            if (is("gAMA")) {
                if (length != 4) fail(sony2fuji::RenderStatus::Unsupported);
                hasGamma = true;
            } else {
                if (length != 32) fail(sony2fuji::RenderStatus::Unsupported);
                hasChromaticities = true;
            }
            reader.skip(length);
        } else if (is("eXIf")) {
            if (length > kMetadataChunkLimit) fail(sony2fuji::RenderStatus::Unsupported);
            std::vector<uint8_t> exif(length);
            reader.readExact(exif.data(), exif.size());
            mergeOrientation(info, parseExifOrientation(exif.data(), exif.size()));
        } else if (is("iTXt")) {
            if (length > kMetadataChunkLimit) fail(sony2fuji::RenderStatus::Unsupported);
            std::vector<uint8_t> text(length);
            reader.readExact(text.data(), text.size());
            if (containsInsensitive(text.data(), text.size(), "gainmap") ||
                containsInsensitive(text.data(), text.size(), "hdrgm") ||
                containsInsensitive(text.data(), text.size(), "hdrgainmap")) {
                fail(sony2fuji::RenderStatus::Unsupported);
            }
        } else {
            reader.skip(length);
        }
        reader.skip(4);
        if (is("IEND")) {
            if (length != 0) fail(sony2fuji::RenderStatus::ProcessingError);
            seenEnd = true;
        }
    }
    if (!seenHeader || !seenEnd) fail(sony2fuji::RenderStatus::ProcessingError);
    if (info.explicitSrgb && info.colorProfileMarker)
        fail(sony2fuji::RenderStatus::Unsupported);
    if ((hasGamma || hasChromaticities) && !info.colorProfileMarker && !info.explicitSrgb)
        fail(sony2fuji::RenderStatus::Unsupported);
}

void scanJpeg(const std::wstring& path, MetadataInfo& info) {
    BinaryReader reader(path);
    if (reader.readByte() != 0xff || reader.readByte() != 0xd8)
        fail(sony2fuji::RenderStatus::ProcessingError);
    size_t metadataBytes = 0;
    bool seenFrame = false;
    while (true) {
        uint8_t prefix = reader.readByte();
        while (prefix != 0xff) prefix = reader.readByte();
        uint8_t marker = reader.readByte();
        while (marker == 0xff) marker = reader.readByte();
        if (marker == 0xda || marker == 0xd9) {
            if (!seenFrame) fail(sony2fuji::RenderStatus::ProcessingError);
            return;
        }
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (marker == 0x00 || marker < 0xc0) fail(sony2fuji::RenderStatus::ProcessingError);
        const auto length = reader.readU16BE();
        if (length < 2) fail(sony2fuji::RenderStatus::ProcessingError);
        const auto payloadLength = static_cast<size_t>(length - 2);
        const bool frameMarker = marker >= 0xc0 && marker <= 0xcf &&
            marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
        if (frameMarker) {
            if (seenFrame || payloadLength < 6) fail(sony2fuji::RenderStatus::ProcessingError);
            if (marker != 0xc0 && marker != 0xc1 && marker != 0xc2)
                fail(sony2fuji::RenderStatus::Unsupported);
            const auto precision = reader.readByte();
            const auto height = reader.readU16BE();
            const auto width = reader.readU16BE();
            const auto components = reader.readByte();
            if (precision != 8 || components != 3) fail(sony2fuji::RenderStatus::Unsupported);
            if (width == 0 || height == 0 || payloadLength != 6u + components * 3u)
                fail(sony2fuji::RenderStatus::ProcessingError);
            if (static_cast<uint64_t>(width) > kMaxDisplayPixels / height)
                fail(sony2fuji::RenderStatus::Unsupported);
            reader.skip(payloadLength - 6);
            seenFrame = true;
        } else if (marker >= 0xe0 && marker <= 0xef) {
            if (payloadLength > kMetadataChunkLimit - metadataBytes)
                fail(sony2fuji::RenderStatus::Unsupported);
            metadataBytes += payloadLength;
            std::vector<uint8_t> payload(payloadLength);
            reader.readExact(payload.data(), payload.size());
            if (marker == 0xe2 && equalBytes(payload.data(), payload.size(), "ICC_PROFILE\0", 12))
                info.colorProfileMarker = true;
            // 长度 6 保证 payload.size() >= 6，下面的 size - 6 不会下溢。
            if (marker == 0xe1 && equalBytes(payload.data(), payload.size(), "Exif\0\0", 6))
                mergeOrientation(info, parseExifOrientation(payload.data() + 6, payload.size() - 6));
            if (marker == 0xe1 &&
                (containsInsensitive(payload.data(), payload.size(), "gainmap") ||
                 containsInsensitive(payload.data(), payload.size(), "hdrgm") ||
                 containsInsensitive(payload.data(), payload.size(), "hdrgainmap"))) {
                fail(sony2fuji::RenderStatus::Unsupported);
            }
        } else {
            reader.skip(payloadLength);
        }
    }
}

sony2fuji::tiff::Payload tiffEntryPayload(const sony2fuji::tiff::Reader& reader,
                                          const sony2fuji::tiff::Entry& entry) {
    if (entry.type == 0 || entry.type > 12)
        fail(sony2fuji::RenderStatus::Unsupported);
    const size_t width = sony2fuji::tiff::elementWidth(entry.type);
    if (!width || uint64_t(entry.count) > std::numeric_limits<uint64_t>::max() / width)
        fail(sony2fuji::RenderStatus::Unsupported);
    sony2fuji::tiff::Payload payload;
    if (!reader.payload(entry, payload))
        fail(sony2fuji::RenderStatus::ProcessingError);
    return payload;
}

std::vector<uint8_t> readTiffData(const sony2fuji::tiff::Reader& reader,
                                  const sony2fuji::tiff::Payload& payload, size_t limit) {
    if (payload.size > limit) fail(sony2fuji::RenderStatus::Unsupported);
    std::vector<uint8_t> result(payload.size);
    if (!result.empty() && !reader.read(payload.offset, result.data(), result.size()))
        fail(sony2fuji::RenderStatus::ProcessingError);
    return result;
}

std::vector<uint32_t> readTiffUnsignedValues(const sony2fuji::tiff::Reader& reader,
                                             const sony2fuji::tiff::Entry& entry,
                                             const sony2fuji::tiff::Payload& payload,
                                             size_t limit = 4096) {
    if (entry.type != 3 && entry.type != 4)
        fail(sony2fuji::RenderStatus::Unsupported);
    if (payload.size > limit) fail(sony2fuji::RenderStatus::Unsupported);
    std::vector<uint32_t> result;
    result.reserve(entry.count);
    for (uint32_t index = 0; index < entry.count; ++index) {
        uint64_t value = 0;
        if (!reader.integer(payload.offset + static_cast<size_t>(index) * payload.width,
                            payload.width, value)) {
            fail(sony2fuji::RenderStatus::ProcessingError);
        }
        result.push_back(static_cast<uint32_t>(value));
    }
    return result;
}

bool tiffEntryHasNoPageMarker(const sony2fuji::tiff::Reader& reader,
                              const sony2fuji::tiff::Entry& entry,
                              const sony2fuji::tiff::Payload& payload) {
    if (entry.tag == 297) return false;
    if (entry.tag != 254 && entry.tag != 255) return true;
    if (entry.count != 1 || entry.type != (entry.tag == 254 ? 4 : 3)) return false;
    const auto values = readTiffUnsignedValues(reader, entry, payload);
    return entry.tag == 254 ? (values[0] & 2u) == 0 : values[0] != 3;
}

bool hasSigmaTIFFPreview(const sony2fuji::tiff::Reader& reader,
                         sony2fuji::tiff::Traversal& traversal,
                         uint32_t offset, uint64_t primaryWidth, uint64_t primaryHeight) {
    sony2fuji::tiff::Directory dir;
    if (!traversal.open(reader, offset, 1, dir)) {
        uint64_t count = 0;
        if (reader.integer(offset, 2, count) && (count == 0 || count > 4096)) return false;
        fail(sony2fuji::RenderStatus::ProcessingError);
    }
    if (dir.count == 0 || dir.next != 0) return false;
    uint64_t width = 0, height = 0;
    bool depth8 = false;
    if (!reader.entries(dir, [&](const sony2fuji::tiff::Entry& entry) {
        const auto payload = tiffEntryPayload(reader, entry);
        if (!tiffEntryHasNoPageMarker(reader, entry, payload)) return false;
        if (entry.tag == 256 || entry.tag == 257) {
            const auto values = readTiffUnsignedValues(reader, entry, payload);
            if (values.size() != 1) return false;
            if (entry.tag == 256) width = values[0];
            else height = values[0];
        } else if (entry.tag == 258) {
            const auto values = readTiffUnsignedValues(reader, entry, payload);
            if (values.empty() || std::any_of(values.begin(), values.end(),
                    [](uint32_t value) { return value != 8; }))
                return false;
            depth8 = true;
        }
        return true;
    })) {
        return false;
    }
    // 与 Apple 一致：只识别 160 像素、同比例、无分页标记的第二 IFD。
    const auto aspectDifference = static_cast<int64_t>(primaryWidth * height) -
        static_cast<int64_t>(primaryHeight * width);
    return depth8 && width > 0 && height > 0 && width < primaryWidth && height < primaryHeight &&
        std::max(width, height) == 160 &&
        std::abs(aspectDifference) <= static_cast<int64_t>(std::max(primaryWidth, primaryHeight));
}

void scanTiff(const std::wstring& path, MetadataInfo& info) {
    std::ifstream file(path, std::ios::binary);
    if (!file) fail(sony2fuji::RenderStatus::IoError);
    file.seekg(0, std::ios::end);
    const auto end = file.tellg();
    if (end < 0) fail(sony2fuji::RenderStatus::ProcessingError);
    const uint64_t fileSize = static_cast<uint64_t>(end);
    if (fileSize > std::numeric_limits<size_t>::max())
        fail(sony2fuji::RenderStatus::ProcessingError);
    file.seekg(0, std::ios::beg);

    sony2fuji::tiff::Reader reader(file, static_cast<size_t>(fileSize));
    uint32_t ifdOffset = 0;
    if (!reader.header(ifdOffset)) {
        if (reader.magic() == 43) fail(sony2fuji::RenderStatus::Unsupported);
        fail(sony2fuji::RenderStatus::ProcessingError);
    }

    sony2fuji::tiff::Traversal traversal;
    sony2fuji::tiff::Directory dir;
    if (!traversal.open(reader, ifdOffset, 0, dir)) {
        uint64_t count = 0;
        if (!reader.integer(ifdOffset, 2, count))
            fail(sony2fuji::RenderStatus::ProcessingError);
        if (count > 4096 || count * 12ull > fileSize - ifdOffset - 2ull)
            fail(sony2fuji::RenderStatus::Unsupported);
        fail(sony2fuji::RenderStatus::ProcessingError);
    }

    bool hasWidth = false;
    bool hasHeight = false;
    bool hasPhotometric = false;
    uint64_t width = 0;
    uint64_t height = 0;
    uint32_t depth = 0;
    bool sigmaWriter = false;
    bool noPageMarker = true;
    bool nonIccColorMetadata = false;
    size_t metadataBytes = 0;
    if (!reader.entries(dir, [&](const sony2fuji::tiff::Entry& entry) {
        const auto payload = tiffEntryPayload(reader, entry);
        noPageMarker &= tiffEntryHasNoPageMarker(reader, entry, payload);
        if (entry.tag == 305) {
            if (entry.type != 2) {
                sigmaWriter = false;
                return true;
            }
            if (payload.size > kMetadataChunkLimit - metadataBytes)
                fail(sony2fuji::RenderStatus::Unsupported);
            metadataBytes += payload.size;
            const auto software = readTiffData(reader, payload, kMetadataChunkLimit);
            sigmaWriter = equalBytes(software.data(), software.size(), "SIGMA Photo Pro ", 16);
            return true;
        }
        if (entry.tag == 34675) {
            if (payload.size > kMetadataChunkLimit - metadataBytes)
                fail(sony2fuji::RenderStatus::Unsupported);
            metadataBytes += payload.size;
            info.colorProfileMarker = true;
            return true;
        }
        if (entry.tag == 700) {
            if (payload.size > kMetadataChunkLimit - metadataBytes)
                fail(sony2fuji::RenderStatus::Unsupported);
            metadataBytes += payload.size;
            const auto xmp = readTiffData(reader, payload, kMetadataChunkLimit);
            if (containsInsensitive(xmp.data(), xmp.size(), "gainmap") ||
                containsInsensitive(xmp.data(), xmp.size(), "hdrgm") ||
                containsInsensitive(xmp.data(), xmp.size(), "hdrgainmap"))
                fail(sony2fuji::RenderStatus::Unsupported);
            return true;
        }
        if (entry.tag == 270) {
            if (payload.size > kMetadataChunkLimit - metadataBytes)
                fail(sony2fuji::RenderStatus::Unsupported);
            metadataBytes += payload.size;
            const auto description = readTiffData(reader, payload, kMetadataChunkLimit);
            if (containsInsensitive(description.data(), description.size(), "gainmap") ||
                containsInsensitive(description.data(), description.size(), "hdrgm") ||
                containsInsensitive(description.data(), description.size(), "hdrgainmap"))
                fail(sony2fuji::RenderStatus::Unsupported);
            return true;
        }
        if (entry.tag == 256 || entry.tag == 257) {
            const auto values = readTiffUnsignedValues(reader, entry, payload);
            if (values.size() != 1 || values[0] == 0)
                fail(sony2fuji::RenderStatus::ProcessingError);
            if (entry.tag == 256) {
                hasWidth = true;
                width = values[0];
            } else {
                hasHeight = true;
                height = values[0];
            }
            return true;
        }
        if (entry.tag == 258) {
            const auto values = readTiffUnsignedValues(reader, entry, payload);
            if (values.empty() || (values[0] != 8 && values[0] != 16))
                fail(sony2fuji::RenderStatus::Unsupported);
            for (const auto value : values)
                if (value != values[0]) fail(sony2fuji::RenderStatus::Unsupported);
            depth = values[0];
            return true;
        }
        if (entry.tag == 262) {
            const auto values = readTiffUnsignedValues(reader, entry, payload);
            if (values.size() != 1 || values[0] != 2)
                fail(sony2fuji::RenderStatus::Unsupported);
            hasPhotometric = true;
            return true;
        }
        if (entry.tag == 274) {
            const auto values = readTiffUnsignedValues(reader, entry, payload);
            if (values.size() != 1 || values[0] < 1 || values[0] > 8)
                fail(sony2fuji::RenderStatus::Unsupported);
            mergeOrientation(info, values[0]);
            return true;
        }
        if (entry.tag == 339) {
            const auto values = readTiffUnsignedValues(reader, entry, payload);
            if (values.empty()) fail(sony2fuji::RenderStatus::Unsupported);
            for (const auto value : values)
                if (value != 1) fail(sony2fuji::RenderStatus::Unsupported);
            return true;
        }
        if (entry.tag == 301 || entry.tag == 318 || entry.tag == 319 ||
            entry.tag == 529 || entry.tag == 531 || entry.tag == 532) {
            nonIccColorMetadata = true;
        }
        return true;
    })) {
        fail(sony2fuji::RenderStatus::ProcessingError);
    }
    if (!hasWidth || !hasHeight || !hasPhotometric)
        fail(sony2fuji::RenderStatus::ProcessingError);
    if (width > kMaxDisplayPixels / height)
        fail(sony2fuji::RenderStatus::Unsupported);
    if (nonIccColorMetadata && !info.colorProfileMarker)
        fail(sony2fuji::RenderStatus::Unsupported);
    // 其他后续 IFD 仍交给 WIC 帧数判断：WIC 不把缩略图 IFD 计为一帧，这类 TIFF 改动前就能打开。
    if (dir.next != 0 && depth == 16 && sigmaWriter && noPageMarker && dir.next != ifdOffset &&
        hasSigmaTIFFPreview(reader, traversal, dir.next, width, height))
        info.sigmaTIFFPreview = true;
}

enum class ContainerKind { Jpeg, Png, Tiff, Heif };

ContainerKind containerKind(const std::wstring& path) {
    BinaryReader reader(path);
    std::array<uint8_t, 12> header{};
    reader.readExact(header.data(), header.size());
    static constexpr uint8_t png[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (std::memcmp(header.data(), png, sizeof(png)) == 0) return ContainerKind::Png;
    if (header[0] == 0xff && header[1] == 0xd8) return ContainerKind::Jpeg;
    if ((header[0] == 'I' && header[1] == 'I' && (header[2] == 42 || header[2] == 43) && header[3] == 0) ||
        (header[0] == 'M' && header[1] == 'M' && header[2] == 0 && (header[3] == 42 || header[3] == 43)))
        return ContainerKind::Tiff;
    if (std::memcmp(header.data() + 4, "ftyp", 4) == 0) {
        const auto* brand = header.data() + 8;
        if (std::memcmp(brand, "heic", 4) == 0 || std::memcmp(brand, "heix", 4) == 0 ||
            std::memcmp(brand, "hevc", 4) == 0 || std::memcmp(brand, "hevx", 4) == 0 ||
            std::memcmp(brand, "mif1", 4) == 0 || std::memcmp(brand, "msf1", 4) == 0)
            return ContainerKind::Heif;
    }
    fail(sony2fuji::RenderStatus::Unsupported);
}

ContainerKind containerKind(const GUID& container) {
    if (IsEqualGUID(container, GUID_ContainerFormatJpeg)) return ContainerKind::Jpeg;
    if (IsEqualGUID(container, GUID_ContainerFormatPng)) return ContainerKind::Png;
    if (IsEqualGUID(container, GUID_ContainerFormatTiff)) return ContainerKind::Tiff;
    fail(sony2fuji::RenderStatus::Unsupported);
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
                    fail(sony2fuji::RenderStatus::Unsupported);
            }
            PropVariantClear(&value);
            if (orientation < 1 || orientation > 8) fail(sony2fuji::RenderStatus::Unsupported);
            if (result && *result != orientation) fail(sony2fuji::RenderStatus::Unsupported);
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
        checkHr(countResult, sony2fuji::RenderStatus::Unsupported);
    }
    if (count == 0) {
        if (profileMarker) fail(sony2fuji::RenderStatus::Unsupported);
        return {};
    }
    if (count > 16) fail(sony2fuji::RenderStatus::Unsupported);
    ColorSource result;
    std::vector<ComPtr<IWICColorContext>> contexts(count);
    std::vector<IWICColorContext*> rawContexts(count, nullptr);
    for (UINT index = 0; index < count; ++index)
        checkHr(factory->CreateColorContext(&contexts[index]), sony2fuji::RenderStatus::Unsupported);
    for (UINT index = 0; index < count; ++index)
        rawContexts[index] = contexts[index].Get();
    UINT actualCount = 0;
    checkHr(frame->GetColorContexts(count, rawContexts.data(), &actualCount),
        sony2fuji::RenderStatus::Unsupported);
    if (actualCount != count) fail(sony2fuji::RenderStatus::Unsupported);
    bool exifSrgb = false;
    bool unsupportedExif = false;
    for (const auto& context : contexts) {
        WICColorContextType type = WICColorContextUninitialized;
        checkHr(context->GetType(&type), sony2fuji::RenderStatus::Unsupported);
        if (type == WICColorContextProfile) {
            if (result.context) fail(sony2fuji::RenderStatus::Unsupported);
            result.context = context;
        } else if (type == WICColorContextExifColorSpace) {
            UINT exifColorSpace = 0;
            checkHr(context->GetExifColorSpace(&exifColorSpace), sony2fuji::RenderStatus::Unsupported);
            exifSrgb |= exifColorSpace == 1;
            unsupportedExif |= exifColorSpace != 1;
        } else {
            fail(sony2fuji::RenderStatus::Unsupported);
        }
    }
    // WIC 会同时返回 ICC 和 EXIF 色彩标记；有效 ICC 是实际色彩转换的依据。
    if (!result.context) {
        if (profileMarker || !exifSrgb || unsupportedExif) fail(sony2fuji::RenderStatus::Unsupported);
        return {};
    }
    UINT profileSize = 0;
    const auto profileSizeResult = result.context->GetProfileBytes(0, nullptr, &profileSize);
    if (FAILED(profileSizeResult) && profileSizeResult != WINCODEC_ERR_INSUFFICIENTBUFFER)
        checkHr(profileSizeResult, sony2fuji::RenderStatus::Unsupported);
    if (profileSize == 0 || profileSize > kMetadataChunkLimit) fail(sony2fuji::RenderStatus::Unsupported);
    std::vector<uint8_t> profile(profileSize);
    checkHr(result.context->GetProfileBytes(profileSize, profile.data(), &profileSize),
        sony2fuji::RenderStatus::Unsupported);
    if (!isSdrIccProfile(profile)) fail(sony2fuji::RenderStatus::Unsupported);
    result.transformToSrgb = true;
    return result;
}

enum class SourceFormat { Rgb24, Rgb32, Rgba32, Rgb48, Rgb64, Rgba64 };

struct SourceDescription {
    SourceFormat format = SourceFormat::Rgb24;
    UINT width = 0;
    UINT height = 0;
    bool sixteenBit = false;
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
    } else if (IsEqualGUID(format, GUID_WICPixelFormat48bppRGB) ||
               IsEqualGUID(format, GUID_WICPixelFormat48bppBGR)) {
        result.format = SourceFormat::Rgb48;
        result.sixteenBit = true;
    } else if (IsEqualGUID(format, GUID_WICPixelFormat64bppRGB)) {
        result.format = SourceFormat::Rgb64;
        result.sixteenBit = true;
    } else if (IsEqualGUID(format, GUID_WICPixelFormat64bppRGBA) ||
               IsEqualGUID(format, GUID_WICPixelFormat64bppBGRA)) {
        result.format = SourceFormat::Rgba64;
        result.sixteenBit = true;
    } else {
        fail(sony2fuji::RenderStatus::Unsupported);
    }
    checkHr(frame->GetSize(&result.width, &result.height));
    if (result.width == 0 || result.height == 0 ||
        static_cast<uint64_t>(result.width) > kMaxDisplayPixels / result.height ||
        result.width > UINT32_MAX / (result.sixteenBit ? 8u : 4u)) {
        fail(sony2fuji::RenderStatus::Unsupported);
    }
    return result;
}

void validateAlpha(IWICBitmapFrameDecode* frame, const SourceDescription& description) {
    if (description.format != SourceFormat::Rgba32 && description.format != SourceFormat::Rgba64) return;
    constexpr UINT kTileWidth = 4096;
    const UINT tileWidth = std::min<UINT>(description.width, kTileWidth);
    const UINT bytesPerPixel = description.sixteenBit ? 8 : 4;
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
                    const auto* alpha = line + (column + 1) * bytesPerPixel - (description.sixteenBit ? 2 : 1);
                    if (alpha[0] != 255 || (description.sixteenBit && alpha[1] != 255))
                        fail(sony2fuji::RenderStatus::Unsupported);
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
        default: fail(sony2fuji::RenderStatus::Unsupported);
    }
}

struct PreparedImage {
    ComPtr<IWICBitmapSource> oriented;
    UINT orientedWidth = 0;
    UINT orientedHeight = 0;
    bool sixteenBit = false;
};

PreparedImage prepareHeifImage(IWICImagingFactory* factory, const char* originalPath) {
    auto decoded = sony2fuji::hdr::decodeSDRHEIFFile(originalPath);
    if (!decoded.width || !decoded.height ||
        decoded.width > UINT32_MAX / 4u ||
        static_cast<uint64_t>(decoded.width) > kMaxDisplayPixels / decoded.height)
        fail(sony2fuji::RenderStatus::Unsupported);
    const auto stride = static_cast<size_t>(decoded.width) * 4u;
    const auto total = stride * static_cast<size_t>(decoded.height);
    if (total / stride != decoded.height || decoded.pixels.size() != total ||
        total > std::numeric_limits<UINT>::max())
        fail(sony2fuji::RenderStatus::Unsupported);
    ComPtr<IWICBitmap> bitmap;
    checkHr(factory->CreateBitmapFromMemory(decoded.width, decoded.height,
        GUID_WICPixelFormat32bppRGBA, static_cast<UINT>(stride), static_cast<UINT>(total),
        decoded.pixels.data(), &bitmap));
    PreparedImage result;
    // WIC 已复制输入像素，后续转换不再需要保留解码缓冲。
    std::vector<uint8_t>().swap(decoded.pixels);
    result.orientedWidth = decoded.width;
    result.orientedHeight = decoded.height;
    checkHr(bitmap.As(&result.oriented));
    return result;
}

PreparedImage prepareImage(IWICImagingFactory* factory, const std::wstring& path,
                           const char* originalPath) {
    requireRegularFile(path);
    const auto extension = lowerExtension(originalPath);
    if (knownUnsupportedExtension(extension))
        fail(sony2fuji::RenderStatus::Unsupported);

    const auto kind = containerKind(path);
    if (kind == ContainerKind::Heif)
        return prepareHeifImage(factory, originalPath);
    MetadataInfo metadata;
    if (kind == ContainerKind::Png) scanPng(path, metadata);
    if (kind == ContainerKind::Jpeg) {
        scanJpeg(path, metadata);
        const int mpfCount = sony2fuji::inspectSdrJpegMpf(path);
        if (mpfCount < 0) fail(sony2fuji::RenderStatus::Unsupported);
        if (mpfCount) metadata.jpegImageCount = static_cast<uint32_t>(mpfCount);
    }
    if (kind == ContainerKind::Tiff) scanTiff(path, metadata);

    ComPtr<IWICBitmapDecoder> decoder;
    checkHr(factory->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ,
        WICDecodeMetadataCacheOnDemand, &decoder));
    GUID container{};
    checkHr(decoder->GetContainerFormat(&container));
    if (containerKind(container) != kind) fail(sony2fuji::RenderStatus::Unsupported);
    UINT frameCount = 0;
    checkHr(decoder->GetFrameCount(&frameCount));
    if (frameCount != 1 && frameCount != metadata.jpegImageCount &&
        !(kind == ContainerKind::Tiff && frameCount == 2 && metadata.sigmaTIFFPreview))
        fail(sony2fuji::RenderStatus::Unsupported);

    ComPtr<IWICBitmapFrameDecode> frame;
    checkHr(decoder->GetFrame(0, &frame));
    const auto description = describeSource(frame.Get());
    if (description.sixteenBit && kind != ContainerKind::Png && kind != ContainerKind::Tiff)
        fail(sony2fuji::RenderStatus::Unsupported);
    if (kind != ContainerKind::Png)
        mergeOrientation(metadata, metadataOrientation(frame.Get(), kind));
    const auto colors = getColorSource(factory, frame.Get(), metadata.colorProfileMarker);
    validateAlpha(frame.Get(), description);

    const auto& targetFormat = description.sixteenBit ? GUID_WICPixelFormat64bppRGBA : GUID_WICPixelFormat32bppRGBA;
    ComPtr<IWICBitmapSource> colorSource;
    if (!colors.transformToSrgb || description.sixteenBit) {
        ComPtr<IWICFormatConverter> converter;
        checkHr(factory->CreateFormatConverter(&converter));
        checkHr(converter->Initialize(frame.Get(), targetFormat,
            WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom));
        checkHr(converter.As(&colorSource));
    }

    if (colors.transformToSrgb) {
        ComPtr<IWICColorContext> destination;
        checkHr(factory->CreateColorContext(&destination));
        checkHr(destination->InitializeFromExifColorSpace(1));
        ComPtr<IWICColorTransform> transform;
        checkHr(factory->CreateColorTransformer(&transform));
        // WIC 色彩转换支持 RGBA64，却不保证支持解码器的 RGB48；先无损统一格式。
        checkHr(transform->Initialize(description.sixteenBit ? colorSource.Get() : frame.Get(),
            colors.context.Get(), destination.Get(), targetFormat));
        checkHr(transform.As(&colorSource));
    }

    ComPtr<IWICBitmapFlipRotator> rotator;
    checkHr(factory->CreateBitmapFlipRotator(&rotator));
    checkHr(rotator->Initialize(colorSource.Get(), transformForOrientation(metadata.orientation)));
    PreparedImage result;
    result.sixteenBit = description.sixteenBit;
    checkHr(rotator->GetSize(&result.orientedWidth, &result.orientedHeight));
    if (result.orientedWidth == 0 || result.orientedHeight == 0 ||
        static_cast<uint64_t>(result.orientedWidth) > kMaxDisplayPixels / result.orientedHeight ||
        result.orientedWidth > UINT32_MAX / (result.sixteenBit ? 8u : 4u)) {
        fail(sony2fuji::RenderStatus::Unsupported);
    }
    checkHr(rotator.As(&result.oriented));
    return result;
}

void targetSize(const PreparedImage& image, uint32_t edge, UINT* width, UINT* height) {
    if (!width || !height) fail(sony2fuji::RenderStatus::InvalidArgument);
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
                bool preserveDepth, sony2fuji::OwnedPixelBuffer& output) {
    UINT width = 0, height = 0;
    targetSize(image, edge, &width, &height);
    const bool sixteenBit = preserveDepth && image.sixteenBit;
    const UINT pixelBytes = sixteenBit ? 8 : 4;
    const auto& targetFormat = sixteenBit ? GUID_WICPixelFormat64bppRGBA : GUID_WICPixelFormat32bppRGBA;
    ComPtr<IWICBitmapSource> source = image.oriented;
    if (width != image.orientedWidth || height != image.orientedHeight) {
        ComPtr<IWICBitmapScaler> scaler;
        checkHr(factory->CreateBitmapScaler(&scaler));
        checkHr(scaler->Initialize(image.oriented.Get(), width, height,
            WICBitmapInterpolationModeFant));
        checkHr(scaler.As(&source));
    }
    if (width != image.orientedWidth || height != image.orientedHeight || image.sixteenBit != sixteenBit) {
        // WIC 缩放可能改为 BGRA；输出字节必须符合 C ABI 的 RGBA 约定。
        ComPtr<IWICFormatConverter> converter;
        checkHr(factory->CreateFormatConverter(&converter));
        checkHr(converter->Initialize(source.Get(), targetFormat,
            WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom));
        checkHr(converter.As(&source));
    }
    if (width == 0 || height == 0 || width > UINT32_MAX / pixelBytes ||
        static_cast<uint64_t>(width) > kMaxDisplayPixels / height)
        fail(sony2fuji::RenderStatus::Unsupported);
    const auto stride = static_cast<size_t>(width) * pixelBytes;
    const auto total = stride * static_cast<size_t>(height);
    if (total / stride != height || total > std::numeric_limits<UINT>::max())
        fail(sony2fuji::RenderStatus::Unsupported);
    auto* pixels = static_cast<uint8_t*>(std::malloc(total));
    if (!pixels) fail(sony2fuji::RenderStatus::OutOfMemory);
    try {
        checkHr(source->CopyPixels(nullptr, static_cast<UINT>(stride),
            static_cast<UINT>(total), pixels));
        for (size_t offset = pixelBytes - 1; offset < total; offset += pixelBytes) {
            if (pixels[offset] != 255 || (sixteenBit && pixels[offset - 1] != 255)) {
                fail(sony2fuji::RenderStatus::Unsupported);
            }
        }
    } catch (...) {
        std::free(pixels);
        throw;
    }
    output.reset();
    output.data = pixels;
    output.sizeBytes = total;
    output.width = width;
    output.height = height;
    output.strideBytes = static_cast<uint32_t>(stride);
    output.format = sixteenBit ? sony2fuji::PixelBufferFormat::RGBA16 : sony2fuji::PixelBufferFormat::RGBA8;
}

sony2fuji::RenderStatus loadDisplayImageWindows(const char* path, sony2fuji::OwnedPixelBuffer& output) {
    output.reset();
    if (!path || path[0] == '\0') return sony2fuji::RenderStatus::InvalidArgument;
    try {
        ComApartment apartment;
        const auto widePath = utf8ToWide(path);
        ComPtr<IWICImagingFactory> factory;
        checkHr(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&factory)));
        const auto image = prepareImage(factory.Get(), widePath, path);
        copyOutput(factory.Get(), image, 0, true, output);
        return sony2fuji::RenderStatus::Ok;
    } catch (const StatusError& error) {
        output.reset();
        return error.status();
    } catch (const sony2fuji::hdr::Error& error) {
        output.reset();
        return error.status;
    } catch (const std::bad_alloc&) {
        output.reset();
        return sony2fuji::RenderStatus::OutOfMemory;
    } catch (...) {
        output.reset();
        return sony2fuji::RenderStatus::ProcessingError;
    }
}

sony2fuji::RenderStatus displayPreviewWindows(const char* path, uint32_t edge,
                                              sony2fuji::OwnedPixelBuffer& output,
                                              uint32_t* orientedSourceWidth,
                                              uint32_t* orientedSourceHeight) {
    if (orientedSourceWidth) *orientedSourceWidth = 0;
    if (orientedSourceHeight) *orientedSourceHeight = 0;
    output.reset();
    if (!path || path[0] == '\0') return sony2fuji::RenderStatus::InvalidArgument;
    if (edge == 0) return sony2fuji::RenderStatus::InvalidArgument;
    try {
        ComApartment apartment;
        const auto widePath = utf8ToWide(path);
        ComPtr<IWICImagingFactory> factory;
        checkHr(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
            IID_PPV_ARGS(&factory)));
        const auto image = prepareImage(factory.Get(), widePath, path);
        sony2fuji::OwnedPixelBuffer local;
        // 托管缩略图按四字节读取像素，即使不缩放也必须保持 RGBA8。
        copyOutput(factory.Get(), image, edge, false, local);
        if (orientedSourceWidth) *orientedSourceWidth = image.orientedWidth;
        if (orientedSourceHeight) *orientedSourceHeight = image.orientedHeight;
        output = std::move(local);
        return sony2fuji::RenderStatus::Ok;
    } catch (const StatusError& error) {
        output.reset();
        return error.status();
    } catch (const sony2fuji::hdr::Error& error) {
        output.reset();
        return error.status;
    } catch (const std::bad_alloc&) {
        output.reset();
        return sony2fuji::RenderStatus::OutOfMemory;
    } catch (...) {
        output.reset();
        return sony2fuji::RenderStatus::ProcessingError;
    }
}

} // namespace

namespace sony2fuji {

RenderStatus loadDisplayImage(const char* path, OwnedPixelBuffer& output) {
    return loadDisplayImageWindows(path, output);
}

RenderStatus loadDisplayPreview(const char* path,
                                uint32_t edge,
                                OwnedPixelBuffer& output,
                                uint32_t* orientedSourceWidth,
                                uint32_t* orientedSourceHeight) {
    return displayPreviewWindows(path, edge, output, orientedSourceWidth, orientedSourceHeight);
}

} // namespace sony2fuji
