#include "sony2fuji/ffi/sony2fuji_c.h"
#include "sony2fuji/ffi/sony2fuji_hdr.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

struct BarrierState {
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
    bool released = false;
};

int32_t pauseInFlightCallback(void* context) {
    auto* state = static_cast<BarrierState*>(context);
    std::unique_lock<std::mutex> lock(state->mutex);
    if (!state->entered) {
        state->entered = true;
        state->cv.notify_all();
    }
    state->cv.wait(lock, [state] { return state->released; });
    return 0;
}

struct BarrierWorkerGuard {
    BarrierState& barrier;
    std::thread& worker;
    ~BarrierWorkerGuard() {
        {
            std::lock_guard<std::mutex> lock(barrier.mutex);
            barrier.released = true;
            barrier.cv.notify_all();
        }
        if (worker.joinable()) worker.join();
    }
};

sony2fuji_request makeBufferRequest(std::vector<uint8_t>& pixels) {
    pixels.assign(8 * 8 * 3, 128);
    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_BUFFER;
    request.input_pixels = pixels.data();
    request.input_width = 8;
    request.input_height = 8;
    request.input_pixel_format = SONY2FUJI_PIXEL_RGB8;
    request.input_color_space = SONY2FUJI_COLOR_SRGB;
    request.input_is_linear = 1;
    request.temperature = 6500;
    request.brightness = 1.0f;
    request.contrast = 1.0f;
    request.saturation = 1.0f;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.output_target = SONY2FUJI_TARGET_BUFFER;
    request.output_format = SONY2FUJI_OUTPUT_RGB8;
    request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}

template <class T>
T initHdrStruct() {
    T value{};
    value.version = 1;
    value.struct_size = sizeof(T);
    return value;
}

struct HdrPairFixture {
    std::vector<float> hdr{0.18f, 0.18f, 0.18f, 0.5f, 0.5f, 0.5f};
    std::vector<float> sdr{0.18f, 0.18f, 0.18f, 0.5f, 0.5f, 0.5f};
    sony2fuji_hdr_image_pair_v1 pair = initHdrStruct<sony2fuji_hdr_image_pair_v1>();

    HdrPairFixture() {
        for (auto* buffer : {&pair.hdr, &pair.sdr}) {
            *buffer = initHdrStruct<sony2fuji_hdr_buffer_v1>();
            buffer->width = 2;
            buffer->height = 1;
            buffer->stride_bytes = 24;
            buffer->size_bytes = 24;
            buffer->pixel_format = SONY2FUJI_HDR_RGB32F_LINEAR;
            buffer->color_encoding = SONY2FUJI_HDR_LINEAR_SRGB;
        }
        pair.hdr.data = hdr.data();
        pair.sdr.data = sdr.data();
        pair.native_width = 2;
        pair.native_height = 1;
        pair.orientation_applied = 1;
        pair.source_intent = SONY2FUJI_INTENT_FINAL;
        pair.render_intent = SONY2FUJI_INTENT_FINAL;
        pair.decode_revision = 1;
        pair.source_headroom = 1.0f;
        pair.source_headroom_kind = SONY2FUJI_HDR_HEADROOM_DECLARED;
    }
};

sony2fuji_hdr_request_v1 makeHdrRequest() {
    auto request = initHdrStruct<sony2fuji_hdr_request_v1>();
    request.hdr_processing_version = SONY2FUJI_HDR_PROCESSING_VERSION;
    request.temperature = 6500;
    request.contrast = 1.0f;
    request.saturation = 1.0f;
    request.crop_width = 1.0f;
    request.crop_height = 1.0f;
    request.intent = SONY2FUJI_INTENT_FINAL;
    return request;
}

void testSerialCrossThreadHandoff() {
    // Legitimate hosts (Swift actors, C# SafeHandle finalizers, Kotlin queues) may
    // serialize calls across different OS threads and destroy from a finalizer thread.
    sony2fuji_session* session = nullptr;
    std::thread creator([&] {
        require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session != nullptr,
            "creator thread failed to create session");
    });
    creator.join();

    std::thread configurator([&] {
        require(sony2fuji_session_set_processing_version(session, SONY2FUJI_PROCESSING_BASIC_V3) == SONY2FUJI_STATUS_OK,
            "configurator thread failed on serialized handoff");
    });
    configurator.join();

    std::thread renderer([&] {
        std::vector<uint8_t> pixels;
        const auto request = makeBufferRequest(pixels);
        sony2fuji_buffer output{};
        require(sony2fuji_process(session, &request, &output) == SONY2FUJI_STATUS_OK,
            "renderer thread failed on serialized handoff");
        sony2fuji_release_buffer(&output);
    });
    renderer.join();

    std::thread destroyer([&] {
        require(sony2fuji_session_destroy(session) == SONY2FUJI_STATUS_OK,
            "destroyer thread failed on serialized handoff");
    });
    destroyer.join();
}

void testIndependentSessionsParallel() {
    constexpr int kThreads = 4;
    std::vector<sony2fuji_status> statuses(kThreads, SONY2FUJI_STATUS_PROCESSING_ERROR);
    std::vector<std::thread> workers;
    workers.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        workers.emplace_back([&, i] {
            sony2fuji_session* session = nullptr;
            if (sony2fuji_session_create(&session) != SONY2FUJI_STATUS_OK) return;
            std::vector<uint8_t> pixels;
            const auto request = makeBufferRequest(pixels);
            sony2fuji_buffer output{};
            const auto status = sony2fuji_process(session, &request, &output);
            sony2fuji_release_buffer(&output);
            const auto destroyed = sony2fuji_session_destroy(session);
            if (status == SONY2FUJI_STATUS_OK && destroyed == SONY2FUJI_STATUS_OK) {
                statuses[i] = SONY2FUJI_STATUS_OK;
            }
        });
    }
    for (auto& w : workers) w.join();
    for (int i = 0; i < kThreads; ++i) {
        require(statuses[i] == SONY2FUJI_STATUS_OK, "independent session parallel run failed");
    }
}

void testConcurrentCrossThreadAndDestroyInFlight(bool testDestroyInFlight, bool testConcurrentCalls) {
    sony2fuji_session* session = nullptr;
    require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session != nullptr, "session create");
    BarrierState barrier;
    require(sony2fuji_session_set_cancellation_callback(session, pauseInFlightCallback, &barrier) == SONY2FUJI_STATUS_OK,
        "set cancellation barrier");

    std::vector<uint8_t> pixels;
    const auto request = makeBufferRequest(pixels);
    sony2fuji_status workerStatus = SONY2FUJI_STATUS_PROCESSING_ERROR;

    std::thread worker([&] {
        sony2fuji_buffer output{};
        workerStatus = sony2fuji_process(session, &request, &output);
        sony2fuji_release_buffer(&output);
    });
    BarrierWorkerGuard workerGuard{barrier, worker};

    {
        std::unique_lock<std::mutex> lock(barrier.mutex);
        barrier.cv.wait(lock, [&] { return barrier.entered; });
    }

    if (testConcurrentCalls) {
        const auto setterStatus = sony2fuji_session_set_processing_version(session, SONY2FUJI_PROCESSING_BASIC_V3);
        require(setterStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "concurrent cross-thread set_processing_version was not rejected (got status " +
                std::to_string(setterStatus) + ")");

        sony2fuji_geometry_config geom{SONY2FUJI_GEOMETRY_CONFIG_VERSION, sizeof(geom), 0.1f, 0.1f, 0.8f, 0.8f, 0, 0, 0, 0};
        const auto geomStatus = sony2fuji_session_set_geometry(session, &geom);
        require(geomStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "concurrent cross-thread set_geometry was not rejected (got status " +
                std::to_string(geomStatus) + ")");

        sony2fuji_buffer buf2{};
        const auto process2Status = sony2fuji_process(session, &request, &buf2);
        sony2fuji_release_buffer(&buf2);
        require(process2Status == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "concurrent cross-thread sony2fuji_process was not rejected (got status " +
                std::to_string(process2Status) + ")");

        sony2fuji_hsl_probe* probe = nullptr;
        const auto probeStatus = sony2fuji_session_create_hsl_probe(session, &request, 1, 1, &probe);
        if (probe) sony2fuji_hsl_probe_destroy(probe);
        require(probeStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT && probe == nullptr,
            "concurrent cross-thread create_hsl_probe was not rejected (got status " +
                std::to_string(probeStatus) + ")");

        sony2fuji_processing_migration_result migration{};
        const auto migrateStatus = sony2fuji_session_migrate_processing(session, &request, &migration);
        require(migrateStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "concurrent cross-thread migrate_processing was not rejected (got status " +
                std::to_string(migrateStatus) + ")");

        HdrPairFixture fixture;
        auto hdrRequest = makeHdrRequest();
        auto hdrOutput = initHdrStruct<sony2fuji_hdr_image_pair_v1>();
        auto diag = initHdrStruct<sony2fuji_hdr_diagnostic_v1>();
        const auto hdrStatus = sony2fuji_hdr_render(session, &fixture.pair, &hdrRequest, &hdrOutput, &diag);
        sony2fuji_hdr_release_pair(&hdrOutput);
        require(hdrStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "concurrent cross-thread hdr_render was not rejected (got status " +
                std::to_string(hdrStatus) + ")");

        // Also check non-null busy session in optional-session HDR decode entrypoints.
        auto decodeOpts = initHdrStruct<sony2fuji_hdr_decode_options_v1>();
        decodeOpts.intent = SONY2FUJI_INTENT_PREVIEW;
        decodeOpts.long_edge = 64;
        auto decodePair = initHdrStruct<sony2fuji_hdr_image_pair_v1>();
        const auto hdrDecodeStatus = sony2fuji_hdr_decode_camera_raw(
            session, TEST_FIXTURE_DIR "/linear-lens.dng", &decodeOpts, &decodePair, &diag);
        sony2fuji_hdr_release_pair(&decodePair);
        require(hdrDecodeStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "concurrent cross-thread hdr_decode_camera_raw was not rejected (got status " +
                std::to_string(hdrDecodeStatus) + ")");
    }

    if (testDestroyInFlight) {
        const auto destroyBusyStatus = sony2fuji_session_destroy(session);
        require(destroyBusyStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "out-of-order destroy while session is active in another thread was not rejected (got status " +
                std::to_string(destroyBusyStatus) + ")");
    }

    {
        std::lock_guard<std::mutex> lock(barrier.mutex);
        barrier.released = true;
        barrier.cv.notify_all();
    }
    worker.join();

    require(workerStatus == SONY2FUJI_STATUS_OK,
        "in-flight sony2fuji_process failed after concurrent attempts were rejected");
    require(sony2fuji_session_destroy(session) == SONY2FUJI_STATUS_OK,
        "final session_destroy after worker completion failed");
}

void testHdrInFlightGuard() {
    sony2fuji_session* session = nullptr;
    require(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK && session != nullptr, "hdr session create");
    BarrierState barrier;
    require(sony2fuji_session_set_cancellation_callback(session, pauseInFlightCallback, &barrier) == SONY2FUJI_STATUS_OK,
        "set hdr cancellation barrier");

    HdrPairFixture fixture;
    const auto hdrRequest = makeHdrRequest();
    sony2fuji_status probeStatus = SONY2FUJI_STATUS_PROCESSING_ERROR;
    sony2fuji_hsl_probe* probe = nullptr;
    auto diag = initHdrStruct<sony2fuji_hdr_diagnostic_v1>();

    std::thread worker([&] {
        probeStatus = sony2fuji_hdr_create_hsl_probe(session, &fixture.pair, &hdrRequest, 1, 1, &probe, &diag);
    });
    BarrierWorkerGuard workerGuard{barrier, worker};

    {
        std::unique_lock<std::mutex> lock(barrier.mutex);
        barrier.cv.wait(lock, [&] { return barrier.entered; });
    }

    const auto setterStatus = sony2fuji_session_set_processing_version(session, SONY2FUJI_PROCESSING_BASIC_V3);
    const auto destroyBusyStatus = sony2fuji_session_destroy(session);

    {
        std::lock_guard<std::mutex> lock(barrier.mutex);
        barrier.released = true;
        barrier.cv.notify_all();
    }
    worker.join();
    if (probe) sony2fuji_hsl_probe_destroy(probe);

    require(setterStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "concurrent set_processing_version during hdr_create_hsl_probe was not rejected");
    require(destroyBusyStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "out-of-order destroy during hdr_create_hsl_probe was not rejected");
    require(probeStatus == SONY2FUJI_STATUS_OK, "hdr_create_hsl_probe failed after rejecting concurrent caller");
    require(sony2fuji_session_destroy(session) == SONY2FUJI_STATUS_OK, "hdr final destroy failed");
}

void testDestroyedAndInvalidHandles(bool runUaf, bool runDoubleDestroy, bool runForeign, bool runAba) {
    require(sony2fuji_session_destroy(nullptr) == SONY2FUJI_STATUS_OK, "destroy(nullptr) must succeed as no-op");
    require(sony2fuji_session_set_processing_version(nullptr, SONY2FUJI_PROCESSING_LEGACY) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
        "null setter must reject");

    if (runForeign) {
        auto* bogus = reinterpret_cast<sony2fuji_session*>(static_cast<uintptr_t>(0xDEADBEEF0ULL));
        require(sony2fuji_session_set_processing_version(bogus, SONY2FUJI_PROCESSING_LEGACY) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "foreign pointer must return INVALID_ARGUMENT");
        require(sony2fuji_session_destroy(bogus) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "destroying foreign pointer must return INVALID_ARGUMENT");
    }

    sony2fuji_session* stale = nullptr;
    require(sony2fuji_session_create(&stale) == SONY2FUJI_STATUS_OK && stale != nullptr, "stale baseline create");
    require(sony2fuji_session_destroy(stale) == SONY2FUJI_STATUS_OK, "stale baseline destroy");

    if (runUaf) {
        const auto useStatus = sony2fuji_session_set_processing_version(stale, SONY2FUJI_PROCESSING_BASIC_V3);
        require(useStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "use-after-destroy setter was not rejected (got status " + std::to_string(useStatus) + ")");

        std::vector<uint8_t> pixels;
        const auto request = makeBufferRequest(pixels);
        sony2fuji_buffer output{};
        const auto procStatus = sony2fuji_process(stale, &request, &output);
        sony2fuji_release_buffer(&output);
        require(procStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "use-after-destroy process was not rejected");

        HdrPairFixture fixture;
        const auto hdrRequest = makeHdrRequest();
        auto hdrOutput = initHdrStruct<sony2fuji_hdr_image_pair_v1>();
        auto diag = initHdrStruct<sony2fuji_hdr_diagnostic_v1>();
        require(sony2fuji_hdr_render(stale, &fixture.pair, &hdrRequest, &hdrOutput, &diag) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "use-after-destroy hdr_render was not rejected");

        auto decodeOpts = initHdrStruct<sony2fuji_hdr_decode_options_v1>();
        decodeOpts.intent = SONY2FUJI_INTENT_PREVIEW;
        decodeOpts.long_edge = 64;
        auto decodePair = initHdrStruct<sony2fuji_hdr_image_pair_v1>();
        require(sony2fuji_hdr_decode_camera_raw(stale, TEST_FIXTURE_DIR "/linear-lens.dng", &decodeOpts, &decodePair, &diag) ==
                SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "use-after-destroy hdr_decode_camera_raw was not rejected");

        require(std::strcmp(sony2fuji_session_x3f_error(stale), "Invalid session") == 0,
            "use-after-destroy x3f_error did not return safe fallback");
        require(sony2fuji_session_get_last_backend(stale) == SONY2FUJI_BACKEND_CPU,
            "use-after-destroy get_last_backend did not return safe fallback");
        require(sony2fuji_session_get_raw_decode_count(stale) == 0,
            "use-after-destroy get_raw_decode_count did not return safe fallback");
    }

    if (runDoubleDestroy) {
        const auto againStatus = sony2fuji_session_destroy(stale);
        require(againStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "double destroy was not rejected (got status " + std::to_string(againStatus) + ")");
    }

    if (runAba) {
        // Allocate and keep 64 fresh sessions so naive malloc reuse would overlap 'stale' if unguarded.
        std::vector<sony2fuji_session*> liveSessions;
        liveSessions.reserve(64);
        for (int i = 0; i < 64; ++i) {
            sony2fuji_session* next = nullptr;
            require(sony2fuji_session_create(&next) == SONY2FUJI_STATUS_OK && next != nullptr, "ABA live create");
            liveSessions.push_back(next);
            require(next != stale, "ABA handle value reused an already-destroyed session handle");
        }
        const auto abaStatus = sony2fuji_session_set_processing_version(stale, SONY2FUJI_PROCESSING_BASIC_V3);
        const auto abaDestroy = sony2fuji_session_destroy(stale);
        for (sony2fuji_session* live : liveSessions) {
            require(sony2fuji_session_destroy(live) == SONY2FUJI_STATUS_OK, "ABA cleanup destroy");
        }
        require(abaStatus == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "stale handle succeeded after subsequent session creations (got status " + std::to_string(abaStatus) + ")");
        require(abaDestroy == SONY2FUJI_STATUS_INVALID_ARGUMENT,
            "stale handle destroy succeeded after subsequent session creations (got status " + std::to_string(abaDestroy) + ")");
    }
}

} // namespace

int main(int argc, char** argv) {
    try {
        std::string only;
        if (argc == 2 && std::strncmp(argv[1], "--only=", 7) == 0) {
            only = argv[1] + 7;
        } else if (argc != 1) {
            return 2;
        }

        if (only.empty() || only == "serial") testSerialCrossThreadHandoff();
        if (only.empty() || only == "parallel") testIndependentSessionsParallel();
        if (only.empty() || only == "concurrent") testConcurrentCrossThreadAndDestroyInFlight(false, true);
        if (only.empty() || only == "destroy-inflight") testConcurrentCrossThreadAndDestroyInFlight(true, false);
        if (only.empty() || only == "hdr-concurrent") testHdrInFlightGuard();
        if (only.empty() || only == "uaf") testDestroyedAndInvalidHandles(true, false, false, false);
        if (only.empty() || only == "double-destroy") testDestroyedAndInvalidHandles(false, true, false, false);
        if (only.empty() || only == "foreign") testDestroyedAndInvalidHandles(false, false, true, false);
        if (only.empty() || only == "aba") testDestroyedAndInvalidHandles(false, false, false, true);

        std::cout << "Session handle boundary validation tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL session_boundary: " << error.what() << '\n';
        return 1;
    }
}
