#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"
#include "sony2fuji/lens_correction.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

struct StartGate {
    std::mutex mutex;
    std::condition_variable cv;
    int arrived = 0;
    int target = 0;

    explicit StartGate(int count) : target(count) {}

    void arriveAndWait() {
        std::unique_lock<std::mutex> lock(mutex);
        ++arrived;
        if (arrived >= target) {
            cv.notify_all();
        } else {
            cv.wait(lock, [this] { return arrived >= target; });
        }
    }
};

std::string readFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    require(static_cast<bool>(in), "unable to read fixture xml: " + path.u8string());
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

void writeFile(const std::filesystem::path& path, const std::string& contents) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    require(static_cast<bool>(out), "unable to write temp xml: " + path.u8string());
    out.write(contents.data(), static_cast<std::streamsize>(contents.size()));
    out.flush();
    require(static_cast<bool>(out), "failed flushing temp xml: " + path.u8string());
}

void testSequentialTenSessionsExplicitDatabase(const std::filesystem::path& xmlPath) {
    const uint64_t before = sony2fuji::LensCorrectionDatabase::parseCount();
    const auto pathStr = xmlPath.u8string();
    std::string firstIdentity;

    for (int i = 0; i < 10; ++i) {
        sony2fuji_session* session = nullptr;
        require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session != nullptr, "session create");
        require(sony2fuji_session_set_lens_database(session, pathStr.c_str()) == SONY2FUJI_STATUS_OK,
            "session_set_lens_database failed");

        sony2fuji_lens_metadata meta{SONY2FUJI_LENS_METADATA_VERSION, sizeof(meta),
            "RawLab", "Test Camera", "RawLab", "Test 24mm f/2.8", 24.0f, 2.8f, 1.0f, 0, 1};
        sony2fuji_lens_report report{};
        uint32_t count = 0;
        require(sony2fuji_session_inspect_lens_metadata(session, &meta, &report, nullptr, 0, &count) == SONY2FUJI_STATUS_OK,
            "inspect_lens_metadata failed");
        require(count == 4, "unexpected lens catalog size");
        require(sony2fuji_session_destroy(session) == SONY2FUJI_STATUS_OK, "session destroy");

        const auto db = sony2fuji::LensCorrectionDatabase::load(pathStr);
        require(db != nullptr, "direct load returned null");
        if (i == 0) firstIdentity = db->cacheIdentity();
        require(db->cacheIdentity() == firstIdentity, "cacheIdentity changed across unchanged loads");
    }

    const uint64_t parses = sony2fuji::LensCorrectionDatabase::parseCount() - before;
    require(parses == 1,
        "10 sequential sessions with same lens database should parse once, got " + std::to_string(parses));
}

void testSequentialTenSessionsDefaultSystemDatabase() {
    const uint64_t before = sony2fuji::LensCorrectionDatabase::parseCount();
    for (int i = 0; i < 10; ++i) {
        sony2fuji_session* session = nullptr;
        require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session != nullptr, "sys session create");
        sony2fuji_lens_metadata meta{SONY2FUJI_LENS_METADATA_VERSION, sizeof(meta),
            "RawLab", "Test Camera", "RawLab", "Test 24mm f/2.8", 24.0f, 2.8f, 1.0f, 0, 1};
        sony2fuji_lens_report report{};
        uint32_t count = 0;
        require(sony2fuji_session_inspect_lens_metadata(session, &meta, &report, nullptr, 0, &count) == SONY2FUJI_STATUS_OK,
            "default inspect_lens_metadata failed");
        require(sony2fuji_session_destroy(session) == SONY2FUJI_STATUS_OK, "sys session destroy");
    }
    const uint64_t parses = sony2fuji::LensCorrectionDatabase::parseCount() - before;
    require(parses == 1,
        "10 sequential sessions using default system lens database should load at most once, got " +
            std::to_string(parses));
}

void testConcurrentColdStartAndQueries(const std::filesystem::path& xmlPath, const std::filesystem::path& dirPath) {
    constexpr int kThreads = 8;
    StartGate gate(kThreads);
    std::vector<std::shared_ptr<sony2fuji::LensCorrectionDatabase>> loaded(kThreads);
    const uint64_t beforeFile = sony2fuji::LensCorrectionDatabase::parseCount();

    std::vector<std::thread> workers;
    workers.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        workers.emplace_back([&, i] {
            gate.arriveAndWait();
            loaded[i] = sony2fuji::LensCorrectionDatabase::load(xmlPath.u8string());
        });
    }
    for (auto& w : workers) w.join();

    const uint64_t parsesFile = sony2fuji::LensCorrectionDatabase::parseCount() - beforeFile;
    require(parsesFile == 1,
        "8 concurrent cold-start loads of same XML file must parse once, got " + std::to_string(parsesFile));

    for (int i = 0; i < kThreads; ++i) {
        require(loaded[i] != nullptr, "concurrent load returned nullptr");
        require(loaded[i]->cacheIdentity() == loaded[0]->cacheIdentity(),
            "concurrently loaded DB identities differ");
        require(loaded[i].get() == loaded[0].get(),
            "concurrently loaded DB instances were not shared from process cache");
    }

    // Exercise concurrent queries and LensCorrectionTransform construction on the shared DB instance.
    sony2fuji::LensMetadata metadata;
    metadata.cameraMake = "RawLab";
    metadata.cameraModel = "Test Camera";
    metadata.lensMake = "RawLab";
    metadata.lensModel = "Test 24mm f/2.8";
    metadata.focalLength = 24.0f;
    metadata.aperture = 2.8f;
    sony2fuji::LensCorrectionOptions options;
    options.distortion = true;
    options.tca = true;

    StartGate queryGate(kThreads);
    std::vector<bool> queryOk(kThreads, false);
    workers.clear();
    for (int i = 0; i < kThreads; ++i) {
        workers.emplace_back([&, i] {
            queryGate.arriveAndWait();
            for (int iter = 0; iter < 10; ++iter) {
                const auto profiles = loaded[i]->profiles(metadata);
                const auto report = loaded[i]->inspect(metadata, options);
                sony2fuji::LensCorrectionTransform transform(loaded[i], metadata, options, 65, 49, 3);
                if (profiles.size() != 4 || report.state != sony2fuji::LensCorrectionState::Matched || !transform.active()) {
                    return;
                }
            }
            queryOk[i] = true;
        });
    }
    for (auto& w : workers) w.join();
    for (int i = 0; i < kThreads; ++i) {
        require(queryOk[i], "concurrent read query on shared LensCorrectionDatabase failed");
    }

    // Also test concurrent C ABI sessions loading the same directory database simultaneously.
    StartGate dirGate(kThreads);
    const uint64_t beforeDir = sony2fuji::LensCorrectionDatabase::parseCount();
    std::vector<sony2fuji_status> dirStatuses(kThreads, SONY2FUJI_STATUS_PROCESSING_ERROR);
    workers.clear();
    for (int i = 0; i < kThreads; ++i) {
        workers.emplace_back([&, i] {
            sony2fuji_session* session = nullptr;
            if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return;
            dirGate.arriveAndWait();
            const auto s1 = sony2fuji_session_set_lens_database(session, dirPath.u8string().c_str());
            sony2fuji_lens_metadata meta{SONY2FUJI_LENS_METADATA_VERSION, sizeof(meta),
                "RawLab", "Test Camera", "RawLab", "Test 24mm f/2.8", 24.0f, 2.8f, 1.0f, 0, 1};
            sony2fuji_lens_report report{};
            uint32_t count = 0;
            const auto s2 = sony2fuji_session_inspect_lens_metadata(session, &meta, &report, nullptr, 0, &count);
            sony2fuji_session_destroy(session);
            if (s1 == SONY2FUJI_STATUS_OK && s2 == SONY2FUJI_STATUS_OK && count == 4) {
                dirStatuses[i] = SONY2FUJI_STATUS_OK;
            }
        });
    }
    for (auto& w : workers) w.join();
    const uint64_t parsesDir = sony2fuji::LensCorrectionDatabase::parseCount() - beforeDir;
    for (int i = 0; i < kThreads; ++i) {
        require(dirStatuses[i] == SONY2FUJI_STATUS_OK, "concurrent C ABI directory lens DB load failed");
    }
    require(parsesDir == 1,
        "8 concurrent C ABI sessions loading same directory DB must parse once, got " + std::to_string(parsesDir));
}

void testInvalidationAndNonPoisoning(const std::filesystem::path& tempRoot) {
    const auto xmlFile = tempRoot / "dynamic-lenses.xml";
    const auto fixtureXml = readFile(std::filesystem::u8path(TEST_FIXTURE_DIR) / "lenses.xml");

    // Non-existent file must fail without poisoning the cache when the file appears later.
    require(sony2fuji::LensCorrectionDatabase::load(xmlFile.u8string()) == nullptr,
        "missing file unexpectedly succeeded");

    writeFile(xmlFile, fixtureXml);
    const uint64_t b1 = sony2fuji::LensCorrectionDatabase::parseCount();
    const auto first = sony2fuji::LensCorrectionDatabase::load(xmlFile.u8string());
    require(first != nullptr, "newly created xml file failed to load");
    require(sony2fuji::LensCorrectionDatabase::parseCount() - b1 == 1,
        "first load of created file should parse once");

    const uint64_t b2 = sony2fuji::LensCorrectionDatabase::parseCount();
    const auto cached = sony2fuji::LensCorrectionDatabase::load(xmlFile.u8string());
    require(cached != nullptr && cached->cacheIdentity() == first->cacheIdentity(), "cached load mismatch");
    require(sony2fuji::LensCorrectionDatabase::parseCount() - b2 == 0,
        "second load of unmodified file must hit cache (0 parses)");

    // Mutate content + size (note also update write time explicitly to handle coarse clocks).
    std::string edited = fixtureXml;
    const auto pos = edited.find("-0.12");
    require(pos != std::string::npos, "fixture coefficient marker missing");
    edited.replace(pos, 5, "-0.155");
    writeFile(xmlFile, edited);
    std::error_code ec;
    const auto now = std::filesystem::last_write_time(xmlFile, ec);
    if (!ec) std::filesystem::last_write_time(xmlFile, now + std::chrono::seconds(2), ec);

    const uint64_t b3 = sony2fuji::LensCorrectionDatabase::parseCount();
    const auto reloaded = sony2fuji::LensCorrectionDatabase::load(xmlFile.u8string());
    require(reloaded != nullptr && reloaded->cacheIdentity() != first->cacheIdentity(),
        "modified XML file did not produce updated calibration identity");
    require(sony2fuji::LensCorrectionDatabase::parseCount() - b3 == 1,
        "modified XML file should trigger exactly 1 reload");

    const uint64_t b4 = sony2fuji::LensCorrectionDatabase::parseCount();
    const auto cachedAgain = sony2fuji::LensCorrectionDatabase::load(xmlFile.u8string());
    require(cachedAgain != nullptr && cachedAgain->cacheIdentity() == reloaded->cacheIdentity(),
        "reload result not cached");
    require(sony2fuji::LensCorrectionDatabase::parseCount() - b4 == 0,
        "third load after modification must hit updated cache (0 parses)");
}

} // namespace

int main() {
    const auto nonce = std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    const auto tempRoot = std::filesystem::temp_directory_path() / ("rawlab-lens-cache-" + nonce);
    try {
        std::filesystem::create_directories(tempRoot);
        const auto singleDir = tempRoot / "single";
        const auto concurrentDir = tempRoot / "concurrent";
        const auto dirDb = tempRoot / "dir-db";
        std::filesystem::create_directories(singleDir);
        std::filesystem::create_directories(concurrentDir);
        std::filesystem::create_directories(dirDb);

        const auto fixtureXml = readFile(std::filesystem::u8path(TEST_FIXTURE_DIR) / "lenses.xml");
        const auto seqXml = singleDir / "lenses.xml";
        const auto concXml = concurrentDir / "lenses.xml";
        const auto dirXml = dirDb / "lenses.xml";
        writeFile(seqXml, fixtureXml);
        writeFile(concXml, fixtureXml);
        writeFile(dirXml, fixtureXml);

        testSequentialTenSessionsExplicitDatabase(seqXml);
        testSequentialTenSessionsDefaultSystemDatabase();
        testConcurrentColdStartAndQueries(concXml, dirDb);
        testInvalidationAndNonPoisoning(tempRoot);

        std::filesystem::remove_all(tempRoot);
        std::cout << "Lens database process-level cache tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::error_code ec;
        std::filesystem::remove_all(tempRoot, ec);
        std::cerr << "FAIL lens_database_cache: " << error.what() << '\n';
        return 1;
    }
}
