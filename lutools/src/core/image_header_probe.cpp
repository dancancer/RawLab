#include "core/image_header_probe.h"

#include "core/preview_exposure.h"
#include "core/tiff_ifd.h"

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

uint32_t parseExifOrientation(const uint8_t* tiff, size_t size) {
    tiff::Reader reader(tiff, size);
    uint32_t ifdOffset = 0;
    tiff::Directory dir;
    if (!reader.header(ifdOffset) || !reader.directory(ifdOffset, dir)) return 1;
    uint32_t orientation = 1;
    reader.entries(dir, [&](const tiff::Entry& entry) {
        if (entry.tag == 274 && entry.type == 3 && entry.count == 1) {
            tiff::Payload payload;
            uint64_t val = 0;
            if (reader.payload(entry, payload) && reader.integer(payload.offset, payload.width, val)) {
                orientation = static_cast<uint32_t>(val);
            }
            return false;
        }
        return true;
    });
    return orientation;
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

bool probeTiffHeaderSize(std::ifstream& stream, const uint8_t* /*head*/, std::streamsize headSize,
                         uint64_t fileSize, uint32_t& width, uint32_t& height) {
    if (headSize < 8 || fileSize > std::numeric_limits<size_t>::max()) return false;
    tiff::Reader reader(stream, static_cast<size_t>(fileSize));
    uint64_t ifd0Offset = 0;
    if (!reader.header(ifd0Offset, true) || ifd0Offset == 0) return false;

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

    constexpr size_t kMaxMainIfds = 64;
    constexpr size_t kMaxSubIfdsPerIfd = 8;
    // 已解析偏移跨主链与 SubIFDs 共用：多个主 IFD 重复指向同一批 SubIFDs 时不再冗余读取。
    tiff::Traversal traversal(kMaxMainIfds * (1 + kMaxSubIfdsPerIfd));

    auto parseIfd = [&](uint64_t offset, unsigned depth, IfdInfo& info) -> bool {
        tiff::Directory dir;
        if (!traversal.open(reader, offset, depth, dir) || dir.count == 0) return false;
        info.nextIfdOffset = dir.nextOffset;

        reader.entries(dir, [&](const tiff::Entry& entry) {
            const uint16_t tag = entry.tag;
            if (tag != 254 && tag != 256 && tag != 257 && tag != 274 && tag != 330 && tag != 50720) return true;
            const uint16_t type = entry.type;
            const bool supportedType = type == 1 || type == 3 || type == 4 || type == 5 ||
                type == 13 || type == 16 || type == 18;
            if (!supportedType || entry.count64 == 0) return true;

            tiff::Payload payload;
            if (!reader.payload(entry, payload)) return true;

            const size_t maxValues = tag == 330 ? kMaxSubIfdsPerIfd : 2;
            const size_t toRead = static_cast<size_t>(std::min<uint64_t>(entry.count64, maxValues));
            std::vector<uint64_t> u64s;
            u64s.reserve(toRead);
            for (size_t i = 0; i < toRead; ++i) {
                const size_t at = payload.offset + i * payload.width;
                if (type == 5) {
                    uint64_t num = 0, den = 0;
                    if (!reader.integer(at, 4, num) || !reader.integer(at + 4, 4, den) || den == 0) {
                        u64s.clear();
                        break;
                    }
                    u64s.push_back(static_cast<uint64_t>(std::llround(double(num) / double(den))));
                } else {
                    uint64_t val = 0;
                    if (!reader.integer(at, payload.width, val)) {
                        u64s.clear();
                        break;
                    }
                    u64s.push_back(val);
                }
            }
            if (u64s.empty()) return true;

            if (tag == 254) info.subfileType = static_cast<uint32_t>(u64s[0]);
            else if (tag == 256) info.width = u64s[0];
            else if (tag == 257) info.height = u64s[0];
            else if (tag == 274 && entry.count64 == 1) info.orientation = static_cast<uint32_t>(u64s[0]);
            else if (tag == 330) info.subIfds = std::move(u64s);
            else if (tag == 50720 && u64s.size() >= 2) {
                info.cropWidth = u64s[0];
                info.cropHeight = u64s[1];
            }
            return true;
        });
        return true;
    };

    std::vector<IfdInfo> candidates;
    uint32_t rootOrientation = 0;
    uint64_t currentIfdOffset = ifd0Offset;
    for (size_t step = 0; step < kMaxMainIfds && currentIfdOffset != 0; ++step) {
        if (traversal.seen(currentIfdOffset)) break;
        IfdInfo mainIfd{};
        if (!parseIfd(currentIfdOffset, 0, mainIfd)) {
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
            if (subOffset == 0) continue;
            IfdInfo sub{};
            if (parseIfd(subOffset, 1, sub)) {
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
