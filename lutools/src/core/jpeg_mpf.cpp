#include "core/jpeg_mpf.h"
#include "core/tiff_ifd.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <vector>

namespace sony2fuji {
namespace {

constexpr uint32_t kBaselinePrimary = 0x80030000;
constexpr uint32_t kRepresentative = 0x20000000;
constexpr uint32_t kDependentChild = 0x40000000;
constexpr uint32_t kVgaThumbnail = 0x010001;
constexpr uint32_t kHdThumbnail = 0x010002;

class JpegReader {
public:
    explicit JpegReader(const std::filesystem::path& path) : file_(path, std::ios::binary | std::ios::ate) {
        const auto size = file_.tellg();
        if (size >= 0) {
            limit_ = static_cast<uint64_t>(size);
            seek(0);
        }
    }

    uint64_t limit() const { return limit_; }
    void setLimit(uint64_t limit) { limit_ = limit; }
    uint64_t position() const { return position_; }

    bool seek(uint64_t position) {
        if (position > limit_) return false;
        if (!file_.seekg(static_cast<std::streamoff>(position))) return false;
        position_ = position;
        return true;
    }

    bool skip(uint64_t size) {
        return size <= limit_ - position_ && seek(position_ + size);
    }

    int byte() {
        if (position_ >= limit_) return -1;
        const int value = file_.rdbuf()->sbumpc();
        if (value >= 0) ++position_;
        return value;
    }

    int word() {
        const int high = byte();
        const int low = byte();
        return high < 0 || low < 0 ? -1 : (high << 8) | low;
    }

    bool read(uint8_t* bytes, size_t size) {
        if (size > limit_ - position_) return false;
        if (!file_.read(reinterpret_cast<char*>(bytes), static_cast<std::streamsize>(size))) return false;
        position_ += size;
        return true;
    }

private:
    std::ifstream file_;
    uint64_t position_ = 0;
    uint64_t limit_ = 0;
};

int nextMarker(JpegReader& reader, bool scan = false) {
    for (;;) {
        const int prefix = reader.byte();
        if (prefix < 0) return -1;
        if (prefix != 0xff) {
            if (!scan) return -1;
            continue;
        }
        int marker = reader.byte();
        while (marker == 0xff) marker = reader.byte();
        if (scan && (marker == 0 || (marker >= 0xd0 && marker <= 0xd7))) continue;
        return marker;
    }
}

struct JpegRange {
    uint64_t start = 0;
    uint64_t end = 0;
    uint32_t type = 0;
};

struct MpfIndex {
    std::array<JpegRange, 3> ranges{};
    size_t count = 0;
};

bool parseIndex(const std::vector<uint8_t>& tiff, uint64_t tiffBase, uint64_t fileSize, MpfIndex& result) {
    tiff::Reader reader(tiff.data(), tiff.size());
    uint32_t first = 0;
    tiff::Directory directory;
    if (!reader.header(first) || first < 8 || !reader.directory(first, directory) || directory.next != 0)
        return false;
    const size_t directoryEnd = directory.entriesOffset + size_t(directory.count) * 12 + 4;

    bool version = false;
    uint32_t images = 0, entriesOffset = 0, entriesSize = 0;
    if (!reader.entries(directory, [&](const tiff::Entry& entry) {
        switch (entry.tag) {
        case 0xb000:
            if (version || entry.type != 7 || entry.count != 4 ||
                std::memcmp(tiff.data() + entry.inlineOffset, "0100", 4) != 0) return false;
            version = true;
            break;
        case 0xb001:
            if (images || entry.type != 4 || entry.count != 1 ||
                entry.value < 2 || entry.value > result.ranges.size()) return false;
            images = entry.value;
            break;
        case 0xb002:
            if (entriesSize || entry.type != 7 || entry.count == 0) return false;
            entriesSize = entry.count;
            entriesOffset = entry.value;
            break;
        }
        return true;
    })) return false;
    if (!version || !images || entriesSize != images * 16 || entriesOffset < directoryEnd ||
        entriesOffset > tiff.size() || entriesSize > tiff.size() - entriesOffset) return false;

    for (size_t index = 0; index < images; ++index) {
        const size_t entry = entriesOffset + index * 16;
        uint64_t attributes = 0, length = 0, offset = 0, dependency1 = 0, dependency2 = 0;
        if (!reader.integer(entry, 4, attributes) || !reader.integer(entry + 4, 4, length) ||
            !reader.integer(entry + 8, 4, offset) || !reader.integer(entry + 12, 2, dependency1) ||
            !reader.integer(entry + 14, 2, dependency2)) return false;
        const auto type = static_cast<uint32_t>(attributes & 0xffffff);
        const uint64_t start = index == 0 ? 0 : tiffBase + offset;
        if (length < 4 || start > fileSize || length > fileSize - start) return false;
        if (index == 0) {
            // The representative bit is a presentation hint. The type and dependency identify the primary.
            if ((attributes & ~kRepresentative) != kBaselinePrimary || offset != 0 ||
                length < tiffBase + tiff.size()) return false;
            if (images == 2 ? dependency1 != 2 || dependency2 != 0 :
                !((dependency1 == 2 && dependency2 == 3) || (dependency1 == 3 && dependency2 == 2))) return false;
        } else if ((type != kVgaThumbnail && type != kHdThumbnail) || attributes != (kDependentChild | type) ||
                   dependency1 != 0 || dependency2 != 0) {
            return false;
        }

        const uint64_t end = start + length;
        for (size_t previous = 0; previous < index; ++previous) {
            const auto& range = result.ranges[previous];
            if (type == range.type || (start < range.end && range.start < end)) return false;
        }
        result.ranges[index] = {start, end, type};
    }
    result.count = images;
    return true;
}

bool validThumbnail(JpegReader& reader, const JpegRange& range) {
    reader.setLimit(range.end);
    if (!reader.seek(range.end - 2) || reader.word() != 0xffd9 ||
        !reader.seek(range.start) || reader.word() != 0xffd8) return false;

    reader.setLimit(range.end - 2);
    for (;;) {
        const int marker = nextMarker(reader);
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (marker < 0xc0 || marker == 0xda || marker == 0xd8 || marker == 0xd9) return false;
        const int length = reader.word();
        if (length < 2) return false;
        const bool frame = marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc;
        if (frame) {
            if (marker > 0xc2 || length != 17 || reader.byte() != 8) return false;
            const int height = reader.word();
            const int width = reader.word();
            const bool vga = range.type == kVgaThumbnail;
            return reader.byte() == 3 && width > 0 && height > 0 &&
                std::max(width, height) <= (vga ? 640 : 1920) && std::min(width, height) <= (vga ? 480 : 1080) &&
                reader.skip(length - 8);
        }
        if (!reader.skip(length - 2)) return false;
    }
}

} // namespace

int inspectSdrJpegMpf(const std::filesystem::path& path) {
    JpegReader reader(path);
    if (reader.word() != 0xffd8) return 0;
    const auto fileSize = reader.limit();
    MpfIndex index;
    bool inScan = false;
    bool sawScan = false;
    for (;;) {
        const int marker = nextMarker(reader, inScan);
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (marker == 0xd9) break;
        if (marker < 0xc0 || marker == 0xd8) return index.count ? -1 : 0;
        if (marker == 0xda && !index.count) return 0;
        const int length = reader.word();
        if (length < 2) return index.count ? -1 : 0;
        size_t payloadSize = static_cast<size_t>(length - 2);
        if (marker == 0xe2 && payloadSize >= 4) {
            std::array<uint8_t, 4> signature{};
            if (!reader.read(signature.data(), signature.size())) return index.count ? -1 : 0;
            payloadSize -= signature.size();
            if (std::memcmp(signature.data(), "MPF\0", signature.size()) == 0) {
                if (index.count || payloadSize < 8) return -1;
                const auto tiffBase = reader.position();
                std::vector<uint8_t> tiff(payloadSize);
                if (!reader.read(tiff.data(), tiff.size()) || !parseIndex(tiff, tiffBase, fileSize, index))
                    return -1;
                reader.setLimit(index.ranges.front().end);
                continue;
            }
        }
        if (!reader.skip(payloadSize)) return index.count ? -1 : 0;
        inScan = marker == 0xda;
        sawScan |= inScan;
    }

    if (!index.count) return 0;
    if (!sawScan || reader.position() != index.ranges.front().end) return -1;
    uint64_t indexedEnd = reader.position();
    for (size_t image = 1; image < index.count; ++image) {
        const auto& range = index.ranges[image];
        if (!validThumbnail(reader, range)) return -1;
        indexedEnd = std::max(indexedEnd, range.end);
    }

    // A camera may append private bytes beyond its last index entry.
    reader.setLimit(fileSize);
    if (!reader.seek(indexedEnd) || reader.word() == 0xffd8) return -1;
    return static_cast<int>(index.count);
}

} // namespace sony2fuji
