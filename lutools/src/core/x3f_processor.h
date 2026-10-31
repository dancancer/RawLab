#pragma once

#include "sony2fuji/raw_processor.h"

namespace sony2fuji {

bool hasX3fSignature(const std::string& path);
bool hasX3fExtension(const std::string& path);
bool x3fRenderingAvailable();

// 保存设置显影后的 display-linear sRGB；不是未映射的 scene-linear RAW。
class X3fProcessor {
public:
    X3fProcessor();
    ~X3fProcessor();
    X3fProcessor(const X3fProcessor&) = delete;
    X3fProcessor& operator=(const X3fProcessor&) = delete;
    ErrorCode process(const std::string& path, const std::string& model, int flip,
                      const RAWProcessOptions& options, ImageData& output);
    const std::string& error() const { return error_; }
private:
    void* handle_ = nullptr;
    std::string error_;
    ImageData base_;
};

}
