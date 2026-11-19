#include "ffi/session_internal.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <string>
#include <vector>

namespace {

template <size_t N>
void copyLensText(char (&destination)[N], const std::string& source) noexcept {
    const size_t length = std::min(N - 1, source.size());
    std::copy_n(source.data(), length, destination);
    destination[length] = '\0';
}

sony2fuji_lens_profile toFfiLensProfile(const sony2fuji::LensProfile& profile) noexcept {
    sony2fuji_lens_profile result{};
    copyLensText(result.id, profile.id);
    copyLensText(result.maker, profile.maker);
    copyLensText(result.model, profile.model);
    result.has_distortion = profile.hasDistortion;
    result.has_tca = profile.hasTCA;
    result.is_match = profile.isMatch;
    return result;
}

sony2fuji_lens_report toFfiLensReport(const sony2fuji::LensCorrectionReport& report) noexcept {
    sony2fuji_lens_report result{};
    result.state = static_cast<sony2fuji_lens_state>(report.state);
    copyLensText(result.camera_make, report.metadata.cameraMake);
    copyLensText(result.camera_model, report.metadata.cameraModel);
    copyLensText(result.lens_model, report.metadata.lensModel);
    result.focal_length = report.metadata.focalLength;
    result.profile = toFfiLensProfile(report.profile);
    result.applied_distortion = report.appliedDistortion;
    result.applied_tca = report.appliedTCA;
    result.crop_scale = report.cropScale;
    return result;
}

void assignLensReport(sony2fuji_lens_report* output, const sony2fuji::LensCorrectionReport& source) noexcept {
    *output = toFfiLensReport(source);
}

void assignLensReport(sony2fuji_lens_report_v2* output, const sony2fuji::LensCorrectionReport& source) noexcept {
    *output = {toFfiLensReport(source), source.profile.hasVignetting, source.appliedVignetting};
}

void assignLensProfile(sony2fuji_lens_profile* output, const sony2fuji::LensProfile& source) noexcept {
    *output = toFfiLensProfile(source);
}

void assignLensProfile(sony2fuji_lens_profile_v2* output, const sony2fuji::LensProfile& source) noexcept {
    *output = {toFfiLensProfile(source), source.hasVignetting};
}

bool copyMetadataText(const char* source, size_t capacity, std::string& result) {
    if (!source) {
        result.clear();
        return true;
    }
    size_t length = 0;
    while (length < capacity && source[length]) ++length;
    if (length == capacity) return false;
    result.assign(source, length);
    return true;
}

bool readDisplayLensMetadata(const sony2fuji_lens_metadata* input, sony2fuji::LensMetadata& metadata) {
    if (!input || input->version != SONY2FUJI_LENS_METADATA_VERSION || input->struct_size < sizeof(*input) ||
        input->source_orientation < 1 || input->source_orientation > 8 ||
        (input->embedded_geometry != 0 && input->embedded_geometry != 1) ||
        !std::isfinite(input->focal_length) || input->focal_length < 0 ||
        !std::isfinite(input->aperture) || input->aperture < 0 ||
        !std::isfinite(input->crop_factor) || input->crop_factor < 0) {
        return false;
    }
    if (!copyMetadataText(input->camera_make, 128, metadata.cameraMake) ||
        !copyMetadataText(input->camera_model, 128, metadata.cameraModel) ||
        !copyMetadataText(input->lens_make, 128, metadata.lensMake) ||
        !copyMetadataText(input->lens_model, 256, metadata.lensModel)) {
        return false;
    }
    metadata.focalLength = input->focal_length;
    metadata.aperture = input->aperture;
    metadata.cropFactor = input->crop_factor;
    metadata.embeddedGeometry = input->embedded_geometry != 0;
    return true;
}

template <class Report, class Profile>
sony2fuji_status writeLensInspection(
    sony2fuji::RenderStatus status,
    const sony2fuji::LensCorrectionReport& coreReport,
    const std::vector<sony2fuji::LensProfile>& catalog,
    Report* report,
    Profile* profiles,
    uint32_t capacity,
    uint32_t* count
) noexcept {
    if (status != sony2fuji::RenderStatus::Ok) return toFfiStatus(status);
    assignLensReport(report, coreReport);
    *count = static_cast<uint32_t>(catalog.size());
    if (profiles) {
        if (capacity < catalog.size()) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        for (size_t i = 0; i < catalog.size(); ++i) assignLensProfile(&profiles[i], catalog[i]);
    }
    return SONY2FUJI_STATUS_OK;
}

} // namespace

sony2fuji_status sony2fuji_session_set_lens_database(sony2fuji_session* handle, const char* path) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    return toFfiStatus(lease.raw()->pipeline.setLensDatabase(path));
}

sony2fuji_status sony2fuji_session_set_lens_correction(
    sony2fuji_session* handle,
    const sony2fuji_lens_correction_config* config
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->version != SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION ||
        config->struct_size != sizeof(*config) ||
        (config->distortion != 0 && config->distortion != 1) ||
        (config->tca != 0 && config->tca != 1) ||
        (config->auto_crop != 0 && config->auto_crop != 1)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setLensCorrection(
        config->distortion != 0, config->tca != 0, config->auto_crop != 0, false,
        config->profile_id, sizeof(sony2fuji_lens_profile::id)));
}

sony2fuji_status sony2fuji_session_set_lens_correction_v2(
    sony2fuji_session* handle,
    const sony2fuji_lens_correction_config_v2* config
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !config ||
        config->base.version != SONY2FUJI_LENS_CORRECTION_CONFIG_V2_VERSION ||
        config->base.struct_size != sizeof(*config) ||
        (config->base.distortion != 0 && config->base.distortion != 1) ||
        (config->base.tca != 0 && config->base.tca != 1) ||
        (config->base.auto_crop != 0 && config->base.auto_crop != 1) ||
        (config->vignetting != 0 && config->vignetting != 1)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    return toFfiStatus(lease.raw()->pipeline.setLensCorrection(
        config->base.distortion != 0, config->base.tca != 0, config->base.auto_crop != 0,
        config->vignetting != 0, config->base.profile_id, sizeof(sony2fuji_lens_profile::id)));
}

sony2fuji_status sony2fuji_session_get_lens_report(sony2fuji_session* handle, sony2fuji_lens_report* report) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !report) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    *report = toFfiLensReport(lease.constRaw()->pipeline.lensReport());
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_get_lens_report_v2(sony2fuji_session* handle, sony2fuji_lens_report_v2* report) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !report) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    assignLensReport(report, lease.constRaw()->pipeline.lensReport());
    return SONY2FUJI_STATUS_OK;
}

sony2fuji_status sony2fuji_session_inspect_lens(
    sony2fuji_session* handle, const char* input_path,
    sony2fuji_lens_report* report, sony2fuji_lens_profile* profiles, uint32_t capacity, uint32_t* count
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !input_path || !*input_path || !report || !count ||
        (!profiles && capacity != 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *count = 0;
    *report = {};
    try {
        sony2fuji::LensCorrectionReport coreReport;
        std::vector<sony2fuji::LensProfile> catalog;
        const auto status = lease.raw()->pipeline.inspectLensFile(input_path, coreReport, &catalog);
        return writeLensInspection(status, coreReport, catalog, report, profiles, capacity, count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_session_inspect_lens_v2(
    sony2fuji_session* handle, const char* input_path,
    sony2fuji_lens_report_v2* report, sony2fuji_lens_profile_v2* profiles, uint32_t capacity, uint32_t* count
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !input_path || !*input_path || !report || !count ||
        (!profiles && capacity != 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *count = 0;
    *report = {};
    try {
        sony2fuji::LensCorrectionReport coreReport;
        std::vector<sony2fuji::LensProfile> catalog;
        const auto status = lease.raw()->pipeline.inspectLensFile(input_path, coreReport, &catalog);
        return writeLensInspection(status, coreReport, catalog, report, profiles, capacity, count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_session_set_display_lens_metadata(
    sony2fuji_session* handle,
    const sony2fuji_lens_metadata* metadata
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    if (!metadata) {
        lease.raw()->pipeline.clearDisplayLensMetadata();
        return SONY2FUJI_STATUS_OK;
    }
    try {
        sony2fuji::LensMetadata copied;
        if (!readDisplayLensMetadata(metadata, copied)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        lease.raw()->pipeline.setDisplayLensMetadata(std::move(copied), metadata->source_orientation);
        return SONY2FUJI_STATUS_OK;
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_session_inspect_lens_metadata(
    sony2fuji_session* handle, const sony2fuji_lens_metadata* metadata,
    sony2fuji_lens_report* report, sony2fuji_lens_profile* profiles, uint32_t capacity, uint32_t* count
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !report || !count || (!profiles && capacity != 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *count = 0;
    *report = {};
    try {
        sony2fuji::LensMetadata copied;
        if (!readDisplayLensMetadata(metadata, copied)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        sony2fuji::LensCorrectionReport coreReport;
        std::vector<sony2fuji::LensProfile> catalog;
        const auto status = lease.raw()->pipeline.inspectLensMetadata(copied, coreReport, &catalog);
        return writeLensInspection(status, coreReport, catalog, report, profiles, capacity, count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}

sony2fuji_status sony2fuji_session_inspect_lens_metadata_v2(
    sony2fuji_session* handle, const sony2fuji_lens_metadata* metadata,
    sony2fuji_lens_report_v2* report, sony2fuji_lens_profile_v2* profiles, uint32_t capacity, uint32_t* count
) {
    SessionLease lease;
    if (!SessionLease::acquire(handle, lease) || !report || !count || (!profiles && capacity != 0)) {
        return SONY2FUJI_STATUS_INVALID_ARGUMENT;
    }
    *count = 0;
    *report = {};
    try {
        sony2fuji::LensMetadata copied;
        if (!readDisplayLensMetadata(metadata, copied)) return SONY2FUJI_STATUS_INVALID_ARGUMENT;
        sony2fuji::LensCorrectionReport coreReport;
        std::vector<sony2fuji::LensProfile> catalog;
        const auto status = lease.raw()->pipeline.inspectLensMetadata(copied, coreReport, &catalog);
        return writeLensInspection(status, coreReport, catalog, report, profiles, capacity, count);
    } catch (const std::bad_alloc&) {
        return SONY2FUJI_STATUS_OUT_OF_MEMORY;
    } catch (...) {
        return SONY2FUJI_STATUS_PROCESSING_ERROR;
    }
}
