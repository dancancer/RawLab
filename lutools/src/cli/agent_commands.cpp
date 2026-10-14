#include "agent_commands.h"
#include "raw_info.h"
#include "sony2fuji/edit_recipe.h"
#include "nlohmann/json.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace sony2fuji {
namespace {
using Json = nlohmann::json;

const char* statusCode(sony2fuji_status status) {
    switch (status) {
        case SONY2FUJI_STATUS_OK: return "ok";
        case SONY2FUJI_STATUS_INVALID_ARGUMENT: return "invalid_argument";
        case SONY2FUJI_STATUS_UNSUPPORTED: return "unsupported";
        case SONY2FUJI_STATUS_IO_ERROR: return "io_error";
        case SONY2FUJI_STATUS_PROCESSING_ERROR: return "processing_error";
        case SONY2FUJI_STATUS_OUT_OF_MEMORY: return "out_of_memory";
        case SONY2FUJI_STATUS_OUTPUT_IO_ERROR: return "output_io_error";
    }
    return "processing_error";
}

const char* formatName(sony2fuji_output_format format) {
    return format == SONY2FUJI_OUTPUT_PNG ? "png" : format == SONY2FUJI_OUTPUT_DNG ? "dng" : "jpeg";
}

Json envelope(const std::string& command, const Json& result, const Json& error = nullptr) {
    return {{"protocol_version", 1}, {"command", command}, {"ok", error.is_null()},
            {"result", result}, {"error", error}};
}

std::string machineJson(const Json& value) {
    // Invalid bytes in an argv/OS diagnostic still produce a valid JSON error.
    return value.dump(-1, ' ', false, Json::error_handler_t::replace);
}

// Core diagnostics must not contaminate the machine-readable stdout document.
class DiagnosticsToStderr {
public:
    DiagnosticsToStderr() : previous_(std::cout.rdbuf(std::cerr.rdbuf())) {}
    ~DiagnosticsToStderr() { std::cout.rdbuf(previous_); }
private:
    std::streambuf* previous_;
};

} // namespace

int runAgentCommands(int argc, char* argv[]) {
    bool jsonOutput = false, capabilities = false, printRecipe = false, info = false;
    std::string recipeFile, infoFile;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        jsonOutput |= arg == "--json";
        capabilities |= arg == "--capabilities";
        printRecipe |= arg == "--print-recipe";
        info |= arg == "--info";
    }
    const std::string command = capabilities ? "capabilities" : info ? "info" : printRecipe ? "validate_recipe" : "export";
    auto fail = [&](const std::string& code, const std::string& message, const Json& status = nullptr) {
        if (jsonOutput || capabilities || info)
            std::cout << machineJson(envelope(command, nullptr, {{"code", code}, {"message", message}, {"status", status}})) << '\n';
        else std::cerr << message << '\n';
        return 1;
    };
    try {
        bool seenJson = false, seenCapabilities = false, seenPrint = false;
        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--json" && !seenJson) seenJson = true;
            else if (arg == "--capabilities" && !seenCapabilities) seenCapabilities = true;
            else if (arg == "--print-recipe" && !seenPrint) seenPrint = true;
            else if (arg == "--recipe" && recipeFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                recipeFile = argv[++i];
            else if (arg == "--info" && infoFile.empty() && i + 1 < argc && argv[i + 1][0] != '-')
                infoFile = argv[++i];
            else return fail("invalid_argument", "Unexpected, duplicate or incomplete argument: " + arg);
        }
        if (capabilities) {
            if (!recipeFile.empty() || printRecipe || info) return fail("invalid_argument", "Capabilities cannot be combined with another command");
            std::cout << machineJson(envelope(command, {{"recipe_versions", {1}},
                {"commands", {"capabilities", "validate_recipe", "info", "export"}}, {"input_types", {"raw"}},
                {"output_formats", {"jpeg", "png", "dng"}}, {"exposure_modes", {"scene", "preview", "sensor"}}})) << '\n';
            return 0;
        }
        if (info) {
            if (infoFile.empty() || !recipeFile.empty() || printRecipe)
                return fail("invalid_argument", "--info <RAW> requires one input and no recipe");
            const auto absolute = std::filesystem::absolute(std::filesystem::u8path(infoFile)).lexically_normal().u8string();
            RawInfoResult inspected;
            {
                DiagnosticsToStderr diagnostics;
                inspected = inspectRawInfo(absolute);
            }
            if (inspected.status != SONY2FUJI_STATUS_OK)
                return fail(statusCode(inspected.status), inspected.message, inspected.status);
            std::cout << machineJson(envelope(command, inspected.result)) << '\n';
            return 0;
        }
        if (recipeFile.empty()) return fail("invalid_argument", "--recipe <file> is required");
        const auto path = std::filesystem::u8path(recipeFile);
        std::ifstream file(path, std::ios::binary);
        if (!file) return fail("io_error", "Cannot read recipe: " + recipeFile, SONY2FUJI_STATUS_IO_ERROR);
        std::string document(1024 * 1024 + 1, '\0');
        file.read(document.data(), static_cast<std::streamsize>(document.size()));
        document.resize(static_cast<size_t>(file.gcount()));
        if (file.bad()) return fail("io_error", "Cannot read recipe: " + recipeFile, SONY2FUJI_STATUS_IO_ERROR);
        EditRecipe recipe;
        std::string error;
        if (!parseEditRecipe(document, recipe, error)) return fail("invalid_recipe", error);
        if (printRecipe) {
            const auto normalized = serializeEditRecipe(recipe);
            std::cout << (jsonOutput ? machineJson(envelope(command, Json::parse(normalized))) + "\n" : normalized);
            return 0;
        }
        const auto directory = std::filesystem::absolute(path).parent_path();
        auto resolve = [&](std::string& value) {
            if (!value.empty()) value = (directory / std::filesystem::u8path(value)).lexically_normal().u8string();
        };
        resolve(recipe.inputPath);
        resolve(recipe.outputPath);
        resolve(recipe.lookPath);
        sony2fuji_status status;
        {
            DiagnosticsToStderr diagnostics;
            sony2fuji_session* pointer = nullptr;
            status = sony2fuji_session_create(&pointer);
            auto destroy = [](sony2fuji_session* session) { sony2fuji_session_destroy(session); };
            const std::unique_ptr<sony2fuji_session, decltype(destroy)> session(pointer, destroy);
            if (status == SONY2FUJI_STATUS_OK)
                status = sony2fuji_session_set_raw_exposure_mode(session.get(), recipe.exposureMode);
            const auto request = recipe.toRequest();
            if (status == SONY2FUJI_STATUS_OK) status = sony2fuji_process(session.get(), &request, nullptr);
        }
        if (status != SONY2FUJI_STATUS_OK) return fail(statusCode(status), sony2fuji_status_message(status), status);
        if (jsonOutput) std::cout << machineJson(envelope(command, {{"output_path", recipe.outputPath},
            {"format", formatName(recipe.outputFormat)}})) << '\n';
        else std::cout << "Saved: " << recipe.outputPath << '\n';
        return 0;
    } catch (const std::bad_alloc&) {
        return fail("out_of_memory", "Out of memory", SONY2FUJI_STATUS_OUT_OF_MEMORY);
    } catch (const std::filesystem::filesystem_error& exception) {
        return fail("io_error", exception.what(), SONY2FUJI_STATUS_IO_ERROR);
    } catch (const std::exception& exception) {
        return fail("processing_error", exception.what(), SONY2FUJI_STATUS_PROCESSING_ERROR);
    }
}
} // namespace sony2fuji
