#include "core/pipeline.h"

#include "core/display_lens_correction.h"

#include <cstring>
#include <utility>

namespace sony2fuji {

void Pipeline::ensureLensDatabase() {
    if (!lensDatabaseTried_) {
        lensDatabaseTried_ = true;
        lensDatabase_ = LensCorrectionDatabase::load();
    }
}

std::shared_ptr<const LensCorrectionDatabase> Pipeline::lensDatabaseShared() {
    ensureLensDatabase();
    return lensDatabase_;
}

RenderStatus Pipeline::setLensDatabase(const char* path) {
    if (!LensCorrectionDatabase::available()) return RenderStatus::Unsupported;
    try {
        auto database = LensCorrectionDatabase::load(path ? path : "");
        if (!database) return RenderStatus::IoError;
        lensDatabase_ = std::move(database);
        lensDatabaseTried_ = true;
        ++lensDatabaseRevision_;
        rawKey_.clear();
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::IoError;
    }
}

RenderStatus Pipeline::setLensCorrection(
    bool distortion,
    bool tca,
    bool autoCrop,
    bool vignetting,
    const char* profileId,
    size_t maxProfileIdBytes
) {
    if ((distortion || tca || vignetting) && !LensCorrectionDatabase::available()) {
        return RenderStatus::Unsupported;
    }
    try {
        std::string profile = profileId ? profileId : "";
        if (profile.size() >= maxProfileIdBytes) return RenderStatus::InvalidArgument;
        lensCorrection_ = {distortion, tca, autoCrop, std::move(profile), vignetting};
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::inspectLensFile(
    const char* inputPath,
    LensCorrectionReport& report,
    std::vector<LensProfile>* outProfiles
) {
    report = {};
    if (outProfiles) outProfiles->clear();
    if (inputPath == nullptr || inputPath[0] == '\0') return RenderStatus::InvalidArgument;
    try {
        LensMetadata metadata;
        const auto status = RAWProcessor::readLensMetadata(inputPath, metadata);
        if (status != ErrorCode::Success) return mapErrorCode(status);
        return inspectLensMetadata(metadata, report, outProfiles);
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

RenderStatus Pipeline::inspectLensMetadata(
    const LensMetadata& metadata,
    LensCorrectionReport& report,
    std::vector<LensProfile>* outProfiles
) {
    report = {};
    if (outProfiles) outProfiles->clear();
    try {
        ensureLensDatabase();
        LensCorrectionReport inspected;
        inspected.metadata = metadata;
        if (!lensDatabase_) {
            inspected.state = lensCorrection_.active()
                ? LensCorrectionState::NoDatabase
                : LensCorrectionState::Off;
            report = std::move(inspected);
            return RenderStatus::Ok;
        }
        report = lensDatabase_->inspect(metadata, lensCorrection_);
        if (outProfiles) {
            *outProfiles = lensDatabase_->profiles(metadata);
        }
        return RenderStatus::Ok;
    } catch (const std::bad_alloc&) {
        return RenderStatus::OutOfMemory;
    } catch (...) {
        return RenderStatus::ProcessingError;
    }
}

void Pipeline::clearDisplayLensMetadata() {
    hasDisplayLensMetadata_ = false;
    displayLensMetadata_ = {};
    displayLensOrientation_ = 1;
}

void Pipeline::setDisplayLensMetadata(LensMetadata metadata, int orientation) {
    displayLensMetadata_ = std::move(metadata);
    displayLensOrientation_ = orientation;
    hasDisplayLensMetadata_ = true;
}

} // namespace sony2fuji
