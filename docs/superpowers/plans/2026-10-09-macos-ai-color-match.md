# macOS AI Color Match Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当前 RAW 的 AI 仿色、本地显示 sRGB CUBE 生成、候选预览/应用/恢复，以及 CUBE 分享导出。

**Architecture:** Swift 负责图片、DeepSeek、Keychain 和任务状态；原生 C++ 编译颜色配方。CPU/Metal 在中性显影后应用显式 sRGB CUBE，旧 Log CUBE 和 DCP 路径不变。现有外观库和逐图记录管理应用后的文件。

**Tech Stack:** SwiftUI/AppKit、Foundation、ImageIO/CoreGraphics、Security、C++17、Metal。

**Spec:** [已批准且已修订的设计](../specs/2026-10-09-macos-ai-color-match-design.md)

**Execution status (2026-10-09):** Tasks 1-5 implemented; automated gates and
independent review complete. Task 6 native-window acceptance remains blocked by
the locked Mac, and photographic reference quality remains untested. The
[verification report](../../verification-macos-ai-color-match-2026-10-09.md)
records actual results rather than treating implementation as visual acceptance.

## Global Constraints

- 分支 `codex/macos-ai-color-match`，当前目录工作，保留其他未提交改动；不混合提交、推送或发布。
- macOS 首发。API 自行配置，默认 DeepSeek；密钥 Keychain，`.env` 仅显式开发联调读取。
- 1-6 张参考图，1600 像素长边，每张最多 2 MiB，请求最多 24 MiB，超时 90 秒，单次主动操作一次推理请求。
- 不上传 RAW；上传前应用方向、ICC 转 sRGB、重新编码且不带元数据。不记录认证头或图像请求体。
- 默认 65-grid，最多升级一次 129-grid，原生重读后最大采样通道误差 0.02，不静默放宽。
- 新 CUBE 声明 `#Gamma:sRGB to sRGB` 和 `#Gamut:ITU-R BT.709 to ITU-R BT.709`。不增加 Python/OCIO 应用依赖，不修改 PHOTO v2 布局。
- 主代理负责修改和最终验证，子代理协助只读探索和核验，遵循用户协作约定。
- 用户已批准 sRGB 修订；[Log 烘焙失败证据](../../verification-ai-lut-bake-2026-10-09.md)保留。

## Task 1: 显示域 CUBE 运行时

**Files:** `lutools/include/sony2fuji/lut_parser.h`, `src/core/lut_parser.cpp`, `src/ffi/sony2fuji_c.cpp`, `src/gpu/metal_photo.mm`, `src/gpu/gles_photo.cpp`, `src/gpu/d3d11_photo.cpp`, 新增 `tests/srgb_look_tests.cpp`，修改 `CMakeLists.txt`。

**Interfaces:** 新增内部 `LUTTransfer::SRGB`；现有 C API 签名不变。SRGB 输入必须显式 sRGB 输出和 BT.709 色域，不自动识别未标注创意 LUT。

- [x] 添加 sRGB identity / swap 的 buffer 测试，先运行观察旧实现拒绝新类型。
- [x] 断言 `abs(actualRed - neutralDisplay(sourceBlue)*255) <= 1`；0/0.5/1/2 强度均在显示域混合。
- [x] parser 精确识别声明，CPU 使用 `base` 查表，Metal shader 选择 `filmInput=base`；GLES/D3D11 新类型返回 false，保留 Auto/Force 处理。
- [x] `ctest --test-dir lutools/build-macos -R 'srgb_look|color_contracts|gpu_photo' --output-on-failure`。新测试断言真实 Metal 后端，不伪装 GPU 成功。

## Task 2: 配方与编译器

**Files:** 新增 `lutools/include/sony2fuji/color_recipe.h`, `src/core/color_recipe.cpp`, `src/ffi/color_look_c.cpp`, `tests/color_recipe_tests.cpp`；窄改 C 头与 CMake。

**Interfaces:** 版本1共40个 float：tone[9]、chroma、8组 hue/chroma/lightness、3组 a/b。新增：

```cpp
sony2fuji_status sony2fuji_compile_color_look(uint32_t version,
    const float* parameters, size_t count, const char* destination,
    sony2fuji_color_look_report* report);
sony2fuji_status sony2fuji_export_color_look(const char* source, const char* destination);
```

- [x] 先写恒等、数值锚点、越界/NaN/曲线、已存在目标、脱敏重导出测试并观察缺少入口的失败。
- [x] 实现 `ColorRecipe::apply(RGB)`：九点分段线性 L 曲线；八色相归一化权重 `exp((cos(h-center)-1)/radians(35)^2)`；近灰抑制 `C*C/(C*C+0.035^2)`。
- [x] 染色权重 `shadow=1-smoothstep(.2,.6,L)`、`highlight=smoothstep(.4,.8,L)`、`mid=1-shadow-highlight`；加色乘 `4*L*(1-L)`。色域外在线性 RGB 中沿 `gray=L^3` 方向收敛到立方体边界，色域内不变。原先 Oklab 固定L/h二分在蓝色射线多次进出色域时产生跳变，已由测试反例否定；不宣称新算法严格保持感知色相/明度。
- [x] R-fast 写出、原生重读、固定域/灰阶/色相渐变测误差。65未过才129，失败不安装目标；报告网格和 max/mean/p99。
- [x] `ctest --test-dir lutools/build-macos -R 'color_recipe|srgb_look' --output-on-failure`，验证恒等和代表配方。

## Task 3: Swift 数据、图片与 API

**Files:** 新增 `RawLabMac/Sources/AIColorRecipe.swift`, `AIService.swift`, `AIImage.swift`, `AISettings.swift` 和 `tests/AI*Tests.swift`, `tests/ai-data.sh`, `tests/ai-workflow.sh`, `tests/ai-live.sh`, `tests/ai-render.sh`。

**Interfaces:** `AIColorRecipe: Codable` 提供 `validated()` 和 `parameters: [Float]`；`AIService.generate(configuration:key:images:instruction:previous:) async throws -> AIColorRecipe`；`AIImage` 保存 CGImage/JPEG Data，不发送路径。

- [x] 先写假 URLProtocol 成功/空输出/截断/401/429/取消测试，验证正式 API 不因测试增加环境开关。
- [x] Foundation 校验字段集后 Codable 解码；HTTPS规范化与按地址隔离Keychain，禁止重定向。推理一次请求，JSON mode，响应有限大小，不回显原始错误体。
- [x] ImageIO先检查尺寸，再方向缩略与CoreGraphics转sRGB，JPEG不附元数据。测试参考失败、方向、尺寸和格式限制。
- [x] 测试连接只GET models；正式程序不自动读.env；配置不序列化密钥。

## Task 4: 候选与编辑状态

**Files:** 新增 `AIColorMatchModel.swift`, `AIColorLook.swift`；窄改 `EditorModel.swift`, `Engine.swift`, `Adjustments.swift`, `LookLibrary.swift`。

**Interfaces:** 任务模型暴露生成/继续调整/取消/候选；EditorModel提供冻结、条件应用和恢复操作，现有渲染/批量接口不变。

- [x] 先写快照保留输入/细节而重置输出、取消、换片、重复请求不能提交旧结果的测试。
- [x] 独立串行队列/session精确渲染，不使用含旧输出调整的neutral；网络不占原编辑渲染队列。
- [x] 确认后安装新UUID外观、保存完整编辑、单次发布UI；失败保持原编辑，提供恢复动作。
- [x] 本地保留校验配方/模型/误差，临时与托管文件生命周期分离；运行 `edit-model.sh`, `edit-memory.sh`, `look-library.sh`, `look-import-model.sh`。

## Task 5: UI、导出与分享

**Files:** 新增 `AIColorMatchView.swift`, `AISettingsView.swift`, `AIShare.swift`；窄改 `EditorView.swift`, `FilmDock.swift`, `RawLabMacApp.swift`。

- [x] 先测试候选/托管外观导出、源别名保护、取消/写失败、头部清理、重导入表值保持。
- [x] 原生writer脱敏写目标目录临时文件后原子安装；NSSavePanel确认覆盖，保护RAW/参考图/托管LUT。
- [x] NSSharingServicePicker以独立副本和强引用管理生命周期，系统完成/失败/取消后清理，关闭AI面板不提前删除。文件 provider 已测；系统界面验收见 Task 6 未完成项。
- [x] 原生sheet提供对比、参考条、强度、要求、阶段、错误；应用/导出/分享独立，明确原始100%及sRGB输入。
- [x] 配置SecureField/连接测试，已保存AI外观菜单提供分享；保持现有底部调整栏布局。

## Task 6: 验证交付

- [x] `bash RawLabMac/build.sh`，新增及受影响核心/Swift回归。
- [x] 真实RAW的CPU/Metal、强度、JPEG/16-bit PNG全分辨率输出，保持降噪原有CPU回退。
- [x] 人工测试图进行DeepSeek新schema联调，不擅自上传私人照片；无授权真实参考素材则如实列为未覆盖。
- [ ] 原生最小950x620及常用窗口检查，无输入/失败/生成/预览/分享取消/应用恢复。
- [x] 独立只读评审本功能diff、修复实际问题并记录测试；无推送和发布。
