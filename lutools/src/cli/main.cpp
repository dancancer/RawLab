#include "sony2fuji/sony2fuji.h"
#include "sony2fuji/ffi/sony2fuji_c.h"
#include <iostream>
#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <cctype>

using namespace sony2fuji;


void printUsage(const char* programName) {
    std::cout << "Sony to Fuji LUT Tool v" << getVersionString() << "\n\n";
    std::cout << "用法:\n";
    std::cout << "  " << programName << " <输入RAW文件> -o <输出文件> [选项]\n\n";
    std::cout << "必需参数:\n";
    std::cout << "  <输入RAW文件>        Sony RAW 文件路径 (.ARW)\n";
    std::cout << "  -o, --output <file>  输出文件路径 (.jpg 或 .png)\n\n";
    std::cout << "可选参数:\n";
    std::cout << "  -l, --lut <file>       胶片外观文件路径 (.cube 或 .rlook)\n";
    std::cout << "  --no-lut               不应用 LUT,输出 sRGB 参考图像\n";
    std::cout << "  -q, --quality <1-100>  JPEG 质量 (默认: 95)\n";
    std::cout << "  --auto-wb              使用自动白平衡\n";
    std::cout << "  --camera-wb            使用相机白平衡 (默认)\n";
    std::cout << "  --exposure <EV>        曝光补偿 (默认: 0.0)\n";
    std::cout << "  --raw-exposure <mode>  曝光基准: scene (默认), preview, sensor\n";
    std::cout << "  --brightness <value>   亮度调整 (默认: 1.0)\n";
    std::cout << "  -h, --help             显示此帮助信息\n";
    std::cout << "  -v, --version          显示版本信息\n\n";
    std::cout << "示例:\n";
    std::cout << "  # 不使用 LUT,输出 sRGB 参考图像\n";
    std::cout << "  " << programName << " DSC00001.ARW -o output.jpg --no-lut\n\n";
    std::cout << "  # 使用 ETERNA LUT 处理图像\n";
    std::cout << "  " << programName << " DSC00001.ARW -l F-Log2/ETERNA_BT709.cube -o output.jpg\n\n";
    std::cout << "  # 使用自定义质量和白平衡\n";
    std::cout << "  " << programName << " DSC00001.ARW -l ETERNA.cube -o output.jpg -q 98 --auto-wb\n\n";
}

void printVersion() {
    std::cout << "Sony to Fuji LUT Tool v" << getVersionString() << "\n";
    std::cout << "Copyright (c) 2026\n";
}

struct Options {
    std::string inputFile;
    std::string lutFile;
    std::string outputFile;
    int quality = 95;
    bool autoWhiteBalance = false;
    bool cameraWhiteBalance = true;
    float exposure = 0.0f;
    float brightness = 1.0f;
    bool noLut = false;  // 新增：不应用 LUT
    sony2fuji_raw_exposure_mode rawExposure = SONY2FUJI_EXPOSURE_SCENE;
};

bool parseArguments(int argc, char* argv[], Options& options) {
    if (argc < 2) {
        return false;
    }

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];

        if (arg == "-h" || arg == "--help") {
            return false;
        } else if (arg == "-v" || arg == "--version") {
            printVersion();
            exit(0);
        } else if (arg == "-l" || arg == "--lut") {
            if (i + 1 < argc) {
                options.lutFile = argv[++i];
            } else {
                std::cerr << "错误: " << arg << " 需要参数\n";
                return false;
            }
        } else if (arg == "-o" || arg == "--output") {
            if (i + 1 < argc) {
                options.outputFile = argv[++i];
            } else {
                std::cerr << "错误: " << arg << " 需要参数\n";
                return false;
            }
        } else if (arg == "-q" || arg == "--quality") {
            if (i + 1 < argc) {
                options.quality = std::stoi(argv[++i]);
                if (options.quality < 1 || options.quality > 100) {
                    std::cerr << "错误: 质量必须在 1-100 之间\n";
                    return false;
                }
            } else {
                std::cerr << "错误: " << arg << " 需要参数\n";
                return false;
            }
        } else if (arg == "--auto-wb") {
            options.autoWhiteBalance = true;
            options.cameraWhiteBalance = false;
        } else if (arg == "--camera-wb") {
            options.cameraWhiteBalance = true;
            options.autoWhiteBalance = false;
        } else if (arg == "--raw-exposure") {
            if (i+1>=argc) return false;
            const std::string mode=argv[++i];
            if (mode=="scene") options.rawExposure=SONY2FUJI_EXPOSURE_SCENE;
            else if (mode=="preview") options.rawExposure=SONY2FUJI_EXPOSURE_PREVIEW;
            else if (mode=="sensor") options.rawExposure=SONY2FUJI_EXPOSURE_SENSOR;
            else { std::cerr << "Invalid RAW exposure mode: " << mode << '\n'; return false; }
        } else if (arg == "--exposure") {
            if (i + 1 < argc) {
                options.exposure = std::stof(argv[++i]);
            } else {
                std::cerr << "错误: " << arg << " 需要参数\n";
                return false;
            }
        } else if (arg == "--brightness") {
            if (i + 1 < argc) {
                options.brightness = std::stof(argv[++i]);
            } else {
                std::cerr << "错误: " << arg << " 需要参数\n";
                return false;
            }
        } else if (arg == "--no-lut") {
            options.noLut = true;
        } else if (arg[0] != '-') {
            if (options.inputFile.empty()) {
                options.inputFile = arg;
            } else {
                std::cerr << "错误: 意外的参数 '" << arg << "'\n";
                return false;
            }
        } else {
            std::cerr << "错误: 未知选项 '" << arg << "'\n";
            return false;
        }
    }

    // 验证必需参数
    if (options.inputFile.empty() || options.outputFile.empty()) {
        std::cerr << "错误: 缺少必需参数\n";
        return false;
    }

    // 如果不是 --no-lut 模式,则必须提供 LUT 文件
    if (!options.noLut && options.lutFile.empty()) {
        std::cerr << "错误: 请提供 LUT 文件 (-l) 或使用 --no-lut 直接输出\n";
        return false;
    }

    return true;
}

OutputFormat getOutputFormat(const std::string& filename) {
    size_t dotPos = filename.find_last_of('.');
    if (dotPos != std::string::npos) {
        std::string ext = filename.substr(dotPos + 1);
        if (ext == "jpg" || ext == "jpeg" || ext == "JPG" || ext == "JPEG") {
            return OutputFormat::JPEG;
        } else if (ext == "png" || ext == "PNG") {
            return OutputFormat::PNG;
        }
    }
    return OutputFormat::JPEG;  // 默认
}

int main(int argc, char* argv[]) {
    Options options;

    if (!parseArguments(argc, argv, options)) {
        printUsage(argv[0]);
        return 1;
    }

    sony2fuji_request request{};
    request.version = SONY2FUJI_REQUEST_VERSION;
    request.struct_size = sizeof(request);
    request.input_type = SONY2FUJI_INPUT_RAW;
    request.input_path = options.inputFile.c_str();
    request.lut_path = options.noLut ? nullptr : options.lutFile.c_str();
    request.lut_strength = 1;
    request.wb_mode = options.autoWhiteBalance ? SONY2FUJI_WB_AUTO : SONY2FUJI_WB_CAMERA;
    request.exposure_ev = options.exposure;
    request.brightness = options.brightness;
    request.contrast = request.saturation = 1;
    request.temperature = 6500;
    request.size_mode = SONY2FUJI_SIZE_NATIVE;
    request.intent = SONY2FUJI_INTENT_FINAL;
    request.output_target = SONY2FUJI_TARGET_FILE;
    request.output_path = options.outputFile.c_str();
    request.output_format = getOutputFormat(options.outputFile) == OutputFormat::PNG ?
        SONY2FUJI_OUTPUT_PNG : SONY2FUJI_OUTPUT_JPEG;
    request.jpeg_quality = options.quality;
    sony2fuji_session* session = nullptr;
    auto status = sony2fuji_session_create(&session);
    if (status == SONY2FUJI_STATUS_OK) status = sony2fuji_session_set_raw_exposure_mode(session,options.rawExposure);
    if (status == SONY2FUJI_STATUS_OK) status = sony2fuji_process(session, &request, nullptr);
    sony2fuji_session_destroy(session);
    if (status != SONY2FUJI_STATUS_OK) {
        std::cerr << "Processing failed: " << sony2fuji_status_message(status)
                  << ". Use a declared Fuji F-Log/F-Log2/F-Log2C CUBE with BT.709 output or compiled DCP .rlook.\n";
        return 1;
    }
    std::cout << "Saved: " << options.outputFile << '\n';
    return 0;
}
