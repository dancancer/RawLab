#include "sony2fuji/lens_correction.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
#include <vector>

using namespace sony2fuji;

int main() {
    auto db = LensCorrectionDatabase::load(TEST_FIXTURE_DIR "/lenses.xml");
    assert(db);
    LensMetadata metadata;
    metadata.cameraMake = "RawLab"; metadata.cameraModel = "Test Camera";
    metadata.lensMake = "RawLab"; metadata.lensModel = "Test 24mm f/2.8";
    metadata.focalLength = 24; metadata.aperture = 2.8f;
    LensCorrectionOptions options;
    options.distortion = true; options.tca = true;
    const auto profiles = db->profiles(metadata);
    assert(profiles.size() == 4);
    const auto matched = db->inspect(metadata, options);
    assert(matched.state == LensCorrectionState::Matched && !matched.profile.id.empty());
    assert(matched.profile.hasDistortion && matched.profile.hasTCA);
    auto unknownCamera = metadata;
    unknownCamera.cameraModel = "Unknown Camera";
    unknownCamera.cropFactor = 1;
    const auto fallbackProfiles = db->profiles(unknownCamera);
    assert(fallbackProfiles.size() == 4 && fallbackProfiles.front().isMatch);
    assert(db->inspect(unknownCamera, options).state == LensCorrectionState::Matched);
    unknownCamera.lensModel = "unknown lens";
    auto manual = options; manual.profileID = matched.profile.id;
    assert(db->inspect(unknownCamera, manual).state == LensCorrectionState::Matched);
    unknownCamera.cropFactor = 0;
    assert(db->inspect(unknownCamera, manual).state == LensCorrectionState::NoCamera);
    options.autoCrop = false;
    LensCorrectionTransform transform(db, metadata, options, 129, 97, 3);
    assert(transform.active());
    std::vector<float> coordinates(129 * 97 * 6);
    transform.map(0, 0, 129, 97, coordinates.data());
    assert(coordinates[0] != coordinates[2] && coordinates[2] != coordinates[4]);
    assert(transform.report().appliedDistortion && transform.report().appliedTCA);
    options.autoCrop = true;
    LensCorrectionTransform cropped(db, metadata, options, 129, 97, 3);
    assert(cropped.active() && cropped.report().cropScale >= 1);
    cropped.map(0, 0, 129, 97, coordinates.data());
    for (size_t i = 0; i < coordinates.size(); i += 2) {
        assert(std::isfinite(coordinates[i]) && coordinates[i] >= -1e-4f && coordinates[i] <= 128.0001f);
        assert(std::isfinite(coordinates[i + 1]) && coordinates[i + 1] >= -1e-4f && coordinates[i + 1] <= 96.0001f);
    }
    std::vector<uint16_t> camera(129 * 97 * 4, 1000);
    for (size_t i = 0; i < coordinates.size(); i += 6)
        for (int c = 0; c < 3; ++c)
            assert(std::abs(sampleCameraChannel(camera.data(), 129, 97, c, coordinates[i + c * 2], coordinates[i + c * 2 + 1]) - 1000) < 0.01f);
    assert(sampleCameraChannel(camera.data(), 129, 97, 0, -1, 0) == 0);
    assert(sampleCameraChannel(camera.data(), 129, 97, 0, std::numeric_limits<float>::quiet_NaN(), 0) == 0);
    options.profileID = matched.profile.id;
    metadata.lensModel = "not in database";
    assert(db->inspect(metadata, options).state == LensCorrectionState::Matched);
    options.profileID.clear();
    assert(db->inspect(metadata, options).state == LensCorrectionState::NoLens);
    metadata.lensModel = "Twin 35mm f/2"; metadata.focalLength = 35;
    assert(db->inspect(metadata, options).state == LensCorrectionState::Ambiguous);
    metadata.lensModel = "Test 50mm f/2"; metadata.focalLength = 50;
    options.distortion = false;
    LensCorrectionTransform noTCA(db, metadata, options, 129, 97, 3);
    assert(!noTCA.active() && noTCA.report().state == LensCorrectionState::NoCalibration);
    assert(db->inspect(metadata, options).state == LensCorrectionState::NoCalibration);
    metadata.lensModel = "Test 24mm f/2.8"; metadata.focalLength = 24;
    options.distortion = true;
    LensCorrectionTransform four(db, metadata, options, 129, 97, 4);
    assert(four.report().appliedDistortion && !four.report().appliedTCA);
    metadata.embeddedGeometry = true;
    LensCorrectionTransform embedded(db, metadata, options, 129, 97, 3);
    assert(!embedded.active() && embedded.report().state == LensCorrectionState::EmbeddedGeometry);
    metadata.embeddedGeometry = false;
    options = {};
    assert(db->inspect(metadata, options).state == LensCorrectionState::Off);
    LensCorrectionTransform disabled(db, metadata, options, 129, 97, 3);
    assert(!disabled.active() && disabled.report().state == LensCorrectionState::Off);
    disabled.map(0, 0, 129, 1, coordinates.data());
    assert(coordinates[0] == 0 && coordinates[6] == 1 && coordinates[128 * 6] == 128);

    sony2fuji_session* session = nullptr;
    assert(sony2fuji_session_create(&session) == SONY2FUJI_STATUS_OK);
    sony2fuji_lens_correction_config config{SONY2FUJI_LENS_CORRECTION_CONFIG_VERSION, sizeof(config), 1, 1, 1, nullptr};
    assert(sony2fuji_session_set_lens_correction(nullptr, &config) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    auto invalid = config; invalid.auto_crop = 2;
    assert(sony2fuji_session_set_lens_correction(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    invalid = config; invalid.version = 99;
    assert(sony2fuji_session_set_lens_correction(session, &invalid) == SONY2FUJI_STATUS_INVALID_ARGUMENT);
    assert(sony2fuji_session_set_lens_database(session, TEST_FIXTURE_DIR "/lenses.xml") == SONY2FUJI_STATUS_OK);
    assert(sony2fuji_session_set_lens_database(session, "/no/such/lenses.xml") == SONY2FUJI_STATUS_IO_ERROR);
    assert(sony2fuji_session_set_lens_correction(session, &config) == SONY2FUJI_STATUS_OK);
    sony2fuji_session_destroy(session);
    std::cout << "Lens matching, combined TCA/distortion, automatic crop and C ABI passed\n";
}
