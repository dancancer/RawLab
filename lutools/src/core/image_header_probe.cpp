#include "core/image_header_probe.h"

#include "core/preview_exposure.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <utility>
#include <vector>

namespace sony2fuji {
namespace {

uint16_t readEndian16(const uint8_t* p, bool littleEndian) {
    return littleEndian
        ? static_cast<uint16_t>(p[0] | (uint16_t(p[1]) << 8))
        : static_cast<uint16_t>((uint16_t(p[0]) << 8) | p[1]);
}

uint32_t readEndian32(const uint8_t* p, bool littleEndian) {
    return littleEndian
        ? (uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24))
        : ((uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]));
}

uint64_t readEndian64(const uint8_t* p, bool littleEndian) {
    if (littleEndian) {
        return uint64_t(readEndian32(p, true)) | (uint64_t(readEndian32(p + 4, true)) << 32);
    }
    return (uint64_t(readEndian32(p, false)) << 32) | uint64_t(readEndian32(p + 4, false));
}

uint32_t parseExifOrientation(const uint8_t* tiff, size_t size) {
    if (size < 8) return 1;
    const bool little = tiff[0] == 'I' && tiff[1] == 'I';
    const bool big = tiff[0] == 'M' && tiff[1] == 'M';
    if ((!little && !big) || readEndian16(tiff + 2, little) != 42) return 1;
    const uint32_t ifdOffset = readEndian32(tiff + 4, little);
    if (ifdOffset > size - 2) return 1;
    const uint16_t entries = readEndian16(tiff + ifdOffset, little);
    size_t pos = static_cast<size_t>(ifdOffset) + 2;
    for (uint16_t i = 0; i < entries && pos + 12 <= size; ++i, pos += 12) {
        const uint16_t tag = readEndian16(tiff + pos, little);
        const uint16_t type = readEndian16(tiff + pos + 2, little);
        const uint32_t count = readEndian32(tiff + pos + 4, little);
        if (tag == 274 && type == 3 && count == 1) {
            return readEndian16(tiff + pos + 8, little);
        }
    }
    return 1;
}

ProbeSizeResult probeJpegHeaderSize(std::ifstream& stream, uint32_t& width, uint32_t& height) {
    stream.clear();
    stream.seekg(2, std::ios::beg);
    if (!stream) return ProbeSizeResult::Unsupported;
    uint32_t orientation = 1;
    // 头预检按字节预算扫描（而非固定标记个数）：>4096 个 COM/TEM 段后的 SOF 仍能在
    // 预检阶段命中真实主图尺寸，而 0xFF 填充或海量无载荷段也无法用近乎零成本的标记
    // 绕过尺寸预检。超出预算时延后到解码后再校验（DeferredPostDecode），不虚假拒绝。
    constexpr uint64_t kMaxHeaderScanBytes = 4ull << 20; // 4 MiB
    uint64_t scanned = 2; // SOI 已消耗两字节
    while (scanned < kMaxHeaderScanBytes) {
        int byte = stream.get();
        ++scanned;
        if (byte != 0xFF) return ProbeSizeResult::Unsupported;
        while (byte == 0xFF) {
            byte = stream.get();
            ++scanned;
            if (scanned > kMaxHeaderScanBytes) return ProbeSizeResult::DeferredPostDecode;
        }
        if (byte < 0 || byte == 0x00 || byte == 0xD9 || byte == 0xDA) return ProbeSizeResult::Unsupported;
        if (byte == 0x01 || (byte >= 0xD0 && byte <= 0xD7)) continue;
        uint8_t lenBytes[2]{};
        stream.read(reinterpret_cast<char*>(lenBytes), 2);
        if (stream.gcount() != 2) return ProbeSizeResult::Unsupported;
        scanned += 2;
        const uint16_t segLen = readEndian16(lenBytes, false);
        if (segLen < 2) return ProbeSizeResult::Unsupported;
        const uint32_t payloadLen = static_cast<uint32_t>(segLen - 2);
        if (byte == 0xE1 && payloadLen >= 14) {
            std::vector<uint8_t> app1(payloadLen);
            stream.read(reinterpret_cast<char*>(app1.data()), payloadLen);
            if (stream.gcount() != static_cast<std::streamsize>(payloadLen)) return ProbeSizeResult::Unsupported;
            scanned += payloadLen;
            if (std::memcmp(app1.data(), "Exif\0\0", 6) == 0) {
                orientation = parseExifOrientation(app1.data() + 6, app1.size() - 6);
            }
            continue;
        }
        if (byte >= 0xC0 && byte <= 0xCF && byte != 0xC4 && byte != 0xC8 && byte != 0xCC) {
            if (payloadLen < 5) return ProbeSizeResult::Unsupported;
            uint8_t sof[5]{};
            stream.read(reinterpret_cast<char*>(sof), 5);
            if (stream.gcount() != 5) return ProbeSizeResult::Unsupported;
            uint32_t h = readEndian16(sof + 1, false);
            uint32_t w = readEndian16(sof + 3, false);
            if (w == 0 || h == 0) return ProbeSizeResult::Unsupported;
            if (orientation >= 5 && orientation <= 8) std::swap(w, h);
            width = w;
            height = h;
            return ProbeSizeResult::Probed;
        }
        stream.seekg(payloadLen, std::ios::cur);
        if (!stream) return ProbeSizeResult::Unsupported;
        scanned += payloadLen;
    }
    return ProbeSizeResult::DeferredPostDecode;
}

bool probeTiffHeaderSize(std::ifstream& stream, const uint8_t* head, std::streamsize headSize,
                         uint64_t fileSize, uint32_t& width, uint32_t& height) {
    if (headSize < 8) return false;
    const bool little = head[0] == 'I' && head[1] == 'I';
    const bool big = head[0] == 'M' && head[1] == 'M';
    if (!little && !big) return false;
    const uint16_t magic = readEndian16(head + 2, little);
    const bool bigTiff = magic == 43;
    if (magic != 42 && !bigTiff) return false;
    uint64_t ifd0Offset = 0;
    if (bigTiff) {
        if (headSize < 16 || readEndian16(head + 4, little) != 8 || readEndian16(head + 6, little) != 0)
            return false;
        ifd0Offset = readEndian64(head + 8, little);
    } else {
        ifd0Offset = readEndian32(head + 4, little);
    }

    auto typeBytes = [](uint16_t type) -> size_t {
        switch (type) {
            case 1: return 1;
            case 3: return 2;
            case 4:
            case 13: return 4;
            case 5:
            case 16:
            case 18: return 8;
            default: return 0;
        }
    };
    auto readAt = [&](uint64_t offset, uint8_t* dst, size_t count) -> bool {
        if (count > fileSize || offset > fileSize - count) return false;
        stream.clear();
        stream.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
        if (!stream) return false;
        stream.read(reinterpret_cast<char*>(dst), static_cast<std::streamsize>(count));
        return stream.gcount() == static_cast<std::streamsize>(count);
    };

    struct IfdInfo {
        uint64_t width = 0;
        uint64_t height = 0;
        uint64_t cropWidth = 0;
        uint64_t cropHeight = 0;
        uint32_t subfileType = 0;
        uint32_t orientation = 0;
        uint64_t nextIfdOffset = 0;
        std::vector<uint64_t> subIfds;
    };

    auto parseIfd = [&](uint64_t offset, IfdInfo& info) -> bool {
        uint64_t entryCount = 0;
        uint64_t pos = offset;
        if (bigTiff) {
            uint8_t cnt[8]{};
            if (!readAt(pos, cnt, 8)) return false;
            entryCount = readEndian64(cnt, little);
            pos += 8;
        } else {
            uint8_t cnt[2]{};
            if (!readAt(pos, cnt, 2)) return false;
            entryCount = readEndian16(cnt, little);
            pos += 2;
        }
        if (entryCount == 0 || entryCount > 4096) return false;
        const size_t entrySize = bigTiff ? 20u : 12u;
        const size_t tableBytes = static_cast<size_t>(entryCount) * entrySize;
        if (tableBytes > fileSize || pos > fileSize - tableBytes) return false;
        std::vector<uint8_t> table(tableBytes);
        if (!readAt(pos, table.data(), tableBytes)) return false;

        auto readValues = [&](const uint8_t* entry, size_t maxValues, std::vector<double>& outNums,
                              std::vector<uint64_t>& outU64) {
            const uint16_t type = readEndian16(entry + 2, little);
            const uint64_t count = bigTiff ? readEndian64(entry + 4, little) : readEndian32(entry + 4, little);
            const size_t unit = typeBytes(type);
            if (unit == 0 || count == 0) return;
            const size_t inlineCap = bigTiff ? 8u : 4u;
            const uint8_t* valueField = entry + (bigTiff ? 12 : 8);
            const size_t toRead = static_cast<size_t>(std::min<uint64_t>(count, maxValues));
            const size_t neededBytes = toRead * unit;
            std::vector<uint8_t> buf(neededBytes);
            if (count <= inlineCap / unit) {
                std::memcpy(buf.data(), valueField, neededBytes);
            } else {
                const uint64_t dataOffset = bigTiff ? readEndian64(valueField, little)
                                                    : readEndian32(valueField, little);
                if (!readAt(dataOffset, buf.data(), neededBytes)) return;
            }
            outNums.reserve(toRead);
            outU64.reserve(toRead);
            for (size_t i = 0; i < toRead; ++i) {
                const uint8_t* p = buf.data() + i * unit;
                uint64_t u = 0;
                double d = 0;
                if (type == 1) { u = p[0]; d = double(u); }
                else if (type == 3) { u = readEndian16(p, little); d = double(u); }
                else if (type == 4 || type == 13) { u = readEndian32(p, little); d = double(u); }
                else if (type == 16 || type == 18) { u = readEndian64(p, little); d = double(u); }
                else if (type == 5) {
                    const uint32_t num = readEndian32(p, little);
                    const uint32_t den = readEndian32(p + 4, little);
                    if (den == 0) return;
                    d = double(num) / double(den);
                    u = static_cast<uint64_t>(std::llround(d));
                }
                outNums.push_back(d);
                outU64.push_back(u);
            }
        };

        for (size_t i = 0; i < entryCount; ++i) {
            const uint8_t* entry = table.data() + i * entrySize;
            const uint16_t tag = readEndian16(entry, little);
            if (tag != 254 && tag != 256 && tag != 257 && tag != 274 && tag != 330 && tag != 50720) continue;
            const uint64_t entryValueCount = bigTiff ? readEndian64(entry + 4, little) : readEndian32(entry + 4, little);
            std::vector<double> nums;
            std::vector<uint64_t> u64s;
            readValues(entry, tag == 330 ? 8 : 2, nums, u64s);
            if (u64s.empty()) continue;
            if (tag == 254) info.subfileType = static_cast<uint32_t>(u64s[0]);
            else if (tag == 256) info.width = u64s[0];
            else if (tag == 257) info.height = u64s[0];
            else if (tag == 274 && entryValueCount == 1) info.orientation = static_cast<uint32_t>(u64s[0]);
            else if (tag == 330) info.subIfds = std::move(u64s);
            else if (tag == 50720 && u64s.size() >= 2) {
                info.cropWidth = u64s[0];
                info.cropHeight = u64s[1];
            }
        }
        const uint64_t nextOffsetPos = pos + tableBytes;
        if (bigTiff) {
            uint8_t nextBuf[8]{};
            if (readAt(nextOffsetPos, nextBuf, 8)) {
                info.nextIfdOffset = readEndian64(nextBuf, little);
            }
        } else {
            uint8_t nextBuf[4]{};
            if (readAt(nextOffsetPos, nextBuf, 4)) {
                info.nextIfdOffset = readEndian32(nextBuf, little);
            }
        }
        return true;
    };

    if (ifd0Offset == 0) return false;

    constexpr size_t kMaxMainIfds = 64;
    std::vector<IfdInfo> candidates;
    std::vector<uint64_t> visitedMainIfds;
    // 已解析偏移跨主链与 SubIFDs 共用：多个主 IFD 重复指向同一批 SubIFDs 时不再冗余读取。
    std::vector<uint64_t> visitedIfds;
    uint32_t rootOrientation = 0;
    uint64_t currentIfdOffset = ifd0Offset;
    for (size_t step = 0; step < kMaxMainIfds && currentIfdOffset != 0; ++step) {
        if (std::find(visitedMainIfds.begin(), visitedMainIfds.end(), currentIfdOffset) != visitedMainIfds.end()) {
            break;
        }
        visitedMainIfds.push_back(currentIfdOffset);
        visitedIfds.push_back(currentIfdOffset);
        IfdInfo mainIfd{};
        if (!parseIfd(currentIfdOffset, mainIfd)) {
            if (step == 0) return false;
            break;
        }
        if (step == 0) {
            rootOrientation = mainIfd.orientation;
        } else if (mainIfd.orientation == 0) {
            mainIfd.orientation = rootOrientation;
        }
        const uint64_t nextOffset = mainIfd.nextIfdOffset;
        const auto subOffsets = mainIfd.subIfds;
        const uint32_t parentOrientation = mainIfd.orientation;
        candidates.push_back(std::move(mainIfd));
        for (uint64_t subOffset : subOffsets) {
            if (std::find(visitedIfds.begin(), visitedIfds.end(), subOffset) != visitedIfds.end()) continue;
            visitedIfds.push_back(subOffset);
            IfdInfo sub{};
            if (parseIfd(subOffset, sub)) {
                if (sub.orientation == 0) sub.orientation = parentOrientation;
                candidates.push_back(std::move(sub));
            }
        }
        currentIfdOffset = nextOffset;
    }

    const IfdInfo* best = nullptr;
    uint64_t bestPixels = 0;
    bool bestIsPrimary = false;
    for (const auto& item : candidates) {
        const uint64_t w = (item.cropWidth > 0 && item.cropHeight > 0 &&
            (item.width == 0 || (item.cropWidth <= item.width && item.cropHeight <= item.height)))
            ? item.cropWidth : item.width;
        const uint64_t h = (item.cropWidth > 0 && item.cropHeight > 0 &&
            (item.height == 0 || (item.cropWidth <= item.width && item.cropHeight <= item.height)))
            ? item.cropHeight : item.height;
        if (w == 0 || h == 0) continue;
        const bool isPrimary = (item.subfileType & 1u) == 0;
        const uint64_t clampedW = std::min<uint64_t>(w, std::numeric_limits<uint32_t>::max());
        const uint64_t clampedH = std::min<uint64_t>(h, std::numeric_limits<uint32_t>::max());
        const uint64_t pixels = clampedW > std::numeric_limits<uint64_t>::max() / clampedH
            ? std::numeric_limits<uint64_t>::max() : clampedW * clampedH;
        if (!best || (isPrimary && !bestIsPrimary) || (isPrimary == bestIsPrimary && pixels > bestPixels)) {
            best = &item;
            bestPixels = pixels;
            bestIsPrimary = isPrimary;
        }
    }
    if (!best) return false;
    uint64_t w = (best->cropWidth > 0 && best->cropHeight > 0 &&
        (best->width == 0 || (best->cropWidth <= best->width && best->cropHeight <= best->height)))
        ? best->cropWidth : best->width;
    uint64_t h = (best->cropWidth > 0 && best->cropHeight > 0 &&
        (best->height == 0 || (best->cropWidth <= best->width && best->cropHeight <= best->height)))
        ? best->cropHeight : best->height;
    if (best->orientation >= 5 && best->orientation <= 8) std::swap(w, h);
    width = static_cast<uint32_t>(std::min<uint64_t>(w, std::numeric_limits<uint32_t>::max()));
    height = static_cast<uint32_t>(std::min<uint64_t>(h, std::numeric_limits<uint32_t>::max()));
    return width > 0 && height > 0;
}

} // namespace

bool buildRawSourceIdentityKey(
    const char* inputPathStr,
    bool legacySonyCrop,
    std::string& outBaseKey
) {
    if (!buildFileIdentityKey(inputPathStr, outBaseKey)) return false;
    if (legacySonyCrop) outBaseKey += ":legacy-sony-crop";
    return true;
}

ProbeSizeResult probeInputHeaderSize(
    const char* inputPath,
    bool legacySonyCrop,
    X3fMode x3fMode,
    uint32_t& outWidth,
    uint32_t& outHeight
) {
    outWidth = 0;
    outHeight = 0;
    if (inputPath == nullptr || inputPath[0] == '\0') {
        return ProbeSizeResult::OpenFailed;
    }
    std::error_code fsError;
    const auto path = std::filesystem::u8path(inputPath);
    const uint64_t fileSize = std::filesystem::file_size(path, fsError);
    if (fsError) return ProbeSizeResult::OpenFailed;
    if (fileSize < 4) return ProbeSizeResult::Unsupported;

    std::ifstream stream(path, std::ios::binary);
    if (!stream) return ProbeSizeResult::OpenFailed;
    uint8_t head[24]{};
    stream.read(reinterpret_cast<char*>(head), sizeof(head));
    const std::streamsize headSize = stream.gcount();
    if (headSize < 4) return ProbeSizeResult::OpenFailed;

    if (x3fMode == X3fMode::Normal && std::memcmp(head, "FOVb", 4) == 0) {
        return ProbeSizeResult::DeferredPostDecode;
    }

    static constexpr uint8_t kPngSignature[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (headSize >= 24 && std::memcmp(head, kPngSignature, 8) == 0 &&
        readEndian32(head + 8, false) == 13 && std::memcmp(head + 12, "IHDR", 4) == 0) {
        const uint32_t w = readEndian32(head + 16, false);
        const uint32_t h = readEndian32(head + 20, false);
        if (w == 0 || h == 0) return ProbeSizeResult::Unsupported;
        outWidth = w;
        outHeight = h;
        return ProbeSizeResult::Probed;
    }

    if (head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF) {
        return probeJpegHeaderSize(stream, outWidth, outHeight);
    }

    stream.close();
    const auto rawProbe = RAWProcessor::probeOutputSize(inputPath, legacySonyCrop, outWidth, outHeight, x3fMode);
    if (rawProbe != ProbeSizeResult::Unsupported) {
        return rawProbe;
    }

    std::ifstream tiffStream(path, std::ios::binary);
    if (!tiffStream) return ProbeSizeResult::OpenFailed;
    return probeTiffHeaderSize(tiffStream, head, headSize, fileSize, outWidth, outHeight)
        ? ProbeSizeResult::Probed
        : ProbeSizeResult::Unsupported;
}

} // namespace sony2fuji
