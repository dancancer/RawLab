#include "sony2fuji/lut_parser.h"
#include "sony2fuji/lut_applicator.h"
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include "nlohmann/json.hpp"

using namespace sony2fuji;
using nlohmann::json;
namespace {
int failures = 0;
void check(bool value, const std::string& label) {
    if (!value) { ++failures; std::cerr << "FAIL " << label << '\n'; }
}
json contract() {
    return {{"version", 1},
        {"input", {{"space", "vlog-vgamut"}, {"reference", "scene"}, {"range", "full"}}},
        {"output", {{"space", "srgb"}, {"reference", "display"}, {"range", "full"}}},
        {"interpolation", "linear"}, {"base_rendering", "none"},
        {"evidence", {{"source", "Synthetic test definition"},
                      {"conditions", "Identity RGB table; full-range V-Log input and sRGB output"}}}};
}
void writeCube(const std::filesystem::path& path, const json& metadata, const std::string& prefix = "") {
    std::ofstream file(path);
    file << prefix;
    if (!metadata.is_null()) file << "#RawLabColorContract:" << metadata.dump() << '\n';
    file << "LUT_3D_SIZE 2\n";
    for (int b=0;b<2;++b) for(int g=0;g<2;++g) for(int r=0;r<2;++r)
        file << r << ' ' << g << ' ' << b << '\n';
}
bool photo(const std::filesystem::path& p) {
    auto lut = LUTParser::loadLUT(p.u8string());
    return lut && lut->isPhotoLUT();
}
}
int main() {
    const auto directory = std::filesystem::temp_directory_path() /
        ("rawlab-lut-contract-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directory(directory);
    const auto source = directory/"look.cube";
    auto metadata = contract();
    writeCube(source, metadata);
    check(photo(source), "Explicit evidenced V-Log color contract is admitted");
    {
        auto text = metadata.dump();
        text.insert(1, "\"version\":2,");
        writeCube(source, nullptr, "#RawLabColorContract:" + text + "\n");
        check(!photo(source), "Duplicate JSON fields cannot overwrite conflicting color evidence");
    }
    writeCube(source, nullptr, "#LUMIXPHOTOSTYLE STD\n");
    check(!photo(source), "STD is never guessed to be sRGB");
    writeCube(source, nullptr, "#LUMIXPHOTOSTYLE VLOG\n");
    check(!photo(source), "VLOG alone does not specify output or reference");
    metadata.erase("evidence"); writeCube(source, metadata);
    check(!photo(source), "Missing evidence does not admit a LUT");
    metadata = contract(); metadata["evidence"]["source"] = "  "; writeCube(source, metadata);
    check(!photo(source), "Blank evidence is not a reference");
    metadata = contract(); metadata["output"]["range"] = "automatic"; writeCube(source, metadata);
    check(!photo(source), "Unknown numeric range is blocked");
    metadata = contract(); metadata["input"]["space"] = "srgb";
    metadata["input"]["reference"] = "display";
    metadata["base_rendering"] = "panasonic-standard"; writeCube(source, metadata);
    check(!photo(source), "Unknown camera base rendering is not substituted");
    metadata = contract(); metadata["appearance"] = "verified"; writeCube(source, metadata);
    check(!photo(source), "A manifest cannot self-certify verified appearance");
    writeCube(source, contract(), "#Gamma:F-Log2 to PROVIA\n#Gamut:F-Gamut to ITU-R BT.709\n");
    check(!photo(source), "Conflicting legacy and explicit declarations fail closed");
    writeCube(source, nullptr, "#Gamma:F-Log2 to PROVIA\n#Gamut:F-Gamut to ITU-R BT.709\n");
    check(photo(source), "Existing declared Fuji contracts retain compatibility");
    for (const auto* extra : {"#Gamma:F-Log2 to Other\n", "#Gamut:F-Gamut to ITU-R BT.709\n", "#LUMIXPHOTOSTYLE STD\n"}) {
        writeCube(source, nullptr, std::string("#Gamma:F-Log2 to PROVIA\n#Gamut:F-Gamut to ITU-R BT.709\n") + extra);
        check(!photo(source), "Repeated or contradictory legacy color declarations are blocked");
    }
    writeCube(source, contract(), "#LUMIXPHOTOSTYLE STD\n#LUMIXPHOTOSTYLE VLOG\n");
    check(!photo(source), "A later LUMIX tag cannot hide an earlier conflicting base");
    {
        metadata = contract(); metadata["interpolation"] = "tetrahedral";
        std::ofstream file(source);
        file << "#RawLabColorContract:" << metadata.dump() << "\nLUT_3D_SIZE 2\n";
        for (int b=0;b<2;++b) for(int g=0;g<2;++g) for(int r=0;r<2;++r)
            file << (r*g*b) << " 0 0\n";
    }
    {
        auto value = std::shared_ptr<LUT3D>(LUTParser::loadLUT(source.u8string()));
        LUTApplicator apply(value);
        for (auto p : {RGB(.8f,.5f,.2f),RGB(.2f,.5f,.8f),RGB(.5f,.8f,.2f),
                       RGB(.8f,.2f,.5f),RGB(.5f,.2f,.8f),RGB(.2f,.8f,.5f)})
            check(std::abs(apply.apply(p).r-.2f)<1e-6, "Tetrahedral follows all six vertex orderings");
    }

    {
        const std::string original = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
        auto assigned = contract(); assigned.erase("evidence");
        json confirmation = {{"version",1}, {"source_bytes",62},
            {"source_sha256","c8bce4299c8606d5ca59a4724f46e484e430c42d506cfc2a3f30bbe84d5199cc"},
            {"confirmed",true}, {"contract",assigned}};
        auto save = [&] {
            std::ofstream file(source, std::ios::binary);
            file << original << "\n#RawLabCompatibility:" << confirmation.dump() << '\n';
        };
        save();
        auto compatible = LUTParser::loadLUT(source.u8string());
        check(compatible && compatible->isPhotoLUT() && int(compatible->contractState()) == 7,
              "Confirmed user interpretation is usable and remains distinct from author evidence");
        check(compatible && compatible->hasColorContract() && compatible->requiresCPU(),
              "Compatibility uses explicit CPU color evaluation, never the legacy unknown path");
        confirmation["confirmed"] = false; save();
        check(!photo(source), "Missing user confirmation cannot enable compatibility");
        confirmation["confirmed"] = true; confirmation["source_sha256"] = std::string(64,'0'); save();
        check(!photo(source), "A compatibility record cannot describe changed source bytes");
    }

    const auto vlt = directory/"identity.vlt";
    {
        std::ofstream file(vlt);
        file << "# panasonic vlt file version 1.0\n# source vlt file \"\"\nLUT_3D_SIZE 17\n\n";
        for(int b=0;b<17;++b) for(int g=0;g<17;++g) for(int r=0;r<17;++r)
            file << std::min(4095,r*256) << ' ' << std::min(4095,g*256) << ' ' << std::min(4095,b*256) << '\n';
    }
    auto lut = LUTParser::loadLUT(vlt.u8string());
    check(lut && lut->isValid(), "VLT 1.0 structure is read without inventing color meaning");
    check(lut && !lut->isPhotoLUT(), "VLT numeric format does not imply an output color space");
    if (lut) {
        auto shared = std::shared_ptr<LUT3D>(std::move(lut)); LUTApplicator apply(shared);
        for (float x : {0.f, .18f, 256.f/4095, 3840.f/4095, .999f, 1.f}) {
            auto result=apply.apply(RGB(x,.4f,.7f));
            check(std::abs(result.r-x)<2e-7 && std::abs(result.g-.4f)<2e-7 && std::abs(result.b-.7f)<2e-7,
                  "VLT exact 12-bit knots including the final 255-code interval");
        }
    }
    std::filesystem::remove_all(directory);
    std::cout << "LUT contract failures: " << failures << '\n';
    return failures ? 1 : 0;
}
