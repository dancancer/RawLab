#include "sony2fuji/lens_correction.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <filesystem>
#include <iomanip>
#include <list>
#include <mutex>
#include <sstream>
#include <type_traits>
#include <unordered_map>
#include <vector>
#ifdef SONY2FUJI_ENABLE_LENSFUN
#include <lensfun.h>
#endif

namespace sony2fuji {
namespace {
std::atomic<uint64_t> g_lensDatabaseParseCount{0};

#ifdef SONY2FUJI_ENABLE_LENSFUN
struct FileStamp {
    std::string path;
    uintmax_t size = 0;
    std::filesystem::file_time_type mtime{};

    bool operator==(const FileStamp& other) const {
        return path == other.path && size == other.size && mtime == other.mtime;
    }
};

static_assert(std::is_same_v<decltype(FileStamp::mtime), std::filesystem::file_time_type>,
    "FileStamp must store file_time_type directly to avoid integer nanosecond overflow");

struct SourceDescriptor {
    std::string cacheKey;
    bool isSystem = false;
    bool isDirectory = false;
    std::vector<std::filesystem::path> loadPaths;
    std::vector<FileStamp> stamps;
};

std::string normalizedPathString(const std::filesystem::path& path) {
    std::error_code error;
    const auto canonical = std::filesystem::canonical(path, error);
    return (!error ? canonical : path.lexically_normal()).u8string();
}

bool describeSource(const std::string& path, SourceDescriptor& out) {
    if (path.empty()) {
        out.cacheKey = "system:";
        out.isSystem = true;
        return true;
    }
    std::error_code error;
    const auto source = std::filesystem::u8path(path);
    if (std::filesystem::is_directory(source, error)) {
        std::vector<std::filesystem::path> files;
        for (std::filesystem::directory_iterator it(source, error), end; !error && it != end; it.increment(error)) {
            if (it->path().extension() == ".xml") files.push_back(it->path());
        }
        if (error || files.empty()) return false;
        std::sort(files.begin(), files.end());
        out.isDirectory = true;
        out.cacheKey = "dir:" + normalizedPathString(source);
        out.loadPaths.reserve(files.size());
        out.stamps.reserve(files.size());
        for (const auto& file : files) {
            std::error_code statError;
            const auto size = std::filesystem::file_size(file, statError);
            if (statError) return false;
            const auto mtime = std::filesystem::last_write_time(file, statError);
            if (statError) return false;
            out.loadPaths.push_back(file);
            out.stamps.push_back({normalizedPathString(file), size, mtime});
        }
        return true;
    }
    if (error || !std::filesystem::is_regular_file(source, error) || error) return false;
    std::error_code statError;
    const auto size = std::filesystem::file_size(source, statError);
    if (statError) return false;
    const auto mtime = std::filesystem::last_write_time(source, statError);
    if (statError) return false;
    const auto canon = normalizedPathString(source);
    out.cacheKey = "file:" + canon;
    out.loadPaths.push_back(source);
    out.stamps.push_back({canon, size, mtime});
    return true;
}

struct InFlightLoad {
    std::vector<FileStamp> stamps;
    std::condition_variable cv;
    bool done = false;
    std::shared_ptr<LensCorrectionDatabase> database;
};

struct CacheEntry {
    std::vector<FileStamp> stamps;
    std::shared_ptr<LensCorrectionDatabase> database;
    std::list<std::string>::iterator lruIt;
};

struct LensDatabaseCache {
    static constexpr size_t kMaxEntries = 32;
    std::mutex mutex;
    std::list<std::string> lruOrder;
    std::unordered_map<std::string, CacheEntry> entries;
    std::unordered_map<std::string, std::shared_ptr<InFlightLoad>> inFlight;
};

LensDatabaseCache& lensDatabaseCache() {
    // Process-lifetime cache intentionally outlives static locals used by caller threads.
    static auto* instance = new LensDatabaseCache();
    return *instance;
}
#endif
}

struct LensCorrectionDatabase::Impl {
#ifdef SONY2FUJI_ENABLE_LENSFUN
    mutable std::mutex lookupMutex;
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

    static LensProfile profile(const lfLens* lens, float focal, float aperture, bool match) {
        lfLensCalibDistortion distortion{};
        lfLensCalibTCA tca{};
        lfLensCalibVignetting vignetting{};
        return {id(lens), lens->Maker ? lens->Maker : "", lens->Model ? lens->Model : "",
            lens->InterpolateDistortion(focal, distortion), lens->InterpolateTCA(focal, tca), match,
            std::isfinite(aperture) && aperture > 0 && lens->InterpolateVignetting(focal, aperture, 1000, vignetting)};
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
        report.profile = profile(selected, metadata.focalLength, metadata.aperture, true);
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

uint64_t LensCorrectionDatabase::parseCount() {
    return g_lensDatabaseParseCount.load(std::memory_order_acquire);
}

std::shared_ptr<LensCorrectionDatabase> LensCorrectionDatabase::load(const std::string& path) {
#ifdef SONY2FUJI_ENABLE_LENSFUN
    SourceDescriptor source;
    if (!describeSource(path, source)) return nullptr;

    auto& cache = lensDatabaseCache();
    std::shared_ptr<InFlightLoad> leaderLoad;
    {
        std::unique_lock<std::mutex> lock(cache.mutex);
        while (true) {
            const auto cachedIt = cache.entries.find(source.cacheKey);
            if (cachedIt != cache.entries.end() && cachedIt->second.stamps == source.stamps) {
                cache.lruOrder.splice(cache.lruOrder.begin(), cache.lruOrder, cachedIt->second.lruIt);
                return cachedIt->second.database;
            }
            const auto activeIt = cache.inFlight.find(source.cacheKey);
            if (activeIt != cache.inFlight.end()) {
                auto waitingFor = activeIt->second;
                const bool sameStamp = (waitingFor->stamps == source.stamps);
                waitingFor->cv.wait(lock, [&] { return waitingFor->done; });
                if (sameStamp) return waitingFor->database;
                continue;
            }
            leaderLoad = std::make_shared<InFlightLoad>();
            leaderLoad->stamps = source.stamps;
            cache.inFlight.emplace(source.cacheKey, leaderLoad);
            break;
        }
    }

    struct InFlightGuard {
        LensDatabaseCache& cache;
        const std::string& key;
        const std::shared_ptr<InFlightLoad>& load;
        std::shared_ptr<LensCorrectionDatabase> result;
        bool cacheResult = false;
        ~InFlightGuard() {
            std::lock_guard<std::mutex> lock(cache.mutex);
            cache.inFlight.erase(key);
            if (cacheResult) {
                auto it = cache.entries.find(key);
                if (it != cache.entries.end()) {
                    cache.lruOrder.splice(cache.lruOrder.begin(), cache.lruOrder, it->second.lruIt);
                    it->second.stamps = load->stamps;
                    it->second.database = result;
                } else {
                    while (cache.entries.size() >= LensDatabaseCache::kMaxEntries && !cache.lruOrder.empty()) {
                        cache.entries.erase(cache.lruOrder.back());
                        cache.lruOrder.pop_back();
                    }
                    cache.lruOrder.push_front(key);
                    cache.entries.emplace(key, CacheEntry{load->stamps, result, cache.lruOrder.begin()});
                }
            }
            load->database = result;
            load->done = true;
            load->cv.notify_all();
        }
    } guard{cache, source.cacheKey, leaderLoad, nullptr, false};

    auto result = std::shared_ptr<LensCorrectionDatabase>(new LensCorrectionDatabase());
    auto finish = [&]() {
        const auto& database = result->impl_->database;
        std::unique_ptr<char, decltype(&lf_free)> xml(lfDatabase::Save(database.GetMounts(),
            database.GetCameras(), database.GetLenses()), &lf_free);
        if (!xml) return std::shared_ptr<LensCorrectionDatabase>{};
        // 指纹来自实际载入的标定内容；路径和 profile ID 不足以标识系数更新。
        uint64_t hash = 14695981039346656037ULL, bytes = 0;
        for (const auto* p = reinterpret_cast<const unsigned char*>(xml.get()); *p; ++p, ++bytes)
            hash = (hash ^ *p) * 1099511628211ULL;
        result->cacheIdentity_ = "lensfun-xml-v1:" + std::to_string(bytes) + ":" + std::to_string(hash);
        return result;
    };

    if (source.isSystem) {
        g_lensDatabaseParseCount.fetch_add(1, std::memory_order_acq_rel);
        guard.result = result->impl_->database.Load() == LF_NO_ERROR ? finish() : nullptr;
        guard.cacheResult = true;
        return guard.result;
    }

    g_lensDatabaseParseCount.fetch_add(1, std::memory_order_acq_rel);
    for (const auto& file : source.loadPaths) {
        if (result->impl_->database.Load(file.u8string().c_str()) != LF_NO_ERROR) return nullptr;
    }
    guard.result = finish();
    guard.cacheResult = (guard.result != nullptr);
    return guard.result;
#else
    (void)path;
    return nullptr;
#endif
}

std::vector<LensProfile> LensCorrectionDatabase::profiles(const LensMetadata& metadata) const {
    std::vector<LensProfile> result;
#ifdef SONY2FUJI_ENABLE_LENSFUN
    {
        std::lock_guard<std::mutex> lock(impl_->lookupMutex);
        const auto* body = impl_->camera(metadata);
        const auto matched = impl_->matches(metadata, body);
        const lfLens** compatible = body ? impl_->database.FindLenses(body, nullptr, nullptr) : nullptr;
        const lfLens* const* lenses = body ? compatible : impl_->database.GetLenses();
        if (lenses) for (int i = 0; lenses[i]; ++i)
            result.push_back(Impl::profile(lenses[i], metadata.focalLength, metadata.aperture,
                std::find(matched.begin(), matched.end(), lenses[i]) != matched.end()));
        lf_free(compatible);
    }
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
    std::lock_guard<std::mutex> lock(impl_->lookupMutex);
    if (impl_->resolve(metadata, options, report) &&
        !(options.distortion && report.profile.hasDistortion) && !(options.tca && report.profile.hasTCA) &&
        !(options.vignetting && report.profile.hasVignetting))
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
        report.appliedVignetting = (applied & LF_MODIFY_VIGNETTING) != 0;
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
    {
        std::lock_guard<std::mutex> lock(impl_->database->impl_->lookupMutex);
        impl_->lens = impl_->database->impl_->resolve(metadata, options, report);
        if (!impl_->lens) return;
        const auto* body = impl_->database->impl_->camera(metadata);
        impl_->crop = body ? body->CropFactor : metadata.cropFactor;
    }
    impl_->focal = metadata.focalLength; impl_->aperture = metadata.aperture;
    impl_->flags = (options.distortion ? LF_MODIFY_DISTORTION : 0) |
        (options.tca && channels == 3 ? LF_MODIFY_TCA : 0) |
        (options.vignetting && report.profile.hasVignetting ? LF_MODIFY_VIGNETTING : 0);
    impl_->initialize(1);
    if (!report.appliedDistortion && !report.appliedTCA && !report.appliedVignetting) {
        report.state = LensCorrectionState::NoCalibration;
        impl_->modifier.reset(); return;
    }
    if (options.autoCrop && hasGeometry() && !impl_->inside()) {
        float low = 1, high = 1.05f;
        for (; high <= 8; high *= 1.25f) {
            impl_->initialize(high);
            if (impl_->inside()) break;
        }
        if (high > 8) {
            report.state = LensCorrectionState::UnsupportedInput;
            report.appliedDistortion = report.appliedTCA = report.appliedVignetting = false;
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
bool LensCorrectionTransform::active() const { return hasGeometry() || impl_->report.appliedVignetting; }
bool LensCorrectionTransform::hasGeometry() const { return impl_->report.appliedDistortion || impl_->report.appliedTCA; }
float LensCorrectionTransform::gainAt(float x, float y) const {
#ifdef SONY2FUJI_ENABLE_LENSFUN
    if (impl_->report.appliedVignetting && std::isfinite(x) && std::isfinite(y)) {
        alignas(16) float gain = 1;
        impl_->modifier->ApplyColorModification(&gain, x, y, 1, 1, LF_CR_1(RED), sizeof(float));
        return gain;
    }
#else
    (void)x; (void)y;
#endif
    return 1;
}
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
