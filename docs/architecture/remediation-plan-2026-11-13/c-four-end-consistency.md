> 返回索引：[RawLab 综合整改任务清单](../remediation-plan-2026-11-13.md)

# C. 四端一致性专项（主 §14.8 × 复审 × 0cf4a88a）

✅ 一致或已修；❌ 仍有问题；⏳ 在飞；— 不适用。

| 规则 | Mac（参考端） | iOS | Android | Windows | 结论 |
|---|---|---|---|---|---|
| 普通图片粘到 RAW：曝光基准占位 | ✅ #250 `MacAdjustmentTransfer.swift:159` | ✅ #250 `IOSAdjustmentTransfer.swift:136` | ✅ #285 `AdjustmentTransfer.kt` | ✅ #255 `AdjustmentTransfer.cs:116` | **✅ 复核通过**（四端共享向量全绿） |
| 同上：白平衡占位（none/null 当成相机白平衡） | ✅ #270 | ✅ #270 | ✅ #285 | ✅ #255 `AdjustmentTransferWB.cs:68` | **✅ 复核通过**（四端共享向量全绿） |
| 同上：“全部”范围时镜头五项被关掉 | ✅ #270 | ✅ #270 | ✅ #285 | ✅ #285 | **✅ 复核通过**（四端共享向量全绿） |
| 同上：默认范围时 RAW 降噪被清零 | ✅ #270 | ✅ #270 | —（两个键恒为 0） | —（两个键恒为 0） | **✅ 复核通过** |
| RAW 降噪的交换字段（`raw_level` 还是 `post_rgb`） | #301 RAW 目标忽略 `post_rgb`；栅格/非 Bayer/AI 目标仍抛错 | #301 RAW 目标忽略 `raw_level`；栅格目标收非 0 `post_rgb` 仍抛 `incompatible` | #301 忽略两键并提示 | #301 忽略两键（AI 开启时抛 `ai.target_denoise`） | **复核：部分成立**（#301 @ `a61d8111`：RAW/HDR 目标已对齐，栅格/非 Bayer/AI 目标分叉，且 iOS/Win 提示 UI 有回归，见 D-02） |
| 带配方的普通照片粘到 HDR 时按强度换算 | ✅ #250 `Shared/HDRAdjustmentTransfer.swift:107` | ✅（共用 Shared） | ✅ #312 `AdjustmentTransfer.kt:245` | ✅ #255 `HDRAdjustmentTransfer.cs:80` | **✅ 复核通过**（#312 @ `916ecadd` 补齐 A17） |
| 普通模式“重置全部”保留未启用的 HDR | ✅ 参考行为 | ✅ #256 | ✅ #253 | ✅ #255（经 `Defaults(edit)`；`HDRChecks.cs:134-158`） | **✅ 复核通过**；Windows 的 `Adjustments.ResetAll()` 是死路径，见 L2 |
| HDR 显示映射和相机显影的重置入口 | ✅ #280 `.hdrRendition` 分组+单项重置 | ❌ 无「HDR 渲染」分组、滑杆无双击重置 | ❌ 无独立「HDR 渲染」分组 | ❌ 无独立「HDR 渲染」分组 | **复核：部分成立**（Q5 #280 @ `83381e8e` 仅 Mac 落地） |
| 粘贴时比较处理版本 | ✅ #301 沿用目标版本并提示 | ✅ #301 | ✅ #301 | ✅ #301 | **✅ 复核通过**（#301 @ `a61d8111`，UI 展示缺陷同见 D-02） |
| 预设库、外观库逐条容错 | ❌ `Shared/AdjustmentPresetStore.swift:170-180`（#313 在途，未合入） | ❌ 同上 | ❌ `AdjustmentPresetStore.kt:108-130` | ✅ #251 + #288 UI 展示（**✅ 复核通过**） | 以 Windows 为参照移植（P2-16 在途） |
| 重置入口七种范围 | ✅ #307 | ✅ #262 + #307 | ✅ #307 | ✅ #307 | **复核：部分成立**（#307 @ `3afff0b8` 接入共享重置向量，但 `@spec_default` 掩盖 wire 载荷分歧） |
| 相机：坏文件卡住、张数上限 | — | ✅ #258（联机上限见 I-N6） | ✅ #257 + #296（联机 10k 截窗） | — | **✅ 复核通过**（iOS 联机上限仍见 P1-19） |
| 相机：重连后认上次进度 | — | #267（三段抽样，契约注记待落盘） | ❌ A12 | — | **Android 偏离**；建议照搬 iOS 方案（Q7，完成-06 契约注记待随 P1-23/P3-47 补齐） |

**整改顺序**

1. **在飞 PR 合入**：Mac/iOS 的白平衡、镜头、旧版降噪占位，加上 `adjustment-transfer-scenarios-v1.json` 和契约文档。这是后面所有移植的“规则源”。
2. **Android 一个 PR**：A18（曝光基准）、白平衡、镜头占位、A17（HDR 配方强度），全部用共享场景向量驱动。Android 的 80 条硬编码计数（主 §14.7.1c）一并改成读文件长度。
3. **Windows 一个小 PR**：只改镜头占位，跑场景向量。
4. **产品决策 Q3、Q4 之后**：`raw_level`/`post_rgb` 语义和处理版本比较写进场景向量，再四端各改一次。
5. **预设库、外观库逐条容错**：Mac/iOS 一个 Shared PR，Android 一个 PR，都以 Windows 的 `ListUnreadable` 为参照。
