#include "core/processing_migration.h"
#include <cmath>
#include <iostream>
#include <stdexcept>

using namespace sony2fuji;
static void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }

static ImageData testImage() {
    ImageData image(96, 64);
    for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x)
        image.at(x, y) = RGB(.05f + .8f * x / 95, .05f + .8f * y / 63, .15f + .1f * ((x + y) % 2));
    return image;
}

int main() {
    try {
        const auto image = testImage();
        const auto reference = captureMigrationFrame(image);
        require(migrationQuality(reference, reference).accepted(), "identical appearance is accepted");
        auto changed = image;
        for (auto& p : changed.pixels) p.r += .04f;
        require(!migrationQuality(reference, captureMigrationFrame(changed)).accepted(), "global color shift is rejected");
        changed = image;
        for (int y = 18; y < 30; ++y) for (int x = 30; x < 42; ++x) changed.at(x, y).g += .2f;
        require(!migrationQuality(reference, captureMigrationFrame(changed)).accepted(), "local mismatch cannot hide in the mean");
        changed = image;
        for (int y = 0; y < image.height; ++y) for (int x = 0; x < image.width; ++x)
            changed.at(x, y).b = .2f;
        require(!migrationQuality(reference, captureMigrationFrame(changed)).accepted(), "loss of native detail is rejected");
        ImageData large(1024, 1024);
        for (auto& p : large.pixels) p = RGB(.5f, .5f, .5f);
        auto hidden = large;
        for (int y = 0; y < 1024; y += 8) for (int x = 0; x < 1024; x += 8) {
            hidden.at(x, y).r += .12f;
            hidden.at(x + 1, y).r -= .12f;
        }
        require(migrationQuality(captureMigrationFrame(large), captureMigrationFrame(hidden)).accepted(),
            "balanced changes can evade the fitting grid");
        require(!migrationQuality(captureMigrationFrame(large, true), captureMigrationFrame(hidden, true)).accepted(),
            "full-source validation checks every pixel and catches unsampled changes");
        const auto fullReference = captureMigrationFrame(large, true);
        const auto streamed = captureMigrationFrame(hidden, true, &fullReference);
        require(streamed.nativePixels.empty(), "validation streams the candidate without a second full snapshot");
        const auto packedQuality = migrationQuality(fullReference, captureMigrationFrame(hidden, true));
        const auto streamedQuality = migrationQuality(fullReference, streamed);
        require(packedQuality.rgbRMSE == streamedQuality.rgbRMSE && packedQuality.p99Error == streamedQuality.p99Error &&
            packedQuality.worstTileRMSE == streamedQuality.worstTileRMSE && packedQuality.detailRMSE == streamedQuality.detailRMSE,
            "streamed full-source metrics match two-snapshot metrics exactly");
        MigrationParameters original{0, 1, 0, 0, 1, 0, 0, 0, 0, 0};
        int renders = 0;
        auto candidate = fitMigrationParameters(original, reference, [&](const MigrationParameters& values) {
            ++renders;
            auto pixels = image;
            for (auto& p : pixels.pixels) {
                p.r += .1f * (values[0] - .4f);
                p.g += .1f * (values[3] + .2f);
            }
            return captureMigrationFrame(pixels);
        });
        require(renders <= 161 && renders > 1, "fitting has a deterministic work bound");
        require(std::abs(candidate[0] - .4f) < .07f && std::abs(candidate[3] + .2f) < .07f,
            "fitting changes parameters instead of merely relabeling the version");
        require(validMigrationParameters(candidate), "fitted controls stay within client ranges");
        std::cout << "Migration quality, local/detail rejection and bounded parameter fitting passed\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
