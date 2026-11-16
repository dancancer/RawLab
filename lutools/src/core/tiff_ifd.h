#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <istream>
#include <limits>

namespace sony2fuji::tiff {

struct Directory {
    size_t entriesOffset = 0;
    uint16_t count = 0;
    uint32_t next = 0;
};

struct Entry {
    uint16_t tag = 0;
    uint16_t type = 0;
    uint32_t count = 0;
    uint32_t value = 0;
    size_t inlineOffset = 0;
};

struct Payload {
    size_t offset = 0;
    size_t size = 0;
    size_t width = 0;
};

inline size_t elementWidth(uint16_t type) {
    static constexpr uint8_t widths[] = {0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4};
    return type < sizeof(widths) ? widths[type] : 0;
}

class Reader {
public:
    // 借用输入及其长度；内存或流的生命周期须覆盖读取过程。
    Reader(const void* data, size_t size) : data_(static_cast<const uint8_t*>(data)), size_(size) {}
    Reader(std::istream& input, size_t size) : size_(size), input_(&input) {}

    bool littleEndian() const { return little_; }

    bool read(size_t offset, void* target, size_t length) const {
        if (!contains(offset, length) || (!data_ && !input_)) return false;
        if (!length) return true;
        if (data_) std::memcpy(target, data_ + offset, length);
        else {
            try {
                input_->seekg(std::streamoff(offset));
                if (!input_->read(static_cast<char*>(target), std::streamsize(length))) return false;
            } catch (const std::ios_base::failure&) {
                return false;
            }
        }
        return true;
    }

    bool integer(size_t offset, size_t width, uint64_t& value) const {
        uint8_t bytes[8];
        if (!width || width > sizeof(bytes) || !read(offset, bytes, width)) return false;
        value = 0;
        for (size_t i = 0; i < width; ++i)
            value |= uint64_t(bytes[i]) << (8 * (little_ ? i : width - 1 - i));
        return true;
    }

    // 首目录是否允许为零由调用方决定；DCP 另接受 0x4352 魔数。
    bool header(uint32_t& first, uint16_t alternateMagic = 42) {
        uint8_t bytes[8];
        if (!read(0, bytes, sizeof(bytes))) return false;
        if ((bytes[0] != 'I' && bytes[0] != 'M') || bytes[0] != bytes[1]) return false;
        little_ = bytes[0] == 'I';
        uint64_t magic = 0, offset = 0;
        if (!integer(2, 2, magic) || (magic != 42 && magic != alternateMagic) || !integer(4, 4, offset))
            return false;
        first = uint32_t(offset);
        return true;
    }

    bool directory(uint32_t offset, Directory& output) const {
        uint64_t count = 0, next = 0;
        // 一次校验整张目录及尾部 next-offset，再向调用方提供条目。
        if (!integer(offset, 2, count) || count > 4096 || !contains(offset, size_t(count) * 12 + 6))
            return false;
        const size_t start = size_t(offset) + 2;
        if (!integer(start + size_t(count) * 12, 4, next)) return false;
        output = {start, uint16_t(count), uint32_t(next)};
        return true;
    }

    template<class Visitor>
    bool entries(const Directory& directory, Visitor&& visitor) const {
        for (size_t i = 0; i < directory.count; ++i) {
            const size_t at = directory.entriesOffset + i * 12;
            uint64_t tag = 0, type = 0, count = 0, value = 0;
            if (!integer(at, 2, tag) || !integer(at + 2, 2, type) ||
                !integer(at + 4, 4, count) || !integer(at + 8, 4, value)) return false;
            if (!visitor(Entry{uint16_t(tag), uint16_t(type), uint32_t(count), uint32_t(value), at + 8}))
                return false;
        }
        return true;
    }

    // RAW 会跳过不属于拍摄元数据的标签，须在筛选之后才校验其类型和载荷。
    bool payload(const Entry& entry, Payload& output) const {
        const size_t width = elementWidth(entry.type);
        if (!width) return false;
        const uint64_t length = uint64_t(entry.count) * width;
        if (length > std::numeric_limits<size_t>::max()) return false;
        const size_t offset = length <= 4 ? entry.inlineOffset : size_t(entry.value);
        if (!contains(offset, size_t(length))) return false;
        output = {offset, size_t(length), width};
        return true;
    }

private:
    bool contains(size_t offset, size_t length) const {
        return offset <= size_ && length <= size_ - offset;
    }

    const uint8_t* data_ = nullptr;
    size_t size_ = 0;
    std::istream* input_ = nullptr;
    bool little_ = false;
};

class Traversal {
public:
    // 子目录与 next 链共用访问记录；沿用 HDR 的深度 8、目录总量 32 上限。
    bool open(const Reader& reader, uint32_t offset, unsigned depth, Directory& output) {
        if (depth > 8 || count_ == visited_.size()) return false;
        for (size_t i = 0; i < count_; ++i)
            if (visited_[i] == offset) return false;
        visited_[count_++] = offset;
        return reader.directory(offset, output);
    }

private:
    std::array<uint32_t, 32> visited_{};
    size_t count_ = 0;
};

} // namespace sony2fuji::tiff
