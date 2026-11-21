#ifndef NDEBUG
#error "image_data_bounds_release_tests.cpp must be built with NDEBUG"
#endif

#include "test_harness.h"
#include "sony2fuji/common.h"

#include <stdexcept>

namespace {

template <typename Fn>
bool throwsOutOfRange(Fn&& fn) {
    try {
        (void)fn();
        return false;
    } catch (const std::out_of_range&) {
        return true;
    }
}

} // namespace

TEST_MAIN({
    using sony2fuji::ImageData;
    using sony2fuji::RGB;

    ImageData img(2, 2);
    img.at(0, 0) = RGB(1.0f, 2.0f, 3.0f);
    img.at(1, 1) = RGB(4.0f, 5.0f, 6.0f);
    const ImageData& cimg = img;

    // Test (2, 0) FIRST with RAWLAB_REQUIRE: flattened index 0 * 2 + 2 = 2 < pixels.size() (4),
    // so reverting to assert-only under NDEBUG silently reads pixels[2] with no UB/crash
    // and deterministically fails before reaching negative-index checks.
    RAWLAB_REQUIRE(throwsOutOfRange([&]() -> RGB& { return img.at(2, 0); }),
                   "non-const at(2, 0) throws std::out_of_range under NDEBUG");
    RAWLAB_REQUIRE(throwsOutOfRange([&]() -> const RGB& { return cimg.at(2, 0); }),
                   "const at(2, 0) throws std::out_of_range under NDEBUG");

    RAWLAB_CHECK(throwsOutOfRange([&]() -> RGB& { return img.at(-1, 0); }),
                 "non-const at(-1, 0) throws std::out_of_range");
    RAWLAB_CHECK(throwsOutOfRange([&]() -> const RGB& { return cimg.at(-1, 0); }),
                 "const at(-1, 0) throws std::out_of_range");

    RAWLAB_CHECK(throwsOutOfRange([&]() -> RGB& { return img.at(0, -1); }),
                 "non-const at(0, -1) throws std::out_of_range");
    RAWLAB_CHECK(throwsOutOfRange([&]() -> const RGB& { return cimg.at(0, -1); }),
                 "const at(0, -1) throws std::out_of_range");

    RAWLAB_CHECK(throwsOutOfRange([&]() -> RGB& { return img.at(0, 2); }),
                 "non-const at(0, 2) throws std::out_of_range");
    RAWLAB_CHECK(throwsOutOfRange([&]() -> const RGB& { return cimg.at(0, 2); }),
                 "const at(0, 2) throws std::out_of_range");

    ImageData empty(0, 0);
    const ImageData& cempty = empty;
    RAWLAB_CHECK(throwsOutOfRange([&]() -> RGB& { return empty.at(0, 0); }),
                 "non-const empty ImageData(0, 0).at(0, 0) throws std::out_of_range");
    RAWLAB_CHECK(throwsOutOfRange([&]() -> const RGB& { return cempty.at(0, 0); }),
                 "const empty ImageData(0, 0).at(0, 0) throws std::out_of_range");

    // Verify valid coordinates work properly in both non-const and const overloads.
    RAWLAB_CHECK(cimg.at(0, 0).r == 1.0f && cimg.at(0, 0).g == 2.0f && cimg.at(0, 0).b == 3.0f,
                 "valid const at(0, 0) reads expected pixel");
    RAWLAB_CHECK(cimg.at(1, 1).r == 4.0f && cimg.at(1, 1).g == 5.0f && cimg.at(1, 1).b == 6.0f,
                 "valid const at(1, 1) reads expected pixel");

    // Inconsistent width/height vs pixels.size() must also throw std::out_of_range.
    ImageData inconsistent(2, 2);
    inconsistent.width = 10;
    const ImageData& cinconsistent = inconsistent;
    RAWLAB_CHECK(throwsOutOfRange([&]() -> RGB& { return inconsistent.at(0, 1); }),
                 "non-const inconsistent width throws std::out_of_range on index >= pixels.size()");
    RAWLAB_CHECK(throwsOutOfRange([&]() -> const RGB& { return cinconsistent.at(0, 1); }),
                 "const inconsistent width throws std::out_of_range on index >= pixels.size()");
})
