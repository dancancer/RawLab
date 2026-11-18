#pragma once

#include <iostream>
#include <stdexcept>
#include <string>

namespace rawlab::test {

// Single-threaded assertion counters: failureCount(), checkCount(), check(),
// require(), and resetFailures() mutate non-atomic static ints and must only
// be called from one thread.
inline int& failureCount() {
    static int count = 0;
    return count;
}

inline int& checkCount() {
    static int count = 0;
    return count;
}

inline void resetFailures() {
    failureCount() = 0;
    checkCount() = 0;
}

inline bool check(bool condition, const std::string& message,
                  const char* file = nullptr, int line = 0) {
    ++checkCount();
    if (!condition) {
        ++failureCount();
        if (file != nullptr && line > 0) {
            std::cerr << file << ':' << line << ": FAIL " << message << '\n';
        } else {
            std::cerr << "FAIL " << message << '\n';
        }
    }
    return condition;
}

inline bool checkPass(bool condition, const std::string& message,
                      const char* file = nullptr, int line = 0) {
    if (check(condition, message, file, line)) {
        std::cout << "PASS " << message << '\n';
    }
    return condition;
}

inline void require(bool condition, const std::string& message,
                    const char* file = nullptr, int line = 0) {
    ++checkCount();
    if (!condition) {
        if (file != nullptr && line > 0) {
            throw std::runtime_error(std::string(file) + ':' + std::to_string(line) + ": " + message);
        }
        throw std::runtime_error(message);
    }
}

inline void requirePass(bool condition, const std::string& message,
                        const char* file = nullptr, int line = 0) {
    require(condition, message, file, line);
    std::cout << "PASS " << message << '\n';
}

inline int exitCode() {
    return failureCount() == 0 ? 0 : 1;
}

} // namespace rawlab::test

#define RAWLAB_CHECK(condition, message) \
    ::rawlab::test::check((condition), (message), __FILE__, __LINE__)

#define RAWLAB_REQUIRE(condition, message) \
    ::rawlab::test::require((condition), (message), __FILE__, __LINE__)

#define RAWLAB_TEST_MAIN(...) \
    int main() { \
        try { \
            __VA_ARGS__ \
            return ::rawlab::test::exitCode(); \
        } catch (const std::exception& error) { \
            std::cerr << "FAIL: " << error.what() << '\n'; \
            return 1; \
        } \
    }

#ifndef TEST_MAIN
#define TEST_MAIN(...) RAWLAB_TEST_MAIN(__VA_ARGS__)
#endif
