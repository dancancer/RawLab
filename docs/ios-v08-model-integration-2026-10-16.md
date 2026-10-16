# iOS 0.8 合并后的模型与原生处理验证

本轮最小模型矩阵全部完成：**401 条断言与 3 组 viewport 回归通过，7 项测试最终均完成并返回 0，零跳过、零运行超时。import-state 是同一已链接 binary 的首次续跑；原 wrapper 因执行连接恢复而消失，没有完整退出记录。** 这份报告只记录模型／处理器层；系统 PhotosPicker、完整应用的实际导出与 RUM UI 由协调会话另行验收，不混算。

## 精确来源

- 最终测试源码：`9ec42c6649a5797efeefcf74ea2e3b3ba1a4c284`。
- 应用由协调会话在 `f2857bef02ff49ffaacfdd8b7fe41cae235e9e29` 完成 `build-for-testing`；`RawLab/RawLab` tree 为 `6c48c015fc6d8e5f53670ed9d6e512738243e5ea`。其后提交只修测试隔离与编译输入；本轮结束核对产品、Shared 和 native source/header 相对该应用构建无差异。
- 使用本轮重新构建的 arm64 simulator framework；native core tree 为 `f454bab64993119d45795d5996702a824daadea5`，输入 dylib SHA256 为 `67bd918c1ebce865f1c4c1665b2bb233c86d5ccda85dc734184e90deffc6e293`。未用旧预构建库代替新源码。
- 专用 iPhone 18 Pro / iOS 27 Simulator：`47310A81-02AA-45A1-807A-431181E4D338`，名称 `RawLab V08 Model Integration`。只读 Foundation probe 与真实 RAW harness 均确认 home、Documents、cache、tmp 位于该设备的 `data/` 内；未使用真实用户 profile。
- 证据根目录：`/tmp/rawlab-ios-v08-integration-20261016/models/`。`test-inputs.json` 保留源码／脚本 hash，`final-model-summary.json` 汇总实际结果，`runtime-boundaries.jsonl` 保留受限 runtime 调用。

## 最小矩阵与结果

| 脚本 | 本轮实际结果 | 覆盖范围 |
| --- | --- | --- |
| `import-state.sh` | 167 断言 PASS | 正常导入、独立历史恢复、取消、迟到成功／失败／预览拒绝、编辑锁、retained 文件释放、DNG 成功／失败后的最新参数及尺寸重放。输入为生成的 PNG；不冒充真实 RAW 全链。 |
| `raw-import-history.sh` | 15 断言 PASS | 真实 DJI DNG 的不同 identity／历史设置；迟到 A 不能覆盖 B；成功回调只为接纳 B 触发一次；保存与重新打开、两轴透视画布及像素；独立 fresh Processor 重算精确一致。 |
| `viewport-state.sh` | 3 组 PASS | 忙碌尺寸／最新编辑与降噪取消、DNG 成功和失败后的尺寸重放。 |
| `geometry-processing.sh` | 60 断言 PASS | 独立 C setter 透视参考、旋转／翻转／裁剪／校正、CPU／Auto／Force Metal、DNG 尺寸、冻结 batch、旧历史默认值；真实 RAW 冷 WB 透视 preview=FINAL、session 两轴复位与 Auto／CPU 差异界限。 |
| `processor-export.sh` | 56 断言 PASS | buffer／真实 RAW、JPEG／DNG、方向与 EXIF、手动／自动镜头匹配、CPU／Force Metal、HSL／效果、原生尺寸降噪与独立 FINAL／JPEG 精确对照。未启用完整大师配方排列穷举。 |
| `batch-export.sh` | 89 断言 PASS | 冻结参数、journal、单行失败继续、取消／重试、恢复／容器迁移、DNG checkpoint 与目录故障语义；纯模型使用生成 payload。 |
| `batch-publication.sh` | 14 断言 PASS | Photos 拒绝时 DNG 文件恢复／核对、过时确认不会重置已完成 DNG、文件删除后的重放；JPEG 权限不足与人工确认。 |

计数排除 suite 总结行：RAW history 日志为 16 条 PASS 行、batch export 为 90 条、batch publication 为 15 条；分别只有 15、89、14 条断言。viewport 保留“三组”单位，不按三个单一断言混入总数。

RAW history 的 A/B 使用同一份 DNG 字节及不同 identity／参数，不构成不同相机覆盖。恢复后的 native canvas 为 1890×2700；preview PNG SHA256 为 `73cba3d291e2d5509f73d597fec541dc4e186b47759d985972c3be5d37c434a6`，与独立全新 Processor 的结果一致。

## 素材、输出与原图保护

- 镜头／常规 RAW 输入：共享只读 Sony ARW，45,199,360 字节，SHA256 `dc280884db9e0d2e1e7389dca1370958ea8fde749cef8169702f64237d98763f`，直接引用主工作区 `.cache/shared/raw/`。未复制、下载或 chmod 共享素材。
- RAW history、透视与原生降噪输入：任务私有 DJI DNG 副本，19,545,856 字节，SHA256 `0ecdc8087d566c5ba39f9bd40eef4dfc5f3884ccb016f311a606508751c79eaf`，位于证据根目录 `fixtures/DJI_20250602164503_0444_D.DNG`，并保留到协调会话的真实PhotosPicker UI完成。UI完成后已核对同一hash并删除该磁盘副本，见任务根目录cleanup-final.json。
- 运行结束分别核对共享 Sony、共享 DJI 原件及 DJI 私有副本的 hash，均与运行前相同；见 `final-input-hashes.json`。不能将共享 Sony 描述为私有副本。
- 单张导出全部写入任务 `/tmp` 输出目录，现保留于 `processor-export-artifacts/`；9 个实际输出共 3,914,577 字节，文件 hash／大小见 `processor-output-files.json`。

## 真实失败、修复与基础设施归属

首轮 host batch 运行中，既有 DNG publication 测试把默认输出解析为真实 `/Users/xupeng/Documents/Exports`，创建被文件系统沙箱拒绝（NSCocoaErrorDomain 513），该轮不计通过。只改测试：脚本以 `CFFIXED_USER_HOME` 指向临时 profile，Swift 首个文件写入前断言实际输出根目录位于该 profile。隔离版 89 条断言全过；未提权重试真实 Documents，也没有修改产品路径逻辑。

首轮 import-state 在链接阶段发现新引入的 `Shared/tests/UsageAnalyticsTests.swift` 和 `UsageTransportTests.swift` 各含独立 main。7 个 harness 的 production 源码 glob 现排除 `!**/tests/**`；绝对路径比对确认只排除这两个测试入口，保留 49 个 production Swift 文件。初始 link 失败无模型 runtime，不计通过。相关修复已由协调会话独立复核并提交；产品不改。

并发启动的任务模拟器曾出现 CoreSimulator launch-host 等待，之后 exec-server 恢复又使暂停的父 shell 消失。已结合原日志 0 PASS／FAIL、无 fixture 目录、无 app code signature、空 task cache 及进程检查，确认既有 import-state runtime 尚未开始。协调会话只恢复它拥有的 3 台任务设备，旧设备未动；后续按 PHONE→PAD→MODELS 单设备时段继续。MODELS 时段直接对已有 1,623,376 字节 binary 签名并首次 spawn，167 断言在 9.722 秒内通过，没有重新编译或重复 runtime。旧终端恢复失败与初始沙箱／链接失败的原始日志保留；不将它们描述为产品断言失败。

余下 4 项在同一专用设备顺序执行，runtime spawn 上限 300 秒，install／privacy／uninstall 上限 60 秒；实际全部在界限内 exit 0。Lensfun 数据库重复 Tamron 模型 warning 与旧 trailing-closure 弃用 warning 保留，未据此改产品。

## 重跑命令与证据

以下命令从 iOS worktree 执行，APP 必须是与实际源码／架构配置匹配的新构建；DEVICE 必须是任务自有设备。

```sh
bash RawLab/tests/import-state.sh "$APP" "$DEVICE"
bash RawLab/tests/raw-import-history.sh "$APP" "$DEVICE" "$DJI_PRIVATE" "$TASK_TMP/raw-history"
bash RawLab/tests/viewport-state.sh "$APP" "$DEVICE"
bash RawLab/tests/geometry-processing.sh "$FRAMEWORK" "$DEVICE" "$DJI_PRIVATE"
RAWLAB_TEST_RAW="$SONY_SHARED" RAWLAB_TEST_DENOISE_RAW="$DJI_PRIVATE" bash RawLab/tests/processor-export.sh "$APP" "$DEVICE"
bash RawLab/tests/batch-export.sh
bash RawLab/tests/batch-publication.sh "$APP" "$DEVICE"
```

本轮 import-state 编译日志为 `import-state.log`，首次实际 runtime 是 `import-state-runtime.log`（原已链接 binary 的延续命令详见同名 result JSON）；其余同脚本名 `.log`。初始失败见 `batch-export-initial-host-profile-blocked.log`、`import-state-initial-duplicate-main.log`。完整实际命令／环境／退出码见 `model-results.json`、`import-state-runtime-result.json`、`geometry-result.json`、`batch-export-result.json`。

已清理已完成 harness、重复 framework、bridge.o、module cache 与一次性执行 helper。legacy geometry `build/` 单次输出已移到任务 `/tmp`，其余保留必要的小型测试输入／输出、JSON、日志。专用模拟器仅清除本任务随机 identity 的 19 个 cached 输入；无未知文件被删，RawLabImports 与 Exports 无遗留文件。模型阶段交接时设备未shutdown，私有DJI副本暂保留供真实RAW UI。后续UI完成后，主任务已卸载测试App、正常关机，并核对hash后删除该磁盘副本；详见任务根目录cleanup-final.json与simulator-diagnostics/final-device-cleanup.json。App/XCTest产品及native framework由主任务统一管理。

## 边界

本轮没有增加产品修复，没有修改 Shared／native 数学、其它平台或真实用户 profile，没有提交／推送／修改 PR。新测试及脚本隔离由主任务提交为 `f2857bef`、`8b0264fa`、`9ec42c66`。

模型层直接调用真实 ViewModel／processor，不等于完整 PhotosPicker provider 等待取消、iCloud、真实 Files／Photos 导出或不同相机端到端验收。RUM 这里只验证导入成功 hook 的接纳／迟到规则，opt-in／privacy／lifecycle UI 另有协调会话证据。没有实机触觉、帧率／输入延迟或硬件辅助功能证据；这些边界保持待验。旧单次 SwiftUI 发布 warning 不因本模型日志未出现而宣称已修复。所有本地 PASS 都不是托管 CI PASS。
