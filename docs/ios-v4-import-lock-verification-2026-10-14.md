# iOS v4 导入、裁剪锁与异步身份修复

基线：`3f87abb5d2188e36c3bbdfafe4ed070f71cffda6`，独立工作树 `codex/ios-editor-v4`。

修复实现与测试提交：`92afb1b3d78a4fb82834daba8943898376e22dbe`。本报告与独立复核记录在其后的文档提交中；最终交接 HEAD 与该实现提交的产品/测试源码一致。

原报告确认的是源码可达的锁缺口，尚未动态观察到 RAW A 的旧帧覆盖 RAW B。本次修复和回归阻断该路径，不把它描述为已发生的数据覆盖事故。

## 修复

- 四个角和移动区域统一遵守编辑锁；锁定或切图时取消活动裁剪，清起点，旧触摸不能恢复旧起点。新触摸仍可正常编辑。
- 工具条、几何/镜头草稿绑定和预览入口守锁。绑定同时核对创建时的来源 revision；旧绑定不能跨图写入。锁定时的拖动结束出口不排旧图预览。
- PhotosPicker 的获取任务可取消，await 前后及错误/恢复设置回调均核对请求身份。取消后获得的 retained 文件会释放；旧请求不能清除新请求的导入状态。
- 导入成功、失败、恢复设置只有活动导入请求可发布。导入开始、完成和取消都使旧预览任务失效；预览、错误、直方图和完成回调同时核对来源 revision 与 render ID。
- 独立复核发现的逆序尺寸问题也已修复：降噪尺寸任务在 DNG 导出忙碌时到期，保留 requested edge 和最新设置，导出完成再重放；不提前消费实际预览尺寸。

仅改 iOS UI、iOS ViewModel/照片获取保护及对应测试。Shared、Sony2Fuji 处理算法、缓存、其他平台和设计样式未改。`resultDelivery` 的生产默认仍为主队列异步发布；测试可以扣住已经完成计算的结果，没有生产延时或调试按钮。

## 本次通过证据

| 检查 | 结果 | 日志／结果 |
|---|---|---|
| 最新 app + UI runner 构建 | TEST BUILD SUCCEEDED | `/tmp/rawlab-ios-v4-import-ui-r2-build.log` |
| 确定性导入/取消/旧结果/手势状态，以及逆序 DNG 成功/失败尺寸重放 | 167 assertions PASS | `/tmp/rawlab-ios-v4-import-state-complete.log` |
| 既有忙碌尺寸、降噪取消、DNG 成功及失败后重放 | 三组 PASS | `/tmp/rawlab-ios-v4-import-viewport-r2.log` |
| 真实四角/移动、锁中旧坐标、取消＋迟到 B、各手势中途导入、新触摸恢复 | 4/4 PASS，零跳过 | `/tmp/rawlab-ios-v4-crop-lock-r2/crop-lock-ui.log`、同目录 `.xcresult` |
| 原有裁剪比例解锁/拖角/旋转、几何 Cancel/Apply/退出确认 | 2/2 PASS | `/tmp/rawlab-ios-v4-import-existing.log`、`.xcresult` |
| 默认测试未显式安装/启用独立容器 | 4 项明确 skipped，0 failures | `/tmp/rawlab-ios-v4-crop-lock-default.log` |

专用设备：iPhone `6BAF1C5B-C060-46FC-99C5-BEB18F1F7CE1`、iPad `A9E7D8B6-8145-4E53-A0E7-8791A5EFA14B`，iOS 27 Simulator / Xcode 27。

状态回归使用生成的小 raster，真实 ViewModel 解码/渲染后由测试扣住发布闭包，按 B→A 或取消→迟到 A 释放，检查来源、图像、比较图、直方图、尺寸、状态、busy 和恢复回调。逆序 DNG 测试实际写文件，核对 TIFF 容器、DNGVersion 标记和最终尺寸。ImageIO 识别该线性 DNG 容器，但未提供帧级 DNG 字典；测试按实际文件格式检查。

原生触控容器使用真实 `EditorCropOverlay` 和真实 ViewModel，XCTest 发送实际坐标拖动。它明确使用独立测试应用，并不向 RawLab 加入测试按钮。初版容器因 SDK 27 要求 UIScene 生命周期而在启动阶段失败；修正后四项完整通过，不将初次失败或默认跳过算作触控通过。

## 重跑入口

先用项目 `RawLab/RawLab.xcodeproj`、scheme `RawLab` 完成 `build-for-testing`，保留生成的 `.xctestrun`。本次 derived data 为 `/tmp/rawlab-ios-v4-import-derived`，使用 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO` 及现有 arm64 simulator 桥接 framework。

```sh
bash RawLab/tests/import-state.sh <built-RawLab.app> <dedicated-simulator-UDID>
bash RawLab/tests/viewport-state.sh <built-RawLab.app> <dedicated-simulator-UDID>
bash RawLab/tests/crop-lock-ui.sh <built-RawLab.app> <dedicated-simulator-UDID> <original.xctestrun> <new-output-directory>
```

`crop-lock-ui.sh` 编译、安装测试容器，复制已有版本 1 `.xctestrun` 并保留其路径与环境，显式启用四项容器用例。普通测试不依赖模拟器里曾经安装过该应用；未启用时明确跳过。

## 独立复核与边界

两位独立审查者覆盖初轮 15/15 修改/新增文件，记录了尺寸逆序问题和容器测试入口问题，随后针对修复复核。首轮报告：[行为](../reviews/self-ios-import-state-behavior-20261014.md)、[边界](../reviews/self-ios-crop-lock-regression-20261014.md)；收尾报告：[行为](../reviews/self-ios-import-state-recheck-20261014.md)、[边界](../reviews/self-ios-crop-lock-recheck-20261014.md)。

最终冻结范围为 16 个实现/测试文件，两位收尾复核均无 Must-fix、无 Should-fix，首轮两项问题已关闭；提交前逐文件核对源码与复核快照一致，`git diff --check` 通过。

真实触控覆盖组件＋ViewModel，完整 PhotosPicker 等待阶段的切换/晚错误/取消链由获取 helper 回归和源码复核支撑，没有完整应用录制证明。未重复真机触觉、性能或全部旧 UI 套件。此前父任务在精确 `3f87abb` 的真实 RAW Cancel/Apply/Reset/JPEG+DNG 验证属于旧基线证据，不冒充新提交的 RAW 结果复核；新精确 SHA 交由该验证任务复核。

全部操作保留在独立工作树与本任务模拟器。本地提交；没有推送、PR、合并或发布。
