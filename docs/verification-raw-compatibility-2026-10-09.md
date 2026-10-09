# RAW 兼容性修复与复测 2026-10-09

同一批 DPReview 26 款相机样片完成修复后重测：**24 款样片通过，2 款 HE* 压缩样片仍不支持**。上一轮的 14 通过、9 有限制、3 不通过中，10 个问题样片现已通过；没有放宽测试阈值，也没有全局关闭 OpenMP。

结论仅对应[样片清单](../lutools/tests/dpreview-raw-samples.json)中的文件，不代表这些机型的所有压缩、位深、连拍、电子快门或像素位移模式都已验证。

## 本轮仍无法修复

| 机型 / 当前样片 | 已确认原因 | 当前处理及后续条件 |
| --- | --- | --- |
| Nikon Z6III，NEF HE*，ISO 100 | MakerNote `NEFCompression=14`；LibRaw 0.22.2 的 `nikon_he_load_raw()` 直接返回不支持。当前公开 master 仍无可用 HE* 解码器 | 明确拒绝解码，不生成伪装成功的图像。可改用 Lossless compression 重新拍摄并补充验证；本轮没有该机型的 lossless 对照 |
| Nikon Z50II，NEF HE*，ISO 100 | 同样为 `NEFCompression=14`；RAW strip 起点 `3600896` 是 JPEG-XS/TicoRAW 标记 `ff 10 ff 50`。原库遗漏 `NIKON Z50_2` 的 HE 检测，误用普通解码器才产生横纹/绿块 | 已修复错误路由和坏图仍导出的行为，现正确返回不支持；HE* 像素解码尚未实现。后续条件同上，不能据此判定所有 Z50II NEF 都不支持 |

依据：[LibRaw 官方支持列表](https://www.libraw.org/supported-cameras)、[公开 HE 解码入口](https://github.com/LibRaw/LibRaw/blob/d1f0dd95d662b140592b2e0221558b1076f925ec/src/decoders/decoders_libraw_dcrdefs.cpp)。[LibRaw PR #826](https://github.com/LibRaw/LibRaw/pull/826) 尚未合并且其公开方案不支持 HE*；[dnglab PR #835](https://github.com/dnglab/dnglab/pull/835) 仍为未充分验证的实验实现，不能作为生产正确性的证明。

[Nikon Image SDK](https://sdk.nikonimaging.com/information/en/) 可作为另一个 Mac/Windows 后端评估，但需要接受其协议并新增后端集成，也不覆盖当前 Android/iOS；本轮没有下载、集成或分发该 SDK。上述两项是当前公开依赖和本轮实现下未能可靠解码，不是宣称格式永远无法支持。

## 已落实的修复

| 问题样片 | 根因与修改 | 复测证据 |
| --- | --- | --- |
| Canon EOS R6 Mark III | ColorData 子版本 66 被按 v11 读取，黑白点偏移错误；另缺精确机型矩阵。对 `len=3778/SubVer=66` 使用库内已有 v12 偏移，并补入 Adobe-derived 矩阵 | 黑电平恢复为 512，高光线性上限由异常 144 恢复为 13995；严重洋红消失；RAW/WB/Mac 导出通过 |
| Sony a7R VI | 默认内嵌 JPEG 为 9984×6656，超过 64000000 像素解码上限。保留上限，改用已有的较小预览 | 预览曝光匹配、RAW/WB/Mac 全尺寸导出通过 |
| Fujifilm X-T5、X-S20、X100VI | X-Trans 并行 tile 从共享图像读取重叠边缘，同时邻 tile 写回显影结果，形成数据竞争。改为所有 tile 从同一只读输入副本读取 | 默认 OpenMP 下三款重复显影、曝光线性、WB reset、缓存恢复和 Mac 导出通过；X-T5 完整 CPU/Metal 检查通过 |
| Nikon Z5II、Fujifilm GFX100RF、OM-3 | 缺少精确机型 XYZ-to-camera 校准矩阵。采用有来源的对应型号矩阵，保留文件内黑白点，不套用相似机型参数 | 三款 RAW、绝对 Kelvin/tint、as-shot 等效性和 Mac 导出通过 |
| OM-1 | `use_camera_matrix=1` 随 WB 模式切换，在相机内嵌矩阵与表中矩阵之间切换。改为 `3`，保持色矩阵选择独立于 WB 模式 | as-shot 等效蓝通道误差从 0.829209% 降至 0.000064%，原门槛仍为 0.5%；其他通道和 CPU/Metal 通过 |
| Hasselblad X2D II 100C | 0.22.2 缺少 SensorCode 22 活动区域裁切。回移植官方已合并的规则 | 从带黑边的 11904×8842 改为 11664×8750；新增独立尺寸断言；RAW/WB/Mac/CPU-Metal 通过，图像检查无原有传感器黑边 |

核心还在 `unpack()` 成功后检查 `error_count()`，避免部分解码器只记录损坏却继续导出坏图。没有修改 RAW 原文件。

### 来源与边界

- 可复现补丁：[patch-libraw.cmake](../lutools/cmake/patch-libraw.cmake)。保留 LibRaw 0.22.2 / ABI 25，不整体切换到 ABI 不同的 master。
- 哈苏裁切来自官方提交 [bcb267e](https://github.com/LibRaw/LibRaw/commit/bcb267e0d53808a7db857c79a21a4f6d7f2388a8)。11664×8750 是该上游活动区域规则，不等同于 Phocus/厂商标称的 11656×8742。
- 四个精确机型矩阵来自 RawSpeed [cameras.xml @ c835b05](https://github.com/darktable-org/rawspeed/blob/c835b05aecfacb7343f7c424abd620aa12116c3f/data/cameras.xml)，单独保存在 [rawspeed-camera-calibration.inc](../lutools/third_party/rawspeed-camera-calibration.inc)，保留 CC BY-SA 3.0 归属及修改说明。未引入 RawSpeed 解码器。
- R6 III 的格式/矩阵资料来自 [ErikCJohansson 的 issue #821](https://github.com/LibRaw/LibRaw/issues/821)，解析复用 LibRaw 已有 v12 布局。本地样片已验证，但尚非官方完整机型支持；不扩大为 Dual Pixel、burst 或所有压缩模式已通过。
- X-Trans 修复保留并行能力，代价是显影期间每像素增加 8 字节只读副本，40 MP 约增加 304 MiB。Android 只完成构建，移动设备峰值内存尚未验证；本轮没有增加臆测的内存阈值或降级策略。
- Mac 源码依赖构建、Android、Windows 和 iOS 均接入同一补丁。未打补丁的系统/Homebrew 0.22.2 不自动获得修复；外部依赖需先应用脚本再重建。

## 逐机型最终结果

“通过”指本轮检查未发现问题，不是精确色彩标定认证。Pentax 使用原生 DNG，不代表 PEF 已测试。

镜头畸变校正及相机 JPEG 风格匹配不在本次解码/WB 兼容验证范围。GFX100RF 等 RAW 可保留与机内 JPEG 不同的几何畸变，因此缩略图相关性不能作为精确图像一致性的结论。

| 机型 | 格式 / ISO | 输出尺寸 | 结论 | CPU/Metal |
| --- | --- | --- | --- | --- |
| Canon EOS R5 Mark II | CR3 / 100 | 8192×5464 | 通过 | 通过 |
| Canon EOS R6 Mark III | CR3 / 100 | 6960×4640 | 通过，本地样片修复 | 未配置 |
| Canon EOS R7 | CR3 / 100 | 6960×4640 | 通过 | 未配置 |
| Canon EOS 5D Mark IV | CR2 / 200 | 6720×4480 | 通过 | 未配置 |
| Sony a7 IV | ARW / 200 | 7008×4672 | 通过 | 通过 |
| Sony a7 V | ARW / 100 | 7008×4672 | 通过 | 未配置 |
| Sony a7R VI | ARW / 100 | 9984×6656 | 通过 | 未配置 |
| Sony a6700 | ARW / 100 | 6192×4128 | 通过 | 未配置 |
| Nikon Z6III | NEF HE* / 100 | 无有效输出 | 不支持，见单独表格 | 未到达图像比较 |
| Nikon Z8 | NEF / 100 | 8256×5504 | 通过 | 未配置 |
| Nikon Z5II | NEF / 100 | 6048×4032 | 通过 | 未配置 |
| Nikon Z50II | NEF HE* / 100 | 无有效输出 | 不支持，已阻止坏图导出 | 未配置 |
| Fujifilm X-T5 | RAF / 125 | 7728×5149 | 通过 | 通过 |
| Fujifilm X-S20 | RAF / 160 | 6240×4155 | 通过 | 未配置 |
| Fujifilm X100VI | RAF / 125 | 7728×5149 | 通过 | 未配置 |
| Fujifilm GFX100RF | RAF / 100 | 11648×8735 | 通过 | 未配置 |
| Panasonic Lumix DC-S5II | RW2 / 100 | 6000×4000 | 通过 | 通过 |
| Panasonic Lumix DC-S1II | RW2 / 100 | 6000×4000 | 通过 | 未配置 |
| Panasonic Lumix DC-GH7 | RW2 / 100 | 5776×4336 | 通过 | 未配置 |
| OM System OM-1 | ORF / 200 | 5184×3888 | 通过 | 通过 |
| OM System OM-3 | ORF / 200 | 5184×3888 | 通过 | 未配置 |
| Leica Q3 43 | DNG / 200 | 9520×6336 | 通过 | 通过 |
| Pentax K-3 Mark III | DNG / 200 | 6192×4128 | 通过 | 通过 |
| Pentax K-1 Mark II | DNG / 200 | 7360×4912 | 通过 | 未配置 |
| Ricoh GR IV | DNG / 200 | 6192×4128 | 通过 | 通过 |
| Hasselblad X2D II 100C | 3FR / 200 | 11664×8750 | 通过 | 通过 |

## 验证结果

环境为 macOS 27.0 arm64，LibRaw 0.22.2 加上述补丁、默认 OpenMP，核心 Metal 后端；核心目录 `lutools/build-macos`，应用 `build/RawLab Mac.app`。26 张原始样片约 1.42 GiB，不纳入 Git。

| 检查 | 修复前 | 修复后 |
| --- | --- | --- |
| `raw_smoke` | 20/26 | 24/26；剩余 2 个为 HE* 拒绝解码 |
| `white_balance_tests` | 17/26 | 24/26；剩余 2 个无可用解码输入 |
| Mac `--smoke` | 21/26，包含错误放行的 Z50II | 24/26；剩余 2 个拒绝输出 |
| `acceleration_tests` | 8/10 | 9/10；Z6III 在解码阶段失败，9 个可解码样本全部通过 |
| CTest | 本轮重新执行 | 14/14 通过 |
| Mac 调整回归 | 本轮重新执行 | 7 个本地 RAW fixture 通过 |
| Mac 构建与打包 | 本轮重新执行 | 构建、签名及动态依赖检查通过；最终包 OM-1 smoke 通过 |
| Android `:app:assembleDebug` | 本轮重新执行 | arm64-v8a / x86_64 构建通过；非设备运行认证 |

RAW 检查包含 LibRaw 参考一致性、默认曝光、8/16-bit、曝光线性、重复显影、内嵌预览匹配及原始文件保护。WB 检查包含校准有效性、温度/色调端点、变化方向、as-shot 等效性、reset 和曝光锚定。Mac 检查中性/PROVIA、缓存恢复、全尺寸 JPEG 和 16-bit PNG。GPU 比较要求实际 Metal 后端，RGB8 差值仍为最多 2 DN。

相同 LibRaw 的参考一致性不能单独证明解码正确，因此另检查实际导出图像，确认 R6 III 无原有洋红、哈苏无原有黑边，检查 PNG 完整性及输出尺寸。所有通过样片均有实际 JPEG/PNG 导出；未把 Nikon HE* 失败改成跳过或自动通过，批量运行器保留非零退出码。

补丁在重新解压的官方 0.22.2 源码上连续应用两次成功，生成的 `src/` 与实际构建源码完全一致，验证了干净构建与幂等性。后续同日的 Windows/iOS 验证见下节。

## iOS 平台验证

使用 Xcode 27 / iOS 26.4 模拟器，最低部署版本 18.0。新增[一键构建入口](../lutools/platform/ios/build-framework.sh)，从固定摘要的 LibRaw 0.22.2 与 LibRaw-cmake 源码构建目标依赖，应用同一相机补丁，不再使用旧 0.21.5。

- `bash lutools/build.sh ios`：设备 arm64、模拟器 arm64/x86_64 三个架构构建成功；版本、架构、系统动态依赖和许可证检查通过。替换后的 `sony2fuji.xcframework` 被实际应用构建使用，旧框架保留于 `lutools/build-ios/previous.*/`。
- RawLab 模拟器 Debug 与设备 Release（`CODE_SIGNING_ALLOWED=NO`）构建通过。
- 9 款样片通过 `raw_smoke` 和 `white_balance_tests`：S5II、R6 III、OM-1、a7R VI、X-T5、Z5II、GFX100RF、OM-3、X2D II。没有重新宣称全 26 款完成 iOS 测试。
- S5II、R6 III、OM-1 在模拟器中通过完整 `acceleration_tests`，实际 Metal 后端及原有像素门槛不变。
- Z50II HE* 按预期退出 1 并报告 `Unsupported file format or not RAW file`，不是成功解码。
- `RawLab/tests/processor-export.sh` 使用真实 Sony RAW 验证应用封装、带元数据 JPEG、绝对 Kelvin 与 200% LUT 导出，通过。

日志：[框架构建](../build/raw-compatibility/ios-build-final.log)、[模拟器应用](../build/raw-compatibility/ios-app-simulator-final.log)、[设备应用构建](../build/raw-compatibility/ios-app-device-final.log)、[首批 RAW/WB/Metal](../build/raw-compatibility/ios-raw-tests.log)、[其他 6 款 RAW/WB](../build/raw-compatibility/ios-other-tests.log)、[应用导出](../build/raw-compatibility/ios-processor-export.log)、[HE* 拒绝](../build/raw-compatibility/ios-z50ii-rejection.log)。

边界：未在物理 iPhone/iPad 运行，未验证移动设备峰值内存、温控或签名分发。模拟器 Metal 使用 Mac 主机能力，不能代替真机 GPU/内存验收。

## Windows 平台验证

复用用户授权的 Proxmox VM 100，名称调整为 `rawlab-windows-build`：Windows 11 Pro x64（build 22631.6199）、16 vCPU、约 16 GiB 内存、200 GiB 系统盘。安装 QEMU Guest Agent、OpenSSH Server、.NET 8.0.425 SDK 和 VS 2022 Build Tools；实际编译器 MSVC 19.44.35229.0、CMake 3.31.6-msvc6、Windows SDK 10.0.26100.0。VS 同时安装了 .NET 9 SDK，实际发布命令使用 SDK 9.0.318，应用目标仍为 `net8.0-windows` / `win-x64`，包含 .NET 8 运行时。

SSH 使用独立公钥认证，关闭密码认证，主机公钥通过 Guest Agent 核对；入站 22 端口只允许当前 Mac 与 Proxmox 主机。SSH 服务自动启动，接交流电时关闭自动睡眠。没有修改其他 VM，也没有使用 Windows 真机编译。

编译和测试结束后已重启 VM，未再次手动登录 Windows；SSH 重新连接成功，`sshd` / `QEMU-GA` 自动运行，.NET SDK 与 CMake 均可调用，见[重启后验证](../build/raw-compatibility/windows-after-reboot.log)。VM 保持运行；当前使用 DHCP，后续地址变化时更新构建命令的 `--host`。

[远程构建脚本](../RawLabWindows/build-remote.py) 已实际发送当前未提交工作区，在 VM 原生构建共享核心、带补丁 LibRaw 和 WPF 应用，再打包取回 Mac。首次运行发现原有 ExifTool 检查在 Windows PowerShell 5.1 丢失空参数，已使用 `ProcessStartInfo.Arguments` 保留 `-config ""`，修复后完整流程退出 0。

最终产物：[RawLab-Windows.zip](../build/windows-remote/20261009-102117/RawLab-Windows.zip)，[完整构建日志](../build/windows-remote/20261009-102117/build.log)。包内确认存在 `RawLab.exe`、`sony2fuji.dll`、LibRaw `0.22.2-Release` / R6 III 标记、Visual C++ / OpenMP 运行库、ExifTool 13.59，以及 LibRaw 双许可证和 RawSpeed 校准数据归属。

VM 原生运行结果：

- `color_contracts`、`native_dcp_look`、`image_stats` 三项 CPU CTest 全部通过。
- S5II、R6 III、OM-1、a7R VI、X-T5、Z5II、GFX100RF、OM-3、X2D II 共 9 款样片，`raw_smoke` 和 `white_balance_tests` 共 18 项全部通过。测试保留实际 Windows MSVC/OpenMP 配置，未调整图像门槛。
- X2D II 的参考与实际输出均为 `11664x8750`；Z50II HE* 返回非零退出码及 `Unsupported file format or not RAW file`，没有伪装成功。
- [执行汇总](../build/raw-compatibility/windows-cpu-tests.log)、[逐机型日志](../build/raw-compatibility/results/windows-vm100/)、[本次执行脚本](../build/raw-compatibility/windows-cpu-tests.ps1)。样片只复制到专用 VM 工作目录，不改写原始照片。

VM 只提供 `Microsoft Basic Display Adapter`。未执行要求真实 Direct3D 11 设备的完整 `build.ps1 -Test`，不将 WARP 或 CPU 回退计作 GPU 通过，也不将本轮构建算作 WPF 交互、远程桌面性能或其他未发布功能的全面验收。

## 复现与证据

从仓库根目录构建带补丁的依赖及应用：

```bash
bash RawLabMac/build-dependencies.sh
export PKG_CONFIG_PATH="$PWD/build/macos15-deps/$(uname -m)/install/lib/pkgconfig"
MACOSX_DEPLOYMENT_TARGET=15.0 bash RawLabMac/build.sh

python3 lutools/tests/run_raw_compatibility.py \
  --samples build/raw-compatibility/samples \
  --output build/raw-compatibility/results/new-run

ctest --test-dir lutools/build-macos --output-on-failure
bash RawLabMac/tests/adjustments.sh
```

`--output` 必须是新目录；可加 `--only fuji_xt5 om_1` 缩小范围。下载样片时保留清单 URL 中的原文件名；不得用内嵌 JPEG 代替 RAW。

- 修复后：[自动结果](../build/raw-compatibility/results/fixes-20261009/results.json)、[导出与图像检查汇总](../build/raw-compatibility/results/fixes-20261009/summary.json)、[逐机型日志与图像](../build/raw-compatibility/results/fixes-20261009/)。
- [最终 Mac 包 OM-1 smoke](../build/raw-compatibility/results/final-bundle-om1.log)。
- 图像总览：[第 1 页](../build/raw-compatibility/results/fixes-20261009/contact-sheet-1.jpg)、[第 2 页](../build/raw-compatibility/results/fixes-20261009/contact-sheet-2.jpg)、[第 3 页](../build/raw-compatibility/results/fixes-20261009/contact-sheet-3.jpg)。
- 原始基线：[14 通过 / 9 有限制 / 3 不通过](../build/raw-compatibility/results/run-20261009/summary.json)，旧日志和输出保留，未覆盖。
- 诊断对照：[X-T5 单线程实验](../build/raw-compatibility/results/xtrans-single-thread/results.json)，不是最终产品的线程策略。

以上为修复阶段记录；当时尚未提交、推送或发布。`build/` 链接指向本机留存证据，不随 Git 源码发布。下节记录从独立发布工作区重新构建的结果。

## v0.4.1 独立发布验证

发布分支为 `codex/raw-compatibility-v041`，基线为 `origin/main` 的 `80c360d`。只迁移本轮 RAW 兼容性、构建工具和发布文档；未包含另一个工作区的批量导出、编辑记忆或 RAW 降噪开发。四端版本统一为 `0.4.1` / build `7`，Windows 文件版本为 `0.4.1.7`。

| 独立发布工作区检查 | 结果 |
| --- | --- |
| Mac arm64 / x86_64 应用构建 | 均通过；最低 macOS 15、架构、依赖闭包与 ad-hoc 签名检查通过 |
| Mac 核心 CTest | arm64 8/8、x86_64 8/8 通过，包含现有 DJI RAW/WB/Metal 检查 |
| Mac arm64 全 26 款样片 | 24 款的 RAW/WB/应用导出全部通过；原有 2 款 Nikon HE* 拒绝解码，批量运行器仍按设计返回非零；9 个可解码 GPU 样片全部通过 |
| Mac Intel / Rosetta | R6 III、X-T5、S5II、OM-1 的 15 个已配置阶段全部通过，其中 3 款包含 CPU/Metal 比较 |
| Mac 调整与导出 | S5II、Sony 和 DJI 共 3 个 fixture 通过独立调整回归，包括原尺寸、16-bit 和预览/导出一致性 |
| Windows x64 | 从隔离源码在专用 VM 重新编译 WPF/native 自包含包；9 款 RAW/WB 共 18 项、3 项 CPU CTest 通过，Z50II HE* 拒绝检查通过 |
| Android | arm64-v8a/x86_64 正式签名 APK 构建、签名、16 KB ZIP/ELF 对齐检查通过；36 项主机单元测试通过；实际 APK 版本为 0.4.1/7 |
| Android 升级签名 | 与从 GitHub 下载的 v0.4.0 APK 证书 SHA-256 相同：`9fd68e245a597cde2abb949ff807819a89afdd4b000b5ad02391181f38a06048` |
| iOS | 三架构 XCFramework、未签名设备 Release、模拟器 Debug 构建通过；S5II/R6 III/OM-1/X-T5 的 RAW/WB 通过，前三款 Metal 通过，应用导出及 HE* 拒绝检查通过 |
| 发布附件 | 五个客户端安装包及 LibRaw 补丁源码归档检查通过；核对版本、运行库、许可证、归档完整性并生成 `SHA256SUMS.txt` |

重新检查了 R6 III 与 X2D II 的实际中性 JPEG，没有出现原有严重洋红或传感器黑边；24 款成功导出的 PNG 均为 16-bit。LibRaw 源码附件包含实际补丁源码、固定 LibRaw-cmake、补丁/校准数据及[重建说明](releases/libraw-0.22.2-build.md)，其 `src/` 与 iOS 本轮构建源码一致。

发布工作区的证据根目录为 `build/releases/v0.4.1/`：`compatibility-arm64/results.json`、`compatibility-x86_64/results.json`、`windows-cpu-results/`、`ios-raw-tests/`、`ios-xtrans-tests/` 和 `logs/`。Windows 源码同步还确认此前批量导出/编辑记忆源文件已从专用构建目录移除，未混入发布包。

本轮没有配置 GitHub Actions，不将“没有 CI checks”表述为 CI 通过；Windows 真显卡/WPF 交互、Android 设备运行和 iOS 物理设备/内存验证仍不在本轮通过范围内。原始开发工作区保留不动。[发布说明](releases/v0.4.1.md)列出附件和已知限制。
