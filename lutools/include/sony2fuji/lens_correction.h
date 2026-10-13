#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace sony2fuji {

struct LensMetadata {
    std::string cameraMake, cameraModel, lensMake, lensModel;
    float focalLength = 0, aperture = 0, cropFactor = 0;
    bool embeddedGeometry = false;
};

struct LensCorrectionOptions {
    bool distortion = false, tca = false, autoCrop = true;
    std::string profileID;
    bool active() const { return distortion || tca; }
};

enum class LensCorrectionState {
    Off, Matched, NoDatabase, NoCamera, NoLens, Ambiguous,
    NoCalibration, MissingFocalLength, EmbeddedGeometry, UnsupportedInput
};

struct LensProfile {
    std::string id, maker, model;
    bool hasDistortion = false, hasTCA = false, isMatch = false;
};

struct LensCorrectionReport {
    LensCorrectionState state = LensCorrectionState::Off;
    LensMetadata metadata;
    LensProfile profile;
    bool appliedDistortion = false, appliedTCA = false;
    float cropScale = 1;
};

class LensCorrectionDatabase {
public:
    static bool available();
    static std::shared_ptr<LensCorrectionDatabase> load(const std::string& path = {});
    ~LensCorrectionDatabase();
    std::vector<LensProfile> profiles(const LensMetadata& metadata) const;
    LensCorrectionReport inspect(const LensMetadata& metadata, const LensCorrectionOptions& options) const;
private:
    LensCorrectionDatabase();
    struct Impl;
    std::unique_ptr<Impl> impl_;
    friend class LensCorrectionTransform;
};

class LensCorrectionTransform {
public:
    LensCorrectionTransform(std::shared_ptr<const LensCorrectionDatabase> database,
        const LensMetadata& metadata, const LensCorrectionOptions& options,
        int width, int height, int channels);
    ~LensCorrectionTransform();
    bool active() const;
    const LensCorrectionReport& report() const;
    // Coordinates are in the unrotated active image, with six floats per pixel.
    void map(int x, int y, int width, int height, float* coordinates) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

float sampleCameraChannel(const uint16_t* pixels, int width, int height,
    int channel, float x, float y);

} // namespace sony2fuji
