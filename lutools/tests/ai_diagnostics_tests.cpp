#include "ai/ai_diagnostics.h"
#include <nlohmann/json.hpp>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace sony2fuji::ai;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
int main() {
    try {
        AIDiagnostics diagnostics;
        diagnostics.reset("pnp:selected", 2);
        diagnostics.field("model_digest", "abc123");
        diagnostics.progress(2, 3, 20);
        auto writer = [&] { for (int i = 0; i < 100; ++i) diagnostics.log(2,"DirectML",std::to_string(i)); };
        std::thread first(writer), second(writer); first.join(); second.join();
        diagnostics.log(3,"DirectML",std::string(100000,'x'));
        diagnostics.failure(1,"GPU call failed: 0x887A0001");
        const auto snapshot = nlohmann::json::parse(diagnostics.json());
        require(snapshot.at("requested_device_id") == "pnp:selected", "Requested GPU was lost");
        require(snapshot.at("phase") == 2 && snapshot.at("done") == 3, "Failure lost its progress context");
        require(snapshot.at("native_error") == "GPU call failed: 0x887A0001", "Original native error was lost");
        require(snapshot.at("logs").size() <= 64 && diagnostics.json().size() < 300000,
                "Native diagnostics grew without a bound");
        require(snapshot.at("dropped_log_entries").get<int>() > 0, "Truncated logs were not marked");
        diagnostics.reset("", 3);
        const auto clean = nlohmann::json::parse(diagnostics.json());
        require(clean.at("logs").empty() && !clean.contains("native_error") && !clean.contains("model_digest"),
                "New request leaked the previous failure");
        diagnostics.log(3,"test",std::string("invalid byte \xff"));
        require(nlohmann::json::parse(diagnostics.json()).at("logs").size() == 1,
                "Invalid runtime error encoding broke the diagnostic document");
        std::cout << "PASS bounded per-request native AI diagnostics\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
