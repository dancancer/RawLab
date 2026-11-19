#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <istream>
#include <limits>
#include <vector>

namespace sony2fuji::tiff {

struct Directory {
    size_t entriesOffset = 0;
    uint16_t count = 0;
    uint32_t next = 0;
    uint64_t nextOffset = 0;
};

struct Entry {
    uint16_t tag = 0;
    uint16_t type = 0;
    uint32_t count = 0;
    uint32_t value = 0;
    size_t inlineOffset = 0;
    uint64_t count64 = 0;
    uint64_t value64 = 0;
};

struct Payload {
    size_t offset = 0;
    size_t size = 0;
    size_t width = 0;
};

inline size_t elementWidth(uint16_t type) {
    static constexpr uint8_t widths[] = {
        0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4, 0, 0, 8, 0, 8
    };
    return type < sizeof(widths) ? widths[type] : 0;
}

class Reader {
public:
    // 借用输入及其长度；内存或流的生命周期须覆盖读取过程。
    Reader(const void* data, size_t size) : data_(static_cast<const uint8_t*>(data)), size_(size) {}
    Reader(std::istream& input, size_t size) : size_(size), input_(&input) {}

    bool littleEndian() const { return little_; }
    bool bigTiff() const { return bigTiff_; }
    uint16_t magic() const { return magic_; }

    bool read(uint64_t offset, void* target, size_t length) const {
        if (!contains(offset, length) || (!data_ && !input_)) return false;
        if (!length) return true;
        if (data_) std::memcpy(target, data_ + size_t(offset), length);
        else {
            if (offset > uint64_t(std::numeric_limits<std::streamoff>::max()) ||
                length > size_t(std::numeric_limits<std::streamsize>::max())) return false;
            try {
                // 部分读取/EOF 会置位流状态标志，重新定位前先清除以允许后续读取恢复。
                input_->clear();
                input_->seekg(std::streamoff(offset));
                if (!input_->read(static_cast<char*>(target), std::streamsize(length))) return false;
            } catch (const std::ios_base::failure&) {
                return false;
            }
        }
        return true;
    }

    bool integer(uint64_t offset, size_t width, uint64_t& value) const {
        uint8_t bytes[8];
        if (!width || width > sizeof(bytes) || !read(offset, bytes, width)) return false;
        value = 0;
        for (size_t i = 0; i < width; ++i)
            value |= uint64_t(bytes[i]) << (8 * (little_ ? i : width - 1 - i));
        return true;
    }

    // 首目录是否允许为零由调用方决定；DCP 另接受 0x4352 魔数。
    bool header(uint32_t& first, uint16_t alternateMagic = 42) {
        uint64_t offset = 0;
        if (!header(offset, false, alternateMagic) || offset > std::numeric_limits<uint32_t>::max())
            return false;
        first = uint32_t(offset);
        return true;
    }

    bool header(uint64_t& first, bool allowBigTiff = true, uint16_t alternateMagic = 42) {
        bigTiff_ = false;
        magic_ = 0;
        uint8_t bytes[8];
        if (!read(0, bytes, sizeof(bytes))) return false;
        if ((bytes[0] != 'I' && bytes[0] != 'M') || bytes[0] != bytes[1]) return false;
        little_ = bytes[0] == 'I';
        uint64_t magic = 0;
        if (!integer(2, 2, magic)) return false;
        magic_ = uint16_t(magic);
        if (magic == 43) {
            if (!allowBigTiff) return false;
            uint64_t byteSize = 0, reserved = 0, offset = 0;
            if (!integer(4, 2, byteSize) || byteSize != 8 ||
                !integer(6, 2, reserved) || reserved != 0 ||
                !integer(8, 8, offset)) return false;
            bigTiff_ = true;
            first = offset;
            return true;
        }
        if (magic != 42 && magic != alternateMagic) return false;
        uint64_t offset = 0;
        if (!integer(4, 4, offset)) return false;
        first = offset;
        return true;
    }

    bool directory(uint64_t offset, Directory& output) const {
        const size_t countBytes = bigTiff_ ? 8 : 2;
        const size_t entryBytes = bigTiff_ ? 20 : 12;
        const size_t nextBytes = bigTiff_ ? 8 : 4;
        uint64_t count = 0, next = 0;
        // 一次校验整张目录及尾部 next-offset，再向调用方提供条目。
        if (!integer(offset, countBytes, count) || count > 4096) return false;
        const uint64_t tableBytes = count * entryBytes;
        const uint64_t totalBytes = countBytes + tableBytes + nextBytes;
        if (totalBytes > std::numeric_limits<size_t>::max() || !contains(offset, size_t(totalBytes)))
            return false;
        const size_t start = size_t(offset) + countBytes;
        if (!integer(start + size_t(tableBytes), nextBytes, next)) return false;
        output = {};
        output.entriesOffset = start;
        output.count = uint16_t(count);
        output.next = uint32_t(next);
        output.nextOffset = next;
        return true;
    }

    template<class Visitor>
    bool entries(const Directory& directory, Visitor&& visitor) const {
        const size_t entryBytes = bigTiff_ ? 20 : 12;
        const size_t fieldBytes = bigTiff_ ? 8 : 4;
        for (size_t i = 0; i < directory.count; ++i) {
            const size_t at = directory.entriesOffset + i * entryBytes;
            uint64_t tag = 0, type = 0, count = 0, value = 0;
            if (!integer(at, 2, tag) || !integer(at + 2, 2, type) ||
                !integer(at + 4, fieldBytes, count) ||
                !integer(at + 4 + fieldBytes, fieldBytes, value)) return false;
            Entry entry{};
            entry.tag = uint16_t(tag);
            entry.type = uint16_t(type);
            entry.count = uint32_t(count);
            entry.value = uint32_t(value);
            entry.inlineOffset = at + 4 + fieldBytes;
            entry.count64 = count;
            entry.value64 = value;
            if (!visitor(entry)) return false;
        }
        return true;
    }

    // RAW 会跳过不属于拍摄元数据的标签，须在筛选之后才校验其类型和载荷。
    bool payload(const Entry& entry, Payload& output) const {
        const size_t width = elementWidth(entry.type);
        if (!width) return false;
        const uint64_t count = entry.count64 ? entry.count64 : uint64_t(entry.count);
        if (count > std::numeric_limits<size_t>::max() / width) return false;
        const size_t length = size_t(count) * width;
        const size_t inlineLimit = bigTiff_ ? 8 : 4;
        const uint64_t offset = length <= inlineLimit
            ? uint64_t(entry.inlineOffset)
            : (bigTiff_ ? entry.value64 : uint64_t(entry.value));
        if (!contains(offset, length)) return false;
        output = {size_t(offset), length, width};
        return true;
    }

private:
    bool contains(uint64_t offset, size_t length) const {
        return offset <= size_ && length <= size_ - offset;
    }

    const uint8_t* data_ = nullptr;
    size_t size_ = 0;
    std::istream* input_ = nullptr;
    bool little_ = false;
    bool bigTiff_ = false;
    uint16_t magic_ = 0;
};

class Traversal {
public:
    Traversal() = default;
    explicit Traversal(size_t maxDirectories, unsigned maxDepth = 8)
        : maxDirectories_(maxDirectories), maxDepth_(maxDepth) {}

    bool seen(uint64_t offset) const {
        return std::find(visited_.begin(), visited_.end(), offset) != visited_.end();
    }

    // 子目录与 next 链共用访问记录；默认沿用 HDR 的深度 8、目录总量 32 上限。
    bool open(const Reader& reader, uint64_t offset, unsigned depth, Directory& output) {
        if (depth > maxDepth_ || visited_.size() >= maxDirectories_) return false;
        if (seen(offset)) return false;
        visited_.push_back(offset);
        return reader.directory(offset, output);
    }

private:
    size_t maxDirectories_ = 32;
    unsigned maxDepth_ = 8;
    std::vector<uint64_t> visited_;
};

} // namespace sony2fuji::tiff
