#include "core/tiff_ifd.h"
#include "test_harness.h"

#include <sstream>
#include <string>
#include <vector>

namespace {
using Bytes = std::vector<uint8_t>;
using namespace sony2fuji::tiff;

void put(Bytes& bytes, size_t offset, uint64_t value, size_t width, bool little) {
    for (size_t i = 0; i < width; ++i)
        bytes.at(offset + i) = uint8_t(value >> (8 * (little ? i : width - 1 - i)));
}

Bytes fixture(bool little) {
    Bytes bytes(46, 0);
    bytes[0] = bytes[1] = little ? 'I' : 'M';
    put(bytes, 2, 42, 2, little);
    put(bytes, 4, 8, 4, little);
    put(bytes, 8, 2, 2, little);
    put(bytes, 10, 0x0112, 2, little);
    put(bytes, 12, 3, 2, little);
    put(bytes, 14, 1, 4, little);
    put(bytes, 18, 6, 2, little);
    put(bytes, 22, 0x1234, 2, little);
    put(bytes, 24, 4, 2, little);
    put(bytes, 26, 2, 4, little);
    put(bytes, 30, 38, 4, little);
    put(bytes, 38, 0x12345678, 4, little);
    put(bytes, 42, 0xabcdef01, 4, little);
    return bytes;
}

void validReader(Reader& reader, bool little) {
    uint32_t first = 0;
    RAWLAB_REQUIRE(reader.header(first), "read TIFF header");
    RAWLAB_CHECK(first == 8 && reader.littleEndian() == little, "header byte order and first IFD");
    Directory directory;
    RAWLAB_REQUIRE(reader.directory(first, directory), "read complete IFD");
    RAWLAB_CHECK(directory.count == 2 && directory.next == 0, "directory count and end of chain");
    unsigned seen = 0;
    RAWLAB_CHECK(reader.entries(directory, [&](const Entry& entry) {
        Payload payload;
        if (!reader.payload(entry, payload)) return false;
        uint64_t value = 0;
        if (!reader.integer(payload.offset, payload.width, value)) return false;
        if (seen++ == 0) {
            RAWLAB_CHECK(entry.tag == 0x0112 && value == 6 && payload.size == 2, "inline SHORT is decoded");
        } else {
            RAWLAB_CHECK(entry.tag == 0x1234 && value == 0x12345678 && payload.size == 8, "external LONG array is bounded");
            RAWLAB_CHECK(reader.integer(payload.offset + 4, 4, value) && value == 0xabcdef01, "second LONG uses TIFF byte order");
        }
        return true;
    }), "visit complete entries");
    RAWLAB_CHECK(seen == 2, "visit each directory entry once");
}

void boundaries(bool little) {
    auto bytes = fixture(little);
    // 保留完整 backing，缩短可见范围；撤掉界检查时断言变红而无需触发测试自身的越界读。
    Reader truncated(bytes.data(), 21);
    uint32_t first = 0;
    RAWLAB_REQUIRE(truncated.header(first), "truncated entry retains a valid header");
    Directory directory;
    RAWLAB_CHECK(!truncated.directory(first, directory), "reject truncated directory entry");

    Reader shortCount(bytes.data(), 26);
    RAWLAB_REQUIRE(shortCount.header(first), "short directory retains a valid header");
    RAWLAB_CHECK(!shortCount.directory(first, directory), "reject entry count beyond remaining bytes");

    put(bytes, 26, 0xffffffff, 4, little);
    Reader oversized(bytes.data(), bytes.size());
    RAWLAB_REQUIRE(oversized.header(first) && oversized.directory(first, directory), "oversized value has a complete directory");
    bool sawOversized = false;
    RAWLAB_CHECK(oversized.entries(directory, [&](const Entry& entry) {
        if (entry.tag == 0x1234) {
            Payload payload;
            sawOversized = true;
            RAWLAB_CHECK(!oversized.payload(entry, payload), "reject payload count times stride beyond remaining bytes");
        }
        return true;
    }) && sawOversized, "inspect oversized entry without copying its payload");

    bytes = fixture(little);
    put(bytes, 30, bytes.size() - 4, 4, little);
    Reader badOffset(bytes.data(), bytes.size());
    RAWLAB_REQUIRE(badOffset.header(first) && badOffset.directory(first, directory), "payload offset has a complete directory");
    RAWLAB_CHECK(badOffset.entries(directory, [&](const Entry& entry) {
        if (entry.tag == 0x1234) {
            Payload payload;
            RAWLAB_CHECK(!badOffset.payload(entry, payload), "reject payload crossing the end of the source");
        }
        return true;
    }), "inspect out-of-range payload");

    bytes = fixture(little);
    put(bytes, 34, 8, 4, little);
    Reader cyclic(bytes.data(), bytes.size());
    Traversal traversal;
    RAWLAB_REQUIRE(cyclic.header(first) && traversal.open(cyclic, first, 0, directory), "open first cyclic directory");
    RAWLAB_CHECK(directory.next == 8 && !traversal.open(cyclic, directory.next, 1, directory), "reject next offset pointing to itself");

    Traversal depth;
    RAWLAB_CHECK(!depth.open(cyclic, first, 9, directory), "reject directory nesting beyond the existing HDR limit");
    put(bytes, 8, 4097, 2, little);
    RAWLAB_CHECK(!cyclic.directory(first, directory), "reject more than 4096 directory entries");
}

void headers() {
    auto bytes = fixture(true);
    uint32_t first = 0;
    Reader empty(nullptr, 0);
    RAWLAB_CHECK(!empty.header(first), "empty source is not a TIFF header");
    Reader nullSource(nullptr, bytes.size());
    RAWLAB_CHECK(!nullSource.header(first), "nonempty null source is rejected");
    Reader shortHeader(bytes.data(), 7);
    RAWLAB_CHECK(!shortHeader.header(first), "truncated header is rejected");
    put(bytes, 2, 0x4352, 2, true);
    Reader dcp(bytes.data(), bytes.size());
    RAWLAB_CHECK(!dcp.header(first) && dcp.header(first, 0x4352), "DCP magic is an explicit caller policy");
    bytes[1] = 'M';
    RAWLAB_CHECK(!dcp.header(first, 0x4352), "mixed byte-order markers are rejected");
}

void streamErrors() {
    for (bool exceptions : {false, true}) {
        std::istringstream truncated("II");
        if (exceptions) truncated.exceptions(std::ios::failbit | std::ios::badbit);
        Reader reader(truncated, 8);
        uint32_t first = 0;
        try {
            RAWLAB_CHECK(!reader.header(first), "short stream returns a read failure");
        } catch (const std::ios_base::failure&) {
            RAWLAB_CHECK(false, "stream read failure must return false without throwing");
        }
    }
}
}

TEST_MAIN(
    headers();
    streamErrors();
    for (bool little : {true, false}) {
        const auto bytes = fixture(little);
        Reader memory(bytes.data(), bytes.size());
        validReader(memory, little);
        std::istringstream stream(std::string(bytes.begin(), bytes.end()));
        Reader file(stream, bytes.size());
        validReader(file, little);
        boundaries(little);
    }
)
