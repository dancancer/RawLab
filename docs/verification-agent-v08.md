# Agent v0.8 分阶段验证

## 起点与边界

- 本任务独立 worktree：`/Users/xupeng/.codex/worktrees/bb72/rawtools`。
- 2026-10-15 刷新 `origin/development`，起点为 `acfc4ae99b09b16949914cc22f91603007e4d258`。
- 分支 `feature/agent-complete-edits`；只做本地开发、测试和提交，不 push、PR、merge 或发布。
- 不改移动端 Agent、不做 MCP；macOS 收口后才进入 Windows。

## 默认单张预览

本地提交 `c872d9b`。`EditorView` 默认关闭比较，每次照片 URL 变化重置；只保留用户按钮
在同一照片内切换，参数更新及异步渲染不写此状态。编辑持久化不含比较偏好。

- `python3 RawLabMac/tests/test_single_preview.py`：RED 后 GREEN，3 项源码契约通过。
- `bash RawLabMac/tests/edit-model.sh`：历史恢复、未编辑默认、reset、失败保存保护通过。
- 尚未进行原生按钮点击验收；不把源码契约称为交互实测。

## macOS 完整 RAW 配方

JSON v4 保存最终生效的核心参数。曝光/WB/look/几何之外，补齐对比度、饱和度、高光、阴影、
现有单滑杆 S 曲线、锐化、24 个 HSL 控件、暗角/颗粒全部子参数、小波/显示色度/FBDD 降噪、
镜头畸变/TCA/自动裁边/手动 profile。没有改变 request v2 布局或现有 enum 值。

`RenderEngine.agentRecipe` 返回 Data，不写图片；复用 `Adjustments.apply(to:)`、
`renderHSLSettings` 和当前照片白平衡解析，固化大师配方强度及分项结果，不再次乘整体强度。
保留旧配方 HSL 版本及降噪优先级。v1/v2/v3 严格字段边界与默认结果不变。

`--lens-database` 是本地离线数据库配置，不是图像编辑参数。能力查询返回构建实际支持的
optional features；缺少可选算法时启用请求明确失败，不假装成功。

look 输出覆盖 guard 来自核心 owner 的 `4f95bceb3b3473104869854c3f6389ce82c93c5f`，
本任务只移入该小段保护，并扩展 input/recipe/look 的 direct、normalized、symlink、hardlink
回归。未 cherry-pick 该 owner 整个提交，也未改其工作树；其他核心回归仍待协调集成。

### 实际运行

- parser RED：`Unsupported schema_version: 4`；范围补测 RED：`edits.detail.sharpening is out of range`。
- `edit_recipe_tests`：626 checks 通过；新字段非默认 sentinel 也验证失败时目标保持不变。
- `ctest --test-dir lutools/build-macos --output-on-failure`：33/33 通过，65.78 秒。
- `python3 lutools/tests/test_agent_commands.py --cli lutools/build-macos/sony2fuji --raw lutools/examples/DJI_20250602164503_0444_D.DNG`：14 tests 通过，含 optional features 和输入覆盖保护。
- `bash RawLabMac/build.sh`：完整 app 构建、JXL、bundle 动态依赖与 ad-hoc 签名检查通过。
- `bash RawLabMac/tests/agent-recipe-render.sh lutools/examples/DJI_20250602164503_0444_D.DNG lutools/build-macos/sony2fuji`：通过。

三入口测试使用只读真实 DJI RAW、同一 CPU 后端、相同尺寸与 PNG16：GUI Engine FINAL、
Agent CLI、直接 FINAL 的解码像素 exact；混合非默认 tone/S 曲线/锐化/HSL/暗角/颗粒/小波/
旋转/裁切/透视、旧色度降噪、大师配方 0/50/100/200% 均通过。exact preview 为 248x257，
与同尺寸 FINAL exact。持久化恢复和批量 journal 冻结 settings/look/尺寸后 FINAL exact。

镜头用公开合成 `linear-lens.dng`/`lenses.xml`：实际应用畸变；GUI FINAL RGBA8 与 Agent
PNG16 独立量化后最大差 0。该合成 DNG 的 ImageIO metadata 不可读，不能用于 Swift
`ExportMetadata.preserve` 文件输出，故此例明确采用 FINAL buffer；真实 RAW 文件输出使用上面的 DJI。
没有增加 CPU/GPU 容差；Auto 和 Metal 的原有数值回归由本次 CTest 覆盖。

本轮初次借用旧 worktree 依赖时，该目录被外部清理导致 dyld 失败，未计为通过。
随后复制生成依赖到本 worktree 并重定位，重新完成上述构建和验证；共享素材及原始 RAW 未改写。
原始日志保留在系统临时目录：`/tmp/rawlab-agent-three-entry-final.log`、
`/tmp/rawlab-agent-core-ctest.log`、`/tmp/rawlab-agent-macos-build.log`、`/tmp/rawlab-agent-commands.log`。

## 后续里程碑

- 普通图像：实现和验收进行中；不把系统解码器能力视为应用已经支持。
- Windows：尚未开始适配或验证；进入阶段前刷新 development 与 PR #53。
