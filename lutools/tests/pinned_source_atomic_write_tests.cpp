#include "core/atomic_output_transaction.h"
#include "core/output_file_mode.h"
#include "core/pinned_source_file.h"
#include "core/processing_cancellation.h"
#include "nlohmann/json.hpp"
#include "test_harness.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>
#include <vector>

#ifndef _WIN32
#include <csignal>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#else
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace {

namespace fs = std::filesystem;
using sony2fuji::AtomicOutputOptions;
using sony2fuji::AtomicOutputStatus;
using sony2fuji::AtomicOutputTransaction;
using sony2fuji::OutputModePolicy;
using sony2fuji::PinnedSourceFile;
using sony2fuji::PinnedSourceOptions;
using sony2fuji::ProcessingCancellation;
using sony2fuji::ProcessingCancellationScope;
using sony2fuji::ProcessingCancelled;
using sony2fuji::SourcePinStatus;

struct TempDir {
    fs::path path;
    explicit TempDir(const char* prefix) {
        const auto unique = std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count());
        path = fs::temp_directory_path() / (std::string(prefix) + "_" + unique);
        fs::create_directories(path);
    }
    ~TempDir() {
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

std::vector<uint8_t> readBytes(const fs::path& p) {
    std::ifstream in(p, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

void writeBytes(const fs::path& p, const std::vector<uint8_t>& data) {
    std::ofstream out(p, std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(data.data()), static_cast<std::streamsize>(data.size()));
    out.close();
    RAWLAB_REQUIRE(!out.fail(), "writeBytes failed");
}

void writeText(const fs::path& p, const std::string& s) {
    writeBytes(p, std::vector<uint8_t>(s.begin(), s.end()));
}

std::string readText(const fs::path& p) {
    const auto b = readBytes(p);
    return std::string(b.begin(), b.end());
}

#ifndef _WIN32
unsigned fileMode(const fs::path& p) {
    struct stat st {};
    return ::stat(p.c_str(), &st) == 0 ? static_cast<unsigned>(st.st_mode & 0777) : 0u;
}
#endif

bool tryCreateSymlink(const fs::path& target, const fs::path& link) {
    std::error_code ec;
    fs::create_symlink(target, link, ec);
    return !ec;
}

int countStagingFiles(const fs::path& dir, const std::string& prefix) {
    int count = 0;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(dir, ec)) {
        const std::string name = entry.path().filename().u8string();
        if (name.rfind(prefix, 0) == 0) ++count;
    }
    return count;
}

// Global state for fn-ptr sony2fuji::sourceReadTestHook (WF-MUT-1).
fs::path gHookSwapFrom;
fs::path gHookSwapTo;
bool gHookFired = false;
std::error_code gHookSwapError;

void hookSwapSourceDuringRead() {
    gHookSwapError.clear();
    fs::rename(gHookSwapFrom, gHookSwapTo, gHookSwapError);
    gHookFired = true;
}

void testPinnedSourceTamperClamping() {
    TempDir dir("rawlab_pinned_src");
    const std::vector<uint8_t> payload(64 * 1024, 0x5A);

    // 1. Atomic rename swap of an identical-size/content file during sourceReadTestHook (WF-MUT-1).
    {
        const fs::path source = dir.path / "source.bin";
        const fs::path staged = dir.path / "staged.bin";
        writeBytes(source, payload);
        writeBytes(staged, payload);

        gHookSwapFrom = staged;
        gHookSwapTo = source;
        gHookFired = false;
        gHookSwapError.clear();
        sony2fuji::resetSourceHashPassCount();
        sony2fuji::sourceReadTestHook = hookSwapSourceDuringRead;

        PinnedSourceOptions opts;
        PinnedSourceFile pinned;
        std::vector<uint8_t> out;
        std::string msg;
        const auto status = PinnedSourceFile::pinAndRead(source, opts, pinned, out, &msg);
        sony2fuji::sourceReadTestHook = nullptr;

        RAWLAB_CHECK(gHookFired && !gHookSwapError, "sourceReadTestHook must fire cleanly");
        RAWLAB_CHECK(status == SourcePinStatus::SourceChanged,
            "pinAndRead must reject identical-content atomic swap during read (WF-MUT-1)");
        RAWLAB_CHECK(out.empty() && !pinned.valid(),
            "rejected pinAndRead must not expose partial bytes or valid pin");
        RAWLAB_CHECK(sony2fuji::sourceHashPassCount() == 0,
            "rejected pinAndRead must abort before hashing");
    }

    // 2. In-place modification during read via onReadChunkTestHook.
    {
        const fs::path source = dir.path / "inplace-during-read.bin";
        writeBytes(source, payload);
        const auto originalMtime = fs::last_write_time(source);

        PinnedSourceOptions opts;
        opts.onReadChunkTestHook = [&]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            std::fstream f(source, std::ios::in | std::ios::out | std::ios::binary);
            f.seekp(0);
            const char b = static_cast<char>(0x5B);
            f.write(&b, 1);
            f.flush();
            f.close();
            fs::last_write_time(source, originalMtime);
        };
        PinnedSourceFile pinned;
        std::vector<uint8_t> out;
        const auto status = PinnedSourceFile::pinAndRead(source, opts, pinned, out);
        RAWLAB_CHECK(status == SourcePinStatus::SourceChanged,
            "pinAndRead must detect in-place modification during read even with restored mtime");
    }

    // 3. Single-pass hash invariant, expectedSha256 mismatch, and verifyUnchanged tamper detection.
    {
        const fs::path source = dir.path / "valid.bin";
        writeBytes(source, payload);

        sony2fuji::resetSourceHashPassCount();
        PinnedSourceOptions opts;
        opts.computeSha256 = true;
        PinnedSourceFile pinned;
        std::vector<uint8_t> out;
        RAWLAB_REQUIRE(PinnedSourceFile::pinAndRead(source, opts, pinned, out) == SourcePinStatus::Ok,
            "valid pinAndRead must succeed");
        RAWLAB_CHECK(pinned.valid() && pinned.hasSha256() && out == payload,
            "pinned source preserves exact bytes and sha256");
        RAWLAB_CHECK(sony2fuji::sourceHashPassCount() == 1,
            "pinAndRead hashes source in a single pass");
        RAWLAB_CHECK(pinned.verifyUnchanged(), "unmodified source passes verifyUnchanged");
        RAWLAB_CHECK(sony2fuji::sourceHashPassCount() == 1,
            "verifyUnchanged does not re-hash the file");

        // Matching expectedSha256 succeeds; mismatched expectedSha256 returns SourceChanged.
        std::array<uint8_t, 32> expected = pinned.sha256();
        opts.expectedSha256 = expected.data();
        PinnedSourceFile matched;
        std::vector<uint8_t> outMatched;
        RAWLAB_CHECK(PinnedSourceFile::pinAndRead(source, opts, matched, outMatched) == SourcePinStatus::Ok,
            "matching expectedSha256 succeeds");
        expected[0] ^= 0xFF;
        PinnedSourceFile mismatched;
        std::vector<uint8_t> outMismatch;
        RAWLAB_CHECK(PinnedSourceFile::pinAndRead(source, opts, mismatched, outMismatch) == SourcePinStatus::SourceChanged,
            "mismatched expectedSha256 returns SourceChanged");

        // Replace file with identical size/content & restored mtime -> verifyUnchanged must return false.
        const auto mtime = fs::last_write_time(source);
        const fs::path replacement = dir.path / "replacement.bin";
        writeBytes(replacement, payload);
        fs::last_write_time(replacement, mtime);
        fs::rename(replacement, source);
        RAWLAB_CHECK(!pinned.verifyUnchanged(),
            "verifyUnchanged must reject atomic replacement even with identical size/bytes/mtime");
    }

    // 4. pinIdentity does zero hashing and detects in-place overwrite with restored mtime.
    {
        const fs::path source = dir.path / "identity.bin";
        writeBytes(source, payload);
        sony2fuji::resetSourceHashPassCount();
        PinnedSourceFile idPin;
        RAWLAB_REQUIRE(PinnedSourceFile::pinIdentity(source, false, idPin) == SourcePinStatus::Ok,
            "pinIdentity succeeds on regular file");
        RAWLAB_CHECK(sony2fuji::sourceHashPassCount() == 0 && !idPin.hasSha256() && idPin.verifyUnchanged(),
            "pinIdentity performs zero hashing");

        const auto mtime = fs::last_write_time(source);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        {
            std::fstream f(source, std::ios::in | std::ios::out | std::ios::binary);
            f.seekp(16);
            const char b = static_cast<char>(0xA5);
            f.write(&b, 1);
        }
        fs::last_write_time(source, mtime);
        RAWLAB_CHECK(!idPin.verifyUnchanged(),
            "pinIdentity + verifyUnchanged detects in-place write with restored mtime (ctime/ChangeTime)");
    }

    // 5. pinAndHash streams 1 MiB chunks with zero full-buffer alloc and matches pinAndRead SHA-256.
    {
        const fs::path source = dir.path / "hashed.bin";
        writeBytes(source, payload);
        PinnedSourceOptions readOpts;
        readOpts.computeSha256 = true;
        PinnedSourceFile readPinned;
        std::vector<uint8_t> readBytes;
        RAWLAB_REQUIRE(PinnedSourceFile::pinAndRead(source, readOpts, readPinned, readBytes) == SourcePinStatus::Ok,
            "pinAndRead baseline for pinAndHash");

        sony2fuji::resetSourceHashPassCount();
        PinnedSourceFile hashPinned;
        RAWLAB_CHECK(PinnedSourceFile::pinAndHash(source, readOpts, hashPinned) == SourcePinStatus::Ok,
            "pinAndHash succeeds on regular file");
        RAWLAB_CHECK(hashPinned.valid() && hashPinned.hasSha256() &&
            hashPinned.sha256() == readPinned.sha256() &&
            sony2fuji::sourceHashPassCount() == 1,
            "pinAndHash matches pinAndRead SHA-256 in 1 pass");

        std::array<uint8_t, 32> expected = readPinned.sha256();
        PinnedSourceOptions matchOpts = readOpts;
        matchOpts.expectedSha256 = expected.data();
        PinnedSourceFile matched;
        RAWLAB_CHECK(PinnedSourceFile::pinAndHash(source, matchOpts, matched) == SourcePinStatus::Ok,
            "pinAndHash accepts matching expectedSha256");
        expected[0] ^= 0xFF;
        PinnedSourceFile mismatched;
        RAWLAB_CHECK(PinnedSourceFile::pinAndHash(source, matchOpts, mismatched) == SourcePinStatus::SourceChanged,
            "pinAndHash rejects mismatched expectedSha256");

        // Atomic swap during pinAndHash via sourceReadTestHook returns SourceChanged with 0 hash passes.
        const fs::path staged = dir.path / "hash-staged.bin";
        writeBytes(staged, payload);
        gHookSwapFrom = staged;
        gHookSwapTo = source;
        gHookFired = false;
        gHookSwapError.clear();
        sony2fuji::resetSourceHashPassCount();
        sony2fuji::sourceReadTestHook = hookSwapSourceDuringRead;
        PinnedSourceFile swapped;
        const auto swapSt = PinnedSourceFile::pinAndHash(source, readOpts, swapped);
        sony2fuji::sourceReadTestHook = nullptr;
        RAWLAB_CHECK(gHookFired && !gHookSwapError &&
            swapSt == SourcePinStatus::SourceChanged &&
            !swapped.valid() &&
            sony2fuji::sourceHashPassCount() == 0,
            "pinAndHash rejects atomic swap during read with 0 sourceHashPassCount");
    }

    // 6. Symlink rejection vs allowed symlink and isSameFile.
    {
        const fs::path realFile = dir.path / "real.bin";
        writeText(realFile, "hello");
        const fs::path linkFile = dir.path / "link.bin";
        if (tryCreateSymlink(realFile, linkFile)) {
            RAWLAB_CHECK(PinnedSourceFile::isSameFile(realFile, linkFile),
                "isSameFile detects symlink pointing to same file");
            PinnedSourceFile allowed;
            std::vector<uint8_t> bytes;
            PinnedSourceOptions allowOpts;
            allowOpts.rejectSymlink = false;
            RAWLAB_CHECK(PinnedSourceFile::pinAndRead(linkFile, allowOpts, allowed, bytes) == SourcePinStatus::Ok &&
                bytes == std::vector<uint8_t>({'h', 'e', 'l', 'l', 'o'}),
                "pinAndRead allows user photo symlink when rejectSymlink=false");

            PinnedSourceFile rejected;
            PinnedSourceOptions rejectOpts;
            rejectOpts.rejectSymlink = true;
            RAWLAB_CHECK(PinnedSourceFile::pinAndRead(linkFile, rejectOpts, rejected, bytes) == SourcePinStatus::InvalidPath,
                "pinAndRead rejects symlink when rejectSymlink=true");
            RAWLAB_CHECK(PinnedSourceFile::pinIdentity(linkFile, true, rejected) == SourcePinStatus::InvalidPath,
                "pinIdentity rejects symlink when rejectSymlink=true");
        }
        const fs::path otherFile = dir.path / "other.bin";
        writeText(otherFile, "world");
        RAWLAB_CHECK(!PinnedSourceFile::isSameFile(realFile, otherFile),
            "isSameFile distinguishes distinct files");
    }
}

void testAtomicOutputTransaction() {
    TempDir dir("rawlab_atomic_tx");

    // 1. Foreign staging collision protection + 64-attempt exhaustion safety (WF-MUT-2).
    {
        const fs::path colDir = dir.path / "collision";
        fs::create_directories(colDir);
        const fs::path target = colDir / "target.dat";
        writeText(target, "OLD_TARGET");

        const std::string probe = sony2fuji::stagingSuffix();
        const auto dash = probe.find('-');
        RAWLAB_REQUIRE(dash != std::string::npos, "unexpected stagingSuffix format");
        const std::string pidPart = probe.substr(0, dash);
        const uint64_t nextCounter = std::stoull(probe.substr(dash + 1)) + 1;

        std::vector<fs::path> planted;
        const std::string foreignData = "FOREIGN_TEMP_DO_NOT_MODIFY";
        for (uint64_t i = 0; i < 3; ++i) {
            const fs::path f = colDir / (".rawlab-test-" + pidPart + "-" + std::to_string(nextCounter + i) + ".tmp");
            writeText(f, foreignData);
            planted.push_back(f);
        }

        AtomicOutputOptions opts;
        opts.stagingPrefix = ".rawlab-test";
        opts.stagingExtension = ".tmp";
        opts.rejectSymlinkTarget = true;
        AtomicOutputTransaction tx(target, opts);
        RAWLAB_REQUIRE(tx.begin() == AtomicOutputStatus::Ok,
            "begin() must retry past pre-existing foreign staging files");
        const std::string newData = "NEW_PUBLISHED_DATA";
        RAWLAB_REQUIRE(tx.writeAll(newData.data(), newData.size(), false) == AtomicOutputStatus::Ok,
            "writeAll succeeds");
        RAWLAB_REQUIRE(tx.commit() == AtomicOutputStatus::Ok,
            "commit succeeds after foreign temp skip");
        RAWLAB_CHECK(readText(target) == newData, "published target has new content");
        for (const auto& f : planted) {
            RAWLAB_CHECK(fs::exists(f) && readText(f) == foreignData,
                "AtomicOutputTransaction must never truncate or delete foreign staging files (WF-MUT-2)");
        }

        // Exhaustion test: pre-plant all 64 next candidates; begin() fails without touching any of them.
        const std::string probe2 = sony2fuji::stagingSuffix();
        const uint64_t next2 = std::stoull(probe2.substr(probe2.find('-') + 1)) + 1;
        std::vector<fs::path> all64;
        for (uint64_t i = 0; i < 64; ++i) {
            const fs::path f = colDir / (".rawlab-exhaust-" + pidPart + "-" + std::to_string(next2 + i) + ".tmp");
            writeText(f, foreignData);
            all64.push_back(f);
        }
        {
            AtomicOutputOptions exhaustOpts;
            exhaustOpts.stagingPrefix = ".rawlab-exhaust";
            AtomicOutputTransaction exhaustTx(target, exhaustOpts);
            RAWLAB_CHECK(exhaustTx.begin() == AtomicOutputStatus::IoError,
                "begin() returns IoError when all 64 staging attempts collide");
        }
        for (const auto& f : all64) {
            RAWLAB_CHECK(fs::exists(f) && readText(f) == foreignData,
                "failed/destroyed transaction never unlinks foreign staging files");
        }
    }

    // 2. Symlink target rejection (when rejectSymlinkTarget=true) vs replacement (when false).
    {
        const fs::path symDir = dir.path / "symlink";
        fs::create_directories(symDir);
        const fs::path anchor = symDir / "anchor.txt";
        const fs::path link = symDir / "link.txt";
        writeText(anchor, "ANCHOR_SECRET");
        if (tryCreateSymlink(anchor, link)) {
            AtomicOutputOptions rejectOpts;
            rejectOpts.stagingPrefix = ".rawlab-sym";
            rejectOpts.rejectSymlinkTarget = true;
            {
                AtomicOutputTransaction tx(link, rejectOpts);
                RAWLAB_CHECK(tx.begin() == AtomicOutputStatus::InvalidArgument,
                    "begin() rejects symlink target when rejectSymlinkTarget=true");
            }
            RAWLAB_CHECK(fs::is_symlink(link) && readText(anchor) == "ANCHOR_SECRET" &&
                countStagingFiles(symDir, ".rawlab-sym-") == 0,
                "rejected symlink target leaves link, anchor, and dir clean");

            AtomicOutputOptions replaceOpts;
            replaceOpts.stagingPrefix = ".rawlab-sym";
            replaceOpts.rejectSymlinkTarget = false;
            AtomicOutputTransaction replaceTx(link, replaceOpts);
            RAWLAB_REQUIRE(replaceTx.begin() == AtomicOutputStatus::Ok,
                "begin() allows replacing symlink when rejectSymlinkTarget=false");
            const std::string replaced = "REPLACED_LINK_FILE";
            RAWLAB_REQUIRE(replaceTx.writeAll(replaced.data(), replaced.size(), false) == AtomicOutputStatus::Ok,
                "writeAll succeeds for symlink replacement");
            RAWLAB_REQUIRE(replaceTx.commit() == AtomicOutputStatus::Ok,
                "commit replaces symlink itself");
            RAWLAB_CHECK(!fs::is_symlink(link) && readText(link) == replaced &&
                readText(anchor) == "ANCHOR_SECRET",
                "replacing symlink destination writes regular file and leaves symlink target untouched");
        }
    }

    // 3. Pre-commit tamper rejection and ProcessingCancelled rollback (WF-MUT-3).
    {
        const fs::path preDir = dir.path / "precommit";
        fs::create_directories(preDir);
        const fs::path target = preDir / "output.dat";
        writeText(target, "ORIGINAL_DEST");

        AtomicOutputOptions opts;
        opts.stagingPrefix = ".rawlab-pre";
        {
            AtomicOutputTransaction tx(target, opts);
            RAWLAB_REQUIRE(tx.begin() == AtomicOutputStatus::Ok, "begin succeeds for preCommit false test");
            const std::string bad = "TAMPERED_NEW";
            RAWLAB_REQUIRE(tx.writeAll(bad.data(), bad.size(), false) == AtomicOutputStatus::Ok, "writeAll ok");
            const auto st = tx.commit([]() { return false; });
            RAWLAB_CHECK(st == AtomicOutputStatus::PreCommitRejected,
                "commit returns PreCommitRejected when preCommitCheck returns false (WF-MUT-3)");
        }
        RAWLAB_CHECK(readText(target) == "ORIGINAL_DEST" && countStagingFiles(preDir, ".rawlab-pre-") == 0,
            "PreCommitRejected preserves destination and removes staging file");

        bool threwCancelled = false;
        try {
            ProcessingCancellationScope cancelScope({+[](void*) -> int32_t { return 1; }, nullptr});
            AtomicOutputTransaction tx(target, opts);
            RAWLAB_REQUIRE(tx.begin() == AtomicOutputStatus::Ok, "begin succeeds before cancellation");
            const std::string bad = "CANCELLED_NEW";
            (void)tx.writeAll(bad.data(), bad.size(), true);
        } catch (const ProcessingCancelled&) {
            threwCancelled = true;
        }
        RAWLAB_CHECK(threwCancelled && readText(target) == "ORIGINAL_DEST" &&
            countStagingFiles(preDir, ".rawlab-pre-") == 0,
            "ProcessingCancelled during writeAll cleans up staging and preserves destination");
    }

    // 4. Directory target & missing parent failure.
    {
        const fs::path blockDir = dir.path / "blocked-dir";
        fs::create_directories(blockDir);
        const fs::path marker = blockDir / "keep.txt";
        writeText(marker, "KEEP_MARKER");

        AtomicOutputOptions opts;
        opts.stagingPrefix = ".rawlab-dir";
        opts.createParentDirs = false;
        {
            AtomicOutputTransaction tx(blockDir, opts);
            RAWLAB_CHECK(tx.begin() == AtomicOutputStatus::IoError,
                "begin() rejects directory target with IoError");
        }
        RAWLAB_CHECK(fs::is_directory(blockDir) && readText(marker) == "KEEP_MARKER" &&
            countStagingFiles(dir.path, ".rawlab-dir-") == 0,
            "directory target failure preserves marker and leaks no staging files");

        const fs::path missingParentTarget = dir.path / "nonexistent-parent" / "file.dat";
        AtomicOutputTransaction missingTx(missingParentTarget, opts);
        RAWLAB_CHECK(missingTx.begin() == AtomicOutputStatus::IoError && !fs::exists(missingParentTarget),
            "missing parent with createParentDirs=false returns IoError without creating directories");
    }

    // 5. openStdioWrite() & external owner handle/fd handoff + commit.
    {
        const fs::path ioDir = dir.path / "stdio_ext";
        fs::create_directories(ioDir);
        const fs::path stdioTarget = ioDir / "stdio.bin";
        AtomicOutputOptions opts;
        opts.stagingPrefix = ".rawlab-stdio";
        {
            AtomicOutputTransaction tx(stdioTarget, opts);
            RAWLAB_REQUIRE(tx.begin() == AtomicOutputStatus::Ok, "begin stdio tx");
            std::FILE* f = tx.openStdioWrite();
            RAWLAB_REQUIRE(f != nullptr, "openStdioWrite returns valid FILE*");
            const std::string content = "STDIO_PAYLOAD";
            RAWLAB_REQUIRE(std::fwrite(content.data(), 1, content.size(), f) == content.size(),
                "fwrite to staging FILE*");
            RAWLAB_REQUIRE(tx.commit() == AtomicOutputStatus::Ok, "commit stdio tx");
            RAWLAB_CHECK(readText(stdioTarget) == content && countStagingFiles(ioDir, ".rawlab-stdio-") == 0,
                "stdio transaction publishes cleanly");
        }

        const fs::path extTarget = ioDir / "external.bin";
        opts.openReadWrite = true;
        {
            AtomicOutputTransaction tx(extTarget, opts);
            RAWLAB_REQUIRE(tx.begin() == AtomicOutputStatus::Ok, "begin external owner tx");
#ifndef _WIN32
            const int fd = tx.releasePosixFdForExternalOwner();
            RAWLAB_REQUIRE(fd >= 0, "releasePosixFdForExternalOwner returns valid fd");
            const char msg[] = "EXT_OWNER";
            RAWLAB_REQUIRE(::write(fd, msg, sizeof(msg) - 1) == ssize_t(sizeof(msg) - 1),
                "write through released POSIX fd");
            RAWLAB_REQUIRE(::close(fd) == 0, "close released POSIX fd");
#else
            const HANDLE h = static_cast<HANDLE>(tx.releaseWin32HandleForExternalOwner());
            RAWLAB_REQUIRE(h != INVALID_HANDLE_VALUE, "releaseWin32HandleForExternalOwner returns valid HANDLE");
            const char msg[] = "EXT_OWNER";
            DWORD written = 0;
            RAWLAB_REQUIRE(::WriteFile(h, msg, static_cast<DWORD>(sizeof(msg) - 1), &written, nullptr) &&
                written == sizeof(msg) - 1, "write through released Win32 HANDLE");
            RAWLAB_REQUIRE(::CloseHandle(h) != 0, "close released Win32 HANDLE");
#endif
            tx.markExternalOwnerClosed();
            RAWLAB_REQUIRE(tx.commit() == AtomicOutputStatus::Ok, "commit external owner tx");
            RAWLAB_CHECK(readText(extTarget) == "EXT_OWNER", "external owner transaction publishes cleanly");
        }
    }

    // 6. Cross-platform Unicode/CJK UTF-8 paths + nlohmann::json serialization round-trip.
    {
        const fs::path unicodeDir = dir.path / fs::u8path("测试目录 UTF8");
        const fs::path unicodeTarget = unicodeDir / fs::u8path("输出文件 样片.dat");
        AtomicOutputOptions opts;
        opts.stagingPrefix = ".rawlab-u8";
        opts.includeDestinationFilename = true;
        opts.createParentDirs = true;
        opts.modePolicy = OutputModePolicy::Standard0644;

        nlohmann::json manifest;
        manifest["target"] = unicodeTarget.u8string();
        manifest["directory"] = unicodeDir.u8string();
        const std::string encodedManifest = manifest.dump();
        const auto parsedManifest = nlohmann::json::parse(encodedManifest);
        const fs::path roundtrippedTarget = fs::u8path(parsedManifest.at("target").get<std::string>());

        AtomicOutputTransaction tx(roundtrippedTarget, opts);
        RAWLAB_REQUIRE(tx.begin() == AtomicOutputStatus::Ok, "begin succeeds for Unicode UTF-8 path");
        RAWLAB_REQUIRE(tx.writeAll(encodedManifest.data(), encodedManifest.size(), false) == AtomicOutputStatus::Ok,
            "writeAll succeeds for Unicode UTF-8 path");
        RAWLAB_REQUIRE(tx.commit() == AtomicOutputStatus::Ok, "commit succeeds for Unicode UTF-8 path");
        RAWLAB_CHECK(nlohmann::json::parse(readText(roundtrippedTarget)) == manifest,
            "nlohmann::json manifest round-trips cleanly across Unicode UTF-8 path");
    }

#ifndef _WIN32
    // 7. POSIX permission preservation (0640) and mid-write RLIMIT_FSIZE failure safety.
    {
        const fs::path posixDir = dir.path / "posix";
        fs::create_directories(posixDir);
        const fs::path permTarget = posixDir / "perm0640.dat";
        writeText(permTarget, "OLD_0640");
        RAWLAB_REQUIRE(::chmod(permTarget.c_str(), 0640) == 0, "chmod 0640");

        AtomicOutputOptions preserveOpts;
        preserveOpts.stagingPrefix = ".rawlab-perm";
        preserveOpts.modePolicy = OutputModePolicy::PreserveDestinationOrUmask;
        AtomicOutputTransaction tx(permTarget, preserveOpts);
        RAWLAB_REQUIRE(tx.begin() == AtomicOutputStatus::Ok, "begin 0640");
        const std::string replacement = "NEW_0640";
        RAWLAB_REQUIRE(tx.writeAll(replacement.data(), replacement.size(), false) == AtomicOutputStatus::Ok, "write 0640");
        RAWLAB_REQUIRE(tx.commit() == AtomicOutputStatus::Ok, "commit 0640");
        RAWLAB_CHECK(fileMode(permTarget) == 0640u && readText(permTarget) == replacement,
            "PreserveDestinationOrUmask retains 0640 mode");

        // RLIMIT_FSIZE mid-write failure in forked child preserves existing target and leaks zero staging files.
        const fs::path rlimitTarget = posixDir / "rlimit.dat";
        writeText(rlimitTarget, "KEEP_BEFORE_RLIMIT");
        const pid_t child = ::fork();
        RAWLAB_REQUIRE(child >= 0, "fork for RLIMIT_FSIZE test");
        if (child == 0) {
            std::signal(SIGXFSZ, SIG_IGN);
            const struct rlimit lim = {256, 256};
            if (::setrlimit(RLIMIT_FSIZE, &lim) != 0) _exit(2);
            int code = 4;
            {
                AtomicOutputOptions rOpts;
                rOpts.stagingPrefix = ".rawlab-rlimit";
                AtomicOutputTransaction rTx(rlimitTarget, rOpts);
                if (rTx.begin() != AtomicOutputStatus::Ok) {
                    code = 3;
                } else {
                    std::vector<uint8_t> big(4096, 0x33);
                    const auto wst = rTx.writeAll(big.data(), big.size(), false);
                    if (wst == AtomicOutputStatus::IoError) {
                        code = 0;
                    } else {
                        const auto cst = rTx.commit();
                        code = (cst == AtomicOutputStatus::IoError) ? 0 : 4;
                    }
                }
            }
            _exit(code);
        }
        int status = 0;
        RAWLAB_REQUIRE(::waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0,
            "RLIMIT_FSIZE child hits write/commit IoError cleanly");
        RAWLAB_CHECK(readText(rlimitTarget) == "KEEP_BEFORE_RLIMIT" &&
            countStagingFiles(posixDir, ".rawlab-rlimit-") == 0,
            "RLIMIT_FSIZE failure preserves destination and cleans up staging file");
    }
#endif
}

} // namespace

TEST_MAIN(
    testPinnedSourceTamperClamping();
    testAtomicOutputTransaction();
)
