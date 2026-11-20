#include "test_harness.h"
#include "sony2fuji/lut_parser.h"
#include "nlohmann/json.hpp"

#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <locale>
#include <sstream>
#include <string>

using namespace sony2fuji;
using nlohmann::json;

namespace {
using rawlab::test::check;
using rawlab::test::require;

std::string makeIdentityCube(int size, const std::string& header = "", const std::string& sep = "\n") {
    std::ostringstream oss;
    oss << header;
    oss << "LUT_3D_SIZE " << size << sep;
    const float denom = static_cast<float>(size - 1);
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                oss << (r / denom) << ' ' << (g / denom) << ' ' << (b / denom) << sep;
            }
        }
    }
    return oss.str();
}

std::string makeIdentityVLT(const std::string& header = "# panasonic vlt file version 1.0\n# source vlt file \"test.vlt\"\n",
                            int size = 17) {
    std::ostringstream oss;
    oss << header;
    oss << "LUT_3D_SIZE " << size << "\n";
    for (int b = 0; b < size; ++b) {
        for (int g = 0; g < size; ++g) {
            for (int r = 0; r < size; ++r) {
                oss << std::min(4095, r * 256) << ' '
                    << std::min(4095, g * 256) << ' '
                    << std::min(4095, b * 256) << '\n';
            }
        }
    }
    return oss.str();
}

struct CommaDecimalFacet : std::numpunct<char> {
protected:
    char do_decimal_point() const override { return ','; }
};

struct LocaleGuard {
    std::locale previous;
    explicit LocaleGuard(const std::locale& next) : previous(std::locale::global(next)) {}
    ~LocaleGuard() { std::locale::global(previous); }
};

void testBomAndLineEndings() {
    LUT3D lut;
    const std::string bomLine1 = std::string("\xEF\xBB\xBF") + makeIdentityCube(2);
    check(lut.loadFromData(bomLine1) == ErrorCode::Success && lut.getSize() == 2,
          "UTF-8 BOM on line 1 is stripped and accepted");

    const std::string bomLine2 = std::string("# comment\n\xEF\xBB\xBF") + makeIdentityCube(2);
    check(lut.loadFromData(bomLine2) == ErrorCode::ParseError,
          "UTF-8 BOM on line 2 is not stripped and fails parsing");

    const std::string crlf = makeIdentityCube(2, "# title: CRLF Test\r\n", "\r\n");
    check(lut.loadFromData(crlf) == ErrorCode::Success && lut.getSize() == 2 && lut.getTitle() == " CRLF Test",
          "CRLF line endings are parsed cleanly including metadata title");

    std::string noTrailingNewline = makeIdentityCube(2);
    noTrailingNewline.pop_back();
    check(lut.loadFromData(noTrailingNewline) == ErrorCode::Success &&
          std::abs(lut.getValue(1, 1, 1).b - 1.0f) < 1e-6f,
          "Final row without trailing newline is parsed");

    const std::string bareCr = makeIdentityCube(2, "", "\r");
    check(lut.loadFromData(bareCr) != ErrorCode::Success,
          "Bare CR is not treated as a line separator");
}

void testCommentsAndKeywords() {
    LUT3D lut;
    const std::string cube =
        "\n"
        "   \t  \n"
        "# plain comment without colon\n"
        "TITLE   \"Warm Film\"\n"
        "  LUT_3D_SIZE   +2 # inline comment after size\n"
        "DOMAIN_MIN 0.0 0.0 0.0#inline comment no space\n"
        "DOMAIN_MAX 1.0 1.0 1.0 # inline comment with space\n"
        "0 0 0#c0\n"
        "1 0 0 # c1\n"
        "0 1 0\t#tab comment\n"
        "1 1 0\n"
        "0 0 1\n"
        "1 0 1\n"
        "0 1 1\n"
        "1 1 1\n";
    check(lut.loadFromData(cube) == ErrorCode::Success, "Comments, tabs, +size, and inline # comments succeed");
    check(lut.getTitle() == "   \"Warm Film\"", "TITLE preserves verbatim remainder after keyword");
    check(lut.getSize() == 2, "LUT_3D_SIZE +2 parsed as 2");
}

void testFloatParsingRules() {
    LUT3D lut;
    const std::string valid =
        "LUT_3D_SIZE 2\n"
        "DOMAIN_MIN -1.5 -0.5 -.25\n"
        "DOMAIN_MAX +2.5 5. 1e+1\n"
        "+0.5 -.5 5.\n"
        "-0.0 1.5e-2 -2.5E+1\n"
        "0.0000001e7 1e-30 1e30\n"
        "0.12345678901234567 0.0000000000000000000000001e30 0.99999999999999999\n"
        "0 0 0\n0 0 0\n0 0 0\n1 1 1\n";
    check(lut.loadFromData(valid) == ErrorCode::Success, "Valid scientific, signed, dot, and long-mantissa floats succeed");
    check(std::abs(lut.getValue(0, 0, 0).r - 0.5f) < 1e-6f &&
          std::abs(lut.getValue(0, 0, 0).g + 0.5f) < 1e-6f &&
          std::abs(lut.getValue(0, 0, 0).b - 5.0f) < 1e-6f,
          "Signed and trailing-dot float values match");
    check(std::abs(lut.getValue(1, 0, 0).g - 0.015f) < 1e-6f &&
          std::abs(lut.getValue(1, 0, 0).b + 25.0f) < 1e-6f,
          "Scientific notation values match");
    check(std::abs(lut.getValue(0, 1, 0).r - 1.0f) < 1e-6f &&
          std::abs(lut.getValue(0, 1, 0).g - 1e-30f) < 1e-35f &&
          std::abs(lut.getValue(0, 1, 0).b - 1e30f) < 1e24f,
          "Extreme exponents fallback matches C-locale float parsing");
    check(std::abs(lut.getValue(1, 1, 0).r - 0.12345679f) < 1e-7f &&
          std::abs(lut.getValue(1, 1, 0).g - 1e5f) < 1e-1f &&
          std::abs(lut.getValue(1, 1, 0).b - 1.0f) < 1e-7f,
          "17-digit mantissa and leading-zero exponent compensation match");

    const char* badRows[] = {
        "nan 0 0",
        "0 NaN 0",
        "inf 0 0",
        "-inf 0 0",
        "+inf 0 0",
        "1e+50 0 0",
        "0.1 0.2 0.3 extra",
        "0.1 0.2 0.3abc",
        "0.1 0.2",
        "0.1, 0.2, 0.3",
        ". 0 0",
        "- 0 0",
        "+ 0 0",
        "1e 0 0",
        "1e+ 0 0",
        "0x1.0p0 0 0",
    };
    for (const char* row : badRows) {
        std::string text = "LUT_3D_SIZE 2\n";
        text += row;
        text += "\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n0 0 0\n1 1 1\n";
        check(lut.loadFromData(text) == ErrorCode::ParseError,
              std::string("Malformed/non-finite float row rejected: ") + row);
    }
}

void testSizeDomainAndRowCounts() {
    LUT3D lut;
    check(lut.loadFromData("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n") == ErrorCode::ParseError,
          "Unsupported LUT_1D_SIZE rejected as ParseError");
    check(lut.loadFromData("LUT_3D_SIZE 1\n0 0 0\n") == ErrorCode::InvalidFormat,
          "LUT_3D_SIZE < 2 rejected as InvalidFormat");
    check(lut.loadFromData("LUT_3D_SIZE 257\n") == ErrorCode::InvalidFormat,
          "LUT_3D_SIZE > 256 rejected as InvalidFormat");
    check(lut.loadFromData("LUT_3D_SIZE abc\n") == ErrorCode::InvalidFormat,
          "Non-integer LUT_3D_SIZE rejected as InvalidFormat");
    check(lut.loadFromData("LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n") == ErrorCode::InvalidFormat,
          "Duplicate LUT_3D_SIZE rejected as InvalidFormat");
    check(lut.loadFromData("0 0 0\nLUT_3D_SIZE 2\n") == ErrorCode::ParseError,
          "Data row before LUT_3D_SIZE rejected as ParseError");
    check(lut.loadFromData("#RawLabHDRLook: display-linear-srgb-v1\nLUT_3D_SIZE 66\n") == ErrorCode::InvalidFormat,
          "HDR look LUT_3D_SIZE > 65 rejected as InvalidFormat");

    check(lut.loadFromData(makeIdentityCube(2, "DOMAIN_MIN 1 0 0\nDOMAIN_MAX 1 1 1\n")) == ErrorCode::ParseError,
          "DOMAIN_MIN >= DOMAIN_MAX rejected as ParseError");
    check(lut.loadFromData(makeIdentityCube(2, "DOMAIN_MIN 0 0 0\nDOMAIN_MIN 0 0 0\n")) == ErrorCode::ParseError,
          "Duplicate DOMAIN_MIN rejected as ParseError");
    check(lut.loadFromData(makeIdentityCube(2, "DOMAIN_MAX 1 1 1\nDOMAIN_MAX 1 1 1\n")) == ErrorCode::ParseError,
          "Duplicate DOMAIN_MAX rejected as ParseError");

    // Underflow (7 rows instead of 8) and overflow (9 rows instead of 8)
    const std::string sevenRows = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n";
    check(lut.loadFromData(sevenRows) == ErrorCode::ParseError, "Row count underflow rejected as ParseError");
    check(lut.loadFromData(makeIdentityCube(2) + "1 1 1\n") == ErrorCode::ParseError,
          "Row count overflow rejected as ParseError");
}

void testVLTRulesAndCompatibilityLastLine() {
    LUT3D lut;
    check(lut.loadFromData(makeIdentityVLT(), true) == ErrorCode::Success,
          "Valid 17^3 VLT succeeds");
    check(lut.loadFromData(makeIdentityVLT("# panasonic vlt file version 1.0\n", 17), true) == ErrorCode::InvalidFormat,
          "VLT missing source header rejected as InvalidFormat");
    check(lut.loadFromData(makeIdentityVLT("# source vlt file \"x\"\n", 17), true) == ErrorCode::InvalidFormat,
          "VLT missing version header rejected as InvalidFormat");
    check(lut.loadFromData(makeIdentityVLT("# panasonic vlt file version 1.0\n# source vlt file \"x\"\n", 2), true) == ErrorCode::InvalidFormat,
          "VLT size != 17 rejected as InvalidFormat");
    check(lut.loadFromData(makeIdentityVLT("# panasonic vlt file version 1.0\n# source vlt file \"x\"\nDOMAIN_MIN 0 0 0\n", 17), true) == ErrorCode::InvalidFormat,
          "VLT with DOMAIN_MIN rejected as InvalidFormat");

    auto badVltFloat = makeIdentityVLT();
    const auto pos = badVltFloat.find("256 0 0");
    require(pos != std::string::npos, "Fixture must contain 256 0 0");
    auto badVltNeg = badVltFloat;
    badVltFloat.replace(pos, 7, "256.5 0 0");
    check(lut.loadFromData(badVltFloat, true) == ErrorCode::InvalidFormat,
          "VLT non-integer entry rejected as InvalidFormat");
    badVltNeg.replace(pos, 7, "-1 0 0");
    check(lut.loadFromData(badVltNeg, true) == ErrorCode::InvalidFormat,
          "VLT negative entry rejected as InvalidFormat");
    auto badVltHigh = makeIdentityVLT();
    badVltHigh.replace(pos, 7, "4096 0 0");
    check(lut.loadFromData(badVltHigh, true) == ErrorCode::InvalidFormat,
          "VLT entry > 4095 rejected as InvalidFormat");

    const std::string original = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";
    const json assigned = {{"version", 1},
        {"input", {{"space", "vlog-vgamut"}, {"reference", "scene"}, {"range", "full"}}},
        {"output", {{"space", "srgb"}, {"reference", "display"}, {"range", "full"}}},
        {"interpolation", "linear"}, {"base_rendering", "none"}};
    const json compat = {{"version", 1}, {"source_bytes", 62},
        {"source_sha256", "c8bce4299c8606d5ca59a4724f46e484e430c42d506cfc2a3f30bbe84d5199cc"},
        {"confirmed", true}, {"contract", assigned}};
    const std::string compatLine = original + "\n#RawLabCompatibility:" + compat.dump() + "\n";
    check(lut.loadFromData(compatLine) == ErrorCode::Success &&
          lut.contractState() == LUTContractState::Compatibility,
          "Compatibility record on final line succeeds");
    check(lut.loadFromData(compatLine + "\n") == ErrorCode::InvalidFormat,
          "Blank line after #RawLabCompatibility rejected as InvalidFormat");
    check(lut.loadFromData(compatLine + "# trailing\n") == ErrorCode::InvalidFormat,
          "Comment after #RawLabCompatibility rejected as InvalidFormat");
}

void testLocaleIndependence() {
    const std::string cube =
        "LUT_3D_SIZE 2\n"
        "DOMAIN_MIN 0.0 0.0 0.0\n"
        "DOMAIN_MAX 1.0 1.0 1.0\n"
        "0.25 0.5 0.75\n"
        "1.0 0.0 0.0\n"
        "0.0 1.0 0.0\n"
        "1.0 1.0 0.0\n"
        "0.0 0.0 1.0\n"
        "1.0 0.0 1.0\n"
        "0.0 1.0 1.0\n"
        "1.0 1.0 1.0\n";

    const std::locale commaLocale(std::locale::classic(), new CommaDecimalFacet());
    LocaleGuard guard(commaLocale);

    LUT3D lut;
    const ErrorCode err = lut.loadFromData(cube);
    check(err == ErrorCode::Success, "LUT3D::loadFromData ignores global C++ comma decimal locale");
    if (err == ErrorCode::Success) {
        const RGB p = lut.getValue(0, 0, 0);
        check(std::abs(p.r - 0.25f) < 1e-6f &&
              std::abs(p.g - 0.5f) < 1e-6f &&
              std::abs(p.b - 0.75f) < 1e-6f,
              "Parsed float values under comma locale remain exact");
    }
}

void test65CubeThroughputSanity() {
    const std::string cube65 = makeIdentityCube(65);
    LUT3D lut;
    const auto t0 = std::chrono::steady_clock::now();
    const ErrorCode err = lut.loadFromData(cube65);
    const auto t1 = std::chrono::steady_clock::now();
    const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    std::cout << "65^3 in-memory LUT parse took " << ms << " ms\n";
    check(err == ErrorCode::Success && lut.getSize() == 65, "65^3 LUT parses cleanly");
    check(std::abs(lut.getValue(32, 32, 32).r - 0.5f) < 1e-6f &&
          std::abs(lut.getValue(64, 64, 64).b - 1.0f) < 1e-6f,
          "65^3 LUT midpoint and corner values are exact");
}
} // namespace

int main() {
    try {
        testBomAndLineEndings();
        testCommentsAndKeywords();
        testFloatParsingRules();
        testSizeDomainAndRowCounts();
        testVLTRulesAndCompatibilityLastLine();
        testLocaleIndependence();
        test65CubeThroughputSanity();
        std::cout << "LUT parser tests complete, failures: " << rawlab::test::failureCount() << '\n';
        return rawlab::test::exitCode();
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
