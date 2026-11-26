#include "sony2fuji/gui_store.h"
#include "platform/file_lock.h"
#include "nlohmann/json.hpp"

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using Json = nlohmann::json;
using namespace sony2fuji::gui_store;
using namespace sony2fuji::platform;

namespace {

struct TempDirGuard {
    std::filesystem::path dir;
    explicit TempDirGuard(const std::string& prefix) {
        const auto base = std::filesystem::temp_directory_path();
        const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
        dir = base / (prefix + "-" + std::to_string(now));
        std::filesystem::create_directories(dir);
    }
    ~TempDirGuard() {
        std::error_code ec;
        std::filesystem::remove_all(dir, ec);
    }
};

void writeRaw(const std::filesystem::path& p, const std::string& bytes) {
    std::filesystem::create_directories(p.parent_path());
    std::ofstream out(p, std::ios::binary | std::ios::trunc);
    assert(out.good());
    out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    assert(out.good());
}

std::string readRaw(const std::filesystem::path& p) {
    std::ifstream in(p, std::ios::binary);
    assert(in.good());
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void testPresetLifecycleAndUnreadablePreservation() {
    TempDirGuard guard("rawlab-gui-store-presets");
    const auto dataDir = guard.dir / "data";
    const auto presetsFile = dataDir / "Presets" / "presets.json";

    int64_t fakeClock = 1700000000000LL;
    int uuidSeq = 1;
    GuiStoreOptions opts;
    opts.clockMillis = [&]() { return fakeClock; };
    opts.generateUuid = [&]() {
        char buf[37];
        std::snprintf(buf, sizeof(buf), "00000000-0000-4000-8000-%012d", uuidSeq++);
        return std::string(buf);
    };

    // 1. Create with NFD + preset whitespace name -> NFC + trimmed
    const std::string decomposedE = "e\xCC\x81"; // e + combining acute
    const std::string nfcE = "\xC3\xA9";        // é
    const Json createReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "\u3000  Caf" + decomposedE + " Look \u00A0"},
        {"is_raw", true},
        {"processing_version", 3},
        {"values", {
            {"light.exposure", 0.75},
            {"looks.reference", {{"kind", "builtin"}, {"id", "classic_chrome"}}},
            {"looks.strength", 0.8},
            {"color.white_balance.mode", "camera"},
            {"color.white_balance.temperature_kelvin", nullptr},
            {"color.white_balance.tint", nullptr},
        }},
    };
    const auto r1 = savePresetFromRequestJson(createReq.dump(), opts);
    assert(r1.ok);
    const Json j1 = Json::parse(r1.resultJson);
    assert(j1.at("action") == "created");
    assert(j1.at("id") == "00000000-0000-4000-8000-000000000001");
    assert(j1.at("name") == ("Caf" + nfcE + " Look"));

    // 2. Duplicate without overwrite fails
    const auto rDup = savePresetFromRequestJson(createReq.dump(), opts);
    assert(!rDup.ok);
    assert(rDup.status == GuiStoreStatus::InvalidArgument);

    // 3. Inject an unreadable future entry + retired_id + single leading UTF-8 BOM
    const std::string unreadableRaw = R"({"id":"99999999-9999-4999-8999-999999999999","name":"FuturePreset","future_only":{"nested":[1,2,3],"emoji":"🎨"}})";
    const std::string retiredUuid = "11111111-1111-4111-8111-111111111111";
    const Json currentStore = Json::parse(readRaw(presetsFile));
    const std::string withBomAndFuture =
        std::string("\xEF\xBB\xBF") +
        "{\"presets\":[" + currentStore.at("presets")[0].dump() + "," + unreadableRaw +
        "],\"registry_version\":1,\"retired_ids\":[\"" + retiredUuid + "\"]}";
    writeRaw(presetsFile, withBomAndFuture);

    // 4. Reject collision with unreadable future entry name
    Json futureNameCollision = createReq;
    futureNameCollision["name"] = "FuturePreset";
    futureNameCollision["overwrite"] = true;
    const auto rColl = savePresetFromRequestJson(futureNameCollision.dump(), opts);
    assert(!rColl.ok);
    assert(rColl.status == GuiStoreStatus::InvalidArgument);

    // 5. Overwrite existing preset with clock rollback -> monotonic updated_at + unreadable verbatim at end
    fakeClock = 1600000000000LL;
    Json updateReq = createReq;
    updateReq["name"] = "Caf" + nfcE + " Look";
    updateReq["overwrite"] = true;
    updateReq["values"]["light.exposure"] = 1.25;
    const auto r2 = savePresetFromRequestJson(updateReq.dump(), opts);
    assert(r2.ok);
    const Json j2 = Json::parse(r2.resultJson);
    assert(j2.at("action") == "updated");
    assert(j2.at("id") == "00000000-0000-4000-8000-000000000001");

    const std::string finalBytes = readRaw(presetsFile);
    assert(finalBytes.find(unreadableRaw) != std::string::npos);
    const Json finalStore = Json::parse(finalBytes);
    assert(finalStore.at("presets").size() == 2);
    assert(finalStore.at("presets")[1].at("name") == "FuturePreset");
    assert(finalStore.at("presets")[0].at("updated_at") == 1700000000001LL);
    assert(finalStore.at("retired_ids").size() == 1);
    assert(finalStore.at("retired_ids")[0] == retiredUuid);

    // 6. Reject BOM-only, double-BOM, duplicate keys, float timestamps
    writeRaw(presetsFile, "\xEF\xBB\xBF");
    assert(!savePresetFromRequestJson(createReq.dump(), opts).ok);

    writeRaw(presetsFile, "\xEF\xBB\xBF\xEF\xBB\xBF{\"registry_version\":1,\"presets\":[]}");
    assert(!savePresetFromRequestJson(createReq.dump(), opts).ok);

    writeRaw(presetsFile, " \xEF\xBB\xBF{\"registry_version\":1,\"presets\":[]}");
    assert(!savePresetFromRequestJson(createReq.dump(), opts).ok);

    writeRaw(presetsFile, "{\"registry_version\":1,\"registry_version\":1,\"presets\":[]}");
    assert(!savePresetFromRequestJson(createReq.dump(), opts).ok);
}

void testHdrVersionsAndValidation() {
    TempDirGuard guard("rawlab-gui-store-hdr");
    const auto dataDir = guard.dir / "data";

    // HDR v1 rejects v2 fields (light.curve)
    const Json hdrV1Bad = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "HDR v1 bad"},
        {"is_raw", false},
        {"hdr_processing_version", 1},
        {"values", {
            {"light.exposure", 0.5},
            {"light.curve", {{"mode", "legacy"}, {"points", Json::array()}}},
        }},
    };
    assert(!savePresetFromRequestJson(hdrV1Bad.dump()).ok);

    // HDR v8 rejects v9 extensions (luminance in wheel, free endpoints, parametric)
    const Json hdrV8Bad = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "HDR v8 bad"},
        {"is_raw", false},
        {"hdr_processing_version", 8},
        {"values", {
            {"color.grading.shadows", {{"hue", 120.0}, {"saturation", 30.0}, {"luminance", 5.0}}},
        }},
    };
    assert(!savePresetFromRequestJson(hdrV8Bad.dump()).ok);

    // HDR v9 accepts full extensions + camera_development + hdr.look
    const Json hdrV9Ok = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "HDR v9 ok"},
        {"is_raw", false},
        {"hdr_processing_version", 9},
        {"values", {
            {"light.exposure", 0.4},
            {"light.curve", {
                {"mode", "custom"},
                {"points", Json::array({{0.0, 0.05}, {0.5, 0.52}, {1.0, 0.95}})},
                {"channels", {{"red", {{"mode", "custom"}, {"points", Json::array({{0.0, 0.02}, {1.0, 0.98}})}}}}},
            }},
            {"light.curve.apply_to_luminosity", true},
            {"light.curve.parametric", {
                {"highlights", 10.0}, {"lights", 5.0}, {"darks", -5.0}, {"shadows", -10.0},
                {"split_shadow", 0.25}, {"split_midtone", 0.5}, {"split_highlight", 0.75},
            }},
            {"color.grading.global", {{"hue", 45.0}, {"saturation", 20.0}, {"luminance", -5.0}}},
            {"color.grading.blending", 65.0},
            {"color.grading.balance", -15.0},
            {"hdr.look", {{"sha256", std::string(64, 'a')}, {"name", "Fuji HDR"}, {"strength", 1.0}}},
            {"hdr.camera_development", {
                {"version", 1}, {"white_balance_mode", "as_shot"},
                {"temperature", 0.0}, {"tint", 0.0},
                {"exposure_reference", "sensor"}, {"fbdd_level", 1},
            }},
        }},
    };
    const auto res = savePresetFromRequestJson(hdrV9Ok.dump());
    assert(res.ok);

    // 端点 x 内移：v9 必须拒绝（已发布客户端读不懂），v10 接受；主曲线与分通道同规则。
    auto freeXMaster = hdrV9Ok;
    freeXMaster["name"] = "HDR free X master";
    freeXMaster["values"]["light.curve"]["points"] = Json::array({{0.15, 0.0}, {0.5, 0.52}, {0.85, 1.0}});
    assert(!savePresetFromRequestJson(freeXMaster.dump()).ok);
    auto freeXChannel = hdrV9Ok;
    freeXChannel["name"] = "HDR free X channel";
    freeXChannel["values"]["light.curve"]["channels"]["red"]["points"] = Json::array({{0.1, 0.0}, {0.9, 1.0}});
    assert(!savePresetFromRequestJson(freeXChannel.dump()).ok);
    freeXMaster["hdr_processing_version"] = 10;
    assert(savePresetFromRequestJson(freeXMaster.dump()).ok);
    freeXChannel["hdr_processing_version"] = 10;
    assert(savePresetFromRequestJson(freeXChannel.dump()).ok);
    auto hdrV11 = freeXMaster;
    hdrV11["name"] = "HDR v11";
    hdrV11["hdr_processing_version"] = 11;
    assert(!savePresetFromRequestJson(hdrV11.dump()).ok);

    // SDR 预设没有处理版本门槛，端点 x 内移直接接受；越界仍拒绝。
    const Json sdrFreeX = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "SDR free X"},
        {"is_raw", false},
        {"values", {{"light.curve", {{"mode", "custom"}, {"points", Json::array({{0.15, 0.0}, {0.85, 1.0}})}}}}},
    };
    assert(savePresetFromRequestJson(sdrFreeX.dump()).ok);
    auto sdrOutOfRange = sdrFreeX;
    sdrOutOfRange["name"] = "SDR out of range";
    sdrOutOfRange["values"]["light.curve"]["points"] = Json::array({{-0.05, 0.0}, {1.0, 1.0}});
    assert(!savePresetFromRequestJson(sdrOutOfRange.dump()).ok);

    // recipe_context mismatch rejected
    const Json recipeBad = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "Recipe mismatch"},
        {"is_raw", true},
        {"recipe_context", {{"id", "classic-neg"}, {"strength", 1.0}, {"settings_version", 4}}},
        {"values", {
            {"looks.reference", {{"kind", "recipe"}, {"id", "other"}}},
            {"looks.strength", 1.0},
        }},
    };
    assert(!savePresetFromRequestJson(recipeBad.dump()).ok);
}

void testMacEditSyncCanonicalV2MergeAndMigrations() {
    TempDirGuard guard("rawlab-gui-store-mac");
    const auto dataDir = guard.dir / "data";
    const auto photo = guard.dir / "IMG_0001.ARW";
    const auto sibling = guard.dir / "IMG_0002.JPG";
    writeRaw(photo, "RAWDATA");
    writeRaw(sibling, "JPGDATA");

    GuiStoreOptions opts;
    opts.targetPlatform = GuiStorePlatform::MacOS;
    opts.readIdentity = [&](const std::string& path, GuiStorePlatform) {
        GuiStoreFileIdentity id;
        id.path = path;
        id.size = 7;
        id.macModified = 750000000.25;
        id.macFileNumber = 123456;
        return id;
    };

    const std::string photoPathStr = pathToUtf8(photo);
    const std::string siblingPathStr = pathToUtf8(sibling);

    // Pre-populate edits.json with CanonicalV2 record + unknown Tier-1 key + unformatted sibling slice + processingMigrations
    const std::string siblingSlice = std::string(R"({  "state": { "customSiblingKey" : 42, "filmID":"builtin:velvia", "settings":{"exposure":0.200} }, "identity":{"fileNumber":99,"modified":1,"path":)") + Json(siblingPathStr).dump() + R"(,"size":7} })";
    const Json photoInitialRec = {
        {"identity", {{"fileNumber", 123456}, {"modified", 750000000.25}, {"path", photoPathStr}, {"size", 7}}},
        {"customRecordTag", "preserve-me"},
        {"state", {
            {"filmID", "builtin:astia"},
            {"masterRecipeID", nullptr},
            {"settings", {
                {"settingsVersion", 2},
                {"processing", {{"family", "rawlab"}, {"quality", "standard"}, {"version", 2}}},
                {"exposureMode", "scene"},
                {"whiteBalanceMode", "camera"},
                {"lutID", "builtin:astia"},
                {"lutStrength", 1.0},
                {"denoise", {{"enabled", false}}},
                {"displayChromaDenoise", 0},
                {"contrast", 1.25},
                {"highlights", -0.2},
                {"shadows", 0.3},
                {"saturation", 1.1},
                {"sharpening", 0.4},
                {"toneCurve", 0.15},
                {"unknownSetting", "preserve-setting"},
            }},
        }},
    };
    const std::string initialRaw =
        "{\"version\":1,\"customTier1Flag\":true,\"records\":{" +
        Json(photoPathStr).dump() + ":" + photoInitialRec.dump() + "," +
        Json(siblingPathStr).dump() + ":" + siblingSlice +
        "},\"processingMigrations\":{" +
        Json(photoPathStr).dump() + ":{\"receipt\":\"keep-if-same-ver\"}," +
        Json(siblingPathStr).dump() + ":{\"receipt\":\"sibling-mig\"}}}";
    writeRaw(dataDir / "Edits" / "edits.json", initialRaw);

    // Merge update with same processing_version=2 -> preserves migration, converts CanonicalV2 -> MacLegacyV1
    const Json reqSameVer = {
        {"data_dir", pathToUtf8(dataDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {{"exposure", 0.5}, {"processing_version", 2}}},
    };
    const auto res1 = syncPhotoEditFromRequestJson(reqSameVer.dump(), opts);
    assert(res1.ok);
    const Json r1 = Json::parse(res1.resultJson);
    assert(r1.at("action") == "updated");
    assert(r1.at("filmID") == "builtin:astia");

    const std::string after1Raw = readRaw(dataDir / "Edits" / "edits.json");
    assert(after1Raw.find(siblingSlice) != std::string::npos);
    const Json after1 = Json::parse(after1Raw);
    assert(after1.at("customTier1Flag") == true);
    assert(after1.at("processingMigrations").contains(photoPathStr));
    const Json& st1 = after1.at("records").at(photoPathStr).at("state").at("settings");
    assert(!st1.contains("settingsVersion"));
    assert(!st1.contains("lutID"));
    assert(!st1.contains("lutStrength"));
    assert(!st1.contains("denoise"));
    assert(!st1.contains("displayChromaDenoise"));
    assert(st1.at("exposure") == 0.5);
    assert(st1.at("contrast") == 25.0);
    assert(st1.at("highlights") == 20.0);
    assert(st1.at("shadows") == 30.0);
    assert(st1.at("saturation") == 10.0);
    assert(st1.at("sharpening") == 40.0);
    assert(st1.at("toneCurve") == 15.0);
    assert(st1.at("exposureMode") == "标准显影");
    assert(st1.at("whiteBalanceMode") == "拍摄时设置");
    assert(st1.at("supportsRawNoiseReduction") == true);
    assert(st1.at("unknownSetting") == "preserve-setting");
    assert(after1.at("records").at(photoPathStr).at("customRecordTag") == "preserve-me");

    // Now bump processing_version to 3 -> clears photo's processingMigrations, keeps sibling's
    const Json reqBump = {
        {"data_dir", pathToUtf8(dataDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {{"processing_version", 3}}},
    };
    const auto res2 = syncPhotoEditFromRequestJson(reqBump.dump(), opts);
    assert(res2.ok);
    const Json after2 = Json::parse(readRaw(dataDir / "Edits" / "edits.json"));
    assert(!after2.at("processingMigrations").contains(photoPathStr));
    assert(after2.at("processingMigrations").contains(siblingPathStr));
}

void testWindowsEditSyncSchemaMergeAndOrdinalIgnoreCase() {
    TempDirGuard guard("rawlab-gui-store-win");
    const auto dataDir = guard.dir / "data";
    const std::string winPhoto = "C:\\Photos\\IMG_0010.ARW";
    const std::string winPhotoLower = "c:\\photos\\img_0010.arw";
    const std::string winSibling = "C:\\Photos\\Sibling.JPG";

    GuiStoreOptions opts;
    opts.targetPlatform = GuiStorePlatform::Windows;
    opts.readIdentity = [&](const std::string& p, GuiStorePlatform) {
        GuiStoreFileIdentity id;
        id.path = p;
        id.size = 4096;
        id.winModifiedTicks = 638500000000000000LL;
        id.winCreatedTicks = 638400000000000000LL;
        id.winFileId = "abcd1234-00000001-00000002";
        return id;
    };

    // Sibling slice + existing old-case record + MigrationReceipts + unknown Tier-1 key
    const std::string siblingSlice = R"({"Identity":{"Created":1,"FileID":"1-2-3","Length":10,"Modified":2,"Path":"C:\\Photos\\Sibling.JPG"},"Look":null,"Settings":{"SettingsVersion":2,"Values":[1,0,6500,0,1,0,0,0,1,0]}})";
    const std::string initialEdits =
        "{\"Version\":1,\"CustomRoot\":\"keep\",\"Records\":{\"" +
        std::string("c:\\\\photos\\\\img_0010.arw") +
        "\":{\"Identity\":{\"Path\":\"c:\\\\photos\\\\img_0010.arw\",\"Length\":4096,\"Modified\":638500000000000000,\"Created\":638400000000000000},\"Settings\":{\"SettingsVersion\":1,\"Values\":[100,0.25,6500,0,20,-30,40,10,15,50],\"ExposureMode\":1,\"CameraWhiteBalance\":true,\"Processing\":{\"family\":\"rawlab\",\"version\":1,\"quality\":\"standard\"},\"CustomSetting\":\"keep-setting\"},\"Look\":\"builtin:provia\"},\"C:\\\\Photos\\\\Sibling.JPG\":" +
        siblingSlice +
        "},\"MigrationReceipts\":{\"" +
        std::string("c:\\\\photos\\\\img_0010.arw") +
        "\":{\"Status\":\"migrated\"}}}";
    writeRaw(dataDir / "Edits" / "edits.json", initialEdits);

    const Json winReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"photo_path", winPhoto},
        {"is_raster", false},
        {"adjustments", {
            {"processing_version", 3},
            {"exposure", 0.75},
            {"exposure_mode", "scene"},
            {"black_point", -12.0},
            {"clarity", 20.0},
            {"tone_curve", {
                {"mode", "custom"},
                {"points", Json::array({{0.0, 0.0}, {0.5, 0.6}, {1.0, 1.0}})},
                {"apply_to_luminosity", true},
            }},
            {"color_grading", {
                {"shadows", {{"hue", 210.0}, {"saturation", 15.0}, {"luminance", 0.0}}},
                {"midtones", {{"hue", 0.0}, {"saturation", 0.0}}},
                {"highlights", {{"hue", 35.0}, {"saturation", 10.0}, {"luminance", 4.0}}},
                {"blending", 70.0},
            }},
            {"hsl", {
                {"hue", {1, 0, 0, 0, 0, 0, 0, 0}},
                {"saturation", {0, 2, 0, 0, 0, 0, 0, 0}},
                {"lightness", {0, 0, -3, 0, 0, 0, 0, 0}},
            }},
            {"wavelet", {{"enabled", true}, {"luma", 12.0}, {"chroma", 50.0}, {"coarse", 40.0}, {"preset", "custom"}}},
        }},
    };
    const auto res = syncPhotoEditFromRequestJson(winReq.dump(), opts);
    assert(res.ok);
    const Json r = Json::parse(res.resultJson);
    assert(r.at("action") == "updated");
    assert(r.at("filmID") == "builtin:provia");

    const std::string outRaw = readRaw(dataDir / "Edits" / "edits.json");
    assert(outRaw.find(siblingSlice) != std::string::npos);
    const Json root = Json::parse(outRaw);
    assert(root.at("Version") == 1);
    assert(root.at("CustomRoot") == "keep");
    assert(!root.contains("MigrationReceipts"));
    assert(root.at("Records").size() == 2); // OrdinalIgnoreCase merged, no duplicate!
    assert(root.at("Records").contains(winSibling));

    const Json& rec = root.at("Records").at(winPhotoLower);
    assert(rec.at("Identity").at("FileID") == "abcd1234-00000001-00000002");
    assert(rec.at("Identity").at("Modified") == 638500000000000000LL);
    assert(rec.at("Look") == "builtin:provia");

    const Json& st = rec.at("Settings");
    assert(st.at("SettingsVersion") == 2);
    assert(st.at("ExposureMode") == 0);
    assert(st.at("CameraWhiteBalance") == true);
    assert(st.at("Processing").at("version") == 3);
    assert(st.at("CustomSetting") == "keep-setting");
    // Values[10] upgraded from SettingsVersion 1 & merged:
    assert(std::abs(st.at("Values")[0].get<double>() - 1.0) < 1e-6);  // Strength 100 -> 1.0
    assert(std::abs(st.at("Values")[1].get<double>() - 0.75) < 1e-6); // Exposure updated
    assert(std::abs(st.at("Values")[4].get<double>() - 1.2) < 1e-6);  // Contrast 20 -> 1.2
    assert(std::abs(st.at("Values")[5].get<double>() - 0.3) < 1e-6);  // Highlights -30 -> +0.3
    assert(std::abs(st.at("Values")[6].get<double>() - 0.4) < 1e-6);  // Shadows 40 -> 0.4
    assert(std::abs(st.at("Values")[7].get<double>() - 0.0) < 1e-6);  // ToneCurve zeroed by custom Curve
    assert(std::abs(st.at("Values")[8].get<double>() - 1.15) < 1e-6); // Saturation 15 -> 1.15
    assert(std::abs(st.at("Values")[9].get<double>() - 0.5) < 1e-6);  // Sharpening 50 -> 0.5

    assert(st.at("ToneControls").at("BlackPoint") == -12.0);
    assert(st.at("Atmosphere").at("Clarity") == 20.0);
    assert(st.at("Curve").at("mode") == "custom");
    assert(st.at("Curve").at("apply_to_luminosity") == true);
    assert(st.at("ColorGrading").at("Shadows").at("Hue") == 210.0);
    assert(!st.at("ColorGrading").at("Shadows").contains("Luminance")); // 0 omitted
    assert(st.at("ColorGrading").at("Highlights").at("Luminance") == 4.0);
    assert(st.at("ColorGrading").at("Blending") == 70.0);
    assert(st.at("Hsl").at("Values").size() == 24);
    assert(st.at("Hsl").at("Values")[0] == 1.0);
    assert(st.at("Hsl").at("Values")[9] == 2.0);
    assert(st.at("Hsl").at("Values")[18] == -3.0);
    assert(st.at("Denoise").at("Enabled") == true);
    assert(st.at("Denoise").at("Luma") == 12.0);
    (void)winPhoto;
}

void testSymlinkRejections() {
#if !defined(_WIN32)
    TempDirGuard guard("rawlab-gui-store-symlink");
    const auto dataDir = guard.dir / "data";
    const auto outside = guard.dir / "outside";
    std::filesystem::create_directories(dataDir / "Presets");
    std::filesystem::create_directories(outside);
    writeRaw(outside / "evil.json", "{}");

    // 1. Symlink presets.json rejected
    std::filesystem::create_symlink(outside / "evil.json", dataDir / "Presets" / "presets.json");
    const Json req = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "SafeName"},
        {"values", {{"light.exposure", 0.5}}},
    };
    const auto r1 = savePresetFromRequestJson(req.dump());
    assert(!r1.ok);
    assert(r1.status == GuiStoreStatus::InvalidArgument);

    // 2. Symlink lock file rejected
    std::filesystem::remove(dataDir / "Presets" / "presets.json");
    std::filesystem::create_symlink(outside / "evil.json", dataDir / "Presets" / ".presets.lock");
    const auto r2 = savePresetFromRequestJson(req.dump());
    assert(!r2.ok);
    assert(r2.status == GuiStoreStatus::InvalidArgument);
#endif
}

void testMacPartialMergeAndZeroResets() {
    TempDirGuard guard("rawlab-gui-store-mac-partial");
    const auto dataDir = guard.dir / "data";
    const auto photo = guard.dir / "IMG_0003.ARW";
    writeRaw(photo, "RAWDATA");

    GuiStoreOptions opts;
    opts.targetPlatform = GuiStorePlatform::MacOS;
    opts.readIdentity = [&](const std::string& path, GuiStorePlatform) {
        GuiStoreFileIdentity id;
        id.path = path;
        id.size = 7;
        id.macModified = 750000000.25;
        id.macFileNumber = 654321;
        return id;
    };

    const std::string photoPathStr = pathToUtf8(photo);
    const Json initialRec = {
        {"identity", {{"fileNumber", 654321}, {"modified", 750000000.25}, {"path", photoPathStr}, {"size", 7}}},
        {"state", {
            {"filmID", ""},
            {"masterRecipeID", nullptr},
            {"settings", {
                {"processing", {{"family", "rawlab"}, {"quality", "standard"}, {"version", 3}}},
                {"exposureMode", "标准显影"},
                {"whiteBalanceMode", "拍摄时设置"},
                {"chromaNoiseReduction", 2.0},
                {"toneControls", {{"blackPoint", -10.0}, {"whitePoint", 15.0}, {"vibrance", 20.0}}},
                {"atmosphere", {{"clarity", 30.0}, {"dehaze", -10.0}}},
            }},
        }},
    };
    const std::string initialRaw =
        "{\"version\":1,\"records\":{" + Json(photoPathStr).dump() + ":" + initialRec.dump() + "}}";
    writeRaw(dataDir / "Edits" / "edits.json", initialRaw);

    // 1. Single-subfield partial merge preserves untouched subfields & chromaNoiseReduction
    const Json partialReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {{"black_point", -5.0}, {"clarity", 12.0}}},
    };
    const auto res1 = syncPhotoEditFromRequestJson(partialReq.dump(), opts);
    assert(res1.ok);
    const Json st1 = Json::parse(readRaw(dataDir / "Edits" / "edits.json"))
        .at("records").at(photoPathStr).at("state").at("settings");
    assert(st1.at("chromaNoiseReduction") == 2.0);
    assert(st1.at("toneControls").at("blackPoint") == -5.0);
    assert(st1.at("toneControls").at("whitePoint") == 15.0);
    assert(st1.at("toneControls").at("vibrance") == 20.0);
    assert(st1.at("atmosphere").at("clarity") == 12.0);
    assert(st1.at("atmosphere").at("dehaze") == -10.0);

    // 2. Explicit zero resets erase chromaNoiseReduction and zero targeted subfields only
    const Json zeroPartialReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {{"chroma_noise_reduction", 0}, {"black_point", 0.0}, {"clarity", 0.0}}},
    };
    const auto res2 = syncPhotoEditFromRequestJson(zeroPartialReq.dump(), opts);
    assert(res2.ok);
    const Json st2 = Json::parse(readRaw(dataDir / "Edits" / "edits.json"))
        .at("records").at(photoPathStr).at("state").at("settings");
    assert(!st2.contains("chromaNoiseReduction"));
    assert(st2.at("toneControls").at("blackPoint") == 0.0);
    assert(st2.at("toneControls").at("whitePoint") == 15.0);
    assert(st2.at("toneControls").at("vibrance") == 20.0);
    assert(st2.at("atmosphere").at("clarity") == 0.0);
    assert(st2.at("atmosphere").at("dehaze") == -10.0);

    // 3. Zeroing remaining subfields erases toneControls and atmosphere objects entirely
    const Json zeroAllReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {{"white_point", 0.0}, {"vibrance", 0.0}, {"dehaze", 0.0}}},
    };
    const auto res3 = syncPhotoEditFromRequestJson(zeroAllReq.dump(), opts);
    assert(res3.ok);
    const Json st3 = Json::parse(readRaw(dataDir / "Edits" / "edits.json"))
        .at("records").at(photoPathStr).at("state").at("settings");
    assert(!st3.contains("toneControls"));
    assert(!st3.contains("atmosphere"));
}

void testOverflowVersionAndNormalizedUnreadablePresetCollision() {
    TempDirGuard guard("rawlab-gui-store-overflow");
    const auto dataDir = guard.dir / "data";
    const auto photo = guard.dir / "IMG_0004.ARW";
    writeRaw(photo, "RAWDATA");

    // 1. Overflowing registry_version returns OutputIoError (6), not InvalidArgument (2)
    writeRaw(dataDir / "Presets" / "presets.json",
        R"({"registry_version":999999999999999999999999999,"presets":[]})");
    const Json presetReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "ValidName"},
        {"values", {{"light.exposure", 0.2}}},
    };
    const auto pr = savePresetFromRequestJson(presetReq.dump());
    assert(!pr.ok);
    assert(pr.status == GuiStoreStatus::OutputIoError);

    // 2. Overflowing Mac & Windows edits.json version returns OutputIoError (6)
    GuiStoreOptions macOpts;
    macOpts.targetPlatform = GuiStorePlatform::MacOS;
    macOpts.readIdentity = [&](const std::string& path, GuiStorePlatform) {
        GuiStoreFileIdentity id;
        id.path = path;
        id.size = 7;
        return id;
    };
    writeRaw(dataDir / "Edits" / "edits.json",
        R"({"version":999999999999999999999999999,"records":{}})");
    const Json editReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"photo_path", pathToUtf8(photo)},
        {"is_raster", false},
        {"adjustments", {{"exposure", 0.2}}},
    };
    const auto mr = syncPhotoEditFromRequestJson(editReq.dump(), macOpts);
    assert(!mr.ok);
    assert(mr.status == GuiStoreStatus::OutputIoError);

    GuiStoreOptions winOpts;
    winOpts.targetPlatform = GuiStorePlatform::Windows;
    winOpts.readIdentity = macOpts.readIdentity;
    writeRaw(dataDir / "Edits" / "edits.json",
        R"({"Version":999999999999999999999999999,"Records":{}})");
    const auto wr = syncPhotoEditFromRequestJson(editReq.dump(), winOpts);
    assert(!wr.ok);
    assert(wr.status == GuiStoreStatus::OutputIoError);

    // 3. Unreadable preset name collision normalizes NFD/NFC & whitespace
    writeRaw(dataDir / "Presets" / "presets.json",
        "{\"registry_version\":1,\"presets\":[{\"name\":\"Cafe\\u0301\",\"future\":true},{\"name\":\"  SpacedName  \",\"future\":true}]}");
    const Json nfcReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "Caf\xC3\xA9"},
        {"values", {{"light.exposure", 0.2}}},
    };
    const auto nr = savePresetFromRequestJson(nfcReq.dump());
    assert(!nr.ok);
    assert(nr.status == GuiStoreStatus::InvalidArgument);

    const Json spaceReq = {
        {"data_dir", pathToUtf8(dataDir)},
        {"name", "SpacedName"},
        {"values", {{"light.exposure", 0.2}}},
    };
    const auto sr = savePresetFromRequestJson(spaceReq.dump());
    assert(!sr.ok);
    assert(sr.status == GuiStoreStatus::InvalidArgument);
}

void testV014MacAndWindowsRoundTripExplicitResetsAndOrthogonalPreservation() {
    TempDirGuard guard("rawlab-gui-store-v014");
    const auto macDir = guard.dir / "mac-data";
    const auto winDir = guard.dir / "win-data";
    const auto photo = guard.dir / "IMG_V014.ARW";
    writeRaw(photo, "RAWDATA");
    const std::string photoPathStr = pathToUtf8(photo);

    const Json selBands = {
        {"reds", {{"cyan", -15.0}, {"magenta", 8.0}, {"yellow", 6.0}, {"black", -2.0}}},
        {"yellows", {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}}},
        {"greens", {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}}},
        {"cyans", {{"cyan", 12.0}, {"magenta", -4.0}, {"yellow", -8.0}, {"black", 2.0}}},
        {"blues", {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}}},
        {"magentas", {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}}},
        {"whites", {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}}},
        {"neutrals", {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}}},
        {"blacks", {{"cyan", 0.0}, {"magenta", 0.0}, {"yellow", 0.0}, {"black", 0.0}}},
    };
    const Json bwMixer = {
        {"red", 25.5}, {"orange", 18.25}, {"yellow", 12.0}, {"green", -15.5},
        {"aqua", -28.0}, {"blue", -35.25}, {"purple", 10.5}, {"magenta", 6.25},
    };
    const Json swatches = Json::array({
        {
            {"src_hue", 20.5}, {"src_saturation", 0.3}, {"src_luminance", 0.72},
            {"hue_shift", 2.0}, {"saturation_shift", -8.0}, {"luminance_shift", 1.5},
            {"variance", -35.0}, {"range", 50.0}, {"hue_range", 45.0},
            {"sat_range", 50.0}, {"lum_range", 50.0}, {"enabled", true},
        },
    });
    const Json allV014Adj = {
        {"processing_version", 3},
        {"clarity", 15.0},
        {"texture", 32.5},
        {"ai_denoise_enabled", true},
        {"ai_denoise_blend", 65.0},
        {"calibration", {
            {"shadow_tint", -12.0}, {"red_hue", 8.5}, {"red_saturation", 14.0},
            {"green_hue", -6.0}, {"green_saturation", 5.5}, {"blue_hue", -10.5}, {"blue_saturation", 18.0},
        }},
        {"point_color", {{"swatches", swatches}}},
        {"selective_color", {{"method", "absolute"}, {"bands", selBands}}},
        {"bw", {{"enabled", true}, {"mixer", bwMixer}}},
        {"sharpen_v2", {{"luminance_v2", true}, {"radius", 1.4}, {"detail", 42.5}, {"masking", 62.0}}},
        {"film_optics", {
            {"halation_amount", 28.5}, {"halation_threshold", 82.0}, {"halation_radius", 45.5}, {"halation_hue", -14.0},
            {"bloom_amount", 22.25}, {"bloom_threshold", 68.0}, {"bloom_radius", 52.5},
        }},
        {"photo_effects", {{"grain_tone_curve", "negative_asymmetric"}, {"grain_format_preset", "135"}}},
        {"lens_correction", {
            {"defringe_purple_amount", 6.5}, {"defringe_purple_hue", 35.0},
            {"defringe_green_amount", 4.25}, {"defringe_green_hue", 65.0},
        }},
    };

    // 1. Validate unknown-key rejection inside v0.14.0 adjustment sub-objects
    GuiStoreOptions macOpts;
    macOpts.targetPlatform = GuiStorePlatform::MacOS;
    macOpts.readIdentity = [&](const std::string& p, GuiStorePlatform) {
        GuiStoreFileIdentity id;
        id.path = p;
        id.size = 7;
        id.macModified = 750000000.25;
        id.macFileNumber = 777;
        return id;
    };
    const Json badSwatchKeyReq = {
        {"data_dir", pathToUtf8(macDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {{"point_color", {{"swatches", Json::array({{{"src_hue", 20.0}, {"src_saturation", 0.3}, {"src_luminance", 0.7}, {"typo", 1}}})}}}}},
    };
    const auto badSwatchRes = syncPhotoEditFromRequestJson(badSwatchKeyReq.dump(), macOpts);
    assert(!badSwatchRes.ok && badSwatchRes.status == GuiStoreStatus::InvalidArgument);

    // 2. Mac create -> orthogonal + future + sibling injection -> partial texture reset -> null/default erasures
    const Json macCreateReq = {
        {"data_dir", pathToUtf8(macDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"film_id", "builtin:astia"},
        {"adjustments", allV014Adj},
    };
    const auto m1 = syncPhotoEditFromRequestJson(macCreateReq.dump(), macOpts);
    assert(m1.ok);

    const std::string macSiblingSlice = R"({"identity":{"fileNumber":888,"modified":1,"path":"/Sibling.ARW","size":5},"state":{"filmID":"","settings":{"exposure":0.1}}})";
    Json macDoc = Json::parse(readRaw(macDir / "Edits" / "edits.json"));
    Json& mSt = macDoc.at("records").at(photoPathStr).at("state").at("settings");
    assert(mSt.at("atmosphere").at("clarity") == 15.0);
    assert(mSt.at("atmosphere").at("texture") == 32.5);
    assert(mSt.at("cameraCalibration").at("shadowTint") == -12.0);
    assert(mSt.at("pointColor").at("swatches").size() == 1);
    assert(mSt.at("selectiveColor").at("method") == "absolute");
    assert(mSt.at("bwMixer").at("enabled") == true);
    assert(mSt.at("sharpenV2").at("masking") == 62.0);
    assert(mSt.at("filmOptics").at("halationAmount") == 28.5);
    assert(mSt.at("photoEffects").at("grainToneCurve") == "negative_asymmetric");
    assert(mSt.at("photoEffects").at("grainFormatPreset") == "135");
    assert(mSt.at("lensCorrection").at("defringePurpleAmount") == 6.5);
    assert(mSt.at("aiDenoiseEnabled") == true);
    assert(mSt.at("aiDenoiseBlend") == 65.0);

    // Inject orthogonal fields & future unknown keys (non-settingsVersion-2 modern record preserves lutID too)
    mSt["hdr"] = {{"mode", "hdr"}, {"peakLimit", 3.0}};
    mSt["hdrCameraAI"] = false;
    mSt["proRAWDecodeVersion"] = 2;
    mSt["aiDenoiseStrength"] = 70.0;
    mSt["lutID"] = "builtin:astia";
    mSt["futureExtension"] = {{"k", "keep"}};
    const std::string macSeeded = "{\"version\":1,\"records\":{" + Json(photoPathStr).dump() + ":" +
        macDoc.at("records").at(photoPathStr).dump() + ",\"/Sibling.ARW\":" + macSiblingSlice + "}}";
    writeRaw(macDir / "Edits" / "edits.json", macSeeded);

    // Partial update modifies texture while keeping clarity=15, then resets texture & v0.14.0 blocks via null/defaults
    const Json macTextureOnly = {
        {"data_dir", pathToUtf8(macDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {{"texture", -20.0}}},
    };
    assert(syncPhotoEditFromRequestJson(macTextureOnly.dump(), macOpts).ok);
    const Json mStMid = Json::parse(readRaw(macDir / "Edits" / "edits.json")).at("records").at(photoPathStr).at("state").at("settings");
    assert(mStMid.at("atmosphere").at("clarity") == 15.0);
    assert(mStMid.at("atmosphere").at("texture") == -20.0);

    const Json macResetReq = {
        {"data_dir", pathToUtf8(macDir)},
        {"photo_path", photoPathStr},
        {"is_raster", false},
        {"adjustments", {
            {"texture", 0.0},
            {"calibration", {{"shadow_tint", 0.0}}},
            {"point_color", {{"swatches", Json::array()}}},
            {"selective_color", nullptr},
            {"bw", {{"enabled", false}}},
            {"sharpen_v2", nullptr},
            {"film_optics", {{"halation_amount", 0.0}}},
            {"photo_effects", {{"vignette_amount", 0.0}}},
            {"lens_correction", nullptr},
        }},
    };
    assert(syncPhotoEditFromRequestJson(macResetReq.dump(), macOpts).ok);
    const std::string macFinalRaw = readRaw(macDir / "Edits" / "edits.json");
    assert(macFinalRaw.find(macSiblingSlice) != std::string::npos);
    const Json mStEnd = Json::parse(macFinalRaw).at("records").at(photoPathStr).at("state").at("settings");
    assert(mStEnd.at("atmosphere").at("clarity") == 15.0);
    assert(!mStEnd.at("atmosphere").contains("texture"));
    for (const char* erased : {"cameraCalibration", "pointColor", "selectiveColor", "bwMixer", "sharpenV2", "filmOptics", "photoEffects", "lensCorrection"}) {
        assert(!mStEnd.contains(erased));
    }
    assert(mStEnd.at("hdr").at("peakLimit") == 3.0);
    assert(mStEnd.at("aiDenoiseEnabled") == true);
    assert(mStEnd.at("aiDenoiseBlend") == 65.0);
    assert(mStEnd.at("aiDenoiseStrength") == 70.0);
    assert(mStEnd.at("lutID") == "builtin:astia");
    assert(mStEnd.at("proRAWDecodeVersion") == 2);
    assert(mStEnd.at("futureExtension").at("k") == "keep");

    // 3. Windows NEW record creation includes GrainToneCurve, GrainFormatPreset, Defringe*, and resets erase cleanly
    GuiStoreOptions winOpts;
    winOpts.targetPlatform = GuiStorePlatform::Windows;
    winOpts.readIdentity = [&](const std::string& p, GuiStorePlatform) {
        GuiStoreFileIdentity id;
        id.path = p;
        id.size = 7;
        id.winModifiedTicks = 638500000000000000LL;
        id.winCreatedTicks = 638400000000000000LL;
        id.winFileId = "v014-win-id";
        return id;
    };
    const std::string winPhoto = "C:\\Photos\\V014_Portrait.ARW";
    const Json winCreateReq = {
        {"data_dir", pathToUtf8(winDir)},
        {"photo_path", winPhoto},
        {"is_raster", false},
        {"film_id", "builtin:classic_chrome"},
        {"adjustments", allV014Adj},
    };
    const auto w1 = syncPhotoEditFromRequestJson(winCreateReq.dump(), winOpts);
    assert(w1.ok);

    Json winDoc = Json::parse(readRaw(winDir / "Edits" / "edits.json"));
    Json& wSt = winDoc.at("Records").at(winPhoto).at("Settings");
    assert(wSt.at("Atmosphere").at("Texture") == 32.5);
    assert(wSt.at("Effects").at("GrainToneCurve") == "negative_asymmetric");
    assert(wSt.at("Effects").at("GrainFormatPreset") == "135");
    assert(wSt.at("Lens").at("DefringePurpleAmount") == 6.5);
    assert(wSt.at("Lens").at("DefringePurpleHue") == 35.0);
    assert(wSt.at("Lens").at("DefringeGreenAmount") == 4.25);
    assert(wSt.at("Lens").at("DefringeGreenHue") == 65.0);
    assert(wSt.at("CameraCalibration").at("shadowTint") == -12.0);
    assert(wSt.at("PointColor").at("swatches").size() == 1);
    assert(wSt.at("SelectiveColor").at("method") == "absolute");
    assert(wSt.at("BwMixer").at("enabled") == true);
    assert(wSt.at("SharpenV2").at("luminanceV2") == true);
    assert(wSt.at("FilmOptics").at("bloomAmount") == 22.25);

    wSt["HDR"] = {{"Mode", "hdr"}, {"PeakLimit", 2.5}};
    wSt["ProRAWDecodeVersion"] = 2;
    wSt["aiDenoiseStrength"] = 70.0;
    wSt["lutID"] = "builtin:classic_chrome";
    wSt["FutureWin"] = 99;
    writeRaw(winDir / "Edits" / "edits.json", winDoc.dump());

    const Json winResetReq = {
        {"data_dir", pathToUtf8(winDir)},
        {"photo_path", winPhoto},
        {"is_raster", false},
        {"adjustments", {
            {"clarity", 0.0},
            {"texture", nullptr},
            {"calibration", nullptr},
            {"point_color", nullptr},
            {"selective_color", {{"method", "relative"}}},
            {"bw", nullptr},
            {"sharpen_v2", nullptr},
            {"film_optics", nullptr},
            {"photo_effects", nullptr},
            {"lens_correction", nullptr},
            {"ai_denoise_blend", 100.0},
        }},
    };
    assert(syncPhotoEditFromRequestJson(winResetReq.dump(), winOpts).ok);
    const Json wStEnd = Json::parse(readRaw(winDir / "Edits" / "edits.json")).at("Records").at(winPhoto).at("Settings");
    for (const char* erased : {"Atmosphere", "CameraCalibration", "PointColor", "SelectiveColor", "BwMixer", "SharpenV2", "FilmOptics", "AIDenoiseBlend"}) {
        assert(!wStEnd.contains(erased));
    }
    assert(!wStEnd.at("Effects").contains("GrainToneCurve"));
    assert(!wStEnd.at("Effects").contains("GrainFormatPreset"));
    assert(!wStEnd.at("Lens").contains("DefringePurpleAmount"));
    assert(wStEnd.at("HDR").at("PeakLimit") == 2.5);
    assert(wStEnd.at("AIDenoiseEnabled") == true);
    assert(wStEnd.at("aiDenoiseStrength") == 70.0);
    assert(wStEnd.at("lutID") == "builtin:classic_chrome");
    assert(wStEnd.at("ProRAWDecodeVersion") == 2);
    assert(wStEnd.at("FutureWin") == 99);
}

} // namespace

int main() {
    testPresetLifecycleAndUnreadablePreservation();
    testHdrVersionsAndValidation();
    testMacEditSyncCanonicalV2MergeAndMigrations();
    testWindowsEditSyncSchemaMergeAndOrdinalIgnoreCase();
    testSymlinkRejections();
    testMacPartialMergeAndZeroResets();
    testOverflowVersionAndNormalizedUnreadablePresetCollision();
    testV014MacAndWindowsRoundTripExplicitResetsAndOrthogonalPreservation();
    std::cout << "gui_store_tests passed\n";
    return 0;
}
