// Temperature/xy conversion adapted from Adobe DNG SDK dng_temperature.cpp.
// Copyright 2006-2019 Adobe Systems Incorporated. All Rights Reserved.
// Adobe permits use, modification and distribution under the accompanying
// license in third_party/Adobe-DNG-SDK-LICENSE.txt.
#include "white_balance.h"
#include <algorithm>
#include <cmath>

namespace sony2fuji {
namespace {
struct Isotherm { double r, u, v, slope; };
// Wyszecki & Stiles, Color Science, second edition, p. 228 (DNG SDK table).
constexpr Isotherm table[] = {
    {0,.18006,.26352,-.24341}, {10,.18066,.26589,-.25479},
    {20,.18133,.26846,-.26876}, {30,.18208,.27119,-.28539},
    {40,.18293,.27407,-.30470}, {50,.18388,.27709,-.32675},
    {60,.18494,.28021,-.35156}, {70,.18611,.28342,-.37915},
    {80,.18740,.28668,-.40955}, {90,.18880,.28997,-.44278},
    {100,.19032,.29326,-.47888}, {125,.19462,.30141,-.58204},
    {150,.19962,.30921,-.70471}, {175,.20525,.31647,-.84901},
    {200,.21142,.32312,-1.0182}, {225,.21807,.32909,-1.2168},
    {250,.22511,.33439,-1.4512}, {275,.23247,.33904,-1.7298},
    {300,.24010,.34308,-2.0637}, {325,.24702,.34655,-2.4681},
    {350,.25591,.34951,-2.9641}, {375,.26400,.35200,-3.5814},
    {400,.27218,.35407,-4.3633}, {425,.28039,.35577,-5.3762},
    {450,.28863,.35714,-6.7262}, {475,.29685,.35823,-8.5955},
    {500,.30505,.35907,-11.324}, {525,.31320,.35968,-15.628},
    {550,.32129,.36011,-23.325}, {575,.32931,.36038,-40.770},
    {600,.33724,.36051,-116.45}
};
std::array<double,2> direction(double slope) {
    const double length = std::hypot(1.0,slope);
    return {1/length,slope/length};
}
double illuminantTemperature(unsigned value) {
    switch (value) {
        case 17: case 3: return 2856;
        case 18: return 4874;
        case 19: return 6774;
        case 20: return 5503;
        case 21: return 6504;
        case 22: return 7504;
        case 23: return 5003;
        case 1: case 4: case 9: return 5500;
        case 10: return 6500;
        case 11: return 7500;
        default: return 0;
    }
}
using Matrix = std::array<std::array<double,3>,3>;
bool inverse(const Matrix& m, Matrix& out) {
    const double d=m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])-
        m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])+m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);
    if (!std::isfinite(d) || std::abs(d)<1e-10) return false;
    for (int r=0;r<3;++r) for (int c=0;c<3;++c)
        out[c][r]=(m[(r+1)%3][(c+1)%3]*m[(r+2)%3][(c+2)%3]-
                   m[(r+1)%3][(c+2)%3]*m[(r+2)%3][(c+1)%3])/d;
    return true;
}
bool validMatrix(const Matrix& m) {
    for (auto& row:m) for (double v:row) if (!std::isfinite(v)) return false;
    Matrix unused{};
    return inverse(m,unused);
}
Matrix dngMatrix(const libraw_data_t& raw, int index) {
    Matrix result{};
    const auto& profile=raw.color.dng_color[index];
    bool calibrated=false;
    for (int r=0;r<3;++r) for (int c=0;c<3;++c) calibrated |= profile.calibration[r][c]!=0;
    for (int r=0;r<3;++r) for (int c=0;c<3;++c) {
        double value=profile.colormatrix[r][c];
        if (calibrated) {
            value=0;
            for (int k=0;k<3;++k) value+=profile.calibration[r][k]*profile.colormatrix[k][c];
        }
        const double analog=raw.color.dng_levels.analogbalance[r];
        result[r][c]=value*(analog>0 && std::isfinite(analog) ? analog : 1);
    }
    return result;
}
}

WhitePoint temperatureWhitePoint(double temperature, double tint) {
    const double r=1e6/std::clamp(temperature,2000.0,50000.0), offset=tint/-3000;
    int i=0;
    while (i<29 && r>=table[i+1].r) ++i;
    const auto& a=table[i]; const auto& b=table[i+1];
    const double f=(b.r-r)/(b.r-a.r);
    const auto da=direction(a.slope), db=direction(b.slope);
    double du=f*da[0]+(1-f)*db[0], dv=f*da[1]+(1-f)*db[1];
    const double length=std::hypot(du,dv);
    const double u=f*a.u+(1-f)*b.u+offset*du/length;
    const double v=f*a.v+(1-f)*b.v+offset*dv/length;
    return {1.5*u/(u-4*v+2),v/(u-4*v+2)};
}

TemperatureTint whitePointTemperature(WhitePoint xy) {
    const double denominator=1.5-xy.x+6*xy.y;
    const double u=2*xy.x/denominator, v=3*xy.y/denominator;
    double previousDistance=0;
    auto previousDirection=direction(table[0].slope);
    for (int i=1;i<=30;++i) {
        const auto& a=table[i-1]; const auto& b=table[i];
        auto d=direction(b.slope);
        double distance=-(u-b.u)*d[1]+(v-b.v)*d[0];
        if (distance<=0 || i==30) {
            distance=std::max(0.0,-distance);
            const double f=i==1 ? 0 : distance/(previousDistance+distance);
            const double du=f*previousDirection[0]+(1-f)*d[0];
            const double dv=f*previousDirection[1]+(1-f)*d[1];
            const double offset=((u-f*a.u-(1-f)*b.u)*du+(v-f*a.v-(1-f)*b.v)*dv)/std::hypot(du,dv);
            return {1e6/(f*a.r+(1-f)*b.r),offset*-3000};
        }
        previousDistance=distance; previousDirection=d;
    }
    return {6500,0};
}

CameraWhiteBalance::Matrix CameraWhiteBalance::matrix(double temperature) const {
    if (firstTemperature_==0 || secondTemperature_==0 || firstTemperature_==secondTemperature_) return first_;
    const double f=std::clamp((1/temperature-1/secondTemperature_)/(1/firstTemperature_-1/secondTemperature_),0.0,1.0);
    Matrix result{};
    for (int r=0;r<3;++r) for (int c=0;c<3;++c) result[r][c]=f*first_[r][c]+(1-f)*second_[r][c];
    return result;
}

CameraWhiteBalance::CameraWhiteBalance(const libraw_data_t& raw) {
    if (raw.idata.colors!=3) return;
    for (int r=0;r<3;++r) for (int c=0;c<3;++c) first_[r][c]=raw.color.cam_xyz[r][c];
    if (raw.idata.dng_version) {
        auto a=dngMatrix(raw,0), b=dngMatrix(raw,1);
        if (validMatrix(a)) first_=a;
        else if (validMatrix(b)) first_=b;
        if (validMatrix(a) && validMatrix(b)) {
            second_=b;
            firstTemperature_=illuminantTemperature(raw.color.dng_color[0].illuminant);
            secondTemperature_=illuminantTemperature(raw.color.dng_color[1].illuminant);
        }
    }
    if (!validMatrix(first_)) return;
    std::array<double,3> neutral{};
    for (int c=0;c<3;++c) {
        const double gain=raw.color.cam_mul[c];
        if (!std::isfinite(gain) || gain<=0) return;
        neutral[c]=1/gain;
    }
    for (int iteration=0;iteration<30;++iteration) {
        Matrix cameraToXYZ{};
        if (!inverse(matrix(asShot_.temperature),cameraToXYZ)) return;
        std::array<double,3> xyz{};
        for (int r=0;r<3;++r) for (int c=0;c<3;++c) xyz[r]+=cameraToXYZ[r][c]*neutral[c];
        const double sum=xyz[0]+xyz[1]+xyz[2];
        if (sum<=0 || xyz[0]<=0 || xyz[1]<=0 || xyz[2]<=0) return;
        const auto next=whitePointTemperature({xyz[0]/sum,xyz[1]/sum});
        const double change=std::abs(asShot_.temperature-next.temperature);
        asShot_=next;
        if (change<0.01) break;
    }
    valid_=std::isfinite(asShot_.temperature) && std::isfinite(asShot_.tint) &&
        asShot_.temperature>=2000 && asShot_.temperature<=50000 && std::abs(asShot_.tint)<=150;
}

bool CameraWhiteBalance::multipliers(double temperature, double tint, float output[4], const Matrix* profileMatrix) const {
    if (!valid_ || !std::isfinite(temperature) || !std::isfinite(tint) ||
        temperature<2000 || temperature>50000 || std::abs(tint)>150) return false;
    const auto xy=temperatureWhitePoint(temperature,tint);
    const std::array<double,3> xyz={xy.x/xy.y,1,(1-xy.x-xy.y)/xy.y};
    const auto m=profileMatrix ? *profileMatrix : matrix(temperature);
    for (int c=0;c<3;++c) {
        double response=0;
        for (int j=0;j<3;++j) response+=m[c][j]*xyz[j];
        if (!std::isfinite(response)) return false;
        // Extreme illuminants can leave the camera matrix's physical gamut.
        // Project to a positive response rather than rejecting a valid slider value.
        output[c]=1/std::max(response,1e-4);
    }
    const float green=output[1];
    for (int c=0;c<3;++c) output[c]/=green;
    output[3]=1;
    return true;
}
}
