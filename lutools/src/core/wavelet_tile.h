#pragma once

#include <opencv2/core.hpp>
#include <vector>

namespace sony2fuji {

inline cv::Mat waveletTilePlane(const cv::Mat& image,const cv::Rect& center,
                               int radius,int alignment,int channel) {
    const int width=(center.width+alignment-1)/alignment*alignment+2*radius;
    const int height=(center.height+alignment-1)/alignment*alignment+2*radius;
    cv::Mat plane(height,width,CV_32F);
    std::vector<int> columns(width);
    for (int x=0;x<width;++x)
        columns[x]=cv::borderInterpolate(center.x-radius+x,image.cols,cv::BORDER_REFLECT_101);
    // 末尾 tile 的对齐区可能越过局部 ROI；必须按原图边界反射。
    for (int y=0;y<height;++y) {
        const int sourceY=cv::borderInterpolate(center.y-radius+y,image.rows,cv::BORDER_REFLECT_101);
        const auto* source=image.ptr<cv::Vec3f>(sourceY);
        auto* output=plane.ptr<float>(y);
        for (int x=0;x<width;++x) output[x]=source[columns[x]][channel];
    }
    return plane;
}

} // namespace sony2fuji
