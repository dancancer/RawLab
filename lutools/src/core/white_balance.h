#pragma once
#include <libraw/libraw_types.h>
#include <array>

namespace sony2fuji {
struct WhitePoint { double x, y; };
struct TemperatureTint { double temperature, tint; };
WhitePoint temperatureWhitePoint(double temperature, double tint);
TemperatureTint whitePointTemperature(WhitePoint white);

class CameraWhiteBalance {
    using Matrix = std::array<std::array<double,3>,3>;
public:
    CameraWhiteBalance() = default;
    CameraWhiteBalance(const Matrix& first, const Matrix& second, double firstTemperature, double secondTemperature);
    explicit CameraWhiteBalance(const libraw_data_t& raw);
    bool available() const { return valid_; }
    TemperatureTint asShot() const { return asShot_; }
    bool multipliers(double temperature, double tint, float output[4], const Matrix* profileMatrix = nullptr) const;
    bool solveTemperatureTint(const std::array<double,3>& neutral, TemperatureTint& out) const;
    void calibrationData(Matrix& first, Matrix& second, double& firstTemperature, double& secondTemperature) const {
        first = first_;
        second = second_;
        firstTemperature = firstTemperature_;
        secondTemperature = secondTemperature_;
    }
private:
    bool solveTemperatureTintUnchecked(const std::array<double,3>& neutral, TemperatureTint& out) const;
    Matrix matrix(double temperature) const;
    Matrix first_{}, second_{};
    double firstTemperature_ = 0, secondTemperature_ = 0;
    TemperatureTint asShot_{6500,0};
    bool valid_ = false;
};
}
