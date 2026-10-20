#pragma once
#include <array>
#include <algorithm>
#include <cmath>
#include <optional>
#include <opencv2/core.hpp>

namespace denoise_quality {
inline constexpr std::array<std::array<int, 2>, 9> residualLags{{
    {1, 0}, {0, 1}, {1, 1}, {2, 0}, {0, 2}, {4, 0}, {0, 4}, {8, 0}, {0, 8}}};

struct ResidualCorrelations {
    std::array<std::optional<double>, 3> rgb;
    std::array<std::array<std::optional<double>, 3>, 9> spatial;
};

inline ResidualCorrelations residualCorrelations(const cv::Mat& residual) {
    CV_Assert(residual.type() == CV_32FC3);
    const auto correlation = [&](int first, int second, int dx, int dy) -> std::optional<double> {
        double sx=0, sy=0, sxx=0, syy=0, sxy=0, count=0;
        for (int y=0;y<residual.rows-dy;++y) for (int x=0;x<residual.cols-dx;++x) {
            const double a=residual.at<cv::Vec3f>(y,x)[first];
            const double b=residual.at<cv::Vec3f>(y+dy,x+dx)[second];
            sx+=a; sy+=b; sxx+=a*a; syy+=b*b; sxy+=a*b; ++count;
        }
        if (count<2) return std::nullopt;
        const double vx=sxx-sx*sx/count, vy=syy-sy*sy/count;
        if (!(vx>0 && vy>0)) return std::nullopt;
        return std::clamp((sxy-sx*sy/count)/std::sqrt(vx*vy),-1.,1.);
    };
    ResidualCorrelations result;
    result.rgb={correlation(0,1,0,0),correlation(0,2,0,0),correlation(1,2,0,0)};
    for (size_t i=0;i<residualLags.size();++i) for (int c=0;c<3;++c)
        result.spatial[i][c]=correlation(c,c,residualLags[i][0],residualLags[i][1]);
    return result;
}
}
