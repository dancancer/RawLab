#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>

namespace sony2fuji::hdr::storage {
void requireSpace(const std::filesystem::path& root, uint64_t required);
class Directory {
    struct State;
    std::unique_ptr<State> state_;
public:
    std::filesystem::path path;
    explicit Directory(const std::filesystem::path& root, uint64_t required);
    ~Directory();
    Directory(const Directory&) = delete;
    Directory& operator=(const Directory&) = delete;
    static void recover(const std::filesystem::path& root);
};

class File {
    struct State;
    std::unique_ptr<State> state_;
public:
    explicit File(const std::filesystem::path& path, bool create = false);
    ~File();
    File(const File&) = delete;
    File& operator=(const File&) = delete;
    void resize(uint64_t size);
    uint64_t size() const;
    void append(const void* data, size_t bytes);
    void write(uint64_t offset, const void* data, size_t bytes);
    void read(uint64_t offset, void* data, size_t bytes) const;
    friend class Mapping;
};

class Mapping {
    struct State;
    std::unique_ptr<State> state_;
public:
    Mapping(const std::filesystem::path& path, size_t size);
    ~Mapping();
    const void* data() const;
};
}
