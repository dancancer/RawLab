#pragma once

#include <filesystem>

namespace sony2fuji {

// Returns 0 without an MPF index, -1 for an invalid or unsupported index,
// or the number of indexed JPEGs (2 or 3) for an SDR primary and its previews.
int inspectSdrJpegMpf(const std::filesystem::path& path);

}
