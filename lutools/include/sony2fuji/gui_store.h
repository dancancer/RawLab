#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>

namespace sony2fuji {
namespace gui_store {

enum class GuiStorePlatform {
    MacOS,
    Windows,
};

enum class GuiStoreStatus {
    Ok = 0,
    InvalidArgument = 2,
    IoError = 3,
    Unsupported = 4,
    OutOfMemory = 5,
    OutputIoError = 6,
    Cancelled = 7,
    AiNotReady = 8,
};

struct GuiStoreFileIdentity {
    std::string path;
    uint64_t size = 0;
    // MacOS: CFAbsoluteTime (seconds since 2001-01-01T00:00:00Z)
    double macModified = 0.0;
    uint64_t macFileNumber = 0;
    // Windows: .NET Ticks (100ns intervals since 0001-01-01T00:00:00Z)
    int64_t winModifiedTicks = 0;
    int64_t winCreatedTicks = 0;
    std::string winFileId;
};

struct GuiStoreOptions {
    std::optional<GuiStorePlatform> targetPlatform;
    std::function<int64_t()> clockMillis;
    std::function<std::string()> generateUuid;
    std::function<GuiStoreFileIdentity(const std::string&, GuiStorePlatform)> readIdentity;
};

struct GuiStoreResult {
    bool ok = false;
    GuiStoreStatus status = GuiStoreStatus::Ok;
    std::string code;
    std::string message;
    std::string resultJson;
};

std::optional<GuiStorePlatform> currentHostPlatform();

GuiStoreResult savePresetFromRequestJson(
    const std::string& requestJson,
    const GuiStoreOptions& options = {});

GuiStoreResult syncPhotoEditFromRequestJson(
    const std::string& requestJson,
    const GuiStoreOptions& options = {});

} // namespace gui_store
} // namespace sony2fuji
