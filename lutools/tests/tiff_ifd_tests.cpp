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

    // Read past physical EOF (with stream size claim larger than actual bytes), then recover via clear() on valid bytes.
    const auto bytes = fixture(true);
    const std::string data(bytes.begin(), bytes.end());
    for (bool exceptions : {false, true}) {
        std::istringstream stream(data);
        if (exceptions) stream.exceptions(std::ios::failbit | std::ios::badbit);
        Reader reader(stream, data.size() + 16);
        uint64_t dummy = 0;
        RAWLAB_CHECK(!reader.integer(data.size(), 4, dummy), "read past physical stream EOF fails cleanly");
        uint32_t first = 0;
        RAWLAB_REQUIRE(reader.header(first), "stream recovers after EOF/failbit via clear()");
        Directory dir;
        RAWLAB_CHECK(reader.directory(first, dir) && dir.count == 2, "recovered stream reads directory cleanly");
    }
}

Bytes bigTiffFixture(bool little) {
    // Header (16) + IFD0 (8 + 3*20 + 8 = 76 -> ends at 92) + IFD1 (8 + 1*20 + 8 = 36 -> ends at 128) + ext (16 -> ends at 144)
    Bytes bytes(144, 0);
    bytes[0] = bytes[1] = little ? 'I' : 'M';
    put(bytes, 2, 43, 2, little);
    put(bytes, 4, 8, 2, little);
    put(bytes, 6, 0, 2, little);
    put(bytes, 8, 16, 8, little);

    // IFD0 at 16: 3 entries
    put(bytes, 16, 3, 8, little);
    // Entry 0 at 24: tag 0x0100, LONG8 (16), count 1, inline value 50000
    put(bytes, 24, 0x0100, 2, little);
    put(bytes, 26, 16, 2, little);
    put(bytes, 28, 1, 8, little);
    put(bytes, 36, 50000, 8, little);
    // Entry 1 at 44: tag 0x014a (SubIFDs), IFD8 (18), count 1, inline value 92 (IFD1)
    put(bytes, 44, 0x014a, 2, little);
    put(bytes, 46, 18, 2, little);
    put(bytes, 48, 1, 8, little);
    put(bytes, 56, 92, 8, little);
    // Entry 2 at 64: tag 0x1234, LONG8 (16), count 2, external offset 128
    put(bytes, 64, 0x1234, 2, little);
    put(bytes, 66, 16, 2, little);
    put(bytes, 68, 2, 8, little);
    put(bytes, 76, 128, 8, little);
    // IFD0 next at 84 -> 92 (IFD1)
    put(bytes, 84, 92, 8, little);

    // IFD1 at 92: 1 entry
    put(bytes, 92, 1, 8, little);
    put(bytes, 100, 0x0101, 2, little);
    put(bytes, 102, 16, 2, little);
    put(bytes, 104, 1, 8, little);
    put(bytes, 112, 40000, 8, little);
    // IFD1 next at 120 -> 0
    put(bytes, 120, 0, 8, little);

    // External LONG8 array at 128
    put(bytes, 128, 0x0123456789abcdefULL, 8, little);
    put(bytes, 136, 0xfedcba9876543210ULL, 8, little);
    return bytes;
}

void bigTiffTests(bool little) {
    auto bytes = bigTiffFixture(little);

    // Classic uint32 header rejects BigTIFF while exposing magic() == 43
    {
        Reader classic(bytes.data(), bytes.size());
        uint32_t classicFirst = 0;
        RAWLAB_CHECK(!classic.header(classicFirst) && classic.magic() == 43,
            "classic header rejects BigTIFF and reports magic 43");
    }

    // Valid BigTIFF memory & stream reader
    for (bool useStream : {false, true}) {
        std::istringstream stream(std::string(bytes.begin(), bytes.end()));
        Reader reader = useStream ? Reader(stream, bytes.size()) : Reader(bytes.data(), bytes.size());
        uint64_t first = 0;
        RAWLAB_REQUIRE(reader.header(first) && reader.bigTiff() && first == 16, "read BigTIFF header");
        Directory dir;
        RAWLAB_REQUIRE(reader.directory(first, dir), "read BigTIFF IFD0");
        RAWLAB_CHECK(dir.count == 3 && dir.nextOffset == 92, "BigTIFF IFD0 count and 64-bit nextOffset");

        unsigned seen = 0;
        uint64_t subOffset = 0;
        RAWLAB_CHECK(reader.entries(dir, [&](const Entry& entry) {
            Payload p;
            if (!reader.payload(entry, p)) return false;
            uint64_t v = 0;
            if (!reader.integer(p.offset, p.width, v)) return false;
            if (seen == 0) {
                RAWLAB_CHECK(entry.tag == 0x0100 && p.width == 8 && p.size == 8 && v == 50000,
                    "BigTIFF 8-byte inline LONG8 decoded");
            } else if (seen == 1) {
                RAWLAB_CHECK(entry.tag == 0x014a && p.width == 8 && p.size == 8 && v == 92,
                    "BigTIFF 8-byte inline IFD8 decoded");
                subOffset = v;
            } else {
                uint64_t v2 = 0;
                RAWLAB_CHECK(entry.tag == 0x1234 && p.size == 16 &&
                    v == 0x0123456789abcdefULL &&
                    reader.integer(p.offset + 8, 8, v2) && v2 == 0xfedcba9876543210ULL,
                    "BigTIFF external LONG8 array decoded");
            }
            ++seen;
            return true;
        }) && seen == 3, "visit all BigTIFF entries");

        Directory ifd1;
        RAWLAB_REQUIRE(reader.directory(dir.nextOffset, ifd1), "read BigTIFF IFD1 via nextOffset");
        RAWLAB_CHECK(ifd1.count == 1 && ifd1.nextOffset == 0 && subOffset == 92, "BigTIFF IFD1 valid");
    }

    // Truncated BigTIFF header (15 bytes) and invalid bytesize / reserved fields
    {
        Reader shortBig(bytes.data(), 15);
        uint64_t first = 0;
        RAWLAB_CHECK(!shortBig.header(first), "reject truncated 15-byte BigTIFF header");

        auto badByteSize = bytes;
        put(badByteSize, 4, 4, 2, little);
        Reader rByteSize(badByteSize.data(), badByteSize.size());
        RAWLAB_CHECK(!rByteSize.header(first), "reject BigTIFF bytesize != 8");

        auto badReserved = bytes;
        put(badReserved, 6, 1, 2, little);
        Reader rReserved(badReserved.data(), badReserved.size());
        RAWLAB_CHECK(!rReserved.header(first), "reject BigTIFF reserved != 0");
    }

    // Truncated BigTIFF directory (missing trailing 8-byte nextOffset)
    {
        Reader truncDir(bytes.data(), 91);
        uint64_t first = 0;
        Directory dir;
        RAWLAB_REQUIRE(truncDir.header(first), "header intact for truncated BigTIFF directory");
        RAWLAB_CHECK(!truncDir.directory(first, dir), "reject BigTIFF directory with truncated nextOffset");
    }

    // BigTIFF 64-bit count*width overflow and OOB external offset
    {
        auto overflowBytes = bytes;
        put(overflowBytes, 68, 0x2000000000000001ULL, 8, little);
        Reader overflowReader(overflowBytes.data(), overflowBytes.size());
        uint64_t first = 0;
        Directory dir;
        RAWLAB_REQUIRE(overflowReader.header(first) && overflowReader.directory(first, dir),
            "open BigTIFF directory with overflowing count");
        bool checked = false;
        RAWLAB_CHECK(overflowReader.entries(dir, [&](const Entry& entry) {
            if (entry.tag == 0x1234) {
                Payload p;
                checked = true;
                RAWLAB_CHECK(!overflowReader.payload(entry, p),
                    "reject BigTIFF 64-bit count * width multiplication overflow");
            }
            return true;
        }) && checked, "checked BigTIFF overflow entry");

        auto oobBytes = bytes;
        put(oobBytes, 76, oobBytes.size() - 8, 8, little);
        Reader oobReader(oobBytes.data(), oobBytes.size());
        RAWLAB_REQUIRE(oobReader.header(first) && oobReader.directory(first, dir),
            "open BigTIFF directory with OOB payload offset");
        checked = false;
        RAWLAB_CHECK(oobReader.entries(dir, [&](const Entry& entry) {
            if (entry.tag == 0x1234) {
                Payload p;
                checked = true;
                RAWLAB_CHECK(!oobReader.payload(entry, p), "reject BigTIFF OOB payload offset");
            }
            return true;
        }) && checked, "checked BigTIFF OOB payload entry");
    }
}

void traversalLimits() {
    // Chain of 64 classic empty IFDs (each 6 bytes: count=0 + next=offset+6, last next=0)
    constexpr size_t kMainCount = 64;
    Bytes chain(8 + kMainCount * 6, 0);
    chain[0] = chain[1] = 'I';
    put(chain, 2, 42, 2, true);
    put(chain, 4, 8, 4, true);
    for (size_t i = 0; i < kMainCount; ++i) {
        const size_t at = 8 + i * 6;
        put(chain, at, 0, 2, true);
        put(chain, at + 2, (i + 1 < kMainCount) ? (at + 6) : 0, 4, true);
    }

    Reader reader(chain.data(), chain.size());
    uint32_t first = 0;
    RAWLAB_REQUIRE(reader.header(first), "open 64-IFD chain header");

    Traversal defaultTraversal;
    uint64_t offset = first;
    size_t defaultCount = 0;
    Directory dir;
    while (offset != 0 && defaultTraversal.open(reader, offset, 0, dir)) {
        ++defaultCount;
        offset = dir.nextOffset;
    }
    RAWLAB_CHECK(defaultCount == 32, "default Traversal enforces 32-directory HDR limit");

    Traversal expandedTraversal(kMainCount * 9);
    offset = first;
    size_t expandedCount = 0;
    while (offset != 0 && expandedTraversal.open(reader, offset, 0, dir)) {
        ++expandedCount;
        offset = dir.nextOffset;
    }
    RAWLAB_CHECK(expandedCount == 64 && offset == 0, "configured Traversal supports 64 main IFDs");
    RAWLAB_CHECK(!expandedTraversal.open(reader, first, 0, dir), "configured Traversal still detects cycles");
}

void malformedEdgeCases(bool little) {
    // 1. SubIFD (0x014A) & ExifIFD (0x8769) shared-cycle, null, and header-overlap attacks.
    {
        // Classic TIFF: IFD0 at 8 (2 entries: 0x014A -> 38, 0x8769 -> 38), IFD1/SubIFD at 38 (1 entry: 0x014A -> 8)
        Bytes bytes(64, 0);
        bytes[0] = bytes[1] = little ? 'I' : 'M';
        put(bytes, 2, 42, 2, little);
        put(bytes, 4, 8, 4, little);
        // IFD0 at 8: count = 2
        put(bytes, 8, 2, 2, little);
        put(bytes, 10, 0x014a, 2, little);
        put(bytes, 12, 4, 2, little);
        put(bytes, 14, 1, 4, little);
        put(bytes, 18, 38, 4, little);
        put(bytes, 22, 0x8769, 2, little);
        put(bytes, 24, 4, 2, little);
        put(bytes, 26, 1, 4, little);
        put(bytes, 30, 38, 4, little);
        put(bytes, 34, 0, 4, little);
        // SubIFD at 38: count = 1, points back to IFD0 (8)
        put(bytes, 38, 1, 2, little);
        put(bytes, 40, 0x014a, 2, little);
        put(bytes, 42, 4, 2, little);
        put(bytes, 44, 1, 4, little);
        put(bytes, 48, 8, 4, little);
        put(bytes, 52, 0, 4, little);

        Reader reader(bytes.data(), bytes.size());
        uint32_t first = 0;
        RAWLAB_REQUIRE(reader.header(first), "open cyclic SubIFD header");
        Traversal traversal;
        Directory ifd0;
        RAWLAB_REQUIRE(traversal.open(reader, first, 0, ifd0), "open IFD0");
        uint64_t subOffset = 0, exifOffset = 0;
        RAWLAB_CHECK(reader.entries(ifd0, [&](const Entry& e) {
            Payload p;
            uint64_t v = 0;
            if (!reader.payload(e, p) || !reader.integer(p.offset, p.width, v)) return false;
            if (e.tag == 0x014a) subOffset = v;
            if (e.tag == 0x8769) exifOffset = v;
            return true;
        }), "read SubIFD and ExifIFD offsets");
        Directory subIfd;
        RAWLAB_REQUIRE(traversal.open(reader, subOffset, 1, subIfd), "open first SubIFD");
        // ExifIFD pointing to the same already-visited offset must be rejected by shared visited_ tracking.
        Directory dupIfd;
        RAWLAB_CHECK(!traversal.open(reader, exifOffset, 1, dupIfd),
            "shared Traversal rejects duplicate SubIFD/ExifIFD target");
        uint64_t backToRoot = 0;
        RAWLAB_CHECK(reader.entries(subIfd, [&](const Entry& e) {
            Payload p;
            return reader.payload(e, p) && reader.integer(p.offset, p.width, backToRoot);
        }) && backToRoot == 8, "extract cyclic back-pointer from SubIFD");
        Directory cycleDir;
        RAWLAB_CHECK(!traversal.open(reader, backToRoot, 2, cycleDir),
            "SubIFD pointing back to IFD0 is rejected");
    }

    // 2. IFD offset overlapping TIFF header (offset 0, 2, 4) rejected even on large buffers where bytes[2..3] == 42 <= 4096.
    {
        Bytes bytes(1024, 0);
        bytes[0] = bytes[1] = little ? 'I' : 'M';
        put(bytes, 2, 42, 2, little);
        put(bytes, 4, 8, 4, little);
        put(bytes, 8, 0, 2, little);
        put(bytes, 10, 2, 4, little); // nextOffset = 2 (inside header!)
        Reader reader(bytes.data(), bytes.size());
        uint32_t first = 0;
        RAWLAB_REQUIRE(reader.header(first), "header valid for header-overlap test");
        Directory dir;
        RAWLAB_CHECK(!reader.directory(0, dir), "reject IFD at offset 0");
        RAWLAB_CHECK(!reader.directory(2, dir), "reject IFD overlapping classic TIFF header at offset 2");
        Traversal traversal;
        RAWLAB_REQUIRE(traversal.open(reader, first, 0, dir), "open IFD0");
        Directory headerOverlap;
        RAWLAB_CHECK(!traversal.open(reader, dir.nextOffset, 1, headerOverlap),
            "Traversal rejects nextOffset overlapping TIFF header");
    }

    // 3. Unsupported / gap / zero TIFF types rejected while count == 0 with valid type is accepted.
    {
        auto bytes = fixture(little);
        Reader reader(bytes.data(), bytes.size());
        uint32_t first = 0;
        Directory dir;
        RAWLAB_REQUIRE(reader.header(first) && reader.directory(first, dir), "fixture ready for type checks");
        for (uint16_t badType : {uint16_t{0}, uint16_t{14}, uint16_t{15}, uint16_t{17}, uint16_t{19}, uint16_t{255}}) {
            Entry e{};
            e.tag = 0x1000;
            e.type = badType;
            e.count = 1;
            e.count64 = 1;
            e.inlineOffset = 18;
            Payload p;
            RAWLAB_CHECK(!reader.payload(e, p), "reject zero/gap/unknown TIFF element type");
        }
        Entry zeroCount{};
        zeroCount.tag = 0x1000;
        zeroCount.type = 7;
        zeroCount.count = 0;
        zeroCount.count64 = 0;
        zeroCount.inlineOffset = 18;
        Payload zeroPayload;
        RAWLAB_CHECK(reader.payload(zeroCount, zeroPayload) && zeroPayload.size == 0,
            "accept valid type with zero count");
    }

    // 4. 64-bit integer overflow & wrap-around in payload() / contains() and BigTIFF count64 > UINT32_MAX.
    {
        auto big = bigTiffFixture(little);
        // Entry with count64 == 0x100000000ULL (low 32 bits == 0!) must NOT be treated as count == 0.
        put(big, 68, 0x100000000ULL, 8, little);
        Reader bigReader(big.data(), big.size());
        uint64_t first = 0;
        Directory dir;
        RAWLAB_REQUIRE(bigReader.header(first) && bigReader.directory(first, dir), "open BigTIFF directory");
        bool checkedHighCount = false;
        RAWLAB_CHECK(bigReader.entries(dir, [&](const Entry& e) {
            if (e.tag == 0x1234) {
                checkedHighCount = true;
                RAWLAB_CHECK(e.count == 0 && e.count64 == 0x100000000ULL, "preserve 64-bit count above UINT32_MAX");
                Payload p;
                RAWLAB_CHECK(!bigReader.payload(e, p),
                    "reject BigTIFF entry whose count64 > UINT32_MAX exceeds backing buffer");
            }
            return true;
        }) && checkedHighCount, "checked BigTIFF count64 > UINT32_MAX");

        // BigTIFF header rejected when allowBigTiff == false, and IFD overlapping 16-byte BigTIFF header rejected.
        Reader disallowReader(big.data(), big.size());
        uint64_t disallowedFirst = 0;
        RAWLAB_CHECK(!disallowReader.header(disallowedFirst, false), "reject BigTIFF when allowBigTiff=false");
        RAWLAB_CHECK(!bigReader.directory(8, dir), "reject BigTIFF IFD overlapping 16-byte header");

        // BigTIFF directory count > 4096 rejected.
        auto tooManyBig = big;
        put(tooManyBig, 16, 4097, 8, little);
        Reader tooManyReader(tooManyBig.data(), tooManyBig.size());
        RAWLAB_REQUIRE(tooManyReader.header(first), "open BigTIFF header for count > 4096");
        RAWLAB_CHECK(!tooManyReader.directory(first, dir), "reject BigTIFF directory count > 4096");

        // Wrap-around offset near UINT64_MAX/SIZE_MAX in contains() via payload() (external payload > 8 bytes).
        Entry wrapEntry{};
        wrapEntry.tag = 0x1234;
        wrapEntry.type = 4; // LONG (width 4)
        wrapEntry.count = 3;
        wrapEntry.count64 = 3; // length = 12 (> BigTIFF 8-byte inline limit)
        wrapEntry.value64 = std::numeric_limits<uint64_t>::max() - 4;
        wrapEntry.value = std::numeric_limits<uint32_t>::max() - 4;
        Payload wrapPayload;
        RAWLAB_CHECK(!bigReader.payload(wrapEntry, wrapPayload), "reject wrap-around 64-bit payload offset");
    }
}
}

TEST_MAIN(
    headers();
    streamErrors();
    traversalLimits();
    for (bool little : {true, false}) {
        const auto bytes = fixture(little);
        Reader memory(bytes.data(), bytes.size());
        validReader(memory, little);
        std::istringstream stream(std::string(bytes.begin(), bytes.end()));
        Reader file(stream, bytes.size());
        validReader(file, little);
        boundaries(little);
        bigTiffTests(little);
        malformedEdgeCases(little);
    }
)
