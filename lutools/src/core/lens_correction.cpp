#include "sony2fuji/lens_correction.h"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <iomanip>
#include <sstream>
#ifdef SONY2FUJI_ENABLE_LENSFUN
#include <lensfun.h>
#endif

namespace sony2fuji {

struct LensCorrectionDatabase::Impl {
#ifdef SONY2FUJI_ENABLE_LENSFUN
    lfDatabase database;

    const lfCamera* camera(const LensMetadata& metadata) const {
        const lfCamera** cameras = database.FindCameras(metadata.cameraMake.c_str(), metadata.cameraModel.c_str());
        const lfCamera* result = cameras && cameras[0] && !cameras[1] ? cameras[0] : nullptr;
        lf_free(cameras);
        return result;
    }

    static std::string id(const lfLens* lens) {
        std::ostringstream key;
        key << lens->Maker << '\n' << lens->Model << '\n';
        if (lens->Mounts && lens->Mounts[0]) key << lens->Mounts[0];
        key << '\n' << std::fixed << std::setprecision(6) << lens->CropFactor;
        return key.str();
    }

    static LensProfile profile(const lfLens* lens, float focal, bool match) {
        lfLensCalibDistortion distortion{};
        lfLensCalibTCA tca{};
        return {id(lens), lens->Maker ? lens->Maker : "", lens->Model ? lens->Model : "",
            lens->InterpolateDistortion(focal, distortion), lens->InterpolateTCA(focal, tca), match};
    }

    std::vector<const lfLens*> matches(const LensMetadata& metadata, const lfCamera* camera) const {
        if (metadata.lensModel.empty() && (!camera || !camera->Mount || camera->Mount[0] < 'a' || camera->Mount[0] > 'z')) return {};
        const lfLens** lenses = database.FindLenses(camera,
            metadata.lensMake.empty() ? nullptr : metadata.lensMake.c_str(),
            metadata.lensModel.empty() ? nullptr : metadata.lensModel.c_str());
        std::vector<const lfLens*> result;
        if (lenses) for (int i = 0; lenses[i]; ++i) result.push_back(lenses[i]);
        lf_free(lenses);
        return result;
    }

    const lfLens* resolve(const LensMetadata& metadata, const LensCorrectionOptions& options,
                         LensCorrectionReport& report) const {
        report.metadata = metadata;
        const auto* body = camera(metadata);
        if (!body && !(std::isfinite(metadata.cropFactor) && metadata.cropFactor > 0)) {
            report.state = LensCorrectionState::NoCamera;
            return nullptr;
        }
        const lfLens* selected = nullptr;
        if (!options.profileID.empty()) {
            for (auto lens = database.GetLenses(); lens && *lens; ++lens)
                if (id(*lens) == options.profileID) { selected = *lens; break; }
        } else {
            const auto candidates = matches(metadata, body);
            if (candidates.size() == 1) selected = candidates.front();
            else if (candidates.size() > 1) {
                report.state = LensCorrectionState::Ambiguous;
                return nullptr;
            }
        }
        if (!selected) { report.state = LensCorrectionState::NoLens; return nullptr; }
        report.profile = profile(selected, metadata.focalLength, true);
        report.state = LensCorrectionState::Matched;
        return selected;
    }
#endif
};

LensCorrectionDatabase::LensCorrectionDatabase() : impl_(std::make_unique<Impl>()) {}
LensCorrectionDatabase::~LensCorrectionDatabase() = default;

bool LensCorrectionDatabase::available() {
#ifdef SONY2FUJI_ENABLE_LENSFUN
    return true;
#else
    return false;
#endif
}

std::shared_ptr<LensCorrectionDatabase> LensCorrectionDatabase::load(const std::string& path) {
#ifdef SONY2FUJI_ENABLE_LENSFUN
    auto result = std::shared_ptr<LensCorrectionDatabase>(new LensCorrectionDatabase());
    if (path.empty()) return result->impl_->database.Load() == LF_NO_ERROR ? result : nullptr;
    std::error_code error;
    const auto source = std::filesystem::u8path(path);
    if (std::filesystem::is_directory(source, error)) {
        std::vector<std::filesystem::path> files;
        for (std::filesystem::directory_iterator it(source, error), end; !error && it != end; it.increment(error))
            if (it->path().extension() == ".xml") files.push_back(it->path());
        if (error || files.empty()) return nullptr;
        std::sort(files.begin(), files.end());
        for (const auto& file : files)
            if (result->impl_->database.Load(file.u8string().c_str()) != LF_NO_ERROR) return nullptr;
        return result;
    }
    return result->impl_->database.Load(path.c_str()) == LF_NO_ERROR ? result : nullptr;
#else
    (void)path;
    return nullptr;
#endif
}

std::vector<LensProfile> LensCorrectionDatabase::profiles(const LensMetadata& metadata) const {
    std::vector<LensProfile> result;
#ifdef SONY2FUJI_ENABLE_LENSFUN
    const auto* body = impl_->camera(metadata);
    const auto matched = impl_->matches(metadata, body);
    const lfLens** compatible = body ? impl_->database.FindLenses(body, nullptr, nullptr) : nullptr;
    const lfLens* const* lenses = body ? compatible : impl_->database.GetLenses();
    if (lenses) for (int i = 0; lenses[i]; ++i)
        result.push_back(Impl::profile(lenses[i], metadata.focalLength,
            std::find(matched.begin(), matched.end(), lenses[i]) != matched.end()));
    lf_free(compatible);
    std::sort(result.begin(), result.end(), [](const LensProfile& a, const LensProfile& b) {
        if (a.isMatch != b.isMatch) return a.isMatch > b.isMatch;
        return a.maker == b.maker ? a.model < b.model : a.maker < b.maker;
    });
#else
    (void)metadata;
#endif
    return result;
}

LensCorrectionReport LensCorrectionDatabase::inspect(const LensMetadata& metadata, const LensCorrectionOptions& options) const {
    LensCorrectionReport report;
    report.metadata = metadata;
    if (!options.active()) return report;
    if (metadata.embeddedGeometry) { report.state = LensCorrectionState::EmbeddedGeometry; return report; }
#ifdef SONY2FUJI_ENABLE_LENSFUN
    if (!std::isfinite(metadata.focalLength) || metadata.focalLength <= 0) {
        report.state = LensCorrectionState::MissingFocalLength;
        return report;
    }
    if (impl_->resolve(metadata, options, report) &&
        !(options.distortion && report.profile.hasDistortion) && !(options.tca && report.profile.hasTCA))
        report.state = LensCorrectionState::NoCalibration;
#else
    report.state = LensCorrectionState::NoDatabase;
#endif
    return report;
}

struct LensCorrectionTransform::Impl {
    std::shared_ptr<const LensCorrectionDatabase> database;
    LensCorrectionReport report;
    int width = 0, height = 0;
#ifdef SONY2FUJI_ENABLE_LENSFUN
    std::unique_ptr<lfModifier> modifier;
    const lfLens* lens = nullptr;
    float crop = 1, focal = 0, aperture = 0;
    int flags = 0;
    void initialize(float scale) {
        modifier = std::make_unique<lfModifier>(lens, crop, width, height);
        const int applied = modifier->Initialize(lens, LF_PF_F32, focal, aperture, 1000,
            scale, lens->Type, flags | LF_MODIFY_SCALE, false);
        report.appliedDistortion = (applied & LF_MODIFY_DISTORTION) != 0;
        report.appliedTCA = (applied & LF_MODIFY_TCA) != 0;
    }
    bool inside() const {
        // Include all channel footprints, not only the green-channel distortion model.
        alignas(16) float coordinates[6];
        auto valid = [&](int x, int y) {
            modifier->ApplySubpixelGeometryDistortion(float(x), float(y), 1, 1, coordinates);
            for (int c = 0; c < 3; ++c)
                if (!std::isfinite(coordinates[c * 2]) || !std::isfinite(coordinates[c * 2 + 1]) ||
                    coordinates[c * 2] < 0 || coordinates[c * 2] > width - 1 ||
                    coordinates[c * 2 + 1] < 0 || coordinates[c * 2 + 1] > height - 1) return false;
            return true;
        };
        for (int x = 0; x < width; ++x) if (!valid(x, 0) || !valid(x, height - 1)) return false;
        for (int y = 1; y < height - 1; ++y) if (!valid(0, y) || !valid(width - 1, y)) return false;
        return true;
    }
#endif
};

LensCorrectionTransform::LensCorrectionTransform(std::shared_ptr<const LensCorrectionDatabase> database,
    const LensMetadata& metadata, const LensCorrectionOptions& options, int width, int height, int channels)
    : impl_(std::make_unique<Impl>()) {
    impl_->database = std::move(database);
    impl_->width = width; impl_->height = height;
    auto& report = impl_->report;
    report.metadata = metadata;
    if (!options.active()) return;
    if (metadata.embeddedGeometry) { report.state = LensCorrectionState::EmbeddedGeometry; return; }
    if (!impl_->database) { report.state = LensCorrectionState::NoDatabase; return; }
    if (!std::isfinite(metadata.focalLength) || metadata.focalLength <= 0) {
        report.state = LensCorrectionState::MissingFocalLength; return;
    }
    if (width < 2 || height < 2 || (channels != 3 && channels != 4)) {
        report.state = LensCorrectionState::UnsupportedInput; return;
    }
#ifdef SONY2FUJI_ENABLE_LENSFUN
    impl_->lens = impl_->database->impl_->resolve(metadata, options, report);
    if (!impl_->lens) return;
    const auto* body = impl_->database->impl_->camera(metadata);
    impl_->crop = body ? body->CropFactor : metadata.cropFactor;
    impl_->focal = metadata.focalLength; impl_->aperture = metadata.aperture;
    impl_->flags = (options.distortion ? LF_MODIFY_DISTORTION : 0) |
        (options.tca && channels == 3 ? LF_MODIFY_TCA : 0);
    impl_->initialize(1);
    if (!report.appliedDistortion && !report.appliedTCA) {
        report.state = LensCorrectionState::NoCalibration;
        impl_->modifier.reset(); return;
    }
    if (options.autoCrop && !impl_->inside()) {
        float low = 1, high = 1.05f;
        for (; high <= 8; high *= 1.25f) {
            impl_->initialize(high);
            if (impl_->inside()) break;
        }
        if (high > 8) {
            report.state = LensCorrectionState::UnsupportedInput;
            report.appliedDistortion = report.appliedTCA = false;
            impl_->modifier.reset(); return;
        }
        for (int i = 0; i < 18; ++i) {
            const float middle = (low + high) * .5f;
            impl_->initialize(middle);
            if (impl_->inside()) high = middle; else low = middle;
        }
        report.cropScale = high * 1.00001f;
        impl_->initialize(report.cropScale);
    }
#endif
}

LensCorrectionTransform::~LensCorrectionTransform() = default;
bool LensCorrectionTransform::active() const { return impl_->report.appliedDistortion || impl_->report.appliedTCA; }
const LensCorrectionReport& LensCorrectionTransform::report() const { return impl_->report; }

void LensCorrectionTransform::map(int x, int y, int width, int height, float* coordinates) const {
#ifdef SONY2FUJI_ENABLE_LENSFUN
    if (impl_->modifier && impl_->modifier->ApplySubpixelGeometryDistortion(float(x), float(y), width, height, coordinates)) return;
#endif
    for (int row = 0; row < height; ++row) for (int col = 0; col < width; ++col)
        for (int c = 0; c < 3; ++c) {
            *coordinates++ = float(x + col); *coordinates++ = float(y + row);
        }
}

float sampleCameraChannel(const uint16_t* pixels, int width, int height, int channel, float x, float y) {
    if (!pixels || width <= 0 || height <= 0 || channel < 0 || channel > 3 ||
        !std::isfinite(x) || !std::isfinite(y) || x < -1e-4f || y < -1e-4f ||
        x > width - 1 + 1e-4f || y > height - 1 + 1e-4f) return 0;
    x = std::clamp(x, 0.f, float(width - 1)); y = std::clamp(y, 0.f, float(height - 1));
    const int x0 = int(std::floor(x)), y0 = int(std::floor(y));
    const int x1 = std::min(x0 + 1, width - 1), y1 = std::min(y0 + 1, height - 1);
    auto at = [&](int col, int row) { return float(pixels[(static_cast<size_t>(row) * width + col) * 4 + channel]); };
    const float dx = x - x0, dy = y - y0;
    return ((1 - dx) * at(x0, y0) + dx * at(x1, y0)) * (1 - dy) +
        ((1 - dx) * at(x0, y1) + dx * at(x1, y1)) * dy;
}

} // namespace sony2fuji
