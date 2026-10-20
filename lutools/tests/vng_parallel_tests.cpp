#include <libraw/libraw.h>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {
class SyntheticRaw : public LibRaw {
public:
    SyntheticRaw(int width, int height, int colors, bool flat) {
        imgdata.sizes.width = imgdata.sizes.iwidth = width;
        imgdata.sizes.height = imgdata.sizes.iheight = height;
        imgdata.idata.colors = colors;
        imgdata.idata.filters = colors == 4 ? 0xb4b4b4b4U : 0x94949494U;
        imgdata.image = static_cast<ushort (*)[4]>(std::calloc(size_t(width) * height, sizeof(ushort[4])));
        if (!imgdata.image) throw std::bad_alloc();
        uint32_t seed = 0x7492bafe;
        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            imgdata.image[size_t(y) * width + x][fcol(y, x)] = flat ? 12000 : (seed & 65535);
        }
    }
    void interpolate() { vng_interpolate(); }
    uint64_t fingerprint() const {
        uint64_t hash = UINT64_C(14695981039346656037);
        for (size_t i = 0; i < size_t(imgdata.sizes.width) * imgdata.sizes.height; ++i)
            for (int c = 0; c < imgdata.idata.colors; ++c) {
                hash = (hash ^ (imgdata.image[i][c] & 255)) * UINT64_C(1099511628211);
                hash = (hash ^ (imgdata.image[i][c] >> 8)) * UINT64_C(1099511628211);
            }
        return hash;
    }
};

struct Progress {
    std::vector<std::array<int, 3>> calls;
    int cancelAt = -1;
    static int callback(void* context, LibRaw_progress stage, int iteration, int expected) {
        auto& state = *static_cast<Progress*>(context);
        state.calls.push_back({int(stage), iteration, expected});
        return int(state.calls.size()) == state.cancelAt;
    }
};
}

int main(int argc, char**) {
    try {
        const std::array<std::array<int, 3>, 9> shapes{{
            {7, 7, 3}, {8, 8, 3}, {17, 259, 3}, {33, 260, 3}, {513, 517, 3},
            {511, 519, 4}, {18, 258, 4}, {512, 1028, 3}, {513, 1029, 4}
        }};
        // Released LibRaw 0.22.2, before the parallel patch; all active channels, including borders.
        const std::array<uint64_t, 18> expected{{
            8225016403659521555ULL, 15301924655879904435ULL,
            3556318248959150629ULL, 4644455497328818469ULL,
            1189897464469312598ULL, 5502605145981598883ULL,
            16961228449665312716ULL, 16018952498026139397ULL,
            6080680623004601440ULL, 7032555886806847635ULL,
            17522806313207607561ULL, 6256865826699000773ULL,
            9721440431192103410ULL, 1086767814943221157ULL,
            14369078779071441840ULL, 6545502722567496485ULL,
            9067647029425467124ULL, 18093033659445367109ULL
        }};
        size_t index = 0;
        for (const auto& shape : shapes) for (bool flat : {false, true}) {
            auto raw = std::make_unique<SyntheticRaw>(shape[0], shape[1], shape[2], flat);
            Progress progress;
            raw->set_progress_handler(&Progress::callback, &progress);
            raw->interpolate();
            const auto actual = raw->fingerprint();
            if (argc > 1) std::cout << actual << "ULL,\n";
            else if (actual != expected[index]) throw std::runtime_error("released VNG fingerprint mismatch " + std::to_string(index));
            auto quiet = std::make_unique<SyntheticRaw>(shape[0], shape[1], shape[2], flat);
            quiet->interpolate();
            if (quiet->fingerprint() != actual) throw std::runtime_error("callback changed VNG pixels");
            if (shape[0] >= 8) {
                const int batches = (shape[1] - 5) / 256 + 1;
                if (progress.calls.size() != size_t(3 + batches))
                    throw std::runtime_error("VNG callback sequence changed");
                for (int batch = 0; batch < batches; ++batch)
                    if (progress.calls[3 + batch] != std::array<int, 3>{
                        int(LIBRAW_PROGRESS_INTERPOLATE), batch + 1, (shape[1] - 3) / 256 + 1})
                        throw std::runtime_error("VNG callback values changed");
                auto cancelled = std::make_unique<SyntheticRaw>(shape[0], shape[1], shape[2], flat);
                Progress cancellation;
                cancellation.cancelAt = 3 + batches;
                cancelled->set_progress_handler(&Progress::callback, &cancellation);
                bool threw = false;
                try { cancelled->interpolate(); }
                catch (LibRaw_exceptions error) { threw = error == LIBRAW_EXCEPTION_CANCELLED_BY_CALLBACK; }
                if (!threw) throw std::runtime_error("VNG cancellation lost");
            }
            ++index;
        }
        std::cout << "PASS released VNG pixels, boundaries, progress and cancellation\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
