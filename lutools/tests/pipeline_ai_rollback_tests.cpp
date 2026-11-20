#include "test_harness.h"
#include "core/pipeline.h"
#include "core/pipeline_runtime.h"
#include "ai/ai_session.h"

namespace sony2fuji {

struct PreviewExposureCache::Impl {};
PreviewExposureCache::PreviewExposureCache() = default;
PreviewExposureCache::~PreviewExposureCache() = default;

struct WaveletDenoiseAnalysisCache::Impl {};
WaveletDenoiseAnalysisCache::WaveletDenoiseAnalysisCache() = default;
WaveletDenoiseAnalysisCache::~WaveletDenoiseAnalysisCache() = default;

class RAWProcessor::Impl {};
RAWProcessor::RAWProcessor() = default;
RAWProcessor::RAWProcessor(bool) {}
RAWProcessor::~RAWProcessor() = default;

ErrorCode RAWProcessor::inspectCameraHDR(const std::string&, int&, int&, uint64_t&) {
    return ErrorCode::Unsupported;
}

ErrorCode RAWProcessor::unpackInspectedCameraHDR() {
    return ErrorCode::Unsupported;
}

ErrorCode RAWProcessor::readBayerSource(const RAWProcessOptions&, RAWBayerSource&) {
    return ErrorCode::Unsupported;
}

Pipeline::Pipeline()
    : gpuConfig_(),
      runtime_(std::make_unique<PipelineRuntimeState>()) {}

Pipeline::~Pipeline() = default;

void Pipeline::ensureLensDatabase() {}

RAWProcessOptions Pipeline::rawWhiteBalanceOptions(const RenderParams&) const {
    return {};
}

RenderStatus validateRenderParams(const RenderParams&, bool) {
    return RenderStatus::Ok;
}

namespace hdr {
void admitMemory(uint64_t) {}
} // namespace hdr

namespace ai {
bool CoreMLGraph::available() { return false; }
bool CoreMLGraph::gpuPlanAvailable() { return false; }
} // namespace ai

} // namespace sony2fuji

using namespace sony2fuji;

static AiDenoiseConfig makeConfig(bool enabled) {
    AiDenoiseConfig cfg;
    cfg.enabled = enabled;
    cfg.backend = AiBackendPreference::Auto;
    cfg.modelDirectory = "/tmp/models";
    cfg.cacheDirectory = "/tmp/cache";
    return cfg;
}

TEST_MAIN({
    Pipeline pipeline;
    RAWLAB_REQUIRE(!pipeline.aiEnabled(), "fresh pipeline starts with aiEnabled() == false");
    RAWLAB_REQUIRE(ai::AISession::liveSessions == 0, "fresh pipeline starts with 0 live AISessions");

    // 1. First-time configure() failure (bad_alloc) must reset runtime_->ai and leave aiEnabled() == false.
    ai::AISession::nextConfigureFault = ai::ConfigureFault::BadAlloc;
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(true)) == RenderStatus::OutOfMemory,
                 "first failure bad_alloc maps to OutOfMemory");
    RAWLAB_CHECK(!pipeline.aiEnabled(), "first bad_alloc leaves aiEnabled() == false");
    RAWLAB_CHECK(ai::AISession::liveSessions == 0, "first bad_alloc resets runtime_->ai to null");

    // 2. First-time configure() failure (std::invalid_argument) must reset runtime_->ai and leave aiEnabled() == false.
    ai::AISession::nextConfigureFault = ai::ConfigureFault::InvalidArgument;
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(true)) == RenderStatus::InvalidArgument,
                 "first failure std::exception maps to InvalidArgument");
    RAWLAB_CHECK(!pipeline.aiEnabled(), "first std::exception leaves aiEnabled() == false");
    RAWLAB_CHECK(ai::AISession::liveSessions == 0, "first std::exception resets runtime_->ai to null");

    // 3. First-time configure() failure (non-std::exception) must reset runtime_->ai and leave aiEnabled() == false.
    ai::AISession::nextConfigureFault = ai::ConfigureFault::Unknown;
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(true)) == RenderStatus::ProcessingError,
                 "first failure unknown exception maps to ProcessingError");
    RAWLAB_CHECK(!pipeline.aiEnabled(), "first unknown exception leaves aiEnabled() == false");
    RAWLAB_CHECK(ai::AISession::liveSessions == 0, "first unknown exception resets runtime_->ai to null");

    // 4. Subsequent valid enable succeeds.
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(true)) == RenderStatus::Ok,
                 "valid setAiDenoise(true) succeeds");
    RAWLAB_CHECK(pipeline.aiEnabled(), "valid setAiDenoise(true) enables AI");
    RAWLAB_CHECK(ai::AISession::liveSessions == 1, "valid setAiDenoise(true) creates ai session");

    // 5. When hadAI == true and previousEnabled == true, failed disable restores previousEnabled == true.
    ai::AISession::nextConfigureFault = ai::ConfigureFault::InvalidArgument;
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(false)) == RenderStatus::InvalidArgument,
                 "failed disable maps to InvalidArgument");
    RAWLAB_CHECK(pipeline.aiEnabled(), "failed disable restores previousEnabled == true");
    RAWLAB_CHECK(ai::AISession::liveSessions == 1, "failed disable keeps existing ai session");

    // 6. Valid disable sets enabled == false while retaining session.
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(false)) == RenderStatus::Ok,
                 "valid setAiDenoise(false) succeeds");
    RAWLAB_CHECK(!pipeline.aiEnabled(), "valid setAiDenoise(false) disables AI");
    RAWLAB_CHECK(ai::AISession::liveSessions == 1, "valid disable keeps existing ai session");

    // 7. When hadAI == true and previousEnabled == false, failures restore previousEnabled == false.
    ai::AISession::nextConfigureFault = ai::ConfigureFault::BadAlloc;
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(true)) == RenderStatus::OutOfMemory,
                 "re-enable bad_alloc maps to OutOfMemory");
    RAWLAB_CHECK(!pipeline.aiEnabled(), "re-enable bad_alloc restores previousEnabled == false");

    ai::AISession::nextConfigureFault = ai::ConfigureFault::InvalidArgument;
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(true)) == RenderStatus::InvalidArgument,
                 "re-enable invalid_argument maps to InvalidArgument");
    RAWLAB_CHECK(!pipeline.aiEnabled(), "re-enable invalid_argument restores previousEnabled == false");

    ai::AISession::nextConfigureFault = ai::ConfigureFault::Unknown;
    RAWLAB_CHECK(pipeline.setAiDenoise(makeConfig(true)) == RenderStatus::ProcessingError,
                 "re-enable unknown maps to ProcessingError");
    RAWLAB_CHECK(!pipeline.aiEnabled(), "re-enable unknown restores previousEnabled == false");
})
