#include "model_package.h"
#include "../core/sha256.h"

namespace sony2fuji::ai {
std::string sha256Bytes(const void* data, size_t size) { return hash::sha256Bytes(data, size); }
std::string sha256File(const std::string& path) { return hash::sha256File(path); }
}
